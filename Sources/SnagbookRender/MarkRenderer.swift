import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import SnagbookCore
import UniformTypeIdentifiers

/// Draws marks. The same routine paints the live canvas and the exported picture, so what
/// you see while marking up is exactly what gets saved.
public enum MarkRenderer {
    /// Draw `marks` into `ctx`, whose user space is image pixels with the origin TOP-LEFT
    /// (callers flip). `original` is needed for pixelated areas.
    public static func draw(_ marks: [Mark], in ctx: CGContext, original: CGImage?, imageHeight: Double) {
        for m in marks { draw(m, in: ctx, original: original, imageHeight: imageHeight) }
    }

    public static func draw(_ m: Mark, in ctx: CGContext, original: CGImage?, imageHeight: Double) {
        let color = cgColor(m.color)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(m.width)

        switch m.tool {
        case .rect:
            guard m.points.count >= 2 else { return }
            let r = rect(Box.spanning(m.points[0], m.points[1]))
            withShadow(ctx) { ctx.stroke(r) }
        case .ellipse:
            guard m.points.count >= 2 else { return }
            let r = rect(Box.spanning(m.points[0], m.points[1]))
            withShadow(ctx) { ctx.strokeEllipse(in: r) }
        case .arrow:
            guard m.points.count >= 2 else { return }
            let tail = m.points[0], tip = m.points[1]
            let (b1, b2) = Geometry.arrowHead(tail: tail, tip: tip, width: m.width)
            // Shorten the shaft so its round cap does not poke through the head.
            let back = Geometry.dist(tail, tip) > m.width * 2 ? m.width * 1.2 : 0
            let angle = atan2(tip.y - tail.y, tip.x - tail.x)
            let shaftEnd = Pt(tip.x - back * cos(angle), tip.y - back * sin(angle))
            withShadow(ctx) {
                ctx.beginPath()
                ctx.move(to: cg(tail))
                ctx.addLine(to: cg(shaftEnd))
                ctx.strokePath()
                ctx.beginPath()
                ctx.move(to: cg(tip))
                ctx.addLine(to: cg(b1))
                ctx.addLine(to: cg(b2))
                ctx.closePath()
                ctx.fillPath()
            }
        case .pen, .highlighter:
            guard let first = m.points.first else { return }
            if m.tool == .highlighter {
                ctx.setBlendMode(.multiply)
                ctx.setStrokeColor(cgColor(m.color, alpha: 0.42))
                ctx.setLineCap(.square)
            }
            ctx.beginPath()
            ctx.move(to: cg(first))
            if m.points.count == 1 {
                ctx.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
            } else {
                smoothPath(ctx, m.points)
            }
            if m.tool == .pen { withShadow(ctx) { ctx.strokePath() } } else { ctx.strokePath() }
        case .text:
            guard let p = m.points.first, let text = m.text, !text.isEmpty else { return }
            drawText(text, at: p, size: m.width, color: color, in: ctx)
        case .counter:
            guard let p = m.points.first else { return }
            let r = m.counterRadius
            let circle = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            withShadow(ctx) { ctx.fillEllipse(in: circle) }
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.setLineWidth(max(1.5, r * 0.12))
            ctx.strokeEllipse(in: circle.insetBy(dx: 0.5, dy: 0.5))
            drawCentered(String(m.number ?? 1), center: p, size: r * 1.15, color: contrasting(m.color), in: ctx)
        case .pixelate:
            guard m.points.count >= 2, let original else { return }
            let box = Box.spanning(m.points[0], m.points[1]).intersection(Box(x: 0, y: 0, w: Double(original.width), h: Double(original.height)))
            guard !box.isEmpty, let tile = pixelated(original, box: box) else { return }
            // `ctx` is flipped (top-left origin); draw the tile upright.
            ctx.saveGState()
            ctx.translateBy(x: box.x, y: box.y + box.h)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .none
            ctx.draw(tile, in: CGRect(x: 0, y: 0, width: box.w, height: box.h))
            ctx.restoreGState()
        }
    }

    /// The finished picture: the original, cropped, with every mark drawn on it.
    public static func render(_ doc: MarkDocument, original: CGImage) -> CGImage? {
        let out = doc.outputBox
        let w = Int(out.w), h = Int(out.h)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Top-left origin, shifted by the crop.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -out.x, y: -out.y)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(original.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
        ctx.restoreGState()
        draw(doc.marks, in: ctx, original: original, imageHeight: Double(original.height))
        return ctx.makeImage()
    }

    // MARK: - pieces

