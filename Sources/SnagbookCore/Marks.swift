import Foundation

/// A point in image pixels, origin top-left.
public struct Pt: Codable, Equatable, Hashable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

public struct Box: Codable, Equatable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + w }
    public var maxY: Double { y + h }
    public var isEmpty: Bool { w <= 0 || h <= 0 }

    /// The box spanned by two corners, in any order.
    public static func spanning(_ a: Pt, _ b: Pt) -> Box {
        Box(x: min(a.x, b.x), y: min(a.y, b.y), w: abs(a.x - b.x), h: abs(a.y - b.y))
    }

    public func insetBy(_ d: Double) -> Box { Box(x: x + d, y: y + d, w: w - 2 * d, h: h - 2 * d) }

    public func contains(_ p: Pt) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }

    public func intersection(_ o: Box) -> Box {
        let x0 = max(minX, o.minX), y0 = max(minY, o.minY), x1 = min(maxX, o.maxX), y1 = min(maxY, o.maxY)
        return x1 > x0 && y1 > y0 ? Box(x: x0, y: y0, w: x1 - x0, h: y1 - y0) : Box(x: 0, y: 0, w: 0, h: 0)
    }

    public func union(_ o: Box) -> Box {
        if isEmpty { return o }
        if o.isEmpty { return self }
        let x0 = min(minX, o.minX), y0 = min(minY, o.minY)
        return Box(x: x0, y: y0, w: max(maxX, o.maxX) - x0, h: max(maxY, o.maxY) - y0)
    }
}

public enum MarkTool: String, Codable, CaseIterable {
    case arrow, ellipse, rect, pen, highlighter, text, counter, pixelate

    /// Single-key shortcut in the mark-up window.
    public var key: Character {
        switch self {
        case .arrow: return "a"
        case .ellipse: return "o"
        case .rect: return "r"
        case .pen: return "p"
        case .highlighter: return "h"
        case .text: return "t"
        case .counter: return "n"
        case .pixelate: return "b"
        }
    }

    public var title: String {
        switch self {
        case .arrow: return "Arrow"
        case .ellipse: return "Circle"
        case .rect: return "Box"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .text: return "Text"
        case .counter: return "Number"
        case .pixelate: return "Blur"
        }
    }

    /// Drawn by dragging from one corner to another (as opposed to a free path or a click).
    public var isTwoPoint: Bool { [.arrow, .ellipse, .rect, .pixelate].contains(self) }
    public var isPath: Bool { self == .pen || self == .highlighter }
}

/// One mark on a screenshot. Coordinates are image pixels.
public struct Mark: Codable, Equatable {
    public var tool: MarkTool
    /// Two-point tools: [start, end]. Paths: every sample. Text and counter: [anchor].
    public var points: [Pt]
    /// "#rrggbb"
    public var color: String
    /// Stroke width in image pixels (text: font size).
    public var width: Double
    public var text: String?
    public var number: Int?

    public init(tool: MarkTool, points: [Pt], color: String, width: Double, text: String? = nil, number: Int? = nil) {
        self.tool = tool
        self.points = points
        self.color = color
        self.width = width
        self.text = text
        self.number = number
    }

