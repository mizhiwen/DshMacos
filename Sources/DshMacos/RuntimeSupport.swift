import Foundation

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

func materializedArguments(_ arguments: [String], port: UInt16) -> [String] {
    arguments.map { $0.replacingOccurrences(of: "{port}", with: String(port)) }
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
