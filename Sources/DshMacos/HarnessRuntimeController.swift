import Darwin
import Foundation

enum HarnessPhase: String {
    case stopped
    case starting
    case ready
    case stopping
    case failed

    var title: String {
        switch self {
        case .stopped: return "已停止"
        case .starting: return "正在启动"
        case .ready: return "运行中"
        case .stopping: return "正在停止"
        case .failed: return "启动失败"
        }
    }
}

@MainActor
final class HarnessRuntimeController: ObservableObject {
    @Published private(set) var phase: HarnessPhase = .stopped
    @Published private(set) var serviceURL: URL?
    @Published private(set) var processID: Int32?
    @Published private(set) var errorMessage: String?
    @Published private(set) var logTail: [String] = []

    private var process: Process?
    private var stdinPipe: Pipe?
    private var publishedServiceURL: URL?
    private var generation = UUID()
    private let session: URLSession
    private let maxLogLines = 180

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 2
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        session = URLSession(
            configuration: configuration,
            delegate: HTTPRedirectBlockingDelegate.shared,
            delegateQueue: nil
        )
    }

    var isBusy: Bool { phase == .starting || phase == .stopping }
    var isReady: Bool { phase == .ready && serviceURL != nil }

    func start(using settings: AppSettings) async {
        guard phase != .starting, phase != .ready else { return }
        let normalized = settings.normalized()
        let runGeneration = UUID()
        generation = runGeneration
        publishedServiceURL = nil
        transition(to: .starting, url: nil, error: nil)

        do {
            try AppPaths.prepare()
            do {
                let repaired = try repairLegacyHarnessSessions(in: AppPaths.harnessHome)
                if repaired > 0 {
                    record("已兼容 \(repaired) 个旧会话，供新版 Harness 加载", source: "APP")
                }
            } catch {
                record("旧会话兼容修复未完成：\(error.localizedDescription)", source: "ERR")
            }
            if normalized.launchMode == .external {
                let url = try normalizedLoopbackURL(normalized.externalURL)
                _ = try await waitUntilReady(
                    fallbackURL: url,
                    timeout: TimeInterval(normalized.startupTimeoutSeconds),
                    generation: runGeneration
                )
                guard generation == runGeneration else { return }
                transition(to: .ready, url: url, error: nil)
                return
            }

            let port = try requestedHarnessPort(from: normalized.arguments)
            let fallbackURL = URL(string: "http://127.0.0.1:\(port)")!
            if portArgumentValue(in: normalized.arguments) != "0",
               let adopted = await adoptExistingHarness(on: fallbackURL)
            {
                attachExistingHarness(port: port)
                persistHarnessServiceURL(adopted)
                guard generation == runGeneration else { return }
                record("复用本机已运行的 Harness：\(adopted.host ?? "127.0.0.1"):\(port)", source: "APP")
                transition(to: .ready, url: adopted, error: nil)
                return
            }
            let executable = try resolvedExecutableURL(command: normalized.command)
            let workspace = try resolvedWorkspace(from: normalized.workspace)
            let arguments = materializedArguments(normalized.arguments, port: port)
            let child = try makeProcess(
                executable: executable,
                arguments: arguments,
                workspace: workspace,
                generation: runGeneration
            )

            record("启动 \(executable.lastPathComponent) \(arguments.joined(separator: " "))", source: "APP")
            try child.run()
            process = child
            processID = child.processIdentifier
            _ = setpgid(child.processIdentifier, child.processIdentifier)
            HarnessProcessLease.update(pid: child.processIdentifier, port: port)

            let url = try await waitUntilReady(
                fallbackURL: fallbackURL,
                timeout: TimeInterval(normalized.startupTimeoutSeconds),
                generation: runGeneration
            )
            persistHarnessServiceURL(url)
            guard generation == runGeneration else { return }
            transition(to: .ready, url: url, error: nil)
        } catch {
            if let child = process { await terminate(child) }
            resetProcess()
            guard generation == runGeneration else { return }
            transition(to: .failed, url: nil, error: error.localizedDescription)
            record(error.localizedDescription, source: "ERR")
        }
    }

    func stop() async {
        guard phase != .stopped, phase != .stopping else { return }
        generation = UUID()
        phase = .stopping
        if let child = process { await terminate(child) }
        HarnessProcessLease.reap()
        resetProcess()
        transition(to: .stopped, url: nil, error: nil)
    }

    func restart(using settings: AppSettings) async {
        await stop()
        await start(using: settings)
    }

    func stopImmediately() {
        generation = UUID()
        if let child = process {
            child.standardOutput = nil
            child.standardError = nil
        }
        process = nil
        processID = nil
        stdinPipe = nil
    }

    private func adoptExistingHarness(on fallbackURL: URL) async -> URL? {
        let adopted = adoptedHarnessURL(
            port: UInt16(fallbackURL.port ?? Int(HarnessPorts.default)),
            persisted: persistedHarnessServiceURL(),
            logged: lastPublishedHarnessURLFromDisk()
        )
        if let status = await probeHTTPStatus(adopted), isHarnessReadyStatus(status) {
            return adopted
        }
        if let status = await probeHTTPStatus(fallbackURL), isHarnessReachableStatus(status) {
            return adopted
        }
        return nil
    }

    private func lastPublishedHarnessURLFromDisk() -> URL? {
        guard
            let data = try? String(contentsOf: AppPaths.harnessLog, encoding: .utf8)
        else {
            return nil
        }
        return lastPublishedHarnessURL(fromLog: data)
    }

    private func attachExistingHarness(port: UInt16) {
        let pid = loopbackListenPIDs(on: port).first { pid in
            guard let command = processCommandLine(pid: pid) else { return false }
            return isManagedHarnessCommandLine(command, port: port)
        }
        processID = pid
        HarnessProcessLease.update(pid: pid, port: port)
    }

    private func probeHTTPStatus(_ url: URL) async -> Int? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 1.2
            request.httpShouldHandleCookies = false
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode
        } catch {
            return nil
        }
    }

    private func transition(to phase: HarnessPhase, url: URL?, error: String?) {
        self.phase = phase
        serviceURL = url
        errorMessage = error
    }

    private func resolvedWorkspace(from value: String) throws -> URL {
        if value.isEmpty { return AppPaths.defaultWorkspace }
        let url = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppError.message("工作区不存在：\(url.path)")
        }
        return url
    }

    private func makeProcess(
        executable: URL,
        arguments: [String],
        workspace: URL,
        generation: UUID
    ) throws -> Process {
        let stdin = Pipe()
        let output = Pipe()
        let error = Pipe()
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = workspace
        child.standardInput = stdin
        child.standardOutput = output
        child.standardError = error
        stdinPipe = stdin

        var searchDirectories = executableSearchDirectories()
        if executable.lastPathComponent == "dsh" {
            searchDirectories = try searchDirectoriesForDshRuntime(from: searchDirectories)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["DSH_HOME"] = AppPaths.harnessHome.path
        environment["PATH"] = searchDirectories
            .map(\.path)
            .joined(separator: ":")
        child.environment = environment

        observe(output.fileHandleForReading, source: "OUT", generation: generation)
        observe(error.fileHandleForReading, source: "ERR", generation: generation)
        child.terminationHandler = { completed in
            output.fileHandleForReading.readabilityHandler = nil
            error.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.resetProcess()
                HarnessProcessLease.update(pid: nil, port: nil)
                if self.phase == .stopping {
                    self.transition(to: .stopped, url: nil, error: nil)
                } else {
                    let reason = "Harness 已退出（code=\(completed.terminationStatus)）"
                    self.transition(to: .failed, url: nil, error: reason)
                    self.record(reason, source: "ERR")
                }
            }
        }
        return child
    }

    private func observe(_ handle: FileHandle, source: String, generation: UUID) {
        handle.readabilityHandler = { readable in
            let data = readable.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.record(text, source: source)
            }
        }
    }

    private func record(_ text: String, source: String) {
        if let published = publishedHarnessURL(from: text) {
            publishedServiceURL = published
        }
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "[\(source)] \($0)" }
        guard !lines.isEmpty else { return }
        logTail = Array((logTail + lines).suffix(maxLogLines))

        let payload = (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
        if !FileManager.default.fileExists(atPath: AppPaths.harnessLog.path) {
            FileManager.default.createFile(atPath: AppPaths.harnessLog.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: AppPaths.harnessLog) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        }
    }

    private func waitUntilReady(fallbackURL: URL, timeout: TimeInterval, generation: UUID) async throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        var lastReason = "服务尚未响应"
        let watchingProcess = process != nil
        while Date() < deadline {
            guard self.generation == generation else {
                throw CancellationError()
            }
            if watchingProcess, process == nil || process?.isRunning == false {
                throw AppError.message("Harness 进程在启动完成前退出")
            }
            let url = publishedServiceURL ?? fallbackURL
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 1.5
                request.httpShouldHandleCookies = false
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse {
                    if isHarnessReadyStatus(http.statusCode) {
                        return url
                    }
                    lastReason = urlHasPendingAuth(http.statusCode, url: url)
                        ? "服务已启动，正在等待启动 token"
                        : "服务返回了非成功状态（HTTP \(http.statusCode)）"
                }
            } catch {
                lastReason = error.localizedDescription
            }
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        throw AppError.message("Harness 启动超时：\(lastReason)")
    }

    private func urlHasPendingAuth(_ status: Int, url: URL) -> Bool {
        status == 401 && !urlHasLaunchToken(url)
    }

    private func resetProcess() {
        stdinPipe = nil
        process = nil
        processID = nil
        publishedServiceURL = nil
    }

    private func terminate(_ child: Process) async {
        guard child.isRunning else { return }
        let pid = child.processIdentifier
        if kill(-pid, SIGTERM) != 0 { child.terminate() }

        let deadline = Date().addingTimeInterval(5)
        while child.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if child.isRunning {
            if kill(-pid, SIGKILL) != 0 { child.interrupt() }
        }
    }
}

private final class HTTPRedirectBlockingDelegate: NSObject, URLSessionTaskDelegate {
    static let shared = HTTPRedirectBlockingDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
