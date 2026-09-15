import Foundation

enum AppPaths {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DshMacos", isDirectory: true)
    }

    static var settings: URL { root.appendingPathComponent("settings.json") }
    static var harnessHome: URL { root.appendingPathComponent("harness-home", isDirectory: true) }
    static var defaultWorkspace: URL { root.appendingPathComponent("workspace", isDirectory: true) }
    static var wallpapers: URL { root.appendingPathComponent("wallpapers", isDirectory: true) }
    static var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    static var harnessLog: URL { logs.appendingPathComponent("harness.log") }

    static func prepare() throws {
        for directory in [root, harnessHome, defaultWorkspace, wallpapers, logs] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }
}

final class SettingsStore {
    private let fileManager: FileManager
    private let settingsURL: URL

    init(fileManager: FileManager = .default, settingsURL: URL = AppPaths.settings) {
        self.fileManager = fileManager
        self.settingsURL = settingsURL
    }

    func load() -> AppSettings {
        guard
            let data = try? Data(contentsOf: settingsURL),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return AppSettings()
        }
        return decoded.normalized()
    }

    func save(_ settings: AppSettings) throws {
        try fileManager.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings.normalized())
        try data.write(to: settingsURL, options: .atomic)
    }

    func importWallpaper(from source: URL) throws -> URL {
        let allowed = ["png", "jpg", "jpeg", "webp"]
        let ext = source.pathExtension.lowercased()
        guard allowed.contains(ext) else {
            throw AppError.message("壁纸仅支持 PNG、JPEG 和 WebP")
        }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 20 * 1_024 * 1_024 else {
            throw AppError.message("壁纸文件无效或超过 20 MB")
        }
        try AppPaths.prepare()
        let destination = AppPaths.wallpapers
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }
}

enum AppError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message): return message
        }
    }
}
