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
    struct Receipt: Codable { var desired: String?; var temporary: String? = nil }
    struct Checkpoint: Codable {
        var files: [String: String] = [:]
        var receipts: [String: Receipt] = [:]
        var localStamps: [String: Stamp]? = nil
        var localDigests: [String: String]? = nil
        var parentIdentity: String? = nil
        var resolvedParent: String? = nil
        var targetIdentity: String? = nil
        var lastChecked: Date? = nil
        var deleted = false
        var creatingTarget = false
    }
    private let trash: @Sendable (URL) throws -> Void
    // The injected boundary also proves a stalled destination never runs on the UI thread.
    private let beforeDestinationAccess: (@Sendable () -> Void)?
    private let acknowledgementCheckInterval: TimeInterval
    public init(trash: @escaping @Sendable (URL) throws -> Void, beforeDestinationAccess: (@Sendable () -> Void)? = nil, acknowledgementCheckInterval: TimeInterval = 0) {
        self.trash = trash
        self.beforeDestinationAccess = beforeDestinationAccess
        self.acknowledgementCheckInterval = acknowledgementCheckInterval
    }

    public func run(_ entry: LocalSessionStore.Entry) throws -> Result {
        let lease = open(entry.directory.appendingPathComponent(".sync-lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        guard lease >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(lease) }
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else { return .pending }
        let fm = FileManager.default
        var checkpoint = try Self.load(entry)
        if checkpoint.deleted { return try Self.retire(checkpoint, entry: entry) }
        let stamps = try Self.stamps(in: entry.content)
        let unchanged = !entry.deleteRequested && checkpoint.receipts.isEmpty && checkpoint.localStamps == stamps
        if unchanged, let checked = checkpoint.lastChecked {
            let elapsed = Date().timeIntervalSince(checked)
            if elapsed >= 0 && elapsed < acknowledgementCheckInterval { return .synced }
        }
        beforeDestinationAccess?()
        let requested = Paths.url(entry.target)
        let parent = requested.deletingLastPathComponent().resolvingSymlinksInPath()
        let destination = parent.appendingPathComponent(requested.lastPathComponent)
        let sameSession = (try? Session.loadManifest(destination).id) == entry.sessionID
        if let expected = checkpoint.resolvedParent, expected != parent.path, !sameSession { throw SyncError.conflict("destination path") }
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
        if let expected = checkpoint.parentIdentity, expected != parentIdentity,
           !sameSession, checkpoint.targetIdentity != nil { throw SyncError.conflict("destination folder") }
        if checkpoint.parentIdentity != parentIdentity || checkpoint.resolvedParent != parent.path {
            checkpoint.parentIdentity = parentIdentity
            checkpoint.resolvedParent = parent.path
            try Self.save(checkpoint, entry: entry)
        }
        if !fm.fileExists(atPath: destination.path) {
            if checkpoint.targetIdentity != nil {
                if entry.deleteRequested { return try Self.retire(checkpoint, entry: entry) }
                throw SyncError.unavailable
            }
            if entry.deleteRequested { return try Self.retire(checkpoint, entry: entry) }
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
            if checkpoint.targetIdentity != identity {
                guard sameSession else { throw SyncError.conflict("session folder") }
                checkpoint.targetIdentity = identity
                try Self.save(checkpoint, entry: entry)
            }
        }
        if let manifest = checkpoint.files[Session.manifestName] {
            let current = try Self.digestIfPresent(destination.appendingPathComponent(Session.manifestName))
            guard current == manifest || (checkpoint.receipts[Session.manifestName].map { current == $0.desired } ?? false) else { throw SyncError.conflict(Session.manifestName) }
        }
        // A write may have reached the drive immediately before the process exited.
        for (path, receipt) in checkpoint.receipts {
            let remote = try Self.file(path, under: destination)
            if let name = receipt.temporary {
                let temporary = try Self.file(name, under: destination)
                guard temporary.deletingLastPathComponent() == remote.deletingLastPathComponent(),
                      temporary.lastPathComponent.hasPrefix(".snagbook-"),
                      UUID(uuidString: String(temporary.lastPathComponent.dropFirst(".snagbook-".count))) != nil else { throw SyncError.invalidPath }
                if try Self.digestIfPresent(temporary) != nil { try fm.removeItem(at: temporary) }
            }
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
            return try Self.retire(checkpoint, entry: entry)
        }
        if unchanged {
            let readme = try Self.digestIfPresent(destination.appendingPathComponent(Session.readmeName))
            guard readme == checkpoint.files[Session.readmeName] else { throw SyncError.conflict(Session.readmeName) }
            checkpoint.lastChecked = Date()
            try Self.save(checkpoint, entry: entry)
            return .synced
        }
        let snapshot = entry.directory.appendingPathComponent(".snapshot")
        if fm.fileExists(atPath: snapshot.path) { try fm.removeItem(at: snapshot) }
        defer { try? fm.removeItem(at: snapshot) }
        try Self.copyTree(from: entry.content, to: snapshot)
        var desired: [String: String] = [:]
        for (path, stamp) in stamps {
            if checkpoint.localStamps?[path] == stamp, let cached = checkpoint.localDigests?[path] {
                desired[path] = cached
            } else {
                let copied = try ContentDigest.file(Self.file(path, under: snapshot))
                guard copied == (try ContentDigest.file(Self.file(path, under: entry.content))) else { return .pending }
                desired[path] = copied
            }
        }
        guard stamps == (try Self.stamps(in: entry.content)) else { return .pending }
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
            let temporaryName = ".snagbook-\(UUID().uuidString)"
            let components = path.split(separator: "/").dropLast().map(String.init)
            let temporaryPath = (components + [temporaryName]).joined(separator: "/")
            checkpoint.receipts[path] = Receipt(desired: desired[path], temporary: desired[path] == nil ? nil : temporaryPath)
            try Self.save(checkpoint, entry: entry)
            if let digest = desired[path] {
                try Self.makeParents(of: remote, under: destination)
                let temporary = try Self.file(temporaryPath, under: destination)
                defer { try? fm.removeItem(at: temporary) }
                try fm.copyItem(at: snapshot.appendingPathComponent(path), to: temporary)
                let handle = try FileHandle(forWritingTo: temporary)
                do { try handle.synchronize(); try handle.close() }
                catch { try? handle.close(); throw error }
                let current = try Self.digestIfPresent(remote)
                guard current == actual else { throw SyncError.conflict(path) }
                // rename is atomic on the destination filesystem; copying from local storage is not.
                guard rename(temporary.path, remote.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                checkpoint.files[path] = digest
            } else {
                if actual != nil { try trash(remote) }
                var directory = remote.deletingLastPathComponent()
                while directory.path != destination.path && directory.path.hasPrefix(destination.path + "/") {
                    guard rmdir(directory.path) == 0 else { break }
                    directory.deleteLastPathComponent()
                }
                checkpoint.files[path] = nil
            }
            checkpoint.receipts[path] = nil
            try Self.save(checkpoint, entry: entry)
        }
        checkpoint.localStamps = stamps
        checkpoint.localDigests = desired
        checkpoint.lastChecked = Date()
        try Self.save(checkpoint, entry: entry)
        return try Self.stamps(in: entry.content) == stamps ? .synced : .pending
    }

    private static func retire(_ checkpoint: Checkpoint, entry: LocalSessionStore.Entry) throws -> Result {
        var done = checkpoint
        done.deleted = true
        try save(done, entry: entry)
        let retired = entry.directory.deletingLastPathComponent().appendingPathComponent(".retired", isDirectory: true)
        if !FileManager.default.fileExists(atPath: retired.path) { try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: false) }
        _ = try directoryIdentity(retired)
        let target = retired.appendingPathComponent(entry.directory.lastPathComponent)
        try FileManager.default.moveItem(at: entry.directory, to: target)
        try? FileManager.default.removeItem(at: target)
        return .deleted
    }

    public static func hasAcknowledgedContent(_ entry: LocalSessionStore.Entry) throws -> Bool {
        guard !entry.deleteRequested else { return false }
        let checkpoint = try load(entry)
        let current = try stamps(in: entry.content)
        return !checkpoint.deleted && checkpoint.receipts.isEmpty && checkpoint.localStamps == current
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
