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
    let session: Session
    let itemIdentity: String
    private var pictureBinding: Session.FileBinding
    private var origBinding: Session.FileBinding?
    private var marksBinding: Session.FileBinding?
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
    /// True while the opacity slider is being dragged: one drag is one step to undo, however
    /// many values it passes through.
    var sliding = false { didSet { if !sliding { slideCommitted = false } } }
    private var slideCommitted = false
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
        do {
            guard let source = model.session, let itemIdentity = model.openedItemIdentity(item) else {
                throw SnagError.noSuchItem(item)
            }
            let session = try source.reopenedMatchingItem(item, identity: itemIdentity, fallbackHeader: model.config.header)
            let itemDir = try session.itemURL(item)
            let fileURL = itemDir.appendingPathComponent(relative)
            let comp = MarkDocument.companions(of: relative)
            let origURL = itemDir.appendingPathComponent(comp.orig)
            let marksURL = itemDir.appendingPathComponent(comp.marks)
            let pictureBinding = try Session.bindFile(fileURL)
            let origBinding = FileManager.default.fileExists(atPath: origURL.path) ? try Session.bindFile(origURL) : nil
            let marksBinding = FileManager.default.fileExists(atPath: marksURL.path) ? try Session.bindFile(marksURL) : nil
            let originalData = try Session.read(origBinding ?? pictureBinding)
            guard let original = ImageFile.load(originalData) else { throw VideoErrorLike("read") }
            var doc = MarkDocument(width: original.width, height: original.height)
            if let marksBinding, let d = try? MarkDocument.decode(Session.read(marksBinding)), d.width == original.width, d.height == original.height {
                doc = d
            }
            let a = Annotator(item: item, relative: relative, isNew: isNew, model: model, session: session, itemIdentity: itemIdentity, pictureBinding: pictureBinding, origBinding: origBinding, marksBinding: marksBinding, original: original, doc: doc)
            open.append(a)
            a.show()
        } catch {
            model.alert = .init(title: "Cannot open picture", message: "\(relative) could not be read.")
        }
    }

    init(item: Int, relative: String, isNew: Bool, model: AppModel, session: Session, itemIdentity: String, pictureBinding: Session.FileBinding, origBinding: Session.FileBinding?, marksBinding: Session.FileBinding?, original: CGImage, doc: MarkDocument) {
        self.item = item
        self.relative = relative
        self.isNew = isNew
        self.model = model
        self.session = session
        self.itemIdentity = itemIdentity
        self.pictureBinding = pictureBinding
        self.origBinding = origBinding
        self.marksBinding = marksBinding
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
        do {
            let live = try liveSession()
            let itemDir = try live.itemURL(item)
            let fileURL = itemDir.appendingPathComponent(relative)
            let comp = MarkDocument.companions(of: relative)
            let origURL = itemDir.appendingPathComponent(comp.orig)
            let marksURL = itemDir.appendingPathComponent(comp.marks)
            let pictureBinding = try Session.rebind(self.pictureBinding, to: fileURL)
            let origBinding = try self.origBinding.map { try Session.rebind($0, to: origURL) }
            let marksBinding = try self.marksBinding.map { try Session.rebind($0, to: marksURL) }
            if origBinding == nil, FileManager.default.fileExists(atPath: origURL.path) {
                throw SnagError.mediaChanged(origURL.lastPathComponent)
            }
            if marksBinding == nil, FileManager.default.fileExists(atPath: marksURL.path) {
                throw SnagError.mediaChanged(marksURL.lastPathComponent)
            }
            let boundOriginal = try origBinding.map(Session.read)
            var nextOrigBinding = origBinding
            var nextMarksBinding = marksBinding
            if doc.marks.isEmpty && doc.crop == nil {
                if let origBinding, let originalPicture = boundOriginal {
                    let previousPicture = try Session.read(pictureBinding)
                    let previousMarks = try marksBinding.map(Session.read)
                    var removedMarks = false
                    do {
                        try Session.write(originalPicture, to: pictureBinding)
                        if let marksBinding {
                            try Session.remove(marksBinding)
                            removedMarks = true
                        }
                        try Session.remove(origBinding)
                        nextOrigBinding = nil
                        nextMarksBinding = nil
                    } catch {
                        try? Session.write(previousPicture, to: pictureBinding)
                        if removedMarks, let previousMarks { try? previousMarks.write(to: marksURL, options: .withoutOverwriting) }
                        throw error
                    }
                } else if let marksBinding {
                    try Session.remove(marksBinding)
                    nextMarksBinding = nil
                }
            } else {
                let previousPicture = try Session.read(pictureBinding)
                let previousMarks = try marksBinding.map(Session.read)
                guard let rendered = MarkRenderer.render(doc, original: original), let picture = ImageFile.pngData(rendered),
                      let pristine = ImageFile.pngData(original) else { throw VideoErrorLike("render") }
                let encoded = try doc.encoded()
                var createdOrig: Session.FileBinding?
                var createdMarks: Session.FileBinding?
                do {
                    if origBinding == nil {
                        try pristine.write(to: origURL, options: .withoutOverwriting)
                        createdOrig = try Session.bindFile(origURL)
                    }
                    if let marksBinding {
                        try Session.write(encoded, to: marksBinding)
                    } else {
                        try encoded.write(to: marksURL, options: .withoutOverwriting)
                        createdMarks = try Session.bindFile(marksURL)
                    }
                    try Session.write(picture, to: pictureBinding)
                    nextOrigBinding = origBinding ?? createdOrig
                    nextMarksBinding = marksBinding ?? createdMarks
                } catch {
                    try? Session.write(previousPicture, to: pictureBinding)
                    if let marksBinding, let previousMarks { try? Session.write(previousMarks, to: marksBinding) }
                    if let createdMarks { try? Session.remove(createdMarks) }
                    if let createdOrig { try? Session.remove(createdOrig) }
                    throw error
                }
            }
            self.pictureBinding = pictureBinding
            self.origBinding = nextOrigBinding
            self.marksBinding = nextMarksBinding
            try model.annotationFinished(session: live, item: item, relative: relative, isNew: isNew, kept: true)
            finished = true
            try? live.writeReadme()
            close()
        } catch {
            model.show(error)
        }
    }

    /// New screenshot: keep it without marks. Existing picture: leave it as it was.
    func skip() {
        do {
            if isNew { try model.annotationFinished(session: try liveSession(), item: item, relative: relative, isNew: true, kept: true) }
            finished = true
            close()
        } catch {
            model.show(error)
        }
    }

    /// New screenshot only: throw it away.
    func discard() {
        do {
            if isNew {
                let live = try liveSession()
                let current = try Session.rebind(pictureBinding, to: try live.itemURL(item).appendingPathComponent(relative))
                try Session.remove(current)
                model.flash("Screenshot discarded")
            }
            finished = true
            close()
        } catch {
            model.show(error)
        }
    }

    private func liveSession() throws -> Session {
        try session.reopenedMatchingItem(item, identity: itemIdentity, fallbackHeader: model.config.header)
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
                Slider(value: Binding(get: { a.opacity }, set: { a.setOpacity($0) }), in: 0.1...1, onEditingChanged: { a.sliding = $0 })
                    .frame(minWidth: 40, idealWidth: 90, maxWidth: 90)
                    .help("How solid marks are: drag left to see the picture through them (, and . step it)")
                Text("\(Int((a.opacity * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 34, alignment: .leading)
                Spacer(minLength: 12)
                // Icons that never shrink: on a narrow window the words were squeezed to slivers.
                HStack(spacing: 10) {
                    Button { a.undo() } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.borderless).help("Undo (⌘Z)")
                    if a.isNew {
                        Button { a.discard() } label: { Image(systemName: "trash").foregroundStyle(.red) }
                            .buttonStyle(.borderless).help("Discard: throw this screenshot away (⌘⌫)")
                        Button { a.skip() } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless).help("No marks: keep the screenshot as it is (Esc)")
                    } else {
                        Button { a.skip() } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless).help("Cancel: keep the picture as it was (Esc)")
                    }
                    Button { a.done() } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .font(.system(size: 24))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .help("Done: save the marks (Return)")
                }
                .font(.system(size: 16))
                .fixedSize()
                .layoutPriority(1)
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
        if sliding && slideCommitted {
            doc.marks[i].opacity = markOpacity
            canvas?.needsDisplay = true
            return
        }
        commit { $0.marks[i].opacity = self.markOpacity }
        slideCommitted = sliding
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
