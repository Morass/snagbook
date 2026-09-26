import AppKit
import SnagbookCore
import SnagbookRender
import SwiftUI

/// The mark-up window: circle, arrow, box, write on a screenshot, then Done.
/// The untouched original and the marks are kept beside the picture, so marks can be
/// changed later (double-click the picture in the note).
@MainActor
final class Annotator: NSObject, NSWindowDelegate, ObservableObject {
    static var open: [Annotator] = []

    let item: Int
    let relative: String
    let isNew: Bool
    unowned let model: AppModel
    let original: CGImage
    private let previousApp: NSRunningApplication?

    @Published var doc: MarkDocument
    /// Every screenshot opens with the highlighter.
    @Published var tool: Tool = .mark(.highlighter)
    /// The colour of the current tool. Each tool keeps its own: the highlighter starts
    /// yellow, everything else red.
    @Published var color = Annotator.palette[1] {
        didSet { colors[tool] = color }
    }
    private var colors: [Tool: String] = [.mark(.highlighter): Annotator.palette[1]]
    @Published var width: Double
    /// How solid new marks are, 10–100%. With Select, it changes the selected mark.
    @Published var opacity: Double = 1
    @Published var selected: Int?
    private var undoStack: [MarkDocument] = []
    private var redoStack: [MarkDocument] = []
    private var window: NSWindow!
    weak var canvas: AnnotationCanvas?
    private var finished = false

    enum Tool: Hashable {
        case mark(MarkTool), select, crop
        var key: Character { switch self { case .mark(let t): return t.key; case .select: return "v"; case .crop: return "c" } }
        var title: String { switch self { case .mark(let t): return t.title; case .select: return "Select"; case .crop: return "Crop" } }
        var symbol: String {
            switch self {
            case .select: return "cursorarrow"
            case .crop: return "crop"
            case .mark(let t):
                switch t {
                case .arrow: return "arrow.up.right"
                case .ellipse: return "circle"
                case .rect: return "rectangle"
                case .pen: return "scribble"
                case .highlighter: return "highlighter"
                case .text: return "textformat"
                case .counter: return "1.circle"
                case .pixelate: return "square.grid.3x3.fill"
                }
            }
        }
        static var all: [Tool] { [.mark(.highlighter), .mark(.ellipse), .mark(.arrow), .mark(.rect), .mark(.pen), .mark(.text), .mark(.counter), .mark(.pixelate), .crop, .select] }
        static var ellipse: Tool { .mark(.ellipse) }
    }

    static let palette = ["#ff3b30", "#ffcc00", "#34c759", "#0a84ff", "#ffffff", "#000000"]

    // MARK: - open

    static func open(item: Int, relative: String, isNew: Bool, model: AppModel) {
        guard let session = model.session, let itemDir = try? session.itemURL(item) else { return }
        let fileURL = itemDir.appendingPathComponent(relative)
        let comp = MarkDocument.companions(of: relative)
        let origURL = itemDir.appendingPathComponent(comp.orig)
        let marksURL = itemDir.appendingPathComponent(comp.marks)
        let hasOrig = FileManager.default.fileExists(atPath: origURL.path)
        guard let original = ImageFile.load(hasOrig ? origURL : fileURL) else {
            model.alert = .init(title: "Cannot open picture", message: "\(relative) could not be read.")
            return
        }
        var doc = MarkDocument(width: original.width, height: original.height)
        if hasOrig, let data = try? Data(contentsOf: marksURL), let d = try? MarkDocument.decode(data), d.width == original.width, d.height == original.height {
            doc = d
        }
        let a = Annotator(item: item, relative: relative, isNew: isNew, model: model, original: original, doc: doc)
        open.append(a)
        a.show()
    }