    /// Roughly the area the mark covers, for hit testing and redraw.
    public var bounds: Box {
        guard let first = points.first else { return Box(x: 0, y: 0, w: 0, h: 0) }
        var b = Box(x: first.x, y: first.y, w: 0, h: 0)
        for p in points.dropFirst() { b = b.union(Box(x: p.x, y: p.y, w: 0.0001, h: 0.0001)) }
        switch tool {
        case .text:
            let lines = (text ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            let longest = lines.map(\.count).max() ?? 1
            return Box(x: first.x, y: first.y, w: max(1, Double(longest)) * width * 0.6, h: Double(max(1, lines.count)) * width * 1.25)
        case .counter:
            let r = counterRadius
            return Box(x: first.x - r, y: first.y - r, w: 2 * r, h: 2 * r)
        default:
            return b.insetBy(-width)
        }
    }

    public var counterRadius: Double { max(12, width * 3.2) }

    /// True when `p` is on (or within `tolerance` of) the mark.
    public func hit(_ p: Pt, tolerance: Double) -> Bool {
        let tol = tolerance + width / 2
        switch tool {
        case .rect, .pixelate:
            guard points.count >= 2 else { return false }
            let b = Box.spanning(points[0], points[1])
            if tool == .pixelate { return b.insetBy(-tol).contains(p) }
            return b.insetBy(-tol).contains(p) && !b.insetBy(tol).contains(p)
        case .ellipse:
            guard points.count >= 2 else { return false }
            let b = Box.spanning(points[0], points[1])
            let rx = b.w / 2, ry = b.h / 2
            guard rx > 0, ry > 0 else { return false }
            let cx = b.x + rx, cy = b.y + ry
            let d = ((p.x - cx) * (p.x - cx)) / (rx * rx) + ((p.y - cy) * (p.y - cy)) / (ry * ry)
            let band = tol / min(rx, ry)
            return abs(sqrt(d) - 1) <= band
        case .arrow:
            guard points.count >= 2 else { return false }
            return Geometry.distance(p, segment: points[0], points[1]) <= tol
        case .pen, .highlighter:
            if points.count == 1 { return Geometry.dist(p, points[0]) <= tol }
            for i in 1..<points.count where Geometry.distance(p, segment: points[i - 1], points[i]) <= tol { return true }
            return false
        case .text, .counter:
            return bounds.insetBy(-tolerance).contains(p)
        }
    }

    public func moved(dx: Double, dy: Double) -> Mark {
        var m = self
        m.points = points.map { Pt($0.x + dx, $0.y + dy) }
        return m
    }
}

/// Everything needed to redraw a marked-up screenshot from its untouched original.
/// Stored as "<name>.marks.json" beside "<name>.orig.png" and the rendered "<name>.png".
public struct MarkDocument: Codable, Equatable {
    public var version: Int = 1
    public var width: Int
    public var height: Int
    /// Crop, in original pixels; nil keeps the whole picture.
    public var crop: Box?
    public var marks: [Mark]

    public init(width: Int, height: Int, crop: Box? = nil, marks: [Mark] = []) {
        self.width = width
        self.height = height
        self.crop = crop
        self.marks = marks
    }

    /// The next number a counter mark should show.
    public var nextCounter: Int { (marks.compactMap(\.number).max() ?? 0) + 1 }

    /// The crop, clamped to the picture, or the whole picture.
    public var outputBox: Box {
        let full = Box(x: 0, y: 0, w: Double(width), h: Double(height))
        guard let crop else { return full }
        let c = crop.intersection(full)
        return c.w >= 4 && c.h >= 4 ? Box(x: c.x.rounded(), y: c.y.rounded(), w: c.w.rounded(), h: c.h.rounded()) : full
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> MarkDocument {
        try JSONDecoder().decode(MarkDocument.self, from: data)
    }

    /// The marks file and original that belong to a rendered picture "media/shot-001.png".
    public static func companions(of relative: String) -> (orig: String, marks: String) {
        let stem = relative.hasSuffix(".png") ? String(relative.dropLast(4)) : relative
        return (stem + ".orig.png", stem + ".marks.json")
    }
}

public enum Geometry {
    public static func dist(_ a: Pt, _ b: Pt) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }

    public static func distance(_ p: Pt, segment a: Pt, _ b: Pt) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return dist(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return dist(p, Pt(a.x + t * dx, a.y + t * dy))
    }

    /// Shift-constrain a drag: squares and circles, or arrows snapped to 45°.
    public static func constrain(_ start: Pt, _ end: Pt, tool: MarkTool) -> Pt {
        let dx = end.x - start.x, dy = end.y - start.y
        if tool == .arrow {
            let angle = atan2(dy, dx)
            let step = Double.pi / 4
            let snapped = (angle / step).rounded() * step
            let len = (dx * dx + dy * dy).squareRoot()
            return Pt(start.x + cos(snapped) * len, start.y + sin(snapped) * len)
        }
        let side = max(abs(dx), abs(dy))
        return Pt(start.x + (dx < 0 ? -side : side), start.y + (dy < 0 ? -side : side))
    }

    /// The two barbs of an arrow head at `tip`, for a shaft coming from `tail`.
    public static func arrowHead(tail: Pt, tip: Pt, width: Double) -> (Pt, Pt) {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let len = min(max(width * 4.5, 14), max(dist(tail, tip) * 0.6, 6))
        let spread = Double.pi / 7
        return (Pt(tip.x - len * cos(angle - spread), tip.y - len * sin(angle - spread)),
                Pt(tip.x - len * cos(angle + spread), tip.y - len * sin(angle + spread)))
    }

    /// Drop path samples closer than `minStep` to the previous kept one.
    public static func simplify(_ pts: [Pt], minStep: Double) -> [Pt] {
        guard var last = pts.first else { return [] }
        var out = [last]
        for p in pts.dropFirst() where dist(p, last) >= minStep {
            out.append(p)
            last = p
        }
        if let end = pts.last, out.last != end { out.append(end) }
        return out
    }
}
