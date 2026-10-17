import XCTest
@testable import SnagbookCore

final class StorageLocationTests: XCTestCase {
    func testOnlyPositivelyIdentifiedOffDiskVolumesUseBackgroundStorage() {
        let cases: [(Bool?, Bool?, StorageLocation)] = [
            (true, true, .internalDisk),
            (true, false, .offDisk),
            (false, nil, .offDisk),
            (nil, false, .unknown),
            (true, nil, .unknown),
            (nil, nil, .unknown)
        ]
        for (local, internalBus, expected) in cases {
            XCTAssertEqual(StorageLocation.classify(isLocal: local, isInternal: internalBus), expected,
                           "local=\(String(describing: local)), internal=\(String(describing: internalBus))")
        }
    }

    func testDisconnectedKnownDestinationRetainsRecognitionButInternalMountReplacesIt() {
        XCTAssertEqual(StorageLocation.unknown.retainingRecognition(.offDisk), .offDisk)
        XCTAssertEqual(StorageLocation.unknown.retainingRecognition(.internalDisk), .unknown)
        XCTAssertEqual(StorageLocation.unknown.retainingRecognition(nil), .unknown)
        XCTAssertEqual(StorageLocation.internalDisk.retainingRecognition(.offDisk), .internalDisk)
    }
    func testMissingChildUsesExistingParentButPermissionFailureDoesNotGuess() {
        let target = URL(fileURLWithPath: "/new-\(UUID().uuidString)")
        var seen: [URL] = []
        let result = StorageLocation.detect(at: target) { url in
            seen.append(url)
            if url == target { throw CocoaError(.fileReadNoSuchFile) }
            return (true, true)
        }
        XCTAssertEqual(result, .internalDisk)
        XCTAssertEqual(seen, [target, target.deletingLastPathComponent()])
        seen = []
        XCTAssertEqual(StorageLocation.detect(at: target) { url in
            seen.append(url)
            throw CocoaError(.fileReadNoPermission)
        }, .unknown)
        XCTAssertEqual(seen, [target])
    }

    func testAbsentMountNeverInheritsTheInternalVolumesDirectory() {
        let target = URL(fileURLWithPath: "/Volumes/missing-\(UUID().uuidString)/notes")
        XCTAssertEqual(StorageLocation.detect(at: target) { url in
            if url.path == "/Volumes" { return (true, true) }
            throw CocoaError(.fileReadNoSuchFile)
        }, .unknown)
    }

    func testDanglingSymlinkToAnAbsentVolumeIsNotAnInternalDestination() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("storage-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let alias = base.appendingPathComponent("share")
        let missingMount = "/Volumes/unmounted-\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: missingMount)
        XCTAssertEqual(StorageLocation.detect(at: alias.appendingPathComponent("notes")) { url in
            if url.path.hasPrefix(missingMount + "/") || url.path == missingMount { throw CocoaError(.fileReadNoSuchFile) }
            return (true, true)
        }, .unknown)
        let relative = base.appendingPathComponent("relative")
        try FileManager.default.createSymbolicLink(atPath: relative.path, withDestinationPath: "share")
        XCTAssertEqual(StorageLocation.detect(at: relative.appendingPathComponent("notes")) { url in
            if url.path.hasPrefix(missingMount + "/") || url.path == missingMount { throw CocoaError(.fileReadNoSuchFile) }
            return (true, true)
        }, .unknown)
    }

    #if os(macOS)
    func testInternalFolderAndSymlinkAreRecognizedWithoutCreatingMissingChildren() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let alias = base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: base)
        let missing = alias.appendingPathComponent("new/subfolder")
        XCTAssertEqual(StorageLocation.detect(at: missing), .internalDisk)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
    #endif

}
