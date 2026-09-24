import Foundation

public enum Paths {
    public static var home: String {
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    }

    /// "~/x" -> "<home>/x". Symlinks are left alone on purpose: a shared folder may be
    /// a link whose target path differs between machines, and the "~" spelling is the one
    /// that means the same thing everywhere.
    public static func expand(_ path: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    /// "<home>/x" -> "~/x"; anything outside the home folder is returned unchanged.
    public static func abbreviate(_ path: String) -> String {
        let h = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }

    public static func url(_ path: String) -> URL {
        URL(fileURLWithPath: expand(path), isDirectory: true)
    }
}

public enum Naming {
    /// Eight hex characters, as random as the system allows.
    public static func randomHash() -> String {
        var g = SystemRandomNumberGenerator()
        return String(format: "%08x", UInt32.random(in: .min ... .max, using: &g))
    }

    /// Expand a session folder format such as "{hash}_{dd}-{MM}-{yyyy}".
    public static func sessionFolder(format: String, date: Date, hash: String, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let two = { (n: Int?) in String(format: "%02d", n ?? 0) }
        var s = format.isEmpty ? "{hash}_{dd}-{MM}-{yyyy}" : format
        let pairs: [(String, String)] = [
            ("{hash}", hash), ("{yyyy}", String(format: "%04d", c.year ?? 0)), ("{MM}", two(c.month)),
            ("{dd}", two(c.day)), ("{HH}", two(c.hour)), ("{mm}", two(c.minute)),
        ]
        for (k, v) in pairs { s = s.replacingOccurrences(of: k, with: v) }
        return safeFileName(s, fallback: hash)
    }

    /// A file-name-safe spelling: no slashes, no leading dots, no control characters.
    public static func safeFileName(_ s: String, fallback: String) -> String {
        var out = s.unicodeScalars.map { c -> Character in
            if c == "/" || c == ":" || c == "\\" || c.properties.generalCategory == .control { return "-" }
            return Character(c)
        }.reduce(into: "") { $0.append($1) }
        while out.hasPrefix(".") { out.removeFirst() }
        out = out.trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? fallback : String(out.prefix(120))
    }

    /// "Main menu: the Start button!" -> "main-menu-the-start-button"
    public static func slug(_ title: String, maxLength: Int = 40) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var out = ""
        var dash = false
        for c in folded.unicodeScalars {
            if (c >= "a" && c <= "z") || (c >= "0" && c <= "9") {
                out.unicodeScalars.append(c)
                dash = false
            } else if (c >= "A" && c <= "Z") {
                out.unicodeScalars.append(Unicode.Scalar(c.value + 32)!)
                dash = false
            } else if !dash && !out.isEmpty {
                out.append("-")
                dash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > maxLength {
            out = String(out.prefix(maxLength))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out
    }

    /// "01-main-menu". The number is the item's permanent id; the words follow its title.
    public static func itemFolder(id: Int, title: String) -> String {
        let s = slug(title)
        let n = String(format: "%02d", id)
        return s.isEmpty ? n : "\(n)-\(s)"
    }

    /// The first free "prefix-001.ext", "prefix-002.ext", … among `existing` names.
    public static func nextMediaName(prefix: String, ext: String, existing: Set<String>) -> String {
        var n = 1
        let lower = Set(existing.map { $0.lowercased() })
        while true {
            let name = String(format: "%@-%03d.%@", prefix, n, ext)
            let stem = String(format: "%@-%03d", prefix, n).lowercased()
            if !lower.contains(where: { $0 == name.lowercased() || $0.hasPrefix(stem + ".") || $0.hasPrefix(stem + "-") }) { return name }
            n += 1
        }
    }
}

/// Flat YAML front matter: `key: "value"` lines between two `---` lines. Only what the app
/// writes is understood; anything else in the block is carried along untouched.
public enum FrontMatter {
    public typealias Fields = [(key: String, value: String)]

    public static func split(_ text: String) -> (fields: Fields, raw: String, body: String) {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard t.hasPrefix("---\n") else { return ([], "", t) }
        let rest = t.dropFirst(4)
        guard let end = rest.range(of: "\n---\n") ?? (rest.hasSuffix("\n---") ? rest.range(of: "\n---", options: .backwards) : nil) else {
            return ([], "", t)
        }
        let block = String(rest[rest.startIndex..<end.lowerBound])
        var body = String(rest[end.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }
        var fields: Fields = []
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("#") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields.append((key, unquote(value)))
        }
        return (fields, block, body)
    }

    /// Replace (or add) `updates` in the front matter block, keeping every other line.
    public static func join(raw: String, updates: Fields, body: String) -> String {
        var lines = raw.isEmpty ? [] : raw.components(separatedBy: "\n")
        for (key, value) in updates {
            let line = "\(key): \(quote(value))"
            if let i = lines.firstIndex(where: { $0.hasPrefix(key + ":") }) { lines[i] = line } else { lines.append(line) }
        }
        return "---\n" + lines.joined(separator: "\n") + "\n---\n\n" + body
    }

    public static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ") + "\""
    }

    public static func unquote(_ s: String) -> String {
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            var out = ""
            var esc = false
            for c in s.dropFirst().dropLast() {
                if esc { out.append(c == "n" ? "\n" : c); esc = false } else if c == "\\" { esc = true } else { out.append(c) }
            }
            return out
        }
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return s
    }
}

/// Fills the placeholders of the session header.
public enum Header {
    /// {session} the session folder, {readme} its README.md, {date} the day it started,
    /// {items} how many items it has. Paths use "~" for the home folder.
    public static func render(_ template: String, session: String, date: Date, items: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let readme = session.hasSuffix("/") ? session + "README.md" : session + "/README.md"
        return template
            .replacingOccurrences(of: "{session}", with: session)
            .replacingOccurrences(of: "{readme}", with: readme)
            .replacingOccurrences(of: "{date}", with: f.string(from: date))
            .replacingOccurrences(of: "{items}", with: String(items))
    }
}
