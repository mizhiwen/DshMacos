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
    private var generation = UUID()
    private let session: URLSession
    private let maxLogLines = 180

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 2
        session = URLSession(configuration: configuration)
    }

    var isBusy: Bool { phase == .starting || phase == .stopping }
    var isReady: Bool { phase == .ready && serviceURL != nil }

    func start(using settings: AppSettings) async {
        guard phase != .starting, phase != .ready else { return }
        let normalized = settings.normalized()
        let runGeneration = UUID()
        generation = runGeneration
        transition(to: .starting, url: nil, error: nil)

        do {
            try AppPaths.prepare()
            if normalized.launchMode == .external {
                let url = try normalizedLoopbackURL(normalized.externalURL)
                try await waitUntilReady(
                    url: url,
                    timeout: TimeInterval(normalized.startupTimeoutSeconds),
                    generation: runGeneration
                )
                guard generation == runGeneration else { return }
                transition(to: .ready, url: url, error: nil)
                return
            }

            let port = try reserveAvailablePort()
            let url = URL(string: "http://127.0.0.1:\(port)")!
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

            try await waitUntilReady(
                url: url,
                timeout: TimeInterval(normalized.startupTimeoutSeconds),
                generation: runGeneration
            )
            guard generation == runGeneration else { return }
            transition(to: .ready, url: url, error: nil)
        } catch {
            if let child = process { await terminate(child) }
            process = nil
            processID = nil
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
        process = nil
        processID = nil
        transition(to: .stopped, url: nil, error: nil)
    }

    func restart(using settings: AppSettings) async {
        await stop()
        await start(using: settings)
    }

    func stopImmediately() {
        generation = UUID()
        guard let child = process, child.isRunning else { return }
        let pid = child.processIdentifier
        if kill(-pid, SIGTERM) != 0 { child.terminate() }
        child.standardOutput = nil
        child.standardError = nil
        process = nil
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
        let output = Pipe()
        let error = Pipe()
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = workspace
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = error

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
                self.process = nil
                self.processID = nil
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

    private func waitUntilReady(url: URL, timeout: TimeInterval, generation: UUID) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastReason = "服务尚未响应"
        while Date() < deadline {
            guard self.generation == generation else {
                throw CancellationError()
            }
            if let child = process, !child.isRunning {
                throw AppError.message("Harness 进程在启动完成前退出")
            }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 1.5
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, (200 ..< 400).contains(http.statusCode) {
                    return
                }
                lastReason = "服务返回了非成功状态"
            } catch {
                lastReason = error.localizedDescription
            }
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        throw AppError.message("Harness 启动超时：\(lastReason)")
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

private func reserveAvailablePort() throws -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw AppError.message("无法创建本机端口") }
    defer { close(descriptor) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(0)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { throw AppError.message("无法绑定本机端口") }

    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            getsockname(descriptor, socketAddress, &length)
        }
    }
    guard nameResult == 0 else { throw AppError.message("无法读取本机端口") }
    return UInt16(bigEndian: address.sin_port)
}
