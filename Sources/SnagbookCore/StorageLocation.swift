import Foundation

public enum StorageLocation: String, Codable, Sendable {
    case internalDisk, offDisk, unknown

    public static func classify(isLocal: Bool?, isInternal: Bool?) -> StorageLocation {
        if isLocal == false { return .offDisk }
        guard isLocal == true, let isInternal else { return .unknown }
        return isInternal ? .internalDisk : .offDisk
    }

    public func retainingRecognition(_ previous: StorageLocation?) -> StorageLocation {
        self == .unknown && previous == .offDisk ? .offDisk : self
    }

    /// Volume queries can wait for a disconnected filesystem; run this on a worker.
    public static func detect(at url: URL, volumeInfo: ((URL) throws -> (Bool?, Bool?))? = nil) -> StorageLocation {
        guard let resolved = resolvingLinks(at: url)?.resolvingSymlinksInPath().standardizedFileURL else { return .unknown }
        var candidate = resolved
        let read = volumeInfo ?? readVolume
        while true {
            // An absent mount must not inherit the internal disk beneath /Volumes.
            if candidate.path == "/Volumes", resolved.path.hasPrefix("/Volumes/") { return .unknown }
            do {
                let (local, internalBus) = try read(candidate)
                return classify(isLocal: local, isInternal: internalBus)
            } catch {
                let error = error as NSError
                guard error.domain == NSCocoaErrorDomain,
                      [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) else { return .unknown }
                let parent = candidate.deletingLastPathComponent()
                guard parent != candidate else { return .unknown }
                candidate = parent
            }
        }
    }

    private static func resolvingLinks(at url: URL) -> URL? {
        var pending = url.path.split(separator: "/").map(String.init)
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        var links = 0
        while !pending.isEmpty {
            let component = pending.removeFirst()
            if component == "." { continue }
            if component == ".." { current.deleteLastPathComponent(); continue }
            current.appendPathComponent(component)
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) {
                links += 1
                guard links <= 40 else { return nil }
                current = target.hasPrefix("/") ? URL(fileURLWithPath: "/", isDirectory: true) : current.deletingLastPathComponent()
                pending = target.split(separator: "/").map(String.init) + pending
            }
        }
        return current
    }

    private static func readVolume(_ url: URL) throws -> (Bool?, Bool?) {
        #if os(macOS)
        let values = try url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsInternalKey])
        return (values.volumeIsLocal, values.volumeIsInternal)
        #else
        return (nil, nil)
        #endif
    }
}
