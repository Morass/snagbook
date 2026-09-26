import AVFoundation
import CoreGraphics
import XCTest
import SnagbookCore
@testable import SnagbookRender

final class RenderTests: XCTestCase {
    /// A w×h picture: white, with a black-and-white checkerboard in the top-left quarter.
    func testImage(_ w: Int = 200, _ h: Int = 100) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for y in stride(from: 0, to: h / 2, by: 2) {
            for x in stride(from: (y / 2) % 2 * 2, to: w / 2, by: 4) {
                // CG origin is bottom-left; the checker occupies the TOP-left quarter.
                ctx.fill(CGRect(x: x, y: h - 1 - y - 1, width: 2, height: 2))
            }
        }
        return ctx.makeImage()!
    }

    /// RGBA of pixel (x, y) with the origin top-left.
    func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = (y * img.width + x) * 4
        return (Int(p[i]), Int(p[i + 1]), Int(p[i + 2]))
    }

    func isRed(_ c: (Int, Int, Int)) -> Bool { c.0 > 180 && c.1 < 110 && c.2 < 110 }
    func isWhite(_ c: (Int, Int, Int)) -> Bool { c.0 > 240 && c.1 > 240 && c.2 > 240 }

    func testRectangleLandsWhereItWasDrawnTopLeftOrigin() throws {
        let doc = MarkDocument(width: 200, height: 100, marks: [Mark(tool: .rect, points: [Pt(120, 10), Pt(180, 60)], color: "#ff0000", width: 4)])
        let out = try XCTUnwrap(MarkRenderer.render(doc, original: testImage()))
        XCTAssertEqual(out.width, 200)
        XCTAssertTrue(isRed(pixel(out, 120, 35)), "left edge of the box, near the top of the picture: \(pixel(out, 120, 35))")
        XCTAssertTrue(isWhite(pixel(out, 150, 35)), "inside the box stays clear")
        XCTAssertTrue(isWhite(pixel(out, 150, 90)), "below the box stays clear")
    }

    func testOpacityLetsThePictureShowThrough() throws {
        let solid = MarkDocument(width: 200, height: 100, marks: [Mark(tool: .rect, points: [Pt(120, 10), Pt(180, 60)], color: "#ff0000", width: 8)])
        var faint = solid
        faint.marks[0].opacity = 0.4
        let a = pixel(try XCTUnwrap(MarkRenderer.render(solid, original: testImage())), 120, 30)
        let b = pixel(try XCTUnwrap(MarkRenderer.render(faint, original: testImage())), 120, 30)
        XCTAssertTrue(isRed(a), "\(a)")
        XCTAssertEqual(b.0, 255, accuracy: 3)
        XCTAssertTrue(b.1 > 120 && b.1 < 190 && b.2 > 120 && b.2 < 190, "40% red over white is pink, not red: \(b)")
    }

    func testCropChangesTheOutputSizeAndOffsetsMarks() throws {
        let doc = MarkDocument(width: 200, height: 100, crop: Box(x: 100, y: 0, w: 100, h: 50),
                               marks: [Mark(tool: .ellipse, points: [Pt(110, 5), Pt(190, 45)], color: "#ff0000", width: 6)])
        let out = try XCTUnwrap(MarkRenderer.render(doc, original: testImage()))
        XCTAssertEqual(out.width, 100)
        XCTAssertEqual(out.height, 50)
        XCTAssertTrue(isRed(pixel(out, 10, 25)), "left of the ellipse at crop-local x=10: \(pixel(out, 10, 25))")
    }

    func testPixelateHidesDetailButLeavesTheRest() throws {
        let orig = testImage()
        let doc = MarkDocument(width: 200, height: 100, marks: [Mark(tool: .pixelate, points: [Pt(0, 0), Pt(100, 50)], color: "#000000", width: 1)])
        let out = try XCTUnwrap(MarkRenderer.render(doc, original: orig))
        // In the checkerboard, neighbouring 2px cells alternate; pixelated, they match.
        var differing = 0
        for x in stride(from: 10, to: 90, by: 2) where pixel(out, x, 20) != pixel(out, x + 2, 20) { differing += 1 }
        var differingOrig = 0
        for x in stride(from: 10, to: 90, by: 2) where pixel(orig, x, 20) != pixel(orig, x + 2, 20) { differingOrig += 1 }
        XCTAssertGreaterThan(differingOrig, 20)
        XCTAssertLessThan(differing, differingOrig / 3)
        XCTAssertTrue(isWhite(pixel(out, 150, 80)))
    }

    func testTextAndCounterAndArrowDrawSomething() throws {
        let marks = [
            Mark(tool: .text, points: [Pt(110, 60)], color: "#ff0000", width: 22, text: "HI"),
            Mark(tool: .counter, points: [Pt(30, 80)], color: "#ff0000", width: 4, number: 3),
            Mark(tool: .arrow, points: [Pt(60, 95), Pt(100, 60)], color: "#ff0000", width: 5),
            Mark(tool: .highlighter, points: [Pt(110, 95), Pt(190, 95)], color: "#ffe600", width: 10),
        ]
        let out = try XCTUnwrap(MarkRenderer.render(MarkDocument(width: 200, height: 100, marks: marks), original: testImage()))
        var red = 0
        for y in 60..<85 { for x in 110..<150 where isRed(pixel(out, x, y)) { red += 1 } }
        XCTAssertGreaterThan(red, 30, "the text is there")
        XCTAssertTrue(isRed(pixel(out, 30, 70)) || isRed(pixel(out, 22, 80)), "the counter disc is there")
        let hl = pixel(out, 150, 95)
        XCTAssertTrue(hl.0 > 200 && hl.2 < 200, "highlighter tints yellow: \(hl)")
    }

    func testPNGRoundTripKeepsPixels() throws {
        let img = testImage(64, 32)
        let data = try XCTUnwrap(ImageFile.pngData(img))
        let back = try XCTUnwrap(ImageFile.load(data))
        XCTAssertEqual(back.width, 64)
        XCTAssertEqual(pixel(back, 1, 1).0, pixel(img, 1, 1).0)
    }

    func testVideoWriterAndStills() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip-001.mp4")
        let w = try VideoWriter(url: url, width: 320, height: 180, fps: 15, withAudio: false)
        // 3.2 seconds of frames whose colour changes every second.
        for i in 0..<48 {
            let pb = try XCTUnwrap(Self.pixelBuffer(width: 320, height: 180, gray: UInt8(40 + (i / 15) * 60)))
            w.append(pixels: pb, at: CMTime(value: CMTimeValue(i), timescale: 15))
        }
        let duration = try await w.finish()
        XCTAssertEqual(duration, 3.2, accuracy: 0.1)
        let info = try await VideoStills.write(for: url, fps: 15, maxStills: 60, source: "region", app: nil)
        XCTAssertEqual(info.stills.count, 4)
        XCTAssertEqual(info.width, 320)
        XCTAssertEqual(info.contactSheet, "clip-001-contact.jpg")
        for s in info.stills { XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(s.file).path), s.file) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("clip-001.json").path))
        // The stills really are from different moments: frame 1 darker than frame 4.
        let a = try XCTUnwrap(ImageFile.load(dir.appendingPathComponent(info.stills[0].file)))
        let d = try XCTUnwrap(ImageFile.load(dir.appendingPathComponent(info.stills[3].file)))
        XCTAssertLessThan(pixel(a, 10, 10).0 + 60, pixel(d, 10, 10).0)
    }

    func testEmptyRecordingIsAnError() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).mp4")
        let w = try VideoWriter(url: url, width: 64, height: 64, fps: 15, withAudio: false)
        do {
            _ = try await w.finish()
            XCTFail("expected an error")
        } catch VideoError.empty {}
    }

    static func pixelBuffer(width: Int, height: Int, gray: UInt8) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bpr + x * 4
                base[i] = gray; base[i + 1] = gray; base[i + 2] = gray; base[i + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }
}
