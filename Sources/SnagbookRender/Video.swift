import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import SnagbookCore

/// Writes H.264 MP4 from pixel buffers or sample buffers: hardware encoded, a key frame every
/// second, sized for being looked at (by people or programs), not for archiving.
public final class VideoWriter {
    public let url: URL
    public let width: Int
    public let height: Int
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var audio: AVAssetWriterInput?
    private var started = false
    private var firstTime: CMTime = .invalid
    private var lastTime: CMTime = .invalid
    private let queue = DispatchQueue(label: "snagbook.videowriter")
    public private(set) var frames = 0

    public init(url: URL, width: Int, height: Int, fps: Int, withAudio: Bool) throws {
        self.url = url
        self.width = width
        self.height = height
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: CaptureMath.bitRate(width: width, height: height, fps: fps),
                AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(video) else { throw VideoError.cannotWrite("video input") }
        writer.add(video)
        if withAudio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 96_000,
            ])
            a.expectsMediaDataInRealTime = true
            if writer.canAdd(a) {
                writer.add(a)
                audio = a
            }
        }
    }

    private func startIfNeeded(_ t: CMTime) -> Bool {
        if started { return true }
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: t)
        firstTime = t
        started = true
        return true
    }

    /// Append a finished video frame (from the capture stream).
    public func append(video sample: CMSampleBuffer) {
        queue.sync {
            let t = CMSampleBufferGetPresentationTimeStamp(sample)
            guard startIfNeeded(t), video.isReadyForMoreMediaData else { return }
            if lastTime.isValid && t <= lastTime { return }
            if video.append(sample) {
                lastTime = t
                frames += 1
            }
        }
    }

    /// Append a pixel buffer at an explicit time (the self-test's synthetic frames, and the
    /// capture path when it has to re-time a frame).
    public func append(pixels: CVPixelBuffer, at t: CMTime) {
        queue.sync {
            guard startIfNeeded(t) else { return }
            var spins = 0
            while !video.isReadyForMoreMediaData && spins < 200 {
                usleep(1000)
                spins += 1
            }
            guard video.isReadyForMoreMediaData else { return }
            if lastTime.isValid && t <= lastTime { return }
            if adaptor.append(pixels, withPresentationTime: t) {
                lastTime = t
                frames += 1
            }
        }
    }

    public func append(audio sample: CMSampleBuffer) {
        queue.sync {
            guard started, let audio, audio.isReadyForMoreMediaData else { return }
            audio.append(sample)
        }
    }

    public var pixelBufferPool: CVPixelBufferPool? { adaptor.pixelBufferPool }

    /// Finish the file. Returns its duration in seconds.
    public func finish() async throws -> Double {
        let (isStarted, first, last): (Bool, CMTime, CMTime) = queue.sync { (started, firstTime, lastTime) }
        guard isStarted, frames > 0 else {
            writer.cancelWriting()
            throw VideoError.empty
        }
        // Hold the last frame on screen for one more frame so a still picture has a length.
        let end = CMTimeAdd(last, CMTime(value: 1, timescale: 15))
        video.markAsFinished()
        audio?.markAsFinished()
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        if writer.status != .completed { throw VideoError.cannotWrite(writer.error?.localizedDescription ?? "unknown") }
        return CMTimeGetSeconds(CMTimeSubtract(end, first))
    }

    public func cancel() {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}

public enum VideoError: Error, LocalizedError {
    case empty
    case cannotWrite(String)
    case cannotRead(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "Nothing was recorded."
        case .cannotWrite(let s): return "The video could not be written: \(s)"
        case .cannotRead(let s): return "The video could not be read: \(s)"
        }
    }
}

/// What gets written beside a video so it can be understood without playing it:
/// still frames (one a second), a contact sheet with timestamps, and a small JSON file.
public enum VideoStills {
    public struct Info: Codable, Equatable {
        public var video: String
        public var duration: Double
        public var width: Int
        public var height: Int
        public var fps: Int
        public var recorded: String
        public var stills: [Still]
        public var contactSheet: String?
        /// What was recorded: "region", "screen" or "window", and where.
        public var source: String?
        public var app: String?

