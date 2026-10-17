import Foundation

// Network volumes often have no system Trash. A same-volume archive keeps deletion reversible.
enum DestinationTrash {
    static func handler(for parent: URL, systemTrash: @escaping @Sendable (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }) -> @Sendable (URL) throws -> Void {
        { source in
            let fm = FileManager.default
            do { try systemTrash(source) }
            catch {
                let archive = parent.appendingPathComponent(".snagbook-trash", isDirectory: true)
                if !fm.fileExists(atPath: archive.path) { try fm.createDirectory(at: archive, withIntermediateDirectories: false) }
                let attrs = try fm.attributesOfItem(atPath: archive.path)
                guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw error }
                try fm.moveItem(at: source, to: archive.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent))
            }
        }
    }
}
