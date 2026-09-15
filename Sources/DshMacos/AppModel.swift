import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet { persistSettings() }
    }
    @Published var isShowingSettings = false
    @Published private(set) var persistenceError: String?

    let runtime = HarnessRuntimeController()

    private let store: SettingsStore
    private var terminationObserver: NSObjectProtocol?

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        settings = store.load()
        try? AppPaths.prepare()

        let runtime = runtime
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak runtime] in
                runtime?.stopImmediately()
            }
        }

        if settings.autoStart {
            Task { [weak self] in
                guard let self else { return }
                await self.runtime.start(using: self.settings)
            }
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    func start() {
        Task { await runtime.start(using: settings) }
    }

    func stop() {
        Task { await runtime.stop() }
    }

    func restart() {
        Task { await runtime.restart(using: settings) }
    }

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "选择 Harness 工作区"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if !settings.workspace.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: settings.workspace, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            settings.workspace = url.standardizedFileURL.path
        }
    }

    func chooseWallpaper() {
        let panel = NSOpenPanel()
        panel.title = "选择 Harness 壁纸"
        panel.prompt = "使用此壁纸"
        panel.allowedContentTypes = wallpaperPickerContentTypes()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            settings.wallpaper.path = try store.importWallpaper(from: source).path
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    func clearWallpaper() {
        settings.wallpaper.path = ""
    }

    func revealDataDirectory() {
        try? AppPaths.prepare()
        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.root])
    }

    func revealLog() {
        try? AppPaths.prepare()
        if !FileManager.default.fileExists(atPath: AppPaths.harnessLog.path) {
            FileManager.default.createFile(atPath: AppPaths.harnessLog.path, contents: nil)
        }
        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.harnessLog])
    }

    private func persistSettings() {
        do {
            try store.save(settings)
            persistenceError = nil
        } catch {
            persistenceError = "设置保存失败：\(error.localizedDescription)"
        }
    }
}
