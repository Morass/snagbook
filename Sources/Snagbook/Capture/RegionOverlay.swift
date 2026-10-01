import AppKit
import SnagbookCore
import SwiftUI

/// The on-screen parts of capturing: the dimmed picker, the frame around a chosen region
/// and the control strip under it. Every window here is a non-activating panel that joins
/// every Space, so it shows over a full-screen game without taking focus away from it.
/// None of it ends up in a capture: the capture filter leaves out all of Snagbook's windows.
@MainActor
final class RegionOverlay {
    weak var controller: CaptureController?
    private var pickers: [PickerPanel] = []
    private var frame: OverlayPanel?
    private var pill: OverlayPanel?

    static func panel(_ rect: NSRect) -> OverlayPanel {
        let p = OverlayPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        return p
    }

    // MARK: - picking

    func startPicking(intent: CaptureController.Intent) {
        hideAll()
        for screen in NSScreen.screens {
            let p = PickerPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .screenSaver
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.acceptsMouseMovedEvents = true
            let view = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.screen = screen
            view.intent = intent
            view.onPick = { [weak self] t in self?.controller?.picked(t, intent: intent) }
            view.onCancel = { [weak self] in self?.controller?.cancel() }
            p.contentView = view
            p.setFrame(screen.frame, display: true)
            p.orderFrontRegardless()
            pickers.append(p)
        }
        // The panel under the mouse takes the keys (Esc, F, Return) without activating us.
        let mouse = NSEvent.mouseLocation
        (pickers.first { $0.frame.contains(mouse) } ?? pickers.first)?.makeKey()
        NSCursor.crosshair.set()
    }

    // MARK: - placed / recording

    func showRecording(_ t: CaptureTarget, recording: Bool = true) {
        closePickers()
        let border: CGFloat = recording ? 3 : 2
        let outer = t.rect.insetBy(dx: -border - 1, dy: -border - 1)
        if frame == nil {
            let f = Self.panel(outer)
            f.ignoresMouseEvents = true
            f.contentView = FrameView(frame: NSRect(origin: .zero, size: outer.size))
            frame = f
        }
        if let f = frame, let v = f.contentView as? FrameView {
            f.setFrame(outer, display: false)
            v.frame = NSRect(origin: .zero, size: outer.size)
            v.recording = recording
            v.border = border
            v.needsDisplay = true
            f.orderFrontRegardless()
        }
        showPill(near: t)
    }

    func showSaving() {
        if let v = frame?.contentView as? FrameView {
            v.recording = false
            v.needsDisplay = true
        }
        if let t = controller?.target { showPill(near: t) }
    }

    private func showPill(near t: CaptureTarget) {
        guard let controller else { return }
        if pill == nil {
            let p = Self.panel(NSRect(x: 0, y: 0, width: 300, height: 40))
            p.becomesKeyOnlyIfNeeded = true
            p.ignoresMouseEvents = false
            let host = FirstMouseHostingView(rootView: CapturePill(capture: controller))
            p.contentView = host
            pill = p
        }
        guard let p = pill, let host = p.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        // Below the region if there is room, else above it, else inside its bottom edge.
        let screen = t.screenFrame
        var origin = NSPoint(x: t.rect.midX - size.width / 2, y: t.rect.minY - size.height - 10)
        if origin.y < screen.minY + 4 { origin.y = t.rect.maxY + 10 }
        if origin.y + size.height > screen.maxY - 4 { origin.y = t.rect.minY + 12 }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        p.orderFrontRegardless()
    }

    var stopControlAcceptsClick: Bool {
        guard let pill, let view = pill.contentView else { return false }
        return pill.isVisible && !pill.ignoresMouseEvents && view.acceptsFirstMouse(for: nil)
    }

    func hideAll() {
        closePickers()
        frame?.orderOut(nil)
        pill?.orderOut(nil)
    }

