import SwiftUI
import WebKit
import UserNotifications
import WidgetKit

@main
struct LiftApp: App {
    init() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    var body: some Scene {
        WindowGroup {
            WebView()
                .ignoresSafeArea(.container)
                .background(Color.black.ignoresSafeArea())
                .preferredColorScheme(.dark)
        }
    }
}

struct WebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        config.userContentController.addScriptMessageHandler(Bridge(), contentWorld: .page, name: "native")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.allowsLinkPreview = false
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.pinchGestureRecognizer?.isEnabled = false
        web.scrollView.keyboardDismissMode = .interactive
        context.coordinator.load(web)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        func load(_ web: WKWebView) {
            guard let dir = Bundle.main.url(forResource: "Web", withExtension: nil),
                  FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.html").path) else {
                show(web, "Web/index.html was not found inside the app.")
                return
            }
            web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        }

        func webView(_ web: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            show(web, error.localizedDescription)
        }

        func webView(_ web: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            show(web, error.localizedDescription)
        }

        func webViewWebContentProcessDidTerminate(_ web: WKWebView) {
            load(web)
        }

        private func show(_ web: WKWebView, _ message: String) {
            let text = message.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            let page = "<meta name=viewport content='width=device-width,initial-scale=1'><body style='margin:0;padding:72px 24px;background:#000;color:#fff;font:17px -apple-system'><h2>Lift can’t start</h2><p style='color:#aaa'>\(text)</p></body>"
            web.loadHTMLString(page, baseURL: nil)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               !url.isFileURL {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

@MainActor
final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let fn = body["fn"] as? String else {
            return (nil, "Bad request")
        }
        let args = body["args"] as? [Any] ?? []
        do {
            switch fn {
            case "getAll":
                return (try Store.shared.getAll(), nil)
            case "saveTables":
                try Store.shared.save(batch: args.first)
                return (nil, nil)
            case "backupInfo":
                return (Store.shared.backupInfo(), nil)
            case "widgetSync":
                let result = WidgetStore.write(args.first as? String ?? "")
                if result == "ok" {
                    WidgetCenter.shared.reloadAllTimelines()
                }
                return (result, nil)
            case "health":
                return (try await Health.summary(), nil)
            case "haptic":
                haptic(args.first as? String ?? "light")
                return (nil, nil)
            case "exportFile":
                let name = args.count > 0 ? args[0] as? String ?? "export.json" : "export.json"
                let text = args.count > 1 ? args[1] as? String ?? "" : ""
                try share(name: name, text: text)
                return (nil, nil)
            default:
                return (nil, "Unknown function: \(fn)")
            }
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func haptic(_ style: String) {
        if style == "success" {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            UIImpactFeedbackGenerator(style: style == "medium" ? .medium : .light).impactOccurred()
        }
    }

    private func share(name: String, text: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent((name as NSString).lastPathComponent)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        while let next = top.presentedViewController {
            top = next
        }
        top.present(UIActivityViewController(activityItems: [url], applicationActivities: nil), animated: true)
    }
}
