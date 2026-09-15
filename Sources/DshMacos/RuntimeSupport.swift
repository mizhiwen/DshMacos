import Darwin
import Foundation

enum HarnessPorts {
    static let `default`: UInt16 = 3080
}

private let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

struct NodeVersion: Comparable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2,
              let major = Int(components[0]),
              let minor = Int(components[1]) else { return nil }
        let patchText = components.count > 2
            ? components[2].prefix { $0.isNumber }
            : Substring("0")
        guard let patch = Int(patchText) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var description: String { "v\(major).\(minor).\(patch)" }

    var supportsParseEnv: Bool {
        if major >= 22 { return true }
        if major == 21 { return minor >= 7 }
        if major == 20 { return minor >= 12 }
        return false
    }

    var supportsZstd: Bool { major >= 22 }

    static func < (lhs: NodeVersion, rhs: NodeVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

func normalizedLoopbackURL(_ rawValue: String) throws -> URL {
    guard
        let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
        let scheme = url.scheme?.lowercased(),
        let host = url.host?.lowercased(),
        ["http", "https"].contains(scheme),
        loopbackHosts.contains(host),
        url.user == nil,
        url.password == nil
    else {
        throw AppError.message("Harness 只允许使用本机回环 HTTP 地址")
    }
    return url
}

func publishedHarnessURL(from output: String) -> URL? {
    var fallback: URL?
    for line in output.split(whereSeparator: \.isNewline) {
        guard let url = firstLoopbackHTTPURL(in: String(line)) else { continue }
        if urlHasLaunchToken(url) { return url }
        fallback = fallback ?? url
    }
    return fallback
}

func urlsShareOrigin(_ lhs: URL?, _ rhs: URL) -> Bool {
    guard let lhs, let left = harnessOrigin(lhs), let right = harnessOrigin(rhs) else {
        return false
    }
    return left == right
}

func isHarnessReadyStatus(_ status: Int) -> Bool {
    (200 ..< 400).contains(status)
}

func isHarnessReachableStatus(_ status: Int) -> Bool {
    isHarnessReadyStatus(status) || status == 401
}

func persistHarnessServiceURL(_ url: URL, to file: URL = AppPaths.harnessServiceURL) {
    try? url.absoluteString.write(to: file, atomically: true, encoding: .utf8)
}

func persistedHarnessServiceURL(from file: URL = AppPaths.harnessServiceURL) -> URL? {
    guard
        let raw = try? String(contentsOf: file, encoding: .utf8),
        let url = try? normalizedLoopbackURL(raw)
    else {
        return nil
    }
    return url
}

func lastPublishedHarnessURL(fromLog log: String) -> URL? {
    for line in log.split(whereSeparator: \.isNewline).reversed() {
        if let url = publishedHarnessURL(from: String(line)) {
            return url
        }
    }
    return nil
}

func adoptedHarnessURL(port: UInt16, persisted: URL?, logged: URL?) -> URL {
    let fallback = URL(string: "http://127.0.0.1:\(port)")!
    if let persisted, urlsShareOrigin(persisted, fallback) { return persisted }
    if let logged, urlsShareOrigin(logged, fallback) { return logged }
    return fallback
}

private func firstLoopbackHTTPURL(in line: String) -> URL? {
    guard let match = line.range(of: #"https?://\S+"#, options: .regularExpression) else {
        return nil
    }
    var raw = String(line[match])
    while let last = raw.last, ".,;)]".contains(last) {
        raw.removeLast()
    }
    return try? normalizedLoopbackURL(raw)
}

func urlHasLaunchToken(_ url: URL) -> Bool {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .contains { $0.name == "token" && !($0.value ?? "").isEmpty } ?? false
}

private func harnessOrigin(_ url: URL) -> (String, String, Int)? {
    guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
        return nil
    }
    let port: Int
    if let explicit = url.port {
        port = explicit
    } else if scheme == "http" {
        port = 80
    } else if scheme == "https" {
        port = 443
    } else {
        return nil
    }
    return (scheme, host, port)
}

