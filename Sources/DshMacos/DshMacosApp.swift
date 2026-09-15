import AppKit
import SwiftUI

@main
struct DshMacosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("DeepSeek Harness") {
            ContentView(model: model)
                .background(WindowChromeConfigurator(appDelegate: appDelegate))
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Harness 设置…") {
                    model.isShowingSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Harness") {
                Button("启动") { model.start() }
                    .disabled(model.runtime.isBusy || model.runtime.isReady)
                Button("重新启动") { model.restart() }
                    .disabled(model.runtime.isBusy)
                Button("停止") { model.stop() }
                    .disabled(model.runtime.isBusy || !model.runtime.isReady)
                Divider()
                Button("显示日志") { model.revealLog() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Keep the closed SwiftUI window alive so LaunchServices can show the same
    // window (and WebView session) again instead of requiring a process restart.
    var mainWindow: NSWindow?

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showMainWindow(in: sender)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let application = notification.object as? NSApplication,
              mainWindow != nil,
              mainWindow?.isVisible == false else { return }
        showMainWindow(in: application)
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        showMainWindow(in: sender)
        return true
    }

    private func showMainWindow(in application: NSApplication) {
        let window = mainWindow ?? application.windows.first(where: {
            $0.identifier?.rawValue == WindowChromeConfigurator.windowIdentifier
                || $0.title == "DeepSeek Harness"
        })
        guard let window else { return }

        mainWindow = window
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
    }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    let appDelegate: AppDelegate

    static let windowIdentifier = "com.local.dshmacos.main-window"
    private static let frameDefaultsKey = "mainWindowFrame.v1"
    private static let minimumFrameSize = NSSize(width: 920, height: 640)

    final class Coordinator {
        weak var configuredWindow: NSWindow?
        var observers: [NSObjectProtocol] = []

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWindow(for: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWindow(for: nsView, coordinator: context.coordinator)
    }

    private func configureWindow(for view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none

            guard coordinator.configuredWindow !== window else { return }
            coordinator.configuredWindow = window
            window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
            window.isReleasedWhenClosed = false

            Self.restoreFrame(of: window)
            Self.observeFrameChanges(of: window, coordinator: coordinator)

            appDelegate.mainWindow = window
        }
    }

    private static func observeFrameChanges(of window: NSWindow, coordinator: Coordinator) {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.willCloseNotification
        ]
        coordinator.observers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                guard let window else { return }
                UserDefaults.standard.set(
                    NSStringFromRect(window.frame),
                    forKey: Self.frameDefaultsKey
                )
            }
        }
    }

    private static func restoreFrame(of window: NSWindow) {
        guard let rawValue = UserDefaults.standard.string(forKey: frameDefaultsKey),
              let frame = restoredWindowFrame(
                  from: rawValue,
                  visibleFrames: NSScreen.screens.map(\.visibleFrame),
                  minimumSize: minimumFrameSize
              ) else { return }
        window.setFrame(frame, display: false)
    }
}

func restoredWindowFrame(
    from rawValue: String,
    visibleFrames: [NSRect],
    minimumSize: NSSize
) -> NSRect? {
    var frame = NSRectFromString(rawValue)
    guard frame.origin.x.isFinite,
          frame.origin.y.isFinite,
          frame.width.isFinite,
          frame.height.isFinite,
          frame.width > 0,
          frame.height > 0 else { return nil }

    guard let visibleFrame = visibleFrames.max(by: {
        NSIntersectionRect($0, frame).width * NSIntersectionRect($0, frame).height
            < NSIntersectionRect($1, frame).width * NSIntersectionRect($1, frame).height
    }) else {
        frame.size.width = max(frame.width, minimumSize.width)
        frame.size.height = max(frame.height, minimumSize.height)
        return frame
    }

    frame.size.width = min(max(frame.width, minimumSize.width), visibleFrame.width)
    frame.size.height = min(max(frame.height, minimumSize.height), visibleFrame.height)
    frame.origin.x = min(
        max(frame.origin.x, visibleFrame.minX),
        visibleFrame.maxX - frame.width
    )
    frame.origin.y = min(
        max(frame.origin.y, visibleFrame.minY),
        visibleFrame.maxY - frame.height
    )
    return frame
}
