import AppKit
import SwiftUI

enum TitlebarHitMetrics {
    static let height: CGFloat = 36
    static let leadingReserve: CGFloat = 86
}

enum TitlebarDoubleClickAction: Equatable {
    case fill
    case zoom
    case fullScreen
    case miniaturize
    case none
}

func titlebarDoubleClickAction(for preference: String?) -> TitlebarDoubleClickAction {
    switch preference {
    case "Minimize":
        return .miniaturize
    case "None":
        return .none
    case "Maximize":
        return .zoom
    case "Fill":
        return .fill
    default:
        return .fill
    }
}

func titlebarHitRect(in bounds: NSRect, flipped: Bool) -> NSRect {
    NSRect(
        x: bounds.minX + TitlebarHitMetrics.leadingReserve,
        y: flipped ? bounds.minY : bounds.maxY - TitlebarHitMetrics.height,
        width: max(bounds.width - TitlebarHitMetrics.leadingReserve, 0),
        height: TitlebarHitMetrics.height
    )
}

func shouldHandleTitlebarClick(point: NSPoint, in bounds: NSRect, flipped: Bool) -> Bool {
    titlebarHitRect(in: bounds, flipped: flipped).contains(point)
}

func shouldHandleTitlebarClick(_ event: NSEvent, in window: NSWindow) -> Bool {
    guard let content = window.contentView else { return false }
    let point = content.convert(event.locationInWindow, from: nil)
    return shouldHandleTitlebarClick(point: point, in: content.bounds, flipped: content.isFlipped)
}

func performTitlebarDoubleClick(on window: NSWindow) {
    let action = titlebarDoubleClickAction(
        for: UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
    )
    window.collectionBehavior.insert(.fullScreenPrimary)
    window.collectionBehavior.remove(.fullScreenNone)
    window.collectionBehavior.remove(.fullScreenAuxiliary)

    DispatchQueue.main.async { [weak window] in
        guard let window else { return }
        switch action {
        case .miniaturize:
            window.miniaturize(nil)
        case .none:
            break
        case .zoom:
            window.zoom(nil)
        case .fill:
            performTitlebarFill(on: window)
        case .fullScreen:
            window.toggleFullScreen(nil)
        }
    }
}

private var titlebarFillRestoreFrames: [ObjectIdentifier: NSRect] = [:]

func titlebarFilledFrame(for visibleFrame: NSRect) -> NSRect {
    visibleFrame
}

func framesApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect, tolerance: CGFloat = 2) -> Bool {
    abs(lhs.minX - rhs.minX) <= tolerance
        && abs(lhs.minY - rhs.minY) <= tolerance
        && abs(lhs.width - rhs.width) <= tolerance
        && abs(lhs.height - rhs.height) <= tolerance
}

func performTitlebarFill(on window: NSWindow) {
    guard let screen = window.screen ?? NSScreen.main else { return }
    let target = titlebarFilledFrame(for: screen.visibleFrame)
    let identity = ObjectIdentifier(window)
    if framesApproximatelyEqual(window.frame, target) {
        if let saved = titlebarFillRestoreFrames.removeValue(forKey: identity) {
            window.setFrame(saved, display: true, animate: true)
        } else {
            window.zoom(nil)
        }
        return
    }
    titlebarFillRestoreFrames[identity] = window.frame
    window.setFrame(target, display: true, animate: true)
}

enum TitlebarHitInstaller {
    static let identifier = NSUserInterfaceItemIdentifier("com.local.dshmacos.titlebar-hit")

    static func install(on window: NSWindow) {
        guard let content = window.contentView else { return }
        let hit = content.subviews.compactMap { $0 as? TitlebarHitView }.first
            ?? TitlebarHitView()
        hit.identifier = identifier
        hit.autoresizingMask = [.width, .minYMargin]
        layout(hit, in: content)
        if hit.superview !== content || content.subviews.last !== hit {
            content.addSubview(hit, positioned: .above, relativeTo: nil)
        }
    }

    static func layout(_ hit: NSView, in content: NSView) {
        hit.frame = titlebarHitRect(in: content.bounds, flipped: content.isFlipped)
        if content.isFlipped {
            hit.autoresizingMask = [.width, .maxYMargin]
        } else {
            hit.autoresizingMask = [.width, .minYMargin]
        }
    }
}

final class TitlebarClickMonitor {
    private var monitor: Any?

    deinit {
        stop()
    }

    func install(on window: NSWindow) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak window] event in
            guard let window, event.window === window else { return event }
            guard shouldHandleTitlebarClick(event, in: window) else { return event }
            if event.clickCount >= 2 {
                performTitlebarDoubleClick(on: window)
                return nil
            }
            window.performDrag(with: event)
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

struct TitlebarDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> TitlebarHitView {
        TitlebarHitView()
    }

    func updateNSView(_ nsView: TitlebarHitView, context: Context) {}
}

final class TitlebarHitView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount >= 2 {
            performTitlebarDoubleClick(on: window)
            return
        }
        window.performDrag(with: event)
    }
}
