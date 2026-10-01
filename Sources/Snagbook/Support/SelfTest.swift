import AppKit
import AVFoundation
import KeyboardShortcuts
import SnagbookCore
import SnagbookRender
import WebKit

/// End-to-end checks against the real app, run with SNAGBOOK_SELFTEST=1 and a throwaway
/// SNAGBOOK_CONFIG. They drive the real editor page, the real file layout, the mark-up
/// window and the recording pipeline (with generated frames), then exit 0 or 1.
/// SNAGBOOK_SCREENSHOT=<file.png> also saves a picture of the window.
@MainActor
enum SelfTest {
    static var failures: [String] = []

    static func runIfRequested(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard env["SNAGBOOK_SELFTEST"] != nil || env["SNAGBOOK_SCREENSHOT"] != nil else { return }
        guard env["SNAGBOOK_CONFIG"] != nil else {
            print("SELFTEST refuses to run without SNAGBOOK_CONFIG pointing at a throwaway settings file")
            exit(2)
        }
        model.pasteboard = NSPasteboard(name: NSPasteboard.Name("snagbook-selftest-\(getpid())"))
        Task {
            // Give the window and the page a moment.
            for _ in 0..<100 where !(await pageReady(model)) { try? await Task.sleep(nanoseconds: 100_000_000) }
            if env["SNAGBOOK_SELFTEST"] != nil {
                await run(model)
                await interactions(model)
            }
            if let shot = env["SNAGBOOK_SCREENSHOT"] { await screenshot(model, to: shot) }
            model.pasteboard.releaseGlobally()
            if failures.isEmpty {
                print("SELFTEST PASS")
                exit(0)
            }
            print("SELFTEST FAIL")
            for f in failures { print("  - \(f)") }
            exit(1)
        }
    }

