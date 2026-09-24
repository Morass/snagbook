import Foundation

/// A button on the template bar: one click types `body` at the caret.
public struct Template: Codable, Equatable, Identifiable, Hashable {
    public var id: UUID
    /// Shown on the button. Short: a word, or an emoji.
    public var label: String
    /// Optional symbol shown before the label: an emoji, or an SF Symbol name.
    public var icon: String
    /// Markdown inserted at the caret.
    public var body: String

    public init(id: UUID = UUID(), label: String, icon: String = "", body: String) {
        self.id = id
        self.label = label
        self.icon = icon
        self.body = body
    }
}

public struct CaptureSettings: Codable, Equatable {
    /// Frames per second of a recording. 15 is plenty to see what happened, and small.
    public var fps: Int = 15
    /// Longest side of a recording in pixels; bigger regions are scaled down.
    public var maxLongEdge: Int = 1920
    public var systemAudio: Bool = false
    public var showCursor: Bool = true
    /// Open the mark-up window after a screenshot taken with Snagbook.
    public var annotateScreenshots: Bool = true
    /// Still frames written beside each video, one per second up to this many.
    public var maxStills: Int = 60

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CaptureSettings()
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
        maxLongEdge = try c.decodeIfPresent(Int.self, forKey: .maxLongEdge) ?? d.maxLongEdge
        systemAudio = try c.decodeIfPresent(Bool.self, forKey: .systemAudio) ?? d.systemAudio
        showCursor = try c.decodeIfPresent(Bool.self, forKey: .showCursor) ?? d.showCursor
        annotateScreenshots = try c.decodeIfPresent(Bool.self, forKey: .annotateScreenshots) ?? d.annotateScreenshots
        maxStills = try c.decodeIfPresent(Int.self, forKey: .maxStills) ?? d.maxStills
    }

    /// Values a hand-edited file could get wrong, pulled back into range.
    public var sanitized: CaptureSettings {
        var s = self
        s.fps = min(max(s.fps, 1), 60)
        s.maxLongEdge = min(max(s.maxLongEdge, 320), 7680)
        s.maxStills = min(max(s.maxStills, 0), 600)
        return s
    }
}

/// What the Copy Hand-off command puts on the clipboard.
public enum HandoffStyle: String, Codable, CaseIterable {
    /// The header text (with the session's path filled in).
    case header
    /// Only the path of the session's README.md.
    case path
}

/// Everything the user can set. Stored as JSON so it can be provisioned or edited by hand.
public struct Config: Codable, Equatable {
    /// Where new sessions are created. `~` is the home folder.
    public var sessionsFolder: String = "~/Snagbook"
    /// Name of a new session's folder. Tokens: {hash} {yyyy} {MM} {dd} {HH} {mm}.
    public var folderFormat: String = "{hash}_{dd}-{MM}-{yyyy}"
    /// Text at the top of every new session's README.md; see `Header` for placeholders.
    public var header: String = Config.defaultHeader
    public var handoff: HandoffStyle = .header
    public var templates: [Template] = Config.defaultTemplates
    public var capture = CaptureSettings()
    /// Keep the notebook above other windows, including full-screen apps.
    public var alwaysOnTop: Bool = false
    /// The session that was open last, reopened on launch.
    public var lastSession: String?

    public static let defaultHeader = """
    These are notes from a test session. Each numbered folder is one finding: read its \
    notes.md, and look at the screenshots and videos in its media/ folder. Every video \
    has still frames (one per second) and a contact sheet beside it.

    Session: {session}
    """

    public static let defaultTemplates: [Template] = [
        Template(label: "Bug", icon: "🐞", body: "**Bug:** "),
        Template(label: "Expected", icon: "", body: "\n\n**Expected:** \n\n**Actual:** "),
        Template(label: "Steps", icon: "", body: "Steps to reproduce:\n\n1. "),
        Template(label: "Idea", icon: "💡", body: "**Idea:** "),
    ]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        sessionsFolder = try c.decodeIfPresent(String.self, forKey: .sessionsFolder) ?? d.sessionsFolder
        folderFormat = try c.decodeIfPresent(String.self, forKey: .folderFormat) ?? d.folderFormat
        header = try c.decodeIfPresent(String.self, forKey: .header) ?? d.header
        handoff = (try? c.decodeIfPresent(HandoffStyle.self, forKey: .handoff)) ?? d.handoff
        templates = try c.decodeIfPresent([Template].self, forKey: .templates) ?? d.templates
        capture = try c.decodeIfPresent(CaptureSettings.self, forKey: .capture) ?? d.capture
        alwaysOnTop = try c.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? d.alwaysOnTop
        lastSession = try c.decodeIfPresent(String.self, forKey: .lastSession)
    }
}

/// Reads and writes the config file. A missing file is the defaults; a broken one is
/// reported and left alone (never overwritten with defaults behind the user's back).
public final class ConfigStore {
    public let url: URL
    public private(set) var config: Config
    /// Set when the file exists but could not be read; saving is refused until fixed.
    public private(set) var loadError: String?

    public init(url: URL) {
        self.url = url
        self.config = Config()
        reload()
    }

    public func reload() {
        loadError = nil
        guard let data = try? Data(contentsOf: url) else {
            config = Config()
            return
        }
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
            config.capture = config.capture.sanitized
        } catch {
            config = Config()
            loadError = "\(url.path): \(error.localizedDescription)"
        }
    }

    public func update(_ change: (inout Config) -> Void) throws {
        var c = config
        change(&c)
        config = c
        try save()
    }

    public func save() throws {
        if let loadError { throw SnagError.configUnreadable(loadError) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(config).write(to: url, options: .atomic)
    }
}

public enum SnagError: Error, LocalizedError, Equatable {
    case configUnreadable(String)
    case notASession(String)
    case noSuchItem(Int)
    case badName(String)

    public var errorDescription: String? {
        switch self {
        case .configUnreadable(let s): return "The settings file could not be read, so it was not overwritten: \(s)"
        case .notASession(let s): return "\(s) is not a Snagbook session (no session.json)."
        case .noSuchItem(let id): return "Item \(id) does not exist."
        case .badName(let s): return "“\(s)” cannot be used as a name."
        }
    }
}
