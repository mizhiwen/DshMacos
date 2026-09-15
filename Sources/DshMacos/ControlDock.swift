import AppKit
import SwiftUI

enum ControlDockMetrics {
    static let edgeInset: CGFloat = 10
    static let topSafeInset = TitlebarHitMetrics.height
    static let leadingSafeWhenTop = TitlebarHitMetrics.leadingReserve
    static let size = CGSize(width: 28, height: 28)
}

struct CanvasSizePreferenceKey: PreferenceKey {
    static var defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}

func controlDockHitSize(edge: ControlDockEdge) -> CGSize {
    ControlDockMetrics.size
}

func controlDockVisualSize(edge: ControlDockEdge, emphasized: Bool) -> CGSize {
    ControlDockMetrics.size
}

func controlDockOrigin(
    settings: ControlDockSettings,
    canvas: CGSize,
    pill: CGSize
) -> CGPoint {
    let inset = ControlDockMetrics.edgeInset
    let offset = CGFloat(settings.offset.clamped(to: 0 ... 1))
    switch settings.edge {
    case .top:
        let minX = ControlDockMetrics.leadingSafeWhenTop
        let travel = canvas.width - pill.width - minX - inset
        return CGPoint(
            x: minX + max(travel, 0) * offset,
            y: ControlDockMetrics.topSafeInset
        )
    case .bottom:
        let travel = canvas.width - pill.width - inset * 2
        return CGPoint(
            x: inset + max(travel, 0) * offset,
            y: max(canvas.height - pill.height - inset, 0)
        )
    case .leading:
        let minY = ControlDockMetrics.topSafeInset
        let travel = canvas.height - pill.height - minY - inset
        return CGPoint(
            x: inset,
            y: minY + max(travel, 0) * offset
        )
    case .trailing:
        let minY = ControlDockMetrics.topSafeInset
        let travel = canvas.height - pill.height - minY - inset
        return CGPoint(
            x: max(canvas.width - pill.width - inset, 0),
            y: minY + max(travel, 0) * offset
        )
    }
}

func snappedControlDock(
    center: CGPoint,
    canvas: CGSize,
    pill: CGSize
) -> ControlDockSettings {
    let inset = ControlDockMetrics.edgeInset
    let distances: [(ControlDockEdge, CGFloat)] = [
        (.top, center.y),
        (.bottom, canvas.height - center.y),
        (.leading, center.x),
        (.trailing, canvas.width - center.x)
    ]
    let edge = distances.min { $0.1 < $1.1 }?.0 ?? .trailing

    switch edge {
    case .top:
        let minX = ControlDockMetrics.leadingSafeWhenTop
        let travel = max(canvas.width - pill.width - minX - inset, 1)
        let originX = center.x - pill.width / 2
        return ControlDockSettings(
            edge: .top,
            offset: Double((originX - minX) / travel).clamped(to: 0 ... 1)
        )
    case .bottom:
        let travel = max(canvas.width - pill.width - inset * 2, 1)
        let originX = center.x - pill.width / 2
        return ControlDockSettings(
            edge: .bottom,
            offset: Double((originX - inset) / travel).clamped(to: 0 ... 1)
        )
    case .leading, .trailing:
        let minY = ControlDockMetrics.topSafeInset
        let travel = max(canvas.height - pill.height - minY - inset, 1)
        let originY = center.y - pill.height / 2
        return ControlDockSettings(
            edge: edge,
            offset: Double((originY - minY) / travel).clamped(to: 0 ... 1)
        )
    }
}

@MainActor
func makeHarnessControlMenu(
    model: AppModel,
    isDarkMode: Bool,
    storing actions: inout [ControlDockMenuAction]
) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    actions.removeAll()

    func addItem(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        let holder = ControlDockMenuAction(action)
        actions.append(holder)
        let item = NSMenuItem(title: title, action: #selector(ControlDockMenuAction.invoke), keyEquivalent: "")
        item.target = holder
        item.isEnabled = enabled
        menu.addItem(item)
    }

    let status = NSMenuItem(title: model.runtime.phase.title, action: nil, keyEquivalent: "")
    status.isEnabled = false
    menu.addItem(status)
    menu.addItem(.separator())

    if model.runtime.isReady {
        addItem("重新启动") { model.restart() }
        addItem("停止") { model.stop() }
    } else {
        addItem(model.runtime.phase == .failed ? "重试" : "启动", enabled: !model.runtime.isBusy) {
            model.start()
        }
    }
    menu.addItem(.separator())
    addItem(isDarkMode ? "切换到浅色" : "切换到深色") {
        model.settings.appearanceMode = isDarkMode ? .light : .dark
    }
    addItem("设置…") { model.showSettings() }
    return menu
}

func harnessStatusSymbolName(for phase: HarnessPhase) -> String {
    switch phase {
    case .ready:
        return "circle.fill"
    case .starting, .stopping:
        return "ellipsis.circle"
    case .failed:
        return "exclamationmark.circle"
    case .stopped:
        return "circle"
    }
}

struct ControlDockOverlay: View {
    @ObservedObject var model: AppModel
    let canvasSize: CGSize
    let isDarkMode: Bool

