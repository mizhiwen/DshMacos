import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var runtime: HarnessRuntimeController
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel) {
        self.model = model
        runtime = model.runtime
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Harness 桌面设置")
                        .font(.system(size: 20, weight: .semibold))
                    Text("设置会自动保存到应用数据目录")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(22)

            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    runtimeSection
                    workspaceSection
                    appearanceSection
                    dataSection

                    if let error = model.persistenceError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(22)
            }

            Divider()
            HStack {
                Text(runtime.isReady ? "修改运行参数后需要重启 Harness 才会生效。" : "请确认运行参数后启动 Harness。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(runtime.isReady ? "应用并重启" : "启动 Harness") {
                    dismiss()
                    if runtime.isReady { model.restart() } else { model.start() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(runtime.isBusy)
            }
            .padding(16)
        }
        .frame(width: 720, height: 700)
        .preferredColorScheme(model.settings.appearanceMode.preferredColorScheme)
    }

    private var runtimeSection: some View {
        SettingsCard(title: "运行方式", subtitle: "桌面端只允许嵌入本机回环地址。") {
            Picker("模式", selection: $model.settings.launchMode) {
                Text("由应用托管").tag(HarnessLaunchMode.managed)
                Text("连接已有实例").tag(HarnessLaunchMode.external)
            }
            .pickerStyle(.segmented)

            if model.settings.launchMode == .managed {
                SettingsField(title: "启动命令", hint: "只填写可执行文件；不会经过 Shell。") {
                    TextField("dsh", text: $model.settings.command)
                        .textFieldStyle(.roundedBorder)
                }
                SettingsField(title: "参数", hint: "每行一个参数；{port} 会替换为随机本机端口。") {
                    TextEditor(text: argumentsBinding)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 96)
                        .padding(6)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.1)))
                }
            } else {
                SettingsField(title: "本机地址", hint: "例如 http://127.0.0.1:3080") {
                    TextField("http://127.0.0.1:3080", text: $model.settings.externalURL)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Toggle("打开应用时自动启动", isOn: $model.settings.autoStart)
                Spacer()
                Stepper(
                    "超时 \(model.settings.startupTimeoutSeconds) 秒",
                    value: $model.settings.startupTimeoutSeconds,
                    in: 5 ... 180,
                    step: 5
                )
            }
            .font(.system(size: 11))
        }
    }

    private var workspaceSection: some View {
        SettingsCard(title: "工作区", subtitle: "未选择时使用应用自己的安全工作目录。") {
            HStack(spacing: 8) {
                Text(model.settings.workspace.isEmpty ? AppPaths.defaultWorkspace.path : model.settings.workspace)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                Button("选择…") { model.chooseWorkspace() }
                if !model.settings.workspace.isEmpty {
                    Button("默认") { model.settings.workspace = "" }
                }
            }
        }
    }

    private var appearanceSection: some View {
        SettingsCard(title: "外观", subtitle: "日夜模式会同时应用到原生窗口与 Harness WebView。") {
            Picker("界面模式", selection: $model.settings.appearanceMode) {
                Text("跟随系统").tag(AppearanceMode.system)
                Text("浅色").tag(AppearanceMode.light)
                Text("深色").tag(AppearanceMode.dark)
            }
            .pickerStyle(.segmented)

            HStack(alignment: .top, spacing: 16) {
                WallpaperPreview(settings: model.settings.wallpaper)
                    .frame(width: 180, height: 116)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button("选择图片…") { model.chooseWallpaper() }
                        Button("清除") { model.clearWallpaper() }
                            .disabled(model.settings.wallpaper.path.isEmpty)
                    }
                    if !model.settings.wallpaper.path.isEmpty {
                        Text(URL(fileURLWithPath: model.settings.wallpaper.path).lastPathComponent)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Picker("填充", selection: $model.settings.wallpaper.fit) {
                        Text("覆盖").tag(WallpaperFit.cover)
                        Text("适应").tag(WallpaperFit.contain)
                        Text("拉伸").tag(WallpaperFit.fill)
                    }
                    .pickerStyle(.segmented)
                }
                .frame(maxWidth: .infinity)
            }

            SliderRow(title: "壁纸强度", value: $model.settings.wallpaper.opacity, range: 0 ... 1)
            SliderRow(title: "模糊", value: $model.settings.wallpaper.blur, range: 0 ... 40, suffix: " px")
            SliderRow(title: "可读性遮罩", value: $model.settings.wallpaper.overlay, range: 0 ... 0.9)
            SliderRow(title: "水平位置", value: $model.settings.wallpaper.positionX, range: 0 ... 1)
            SliderRow(title: "垂直位置", value: $model.settings.wallpaper.positionY, range: 0 ... 1)
        }
    }

    private var dataSection: some View {
        SettingsCard(title: "本地数据", subtitle: AppPaths.root.path) {
            HStack {
                Button("在访达中显示") { model.revealDataDirectory() }
                Button("查看 Harness 日志") { model.revealLog() }
                Spacer()
                Text("凭据由 Harness 自身管理")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
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

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }
}

private struct SettingsField<Content: View>: View {
    let title: String
    let hint: String
    let content: Content

    init(title: String, hint: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .medium))
            content
            Text(hint).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var suffix = "%"

    var body: some View {
        HStack {
            Text(title).font(.system(size: 11)).frame(width: 78, alignment: .leading)
            Slider(value: $value, in: range)
            Text(displayValue)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    private var displayValue: String {
        if suffix == " px" { return "\(Int(value.rounded()))\(suffix)" }
        return "\(Int((value * 100).rounded()))\(suffix)"
    }
}

private struct WallpaperPreview: View {
    let settings: WallpaperSettings

    var body: some View {
        ZStack {
            WallpaperView(settings: settings)
            if settings.path.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "photo")
                    Text("未选择壁纸").font(.system(size: 9))
                }
                .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.12)))
    }
}
