import AppKit
import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case runtime
    case appearance
    case data

    var id: String { rawValue }

    var title: String {
        switch self {
        case .runtime: return "运行"
        case .appearance: return "外观"
        case .data: return "数据"
        }
    }

    var symbol: String {
        switch self {
        case .runtime: return "play.circle"
        case .appearance: return "paintpalette"
        case .data: return "internaldrive"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var runtime: HarnessRuntimeController
    @Environment(\.dismiss) private var dismiss
    @State private var pane: SettingsPane = .runtime

    init(model: AppModel) {
        self.model = model
        runtime = model.runtime
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 176)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 800, height: 580)
        .preferredColorScheme(model.settings.appearanceMode.preferredColorScheme)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title)
                    .font(.system(size: 15, weight: .semibold))
                Text(paneSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var paneSubtitle: String {
        switch pane {
        case .runtime:
            return "只连接本机地址，启动参数改完后需要重启才会生效。"
        case .appearance:
            return "日夜模式会同时作用在窗口和页面上。"
        case .data:
            return "配置、壁纸和日志都保存在这台电脑。"
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsPane.allCases) { item in
                sidebarRow(item)
            }
            Spacer(minLength: 16)
            runtimeBadge
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func sidebarRow(_ item: SettingsPane) -> some View {
        Button {
            pane = item
        } label: {
            Label(item.title, systemImage: item.symbol)
                .font(.system(size: 13, weight: pane == item ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(pane == item ? Color.accentColor.opacity(0.16) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var runtimeBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(runtime.phase.title)
                .font(.system(size: 11, weight: .medium))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var statusColor: Color {
        switch runtime.phase {
        case .ready: return Color(red: 0.36, green: 0.74, blue: 0.48)
        case .starting, .stopping: return Color(red: 0.93, green: 0.74, blue: 0.30)
        case .failed: return Color(red: 0.90, green: 0.38, blue: 0.36)
        case .stopped: return Color.secondary.opacity(0.55)
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            if let error = model.persistenceError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                Divider()
            }

            Group {
                switch pane {
                case .runtime:
                    runtimePane
                case .appearance:
                    appearancePane
                case .data:
                    dataPane
                }
            }
            .formStyle(.grouped)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var runtimePane: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("模式", selection: $model.settings.launchMode) {
                        Text("由应用托管").tag(HarnessLaunchMode.managed)
                        Text("连接已有实例").tag(HarnessLaunchMode.external)
                    }
                    .pickerStyle(.segmented)

                    if model.settings.launchMode == .managed {
                        TextField("启动命令", text: $model.settings.command)
                        LabeledContent("参数") {
                            TextEditor(text: argumentsBinding)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minHeight: 84, maxHeight: 120)
                        }
                    } else {
                        TextField("本机地址", text: $model.settings.externalURL)
                    }
                } footer: {
                    Text(
                        model.settings.launchMode == .managed
                            ? "只填可执行文件名，不走终端。参数每行一条，{port} 会换成随机端口。"
                            : "例如 http://127.0.0.1:3080，仅限本机回环地址。"
                    )
                }

                Section {
                    LabeledContent("目录") {
                        Text(workspacePath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    HStack {
                        Button("选择…") { model.chooseWorkspace() }
                        if !model.settings.workspace.isEmpty {
                            Button("恢复默认") { model.settings.workspace = "" }
                        }
                        Spacer()
                    }
                } header: {
                    Text("工作区")
                } footer: {
                    Text("未选择时使用应用自己的安全工作目录。")
                }

                Section {
                    Toggle("打开应用时自动启动", isOn: $model.settings.autoStart)
                    Stepper(
                        value: $model.settings.startupTimeoutSeconds,
                        in: 5 ... 180,
                        step: 5
                    ) {
                        Text("等待就绪 \(model.settings.startupTimeoutSeconds) 秒")
                    }
                } header: {
                    Text("启动选项")
                }
            }

            Spacer(minLength: 0)
            runtimeFooter
        }
    }

    private var runtimeFooter: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(runtime.isReady ? "运行参数改完后，重启才会生效。" : "确认参数后即可启动。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button(runtime.isReady ? "应用并重启" : "启动 Harness") {
                if runtime.isReady { model.restart() } else { model.start() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(runtime.isBusy)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var appearancePane: some View {
        Form {
            Section {
                Picker("外观", selection: $model.settings.appearanceMode) {
                    Text("跟随系统").tag(AppearanceMode.system)
                    Text("浅色").tag(AppearanceMode.light)
                    Text("深色").tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("界面")
            }

            Section {
                WallpaperPreview(settings: $model.settings.wallpaper)
                    .frame(height: 188)
                    .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))

                HStack(spacing: 8) {
                    Button("选择壁纸…") { model.chooseWallpaper() }
                    Button("清除") { model.clearWallpaper() }
                        .disabled(model.settings.wallpaper.path.isEmpty)
                    if !model.settings.wallpaper.path.isEmpty {
                        Text(URL(fileURLWithPath: model.settings.wallpaper.path).lastPathComponent)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }

                Picker("填充", selection: $model.settings.wallpaper.fit) {
                    Text("覆盖").tag(WallpaperFit.cover)
                    Text("适应").tag(WallpaperFit.contain)
                    Text("拉伸").tag(WallpaperFit.fill)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("壁纸")
            } footer: {
                Text("支持图片、GIF 和视频（MP4 / MOV）。视频会静音循环；系统动态桌面 HEIC 会按静图显示。按住预览图可调整位置。")
            }

            Section {
                SliderRow(title: "壁纸强度", value: $model.settings.wallpaper.opacity, range: 0 ... 1)
                SliderRow(title: "模糊", value: $model.settings.wallpaper.blur, range: 0 ... 40, suffix: " px")
                SliderRow(title: "遮罩", value: $model.settings.wallpaper.overlay, range: 0 ... 0.9)
                SliderRow(title: "水平", value: $model.settings.wallpaper.positionX, range: 0 ... 1)
                SliderRow(title: "垂直", value: $model.settings.wallpaper.positionY, range: 0 ... 1)
            } header: {
                Text("画面")
            }
        }
    }

    private var dataPane: some View {
        Form {
            Section {
                pathRow(title: "数据目录", path: AppPaths.root.path) {
                    model.revealDataDirectory()
                }
            } header: {
                Text("应用数据")
            } footer: {
                Text("凭据由 Harness 自己管理，不会写进这个应用。")
            }

            Section {
                pathRow(title: "Harness 日志", path: AppPaths.harnessLog.path) {
                    model.revealLog()
                }
            } header: {
                Text("日志")
            }
        }
    }

    private func pathRow(title: String, path: String, reveal: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(title) {
                Button("在访达中显示", action: reveal)
            }
            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }

    private var workspacePath: String {
        model.settings.workspace.isEmpty ? AppPaths.defaultWorkspace.path : model.settings.workspace
    }

    private var argumentsBinding: Binding<String> {
        Binding(
            get: { model.settings.arguments.joined(separator: "\n") },
            set: { value in
                model.settings.arguments = value
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var suffix = "%"

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 64, alignment: .leading)
            Slider(value: $value, in: range)
            Text(displayValue)
                .font(.system(size: 11, design: .monospaced).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    private var displayValue: String {
        if suffix == " px" { return "\(Int(value.rounded()))\(suffix)" }
        return "\(Int((value * 100).rounded()))\(suffix)"
    }
}

private struct WallpaperPreview: View {
    @Binding var settings: WallpaperSettings

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                WallpaperView(settings: settings)

                if settings.path.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 22, weight: .light))
                        Text("还没有壁纸")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(.secondary)
                }

                VStack {
                    windowChrome
                    Spacer()
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .gesture(positionDrag(in: proxy.size))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var windowChrome: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(red: 1, green: 0.38, blue: 0.35)).frame(width: 8, height: 8)
            Circle().fill(Color(red: 1, green: 0.76, blue: 0.23)).frame(width: 8, height: 8)
            Circle().fill(Color(red: 0.30, green: 0.77, blue: 0.39)).frame(width: 8, height: 8)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func positionDrag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard !settings.path.isEmpty, size.width > 0, size.height > 0 else { return }
                settings.positionX = Double((value.location.x / size.width).clamped(to: 0 ... 1))
                settings.positionY = Double((value.location.y / size.height).clamped(to: 0 ... 1))
            }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(range.lowerBound, self))
    }
}
