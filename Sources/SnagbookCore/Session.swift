import Foundation

public struct ItemRecord: Codable, Equatable, Identifiable {
    /// Permanent number, never reused within a session; it prefixes the folder name.
    public var id: Int
    public var folder: String
    public var title: String
    public var created: Date
}

public struct Manifest: Codable, Equatable {
    public var format: Int = 1
    public var id: String
    public var created: Date
    /// A name the user gave the session ("Inventory pass", "Build 412"); nil until then.
    public var title: String?
    /// This session's own header, placeholders unfilled. Nil: follow the global header
    /// (`Session.fallbackHeader`), so changing it in the settings reaches every session.
    public var header: String?
    /// Display order.
    public var items: [ItemRecord]
    public var nextItem: Int
}

/// One test session: a folder holding session.json, README.md and a folder per item.
///
///     a1b2c3d4_24-09-2026/
///       README.md          header + every item's note, for whoever reads it next
///       session.json       order, titles, ids
///       01-main-menu/
///         notes.md         the note, Markdown with a small front matter
///         media/           shot-001.png, clip-001.mp4, clip-001-frames/, …
public final class Session {
    public let url: URL
    /// How to spell the folder for people and other programs ("~/…").
    public let displayPath: String
    public private(set) var manifest: Manifest
    private let fileIdentity: String?
    /// The header used when the session has none of its own (the app's global setting).
    public var fallbackHeader: String = Config.defaultHeader {
        didSet { if manifest.header == nil, oldValue != fallbackHeader { try? writeReadme() } }
    }

    public static let manifestName = "session.json"
    public static let readmeName = "README.md"
    public static let noteName = "notes.md"
    public static let mediaName = "media"

    private let fm = FileManager.default

    init(url: URL, displayPath: String, manifest: Manifest, fallbackHeader: String = Config.defaultHeader) {
        self.url = url
        self.displayPath = displayPath
        self.manifest = manifest
        self.fallbackHeader = fallbackHeader
        self.fileIdentity = Self.identity(of: url)
    }

    // MARK: - create / open / list

