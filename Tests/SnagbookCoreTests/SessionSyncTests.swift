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
    func testCacheRootAliasStillFindsTheWorkingSession() throws {
        let real = base.appendingPathComponent("real-cache")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        let alias = base.appendingPathComponent("cache-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let aliased = try LocalSessionStore(root: alias)
        let session = try aliased.create(destinationRoot: destination.path, config: Config())
        XCTAssertNotNil(try aliased.entry(content: session.url))
        XCTAssertTrue(session.url.path.hasPrefix(aliased.root.path + "/"))
    }

    func testChosenDestinationAliasCanSyncAndImportWithoutLosingItsDisplayPath() throws {
        let alias = base.appendingPathComponent("chosen-destination")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: destination)
        let local = try store.create(destinationRoot: alias.path, config: Config())
        let item = try local.addItem()
        try local.writeNote(item.id, body: "at chosen path")
        let entry = try XCTUnwrap(store.entry(content: local.url))
        XCTAssertEqual(try worker.run(entry), .synced)
        let otherStore = try LocalSessionStore(root: base.appendingPathComponent("other-cache"))
        let imported = try otherStore.importSession(entry.target, header: Config.defaultHeader)
        XCTAssertEqual(imported.displayPath, entry.target)
        let identity = try XCTUnwrap(imported.itemIdentity(item.id))
        let reopened = try imported.reopenedMatchingItem(item.id, identity: identity, fallbackHeader: Config.defaultHeader)
        XCTAssertEqual(reopened.displayPath, entry.target)
        try imported.writeNote(item.id, body: "imported edit")
        XCTAssertEqual(try worker.run(XCTUnwrap(otherStore.entry(content: imported.url))), .synced)
        XCTAssertEqual(try Session.open(entry.target).readNote(item.id), "imported edit")
    }

    func testMissingDestinationManifestStopsWritesIntoTheRemainingFolder() throws {
        let (local, entry) = try create()
        let item = try local.addItem()
        try local.writeNote(item.id, body: "original")
        XCTAssertEqual(try worker.run(entry), .synced)
        let remote = try Session.open(entry.target)
        try FileManager.default.removeItem(at: remote.url.appendingPathComponent(Session.manifestName))
        try local.writeNote(item.id, body: "queued")
        XCTAssertThrowsError(try worker.run(entry))
        let body = try text(remote.url.appendingPathComponent(local.manifest.items[0].folder).appendingPathComponent(Session.noteName))
        XCTAssertTrue(body.contains("original"))
        XCTAssertFalse(body.contains("queued"))
    }

    func testRecoversAnEmptyTargetCreatedBeforeItsIdentityWasCheckpointed() throws {
        let (local, entry) = try create()
        try local.addItem()
        var checkpoint = SessionSync.Checkpoint()
        checkpoint.parentIdentity = try SessionSync.directoryIdentity(destination)
        checkpoint.creatingTarget = true
        try SessionSync.save(checkpoint, entry: entry)
        try FileManager.default.createDirectory(at: Paths.url(entry.target), withIntermediateDirectories: false)
        XCTAssertEqual(try worker.run(entry), .synced)
        XCTAssertEqual(try Session.open(entry.target).manifest.id, local.manifest.id)
    }

    func testRemountedDestinationWithSameSessionCanResume() throws {
        let (local, entry) = try create()
        let item = try local.addItem()
        XCTAssertEqual(try worker.run(entry), .synced)
        var checkpoint = try SessionSync.load(entry)
        checkpoint.parentIdentity = "previous-mount:parent"
        checkpoint.targetIdentity = "previous-mount:session"
        try SessionSync.save(checkpoint, entry: entry)
        try local.writeNote(item.id, body: "after remount")
        XCTAssertEqual(try worker.run(entry), .synced)
        XCTAssertEqual(try Session.open(entry.target).readNote(item.id), "after remount")
    }

    func testRestoredDeletedSessionCanBeOpenedAgain() throws {
        let (local, entry) = try create()
        try local.addItem()
        XCTAssertEqual(try worker.run(entry), .synced)
        try store.requestDeletion(local.url)
        XCTAssertEqual(try worker.run(XCTUnwrap(store.entry(target: entry.target))), .deleted)
        let trash = try FileManager.default.contentsOfDirectory(at: base.appendingPathComponent("trash"), includingPropertiesForKeys: nil)
        try FileManager.default.moveItem(at: XCTUnwrap(trash.first), to: Paths.url(entry.target))
        let reopened = try store.importSession(entry.target, header: Config.defaultHeader)
        XCTAssertEqual(reopened.manifest.id, entry.sessionID)
        XCTAssertNotEqual(reopened.url, local.url)
    }

    func testCustomFolderNamesStayUniqueWithoutConsultingTheDestination() throws {
        var config = Config()
        config.folderFormat = "same-name"
        let one = try store.create(destinationRoot: destination.path, config: config)
        let two = try store.create(destinationRoot: destination.path, config: config)
        XCTAssertNotEqual(one.displayPath, two.displayPath)
        XCTAssertEqual(try store.entries().count, 2)
    }

    func testOneBrokenDescriptorDoesNotHideHealthySessions() throws {
        let (local, entry) = try create()
        let broken = store.root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
        try Data("not json".utf8).write(to: broken.appendingPathComponent("destination.json"))
        XCTAssertNotNil(try store.entry(content: local.url))
        XCTAssertNotNil(try store.scan().issues["broken"])
        XCTAssertEqual(try worker.run(entry), .synced)
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.appendingPathComponent("destination.json").path))
    }

    func testDeletingTheLastItemDoesNotLeaveAGhostFolderThatChangesTheRemoteManifest() throws {
        let (local, entry) = try create()
        let item = try local.addItem()
        XCTAssertEqual(try worker.run(entry), .synced)
        try local.deleteItem(item.id)
        XCTAssertEqual(try worker.run(entry), .synced)
        let remote = try Session.open(entry.target)
        XCTAssertEqual(remote.manifest.nextItem, local.manifest.nextItem)
        XCTAssertEqual(try worker.run(entry), .synced)
    }


    func testAStalledDestinationDoesNotPreventAnotherDestinationFromSyncing() throws {
        let (one, first) = try create()
        try one.addItem()
        let secondRoot = base.appendingPathComponent("other-destination")
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: false)
        let two = try store.create(destinationRoot: secondRoot.path, config: Config())
        try two.addItem()
        let second = try XCTUnwrap(store.entry(content: two.url))
        let entered = expectation(description: "first destination is stalled")
        let healthy = expectation(description: "other destination completes independently")
        let finished = expectation(description: "both workers finish")
        finished.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        let stalledTarget = first.target
        let healthyTarget = second.target
        let runner = SessionSyncRunner { entry in
            SessionSync(trash: { _ in }, beforeDestinationAccess: {
                if entry.target == stalledTarget { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
            })
        }
        runner.submit([first, second]) { entry, result in
            if entry.target == healthyTarget { XCTAssertEqual(result, .synced); healthy.fulfill() }
            finished.fulfill()
        }
        wait(for: [entered, healthy], timeout: 3)
        release.signal()
        wait(for: [finished], timeout: 4)
    }

    func testDescriptorDefaultsKeepOlderLocalQueuesReadable() throws {
        let (_, entry) = try create()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: entry.descriptor)) as? [String: Any])
        json.removeValue(forKey: "deleteRequested")
        json.removeValue(forKey: "allowCreateParent")
        try JSONSerialization.data(withJSONObject: json).write(to: entry.descriptor, options: .atomic)
        let restored = try XCTUnwrap(store.entry(target: entry.target))
        XCTAssertFalse(restored.deleteRequested)
        XCTAssertFalse(restored.allowCreateParent)
    }

    func testADeletionQueuedWhileAnotherEntryIsStalledIsNotUploaded() throws {
        let (_, first) = try create()
        let (secondLocal, second) = try create()
        try secondLocal.addItem()
        let entered = expectation(description: "first entry is stalled")
        let completed = expectation(description: "both entries finished")
        completed.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        let firstKey = first.key
        let secondKey = second.key
        let runner = SessionSyncRunner { entry in
            SessionSync(trash: { _ in }, beforeDestinationAccess: {
                if entry.key == firstKey { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
            })
        }
        runner.submit([first, second]) { entry, outcome in
            if entry.key == secondKey { XCTAssertEqual(outcome, .deleted) }
            completed.fulfill()
        }
        wait(for: [entered], timeout: 3)
        try store.requestDeletion(secondLocal.url)
        release.signal()
        wait(for: [completed], timeout: 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.url(second.target).path))
    }

    func testInterruptedRemoteTemporaryCopyIsCleanedUsingItsDurableReceipt() throws {
        let (local, entry) = try create()
        let item = try local.addItem()
        try local.writeNote(item.id, body: "old")
        XCTAssertEqual(try worker.run(entry), .synced)
        try local.writeNote(item.id, body: "new")
        let note = try local.noteURL(item.id)
        let path = String(note.path.dropFirst(local.url.path.count + 1))
        let temporary = local.manifest.items[0].folder + "/.snagbook-11111111-2222-3333-4444-555555555555"
        let remoteTemporary = Paths.url(entry.target).appendingPathComponent(temporary)
        try Data("partial copy".utf8).write(to: remoteTemporary)
        var checkpoint = try SessionSync.load(entry)
        checkpoint.receipts[path] = SessionSync.Receipt(desired: try ContentDigest.file(note))
        try SessionSync.save(checkpoint, entry: entry)
        let checkpointURL = entry.directory.appendingPathComponent("checkpoint.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: checkpointURL)) as? [String: Any])
        var receipts = try XCTUnwrap(json["receipts"] as? [String: Any])
        var receipt = try XCTUnwrap(receipts[path] as? [String: Any])
        receipt["temporary"] = temporary
        receipts[path] = receipt
        json["receipts"] = receipts
        try JSONSerialization.data(withJSONObject: json).write(to: checkpointURL, options: .atomic)
        XCTAssertEqual(try worker.run(entry), .synced)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remoteTemporary.path))
        XCTAssertEqual(try Session.open(entry.target).readNote(item.id), "new")
    }


    func testMalformedTemporaryReceiptNeverRemovesDestinationContent() throws {
        let (local, entry) = try create()
        let item = try local.addItem()
        try local.writeNote(item.id, body: "precious")
        XCTAssertEqual(try worker.run(entry), .synced)
        let path = local.manifest.items[0].folder + "/notes.md"
        var checkpoint = try SessionSync.load(entry)
        checkpoint.receipts[path] = SessionSync.Receipt(desired: "not-sent", temporary: path)
        try SessionSync.save(checkpoint, entry: entry)
        XCTAssertThrowsError(try worker.run(entry))
        XCTAssertTrue(try text(Paths.url(entry.target).appendingPathComponent(path)).contains("precious"))
    }


    func testDestinationRemovalIsReportedEvenWhenNoNewLocalEditExists() throws {
        let (local, entry) = try create()
        try local.addItem()
        XCTAssertEqual(try worker.run(entry), .synced)
        try FileManager.default.removeItem(at: Paths.url(entry.target))
        XCTAssertThrowsError(try worker.run(entry))
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.url.path))
    }

    func testCommittedImportSurvivesAnErrorAfterItsCommitMarker() throws {
        let remote = try Session.create(root: destination.path, config: Config())
        let item = try remote.addItem()
        try remote.writeNote(item.id, body: "keep the committed copy")
        XCTAssertThrowsError(try store.importSession(remote.displayPath, header: Config.defaultHeader, afterCommit: { throw CocoaError(.fileReadUnknown) }))
        let committed = try XCTUnwrap(store.entry(target: remote.displayPath))
        XCTAssertEqual(try store.session(committed).readNote(item.id), "keep the committed copy")
    }

    func testAliasesOfOneSessionCannotPublishConcurrently() throws {
        let (firstLocal, first) = try create()
        let item = try firstLocal.addItem()
        XCTAssertEqual(try worker.run(first), .synced)
        let aliasRoot = base.appendingPathComponent("destination-alias")
        try FileManager.default.createSymbolicLink(at: aliasRoot, withDestinationURL: destination)
        let otherStore = try LocalSessionStore(root: base.appendingPathComponent("other-local"))
        let other = try otherStore.importSession(aliasRoot.appendingPathComponent(Paths.url(first.target).lastPathComponent).path, header: Config.defaultHeader)
        let second = try XCTUnwrap(otherStore.entry(content: other.url))
        try firstLocal.writeNote(item.id, body: "first writer")
        try other.writeNote(item.id, body: "second writer")
        let entered = expectation(description: "first publisher is active")
        let deferred = expectation(description: "same-session alias waits")
        let finished = expectation(description: "first publisher finishes")
        let release = DispatchSemaphore(value: 0)
        let firstKey = first.key
        let runner = SessionSyncRunner { entry in
            SessionSync(trash: { _ in }, beforeDestinationAccess: {
                if entry.key == firstKey { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
            })
        }
        runner.submit([first]) { _, _ in finished.fulfill() }
        wait(for: [entered], timeout: 3)
        runner.submit([second]) { _, outcome in XCTAssertEqual(outcome, .pending); deferred.fulfill() }
        wait(for: [deferred], timeout: 3)
        release.signal()
        wait(for: [finished], timeout: 4)
    }

}