func materializedArguments(_ arguments: [String], port: UInt16) -> [String] {
    var result = arguments.map { $0.replacingOccurrences(of: "{port}", with: String(port)) }
    if let index = result.firstIndex(of: "--port"),
       result.indices.contains(index + 1),
       result[index + 1] == "0"
    {
        result[index + 1] = String(port)
    }
    return result
}

func requestedHarnessPort(from arguments: [String]) throws -> UInt16 {
    guard let value = portArgumentValue(in: arguments) else {
        return HarnessPorts.default
    }
    if value == "{port}" {
        return HarnessPorts.default
    }
    if value == "0" {
        return try reserveAvailablePort()
    }
    guard let port = UInt16(value), port > 0 else {
        throw AppError.message("Harness 端口无效：\(value)")
    }
    return port
}

func portArgumentValue(in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: "--port"), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

func reserveAvailablePort() throws -> UInt16 {
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

func executableSearchDirectories(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
) -> [URL] {
    var paths = [
        home.appendingPathComponent(".local/bin", isDirectory: true),
        home.appendingPathComponent(".npm-global/bin", isDirectory: true)
    ]

    let nvmRoot = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
    if let versions = try? FileManager.default.contentsOfDirectory(
        at: nvmRoot,
        includingPropertiesForKeys: nil
    ) {
        paths.append(contentsOf: versions.sorted {
            $0.lastPathComponent.compare(
                $1.lastPathComponent,
                options: .numeric
            ) == .orderedDescending
        }.map { $0.appendingPathComponent("bin", isDirectory: true) })
    }

    paths.append(contentsOf: (environment["PATH"] ?? "")
        .split(separator: ":")
        .map { URL(fileURLWithPath: String($0), isDirectory: true) })
    paths.append(contentsOf: [
        URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
        URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        URL(fileURLWithPath: "/usr/bin", isDirectory: true),
        URL(fileURLWithPath: "/bin", isDirectory: true)
    ])

    var seen = Set<String>()
    return paths.filter { seen.insert($0.standardizedFileURL.path).inserted }
}

func searchDirectoriesForDshRuntime(
    from directories: [URL] = executableSearchDirectories()
) throws -> [URL] {
    var discoveredVersions: [NodeVersion] = []
    for directory in directories {
        let node = directory.appendingPathComponent("node")
        guard FileManager.default.isExecutableFile(atPath: node.path),
              let version = nodeVersion(at: node) else { continue }
        discoveredVersions.append(version)
        if version.supportsParseEnv {
            return [directory] + directories.filter {
                $0.standardizedFileURL != directory.standardizedFileURL
            }
        }
    }

    let found = discoveredVersions.isEmpty
        ? "未找到 Node.js"
        : "检测到 " + discoveredVersions.map(\.description).joined(separator: "、")
    throw AppError.message(
        "当前 DSH 需要 Node.js 20.12+（推荐 22）。\(found)，请安装或选择兼容版本。"
    )
}

func resolvedZstdNodeURL(
    from directories: [URL] = executableSearchDirectories()
) -> URL? {
    for directory in directories {
        let node = directory.appendingPathComponent("node")
        guard FileManager.default.isExecutableFile(atPath: node.path),
              let version = nodeVersion(at: node),
              version.supportsZstd else { continue }
        return node
    }
    return nil
}

private func nodeVersion(at executable: URL) -> NodeVersion? {
    let output = Pipe()
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--version"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let value = String(data: data, encoding: .utf8) else { return nil }
        return NodeVersion(value)
    } catch {
        return nil
    }
}

func cachedDshExecutableURLs(
    home: URL = FileManager.default.homeDirectoryForCurrentUser
) -> [URL] {
    let cacheRoot = home.appendingPathComponent(".npm/_npx", isDirectory: true)
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: cacheRoot,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }
    return entries
        .sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return left > right
        }
        .map { $0.appendingPathComponent("node_modules/.bin/dsh") }
        .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
}

func resolvedExecutableURL(
    command: String,
    searchDirectories: [URL] = executableSearchDirectories(),
    cachedDshExecutables: [URL] = cachedDshExecutableURLs()
) throws -> URL {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw AppError.message("请填写 Harness 启动命令") }

    let direct = URL(fileURLWithPath: trimmed)
    var candidates = (trimmed as NSString).isAbsolutePath
        ? [direct]
        : searchDirectories.map { $0.appendingPathComponent(trimmed) }
    if trimmed == "dsh" { candidates.append(contentsOf: cachedDshExecutables) }

    if let match = candidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0.path)
    }) {
        return match
    }
    throw AppError.message("找不到可执行文件：\(trimmed)")
}

