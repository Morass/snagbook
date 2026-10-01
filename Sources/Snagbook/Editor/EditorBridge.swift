import AppKit
import SnagbookCore
import UniformTypeIdentifiers
import WebKit

/// Owns the web view that hosts the note editor and speaks its small JavaScript API.
/// Calls made before the page has loaded are queued and replayed.
@MainActor
final class EditorBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private(set) var webView: EditorWebView!
    private var ready = false
    private var queued: [String] = []
    weak var model: AppModel?
    /// Item currently shown, as the editor knows it.
    private(set) var shownItem: Int?
    /// Part of every media address; see MediaSchemeHandler.
    private var epoch = 0

    override init() {
        super.init()
        let conf = WKWebViewConfiguration()
        conf.setURLSchemeHandler(MediaSchemeHandler(bridge: self), forURLScheme: MediaSchemeHandler.scheme)
        conf.userContentController.add(WeakHandler(self), name: "snag")
        conf.preferences.setValue(true, forKey: "developerExtrasEnabled")
        conf.suppressesIncrementalRendering = false
        webView = EditorWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: conf)
        webView.bridge = self
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        load()
    }

    private func load() {
        guard let dir = Self.editorDirectory else {
            webView.loadHTMLString("<p style='font:14px -apple-system;padding:20px'>The editor files are missing from the app.</p>", baseURL: nil)
            return
        }
        webView.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
    }

    /// Resources/editor inside the app, or the repository copy when run from `swift run`.
    static var editorDirectory: URL? {
        if let u = Bundle.main.url(forResource: "editor", withExtension: nil), FileManager.default.fileExists(atPath: u.appendingPathComponent("index.html").path) { return u }
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        let dev = dir.appendingPathComponent("Resources/editor")
        return FileManager.default.fileExists(atPath: dev.appendingPathComponent("index.html").path) ? dev : nil
    }

    // MARK: - calls into the page

    func call(_ js: String) {
        if ready { webView.evaluateJavaScript(js, completionHandler: nil) } else { queued.append(js) }
    }

    /// Evaluate and hand back the result (the self-test and flushes need answers).
    func evaluate(_ js: String) async -> Any? {
        guard ready else { return nil }
        return try? await webView.evaluateJavaScript(js)
    }

    static func json(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]), let s = String(data: d, encoding: .utf8) else { return "null" }
        return s
    }

    func open(item id: Int, markdown: String, focus: Bool) {
        shownItem = id
        call("snag.open(\(Self.json(["id": id, "markdown": markdown, "base": MediaSchemeHandler.base(for: id, epoch: epoch), "context": epoch, "focus": focus])))")
    }

    func forget(item id: Int) {
        if shownItem == id { shownItem = nil }
        epoch += 1
        call("snag.forget(\(id))")
    }

    /// Another session is open: its items reuse the ids and picture names of this one.
    func sessionChanged() {
        epoch += 1
        shownItem = nil
        call("snag.reset()")
    }

    /// The current session vanished, so its unsavable editor state must not block recovery.
    func sessionClosed() {
        if let shownItem { forget(item: shownItem) }
        shownItem = nil
        epoch += 1
    }

    /// Write out any change the editor has not reported yet, and wait for it.
    func flush() async -> Bool {
        guard model?.session != nil else {
            sessionClosed()
            return true
        }
        guard ready, let r = await evaluate("snag.takePending()") as? [String: Any],
              let id = r["id"] as? Int, let md = r["markdown"] as? String else { return true }
        guard model?.noteChanged(id: id, markdown: md) == true else {
            call("snag.restorePending(\(Self.json(r)))")
            return false
        }
        return true
    }

    func insertMarkdown(_ text: String) { call("snag.insertMarkdown(\(Self.json(text)))") }

    func insertMedia(kind: String, src: String, label: String) {
        call("snag.insertMedia(\(Self.json(["kind": kind, "src": src, "label": label])))")
    }

    func refreshMedia(_ src: String) { call("snag.refreshMedia(\(Self.json(src)))") }

    func focus() {
        webView.window?.makeFirstResponder(webView)
        call("snag.focus()")
    }

    // MARK: - messages from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            let pending = queued
            queued.removeAll()
            for js in pending { webView.evaluateJavaScript(js, completionHandler: nil) }
            model?.editorReady()
        case "changed":
            if let id = body["id"] as? Int, let md = body["markdown"] as? String,
               model?.noteChanged(id: id, markdown: md) == false {
                call("snag.restorePending(\(Self.json(body)))")
            }
        case "media":
            guard let req = body["reqId"] as? Int else { return }
            guard let item = body["itemId"] as? Int, let context = body["context"] as? Int,
                  item == shownItem, context == epoch else {
                call("snag.mediaFailed(\(req))")
                return
            }
            let data = (body["base64"] as? String).flatMap { Data(base64Encoded: $0) }
            let mime = body["mime"] as? String ?? ""
            let name = body["name"] as? String ?? ""
            if let data, let rel = model?.savePasted(data: data, mime: mime, name: name) {
                call("snag.mediaSaved(\(req), \(Self.json(rel)))")
            } else {
                call("snag.mediaFailed(\(req))")
            }
        case "annotate":
            if let src = body["src"] as? String { model?.annotateExisting(src: src) }
        case "open":
            if let href = body["href"] as? String { model?.openLink(href) }
        default:
            break
        }
    }

    // Links clicked in the page open in the browser, never inside the editor.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url {
            model?.openLink(url.absoluteString)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page crashed: reload it and put the current item back.
        ready = false
        load()
        model?.reopenCurrentAfterCrash()
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle.
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}

/// The editor's web view. Pastes of pictures that WebKit would not hand to the page
/// (a file copied in Finder, a TIFF from some apps) are caught here.
final class EditorWebView: WKWebView {
    weak var bridge: EditorBridge?

    /// ⌘V reaches the view before the Edit menu, so this sees every keyboard paste.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let focused = (window?.firstResponder as? NSView).map { $0 === self || $0.isDescendant(of: self) } ?? false
        if focused, mods == .command, event.charactersIgnoringModifiers == "v", handleNativePaste() { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func handleNativePaste() -> Bool {
        let pb = NSPasteboard.general
        if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let media = files.first(where: { MediaKind.of($0) != nil }) {
            Task { @MainActor in bridge?.model?.importFile(media) }
            return true
        }
        // Plain text or HTML: the page handles it. A bare picture with no text: convert it
        // here, so every image type (TIFF included) becomes a PNG.
        let hasText = pb.availableType(from: [.string, .html, .rtf]) != nil
        if !hasText, let img = NSImage(pasteboard: pb), let png = img.pngData() {
            Task { @MainActor in bridge?.model?.insertImageData(png) }
            return true
        }
        return false
    }
}

enum MediaKind {
    case image, video

    static func of(_ url: URL) -> MediaKind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        return nil
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }
}
