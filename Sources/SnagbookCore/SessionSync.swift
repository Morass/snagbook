import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public final class SessionSync: Sendable {
    public enum Result: Equatable, Sendable { case synced, pending, deleted }
    struct Stamp: Codable, Equatable {
        var size: UInt64
        var modified: Date
        var identity: String
    }
    struct Receipt: Codable { var desired: String? }
    struct Checkpoint: Codable {
        var files: [String: String] = [:]
        var receipts: [String: Receipt] = [:]
        var localStamps: [String: Stamp]? = nil
        var parentIdentity: String? = nil
        var targetIdentity: String? = nil
        var deleted = false
        var creatingTarget = false
    }
    private let trash: @Sendable (URL) throws -> Void
    // The injected boundary also proves a stalled destination never runs on the UI thread.
    private let beforeDestinationAccess: (@Sendable () -> Void)?
    public init(trash: @escaping @Sendable (URL) throws -> Void, beforeDestinationAccess: (@Sendable () -> Void)? = nil) {
        self.trash = trash
        self.beforeDestinationAccess = beforeDestinationAccess
    }

    public func run(_ entry: LocalSessionStore.Entry) throws -> Result {
        let lease = open(entry.directory.appendingPathComponent(".sync-lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        guard lease >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(lease) }
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else { return .pending }
        let fm = FileManager.default
        var checkpoint = try Self.load(entry)
        if checkpoint.deleted { return .deleted }
        let stamps = try Self.stamps(in: entry.content)
        if !entry.deleteRequested, checkpoint.receipts.isEmpty, checkpoint.localStamps == stamps { return .synced }
        beforeDestinationAccess?()
        let destination = Paths.url(entry.target)
        let parent = destination.deletingLastPathComponent()
        if entry.allowCreateParent, !fm.fileExists(atPath: parent.path), !parent.path.hasPrefix("/Volumes/") {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        guard fm.fileExists(atPath: parent.path) else { throw SyncError.unavailable }
        #if os(macOS)
        if parent.path.hasPrefix("/Volumes/") {
            let volume = try parent.resourceValues(forKeys: [.volumeURLKey]).volume
            guard volume?.path != "/" else { throw SyncError.unavailable }
        }
        #endif
        let parentIdentity = try Self.directoryIdentity(parent)
        if let expected = checkpoint.parentIdentity, expected != parentIdentity { throw SyncError.conflict("destination folder") }
        if checkpoint.parentIdentity == nil { checkpoint.parentIdentity = parentIdentity; try Self.save(checkpoint, entry: entry) }
        if !fm.fileExists(atPath: destination.path) {
            if checkpoint.targetIdentity != nil {
                if entry.deleteRequested { checkpoint.deleted = true; try Self.save(checkpoint, entry: entry); return .deleted }
                throw SyncError.unavailable
            }
            if entry.deleteRequested { checkpoint.deleted = true; try Self.save(checkpoint, entry: entry); return .deleted }
            checkpoint.creatingTarget = true
            try Self.save(checkpoint, entry: entry)
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            checkpoint.creatingTarget = false
            checkpoint.targetIdentity = try Self.directoryIdentity(destination)
            try Self.save(checkpoint, entry: entry)
        } else {
            let identity = try Self.directoryIdentity(destination)
            if checkpoint.targetIdentity == nil, checkpoint.creatingTarget, try Self.stamps(in: destination).isEmpty {
                checkpoint.targetIdentity = identity
                checkpoint.creatingTarget = false
                try Self.save(checkpoint, entry: entry)
            }
            guard checkpoint.targetIdentity == identity else { throw SyncError.conflict("session folder") }
        }
        if let manifest = checkpoint.files[Session.manifestName] {
            let current = try Self.digestIfPresent(destination.appendingPathComponent(Session.manifestName))
            guard current == manifest || (checkpoint.receipts[Session.manifestName].map { current == $0.desired } ?? false) else { throw SyncError.conflict(Session.manifestName) }
        }
        // A write may have reached the drive immediately before the process exited.
        for (path, receipt) in checkpoint.receipts {
            let remote = try Self.file(path, under: destination)
            let actual = try Self.digestIfPresent(remote)
            if actual == receipt.desired {
                checkpoint.files[path] = actual
                checkpoint.receipts[path] = nil
            } else if actual == checkpoint.files[path] {
                checkpoint.receipts[path] = nil
            } else { throw SyncError.conflict(path) }
        }
        try Self.save(checkpoint, entry: entry)
        if entry.deleteRequested {
            guard try Self.digests(in: destination) == checkpoint.files else { throw SyncError.conflict("session contents") }
            try trash(destination)
            checkpoint.deleted = true
            try Self.save(checkpoint, entry: entry)
            return .deleted
        }
        let snapshot = entry.directory.appendingPathComponent(".snapshot")
        if fm.fileExists(atPath: snapshot.path) { try fm.removeItem(at: snapshot) }
        defer { try? fm.removeItem(at: snapshot) }
        try Self.copyTree(from: entry.content, to: snapshot)
        let desired = try Self.digests(in: snapshot)
        guard stamps == (try Self.stamps(in: entry.content)), desired == (try Self.digests(in: entry.content)) else { return .pending }
        let changed = Set(desired.keys).union(checkpoint.files.keys).filter { desired[$0] != checkpoint.files[$0] }
        // Preflight the entire change before publishing any part of it.
        for path in changed {
            let actual = try Self.digestIfPresent(Self.file(path, under: destination))
            guard actual == checkpoint.files[path] || actual == desired[path] else { throw SyncError.conflict(path) }
        }
        let writes = changed.filter { desired[$0] != nil }.sorted {
            func rank(_ p: String) -> Int { p == Session.readmeName ? 3 : p == Session.manifestName ? 2 : p.hasSuffix("/notes.md") ? 1 : 0 }
            return rank($0) == rank($1) ? $0 < $1 : rank($0) < rank($1)
        }
        for path in writes + changed.filter({ desired[$0] == nil }).sorted() {
            guard try Self.directoryIdentity(destination) == checkpoint.targetIdentity else { throw SyncError.conflict("session folder") }
            let remote = try Self.file(path, under: destination)
            let actual = try Self.digestIfPresent(remote)
            guard actual == checkpoint.files[path] || actual == desired[path] else { throw SyncError.conflict(path) }
            checkpoint.receipts[path] = Receipt(desired: desired[path])
            try Self.save(checkpoint, entry: entry)
            if let digest = desired[path] {
                try Self.makeParents(of: remote, under: destination)
                let temporary = remote.deletingLastPathComponent().appendingPathComponent(".snagbook-\(UUID().uuidString)")
                defer { try? fm.removeItem(at: temporary) }
                try fm.copyItem(at: snapshot.appendingPathComponent(path), to: temporary)
                let current = try Self.digestIfPresent(remote)
                guard current == actual else { throw SyncError.conflict(path) }
                // rename is atomic on the destination filesystem; copying from local storage is not.
                guard rename(temporary.path, remote.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                checkpoint.files[path] = digest
            } else {
                if actual != nil { try trash(remote) }
                checkpoint.files[path] = nil
            }
            checkpoint.receipts[path] = nil
            try Self.save(checkpoint, entry: entry)
        }
        checkpoint.localStamps = stamps
        try Self.save(checkpoint, entry: entry)
        return try Self.stamps(in: entry.content) == stamps ? .synced : .pending
    }

    static func load(_ entry: LocalSessionStore.Entry) throws -> Checkpoint {
        let url = entry.directory.appendingPathComponent("checkpoint.json")
        if !FileManager.default.fileExists(atPath: url.path) { return Checkpoint() }
        return try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: url))
    }
    static func save(_ checkpoint: Checkpoint, entry: LocalSessionStore.Entry) throws {
        try JSONEncoder().encode(checkpoint).write(to: entry.directory.appendingPathComponent("checkpoint.json"), options: .atomic)
    }
    static func directoryIdentity(_ url: URL) throws -> String {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeDirectory else { throw SyncError.invalidPath }
        return "\(a[.systemNumber] ?? ""):\(a[.systemFileNumber] ?? "")"
    }
    static func stamps(in root: URL) throws -> [String: Stamp] {
        _ = try directoryIdentity(root)
        var result: [String: Stamp] = [:]
        let fm = FileManager.default
        func visit(_ directory: URL, prefix: String) throws {
            for name in try fm.contentsOfDirectory(atPath: directory.path) where !name.hasPrefix(".") {
                let url = directory.appendingPathComponent(name)
                let a = try fm.attributesOfItem(atPath: url.path)
                switch a[.type] as? FileAttributeType {
                case .typeDirectory: try visit(url, prefix: prefix + name + "/")
                case .typeRegular:
                    guard (a[.referenceCount] as? NSNumber)?.intValue == 1 else { throw SyncError.invalidPath }
                    result[prefix + name] = Stamp(size: (a[.size] as? NSNumber)?.uint64Value ?? 0,
                        modified: a[.modificationDate] as? Date ?? .distantPast,
                        identity: "\(a[.systemNumber] ?? ""):\(a[.systemFileNumber] ?? "")")
                default: throw SyncError.invalidPath
                }
            }
        }
        try visit(root, prefix: "")
        return result
    }
    static func digests(in root: URL) throws -> [String: String] {
        try stamps(in: root).mapValuesWithKeys { key in try ContentDigest.file(file(key, under: root)) }
    }
    static func digestIfPresent(_ url: URL) throws -> String? {
        do {
            let a = try FileManager.default.attributesOfItem(atPath: url.path)
            guard a[.type] as? FileAttributeType == .typeRegular, (a[.referenceCount] as? NSNumber)?.intValue == 1 else { throw SyncError.invalidPath }
            return try ContentDigest.file(url)
        } catch let e as NSError where e.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(e.code) { return nil }
    }
    static func file(_ relative: String, under root: URL) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { throw SyncError.invalidPath }
        var url = root
        for part in parts.dropLast() {
            url.appendPathComponent(String(part))
            if FileManager.default.fileExists(atPath: url.path) { _ = try directoryIdentity(url) }
            else if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil { throw SyncError.invalidPath }
        }
        return root.appendingPathComponent(relative)
    }
    static func makeParents(of file: URL, under root: URL) throws {
        let relative = file.deletingLastPathComponent().path.dropFirst(root.path.count)
        var directory = root
        for part in relative.split(separator: "/") {
            directory.appendPathComponent(String(part))
            if !FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
            _ = try directoryIdentity(directory)
        }
    }
    static func copyTree(from source: URL, to target: URL) throws {
        let before = try stamps(in: source)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        for relative in before.keys {
            let to = try file(relative, under: target)
            try makeParents(of: to, under: target)
            try FileManager.default.copyItem(at: file(relative, under: source), to: to)
        }
        guard before == (try stamps(in: source)) else { throw SyncError.changing }
    }
}

private extension Dictionary {
    func mapValuesWithKeys<T>(_ transform: (Key) throws -> T) rethrows -> [Key: T] {
        try Dictionary<Key, T>(uniqueKeysWithValues: keys.map { ($0, try transform($0)) })
    }
}