    @State private var isDragging = false
    @State private var didDrag = false
    @State private var isHovering = false
    @State private var dragTranslation: CGSize = .zero
    @State private var menuActions: [ControlDockMenuAction] = []

    init(model: AppModel, canvasSize: CGSize, isDarkMode: Bool) {
        self.model = model
        self.canvasSize = canvasSize
        self.isDarkMode = isDarkMode
    }

    var body: some View {
        grip
            .frame(width: layoutSize.width, height: layoutSize.height)
            .contentShape(Rectangle())
            .offset(x: origin.x + dragTranslation.width, y: origin.y + dragTranslation.height)
            .animation(.spring(response: 0.32, dampingFraction: 0.88), value: model.settings.controlDock)
            .onHover { isHovering = $0 }
            .help("点击打开控制菜单，按住拖到窗口边缘")
            .opacity(canvasSize.width > 0 ? 1 : 0)
            .onTapGesture {
                guard !didDrag else { return }
                popControlMenu()
            }
            .gesture(dragGesture)
    }

    private var settledEdge: ControlDockEdge {
        model.settings.controlDock.edge
    }

    private var displayedEdge: ControlDockEdge {
        guard isDragging, canvasSize.width > 0 else { return settledEdge }
        return snappedControlDock(
            center: CGPoint(
                x: origin.x + dragTranslation.width + layoutSize.width / 2,
                y: origin.y + dragTranslation.height + layoutSize.height / 2
            ),
            canvas: canvasSize,
            pill: layoutSize
        ).edge
    }

    private var layoutSize: CGSize {
        controlDockHitSize(edge: settledEdge)
    }

    private var origin: CGPoint {
        controlDockOrigin(
            settings: model.settings.controlDock,
            canvas: canvasSize,
            pill: layoutSize
        )
    }

    private var isVertical: Bool {
        switch displayedEdge {
        case .leading, .trailing:
            return true
        case .top, .bottom:
            return false
        }
    }

    private var grip: some View {
        let dots = HStack(spacing: 3.5) {
            ForEach(0 ..< 3, id: \.self) { _ in
                Circle()
                    .fill(Color.primary)
                    .frame(width: 2.5, height: 2.5)
            }
        }

        return dots
            .rotationEffect(.degrees(isVertical ? 90 : 0))
            .opacity(gripOpacity)
            .animation(.easeOut(duration: 0.16), value: isHovering || isDragging)
            .animation(.easeOut(duration: 0.16), value: displayedEdge)
    }

    private var gripOpacity: Double {
        if isDragging { return 0.62 }
        if isHovering { return 0.48 }
        return 0
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                didDrag = true
                isDragging = true
                dragTranslation = value.translation
            }
            .onEnded { value in
                let center = CGPoint(
                    x: origin.x + value.translation.width + layoutSize.width / 2,
                    y: origin.y + value.translation.height + layoutSize.height / 2
                )
                model.settings.controlDock = snappedControlDock(
                    center: center,
                    canvas: canvasSize,
                    pill: layoutSize
                )
                dragTranslation = .zero
                isDragging = false
                DispatchQueue.main.async {
                    didDrag = false
                }
            }
    }

    private func popControlMenu() {
        var actions: [ControlDockMenuAction] = []
        let menu = makeHarnessControlMenu(model: model, isDarkMode: isDarkMode, storing: &actions)
        menuActions = actions
        if let event = NSApp.currentEvent, let view = NSApp.keyWindow?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

struct HarnessStatusItemInstaller: NSViewRepresentable {
    @ObservedObject var model: AppModel
    var isDarkMode: Bool

    func makeCoordinator() -> HarnessStatusItemController {
        HarnessStatusItemController()
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.refresh(model: model, isDarkMode: isDarkMode)
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.refresh(model: model, isDarkMode: isDarkMode)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: HarnessStatusItemController) {
        coordinator.tearDown()
    }
}

@MainActor
final class HarnessStatusItemController {
    private var item: NSStatusItem?
    private var menuActions: [ControlDockMenuAction] = []
    private var lastSignature: String?

    func refresh(model: AppModel, isDarkMode: Bool) {
        let signature = [
            model.runtime.phase.rawValue,
            isDarkMode ? "dark" : "light",
            model.runtime.isBusy ? "busy" : "idle",
            model.runtime.isReady ? "ready" : "off"
        ].joined(separator: "|")
        if lastSignature == signature, item != nil {
            return
        }
        lastSignature = signature

        if item == nil {
            let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            created.button?.imagePosition = .imageOnly
            item = created
        }

        guard let button = item?.button else { return }
        let symbol = harnessStatusSymbolName(for: model.runtime.phase)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "DeepSeek Harness")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "DeepSeek Harness · \(model.runtime.phase.title)"

        var actions: [ControlDockMenuAction] = []
        item?.menu = makeHarnessControlMenu(model: model, isDarkMode: isDarkMode, storing: &actions)
        menuActions = actions
    }

    func tearDown() {
        if let item {
            NSStatusBar.system.removeStatusItem(item)
        }
        item = nil
        lastSignature = nil
        menuActions = []
    }
}

final class ControlDockMenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func invoke() {
        handler()
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(range.lowerBound, self))
    }
}
