import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var runtime: HarnessRuntimeController
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var canvasSize: CGSize = .zero

    init(model: AppModel) {
        self.model = model
        runtime = model.runtime
    }

    var body: some View {
        ZStack {
            WallpaperView(settings: model.settings.wallpaper)
            content
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: CanvasSizePreferenceKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(CanvasSizePreferenceKey.self) { canvasSize = $0 }
        .overlay(alignment: .top) {
            TitlebarDragRegion()
                .frame(height: 36)
                .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .topLeading) {
            ControlDockOverlay(model: model, canvasSize: canvasSize, isDarkMode: isDarkMode)
        }
        .background(HarnessStatusItemInstaller(model: model, isDarkMode: isDarkMode))
        .frame(minWidth: 920, minHeight: 640)
        .preferredColorScheme(model.settings.appearanceMode.preferredColorScheme)
        .sheet(isPresented: $model.isShowingSettings) {
            SettingsView(model: model)
        }
    }

    @ViewBuilder
    private var content: some View {
        if runtime.isReady, let url = runtime.serviceURL {
            HarnessWebView(
                url: url,
                wallpaperEnabled: !model.settings.wallpaper.path.isEmpty,
                isDarkMode: isDarkMode
            )
            .id(url)
        } else {
            launchSurface
        }
    }

    private var launchSurface: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle()
                    .fill(accentColor.opacity(isDarkMode ? 0.16 : 0.1))
                    .frame(width: 116, height: 116)
                    .blur(radius: 8)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(accentColor.gradient)
            }

            VStack(spacing: 8) {
                Text(runtime.phase == .failed ? "Harness 没有启动" : "你的本地 Harness 工作台")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(launchDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            if runtime.phase == .starting {
                ProgressView("等待本地服务就绪…")
                    .controlSize(.small)
            } else {
                HStack(spacing: 10) {
                    Button(runtime.phase == .failed ? "重新启动" : "启动 Harness") {
                        model.start()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(accentColor)

                    Button("运行设置") { model.showSettings() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }

            if runtime.phase == .failed {
                errorPanel
            }
            Spacer()
            Text("只监听本机回环地址 · 不向网页暴露原生命令桥接")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 20)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    (isDarkMode ? Color.black : Color.white).opacity(0.08),
                    accentColor.opacity(isDarkMode ? 0.035 : 0.025)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var errorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(runtime.errorMessage ?? "未知错误", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.orange)

            if !runtime.logTail.isEmpty {
                ScrollView {
                    Text(runtime.logTail.suffix(12).joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(14)
        .frame(maxWidth: 620, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.22))
        )
    }

    private var launchDescription: String {
        if let error = runtime.errorMessage { return error }
        switch model.settings.launchMode {
        case .managed:
            return "应用会在独立数据目录中启动并管理 DeepSeek Harness，然后把 Web UI 安全地嵌入这个窗口。"
        case .external:
            return "连接到已经在本机运行的 DeepSeek Harness，不接管它的进程生命周期。"
        }
    }

    private var accentColor: Color {
        isDarkMode
            ? Color(red: 0.44, green: 0.68, blue: 1.0)
            : Color(red: 0.16, green: 0.43, blue: 0.86)
    }

    private var isDarkMode: Bool {
        switch model.settings.appearanceMode {
        case .system: return systemColorScheme == .dark
        case .light: return false
        case .dark: return true
        }
    }
}

extension AppearanceMode {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