        public struct Still: Codable, Equatable {
            public var time: Double
            public var file: String
        }
    }

    /// For "clip-001.mp4": "clip-001-frames", "clip-001-contact.jpg", "clip-001.json".
    public static func names(for videoName: String) -> (frames: String, sheet: String, json: String) {
        let stem = (videoName as NSString).deletingPathExtension
        return (stem + "-frames", stem + "-contact.jpg", stem + ".json")
    }

    /// Extract the stills and the contact sheet for `videoURL` into its folder.
    public static func write(for videoURL: URL, fps: Int, maxStills: Int, source: String?, app: String?, recorded: Date = Date()) async throws -> Info {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await CMTimeGetSeconds(asset.load(.duration))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoError.cannotRead("no video track") }
        let size = try await track.load(.naturalSize)
        let dir = videoURL.deletingLastPathComponent()
        let n = names(for: videoURL.lastPathComponent)
        let framesDir = dir.appendingPathComponent(n.frames, isDirectory: true)
        try? FileManager.default.removeItem(at: framesDir)
        try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: 1568, height: 1568)

        var stills: [Info.Still] = []
        for (i, t) in CaptureMath.stillTimes(duration: duration, max: maxStills).enumerated() {
            guard let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image,
                  let jpg = ImageFile.jpegData(img, quality: 0.72) else { continue }
            let name = String(format: "%04d.jpg", i + 1)
            try jpg.write(to: framesDir.appendingPathComponent(name), options: .atomic)
            stills.append(.init(time: (t * 10).rounded() / 10, file: n.frames + "/" + name))
        }

        var sheetName: String?
        let sheetTimes = CaptureMath.sheetTimes(duration: duration)
        var tiles: [(CGImage, Double)] = []
        gen.maximumSize = CGSize(width: 480, height: 480)
        for t in sheetTimes {
            if let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image { tiles.append((img, t)) }
        }
        if let sheet = contactSheet(tiles), let jpg = ImageFile.jpegData(sheet, quality: 0.75) {
            try jpg.write(to: dir.appendingPathComponent(n.sheet), options: .atomic)
            sheetName = n.sheet
        }

        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        let info = Info(video: videoURL.lastPathComponent, duration: (duration * 100).rounded() / 100,
                        width: Int(size.width), height: Int(size.height), fps: fps, recorded: iso.string(from: recorded),
                        stills: stills, contactSheet: sheetName, source: source, app: app)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(info).write(to: dir.appendingPathComponent(n.json), options: .atomic)
        return info
    }

    /// Tiles in a grid, each with its time in the corner.
    public static func contactSheet(_ tiles: [(CGImage, Double)]) -> CGImage? {
        guard let first = tiles.first?.0 else { return nil }
        let (cols, rows) = CaptureMath.grid(tiles.count)
        let tw = first.width, th = first.height, gap = 6
        let w = cols * tw + (cols + 1) * gap, h = rows * th + (rows + 1) * gap
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.11, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let fontSize = max(12, Double(th) / 11)
        let font = MarkRenderer.font(fontSize)
        for (i, (img, t)) in tiles.enumerated() {
            let c = i % cols, r = i / cols
            let x = gap + c * (tw + gap)
            let yTop = gap + r * (th + gap)
            let rect = CGRect(x: x, y: h - yTop - th, width: tw, height: th)
            ctx.draw(img, in: rect)
            let label = CaptureMath.stamp(t)
            let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font,
                                                         .init(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attrs))
            let lw = CTLineGetTypographicBounds(line, nil, nil, nil)
            let pad = fontSize * 0.35
            let badge = CGRect(x: rect.minX + 4, y: rect.minY + 4, width: lw + 2 * pad, height: fontSize * 1.35)
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.65))
            ctx.fill(badge)
            ctx.textPosition = CGPoint(x: badge.minX + pad, y: badge.minY + fontSize * 0.35)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()
    }
}
