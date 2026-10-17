import XCTest
@testable import SnagbookCore

final class SessionSyncTests: XCTestCase {
    var base: URL!
    var destination: URL!
    var store: LocalSessionStore!
    var worker: SessionSync!
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)")
        destination = base.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        store = try LocalSessionStore(root: base.appendingPathComponent("local"))
        worker = SessionSync(trash: { file in
            let trash = self.base.appendingPathComponent("trash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: trash.appendingPathComponent(UUID().uuidString))
        })
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
    func create() throws -> (Session, LocalSessionStore.Entry) {
        let session = try store.create(destinationRoot: destination.path, config: Config())
        return (session, try XCTUnwrap(store.entry(content: session.url)))
    }
    func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testLatestLocalNoteAndMediaReachDestinationAfterStoreRestart() throws {
        let (local, entry) = try create()
        let item = try local.addItem()
        try local.writeNote(item.id, body: "first")
        try local.writeNote(item.id, body: "latest")
        let media = try local.saveMedia(item.id, data: Data([1,2,3,4]), prefix: "shot", ext: "png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.url(entry.target).path))
        let restarted = try LocalSessionStore(root: store.root)
        let restored = try restarted.session(XCTUnwrap(restarted.entry(target: entry.target)))
        XCTAssertEqual(try restored.readNote(item.id), "latest")
        XCTAssertEqual(try worker.run(entry), .synced)
        let remote = try Session.open(entry.target)
        XCTAssertEqual(try remote.readNote(item.id), "latest")
        XCTAssertEqual(try Data(contentsOf: remote.itemURL(item.id).appendingPathComponent(media)), Data([1,2,3,4]))
        XCTAssertTrue(try text(remote.url.appendingPathComponent("README.md")).contains(entry.target))
        XCTAssertFalse(try text(remote.url.appendingPathComponent("README.md")).contains(store.root.path))
    }

    func testUnavailableDestinationDoesNotBlockLocalSavingOrRecreateTheParent() throws {
        let (local, entry) = try create()
        let moved = base.appendingPathComponent("disconnected")
        try FileManager.default.moveItem(at: destination, to: moved)
        let item = try local.addItem()
        try local.writeNote(item.id, body: "offline")
        XCTAssertThrowsError(try worker.run(entry))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try local.readNote(item.id), "offline")
        try FileManager.default.moveItem(at: moved, to: destination)
        XCTAssertEqual(try worker.run(entry), .synced)
    }

    func testRemoteEditWithEqualLengthIsPreservedAndLocalEditRemainsQueued() throws {
        let (local, entry) = try create()
        let item = try local.addItem()
        try local.writeNote(item.id, body: "aaa")
        XCTAssertEqual(try worker.run(entry), .synced)
        let remote = try Session.open(entry.target)
        try remote.writeNote(item.id, body: "bbb")
        try local.writeNote(item.id, body: "ccc")
        XCTAssertThrowsError(try worker.run(entry))
        XCTAssertEqual(try remote.readNote(item.id), "bbb")
        XCTAssertEqual(try local.readNote(item.id), "ccc")
        let restarted = try LocalSessionStore(root: store.root)
        XCTAssertEqual(try restarted.session(entry).readNote(item.id), "ccc")
    }

    func testDeletedSharedSessionIsNeverRecreatedByPendingLocalWork() throws {
        let (local, entry) = try create()
        let item = try local.addItem()
        XCTAssertEqual(try worker.run(entry), .synced)
        try FileManager.default.removeItem(at: Paths.url(entry.target))
        try local.writeNote(item.id, body: "kept locally")
        XCTAssertThrowsError(try worker.run(entry))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.url(entry.target).path))
        XCTAssertEqual(try local.readNote(item.id), "kept locally")
    }

    func testRenameAndDeleteAreSyncedWithoutRemovingUntrackedDestinationFiles() throws {
        let (local, entry) = try create()
        let item = try local.addItem(title: "before")
        try local.writeNote(item.id, body: "retained")
        XCTAssertEqual(try worker.run(entry), .synced)
        let remote = Paths.url(entry.target)
        let extra = remote.appendingPathComponent("external.txt")
        try Data("external".utf8).write(to: extra)
        try local.renameItem(item.id, to: "after")
        XCTAssertEqual(try worker.run(entry), .synced)
        let reopened = try Session.open(entry.target)
        XCTAssertEqual(try reopened.readNote(item.id), "retained")
        XCTAssertEqual(try text(extra), "external")
        try local.deleteItem(item.id)
        XCTAssertEqual(try worker.run(entry), .synced)
        XCTAssertEqual(try Session.loadManifest(remote).items.count, 0)
        XCTAssertEqual(try text(extra), "external")
    }

    func testDeletionRequestSurvivesRestartAndUsesTrash() throws {
        let (local, entry) = try create()
        try local.addItem()
        XCTAssertEqual(try worker.run(entry), .synced)
        try store.requestDeletion(local.url)
        let restart = try LocalSessionStore(root: store.root)
        let pending = try XCTUnwrap(restart.entry(target: entry.target))
        XCTAssertTrue(pending.deleteRequested)
        XCTAssertThrowsError(try restart.session(pending))
        XCTAssertEqual(try worker.run(pending), .deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.url(entry.target).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("trash").path))
    }

    func testDeletionDoesNotDiscardAnUnknownRemoteAddition() throws {
        let (local, entry) = try create()
        XCTAssertEqual(try worker.run(entry), .synced)
        let extra = Paths.url(entry.target).appendingPathComponent("external.txt")
        try Data("precious".utf8).write(to: extra)
        try store.requestDeletion(local.url)
        XCTAssertThrowsError(try worker.run(XCTUnwrap(store.entry(target: entry.target))))
        XCTAssertEqual(try text(extra), "precious")
    }

    func testAcknowledgesAWriteCompletedBeforeItsCheckpointAndThenSendsANewerEdit() throws {
        let (local, entry) = try create()
        let item = try local.addItem()
        try local.writeNote(item.id, body: "old")
        XCTAssertEqual(try worker.run(entry), .synced)
        var checkpoint = try SessionSync.load(entry)
        let note = try local.noteURL(item.id)
        let path = String(note.path.dropFirst(local.url.path.count + 1))
        try local.writeNote(item.id, body: "in flight")
        let desired = try ContentDigest.file(note)
        checkpoint.receipts[path] = SessionSync.Receipt(desired: desired)
        try SessionSync.save(checkpoint, entry: entry)
        try Data(contentsOf: note).write(to: Paths.url(entry.target).appendingPathComponent(path), options: .atomic)
        try local.writeNote(item.id, body: "newer")
        XCTAssertEqual(try worker.run(entry), .synced)
        XCTAssertEqual(try Session.open(entry.target).readNote(item.id), "newer")
    }

    func testDestinationSymlinkCannotRedirectAQueuedWrite() throws {
        let (local, entry) = try create()
        let item = try local.addItem()
        XCTAssertEqual(try worker.run(entry), .synced)
        let remote = try Session.open(entry.target)
        let media = try remote.mediaURL(item.id)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: false)
        try FileManager.default.removeItem(at: media)
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: media, withDestinationURL: outside)
        _ = try local.saveMedia(item.id, data: Data([8]), prefix: "shot", ext: "png")
        XCTAssertThrowsError(try worker.run(entry))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testOpeningCachedSessionAndSavingDoesNotWaitForAStalledDestinationWorker() throws {
        let (local, entry) = try create()
        let item = try local.addItem()
        let entered = expectation(description: "worker entered destination")
        let completed = expectation(description: "worker completed")
        let unblock = DispatchSemaphore(value: 0)
        worker = SessionSync(trash: { _ in }, beforeDestinationAccess: { entered.fulfill(); _ = unblock.wait(timeout: .now() + 4) })
        DispatchQueue.global(qos: .utility).async {
            defer { completed.fulfill() }
            _ = try? self.worker.run(entry)
        }
        wait(for: [entered], timeout: 2)
        let reopened = try store.session(entry)
        try reopened.writeNote(item.id, body: "responsive")
        XCTAssertEqual(try reopened.readNote(item.id), "responsive")
        unblock.signal()
        wait(for: [completed], timeout: 4)
    }

    func testPortableSHA256MatchesPublishedVectorsAndStreaming() throws {
        var empty = PortableSHA256()
        XCTAssertEqual(empty.finish(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        var abc = PortableSHA256()
        abc.update(Data("a".utf8)); abc.update(Data("bc".utf8))
        XCTAssertEqual(abc.finish(), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        var million = PortableSHA256()
        for _ in 0..<1000 { million.update(Data(repeating: 97, count: 1000)) }
        XCTAssertEqual(million.finish(), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
}
