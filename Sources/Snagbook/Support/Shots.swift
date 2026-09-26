import AppKit
import SnagbookCore
import WebKit

/// Pictures for the README. The app draws its own windows into bitmaps — no screen
/// recording, nothing that needs a permission dialog on a machine nobody is sitting at.
///
///     HOME=<throwaway> SNAGBOOK_CONFIG=<throwaway>/config.json SNAGBOOK_SHOTS=<dir> \
///         build/Snagbook.app/Contents/MacOS/Snagbook
///
/// The session it opens is whatever the config's lastSession names (see scripts/readme-shots.sh).
/// Writes notebook.png, markup.png and recording.png, then quits.
@MainActor
enum Shots {
    static var dir: String? { ProcessInfo.processInfo.environment["SNAGBOOK_SHOTS"] }
    static var isCapturing: Bool { dir != nil }

    static func runIfRequested(_ model: AppModel) {
        guard let dir else { return }
        Task { @MainActor in
            for _ in 0..<100 where !(await SelfTest.pageReady(model)) { await SelfTest.settle(100) }
            guard let win = WindowPlacement.notebook else { return fail("no notebook window") }
            win.setFrame(NSRect(x: 80, y: 80, width: 1080, height: 700), display: true)
            await SelfTest.settle(500)

            // 1. The notebook, on the item with a picture.
            model.select(1)
            await SelfTest.settle(1200)
            await write(win, webViews: [model.editor.webView], to: dir + "/notebook.png")

            // 2. The same picture in the mark-up window, with a few marks on it.
            Annotator.open(item: 1, relative: "media/image-001.png", isNew: false, model: model)
            await SelfTest.settle(800)
            if let a = Annotator.open.last, let aw = a.canvas?.window {
                let w = Double(a.doc.width), h = Double(a.doc.height)
                a.commit { d in
                    d.marks.append(Mark(tool: .highlighter, points: [Pt(w * 0.075, h * 0.12), Pt(w * 0.43, h * 0.12)], color: "#ffcc00", width: max(12, h / 22)))
                    d.marks.append(Mark(tool: .ellipse, points: [Pt(w * 0.34, h * 0.5), Pt(w * 0.66, h * 0.73)], color: "#ff3b30", width: max(4, h / 90)))
                    d.marks.append(Mark(tool: .arrow, points: [Pt(w * 0.86, h * 0.9), Pt(w * 0.68, h * 0.7)], color: "#ff3b30", width: max(4, h / 90)))
                    d.marks.append(Mark(tool: .counter, points: [Pt(w * 0.3, h * 0.45)], color: "#0a84ff", width: max(4, h / 90), number: 1))
                    d.marks.append(Mark(tool: .text, points: [Pt(w * 0.06, h * 0.8)], color: "#ffffff", width: max(18, h / 16), text: "logo covers Start"))
                }
                a.opacity = 1
                aw.setFrame(NSRect(x: 120, y: 60, width: 1000, height: 700), display: true)
                await SelfTest.settle(800)
                await write(aw, webViews: [], to: dir + "/markup.png")
                if ProcessInfo.processInfo.environment["SNAGBOOK_SHOTS_NARROW"] != nil {
                    aw.setFrame(NSRect(x: 120, y: 60, width: 620, height: 560), display: true)
                    await SelfTest.settle(800)
                    await write(aw, webViews: [], to: dir + "/markup-narrow.png")
                }
                a.skip()
            } else {
                fail("the mark-up window did not open")
            }
            await SelfTest.settle(500)

            // 3. A note with a recording in it.
            if let rec = model.items.first(where: { $0.folder.contains("recording") }) {
                model.select(rec.id)
                await SelfTest.settle(1500)
                await write(win, webViews: [model.editor.webView], to: dir + "/recording.png")
            }
            print("shots: done")
            exit(failures ? 1 : 0)
        }
    }

    private static var failures = false

    private static func fail(_ what: String) {
        print("shots: FAIL \(what)")
        failures = true
    }

    /// The whole window (title bar and toolbar included), drawn from its layers, with each web
    /// view's own snapshot laid over it (a web view draws in another process).
    static func write(_ window: NSWindow, webViews: [WKWebView], to path: String) async {
        guard let root = window.contentView?.superview ?? window.contentView else { return fail("no view") }
        // Translucent materials cannot be drawn offscreen (they come out white): let the views
        // behind them paint instead.
        func plain(_ v: NSView) {
            let name = String(describing: type(of: v))
            if v is NSVisualEffectView || name.contains("Backdrop") || name.contains("Blurry") || String(describing: type(of: v.layer as Any)).contains("Backdrop") { v.isHidden = true }
            v.subviews.forEach(plain)
        }
        plain(root)
        root.layoutSubtreeIfNeeded()
        await SelfTest.settle(300)
        let size = root.bounds.size
        let scale = window.backingScaleFactor
        let W = Int(size.width * scale), H = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return fail("no bitmap") }
        // Dynamic colours resolve in the window's appearance (dark or light), not the default one.
        func resolved(_ c: NSColor) -> CGColor {
            var out = c.cgColor
            window.effectiveAppearance.performAsCurrentDrawingAppearance { out = c.cgColor }
            return out
        }
        ctx.setFillColor(resolved(.windowBackgroundColor))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.scaleBy(x: scale, y: scale)
        // Views that paint themselves use the current appearance while they are rendered here.
        window.effectiveAppearance.performAsCurrentDrawingAppearance { root.layer?.render(in: ctx) }
        // The glass itself draws as a white slab; lay the sidebar's own contents over it on the
        // window's background.
        for web in webViews {
            guard let snap = try? await web.takeSnapshot(configuration: WKSnapshotConfiguration()),
                  let cg = snap.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fail("web view snapshot"); continue }
            let r = web.convert(web.bounds, to: nil) // window coordinates, origin bottom-left
            ctx.draw(cg, in: r)
        }
        guard let img = ctx.makeImage() else { return fail("no image") }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let png = rep.representation(using: .png, properties: [:]) else { return fail("png") }
        try? png.write(to: URL(fileURLWithPath: path))
        print("shots: \(path) \(W)x\(H)")
    }
}
