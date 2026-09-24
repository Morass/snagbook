import AppKit
import SnagbookCore
import SnagbookRender
import SwiftUI

/// The capture workflow: pick a region, record it or photograph it, and file the result
/// into the current item. Driven by the global shortcuts, the menu, the toolbar and the
/// little control strip under the region.
@MainActor
final class CaptureController: ObservableObject {
    enum Intent { case record, shoot }
    enum Phase: Equatable { case idle, picking, recording, saving }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var target: CaptureTarget?
    @Published private(set) var recordingStarted: Date?

    unowned let model: AppModel
    private let overlay = RegionOverlay()
    private var recorder: Recorder?
    private var recordingFile: URL?
    private var recordingItem: Int?
    /// The notebook stepped aside for this capture and comes back when it is filed.
    private var restoreNotebook = false

    init(model: AppModel) {
        self.model = model
        overlay.controller = self
    }

    var isRecording: Bool { phase == .recording }

    var recordButtonTitle: String {
        switch phase {
        case .recording: return "Stop"
        case .saving: return "Saving…"
        default: return "Record"
        }
    }

    // MARK: - entry points

    /// Record: drag a rectangle and recording starts. Again (or Stop): stop and file it.
    func recordAction() {
        switch phase {
        case .idle: pick(.record)
        case .picking: cancel()
        case .recording: stopRecording()
        case .saving: break
        }
    }

    /// Screenshot: drag a rectangle and it is taken. While recording: the recorded area.
    func screenshotAction() {
        switch phase {
        case .idle: pick(.shoot)
        case .recording: if let target { shoot(target) }
        case .picking, .saving: break
        }
    }

    func pick(_ intent: Intent) {
        guard Permissions.ensureScreenRecording(model) else { return }
        phase = .picking
        // Started from the notebook: step aside so whatever is behind it can be selected.
        if NSApp.isActive, let w = WindowPlacement.notebook, w.isVisible {
            restoreNotebook = true
            w.orderOut(nil)
            NSApp.deactivate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.overlay.startPicking(intent: intent) }
        } else {
            overlay.startPicking(intent: intent)
        }
    }

    /// Called by the overlay when the rectangle is drawn.
    func picked(_ t: CaptureTarget, intent: Intent) {
        target = t
        switch intent {
        case .record:
            phase = .idle
            startRecording(t)
        case .shoot:
            phase = .idle
            overlay.hideAll()
            // Let the overlay leave the screen before the picture is taken.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.shoot(t) }
        }
    }

    func cancel() {
        switch phase {
        case .recording: stopRecording()
        default:
            phase = .idle
            target = nil
            overlay.hideAll()
            bringNotebookBack()
        }
    }

    /// True once: the caller should show the notebook again (the mark-up window asks).
    func takeRestoreNotebook() -> Bool {
        defer { restoreNotebook = false }
        return restoreNotebook
    }

    private func bringNotebookBack() {
        if takeRestoreNotebook() { WindowPlacement.show() }
    }

    // MARK: - screenshot

    func shoot(_ t: CaptureTarget) {
        Task {
            do {
                let image = try await ScreenGrabber.screenshot(t)
                model.screenshotTaken(image, source: t.summary)
                if !model.config.capture.annotateScreenshots { bringNotebookBack() }
            } catch {
                bringNotebookBack()
                model.show(error)
            }
        }
    }

    // MARK: - recording

    func startRecording(_ t: CaptureTarget) {
        guard phase == .idle else { return }
        let id: Int
        do { id = try model.ensureItem() } catch { return model.show(error) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Snagbook-recording-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("recording.mp4")
        let rec = Recorder()
        rec.onError = { [weak self] error in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                self.model.show(error)
                self.stopRecording()
            }
        }
        recorder = rec
        recordingFile = file
        recordingItem = id
        phase = .recording
        recordingStarted = Date()
        overlay.showRecording(t)
        Task {
            do {
                try await rec.start(t, settings: model.config.capture, to: file)
            } catch {
                recorder = nil
                phase = .idle
                recordingStarted = nil
                target = nil
                overlay.hideAll()
                try? FileManager.default.removeItem(at: dir)
                bringNotebookBack()
                model.show(error)
            }
        }
    }

    func stopRecording() {
        guard phase == .recording, let rec = recorder, let file = recordingFile, let item = recordingItem, let t = target else { return }
        phase = .saving
        overlay.showSaving()
        let settings = model.config.capture
        Task {
            defer {
                recorder = nil
                recordingStarted = nil
                try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            }
            do {
                let duration = try await rec.stop()
                let saved = try await fileRecording(file, into: item, target: t, settings: settings, duration: duration)
                model.recordingSaved(item: item, relative: saved, duration: duration)
            } catch {
                model.show(error)
            }
            phase = .idle
            target = nil
            overlay.hideAll()
            bringNotebookBack()
        }
    }

    /// Name the recording, write its stills beside it, and move all of it into the item.
    func fileRecording(_ recording: URL, into item: Int, target t: CaptureTarget, settings: CaptureSettings, duration: Double) async throws -> String {
        guard let session = model.session else { throw SnagError.noSuchItem(item) }
        let reserved = try session.reserveMediaName(item, prefix: "clip", ext: "mp4")
        let name = reserved.url.lastPathComponent
        let work = recording.deletingLastPathComponent()
        let named = work.appendingPathComponent(name)
        try FileManager.default.moveItem(at: recording, to: named)
        let info = try await VideoStills.write(for: named, fps: settings.fps, maxStills: settings.maxStills, source: t.summary, app: t.appName)
        let n = VideoStills.names(for: name)
        let media = reserved.url.deletingLastPathComponent()
        var moves = [(named, reserved.url), (work.appendingPathComponent(n.json), media.appendingPathComponent(n.json)),
                     (work.appendingPathComponent(n.frames), media.appendingPathComponent(n.frames))]
        if info.contactSheet != nil { moves.append((work.appendingPathComponent(n.sheet), media.appendingPathComponent(n.sheet))) }
        for (from, to) in moves {
            try? FileManager.default.removeItem(at: to)
            try FileManager.default.moveItem(at: from, to: to)
        }
        return reserved.relative
    }
}

// MARK: - the strip of controls under the region

struct CapturePill: View {
    @ObservedObject var capture: CaptureController

    var body: some View {
        HStack(spacing: 6) {
            switch capture.phase {
            case .recording:
                Button { capture.stopRecording() } label: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 9, height: 9)
                        if let start = capture.recordingStarted {
                            TimelineView(.periodic(from: start, by: 1)) { ctx in
                                Text(CaptureMath.duration(ctx.date.timeIntervalSince(start))).monospacedDigit()
                            }
                        }
                    }
                }
                .buttonStyle(PillButton(tint: .red))
                .help("Stop (⌃⌘R)")
                Button { capture.screenshotAction() } label: { Image(systemName: "camera") }.buttonStyle(PillButton()).help("Screenshot (⌃⌘S)")
            case .saving:
                ProgressView().controlSize(.small)
                Text("Saving…").foregroundStyle(.white)
            default:
                EmptyView()
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.78)))
        .overlay(Capsule().stroke(Color.white.opacity(0.15)))
        .fixedSize()
    }
}

struct PillButton: ButtonStyle {
    var tint: Color = .white.opacity(0.14)
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(configuration.isPressed ? tint.opacity(0.6) : tint))
    }
}
