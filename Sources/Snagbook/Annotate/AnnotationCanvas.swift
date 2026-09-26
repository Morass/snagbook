import AppKit
import SnagbookCore
import SnagbookRender

/// Shows the picture scaled to fit and turns mouse drags into marks. All geometry is kept
/// in image pixels; the view only converts at its edges.
final class AnnotationCanvas: NSView, NSTextFieldDelegate {
    unowned let a: Annotator
    private var draft: Mark?
    private var cropDraft: Box?
    private var dragStart: Pt?
    private var moveFrom: Pt?
    private var moved = false
    private var textField: NSTextField?
    private var textAnchor: Pt?
    private var editingIndex: Int?

    init(annotator: Annotator) {
        a = annotator
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - geometry

    /// Image pixels per view point, and where the picture sits.
    var layout: (scale: Double, origin: CGPoint) {
        let iw = Double(a.original.width), ih = Double(a.original.height)
        let pad = 16.0
        // Fit the window, but never larger than one image pixel per screen pixel.
        let native = 1 / Double(window?.backingScaleFactor ?? 2)
        let scale = max(min((bounds.width - 2 * pad) / iw, (bounds.height - 2 * pad) / ih, native), 0.01)
        return (scale, CGPoint(x: (bounds.width - iw * scale) / 2, y: (bounds.height - ih * scale) / 2))
    }

    func toImage(_ p: NSPoint) -> Pt {
        let l = layout
        return Pt((p.x - l.origin.x) / l.scale, (p.y - l.origin.y) / l.scale)
    }

    func toView(_ p: Pt) -> NSPoint {
        let l = layout
        return NSPoint(x: l.origin.x + p.x * l.scale, y: l.origin.y + p.y * l.scale)
    }

    func clampToImage(_ p: Pt) -> Pt { Pt(min(max(p.x, 0), Double(a.original.width)), min(max(p.y, 0), Double(a.original.height))) }

    // MARK: - drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.blended(withFraction: 0.35, of: .black)?.setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let l = layout
        let iw = Double(a.original.width), ih = Double(a.original.height)
        ctx.saveGState()
        ctx.translateBy(x: l.origin.x, y: l.origin.y)
        ctx.scaleBy(x: l.scale, y: l.scale)
        // The view is flipped (top-left origin); CGImage draws bottom-up, so flip it back.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: ih)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(a.original, in: CGRect(x: 0, y: 0, width: iw, height: ih))
        ctx.restoreGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: iw, height: ih))
        var marks = a.doc.marks
        if let i = editingIndex, marks.indices.contains(i) { marks.remove(at: i) }
        MarkRenderer.draw(marks, in: ctx, original: a.original, imageHeight: ih)
        if let draft { MarkRenderer.draw(draft, in: ctx, original: a.original, imageHeight: ih) }
        // Crop: darken what will be cut away.
        if let crop = cropDraft ?? a.doc.crop {
            let full = CGRect(x: 0, y: 0, width: iw, height: ih)
            let keep = CGRect(x: crop.x, y: crop.y, width: crop.w, height: crop.h)
            let path = CGMutablePath()
            path.addRect(full)
            path.addRect(keep)
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(1.5 / l.scale)
            ctx.setLineDash(phase: 0, lengths: [6 / l.scale, 4 / l.scale])
            ctx.stroke(keep)
            ctx.setLineDash(phase: 0, lengths: [])
        }
        if a.tool == .select, let i = a.selected, a.doc.marks.indices.contains(i) {
            let b = a.doc.marks[i].bounds
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5 / l.scale)
            ctx.setLineDash(phase: 0, lengths: [4 / l.scale, 3 / l.scale])
            ctx.stroke(CGRect(x: b.x, y: b.y, width: b.w, height: b.h).insetBy(dx: -4 / l.scale, dy: -4 / l.scale))
        }
        ctx.restoreGState()
    }

    override func resetCursorRects() {
        let l = layout
        let img = NSRect(x: l.origin.x, y: l.origin.y, width: Double(a.original.width) * l.scale, height: Double(a.original.height) * l.scale)
        let cursor: NSCursor
        switch a.tool {
        case .select: cursor = .arrow
        case .mark(.text): cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(img, cursor: cursor)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        repositionTextField()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = clampToImage(toImage(convert(event.locationInWindow, from: nil)))
        if textField != nil {
            endTextEditing(commit: true)
            if case .mark(.text) = a.tool { return }
        }
        switch a.tool {
        case .select:
            a.selected = a.doc.marks.indices.reversed().first { a.doc.marks[$0].hit(p, tolerance: 6 / layout.scale) }
            // The slider shows the selected mark's opacity, so it can be changed from there.
            if let i = a.selected { a.opacity = a.doc.marks[i].opacity ?? 1 }
            moveFrom = a.selected == nil ? nil : p
            moved = false
            if event.clickCount == 2, let i = a.selected, a.doc.marks[i].tool == .text { beginTextEditing(at: a.doc.marks[i].points[0], editing: i) }
        case .crop:
            dragStart = p
            cropDraft = nil
        case .mark(let t):
            switch t {
            case .text:
                beginTextEditing(at: p, editing: nil)
            case .counter:
                let n = a.doc.nextCounter
                a.commit { $0.marks.append(Mark(tool: .counter, points: [p], color: a.color, width: a.width, number: n, opacity: a.markOpacity)) }
            default:
                dragStart = p
                draft = Mark(tool: t, points: t.isPath ? [p] : [p, p], color: t == .pixelate ? "#000000" : a.color, width: t == .highlighter ? a.width * 4 : a.width, opacity: t == .pixelate ? nil : a.markOpacity)
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let raw = clampToImage(toImage(convert(event.locationInWindow, from: nil)))
        switch a.tool {
        case .select:
            guard let i = a.selected, let from = moveFrom else { return }
            if !moved { a.commit { _ in } }
            moved = true
            a.doc.marks[i] = a.doc.marks[i].moved(dx: raw.x - from.x, dy: raw.y - from.y)
            moveFrom = raw
        case .crop:
            guard let s = dragStart else { return }
            cropDraft = Box.spanning(s, raw)
        case .mark(let t):
            guard var d = draft, let s = dragStart else { return }
            if t.isPath {
                d.points.append(raw)
            } else {
                d.points[1] = event.modifierFlags.contains(.shift) ? Geometry.constrain(s, raw, tool: t) : raw
            }
            draft = d
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; moveFrom = nil; needsDisplay = true }
        switch a.tool {
        case .crop:
            if let c = cropDraft, c.w >= 8, c.h >= 8 {
                a.commit { $0.crop = c }
            } else if a.doc.crop != nil {
                a.commit { $0.crop = nil } // a click with the crop tool removes the crop
            }
            cropDraft = nil
        case .mark(let t):
            guard var d = draft else { return }
            draft = nil
            if t.isPath {
                d.points = Geometry.simplify(d.points, minStep: max(1, 1.5 / layout.scale))
                a.commit { $0.marks.append(d) }
            } else if Geometry.dist(d.points[0], d.points[1]) >= 4 / layout.scale {
                a.commit { $0.marks.append(d) }
            }
        default:
            break
        }
    }

    // MARK: - keys

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let cmd = event.modifierFlags.contains(.command)
        if cmd {
            if chars == "z" { event.modifierFlags.contains(.shift) ? a.redo() : a.undo(); return }
            if event.keyCode == 51, a.isNew { a.discard(); return }
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 53: // Esc
            if draft != nil || cropDraft != nil { draft = nil; cropDraft = nil; needsDisplay = true } else { a.skip() }
            return
        case 36, 76: a.done(); return
        case 51, 117: a.deleteSelected(); needsDisplay = true; return
        default: break
        }
        if let c = chars.first {
            if let t = Annotator.Tool.all.first(where: { $0.key == c }) { a.setTool(t); return }
            if let n = c.wholeNumberValue, (1...Annotator.palette.count).contains(n) {
                a.color = Annotator.palette[n - 1]
                a.recolorSelected(a.color)
                return
            }
            if c == "," { a.setOpacity(a.opacity - 0.1); return }
            if c == "." { a.setOpacity(a.opacity + 0.1); return }
            if c == "[" { a.width = max(1, a.width - 1); return }
            if c == "]" { a.width = min(40, a.width + 1); return }
        }
        super.keyDown(with: event)
    }

    // MARK: - text marks

    func beginTextEditing(at p: Pt, editing index: Int?) {
        endTextEditing(commit: true)
        let size = index.map { a.doc.marks[$0].width } ?? max(18, a.width * 5)
        let f = NSTextField(string: index.flatMap { a.doc.marks[$0].text } ?? "")
        f.font = NSFont.systemFont(ofSize: size * layout.scale, weight: .bold)
        f.textColor = NSColor(hex: index.map { a.doc.marks[$0].color } ?? a.color)
        f.backgroundColor = NSColor.black.withAlphaComponent(0.25)
        f.drawsBackground = true
        f.isBordered = false
        f.focusRingType = .none
        f.delegate = self
        f.placeholderString = "Text"
        textAnchor = p
        editingIndex = index
        textField = f
        addSubview(f)
        repositionTextField()
        window?.makeFirstResponder(f)
        needsDisplay = true
    }

    private func repositionTextField() {
        guard let f = textField, let anchor = textAnchor else { return }
        f.sizeToFit()
        let origin = toView(anchor)
        f.frame = NSRect(x: origin.x, y: origin.y, width: max(f.frame.width + 30, 120), height: f.frame.height)
    }

    func controlTextDidChange(_ obj: Notification) { repositionTextField() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { endTextEditing(commit: true); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { endTextEditing(commit: false); return true }
        return false
    }

    func endTextEditing(commit: Bool) {
        guard let f = textField, let p = textAnchor else { return }
        let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = editingIndex
        textField = nil
        textAnchor = nil
        editingIndex = nil
        f.removeFromSuperview()
        if commit {
            if let i = index {
                a.commit { d in if text.isEmpty { d.marks.remove(at: i) } else { d.marks[i].text = text } }
            } else if !text.isEmpty {
                let size = max(18, a.width * 5)
                a.commit { $0.marks.append(Mark(tool: .text, points: [p], color: a.color, width: size, text: text, opacity: a.markOpacity)) }
            }
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}
