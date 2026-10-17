import Foundation

/// Local content is the durable queue. Checkpoints are acknowledgements, never the only copy.
public final class LocalSessionStore: Sendable {
    public let root: URL
    public init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var directory: URL
        public var target: String
        public var sessionID: String
        public var deleteRequested = false
        public var allowCreateParent = false
        public var key: String { directory.lastPathComponent }
        public var content: URL { directory.appendingPathComponent("session", isDirectory: true) }
        var descriptor: URL { directory.appendingPathComponent("destination.json") }
    }

    public struct Scan {
        public var entries: [Entry]
        public var issues: [String: String]
    }

    public func scan() throws -> Scan {
        var result = Scan(entries: [], issues: [:])
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where !directory.lastPathComponent.hasPrefix(".") {
            let descriptor = directory.appendingPathComponent("destination.json")
            guard FileManager.default.fileExists(atPath: descriptor.path) else { continue }
            do {
                var entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: descriptor))
                entry.directory = directory
                result.entries.append(entry)
            } catch { result.issues[directory.lastPathComponent] = "A local queue record needs attention: " + error.localizedDescription }
        }
        return result
    }

    public func entries() throws -> [Entry] { try scan().entries }

    public func entry(target: String) throws -> Entry? {
        let path = Paths.url(target).standardizedFileURL.path
        return try entries().first {
            Paths.url($0.target).standardizedFileURL.path == path && (try? SessionSync.load($0).deleted) != true
        }
    }

    public static func key(for content: URL) -> String { content.deletingLastPathComponent().lastPathComponent }

    public func entry(content: URL) throws -> Entry? {
        try entries().first { $0.content.standardizedFileURL == content.standardizedFileURL }
    }

    public func session(_ entry: Entry, header: String = Config.defaultHeader) throws -> Session {
        guard !entry.deleteRequested else { throw SyncError.pendingDeletion }
        return try Session.open(entry.content.path, fallbackHeader: header, displayPath: entry.target)
    }

    public func create(destinationRoot: String, config: Config) throws -> Session {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let made = try Session.create(root: directory.path, config: config)
        let content = directory.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.moveItem(at: made.url, to: content)
        let prefix = made.url.lastPathComponent + (config.folderFormat.contains("{hash}") ? "" : "-" + made.manifest.id)
        let taken = Set(try entries().map { Paths.url($0.target).standardizedFileURL.path })
        var name = prefix
        while taken.contains(Paths.url(destinationRoot).appendingPathComponent(name).path) { name = prefix + "-" + UUID().uuidString.prefix(8) }
        let target = Paths.url(destinationRoot).appendingPathComponent(name).path
        let entry = Entry(directory: directory, target: Paths.abbreviate(target), sessionID: made.manifest.id,
                          allowCreateParent: destinationRoot == Config().sessionsFolder)
        try save(entry)
        let opened = try session(entry, header: config.header)
        try opened.writeReadme()
        return opened
    }

    /// Reads the destination; call on a worker. Publishing the descriptor commits the import.
    public func importSession(_ target: String, header: String, afterCommit: (@Sendable () throws -> Void)? = nil) throws -> Session {
        if let entry = try entry(target: target) { return try session(entry, header: header) }
        let remote = Paths.url(target).resolvingSymlinksInPath()
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let entry = Entry(directory: directory, target: Paths.abbreviate(Paths.url(target).path), sessionID: try Session.loadManifest(remote).id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            try SessionSync.copyTree(from: remote, to: entry.content)
            var checkpoint = SessionSync.Checkpoint()
            checkpoint.files = try SessionSync.digests(in: entry.content)
            // Validate against the source too: importing a changing directory is retried, not published.
            guard checkpoint.files == (try SessionSync.digests(in: remote)) else { throw SyncError.changing }
            checkpoint.targetIdentity = try SessionSync.directoryIdentity(remote)
            checkpoint.parentIdentity = try SessionSync.directoryIdentity(remote.deletingLastPathComponent())
            checkpoint.resolvedParent = remote.deletingLastPathComponent().path
            checkpoint.localStamps = try SessionSync.stamps(in: entry.content)
            checkpoint.localDigests = checkpoint.files
            try SessionSync.save(checkpoint, entry: entry)
            try save(entry)
            try afterCommit?()
            return try session(entry, header: header)
        } catch {
            if !FileManager.default.fileExists(atPath: entry.descriptor.path) { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }

    public func requestDeletion(_ content: URL) throws {
        guard var entry = try entry(content: content) else { throw SyncError.invalidPath }
        entry.deleteRequested = true
        try save(entry)
    }

    private func save(_ entry: Entry) throws {
        try JSONEncoder().encode(entry).write(to: entry.descriptor, options: .atomic)
    }
}

public enum SyncError: Error, LocalizedError {
    case conflict(String), unavailable, invalidPath, pendingDeletion, changing
    public var errorDescription: String? {
        switch self {
        case .conflict(let file): return "The shared copy changed (\(file)). Your local work is kept; check both copies before retrying."
        case .unavailable: return "Waiting for the destination. Your work is saved locally."
        case .invalidPath: return "Sync stopped because a file or folder is not an ordinary contained path. Your local work is kept."
        case .pendingDeletion: return "This session is waiting to be moved to the destination’s Trash."
        case .changing: return "Saved locally; waiting for the current save to finish."
        }
    }
}


extension LocalSessionStore.Entry {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        directory = try c.decode(URL.self, forKey: .directory)
        target = try c.decode(String.self, forKey: .target)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        deleteRequested = try c.decodeIfPresent(Bool.self, forKey: .deleteRequested) ?? false
        allowCreateParent = try c.decodeIfPresent(Bool.self, forKey: .allowCreateParent) ?? false
    }
}