    /// Make a new session folder under `root` (e.g. "~/Snagbook").
    public static func create(root: String, config: Config, now: Date = Date(), hash: String = Naming.randomHash()) throws -> Session {
        let rootURL = Paths.url(root)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var name = Naming.sessionFolder(format: config.folderFormat, date: now, hash: hash)
        var n = 2
        while FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(name).path) {
            name = Naming.sessionFolder(format: config.folderFormat, date: now, hash: hash) + "-\(n)"
            n += 1
        }
        let url = rootURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let display = (root.hasSuffix("/") ? String(root.dropLast()) : root) + "/" + name
        let s = Session(url: url, displayPath: Paths.abbreviate(Paths.expand(display)),
                        manifest: Manifest(id: hash, created: now, title: nil, header: nil, items: [], nextItem: 1))
        s.fallbackHeader = config.header
        try s.save(requireManifest: false)
        return s
    }

    /// Open an existing session folder. `path` may use "~".
    public static func open(_ path: String, fallbackHeader: String = Config.defaultHeader) throws -> Session {
        let url = Paths.url(path).resolvingSymlinksInPath()
        let data: Data
        do { data = try Data(contentsOf: url.appendingPathComponent(manifestName)) } catch { throw SnagError.notASession(path) }
        let manifest = try decoder.decode(Manifest.self, from: data)
        let s = Session(url: url, displayPath: Paths.abbreviate(Paths.expand(path)), manifest: manifest, fallbackHeader: fallbackHeader)
        s.repair()
        return s
    }

    public struct Summary: Equatable {
        public var path: String
        public var title: String
        public var created: Date
        public var items: Int
        public var firstTitles: [String]
    }

    /// Sessions under `root`, newest first. Folders without a session.json are ignored.
    public static func list(root: String) -> [Summary] {
        let rootURL = Paths.url(root)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: rootURL.path) else { return [] }
        var out: [Summary] = []
        for name in names where !name.hasPrefix(".") {
            let u = rootURL.appendingPathComponent(name).appendingPathComponent(manifestName)
            guard let d = try? Data(contentsOf: u), let m = try? decoder.decode(Manifest.self, from: d) else { continue }
            let display = (root.hasSuffix("/") ? String(root.dropLast()) : root) + "/" + name
            out.append(Summary(path: Paths.abbreviate(Paths.expand(display)), title: m.title ?? defaultTitle(m.created), created: m.created, items: m.items.count, firstTitles: m.items.prefix(3).map(\.title)))
        }
        return out.sorted { $0.created > $1.created }
    }

    /// Whether the session is still present on disk. Its folder can disappear while the
    /// app has it open.
    public var exists: Bool {
        matchesDiskIdentity
    }

    /// The path still names the session that was opened, rather than a replacement folder.
    public var matchesDiskIdentity: Bool {
        guard let data = try? Data(contentsOf: url.appendingPathComponent(Self.manifestName)),
              let disk = try? Self.decoder.decode(Manifest.self, from: data) else { return false }
        guard disk.id == manifest.id else { return false }
        guard let fileIdentity else { return true }
        return Self.identity(of: url) == fileIdentity
    }

    /// Whether two open objects still refer to the same session folder on disk.
    public func isSameSession(as other: Session) -> Bool {
        guard manifest.id == other.manifest.id,
              matchesDiskIdentity, other.matchesDiskIdentity else { return false }
        if let fileIdentity, let otherIdentity = other.fileIdentity {
            return fileIdentity == otherIdentity
        }
        return url.resolvingSymlinksInPath().standardizedFileURL == other.url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Folders may have been renamed or removed by hand: drop records whose folder is gone,
    /// and adopt item folders that exist on disk but are missing from the manifest.
    func repair() {
        var changed = false
        let before = manifest.items.count
        manifest.items.removeAll { !fm.fileExists(atPath: url.appendingPathComponent($0.folder).path) }
        changed = changed || manifest.items.count != before
        let known = Set(manifest.items.map(\.folder))
        let names = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
        for name in names where !known.contains(name) {
            guard let num = Int(name.prefix(while: { $0.isNumber })), num > 0, name.prefix(while: { $0.isNumber }).count >= 2 else { continue }
            let note = url.appendingPathComponent(name).appendingPathComponent(Self.noteName)
            guard fm.fileExists(atPath: note.path) else { continue }
            let text = (try? String(contentsOf: note, encoding: .utf8)) ?? ""
            let title = FrontMatter.split(text).fields.first { $0.key == "title" }?.value ?? name
            if manifest.items.contains(where: { $0.id == num }) { continue }
            manifest.items.append(ItemRecord(id: num, folder: name, title: title, created: Date()))
            manifest.nextItem = max(manifest.nextItem, num + 1)
            changed = true
        }
        let next = manifest.nextItem
        settleNextItem()
        changed = changed || manifest.nextItem != next
        if changed { try? save() }
    }

    /// The next item takes the number after the highest remaining one, so deleting from the
    /// end gives the numbers back (1 3 4 → 5; delete 4 → 4). A numbered folder still on disk
    /// keeps its number.
    func settleNextItem() {
        let taken = Set(((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).compactMap { Int($0.prefix(while: { $0.isNumber })) })
        var n = (manifest.items.map(\.id).max() ?? 0) + 1
        while taken.contains(n) { n += 1 }
        manifest.nextItem = n
    }

    // MARK: - items

    public func item(_ id: Int) throws -> ItemRecord {
        guard let it = manifest.items.first(where: { $0.id == id }) else { throw SnagError.noSuchItem(id) }
        return it
    }

    public func itemURL(_ id: Int) throws -> URL { url.appendingPathComponent(try item(id).folder, isDirectory: true) }
    public func noteURL(_ id: Int) throws -> URL { try itemURL(id).appendingPathComponent(Self.noteName) }
    public func mediaURL(_ id: Int) throws -> URL { try itemURL(id).appendingPathComponent(Self.mediaName, isDirectory: true) }
    public func itemIdentity(_ id: Int) throws -> String? {
        Self.identity(of: try itemURL(id))
    }

    public func isSameItem(_ id: Int, identity: String) -> Bool {
        (try? itemIdentity(id)) == identity
    }

    public func reopenedMatchingItem(_ id: Int, identity: String, fallbackHeader: String) throws -> Session {
        let current = try Session.loadWithoutRepair(url.path, fallbackHeader: fallbackHeader)
        guard current.isSameSession(as: self) else { throw SnagError.notASession(displayPath) }
        current.repair()
        guard current.isSameItem(id, identity: identity) else { throw SnagError.noSuchItem(id) }
        return current
    }

    private static func loadWithoutRepair(_ path: String, fallbackHeader: String) throws -> Session {
        let url = Paths.url(path).resolvingSymlinksInPath()
        let data: Data
        do { data = try Data(contentsOf: url.appendingPathComponent(manifestName)) } catch { throw SnagError.notASession(path) }
        let manifest = try decoder.decode(Manifest.self, from: data)
        return Session(url: url, displayPath: Paths.abbreviate(Paths.expand(path)), manifest: manifest, fallbackHeader: fallbackHeader)
    }

    /// Add an item after the others. With no title it is "Item N".
    @discardableResult
    public func addItem(title: String? = nil, now: Date = Date()) throws -> ItemRecord {
        try requireExists()
        let id = manifest.nextItem
        let t = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Item \(id)"
        let folder = Naming.itemFolder(id: id, title: t)
        let dir = url.appendingPathComponent(folder, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        let record = ItemRecord(id: id, folder: folder, title: t, created: now)
        let note = FrontMatter.join(raw: "", updates: [("title", t), ("created", Self.iso(now))], body: "")
        try Data(note.utf8).write(to: dir.appendingPathComponent(Self.noteName), options: .atomic)
        manifest.items.append(record)
        manifest.nextItem = id + 1
        try save()
        return record
    }

    /// Rename an item: its title, its note's front matter and its folder name.
    @discardableResult
    public func renameItem(_ id: Int, to title: String) throws -> ItemRecord {
        try requireExists()
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw SnagError.badName(title) }
        guard let i = manifest.items.firstIndex(where: { $0.id == id }) else { throw SnagError.noSuchItem(id) }
        var rec = manifest.items[i]
        if rec.title == t { return rec }
        let newFolder = Naming.itemFolder(id: id, title: t)
        if newFolder != rec.folder {
            let from = url.appendingPathComponent(rec.folder)
            let to = url.appendingPathComponent(newFolder)
            if !fm.fileExists(atPath: to.path) {
                try fm.moveItem(at: from, to: to)
                rec.folder = newFolder
            }
        }
        rec.title = t
        manifest.items[i] = rec
        let noteURL = url.appendingPathComponent(rec.folder).appendingPathComponent(Self.noteName)
        let text = (try? String(contentsOf: noteURL, encoding: .utf8)) ?? ""
        let parts = FrontMatter.split(text)
        try Data(FrontMatter.join(raw: parts.raw, updates: [("title", t)], body: parts.body).utf8).write(to: noteURL, options: .atomic)
        try save()
        return rec
    }

    /// Remove an item. `discard` decides what happens to the folder (the app moves it to
    /// the Trash); the default deletes it.
    public func deleteItem(_ id: Int, discard: ((URL) throws -> Void)? = nil) throws {
        try requireExists()
        let dir = try itemURL(id)
        if let discard { try discard(dir) } else { try fm.removeItem(at: dir) }
        manifest.items.removeAll { $0.id == id }
        settleNextItem()
        try save()
    }

    /// Remove the whole session. The app supplies a discard that moves the folder to the
    /// Trash; keeping that policy outside the core also makes other front ends portable.
    public func delete(discard: (URL) throws -> Void) throws {
        try requireExists()
        try discard(url)
    }

    /// A `discard` for deleteItem: move the folder to the Trash, and when its volume has none
    /// (a network share) delete it outright only if `deletePermanently` agrees. Declining throws
    /// CocoaError(.userCancelled), so the item stays.
    public static func trashOrDelete(trash: @escaping (URL) throws -> Void,
                                     deletePermanently: @escaping (URL) -> Bool) -> (URL) throws -> Void {
        { url in
            do {
                try trash(url)
            } catch let e as CocoaError where e.code == .featureUnsupported {
                guard deletePermanently(url) else { throw CocoaError(.userCancelled) }
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    public func moveItem(_ id: Int, to index: Int) throws {
        try requireExists()
        guard let from = manifest.items.firstIndex(where: { $0.id == id }) else { throw SnagError.noSuchItem(id) }
        let rec = manifest.items.remove(at: from)
        manifest.items.insert(rec, at: max(0, min(index, manifest.items.count)))
        try save()
    }

    /// Give this session its own header; nil goes back to the global one.
    /// The session's name: what the user called it, or when it started.
    public var title: String { manifest.title ?? Self.defaultTitle(manifest.created) }

    public static func defaultTitle(_ created: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM, HH:mm"
        return "Session " + f.string(from: created)
    }

    /// Name the session; an empty name goes back to the date.
    public func setTitle(_ title: String) throws {
        try requireExists()
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        manifest.title = t.isEmpty ? nil : t
        try save()
    }

    public func setHeader(_ header: String?) throws {
        try requireExists()
        manifest.header = header
        try save()
    }

    // MARK: - notes

    /// The note's Markdown without its front matter.
    public func readNote(_ id: Int) throws -> String {
        let text = try String(contentsOf: try noteURL(id), encoding: .utf8)
        return FrontMatter.split(text).body
    }

    /// Store the note's Markdown, keeping its front matter. Returns false when the file
    /// already held exactly this.
    @discardableResult
    public func writeNote(_ id: Int, body: String) throws -> Bool {
        try requireExists()
        let u = try noteURL(id)
        let old = try String(contentsOf: u, encoding: .utf8)
        let parts = FrontMatter.split(old)
        let rec = try item(id)
        let new = FrontMatter.join(raw: parts.raw, updates: parts.fields.isEmpty ? [("title", rec.title), ("created", Self.iso(rec.created))] : [], body: body)
        if new == old { return false }
        try Data(new.utf8).write(to: u, options: .atomic)
        try writeReadme()
        return true
    }

    // MARK: - media

    /// Save bytes into the item's media folder under the next free "prefix-NNN.ext".
    /// Returns the path relative to the item folder ("media/shot-001.png").
    public func saveMedia(_ id: Int, data: Data, prefix: String, ext: String) throws -> String {
        try requireExists()
        let media = try mediaURL(id)
        try ensureDirectory(media)
        let name = Naming.nextMediaName(prefix: prefix, ext: ext.lowercased(), existing: Set((try? fm.contentsOfDirectory(atPath: media.path)) ?? []))
        try data.write(to: media.appendingPathComponent(name), options: .atomic)
        return Self.mediaName + "/" + name
    }

    /// Hold a free name in the item's media folder for a file that will be written later.
    public func reserveMediaName(_ id: Int, prefix: String, ext: String) throws -> (relative: String, url: URL) {
        try requireExists()
        let media = try mediaURL(id)
        try ensureDirectory(media)
        while true {
            let name = Naming.nextMediaName(prefix: prefix, ext: ext.lowercased(), existing: Set((try? fm.contentsOfDirectory(atPath: media.path)) ?? []))
            let url = media.appendingPathComponent(name)
            do {
                try Data().write(to: url, options: .withoutOverwriting)
                return (Self.mediaName + "/" + name, url)
            } catch let e as CocoaError where e.code == .fileWriteFileExists {
                continue
            }
        }
    }

    public struct MediaCount: Equatable {
        public var images = 0, videos = 0
        public init(images: Int = 0, videos: Int = 0) { self.images = images; self.videos = videos }
    }

    public func mediaCount(_ id: Int) -> MediaCount {
        var c = MediaCount()
        guard let media = try? mediaURL(id), let names = try? fm.contentsOfDirectory(atPath: media.path) else { return c }
        for n in names {
            let l = n.lowercased()
            if l.hasSuffix(".orig.png") { continue }
            if [".png", ".jpg", ".jpeg", ".gif", ".heic", ".tiff", ".webp"].contains(where: l.hasSuffix) { c.images += 1 }
            if [".mp4", ".mov", ".m4v", ".webm"].contains(where: l.hasSuffix) { c.videos += 1 }
        }
        return c
    }

    // MARK: - README and hand-off

    public var renderedHeader: String {
        Header.render(manifest.header ?? fallbackHeader, session: displayPath, date: manifest.created, items: manifest.items.count)
    }

    /// README.md: the header, then every item's note with its links pointing into the item's
    /// folder, so one file is the whole session.
    public func readmeText() -> String {
        var out = renderedHeader.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        out += "\n---\n\n"
        let n = manifest.items.count
        out += "Session: **\(title)** · folder `\(displayPath)` · started \(Self.iso(manifest.created)) · \(n) item\(n == 1 ? "" : "s")\n"
        for (i, rec) in manifest.items.enumerated() {
            let body = ((try? readNote(rec.id)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let counts = mediaCount(rec.id)
            var media: [String] = []
            if counts.images > 0 { media.append("\(counts.images) image\(counts.images == 1 ? "" : "s")") }
            if counts.videos > 0 { media.append("\(counts.videos) video\(counts.videos == 1 ? "" : "s")") }
            out += "\n## \(i + 1). \(rec.title)\n\n"
            out += "Folder: [`\(rec.folder)/`](\(rec.folder)/\(Self.noteName))" + (media.isEmpty ? "" : " · " + media.joined(separator: ", ")) + "\n\n"
            out += body.isEmpty ? "_(no notes)_\n" : Self.rebaseLinks(body, into: rec.folder) + "\n"
        }
        return out
    }

    public func writeReadme() throws {
        try requireExists()
        let u = url.appendingPathComponent(Self.readmeName)
        let text = readmeText()
        if (try? String(contentsOf: u, encoding: .utf8)) == text { return }
        try Data(text.utf8).write(to: u, options: .atomic)
    }

    /// What Copy Hand-off puts on the clipboard.
    public func handoff(style: HandoffStyle) -> String {
        let readme = displayPath + "/" + Self.readmeName
        switch style {
        case .path: return readme
        case .header:
            let h = renderedHeader.trimmingCharacters(in: .whitespacesAndNewlines)
            return h.contains(displayPath) ? h : h + "\n\n" + readme
        }
    }

    /// Point a note's relative links (media/…) at the item folder, for README.md.
    static func rebaseLinks(_ body: String, into folder: String) -> String {
        var s = body
        for (a, b) in [("](media/", "](\(folder)/media/"), ("src=\"media/", "src=\"\(folder)/media/"), ("](./media/", "](\(folder)/media/")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s
    }

    // MARK: - persistence

    func save(requireManifest: Bool = true) throws {
        if requireManifest { try requireExists() }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: url.appendingPathComponent(Self.manifestName), options: .atomic)
        try writeReadme()
    }

    private func requireExists() throws {
        guard exists else { throw SnagError.notASession(displayPath) }
    }

    private static func identity(of url: URL) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let volume = a[.systemNumber] as? NSNumber,
              let file = a[.systemFileNumber] as? NSNumber else { return nil }
        return "\(volume.uint64Value):\(file.uint64Value)"
    }

    private func ensureDirectory(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue { return }
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: d)
    }
}
