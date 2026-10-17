import Foundation

/// Local content is the durable queue. Checkpoints are acknowledgements, never the only copy.
public final class LocalSessionStore: Sendable {
    public let root: URL
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var directory: URL
        public var target: String
        public var sessionID: String
        public var deleteRequested = false
        public var allowCreateParent = false
        public var content: URL { directory.appendingPathComponent("session", isDirectory: true) }
        var descriptor: URL { directory.appendingPathComponent("destination.json") }
    }

    public func entries() throws -> [Entry] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { directory in
                let descriptor = directory.appendingPathComponent("destination.json")
                guard FileManager.default.fileExists(atPath: descriptor.path) else { return nil }
                var entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: descriptor))
                entry.directory = directory
                return entry
            }
    }

    public func entry(target: String) throws -> Entry? {
        let path = Paths.url(target).standardizedFileURL.path
        return try entries().first { Paths.url($0.target).standardizedFileURL.path == path }
    }

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
        let target = Paths.url(destinationRoot).appendingPathComponent(made.url.lastPathComponent).path
        let entry = Entry(directory: directory, target: Paths.abbreviate(target), sessionID: made.manifest.id,
                          allowCreateParent: destinationRoot == Config().sessionsFolder)
        try save(entry)
        let opened = try session(entry, header: config.header)
        try opened.writeReadme()
        return opened
    }

    /// Reads the destination; call on a worker. Publishing the descriptor commits the import.
    public func importSession(_ target: String, header: String) throws -> Session {
        if let entry = try entry(target: target) { return try session(entry, header: header) }
        let remote = Paths.url(target)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let entry = Entry(directory: directory, target: Paths.abbreviate(remote.path), sessionID: try Session.loadManifest(remote).id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            try SessionSync.copyTree(from: remote, to: entry.content)
            var checkpoint = SessionSync.Checkpoint()
            checkpoint.files = try SessionSync.digests(in: entry.content)
            // Validate against the source too: importing a changing directory is retried, not published.
            guard checkpoint.files == (try SessionSync.digests(in: remote)) else { throw SyncError.changing }
            checkpoint.targetIdentity = try SessionSync.directoryIdentity(remote)
            checkpoint.parentIdentity = try SessionSync.directoryIdentity(remote.deletingLastPathComponent())
            checkpoint.localStamps = try SessionSync.stamps(in: entry.content)
            try SessionSync.save(checkpoint, entry: entry)
            try save(entry)
            return try session(entry, header: header)
        } catch {
            try? FileManager.default.removeItem(at: directory)
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