    init(item: Int, relative: String, isNew: Bool, model: AppModel, original: CGImage, doc: MarkDocument) {
        self.item = item
        self.relative = relative
        self.isNew = isNew
        self.model = model
        self.original = original
        self.doc = doc
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == getpid() ? nil : front
        // Stroke width scales with the picture so marks look the same on any Retina factor.
        let base = max(3, Double(max(original.width, original.height)) / 320)
        self.width = min(12, base.rounded())
        super.init()
    }

    private func show() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let imgPts = NSSize(width: Double(original.width) / scale, height: Double(original.height) / scale)
        let maxW = screen.width * 0.9, maxH = screen.height * 0.85 - 60
        let fit = min(1, maxW / imgPts.width, maxH / imgPts.height)
        let size = NSSize(width: max(560, imgPts.width * fit + 40), height: max(360, imgPts.height * fit + 100))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Mark up — " + (relative as NSString).lastPathComponent
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: AnnotatorView(a: self))
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { if let c = self.canvas { w.makeFirstResponder(c) } }
    }

    // MARK: - editing

    func commit(_ change: (inout MarkDocument) -> Void) {
        undoStack.append(doc)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        change(&doc)
        canvas?.needsDisplay = true
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return NSSound.beep() }
        redoStack.append(doc)
        doc = prev
        selected = nil
        canvas?.needsDisplay = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return NSSound.beep() }
        undoStack.append(doc)
        doc = next
        canvas?.needsDisplay = true
    }

    func deleteSelected() {
        guard let i = selected, doc.marks.indices.contains(i) else { return }
        commit { $0.marks.remove(at: i) }
        selected = nil
    }

    func setTool(_ t: Tool) {
        canvas?.endTextEditing(commit: true)
        tool = t
        let c = colors[t] ?? Annotator.palette[0]
        if color != c { color = c }
        if t != .select { selected = nil }
        canvas?.needsDisplay = true
        canvas?.window?.invalidateCursorRects(for: canvas!)
    }

    // MARK: - finishing

    /// Save the marks and the rendered picture, then close.
    func done() {
        canvas?.endTextEditing(commit: true)
        guard let session = model.session, let dir = try? session.itemURL(item) else { return close() }
        let fileURL = dir.appendingPathComponent(relative)
        let comp = MarkDocument.companions(of: relative)
        let origURL = dir.appendingPathComponent(comp.orig)
        let marksURL = dir.appendingPathComponent(comp.marks)
        let fm = FileManager.default
        do {
            if doc.marks.isEmpty && doc.crop == nil {
                // Nothing drawn: the picture is just the original, with no companions.
                if fm.fileExists(atPath: origURL.path) {
                    try? fm.removeItem(at: fileURL)
                    try fm.moveItem(at: origURL, to: fileURL)
                }
                try? fm.removeItem(at: marksURL)
            } else {
                if !fm.fileExists(atPath: origURL.path) {
                    guard let png = ImageFile.pngData(original) else { throw VideoErrorLike("encode") }
                    try png.write(to: origURL, options: .atomic)
                }
                guard let out = MarkRenderer.render(doc, original: original), let png = ImageFile.pngData(out) else { throw VideoErrorLike("render") }
                try png.write(to: fileURL, options: .atomic)
                try doc.encoded().write(to: marksURL, options: .atomic)
            }
            finished = true
            model.annotationFinished(item: item, relative: relative, isNew: isNew, kept: true)
            try? session.writeReadme()
        } catch {
            model.show(error)
        }
        close()
    }

    /// New screenshot: keep it without marks. Existing picture: leave it as it was.
    func skip() {
        finished = true
        if isNew { model.annotationFinished(item: item, relative: relative, isNew: true, kept: true) }
        close()
    }

    /// New screenshot only: throw it away.
    func discard() {
        finished = true
        if isNew, let dir = try? model.session?.itemURL(item) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(relative))
            model.flash("Screenshot discarded")
        }
        close()
    }

    private func close() {
        window?.orderOut(nil)
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if !finished { skip() }
        Annotator.open.removeAll { $0 === self }
        if model.capture.takeRestoreNotebook() {
            WindowPlacement.show()
        } else if let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        }
    }
}

