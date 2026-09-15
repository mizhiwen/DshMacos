import Foundation

enum HarnessLaunchMode: String, Codable, CaseIterable, Identifiable {
    case managed
    case external

    var id: String { rawValue }
}

enum WallpaperFit: String, Codable, CaseIterable, Identifiable {
    case cover
    case contain
    case fill

    var id: String { rawValue }
}

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
}

struct WallpaperSettings: Codable, Equatable {
    var path = ""
    var fit: WallpaperFit = .cover
    var opacity = 0.84
    var blur = 0.0
    var overlay = 0.34
    var positionX = 0.5
    var positionY = 0.5

    func normalized() -> WallpaperSettings {
        var copy = self
        copy.opacity = copy.opacity.clamped(to: 0 ... 1)
        copy.blur = copy.blur.clamped(to: 0 ... 40)
        copy.overlay = copy.overlay.clamped(to: 0 ... 0.9)
        copy.positionX = copy.positionX.clamped(to: 0 ... 1)
        copy.positionY = copy.positionY.clamped(to: 0 ... 1)
        return copy
    }
}

struct AppSettings: Codable, Equatable {
    static let currentVersion = 3

    var version = AppSettings.currentVersion
    var autoStart = false
    var launchMode: HarnessLaunchMode = .managed
    var command = "dsh"
    var arguments = ["web", "--no-open", "--port", "{port}"]
    var workspace = ""
    var externalURL = "http://127.0.0.1:3080"
    var startupTimeoutSeconds = 60
    var appearanceMode: AppearanceMode = .system
    var wallpaper = WallpaperSettings()

    enum CodingKeys: String, CodingKey {
        case version
        case autoStart
        case launchMode
        case command
        case arguments
        case workspace
        case externalURL
        case startupTimeoutSeconds
        case appearanceMode
        case wallpaper
    }

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? version
        autoStart = try values.decodeIfPresent(Bool.self, forKey: .autoStart) ?? autoStart
        launchMode = try values.decodeIfPresent(HarnessLaunchMode.self, forKey: .launchMode) ?? launchMode
        command = try values.decodeIfPresent(String.self, forKey: .command) ?? command
        arguments = try values.decodeIfPresent([String].self, forKey: .arguments) ?? arguments
        workspace = try values.decodeIfPresent(String.self, forKey: .workspace) ?? workspace
        externalURL = try values.decodeIfPresent(String.self, forKey: .externalURL) ?? externalURL
        startupTimeoutSeconds = try values.decodeIfPresent(Int.self, forKey: .startupTimeoutSeconds)
            ?? startupTimeoutSeconds
        appearanceMode = try values.decodeIfPresent(AppearanceMode.self, forKey: .appearanceMode)
            ?? appearanceMode
        wallpaper = try values.decodeIfPresent(WallpaperSettings.self, forKey: .wallpaper) ?? wallpaper
    }

    func normalized() -> AppSettings {
        var copy = self
        if copy.version < 2,
           copy.command == "npx",
           copy.arguments.starts(with: ["--yes", "@deepseek-ai/dsh"])
        {
            copy.command = "dsh"
            copy.arguments = Array(copy.arguments.dropFirst(2))
        }
        copy.version = AppSettings.currentVersion
        copy.command = copy.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.command.isEmpty { copy.command = "dsh" }
        copy.arguments = copy.arguments.filter { !$0.isEmpty }
        if copy.command == "dsh",
           copy.arguments.first == "web",
           !copy.arguments.contains("--no-open")
        {
            copy.arguments.insert("--no-open", at: 1)
        }
        copy.workspace = copy.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.externalURL = copy.externalURL.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.startupTimeoutSeconds = min(180, max(5, copy.startupTimeoutSeconds))
        copy.wallpaper = copy.wallpaper.normalized()
        return copy
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(range.lowerBound, self))
    }
}
