import AppKit
import SnagbookCore
import SnagbookRender
import SwiftUI

/// The capture workflow: pick a region, record it or photograph it, and file the result
/// into the current item. Driven by the global shortcuts, the menu, the toolbar and the
/// little control strip under the region.
@MainActor
final class CaptureController: ObservableObject {
    enum Intent { case place, shoot }
    enum Phase: Equatable { case idle, picking, placed, recording, saving }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var target: CaptureTarget?
    @Published private(set) var recordingStarted: Date?
    /// The last region used, offered again (Return) the next time a region is picked.
    private(set) var lastTarget: CaptureTarget?

    unowned let model: AppModel
    private let overlay = RegionOverlay()
    private var recorder: Recorder?
    private var recordingFile: URL?
    private var recordingItem: Int?

    init(model: AppModel) {
        self.model = model
        overlay.controller = self
    }

    var isRecording: Bool { phase == .recording }

    var recordButtonTitle: String {
        switch phase {
        case .recording: return "Stop"
        case .placed: return "Start Recording"
        case .saving: return "Saving…"
        default: return "Record"
        }
    }

    // MARK: - entry points

    /// ⌃⌘R: pick a region; again: record it; again: stop.
    func recordAction() {
        switch phase {
        case .idle: pick(.place)
        case .picking: cancel()
        case .placed: startRecording()
        case .recording: stopRecording()
        case .saving: break
        }
    }

    /// ⌃⌘S: photograph the placed region (also while recording), or pick one and shoot.
    func screenshotAction() {
        switch phase {
        case .idle: pick(.shoot)
        case .picking: break
        case .placed, .recording: if let target { shoot(target) }
        case .saving: break
        }
    }

    func pick(_ intent: Intent) {
        guard Permissions.ensureScreenRecording(model) else { return }
        phase = .picking
        overlay.startPicking(intent: intent, suggestion: lastTarget)
    }

    /// Called by the overlay when the user has chosen.
    func picked(_ t: CaptureTarget, intent: Intent) {
        target = t
        lastTarget = t
        switch intent {
        case .place:
            phase = .placed
            overlay.showPlaced(t, recording: false)
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
        }
    }

    func reselect() {
        overlay.hideAll()
        phase = .idle
        pick(.place)
    }

    // MARK: - screenshot

    func shoot(_ t: CaptureTarget) {
        Task {
            do {
                let image = try await ScreenGrabber.screenshot(t)
                model.screenshotTaken(image, source: t.summary)
            } catch {
                model.show(error)
            }
        }
    }

    // MARK: - recording

    func startRecording() {
        guard let t = target, phase == .placed else { return }
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
        overlay.showPlaced(t, recording: true)
        Task {
            do {
                try await rec.start(t, settings: model.config.capture, to: file)
            } catch {
                recorder = nil
                phase = .placed
                recordingStarted = nil
                overlay.showPlaced(t, recording: false)
                try? FileManager.default.removeItem(at: dir)
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
                Button { capture.startRecording() } label: {
                    HStack(spacing: 5) { Circle().fill(.red).frame(width: 9, height: 9); Text("Record") }
                }
                .buttonStyle(PillButton()).help("Start recording (⌃⌘R)")
                Button { capture.screenshotAction() } label: { Label("Shot", systemImage: "camera") }.buttonStyle(PillButton()).help("Screenshot (⌃⌘S)")
                Button { capture.reselect() } label: { Image(systemName: "rectangle.dashed") }.buttonStyle(PillButton()).help("Select again")
                if let t = capture.target {
                    Text("\(t.pixelSize.width)×\(t.pixelSize.height)").font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                }
                Button { capture.cancel() } label: { Image(systemName: "xmark") }.buttonStyle(PillButton()).help("Close (Esc)")
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
