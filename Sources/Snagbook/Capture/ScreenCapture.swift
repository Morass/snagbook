import AppKit
import AVFoundation
import ScreenCaptureKit
import SnagbookCore
import SnagbookRender

/// What to capture: a rectangle on one display.
struct CaptureTarget: Equatable {
    /// AppKit global points (origin bottom-left of the main display).
    var rect: CGRect
    var displayID: CGDirectDisplayID
    /// The display's frame in AppKit global points.
    var screenFrame: CGRect
    var scale: CGFloat
    /// "region", "screen" or "window"
    var kind: String
    /// For a window: its owner's name.
    var appName: String?

    /// The rectangle relative to its display, origin top-left, as the capture API wants it.
    var local: CGRect {
        let b = RegionMath.displayLocal(Box(rect), screen: Box(screenFrame))
        return CGRect(x: b.x, y: b.y, width: b.w, height: b.h)
    }

    var pixelSize: (width: Int, height: Int) {
        (Int((rect.width * scale).rounded()), Int((rect.height * scale).rounded()))
    }

    var summary: String {
        let p = pixelSize
        return kind == "window" ? "\(appName ?? "window") \(p.width)×\(p.height)" : "\(kind) \(p.width)×\(p.height)"
    }

    static func screen(_ s: NSScreen) -> CaptureTarget {
        CaptureTarget(rect: s.frame, displayID: s.displayID, screenFrame: s.frame, scale: s.backingScaleFactor, kind: "screen")
    }
}

extension Box {
    init(_ r: CGRect) { self.init(x: r.origin.x, y: r.origin.y, w: r.width, h: r.height) }
}

extension NSScreen {
    var displayID: CGDirectDisplayID { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID() }
}

enum CaptureError: Error, LocalizedError {
    case noDisplay
    case notAllowed
    var errorDescription: String? {
        switch self {
        case .noDisplay: return "That display is no longer connected."
        case .notAllowed: return "Snagbook is not allowed to record the screen."
        }
    }
}

enum ScreenGrabber {
    /// The display, with Snagbook's own windows (the frame, the controls) left out.
    static func filter(for displayID: CGDirectDisplayID) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.noDisplay }
        let me = content.applications.filter { $0.processID == getpid() }
        return SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
    }

    static func configuration(_ t: CaptureTarget, width: Int, height: Int, settings: CaptureSettings?) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.sourceRect = t.local
        c.width = width
        c.height = height
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.colorSpaceName = CGColorSpace.sRGB
        c.showsCursor = settings?.showCursor ?? false
        c.scalesToFit = true
        if let settings {
            c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
            c.queueDepth = 6
            c.capturesAudio = settings.systemAudio
            c.excludesCurrentProcessAudio = true
            c.sampleRate = 48_000
            c.channelCount = 2
        }
        return c
    }

    /// A still of the target at full resolution.
    static func screenshot(_ t: CaptureTarget) async throws -> CGImage {
        let filter = try await filter(for: t.displayID)
        let p = t.pixelSize
        let conf = configuration(t, width: max(2, p.width), height: max(2, p.height), settings: nil)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: conf)
    }
}

/// Records one target to an MP4 file.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var writer: VideoWriter?
    private let videoQueue = DispatchQueue(label: "snagbook.capture.video")
    private let audioQueue = DispatchQueue(label: "snagbook.capture.audio")
    private var lastPixels: CVPixelBuffer?
    private let lock = NSLock()
    var onError: ((Error) -> Void)?
    private(set) var url: URL?

    func start(_ t: CaptureTarget, settings: CaptureSettings, to url: URL) async throws {
        let size = CaptureMath.outputSize(width: t.rect.width * t.scale, height: t.rect.height * t.scale, maxLongEdge: settings.maxLongEdge)
        let writer = try VideoWriter(url: url, width: size.width, height: size.height, fps: settings.fps, withAudio: settings.systemAudio)
        let filter = try await ScreenGrabber.filter(for: t.displayID)
        let conf = ScreenGrabber.configuration(t, width: size.width, height: size.height, settings: settings)
        let stream = SCStream(filter: filter, configuration: conf, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if settings.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
        self.writer = writer
        self.url = url
        self.stream = stream
        try await stream.startCapture()
    }

    /// Stop and finish the file; returns its duration.
    func stop() async throws -> Double {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        guard let writer else { throw VideoError.empty }
        // The screen only sends frames when something changes. Repeat the last frame at
        // the moment of stopping, so a still ending is as long as it really was.
        let pixels: CVPixelBuffer? = lock.withLock { lastPixels }
        if let pixels { writer.append(pixels: pixels, at: CMClockGetTime(CMClockGetHostTimeClock())) }
        self.writer = nil
        return try await writer.finish()
    }

    func cancel() {
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
        writer?.cancel()
        writer = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, let writer else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            if let pb = CMSampleBufferGetImageBuffer(sb) { lock.withLock { lastPixels = pb } }
            writer.append(video: sb)
        case .audio:
            writer.append(audio: sb)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}

enum Permissions {
    /// True when Snagbook may capture the screen. The first time, macOS asks the user.
    @MainActor
    static func ensureScreenRecording(_ model: AppModel) -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        let asked = UserDefaults.standard.bool(forKey: "askedScreenRecording")
        UserDefaults.standard.set(true, forKey: "askedScreenRecording")
        if CGRequestScreenCaptureAccess() { return true }
        model.alert = .init(
            title: "Allow screen recording",
            message: asked
                ? "Snagbook needs the Screen Recording permission to take screenshots and recordings. Turn on Snagbook in System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen Snagbook."
                : "macOS has asked whether Snagbook may record the screen. After you allow it in System Settings, quit and reopen Snagbook so the permission takes effect.",
            action: ("Open System Settings", { openScreenRecordingSettings() }))
        NSApp.activate(ignoringOtherApps: true)
        return false
    }

    static func openScreenRecordingSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }
    }
}