    static func pixelated(_ image: CGImage, box: Box) -> CGImage? {
        // CGImage crop rectangles are top-left based, like `box`.
        guard let piece = image.cropping(to: rect(box).integral) else { return nil }
        let block = max(6, min(box.w, box.h) / 10)
        let ci = CIImage(cgImage: piece)
        let f = CIFilter(name: "CIPixellate")!
        f.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(block, forKey: kCIInputScaleKey)
        f.setValue(CIVector(x: ci.extent.midX, y: ci.extent.midY), forKey: kCIInputCenterKey)
        guard let out = f.outputImage?.cropped(to: ci.extent) else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(out, from: ci.extent)
    }

    static func withShadow(_ ctx: CGContext, _ body: () -> Void) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
        body()
        ctx.restoreGState()
    }

    static func smoothPath(_ ctx: CGContext, _ pts: [Pt]) {
        guard pts.count > 2 else {
            for p in pts.dropFirst() { ctx.addLine(to: cg(p)) }
            return
        }
        for i in 1..<pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            ctx.addQuadCurve(to: mid, control: cg(pts[i]))
        }
        ctx.addLine(to: cg(pts[pts.count - 1]))
    }

    static func font(_ size: Double, bold: Bool = true) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    }

    /// Text with a thin outline in the contrasting colour, so it reads on any background.
    static func drawText(_ text: String, at p: Pt, size: Double, color: CGColor, in ctx: CGContext) {
        let f = font(size)
        let lines = text.components(separatedBy: "\n")
        let lineHeight = size * 1.25
        let outline = luminance(color) > 0.6 ? CGColor(red: 0, green: 0, blue: 0, alpha: 0.9) : CGColor(red: 1, green: 1, blue: 1, alpha: 0.95)
        for (i, line) in lines.enumerated() where !line.isEmpty {
            let baseline = p.y + CTFontGetAscent(f) + Double(i) * lineHeight
            for pass in 0..<2 {
                let attrs: [NSAttributedString.Key: Any] = pass == 0
                    ? [.init(kCTFontAttributeName as String): f, .init(kCTStrokeColorAttributeName as String): outline, .init(kCTStrokeWidthAttributeName as String): 14.0]
                    : [.init(kCTFontAttributeName as String): f, .init(kCTForegroundColorAttributeName as String): color]
                let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attrs))
                ctx.saveGState()
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                ctx.textPosition = CGPoint(x: p.x, y: baseline)
                CTLineDraw(ctLine, ctx)
                ctx.restoreGState()
            }
        }
    }

    static func drawCentered(_ text: String, center: Pt, size: Double, color: CGColor, in ctx: CGContext) {
        let f = font(size)
        let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): f, .init(kCTForegroundColorAttributeName as String): color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let bounds = CTLineGetImageBounds(line, ctx)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y + bounds.midY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Size of a text mark in image pixels.
    public static func textSize(_ text: String, size: Double) -> CGSize {
        let f = font(size)
        var w = 0.0
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): f]
            let l = CTLineCreateWithAttributedString(NSAttributedString(string: line.isEmpty ? " " : line, attributes: attrs))
            w = max(w, CTLineGetTypographicBounds(l, nil, nil, nil))
        }
        return CGSize(width: w, height: Double(lines.count) * size * 1.25)
    }

    // MARK: - colours

    public static func cgColor(_ hex: String, alpha: Double = 1) -> CGColor {
        let (r, g, b) = rgb(hex)
        return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    public static func rgb(_ hex: String) -> (Double, Double, Double) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return (1, 0.2, 0.2) }
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }

    static func luminance(_ c: CGColor) -> Double {
        guard let comps = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components, comps.count >= 3 else { return 0.5 }
        return 0.2126 * comps[0] + 0.7152 * comps[1] + 0.0722 * comps[2]
    }

    static func contrasting(_ hex: String) -> CGColor {
        let (r, g, b) = rgb(hex)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.6 ? CGColor(red: 0, green: 0, blue: 0, alpha: 1) : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    }

    static func cg(_ p: Pt) -> CGPoint { CGPoint(x: p.x, y: p.y) }
    static func rect(_ b: Box) -> CGRect { CGRect(x: b.x, y: b.y, width: b.w, height: b.h) }
}

/// Reading and writing pictures without any resampling on the way.
public enum ImageFile {
    public static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
    }

    public static func load(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    public static func pngData(_ image: CGImage) -> Data? {
        encode(image, type: .png, quality: nil)
    }

    public static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        encode(image, type: .jpeg, quality: quality)
    }

    static func encode(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Write atomically so a reader never sees half a file.
    public static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    /// Scale down so the long edge is at most `maxLongEdge` (never up).
    public static func scaled(_ image: CGImage, maxLongEdge: Int) -> CGImage {
        let long = max(image.width, image.height)
        guard long > maxLongEdge, maxLongEdge > 0 else { return image }
        let s = Double(maxLongEdge) / Double(long)
        let w = max(1, Int(Double(image.width) * s)), h = max(1, Int(Double(image.height) * s))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
