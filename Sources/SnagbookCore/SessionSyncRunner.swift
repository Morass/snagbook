import Foundation

/// Only scheduling state is locked; a blocked destination never holds the lock.
public final class SessionSyncRunner: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable { case synced, pending, deleted, failed(String) }
    private let lock = NSLock()
    private var activeRoots: Set<String> = []
    private var activeSessions: Set<String> = []
    private let makeWorker: @Sendable (LocalSessionStore.Entry) -> SessionSync
    public init(makeWorker: @escaping @Sendable (LocalSessionStore.Entry) -> SessionSync) { self.makeWorker = makeWorker }

    public func submit(_ entries: [LocalSessionStore.Entry], completed: @escaping @Sendable (LocalSessionStore.Entry, Outcome) -> Void) {
        let groups = Dictionary(grouping: entries) { Paths.url($0.target).deletingLastPathComponent().standardizedFileURL.path }
        for (root, group) in groups {
            lock.lock()
            let inserted = activeRoots.insert(root).inserted
            lock.unlock()
            guard inserted else { continue }
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { lock.lock(); activeRoots.remove(root); lock.unlock() }
                for entry in group {
                    let outcome = self.process(entry)
                    completed(entry, outcome)
                }
            }
        }
    }

    private func process(_ entry: LocalSessionStore.Entry) -> Outcome {
        do {
            var current = try JSONDecoder().decode(LocalSessionStore.Entry.self, from: Data(contentsOf: entry.descriptor))
            current.directory = entry.directory
            lock.lock()
            let inserted = activeSessions.insert(current.sessionID).inserted
            lock.unlock()
            guard inserted else { return .pending }
            defer { lock.lock(); activeSessions.remove(current.sessionID); lock.unlock() }
            switch try makeWorker(current).run(current) {
            case .synced: return .synced
            case .pending: return .pending
            case .deleted: return .deleted
            }
        } catch { return .failed(error.localizedDescription) }
    }

}