    static func pageReady(_ model: AppModel) async -> Bool {
        (await model.editor.evaluate("typeof snag === 'object'") as? Bool) == true
    }

    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "ok   " : "FAIL ") + what)
        if !ok { failures.append(what) }
    }

    static func read(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }
    static func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }
    static func settle(_ ms: UInt64 = 400) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    static func js(_ model: AppModel, _ code: String) async -> Any? { await model.editor.evaluate(code) }

    static func run(_ model: AppModel) async {
        // 0. Shortcut hints: tooltips come quickly and name the shortcut as it is set now.
        check(UserDefaults.standard.integer(forKey: SnagbookApp.toolTipDelayKey) <= SnagbookApp.toolTipDelay, "tooltips appear within \(SnagbookApp.toolTipDelay) ms")
        let rec = KeyboardShortcuts.getShortcut(for: .record)?.description ?? ""
        check(tip("Record", KeyboardShortcuts.Name.record.hint, then: "drag").hasPrefix("Record  \(rec) — ") && !rec.isEmpty, "the Record tooltip leads with its shortcut: \(rec)")
        check(tip("Stop", "") == "Stop", "a cleared shortcut leaves no stray separator")

        // 1. A session and its first item.
        let before = model.session?.url
        model.newSession()
        for _ in 0..<50 where model.session?.url == before || model.selectedID == nil { await settle(100) }
        guard var session = model.session, session.url != before, let first = model.selectedID else {
            return check(false, "new session creates a session with a first item")
        }
        check(session.url.lastPathComponent.range(of: #"^[0-9a-f]{8}_\d\d-\d\d-\d{4}$"#, options: .regularExpression) != nil, "session folder is hash_dd-mm-yyyy: \(session.url.lastPathComponent)")
        check(model.titleDraft == "Item 1", "first item is called Item 1")

        // 2. Rename moves the folder.
        model.titleDraft = "Main menu"
        model.commitTitle()
        check(exists(session.url.appendingPathComponent("01-main-menu/notes.md")), "renaming the item renames its folder")
        session = model.session!

        // 3. Typing is saved without a Save command.
        await settle()
        _ = await js(model, "snag.focus(); snag.typeText('The logo overlaps the Start button.')")
        await settle(700)
        let noteURL = try! session.noteURL(first)
        check(read(noteURL).contains("The logo overlaps the Start button."), "typed text reaches notes.md by itself")

        // 4. A template types its text at the caret.
        if let bug = model.config.templates.first(where: { $0.label == "Bug" }) {
            model.insertTemplate(bug)
            _ = await js(model, "snag.typeText('menu flickers')")
            _ = await model.editor.flush()
            check(read(noteURL).contains("**Bug:** menu flickers"), "the Bug template inserts **Bug:**")
        } else {
            check(false, "default templates include Bug")
        }

        // 5. A pasted picture becomes a file beside the note.
        let png = ImageFile.pngData(testImage(320, 200, hue: 0.6))!
        model.insertImageData(png)
        await settle()
        _ = await model.editor.flush()
        check(exists(try! session.mediaURL(first).appendingPathComponent("image-001.png")), "pasted picture saved as media/image-001.png")
        check(read(noteURL).contains("![](media/image-001.png)"), "pasted picture is linked in the note")

        // 6. The editor loads media through its own scheme, byte ranges included.
        let loaded = await evalAsync(model, """
            const load = (src) => new Promise((ok) => { const i = new Image(); i.onload = () => ok(i.naturalWidth); i.onerror = () => ok(-1); i.src = src; });
            return [await load('snagbook://item/\(first)/media/image-001.png'), await load('snagbook://item/\(first)/media/../../README.md'), await load('snagbook://item/999/media/image-001.png')].join(',');
            """) as? String ?? ""
        check(loaded.hasPrefix("320,"), "the editor loads the picture through its media URL (\(loaded))")
        check(loaded.hasSuffix(",-1,-1"), "media URLs refuse paths outside the item and unknown items")

        // 7. A screenshot goes through the mark-up window and keeps its original.
        _ = try? model.screenshotTaken(testImage(400, 240, hue: 0.1), source: "selftest")
        await settle()
        if let a = Annotator.open.last {
            a.commit { $0.marks.append(Mark(tool: .ellipse, points: [Pt(40, 40), Pt(200, 160)], color: "#ff3b30", width: 6)) }
            a.commit { $0.marks.append(Mark(tool: .text, points: [Pt(220, 60)], color: "#ff3b30", width: 24, text: "here")) }
            a.done()
            for _ in 0..<50 where Annotator.open.contains(where: { $0 === a }) { await settle(100) }
            _ = await model.editor.flush()
            let media = try! session.mediaURL(first)
            check(exists(media.appendingPathComponent("shot-001.png")), "marked-up screenshot saved")
            check(exists(media.appendingPathComponent("shot-001.orig.png")), "original kept beside it")
            check(exists(media.appendingPathComponent("shot-001.marks.json")), "marks kept beside it")
            let orig = ImageFile.load(media.appendingPathComponent("shot-001.orig.png"))
            let rendered = ImageFile.load(media.appendingPathComponent("shot-001.png"))
            check(orig != nil && rendered != nil && pixel(rendered!, 40, 100) != pixel(orig!, 40, 100), "the marks are drawn into the saved picture")
            check(read(noteURL).contains("![](media/shot-001.png)"), "screenshot is linked in the note")
            // Re-open it and remove the marks: the picture goes back to the original.
            Annotator.open(item: first, relative: "media/shot-001.png", isNew: false, model: model)
            await settle()
            if let again = Annotator.open.last {
                check(again.doc.marks.count == 2, "re-opening restores the marks")
                again.commit { $0.marks.removeAll() }
                again.done()
                await settle()
                check(!exists(media.appendingPathComponent("shot-001.orig.png")) && !exists(media.appendingPathComponent("shot-001.marks.json")), "removing every mark drops the companions")
            } else {
                check(false, "double-click path re-opens the mark-up window")
            }
        } else {
            check(false, "a screenshot opens the mark-up window")
        }

        // 8. A recording, with generated frames, lands with its stills and contact sheet.
        do {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("snagbook-selftest-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let file = work.appendingPathComponent("recording.mp4")
            let w = try VideoWriter(url: file, width: 640, height: 360, fps: 15, withAudio: false)
            for i in 0..<45 {
                let img = testImage(640, 360, hue: Double(i) / 45)
                if let pb = pixelBuffer(img) { w.append(pixels: pb, at: CMTime(value: CMTimeValue(i), timescale: 15)) }
            }
            let duration = try await w.finish()
            let target = CaptureTarget(rect: CGRect(x: 0, y: 0, width: 320, height: 180), displayID: CGMainDisplayID(), screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2, kind: "region")
            let recordingSession = try Session.open(session.url.path, fallbackHeader: model.config.header)
            guard let recordingItemIdentity = try recordingSession.itemIdentity(first) else { throw SnagError.noSuchItem(first) }
            model.openSession(session.displayPath)
            for _ in 0..<30 where model.session === session { await settle(100) }
            let renamedOutside = recordingSession.url.appendingPathComponent("01-renamed-outside")
            try FileManager.default.moveItem(at: try recordingSession.itemURL(first), to: renamedOutside)
            let saved = try await model.capture.fileRecording(file, into: first, session: recordingSession, itemIdentity: recordingItemIdentity, target: target, settings: model.config.capture, duration: duration)
            let rel = saved.relative
            let elsewhere = try model.addItem(title: "Capture switched away", focusTitle: false)
            await settle()
            try model.recordingSaved(session: saved.session, item: first, relative: rel, duration: duration)
            try? FileManager.default.removeItem(at: work)
            await settle()
            _ = await model.editor.flush()
            let media = try! saved.session.mediaURL(first)
            check(rel == "media/clip-001.mp4" && exists(media.appendingPathComponent("clip-001.mp4")), "recording saved as media/clip-001.mp4")
            check(exists(media.appendingPathComponent("clip-001-frames/0003.jpg")), "one still per second beside it")
            check(exists(media.appendingPathComponent("clip-001-contact.jpg")), "contact sheet beside it")
            check(read(media.appendingPathComponent("clip-001.json")).contains("\"duration\""), "clip-001.json describes it")
            check(read(try! saved.session.noteURL(first)).contains("[Video 0:03](media/clip-001.mp4)"), "a recording uses the current item folder and is linked there after the selection changes")
            check(model.session?.manifest.items.first(where: { $0.id == first })?.folder == "01-renamed-outside", "an external item rename is adopted before the recording enters the editor")
            model.rename(first, to: "Main menu restored")
            model.rename(first, to: "Main menu")
            await settle()
            if let current = model.session { session = current }
            model.delete(elsewhere, confirm: false)
            for _ in 0..<30 where model.items.contains(where: { $0.id == elsewhere }) { await settle(100) }
        } catch {
            check(false, "recording pipeline: \(error.localizedDescription)")
        }

        // 9. Back and forward between items.
        let itemCount = model.items.count
        model.newItemFromMenu()
        for _ in 0..<30 where model.items.count == itemCount { await settle(100) }
        let second = model.selectedID ?? -1
        if let current = model.session { session = current }
        check(second != first, "New Item selects the new item")
        _ = await js(model, "snag.focus(); snag.typeText('Second item text')")
        _ = await model.editor.flush()
        model.goBack()
        await settle()
        check(model.selectedID == first, "Back returns to the first item")
        let shown = await js(model, "snag.text()") as? String ?? ""
        check(shown.contains("The logo overlaps"), "the editor shows the first item's note after Back")
        model.goForward()
        await settle()
        check(model.selectedID == second, "Forward returns to the second item")

        // 10. A note changed on disk (by someone else) is shown fresh when reopened.
        model.goBack()
        await settle()
        let secondNote = try! session.noteURL(second)
        let raw = read(secondNote)
        try? raw.replacingOccurrences(of: "Second item text", with: "Edited by an agent").write(to: secondNote, atomically: true, encoding: .utf8)
        model.goForward()
        await settle()
        let shown2 = await js(model, "snag.text()") as? String ?? ""
        check(shown2.contains("Edited by an agent"), "an outside edit is picked up")

        // 11. README and hand-off.
        _ = await model.editor.flush()
        model.copyHandoff()
        await settle()
        let readme = read(session.url.appendingPathComponent("README.md"))
        check(readme.contains("## 1. Main menu") && readme.contains("](01-main-menu/media/shot-001.png)"), "README holds every item with links into its folder")
        let clip = model.pasteboard.string(forType: .string) ?? ""
        check(clip.contains(session.displayPath), "Copy Hand-off puts the session path on the clipboard: \(clip.prefix(80))")
        check(model.statusIsSuccess && model.status?.hasPrefix("Copied") == true, "Copy Hand-off says so in green")

        // 11b. Sessions have names and can be switched without restarting anything.
        model.renameSession("Inventory pass")
        check(model.session?.title == "Inventory pass" && Session.list(root: model.config.sessionsFolder).contains { $0.title == "Inventory pass" }, "a session can be named, and the list shows the name")
        let firstPath = session.displayPath
        model.newSession()
        for _ in 0..<30 where model.session?.displayPath == firstPath { await settle(100) }
        check(model.session?.displayPath != firstPath && model.selectedID != nil, "New Session switches to a fresh session with its first item")
        // A picture pasted here is named like one shown in the first session (item 1,
        // image-001.png); the editor must show this one, not the old one it has seen.
        model.insertImageData(ImageFile.pngData(testImage(200, 150, hue: 0.1))!)
        await settle(800)
        let shownWidths = await evalAsync(model, """
            const imgs = [...document.querySelectorAll('.ProseMirror img')].filter((i) => i.src.includes('image-001'));
            await Promise.all(imgs.map((i) => i.complete ? 0 : new Promise((ok) => { i.onload = i.onerror = ok; })));
            return imgs.map((i) => i.naturalWidth).join(',');
            """) as? String ?? ""
        check(shownWidths == "200", "a picture pasted in another session shows itself, not an earlier session's picture of the same name (\(shownWidths))")
        model.openSession(firstPath)
        for _ in 0..<30 where model.session?.displayPath != firstPath { await settle(100) }
        await settle()
        check(model.session?.title == "Inventory pass" && model.items.contains { $0.id == second }, "switching back reopens the named session where it was")

        // 12. Delete moves an item's folder away and forgets it.
        _ = await js(model, "snag.typeText(' pending before delete')")
        model.delete(second, confirm: false)
        await settle()
        check(!model.items.contains { $0.id == second } && !exists(secondNote.deletingLastPathComponent()), "delete removes the item and its folder")
        check(model.session?.manifest.items.contains(where: { $0.id == second }) == false, "deleting after a pending save updates the active manifest")
        let countBeforeReuse = model.items.count
        let reused = try? model.addItem(title: "Reused after delete", focusTitle: false)
        check(model.items.count == countBeforeReuse + 1 && reused.map { id in model.items.filter { $0.id == id }.count == 1 } == true, "a new item after deletion appears exactly once")
        if let reused { model.delete(reused, confirm: false); await settle() }

        // 13. Real screen capture, when this Mac allows it.
        if CGPreflightScreenCaptureAccess() {
            do {
                let screen = NSScreen.main!
                let t = CaptureTarget(rect: CGRect(x: screen.frame.minX + 100, y: screen.frame.minY + 100, width: 300, height: 200), displayID: screen.displayID, screenFrame: screen.frame, scale: screen.backingScaleFactor, kind: "region")
                let img = try await ScreenGrabber.screenshot(t)
                check(img.width == Int(300 * screen.backingScaleFactor), "real screenshot has the region's pixel size")
                let rec = Recorder()
                let out = FileManager.default.temporaryDirectory.appendingPathComponent("snagbook-live-\(UUID().uuidString).mp4")
                try await rec.start(t, settings: model.config.capture, to: out)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let d = try await rec.stop()
                check(d > 1.0, "real recording lasts as long as it ran (\(d) s)")
                try? FileManager.default.removeItem(at: out)

                model.capture.picked(t, intent: .record)
                if let active = model.selectedID {
                    model.delete(active, confirm: false)
                    check(model.items.contains(where: { $0.id == active }), "an item being recorded cannot be deleted and reused")
                }
                model.capture.stopRecording()
                let stopAccepted = model.capture.phase == .saving
                for _ in 0..<100 where model.capture.phase != .idle { await settle(100) }
                check(stopAccepted && model.capture.phase == .idle, "Stop pressed during recording startup still stops the recording")
            } catch {
                check(false, "real capture: \(error.localizedDescription)")
            }
        } else {
            print("skip real screen capture (no Screen Recording permission for this process)")
        }
    }

    // MARK: - mouse and keys, synthesised

    static func mouse(_ type: NSEvent.EventType, _ view: NSView, _ p: NSPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let inWindow = view.convert(p, to: nil)
        return NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    static func key(_ chars: String, code: UInt16, in view: NSView, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    static func interactions(_ model: AppModel) async {
        // The region picker: a drag becomes a region, a click does nothing, F is the screen.
        guard let screen = NSScreen.main else { return check(false, "a screen exists") }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        let picker = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        picker.screen = screen
        var picked: CaptureTarget?
        picker.onPick = { picked = $0 }
        var cancelled = false
        picker.onCancel = { cancelled = true }
        win.contentView = picker
        picker.mouseDown(with: mouse(.leftMouseDown, picker, NSPoint(x: 100, y: 100)))
        picker.mouseDragged(with: mouse(.leftMouseDragged, picker, NSPoint(x: 300, y: 250)))
        picker.mouseUp(with: mouse(.leftMouseUp, picker, NSPoint(x: 300.4, y: 250.4)))
        if let t = picked {
            check(t.kind == "region" && abs(t.rect.width - 200.5) <= 0.5 && abs(t.rect.minX - (screen.frame.minX + 100)) < 0.01, "dragging in the picker selects that region (\(t.rect))")
            check(abs(t.local.minY - (screen.frame.height - 250.5)) <= 0.5, "the region's top-left position is what the capture needs (\(t.local))")
        } else {
            check(false, "dragging in the picker selects a region")
        }
        picked = nil
        picker.mouseDown(with: mouse(.leftMouseDown, picker, NSPoint(x: 400, y: 400)))
        picker.mouseUp(with: mouse(.leftMouseUp, picker, NSPoint(x: 401, y: 401)))
        check(picked == nil, "a click without a drag picks nothing (no window picking)")
        picker.keyDown(with: key("f", code: 3, in: picker))
        check(picked?.kind == "screen" && picked?.rect == screen.frame, "F in the picker takes the whole screen")
        picker.keyDown(with: key("\u{1b}", code: 53, in: picker))
        check(cancelled, "Esc in the picker cancels")
        win.orderOut(nil)

        // Record goes straight from the drawn rectangle to recording (no second press).
        let c = model.capture
        check(c.recordButtonTitle == "Record", "the Record button says Record when idle")
        let controls = RegionOverlay()
        controls.controller = c
        controls.showRecording(CaptureTarget.screen(screen))
        check(controls.stopControlAcceptsClick, "the floating recording controls accept the first click")
        check(AppDelegate.terminationDecision(phase: .idle, saveFailed: true) == false, "a failed Stop and Save cancels quitting so its recovery message remains visible")
        controls.hideAll()

        // The mark-up canvas: drags draw, keys switch tools, Return saves.
        guard let session = model.session, let id = model.selectedID else { return check(false, "an item for the canvas test") }
        let rel = (try? session.saveMedia(id, data: ImageFile.pngData(testImage(600, 400, hue: 0.3))!, prefix: "shot", ext: "png")) ?? ""
        Annotator.open(item: id, relative: rel, isNew: true, model: model)
        await settle()
        guard let a = Annotator.open.last, let canvas = a.canvas else { return check(false, "the mark-up window opens for a new screenshot") }
        canvas.window?.setContentSize(NSSize(width: 900, height: 700))
        canvas.layoutSubtreeIfNeeded()
        await settle(200)
        check(a.tool == .mark(.highlighter) && a.color == Annotator.palette[1], "the mark-up window opens with the yellow highlighter")
        let start = canvas.toView(Pt(100, 100)), end = canvas.toView(Pt(300, 250))
        canvas.keyDown(with: key("o", code: 31, in: canvas))
        check(a.color == Annotator.palette[0], "the other tools start red")
        canvas.mouseDown(with: mouse(.leftMouseDown, canvas, start))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, end))
        canvas.mouseUp(with: mouse(.leftMouseUp, canvas, end))
        check(a.doc.marks.last?.tool == .ellipse, "O then a drag draws a circle")
        if let m = a.doc.marks.last {
            check(abs(m.points[0].x - 100) < 2 && abs(m.points[1].y - 250) < 2, "the circle sits where it was dragged, in picture pixels (\(m.points))")
        }
        canvas.keyDown(with: key("a", code: 0, in: canvas))
        canvas.mouseDown(with: mouse(.leftMouseDown, canvas, canvas.toView(Pt(400, 300))))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, canvas.toView(Pt(320, 200))))
        canvas.mouseUp(with: mouse(.leftMouseUp, canvas, canvas.toView(Pt(320, 200))))
        check(a.doc.marks.count == 2 && a.doc.marks[1].tool == .arrow, "A then a drag draws an arrow")
        canvas.keyDown(with: key("4", code: 21, in: canvas))
        check(a.color == Annotator.palette[3], "a digit picks a colour")
        canvas.keyDown(with: key("h", code: 4, in: canvas))
        check(a.color == Annotator.palette[1], "the highlighter keeps its own colour")
        canvas.keyDown(with: key("a", code: 0, in: canvas))
        check(a.color == Annotator.palette[3], "and the arrow keeps the colour picked for it")
        canvas.keyDown(with: key("z", code: 6, in: canvas, flags: .command))
        check(a.doc.marks.count == 1, "⌘Z undoes the last mark")
        canvas.keyDown(with: key("\r", code: 36, in: canvas))
        await settle()
        let media = (try? session.mediaURL(id)) ?? session.url
        let name = (rel as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        check(exists(media.appendingPathComponent(stem + ".marks.json")), "Return saves the marks")

        Annotator.open(item: id, relative: rel, isNew: false, model: model)
        await settle()
        if let renamed = Annotator.open.last {
            let originalTitle = model.itemTitle(id)
            renamed.commit { $0.marks.append(Mark(tool: .rect, points: [Pt(20, 20), Pt(90, 70)], color: "#ff3b30", width: 4)) }
            model.rename(id, to: "Annotated item")
            renamed.done()
            await settle()
            check(!Annotator.open.contains(where: { $0 === renamed }), "mark-up saves after its item is renamed")
            let movedMedia = (try? model.session?.mediaURL(id)) ?? media
            check(exists(movedMedia.appendingPathComponent(stem + ".marks.json")), "renamed item keeps the annotated picture")
            model.rename(id, to: originalTitle)
        } else {
            check(false, "the rename-during-mark-up window opens")
        }

        Annotator.open(item: id, relative: rel, isNew: false, model: model)
        await settle()
        if let originalReplaced = Annotator.open.last {
            let currentMedia = try! model.session!.mediaURL(id)
            let pristine = currentMedia.appendingPathComponent(stem + ".orig.png")
            let heldPristine = currentMedia.appendingPathComponent(".original.selftest.png")
            try? FileManager.default.moveItem(at: pristine, to: heldPristine)
            let stranger = ImageFile.pngData(testImage(600, 400, hue: 0.9))!
            try? stranger.write(to: pristine)
            originalReplaced.commit { $0.marks.append(Mark(tool: .ellipse, points: [Pt(30, 30), Pt(100, 90)], color: "#ff3b30", width: 4)) }
            originalReplaced.done()
            await settle()
            check(Annotator.open.contains(where: { $0 === originalReplaced }), "mark-up refuses a replacement original picture")
            check((try? Data(contentsOf: pristine)) == stranger, "mark-up leaves a replacement original picture unchanged")
            try? FileManager.default.removeItem(at: pristine)
            try? FileManager.default.moveItem(at: heldPristine, to: pristine)
            originalReplaced.skip()
            await settle()
        } else {
            check(false, "the replacement-original mark-up window opens")
        }

        let unchangedRel = (try? session.saveMedia(id, data: ImageFile.pngData(testImage(240, 160, hue: 0.35))!, prefix: "shot", ext: "png")) ?? ""
        Annotator.open(item: id, relative: unchangedRel, isNew: true, model: model)
        await settle()
        if let unchanged = Annotator.open.last {
            let picture = try! session.itemURL(id).appendingPathComponent(unchangedRel)
            let held = picture.deletingLastPathComponent().appendingPathComponent(".unchanged.selftest.png")
            try? FileManager.default.moveItem(at: picture, to: held)
            let stranger = Data("replacement picture".utf8)
            try? stranger.write(to: picture)
            unchanged.skip()
            for _ in 0..<50 where unchanged.finishing { await settle(100) }
            check(Annotator.open.contains(where: { $0 === unchanged }) && !read(try! session.noteURL(id)).contains(unchangedRel), "No Marks refuses to attach a replacement picture")
            check((try? Data(contentsOf: picture)) == stranger, "No Marks leaves a replacement picture unchanged")
            try? FileManager.default.removeItem(at: picture)
            try? FileManager.default.moveItem(at: held, to: picture)
            unchanged.skip()
            for _ in 0..<50 where Annotator.open.contains(where: { $0 === unchanged }) { await settle(100) }
            check(!Annotator.open.contains(where: { $0 === unchanged }) && read(try! session.noteURL(id)).contains(unchangedRel), "No Marks attaches the restored original picture")
        } else {
            check(false, "the unchanged-picture mark-up window opens")
        }

        let retryRel = (try? session.saveMedia(id, data: ImageFile.pngData(testImage(240, 160, hue: 0.4))!, prefix: "shot", ext: "png")) ?? ""
        Annotator.open(item: id, relative: retryRel, isNew: true, model: model)
        await settle()
        if let retry = Annotator.open.last {
            retry.commit { $0.marks.append(Mark(tool: .rect, points: [Pt(15, 15), Pt(90, 70)], color: "#ff3b30", width: 4)) }
            let elsewhere = try? model.addItem(title: "Attachment retry", focusTitle: false)
            let note = try! session.noteURL(id)
            let heldNote = note.deletingLastPathComponent().appendingPathComponent(".attachment.selftest.md")
            try? FileManager.default.moveItem(at: note, to: heldNote)
            check(retry.windowShouldClose(retry.canvas!.window!) == false && Annotator.open.contains(where: { $0 === retry }), "closing keeps a failed screenshot attachment available to retry")
            for _ in 0..<50 where retry.finishing { await settle(100) }
            retry.done()
            for _ in 0..<50 where retry.finishing { await settle(100) }
            check(Annotator.open.contains(where: { $0 === retry }), "a failed screenshot attachment keeps the picture open")
            try? FileManager.default.moveItem(at: heldNote, to: note)
            let readme = session.url.appendingPathComponent(Session.readmeName)
            let heldReadme = session.url.appendingPathComponent(".readme.selftest.md")
            try? FileManager.default.moveItem(at: readme, to: heldReadme)
            try? FileManager.default.createDirectory(at: readme, withIntermediateDirectories: false)
            retry.done()
            await settle()
            check(!Annotator.open.contains(where: { $0 === retry }) && read(note).contains(retryRel), "a durable screenshot link finishes attachment even if README refresh fails")
            try? FileManager.default.removeItem(at: readme)
            try? FileManager.default.moveItem(at: heldReadme, to: readme)
            try? model.session?.writeReadme()
            if let elsewhere { model.delete(elsewhere, confirm: false); await settle() }
        } else {
            check(false, "the attachment-retry mark-up window opens")
        }

        model.select(id)
        await settle()
        let selectedRetryRel = (try? session.saveMedia(id, data: ImageFile.pngData(testImage(240, 160, hue: 0.6))!, prefix: "shot", ext: "png")) ?? ""
        Annotator.open(item: id, relative: selectedRetryRel, isNew: true, model: model)
        await settle()
        if let selectedRetry = Annotator.open.last {
            let note = try! session.noteURL(id)
            let heldNote = note.deletingLastPathComponent().appendingPathComponent(".selected-attachment.selftest.md")
            try? FileManager.default.moveItem(at: note, to: heldNote)
            selectedRetry.done()
            for _ in 0..<50 where selectedRetry.finishing { await settle(100) }
            check(Annotator.open.contains(where: { $0 === selectedRetry }), "a selected-item attachment waits for its note to save")
            try? FileManager.default.moveItem(at: heldNote, to: note)
            selectedRetry.done()
            for _ in 0..<50 where Annotator.open.contains(where: { $0 === selectedRetry }) { await settle(100) }
            check(!Annotator.open.contains(where: { $0 === selectedRetry }) && read(note).contains(selectedRetryRel), "a selected-item attachment closes only after its link is durable")
        } else {
            check(false, "the selected attachment-retry mark-up window opens")
        }

        let switchedRel = (try? session.saveMedia(id, data: ImageFile.pngData(testImage(240, 160, hue: 0.65))!, prefix: "shot", ext: "png")) ?? ""
        Annotator.open(item: id, relative: switchedRel, isNew: true, model: model)
        await settle()
        if let switched = Annotator.open.last {
            switched.done()
            let other = try? model.addItem(title: "Attachment destination", focusTitle: false)
            for _ in 0..<50 where Annotator.open.contains(where: { $0 === switched }) { await settle(100) }
            let sourceNote = try! session.noteURL(id)
            let otherNote = other.flatMap { try? model.session?.noteURL($0) }
            check(read(sourceNote).contains(switchedRel) && otherNote.map { !read($0).contains(switchedRel) } == true, "an attachment cannot cross an item switch")
            if let other { model.delete(other, confirm: false); await settle() }
            model.select(id)
            await settle()
        } else {
            check(false, "the item-switch attachment window opens")
        }

        let readmeRel = (try? session.saveMedia(id, data: ImageFile.pngData(testImage(240, 160, hue: 0.7))!, prefix: "shot", ext: "png")) ?? ""
        Annotator.open(item: id, relative: readmeRel, isNew: true, model: model)
        await settle()
        if let readmeFailure = Annotator.open.last {
            _ = await js(model, "snag.typeText(' retained through README failure')")
            let readme = session.url.appendingPathComponent(Session.readmeName)
            let heldReadme = session.url.appendingPathComponent(".selected-readme.selftest.md")
            try? FileManager.default.moveItem(at: readme, to: heldReadme)
            try? FileManager.default.createDirectory(at: readme, withIntermediateDirectories: false)
            readmeFailure.done()
            for _ in 0..<50 where Annotator.open.contains(where: { $0 === readmeFailure }) { await settle(100) }
            let durableNote = read(try! session.noteURL(id))
            check(!Annotator.open.contains(where: { $0 === readmeFailure }) && durableNote.contains(readmeRel) && durableNote.contains("retained through README failure"), "a selected attachment accepts a durable note and link when README refresh fails")
            try? FileManager.default.removeItem(at: readme)
            try? FileManager.default.moveItem(at: heldReadme, to: readme)
            try? model.session?.writeReadme()
        } else {
            check(false, "the selected README-failure mark-up window opens")
        }

        let discardRel = (try? session.saveMedia(id, data: ImageFile.pngData(testImage(240, 160, hue: 0.8))!, prefix: "shot", ext: "png")) ?? ""
        Annotator.open(item: id, relative: discardRel, isNew: true, model: model)
        await settle()
        if let discardAfterFailure = Annotator.open.last {
            discardAfterFailure.commit { $0.marks.append(Mark(tool: .rect, points: [Pt(15, 15), Pt(90, 70)], color: "#ff3b30", width: 4)) }
            let note = try! session.noteURL(id)
            let heldNote = note.deletingLastPathComponent().appendingPathComponent(".discard.selftest.md")
            try? FileManager.default.moveItem(at: note, to: heldNote)
            discardAfterFailure.done()
            for _ in 0..<50 where discardAfterFailure.finishing { await settle(100) }
            try? FileManager.default.moveItem(at: heldNote, to: note)
            let media = try! model.session!.mediaURL(id)
            let name = (discardRel as NSString).lastPathComponent
            let discardStem = (name as NSString).deletingPathExtension
            discardAfterFailure.discard()
            await settle()
            _ = await model.editor.flush()
            check(!exists(media.appendingPathComponent(name))
                  && !exists(media.appendingPathComponent(discardStem + ".orig.png"))
                  && !exists(media.appendingPathComponent(discardStem + ".marks.json"))
                  && !read(note).contains(discardRel), "discard after a failed attachment removes the picture, companions and pending link")
        } else {
            check(false, "the discard-after-failure mark-up window opens")
        }

        Annotator.open(item: id, relative: rel, isNew: false, model: model)
        await settle()
        if let rollback = Annotator.open.last {
            rollback.commit { $0.marks.removeAll() }
            let currentMedia = try! model.session!.mediaURL(id)
            let pristine = currentMedia.appendingPathComponent(stem + ".orig.png")
            try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: pristine.path)
            rollback.done()
            await settle()
            check(Annotator.open.contains(where: { $0 === rollback }), "a failed companion removal keeps the picture open")
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: pristine.path)
            rollback.done()
            await settle()
            check(!Annotator.open.contains(where: { $0 === rollback }), "companion removal retries after its original is writable")
        } else {
            check(false, "the companion-removal retry window opens")
        }

        let failedRel = (try? session.saveMedia(id, data: ImageFile.pngData(testImage(240, 160, hue: 0.7))!, prefix: "shot", ext: "png")) ?? ""
        Annotator.open(item: id, relative: failedRel, isNew: true, model: model)
        await settle()
        if let failed = Annotator.open.last {
            let failedURL = try! session.itemURL(id).appendingPathComponent(failedRel)
            let before = try? Data(contentsOf: failedURL)
            let failedStem = ((failedRel as NSString).lastPathComponent as NSString).deletingPathExtension
            let marksURL = try! session.mediaURL(id).appendingPathComponent(failedStem + ".marks.json")
            try? FileManager.default.createDirectory(at: marksURL, withIntermediateDirectories: false)
            failed.commit { $0.marks.append(Mark(tool: .ellipse, points: [Pt(10, 10), Pt(80, 60)], color: "#ff3b30", width: 4)) }
            failed.done()
            await settle()
            check(Annotator.open.contains(where: { $0 === failed }), "a failed mark-up save keeps the picture open")
            check((try? Data(contentsOf: failedURL)) == before, "a partially failed mark-up save leaves the picture unchanged")
            try? FileManager.default.removeItem(at: marksURL)
            failed.skip()
            await settle()
        } else {
            check(false, "the failure-path mark-up window opens")
        }

        let validationRel = (try? session.saveMedia(id, data: ImageFile.pngData(testImage(240, 160, hue: 0.5))!, prefix: "shot", ext: "png")) ?? ""
        Annotator.open(item: id, relative: validationRel, isNew: true, model: model)
        await settle()
        if let validation = Annotator.open.last {
            validation.commit { $0.marks.append(Mark(tool: .rect, points: [Pt(10, 10), Pt(80, 60)], color: "#ff3b30", width: 4)) }
            let manifest = session.url.appendingPathComponent(Session.manifestName)
            let heldManifest = session.url.appendingPathComponent(".session.selftest.json")
            try? FileManager.default.moveItem(at: manifest, to: heldManifest)
            validation.done()
            await settle()
            check(Annotator.open.contains(where: { $0 === validation }), "a failed session validation keeps unsaved marks open")
            try? FileManager.default.moveItem(at: heldManifest, to: manifest)
            validation.discard()
            await settle()
        } else {
            check(false, "the validation-failure mark-up window opens")
        }

        let replacedRel = (try? session.saveMedia(id, data: ImageFile.pngData(testImage(240, 160, hue: 0.2))!, prefix: "shot", ext: "png")) ?? ""
        Annotator.open(item: id, relative: replacedRel, isNew: false, model: model)
        await settle()
        if let replaced = Annotator.open.last {
            let picture = try! session.itemURL(id).appendingPathComponent(replacedRel)
            let heldPicture = picture.deletingLastPathComponent().appendingPathComponent(".picture.selftest.png")
            try? FileManager.default.moveItem(at: picture, to: heldPicture)
            let stranger = Data("replacement picture".utf8)
            try? stranger.write(to: picture)
            replaced.commit { $0.marks.append(Mark(tool: .rect, points: [Pt(10, 10), Pt(80, 60)], color: "#ff3b30", width: 4)) }
            replaced.done()
            await settle()
            check(Annotator.open.contains(where: { $0 === replaced }), "mark-up refuses a replacement picture at the same path")
            check((try? Data(contentsOf: picture)) == stranger, "mark-up does not overwrite a replacement picture")
            try? FileManager.default.removeItem(at: picture)
            try? FileManager.default.moveItem(at: heldPicture, to: picture)
            replaced.skip()
            await settle()
        } else {
            check(false, "the replacement-picture mark-up window opens")
        }

        let liveNote = try! session.noteURL(id)
        let heldNote = liveNote.deletingLastPathComponent().appendingPathComponent(".notes.selftest.md")
        try? FileManager.default.moveItem(at: liveNote, to: heldNote)
        try? FileManager.default.createDirectory(at: liveNote, withIntermediateDirectories: false)
        _ = await js(model, "snag.typeText(' retained after failed save')")
        check(await model.editor.flush() == false, "a failed editor flush refuses to discard the pending note")
        try? FileManager.default.removeItem(at: liveNote)
        try? FileManager.default.moveItem(at: heldNote, to: liveNote)
        check(await model.editor.flush(), "the pending note retries after its folder is repaired")
        check(read(liveNote).contains("retained after failed save"), "the retried note keeps the text from the failed save")

        let liveItem = try! session.itemURL(id)
        let moveSentinel = try? model.addItem(title: "Move sentinel", focusTitle: false)
        model.select(id)
        await settle()
        let orderBeforeReplacement = model.items.map(\.id)
        let heldItem = session.url.appendingPathComponent(".item.selftest")
        try? FileManager.default.moveItem(at: liveItem, to: heldItem)
        try? FileManager.default.createDirectory(at: liveItem, withIntermediateDirectories: false)
        let replacementNote = liveItem.appendingPathComponent(Session.noteName)
        try? "replacement item\n".write(to: replacementNote, atomically: true, encoding: .utf8)
        check(model.noteChanged(id: id, markdown: "must not cross item identity") == false, "autosave refuses a replacement item at the same path")
        check(read(replacementNote) == "replacement item\n", "a replacement item's note is not overwritten")
        let crossedPaste = model.savePasted(data: ImageFile.pngData(testImage(32, 32, hue: 0.1))!, mime: "image/png", name: "replacement.png")
        check(crossedPaste == nil && !exists(liveItem.appendingPathComponent("media")), "pasted media refuses a replacement item folder")
        model.titleDraft = "Must not rename replacement"
        model.commitTitle()
        check(exists(liveItem) && read(replacementNote) == "replacement item\n", "rename refuses a replacement item folder")
        model.delete(id, confirm: false)
        await settle()
        check(exists(liveItem), "delete refuses a replacement item folder")
        if let from = model.items.firstIndex(where: { $0.id == id }) {
            model.move(from: IndexSet(integer: from), to: from == 0 ? model.items.count : 0)
        }
        check(model.items.map(\.id) == orderBeforeReplacement, "reorder refuses a replacement item folder")
        do {
            _ = try model.capture.destinationForOpenedItem()
            check(false, "capture refuses a replacement item folder")
        } catch {
            check(true, "capture refuses a replacement item folder")
        }
        try? FileManager.default.removeItem(at: liveItem)
        try? FileManager.default.moveItem(at: heldItem, to: liveItem)
        if let moveSentinel { model.delete(moveSentinel, confirm: false); await settle() }

        // Closing the notebook window and showing it again brings it back.
        WindowPlacement.notebook?.performClose(nil)
        await settle()
        WindowPlacement.show()
        await settle(600)
        check(WindowPlacement.notebook?.isVisible == true, "the notebook comes back after its window was closed")

        model.newSession()
        let originalPath = session.displayPath
        for _ in 0..<30 where model.session?.displayPath == originalPath { await settle(100) }
        let disposable = model.session?.url
        _ = await js(model, "snag.typeText(' pending before session delete')")
        model.deleteSession(confirm: false)
        for _ in 0..<30 where model.session != nil { await settle(100) }
        check(model.session == nil && disposable.map { !exists($0) } == true, "session deletion still succeeds after flushing pending edits")
        model.openSession(originalPath)
        for _ in 0..<30 where model.session?.displayPath != originalPath { await settle(100) }

        // A read failure is not deletion: keep both the session and its unsaved editor text.
        let currentSession = model.session!
        let pendingID = model.selectedID!
        let manifestURL = currentSession.url.appendingPathComponent(Session.manifestName)
        let heldManifest = currentSession.url.appendingPathComponent(".manifest-unreadable-selftest")
        _ = await js(model, "snag.typeText(' pending while manifest unreadable')")
        try? FileManager.default.moveItem(at: manifestURL, to: heldManifest)
        model.refreshSessionFromDisk()
        check(model.session != nil, "an unreadable manifest leaves the session and pending note open")
        try? FileManager.default.moveItem(at: heldManifest, to: manifestURL)
        check(await model.editor.flush(), "the pending note saves after the manifest is readable again")
        check(read(try! currentSession.noteURL(pendingID)).contains("pending while manifest unreadable"), "a temporary manifest read failure loses no editor text")

        // A session removed elsewhere closes instead of being recreated by the next write.
        let deletedPath = session.displayPath
        _ = await js(model, "snag.typeText(' pending in removed session')")
        try? FileManager.default.removeItem(at: session.url)
        model.refreshSessionFromDisk()
        check(model.session == nil && !exists(session.url), "an open session deleted outside Snagbook is closed and stays deleted: \(deletedPath)")
        check(await model.editor.flush(), "an externally deleted session cannot leave an impossible save blocking recovery")
    }

    /// Run an async function body in the page and return its value.
    static func evalAsync(_ model: AppModel, _ body: String) async -> Any? {
        try? await model.editor.webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    }

    // MARK: - window picture

    static func screenshot(_ model: AppModel, to path: String) async {
        guard let win = WindowPlacement.notebook, let content = win.contentView else { return check(false, "window exists for the screenshot") }
        await settle(600)
        let bounds = content.bounds
        guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        content.cacheDisplay(in: bounds, to: rep)
        let web = model.editor.webView!
        let conf = WKSnapshotConfiguration()
        let snap = try? await web.takeSnapshot(configuration: conf)
        let img = NSImage(size: bounds.size)
        img.lockFocus()
        rep.draw(in: bounds)
        if let snap {
            let r = web.convert(web.bounds, to: content)
            let flipped = content.isFlipped ? NSRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height) : r
            snap.draw(in: flipped)
        }
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff), let png = bmp.representation(using: .png, properties: [:]) else {
            return check(false, "window picture encodes")
        }
        // A blank picture is a failure, not a screenshot: sample the editor pane.
        let cg = bmp.cgImage!
        var seen = Set<Int>()
        let r = web.convert(web.bounds, to: content)
        let scale = Double(cg.width) / Double(bounds.width)
        for y in stride(from: Int(r.minY * scale) + 20, to: Int(r.maxY * scale) - 20, by: 7) {
            for x in stride(from: Int(r.minX * scale) + 20, to: Int(r.maxX * scale) - 20, by: 11) {
                let p = pixel(cg, x, y)
                seen.insert(p.0 / 32 * 64 + p.1 / 32 * 8 + p.2 / 32)
            }
        }
        check(seen.count >= 4, "the editor pane in the window picture is not blank (\(seen.count) colours)")
        try? png.write(to: URL(fileURLWithPath: path))
        print("screenshot: \(path)")
    }

    // MARK: - helpers

    static func testImage(_ w: Int, _ h: Int, hue: Double) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let c = NSColor(hue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.35, brightness: 0.95, alpha: 1)
        ctx.setFillColor(c.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(NSColor(white: 0.2, alpha: 1).cgColor)
        ctx.fill(CGRect(x: w / 8, y: h / 3, width: w * 3 / 4, height: h / 6))
        return ctx.makeImage()!
    }

    static func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }

    static func pixelBuffer(_ img: CGImage) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, img.width, img.height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: img.width, height: img.height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return pb
    }
}
