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

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
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

struct WebAppearance: Equatable {
    let wallpaperEnabled: Bool
    let isDarkMode: Bool
}

private func applyNativeAppearance(to webView: WKWebView, isDarkMode: Bool) {
    webView.appearance = NSAppearance(named: isDarkMode ? .darkAqua : .aqua)
}

private func appearanceJavaScript(wallpaperEnabled: Bool, isDarkMode: Bool) -> String {
    let scheme = isDarkMode ? "dark" : "light"
    let container = isDarkMode ? "rgba(8, 13, 21, .62)" : "rgba(255, 255, 255, .68)"
    let elevated = isDarkMode ? "rgba(13, 20, 31, .76)" : "rgba(255, 255, 255, .82)"
    let floating = isDarkMode ? "rgba(13, 20, 31, .82)" : "rgba(255, 255, 255, .9)"
    let wallpaperCSS = wallpaperEnabled ? """
        :root {
          --dsw-alias-bg-base: transparent !important;
          --dsw-alias-bg-container: \(container) !important;
          --dsw-alias-bg-elevated: \(elevated) !important;
          --dsw-alias-bg-float: \(floating) !important;
          --dsw-specific-bg-base: transparent !important;
        }
        html, body, #root { background: transparent !important; }
        """ : ""
    let css = """
        :root { color-scheme: \(scheme) !important; }
        html {
          -webkit-font-smoothing: antialiased;
          text-rendering: optimizeLegibility;
        }
        button, input, textarea { -webkit-font-smoothing: antialiased; }
        \(wallpaperCSS)
        """
    let literal = String(data: try! JSONEncoder().encode(css), encoding: .utf8)!
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
        })();
        """
}