    private func closePickers() {
        for p in pickers { p.orderOut(nil) }
        pickers.removeAll()
        NSCursor.arrow.set()
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The border drawn around a chosen region: dashed while waiting, red while recording.
final class FrameView: NSView {
    var recording = false
    var border: CGFloat = 2

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: border / 2 + 0.5, dy: border / 2 + 0.5)
        let path = NSBezierPath(rect: r)
        path.lineWidth = border
        if recording {
            NSColor.systemRed.setStroke()
            path.stroke()
        } else {
            NSColor.black.withAlphaComponent(0.55).setStroke()
            path.stroke()
            path.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.white.setStroke()
            path.stroke()
        }
    }
}

/// Full-screen view in which the user drags out the rectangle to capture. Nothing else:
/// no window picking, no remembered region. Esc cancels; F takes the whole screen.
final class PickerView: NSView {
    var screen: NSScreen!
    var intent: CaptureController.Intent = .record
    var onPick: ((CaptureTarget) -> Void)?
    var onCancel: (() -> Void)?

    private var start: NSPoint?
    private var current: NSPoint?
    private var mouse: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    var selection: CGRect? {
        guard let s = start, let c = current else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        defer { start = nil; current = nil; needsDisplay = true }
        // A click, or a rectangle too small to be meant, does nothing: drag again.
        guard let sel = selection, sel.width >= 8, sel.height >= 8 else { return }
        pick(sel.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY), kind: "region")
    }

    private func pick(_ globalRect: CGRect, kind: String) {
        let b = RegionMath.snapped(Box(globalRect), scale: screen.backingScaleFactor, bounds: Box(screen.frame))
        let r = CGRect(x: b.x, y: b.y, width: b.w, height: b.h)
        onPick?(CaptureTarget(rect: r, displayID: screen.displayID, screenFrame: screen.frame, scale: screen.backingScaleFactor, kind: kind, appName: nil))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return } // Esc
        if event.charactersIgnoringModifiers?.lowercased() == "f" { pick(screen.frame, kind: "screen"); return }
        super.keyDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        if let hole = selection, hole.width > 0, hole.height > 0 {
            path.append(NSBezierPath(rect: hole))
            path.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.32).setFill()
        path.fill()

        if let sel = selection, sel.width > 0 {
            let p = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
            p.lineWidth = 1.5
            (intent == .record ? NSColor.systemRed : NSColor.white).setStroke()
            p.stroke()
            let px = (Int(sel.width * screen.backingScaleFactor), Int(sel.height * screen.backingScaleFactor))
            label("\(px.0) × \(px.1)", at: NSPoint(x: sel.maxX, y: sel.minY - 22), alignRight: true)
        } else if let m = mouse {
            // crosshair guides make "start here" obvious
            NSColor.white.withAlphaComponent(0.35).setStroke()
            let g = NSBezierPath()
            g.move(to: NSPoint(x: m.x, y: 0)); g.line(to: NSPoint(x: m.x, y: bounds.maxY))
            g.move(to: NSPoint(x: 0, y: m.y)); g.line(to: NSPoint(x: bounds.maxX, y: m.y))
            g.lineWidth = 1
            g.stroke()
        }
        hint()
    }

    private func label(_ text: String, at p: NSPoint, alignRight: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        var r = NSRect(x: alignRight ? p.x - size.width - 12 : p.x, y: p.y, width: size.width + 12, height: size.height + 6)
        r.origin.x = min(max(r.minX, 4), bounds.maxX - r.width - 4)
        r.origin.y = min(max(r.minY, 4), bounds.maxY - r.height - 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        s.draw(at: NSPoint(x: r.minX + 6, y: r.minY + 3))
    }

    private func hint() {
        guard start == nil, screen.frame.contains(NSEvent.mouseLocation) else { return }
        let text = intent == .record
            ? "Drag a rectangle — recording starts when you let go  ·  Esc cancel"
            : "Drag a rectangle to screenshot  ·  Esc cancel"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        let r = NSRect(x: bounds.midX - size.width / 2 - 14, y: bounds.maxY - 90, width: size.width + 28, height: size.height + 14)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
        s.draw(at: NSPoint(x: r.minX + 14, y: r.minY + 7))
    }
}
