import XCTest
import AppKit
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
