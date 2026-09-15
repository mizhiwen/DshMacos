import AppKit
import SwiftUI
import WebKit

struct HarnessWebView: NSViewRepresentable {
    let url: URL
    let wallpaperEnabled: Bool
    let isDarkMode: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            allowedURL: url,
            appearance: WebAppearance(wallpaperEnabled: wallpaperEnabled, isDarkMode: isDarkMode)
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: appearanceJavaScript(
                    wallpaperEnabled: wallpaperEnabled,
                    isDarkMode: isDarkMode
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let webView = TransparentWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        applyNativeAppearance(to: webView, isDarkMode: isDarkMode)
        context.coordinator.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.allowedURL = url
        context.coordinator.appearance = WebAppearance(
            wallpaperEnabled: wallpaperEnabled,
            isDarkMode: isDarkMode
        )
        applyNativeAppearance(to: webView, isDarkMode: isDarkMode)
        webView.superview?.wantsLayer = true
        webView.superview?.layer?.isOpaque = false
        webView.superview?.layer?.backgroundColor = NSColor.clear.cgColor
        context.coordinator.applyAppearance()
        if webView.url?.absoluteString != url.absoluteString, !webView.isLoading {
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var allowedURL: URL
        var appearance: WebAppearance
        weak var webView: WKWebView?
        private var lastAppearance: WebAppearance?

        init(allowedURL: URL, appearance: WebAppearance) {
            self.allowedURL = allowedURL
            self.appearance = appearance
        }

        func applyAppearance() {
            guard lastAppearance != appearance else { return }
            lastAppearance = appearance
            webView?.evaluateJavaScript(
                appearanceJavaScript(
                    wallpaperEnabled: appearance.wallpaperEnabled,
                    isDarkMode: appearance.isDarkMode
                )
            )
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            lastAppearance = nil
            applyAppearance()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let target = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if target.absoluteString == "about:blank" || isSameOrigin(target, allowedURL) {
                decisionHandler(.allow)
                return
            }
            if ["http", "https"].contains(target.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(target)
            }
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let target = navigationAction.request.url { NSWorkspace.shared.open(target) }
            return nil
        }

        private func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
            lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
                && lhs.host?.lowercased() == rhs.host?.lowercased()
                && effectivePort(lhs) == effectivePort(rhs)
        }

        private func effectivePort(_ url: URL) -> Int? {
            if let port = url.port { return port }
            switch url.scheme?.lowercased() {
            case "http": return 80
            case "https": return 443
            default: return nil
            }
        }
    }
}

final class TransparentWebView: WKWebView {
    override var isOpaque: Bool { false }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        superview?.wantsLayer = true
        superview?.layer?.isOpaque = false
        superview?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let band = NSRect(
            x: bounds.minX,
            y: isFlipped ? bounds.minY : bounds.maxY - TitlebarHitMetrics.height,
            width: bounds.width,
            height: TitlebarHitMetrics.height
        )
        if band.contains(point) {
            return nil
        }
        return super.hitTest(point)
    }
}

struct WebAppearance: Equatable {
    let wallpaperEnabled: Bool
    let isDarkMode: Bool
}

private func applyNativeAppearance(to webView: WKWebView, isDarkMode: Bool) {
    webView.appearance = NSAppearance(named: isDarkMode ? .darkAqua : .aqua)
    webView.setValue(false, forKey: "drawsBackground")
    webView.underPageBackgroundColor = .clear
    webView.wantsLayer = true
    webView.layer?.isOpaque = false
    webView.layer?.backgroundColor = NSColor.clear.cgColor
}

func appearanceCSS(wallpaperEnabled: Bool, isDarkMode: Bool) -> String {
    let scheme = isDarkMode ? "dark" : "light"
    let sidebarWash = isDarkMode
        ? "linear-gradient(90deg, rgba(8,13,21,.50) 0%, rgba(8,13,21,.16) 62%, rgba(8,13,21,0) 100%)"
        : "linear-gradient(90deg, rgba(255,255,255,.40) 0%, rgba(255,255,255,.12) 62%, rgba(255,255,255,0) 100%)"
    let elevated = isDarkMode ? "rgba(13, 20, 31, .58)" : "rgba(255, 255, 255, .72)"
    let floating = isDarkMode ? "rgba(13, 20, 31, .7)" : "rgba(255, 255, 255, .82)"
    // Harness writes theme tokens on `body` / `body[data-ds-dark-theme]`.
    // A :root override is inherited only until body specifies its own value.
    // Sidebar paints the token twice (column + inner root); keep the token
    // transparent and wash only the column so the wallpaper can bleed in.
    let wallpaperCSS = wallpaperEnabled ? """
        html, body, :root, body[data-ds-dark-theme] {
          --dsw-alias-bg-base: transparent !important;
          --dsw-specific-bg-base: transparent !important;
          --dsw-alias-bg-container: transparent !important;
          --dsw-alias-bg-elevated: \(elevated) !important;
          --dsw-alias-bg-float: \(floating) !important;
          --dsw-specific-sidebar-fill: transparent !important;
          --dsw-specific-input-major: \(floating) !important;
        }
        html, body, #root { background: transparent !important; }
        [class*="sidebarCol"] > * { background: transparent !important; }
        [class*="sidebarCol"] { background: \(sidebarWash) !important; }
        [class*="centerCol"] { background: transparent !important; }
        """ : ""
    let schemeCSS = wallpaperEnabled
        ? "button, input, textarea { color-scheme: \(scheme); }"
        : ":root { color-scheme: \(scheme) !important; }"
    return """
        \(schemeCSS)
        html {
          -webkit-font-smoothing: antialiased;
          text-rendering: optimizeLegibility;
        }
        button, input, textarea { -webkit-font-smoothing: antialiased; }
        \(wallpaperCSS)
        """
}

private func appearanceJavaScript(wallpaperEnabled: Bool, isDarkMode: Bool) -> String {
    let literal = String(
        data: try! JSONEncoder().encode(appearanceCSS(
            wallpaperEnabled: wallpaperEnabled,
            isDarkMode: isDarkMode
        )),
        encoding: .utf8
    )!
    return """
        (() => {
          const id = 'dsh-macos-appearance';
          let style = document.getElementById(id);
          if (!style) {
            style = document.createElement('style');
            style.id = id;
            (document.head || document.documentElement).appendChild(style);
          }
          style.textContent = \(literal);
          if (\(wallpaperEnabled ? "true" : "false")) {
            document.querySelectorAll('meta[name="color-scheme"]').forEach((node) => node.remove());
            const root = document.documentElement;
            root.style.setProperty('background', 'transparent', 'important');
            root.style.setProperty('background-color', 'transparent', 'important');
            if (document.body) {
              document.body.style.setProperty('background', 'transparent', 'important');
              document.body.style.setProperty('background-color', 'transparent', 'important');
              document.body.style.setProperty('--dsw-alias-bg-base', 'transparent', 'important');
              document.body.style.setProperty('--dsw-specific-sidebar-fill', 'transparent', 'important');
            }
          }
        })();
        """
}