enum HarnessProcessLease {
    private static let lock = NSLock()
    private static var pid: Int32?
    private static var port: UInt16?

    static func update(pid: Int32?, port: UInt16?) {
        lock.lock()
        self.pid = pid
        self.port = port
        lock.unlock()
        writeHarnessPIDFile(pid)
    }

    static func reap() {
        lock.lock()
        let pid = self.pid
        let port = self.port
        self.pid = nil
        self.port = nil
        lock.unlock()
        reapManagedHarness(pid: pid, port: port)
    }
}

func isManagedHarnessCommandLine(_ command: String, port: UInt16) -> Bool {
    let tokens = command
        .split { $0.isWhitespace }
        .map(String.init)
    let mentionsDsh = tokens.contains { token in
        let name = URL(fileURLWithPath: token).lastPathComponent
        return name == "dsh" || token.contains("@deepseek-ai/dsh")
    }
    guard mentionsDsh, tokens.contains("web") else { return false }
    if let index = tokens.firstIndex(of: "--port"), tokens.indices.contains(index + 1) {
        return tokens[index + 1] == String(port)
    }
    return port == HarnessPorts.default
}

func parseListenPIDs(from lsofOutput: String) -> [Int32] {
    lsofOutput
        .split(whereSeparator: \.isNewline)
        .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        .filter { $0 > 1 }
}

func readHarnessPIDFile(at url: URL = AppPaths.harnessPID) -> Int32? {
    guard
        let text = try? String(contentsOf: url, encoding: .utf8),
        let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
        pid > 1
    else {
        return nil
    }
    return pid
}

func writeHarnessPIDFile(_ pid: Int32?, at url: URL = AppPaths.harnessPID) {
    if let pid {
        try? String(pid).write(to: url, atomically: true, encoding: .utf8)
    } else {
        try? FileManager.default.removeItem(at: url)
    }
}

func terminateProcessTree(pid: Int32) {
    _ = kill(-pid, SIGTERM)
    _ = kill(pid, SIGTERM)
    var waited: useconds_t = 0
    while waited < 400_000, kill(pid, 0) == 0 {
        usleep(50_000)
        waited += 50_000
    }
    if kill(pid, 0) == 0 {
        _ = kill(-pid, SIGKILL)
        _ = kill(pid, SIGKILL)
    }
}

func loopbackListenPIDs(on port: UInt16) -> [Int32] {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return []
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return parseListenPIDs(from: String(data: data, encoding: .utf8) ?? "")
}

func processCommandLine(pid: Int32) -> String? {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-p", String(pid), "-o", "args="]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return text?.isEmpty == false ? text : nil
}

func reapManagedHarness(pid: Int32?, port: UInt16?) {
    var targets = Set<Int32>()
    if let pid { targets.insert(pid) }
    if let stored = readHarnessPIDFile() { targets.insert(stored) }
    if let port {
        for listener in loopbackListenPIDs(on: port) {
            if let command = processCommandLine(pid: listener),
               isManagedHarnessCommandLine(command, port: port)
            {
                targets.insert(listener)
            }
        }
    }
    for target in targets {
        terminateProcessTree(pid: target)
    }
    writeHarnessPIDFile(nil)
}

func reclaimManagedHarnessPort(_ port: UInt16) async throws {
    reapManagedHarness(pid: readHarnessPIDFile(), port: port)
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        let leftover = loopbackListenPIDs(on: port)
        if leftover.isEmpty { return }
        let ours = leftover.filter { pid in
            guard let command = processCommandLine(pid: pid) else { return false }
            return isManagedHarnessCommandLine(command, port: port)
        }
        if ours.isEmpty {
            throw AppError.message("端口 \(port) 已被其他程序占用")
        }
        ours.forEach(terminateProcessTree)
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    if loopbackListenPIDs(on: port).isEmpty { return }
    throw AppError.message("端口 \(port) 仍被旧的 Harness 占用，请关闭后重试")
}
