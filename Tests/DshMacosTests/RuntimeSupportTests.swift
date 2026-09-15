import AVFoundation
import AppKit
import XCTest
@testable import DshMacos

final class RuntimeSupportTests: XCTestCase {
    func testRestoredWindowFrameKeepsSavedSizeAndConstrainsPosition() throws {
        let screen = NSRect(x: 0, y: 25, width: 1440, height: 875)
        let restored = try XCTUnwrap(restoredWindowFrame(
            from: "{{1300, -200}, {1100, 720}}",
            visibleFrames: [screen],
            minimumSize: NSSize(width: 920, height: 640)
        ))

        XCTAssertEqual(restored.size, NSSize(width: 1100, height: 720))
        XCTAssertEqual(restored.origin.x, 340)
        XCTAssertEqual(restored.origin.y, 25)
    }

    func testRestoredWindowFrameRejectsInvalidValue() {
        XCTAssertNil(restoredWindowFrame(
            from: "not-a-frame",
            visibleFrames: [NSRect(x: 0, y: 0, width: 1440, height: 900)],
            minimumSize: NSSize(width: 920, height: 640)
        ))
    }

    func testNodeVersionParsesAndComparesSemanticVersions() throws {
        let current = try XCTUnwrap(NodeVersion("v22.23.1"))
        let older = try XCTUnwrap(NodeVersion("20.12.0"))

        XCTAssertEqual(current.description, "v22.23.1")
        XCTAssertGreaterThan(current, older)
        XCTAssertTrue(current.supportsParseEnv)
        XCTAssertTrue(older.supportsParseEnv)
        XCTAssertFalse(try XCTUnwrap(NodeVersion("v18.20.4")).supportsParseEnv)
    }

    func testUserNodeDirectoriesComeBeforeSystemDirectories() throws {
        let home = URL(fileURLWithPath: "/tmp/dsh-home", isDirectory: true)
        let directories = executableSearchDirectories(
            environment: ["PATH": "/usr/local/bin:/usr/bin"],
            home: home
        )

        XCTAssertEqual(directories.first?.path, "/tmp/dsh-home/.local/bin")
        XCTAssertLessThan(
            try XCTUnwrap(directories.firstIndex { $0.path == "/tmp/dsh-home/.local/bin" }),
            try XCTUnwrap(directories.firstIndex { $0.path == "/usr/local/bin" })
        )
    }

    func testLoopbackURLAcceptsLocalHosts() throws {
        XCTAssertEqual(try normalizedLoopbackURL("http://127.0.0.1:3080").host, "127.0.0.1")
        XCTAssertEqual(try normalizedLoopbackURL("http://localhost:9000/path").host, "localhost")
        XCTAssertEqual(try normalizedLoopbackURL("http://[::1]:8080").host, "::1")
    }

    func testLoopbackURLRejectsRemoteAndNonHTTPURLs() {
        XCTAssertThrowsError(try normalizedLoopbackURL("https://example.com"))
        XCTAssertThrowsError(try normalizedLoopbackURL("file:///tmp/index.html"))
    }

    func testPortTemplateIsMaterializedWithoutShellParsing() {
        XCTAssertEqual(
            materializedArguments(["web", "--port", "{port}", "prefix-{port}"], port: 43123),
            ["web", "--port", "43123", "prefix-43123"]
        )
    }

