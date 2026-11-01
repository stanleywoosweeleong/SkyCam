import UIKit
import WebKit

/// Hosts the SkyCam web UI (bundled in `www`) and answers its native calls:
/// `capture` (bracketed HDR shot), `savePhoto` (put an album photo into Photos) and `insecure` (fallback page).
final class WebViewController: UIViewController, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
    static let appURL = URL(string: "skycam://localhost/index.html")!
    // Used only if WebKit does not treat the bundled page as a secure context (camera would be blocked there).
    static let fallbackURL = URL(string: "https://stanleywoosweeleong.github.io/SkyCam/")!

    private var web: WKWebView!
    private let camera = NativeCamera()

    override func loadView() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: "skycam")
        cfg.userContentController.add(WeakMessageHandler(self), name: "skycam")
        web = WKWebView(frame: .zero, configuration: cfg)
        web.uiDelegate = self
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        view = web
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        web.load(URLRequest(url: Self.appURL))
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // The app already holds the system camera permission, so getUserMedia needs no second prompt.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .destructive) { _ in completionHandler(true) })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let id = (body["id"] as? NSNumber)?.intValue,
              let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "capture":
            camera.capture(params: body) { [weak self] result in self?.reply(id, result) }
        case "savePhoto":
            guard let b64 = body["data"] as? String, let data = Data(base64Encoded: b64) else {
                reply(id, ["ok": false, "error": "no image"]); return
            }
            PhotoSaver.save(data) { [weak self] ok, err in self?.reply(id, ["ok": ok, "error": err ?? ""]) }
        case "insecure":
            if web.url?.scheme == "skycam" { web.load(URLRequest(url: Self.fallbackURL)) }
            reply(id, ["ok": true])
        default:
            reply(id, ["ok": false, "error": "unknown command \(cmd)"])
        }
    }

    private func reply(_ id: Int, _ result: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            self.web.evaluateJavaScript("window.__skycamReply&&window.__skycamReply(\(id),\(json))", completionHandler: nil)
        }
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle with the view controller.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// Serves the bundled web app at skycam://localhost/…
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root = Bundle.main.bundleURL.appendingPathComponent("www", isDirectory: true)
    private static let mime = ["html": "text/html; charset=utf-8", "js": "text/javascript", "svg": "image/svg+xml",
                               "png": "image/png", "webmanifest": "application/manifest+json", "json": "application/json"]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: file) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let type = Self.mime[file.pathExtension.lowercased()] ?? "application/octet-stream"
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": type, "Content-Length": String(data.count)])!
        urlSchemeTask.didReceive(resp)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