struct VideoErrorLike: Error, LocalizedError {
    let what: String
    init(_ w: String) { what = w }
    var errorDescription: String? { "The picture could not be saved (\(what))." }
}

// MARK: - window content

struct AnnotatorView: View {
    @ObservedObject var a: Annotator

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Annotator.Tool.all, id: \.self) { t in
                    Button { a.setTool(t) } label: { Image(systemName: t.symbol).frame(width: 22, height: 18) }
                        .buttonStyle(.borderless)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(a.tool == t ? Color.accentColor.opacity(0.25) : .clear))
                        .help("\(t.title) (\(String(t.key).uppercased()))")
                }
                Divider().frame(height: 20).padding(.horizontal, 4)
                ForEach(Array(Annotator.palette.enumerated()), id: \.offset) { i, c in
                    Button { a.color = c; a.recolorSelected(c) } label: {
                        Circle().fill(Color(nsColor: NSColor(hex: c))).frame(width: 16, height: 16)
                            .overlay(Circle().stroke(a.color == c ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: a.color == c ? 2.5 : 1))
                    }
                    .buttonStyle(.borderless)
                    .help("Colour \(i + 1)")
                }
                Divider().frame(height: 20).padding(.horizontal, 4)
                Button { a.width = max(1, a.width - 1) } label: { Image(systemName: "minus") }.buttonStyle(.borderless).help("Thinner ([)")
                Text("\(Int(a.width))").font(.caption.monospacedDigit()).frame(width: 20)
                Button { a.width = min(40, a.width + 1) } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("Thicker (])")
                Divider().frame(height: 20).padding(.horizontal, 4)
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary).help("Opacity")
                Slider(value: Binding(get: { a.opacity }, set: { a.setOpacity($0) }), in: 0.1...1)
                    .frame(width: 90)
                    .help("How solid marks are: drag left to see the picture through them (, and . step it)")
                Text("\(Int((a.opacity * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 34, alignment: .leading)
                Spacer(minLength: 12)
                Button { a.undo() } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.borderless).help("Undo (⌘Z)")
                if a.isNew {
                    Button("Discard", role: .destructive) { a.discard() }.help("Throw this screenshot away (⌘⌫)")
                    Button("No Marks") { a.skip() }.help("Keep the screenshot as it is (Esc)")
                } else {
                    Button("Cancel") { a.skip() }.help("Keep the picture as it was (Esc)")
                }
                Button("Done") { a.done() }.keyboardShortcut(.defaultAction).help("Save (Return)")
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.bar)
            Divider()
            CanvasHost(a: a)
        }
    }
}

extension Annotator {
    /// What a new mark stores: nil when solid, so files stay as they were.
    var markOpacity: Double? { opacity >= 0.995 ? nil : (opacity * 100).rounded() / 100 }

    func setOpacity(_ v: Double) {
        opacity = min(1, max(0.1, v))
        guard tool == .select, let i = selected, doc.marks.indices.contains(i), doc.marks[i].tool != .pixelate else { return }
        commit { $0.marks[i].opacity = self.markOpacity }
    }

    func recolorSelected(_ c: String) {
        guard tool == .select, let i = selected, doc.marks.indices.contains(i) else { return }
        commit { $0.marks[i].color = c }
    }
}

struct CanvasHost: NSViewRepresentable {
    let a: Annotator
    func makeNSView(context: Context) -> AnnotationCanvas {
        let c = AnnotationCanvas(annotator: a)
        a.canvas = c
        return c
    }
    func updateNSView(_ v: AnnotationCanvas, context: Context) { v.needsDisplay = true }
}

extension NSColor {
    convenience init(hex: String) {
        let (r, g, b) = MarkRenderer.rgb(hex)
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