    func testRelativeExecutableNameSearchesConfiguredDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("npx")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        XCTAssertEqual(
            try resolvedExecutableURL(
                command: "npx",
                searchDirectories: [root],
                cachedDshExecutables: []
            ),
            executable
        )
    }

    func testLegacyNpxSettingsMigrateToLocalDshCommand() {
        var settings = AppSettings()
        settings.version = 1
        settings.command = "npx"
        settings.arguments = ["--yes", "@deepseek-ai/dsh", "web", "--port", "{port}"]

        let migrated = settings.normalized()
        XCTAssertEqual(migrated.version, AppSettings.currentVersion)
        XCTAssertEqual(migrated.command, "dsh")
        XCTAssertEqual(migrated.arguments, ["web", "--no-open", "--port", "{port}"])
    }

    func testLegacySettingsDecodeWithSystemAppearance() throws {
        let data = Data(#"{"version":2,"command":"dsh","arguments":["web"]}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data).normalized()

        XCTAssertEqual(decoded.appearanceMode, .system)
        XCTAssertEqual(decoded.arguments, ["web", "--no-open"])
        XCTAssertEqual(decoded.controlDock.edge, .trailing)
    }

    func testDshFallsBackToCachedExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("dsh")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        XCTAssertEqual(
            try resolvedExecutableURL(
                command: "dsh",
                searchDirectories: [],
                cachedDshExecutables: [executable]
            ),
            executable
        )
    }

    func testSettingsNormalizationClampsAppearanceAndTimeout() {
        var settings = AppSettings()
        settings.command = "   "
        settings.startupTimeoutSeconds = 999
        settings.wallpaper.opacity = 4
        settings.wallpaper.blur = -5
        settings.wallpaper.overlay = 2

        let normalized = settings.normalized()
        XCTAssertEqual(normalized.command, "dsh")
        XCTAssertEqual(normalized.startupTimeoutSeconds, 180)
        XCTAssertEqual(normalized.wallpaper.opacity, 1)
        XCTAssertEqual(normalized.wallpaper.blur, 0)
        XCTAssertEqual(normalized.wallpaper.overlay, 0.9)
    }

    func testLegacySettingsDefaultToTrailingControlDock() throws {
        let data = Data(#"{"version":2,"command":"dsh","arguments":["web"]}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data).normalized()
        XCTAssertEqual(decoded.controlDock.edge, .trailing)
        XCTAssertEqual(decoded.controlDock.offset, 0.16)
    }

    func testControlDockSnapsToNearestEdge() {
        let canvas = CGSize(width: 1000, height: 800)
        let pill = CGSize(width: 36, height: 36)

        XCTAssertEqual(
            snappedControlDock(center: CGPoint(x: 500, y: 20), canvas: canvas, pill: pill).edge,
            .top
        )
        XCTAssertEqual(
            snappedControlDock(center: CGPoint(x: 500, y: 780), canvas: canvas, pill: pill).edge,
            .bottom
        )
        XCTAssertEqual(
            snappedControlDock(center: CGPoint(x: 12, y: 400), canvas: canvas, pill: pill).edge,
            .leading
        )
        XCTAssertEqual(
            snappedControlDock(center: CGPoint(x: 988, y: 400), canvas: canvas, pill: pill).edge,
            .trailing
        )
    }

    func testTitlebarDoubleClickFollowsSystemPreference() {
        XCTAssertEqual(titlebarDoubleClickAction(for: nil), .fill)
        XCTAssertEqual(titlebarDoubleClickAction(for: "Fill"), .fill)
        XCTAssertEqual(titlebarDoubleClickAction(for: "Maximize"), .zoom)
        XCTAssertEqual(titlebarDoubleClickAction(for: "Minimize"), .miniaturize)
        XCTAssertEqual(titlebarDoubleClickAction(for: "None"), .none)
    }

    func testTitlebarFillUsesVisibleFrameAndDetectsAlreadyFilled() {
        let visible = NSRect(x: 0, y: 25, width: 1440, height: 875)
        XCTAssertEqual(titlebarFilledFrame(for: visible), visible)
        XCTAssertTrue(framesApproximatelyEqual(visible, NSRect(x: 1, y: 25, width: 1440, height: 875)))
        XCTAssertFalse(framesApproximatelyEqual(visible, NSRect(x: 120, y: 80, width: 1100, height: 720)))
    }

    func testTitlebarHitRectSkipsTrafficLightsAndStaysAtTop() {
        let bounds = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let unflipped = titlebarHitRect(in: bounds, flipped: false)
        XCTAssertEqual(unflipped, NSRect(x: 86, y: 764, width: 914, height: 36))
        XCTAssertTrue(shouldHandleTitlebarClick(point: NSPoint(x: 500, y: 790), in: bounds, flipped: false))
        XCTAssertFalse(shouldHandleTitlebarClick(point: NSPoint(x: 40, y: 790), in: bounds, flipped: false))
        XCTAssertFalse(shouldHandleTitlebarClick(point: NSPoint(x: 500, y: 400), in: bounds, flipped: false))

        let flipped = titlebarHitRect(in: bounds, flipped: true)
        XCTAssertEqual(flipped.origin, NSPoint(x: 86, y: 0))
        XCTAssertTrue(shouldHandleTitlebarClick(point: NSPoint(x: 500, y: 10), in: bounds, flipped: true))
        XCTAssertFalse(shouldHandleTitlebarClick(point: NSPoint(x: 500, y: 80), in: bounds, flipped: true))
    }

    func testControlDockOriginHugsTrailingEdge() {
        let origin = controlDockOrigin(
            settings: ControlDockSettings(edge: .trailing, offset: 0.5),
            canvas: CGSize(width: 1000, height: 800),
            pill: CGSize(width: 36, height: 36)
        )
        XCTAssertEqual(origin.x, 1000 - 36 - ControlDockMetrics.edgeInset)
        XCTAssertGreaterThan(origin.y, ControlDockMetrics.topSafeInset - 0.5)
    }

    func testControlDockUsesCompactHitSize() {
        XCTAssertEqual(controlDockHitSize(edge: .trailing), ControlDockMetrics.size)
        XCTAssertEqual(controlDockHitSize(edge: .top), ControlDockMetrics.size)
        XCTAssertEqual(controlDockVisualSize(edge: .leading, emphasized: false), ControlDockMetrics.size)
        XCTAssertEqual(controlDockVisualSize(edge: .bottom, emphasized: true), ControlDockMetrics.size)
    }

    func testHarnessStatusSymbolMatchesPhase() {
        XCTAssertEqual(harnessStatusSymbolName(for: .ready), "circle.fill")
        XCTAssertEqual(harnessStatusSymbolName(for: .stopped), "circle")
        XCTAssertEqual(harnessStatusSymbolName(for: .failed), "exclamationmark.circle")
        XCTAssertEqual(harnessStatusSymbolName(for: .starting), "ellipsis.circle")
    }

    func testWallpaperFilePolicyAcceptsStillAndMotion() {
        XCTAssertEqual(wallpaperFilePolicy(pathExtension: "png")?.kind, .image)
        XCTAssertEqual(wallpaperFilePolicy(pathExtension: "HEIC")?.kind, .image)
        XCTAssertEqual(wallpaperFilePolicy(pathExtension: "gif")?.kind, .animatedImage)
        XCTAssertEqual(wallpaperFilePolicy(pathExtension: "mp4")?.kind, .video)
        XCTAssertEqual(wallpaperFilePolicy(pathExtension: "MOV")?.kind, .video)
        XCTAssertNil(wallpaperFilePolicy(pathExtension: "txt"))
        XCTAssertEqual(wallpaperMediaKind(forPath: "/tmp/loop.m4v"), .video)
        XCTAssertEqual(wallpaperMediaKind(forPath: ""), .none)
        XCTAssertEqual(wallpaperVideoGravity(for: .cover), .resizeAspectFill)
        XCTAssertEqual(wallpaperVideoGravity(for: .contain), .resizeAspect)
    }

    func testWallpaperCSSOverridesBodyThemeTokens() {
        let enabled = appearanceCSS(wallpaperEnabled: true, isDarkMode: false)
        XCTAssertTrue(enabled.contains("body[data-ds-dark-theme]"))
        XCTAssertTrue(enabled.contains("--dsw-alias-bg-base: transparent !important"))
        XCTAssertTrue(enabled.contains("--dsw-specific-sidebar-fill: transparent !important"))
        XCTAssertTrue(enabled.contains("[class*=\"sidebarCol\"]"))
        XCTAssertTrue(enabled.contains("linear-gradient"))
        XCTAssertTrue(enabled.contains("html, body, #root { background: transparent !important; }"))

        XCTAssertFalse(enabled.contains(":root { color-scheme:"))

        let disabled = appearanceCSS(wallpaperEnabled: false, isDarkMode: false)
        XCTAssertFalse(disabled.contains("--dsw-alias-bg-base"))
        XCTAssertFalse(disabled.contains("body[data-ds-dark-theme]"))
        XCTAssertTrue(disabled.contains(":root { color-scheme:"))
    }

    func testSettingsStoreRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let store = SettingsStore(settingsURL: url)
        var settings = AppSettings()
        settings.externalURL = "http://127.0.0.1:7777"
        settings.wallpaper.opacity = 0.55

        try store.save(settings)
        XCTAssertEqual(store.load(), settings)
    }
}
