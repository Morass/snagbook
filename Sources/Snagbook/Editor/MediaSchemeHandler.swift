import Foundation
import SnagbookCore
import UniformTypeIdentifiers
import WebKit

/// Serves an item's files to the editor as snagbook://item/<id>/<relative path>.
/// Items are addressed by their permanent id, so renaming an item (and its folder) does not
/// break pictures on screen. Byte ranges are honoured, which video playback needs.
final class MediaSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "snagbook"
    weak var bridge: EditorBridge?

    init(bridge: EditorBridge) { self.bridge = bridge }

    static func base(for id: Int) -> String { "\(scheme)://item/\(id)/" }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "item" else { return fail(task, 400) }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map { String($0).removingPercentEncoding ?? String($0) }
        guard let first = parts.first, let id = Int(first), parts.count >= 2 else { return fail(task, 404) }
        let rel = parts.dropFirst().joined(separator: "/")
        let file: URL? = MainActor.assumeIsolated { bridge?.model?.fileURL(item: id, relative: rel) }
        guard let file, let handle = try? FileHandle(forReadingFrom: file) else { return fail(task, 404) }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        let mime = UTType(filenameExtension: file.pathExtension.lowercased())?.preferredMIMEType ?? "application/octet-stream"

        var status = 200
        var start = 0, end = max(0, size - 1)
        if let range = task.request.value(forHTTPHeaderField: "Range"), let r = ByteRange.parse(range, size: size) {
            (start, end) = r
            status = 206
        }
        let length = size == 0 ? 0 : end - start + 1
        try? handle.seek(toOffset: UInt64(start))
        let data = (try? handle.read(upToCount: length)) ?? Data()
        var headers = [
            "Content-Type": mime,
            "Content-Length": String(data.count),
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
        ]
        if status == 206 { headers["Content-Range"] = "bytes \(start)-\(start + data.count - 1)/\(size)" }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func fail(_ task: WKURLSchemeTask, _ code: Int) {
        let r = HTTPURLResponse(url: task.request.url ?? URL(string: "snagbook://x")!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
        task.didReceive(r)
        task.didFinish()
    }
}
