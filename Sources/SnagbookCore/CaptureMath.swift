import Foundation

/// Numbers for recording and for the stills written beside a video.
public enum CaptureMath {
    /// Output size for a region of `w`×`h` pixels: never larger than `maxLongEdge` on its
    /// long side, never upscaled, and even in both directions (H.264 needs that).
    public static func outputSize(width w: Double, height h: Double, maxLongEdge: Int) -> (width: Int, height: Int) {
        guard w > 0, h > 0 else { return (2, 2) }
        let long = max(w, h)
        let scale = long > Double(maxLongEdge) ? Double(maxLongEdge) / long : 1
        func even(_ v: Double) -> Int { max(2, Int((v * scale).rounded(.down)) & ~1) }
        return (even(w), even(h))
    }

    /// Average bit rate: about 0.1 bit per pixel per frame, with a floor that keeps small
    /// text legible and a ceiling that keeps a minute of video around 20–40 MB.
    public static func bitRate(width: Int, height: Int, fps: Int) -> Int {
        let raw = Double(width * height * max(fps, 1)) * 0.1
        return Int(min(max(raw, 600_000), 6_000_000))
    }

    /// Times (seconds) of the stills: one per second, evenly spread when that would be
    /// more than `max`. Always includes a frame near the start and near the end.
    public static func stillTimes(duration: Double, max: Int) -> [Double] {
        guard duration > 0, max > 0 else { return [] }
        let perSecond = Int(duration.rounded(.down)) + 1
        let n = Swift.min(perSecond, max)
        if n == 1 { return [0] }
        let last = Swift.max(0, duration - 0.05)
        if perSecond <= max {
            var t = (0..<n).map(Double.init)
            if t.last! > last { t[t.count - 1] = last }
            return t
        }
        return (0..<n).map { last * Double($0) / Double(n - 1) }
    }

    /// Up to `count` times spread across the clip for the contact sheet.
    public static func sheetTimes(duration: Double, count: Int = 16) -> [Double] {
        guard duration > 0, count > 0 else { return [] }
        let n = Swift.max(1, Swift.min(count, Int(duration * 2) + 1))
        if n == 1 { return [0] }
        let last = Swift.max(0, duration - 0.05)
        return (0..<n).map { last * Double($0) / Double(n - 1) }
    }

    /// Columns and rows for `n` tiles: as square as possible, wider than tall.
    public static func grid(_ n: Int) -> (cols: Int, rows: Int) {
        guard n > 0 else { return (0, 0) }
        let cols = Int(Double(n).squareRoot().rounded(.up))
        return (cols, (n + cols - 1) / cols)
    }

    /// "0:07.5", "1:02.0", "1:00:03.0"
    public static func stamp(_ t: Double) -> String {
        let tenths = Int((t * 10).rounded())
        let s = tenths / 10, f = tenths % 10
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d.%d", h, m, sec, f) : String(format: "%d:%02d.%d", m, sec, f)
    }

    /// "0:12", "1:05", for a caption.
    public static func duration(_ t: Double) -> String {
        let s = Int(t.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Coordinates between the two conventions that meet in screen capture: AppKit's global
/// points (origin bottom-left of the main display, y up) and a display-local rectangle with
/// its origin top-left (what the capture APIs want).
public enum RegionMath {
    /// `rect` and `screen` in AppKit global points. Returns `rect` relative to the screen's
    /// top-left corner, clipped to it.
    public static func displayLocal(_ rect: Box, screen: Box) -> Box {
        let clipped = rect.intersection(screen)
        return Box(x: clipped.x - screen.x, y: screen.maxY - clipped.maxY, w: clipped.w, h: clipped.h)
    }

    /// The inverse: a display-local top-left rectangle back to AppKit global points.
    public static func global(_ local: Box, screen: Box) -> Box {
        Box(x: local.x + screen.x, y: screen.maxY - local.y - local.h, w: local.w, h: local.h)
    }

    /// Snap a rectangle to whole pixels at `scale` (2 on Retina), keeping it inside `bounds`.
    public static func snapped(_ r: Box, scale: Double, bounds: Box) -> Box {
        let s = scale > 0 ? scale : 1
        let x0 = (r.minX * s).rounded(.down) / s, y0 = (r.minY * s).rounded(.down) / s
        let x1 = (r.maxX * s).rounded(.up) / s, y1 = (r.maxY * s).rounded(.up) / s
        return Box(x: x0, y: y0, w: x1 - x0, h: y1 - y0).intersection(bounds)
    }

    /// A drag shorter than this (points) is a click, which picks the window under it.
    public static let clickSlop = 4.0
}
