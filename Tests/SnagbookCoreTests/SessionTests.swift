import XCTest
@testable import SnagbookCore

final class SessionTests: XCTestCase {
    var root: String!
    var home: String!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("snag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("sessions").path
        home = base.path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    func testCreateMakesHashDateFolderWithManifestAndReadme() throws {
        var cfg = Config()
        cfg.header = "REVIEW {session}"
        let s = try Session.create(root: root, config: cfg, now: date("2026-09-24T10:00:00Z"), hash: "ab12cd34")
        XCTAssertTrue(s.url.lastPathComponent.hasPrefix("ab12cd34_"))
        XCTAssertTrue(s.url.lastPathComponent.hasSuffix("-09-2026"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.url.appendingPathComponent("session.json").path))
        let readme = try String(contentsOf: s.url.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.hasPrefix("REVIEW \(s.displayPath)\n"), readme)
    }

    func testSameMinuteSameHashDoesNotCollide() throws {
        let a = try Session.create(root: root, config: Config(), hash: "00000000")
        let b = try Session.create(root: root, config: Config(), hash: "00000000")
        XCTAssertNotEqual(a.url, b.url)
    }

    func testItemsDefaultNamesRenameAndFolders() throws {
        let s = try Session.create(root: root, config: Config())
        let one = try s.addItem()
        let two = try s.addItem(title: "Main menu")
        XCTAssertEqual(one.title, "Item 1")
        XCTAssertEqual(one.folder, "01-item-1")
        XCTAssertEqual(two.folder, "02-main-menu")
        let renamed = try s.renameItem(1, to: "Inventory: drag & drop")
        XCTAssertEqual(renamed.folder, "01-inventory-drag-drop")
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.url.appendingPathComponent("01-item-1").path))
        let note = try String(contentsOf: s.noteURL(1), encoding: .utf8)
        XCTAssertTrue(note.contains("title: \"Inventory: drag & drop\""), note)
        XCTAssertThrowsError(try s.renameItem(1, to: "   "))
    }

    func testDeletingFromTheEndGivesTheNumbersBack() throws {
        let s = try Session.create(root: root, config: Config())
        for _ in 1...4 { try s.addItem() }
        try s.deleteItem(2)
        XCTAssertEqual(try s.addItem().id, 5, "1 3 4 → 5: a gap in the middle is not refilled")
        try s.deleteItem(5)
        try s.deleteItem(4)
        XCTAssertEqual(try s.addItem().id, 4, "1 3 after deleting 4 and 5 → 4")
        XCTAssertEqual(s.manifest.items.map(\.id), [1, 3, 4])
        XCTAssertEqual(try Session.open(s.url.path).manifest.nextItem, 5)
    }

    func testDeletingEverythingStartsAgainAtOne() throws {
        let s = try Session.create(root: root, config: Config())
        try s.addItem()
        try s.addItem()
        try s.deleteItem(2)
        try s.deleteItem(1)
        XCTAssertEqual(try s.addItem().id, 1)
    }

    func testFolderRemovedFromOutsideAtTheEndGivesItsNumberBack() throws {
        let s = try Session.create(root: root, config: Config())
        for _ in 1...3 { try s.addItem() }
        try FileManager.default.removeItem(at: try s.itemURL(3))
        let reopened = try Session.open(s.url.path)
        XCTAssertEqual(try reopened.addItem().id, 3)
    }

    func testANumberedFolderLeftOnDiskKeepsItsNumber() throws {
        let s = try Session.create(root: root, config: Config())
        for _ in 1...2 { try s.addItem() }
        try s.deleteItem(2) { url in
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent().appendingPathComponent("02-left-behind"), withIntermediateDirectories: false)
        }
        XCTAssertEqual(try s.addItem().id, 3, "02-left-behind is still there, so 2 is not reused")
    }

    func testWriteNoteKeepsFrontMatterAndUpdatesReadme() throws {
        let s = try Session.create(root: root, config: Config())
        try s.addItem(title: "Main menu")
        XCTAssertTrue(try s.writeNote(1, body: "Logo overlaps.\n\n![](media/shot-001.png)\n"))
        XCTAssertFalse(try s.writeNote(1, body: "Logo overlaps.\n\n![](media/shot-001.png)\n"), "unchanged write is skipped")
        let raw = try String(contentsOf: s.noteURL(1), encoding: .utf8)
        XCTAssertTrue(raw.hasPrefix("---\ntitle: \"Main menu\"\ncreated: "), raw)
        XCTAssertEqual(try s.readNote(1), "Logo overlaps.\n\n![](media/shot-001.png)\n")
        let readme = try String(contentsOf: s.url.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("## 1. Main menu"), readme)
        XCTAssertTrue(readme.contains("![](01-main-menu/media/shot-001.png)"), readme)
    }

    func testHandEditedFrontMatterLinesSurvive() throws {
        let s = try Session.create(root: root, config: Config())
        try s.addItem(title: "A")
        let u = try s.noteURL(1)
        try "---\ntitle: \"A\"\nstatus: resolved\n---\n\nbody\n".write(to: u, atomically: true, encoding: .utf8)
        try s.writeNote(1, body: "new body\n")
        try s.renameItem(1, to: "B")
        let raw = try String(contentsOf: s.noteURL(1), encoding: .utf8)
        XCTAssertEqual(raw, "---\ntitle: \"B\"\nstatus: resolved\n---\n\nnew body\n")
    }

    func testMediaNamesCountUpAndSkipCompanions() throws {
        let s = try Session.create(root: root, config: Config())
        try s.addItem()
        XCTAssertEqual(try s.saveMedia(1, data: Data([1]), prefix: "shot", ext: "PNG"), "media/shot-001.png")
        try Data([1]).write(to: s.mediaURL(1).appendingPathComponent("shot-002.orig.png"))
        XCTAssertEqual(try s.saveMedia(1, data: Data([1]), prefix: "shot", ext: "png"), "media/shot-003.png")
        let clip = try s.reserveMediaName(1, prefix: "clip", ext: "mp4")
        XCTAssertEqual(clip.relative, "media/clip-001.mp4")
        try Data([0]).write(to: clip.url)
        XCTAssertEqual(s.mediaCount(1), Session.MediaCount(images: 2, videos: 1))
    }

    func testOpenRepairsFoldersRemovedOrAddedByHand() throws {
        let s = try Session.create(root: root, config: Config())
        try s.addItem(title: "Keep")
        try s.addItem(title: "Gone")
        try FileManager.default.removeItem(at: s.itemURL(2))
        let manual = s.url.appendingPathComponent("07-by-hand")
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        try "---\ntitle: \"By hand\"\n---\n\nx\n".write(to: manual.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let again = try Session.open(s.url.path)
        XCTAssertEqual(again.manifest.items.map(\.title), ["Keep", "By hand"])
        XCTAssertEqual(try again.addItem().id, 8)
    }

    func testListNewestFirstAndIgnoresStrangers() throws {
        _ = try Session.create(root: root, config: Config(), now: date("2026-01-01T00:00:00Z"), hash: "11111111")
        _ = try Session.create(root: root, config: Config(), now: date("2026-02-01T00:00:00Z"), hash: "22222222")
        try FileManager.default.createDirectory(atPath: root + "/not-a-session", withIntermediateDirectories: true)
        let l = Session.list(root: root)
        XCTAssertEqual(l.count, 2)
        XCTAssertTrue(l[0].path.contains("22222222"))
    }

    func testOpenRejectsAFolderWithoutManifest() {
        XCTAssertThrowsError(try Session.open(home)) { XCTAssertEqual($0 as? SnagError, .notASession(home)) }
    }

    func testHandoffStyles() throws {
        var cfg = Config()
        cfg.header = "Please read {readme}"
        let s = try Session.create(root: root, config: cfg)
        XCTAssertEqual(s.handoff(style: .path), s.displayPath + "/README.md")
        XCTAssertEqual(s.handoff(style: .header), "Please read \(s.displayPath)/README.md")
        cfg.header = "No placeholder"
        try s.setHeader(cfg.header)
        XCTAssertEqual(s.handoff(style: .header), "No placeholder\n\n\(s.displayPath)/README.md")
    }

    func testSessionsFollowTheGlobalHeaderUntilGivenTheirOwn() throws {
        var cfg = Config()
        cfg.header = "old {session}"
        let s = try Session.create(root: root, config: cfg)
        s.fallbackHeader = "new header"
        let readme = { try String(contentsOf: s.url.appendingPathComponent("README.md"), encoding: .utf8) }
        XCTAssertTrue(try readme().hasPrefix("new header\n"))
        XCTAssertTrue(try Session.open(s.url.path, fallbackHeader: "from settings").handoff(style: .header).hasPrefix("from settings"))
        try s.setHeader("mine")
        s.fallbackHeader = "ignored"
        XCTAssertTrue(try readme().hasPrefix("mine\n"))
        XCTAssertEqual(try Session.open(s.url.path, fallbackHeader: "x").manifest.header, "mine")
        try s.setHeader(nil)
        XCTAssertTrue(try readme().hasPrefix("ignored\n"))
    }

    func testOldSessionsWithAStoredHeaderStillOpen() throws {
        let s = try Session.create(root: root, config: Config())
        let u = s.url.appendingPathComponent("session.json")
        var json = try String(contentsOf: u, encoding: .utf8)
        json = json.replacingOccurrences(of: "\"id\"", with: "\"header\" : \"frozen\",\n  \"id\"")
        try json.write(to: u, atomically: true, encoding: .utf8)
        XCTAssertEqual(try Session.open(s.url.path).manifest.header, "frozen")
    }

    func testSessionNamesDefaultToTheirStartAndShowInTheList() throws {
        let s = try Session.create(root: root, config: Config(), now: date("2026-09-24T18:30:00Z"))
        XCTAssertTrue(s.title.hasPrefix("Session 24 Sep, "), s.title)
        try s.setTitle("  Inventory pass ")
        XCTAssertEqual(try Session.open(s.url.path).title, "Inventory pass")
        XCTAssertEqual(Session.list(root: root).first?.title, "Inventory pass")
        XCTAssertTrue(try String(contentsOf: s.url.appendingPathComponent("README.md"), encoding: .utf8).contains("Session: **Inventory pass**"))
        try s.setTitle("")
        XCTAssertTrue(s.title.hasPrefix("Session 24 Sep"))
    }

    func testMoveItem() throws {
        let s = try Session.create(root: root, config: Config())
        try s.addItem(); try s.addItem(); try s.addItem()
        try s.moveItem(3, to: 0)
        XCTAssertEqual(s.manifest.items.map(\.id), [3, 1, 2])
        let readme = try String(contentsOf: s.url.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.range(of: "## 1. Item 3") != nil, readme)
    }
}

final class ConfigTests: XCTestCase {
    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString)/config.json") }

    func testMissingFileIsDefaultsAndSaveRoundTrips() throws {
        let u = tmp()
        let store = ConfigStore(url: u)
        XCTAssertEqual(store.config, Config())
        try store.update { $0.sessionsFolder = "~/elsewhere"; $0.capture.fps = 30 }
        XCTAssertEqual(ConfigStore(url: u).config.sessionsFolder, "~/elsewhere")
        XCTAssertEqual(ConfigStore(url: u).config.capture.fps, 30)
    }

    func testPartialFileKeepsDefaultsForMissingKeys() throws {
        let u = tmp()
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"sessionsFolder":"~/x","capture":{"fps":500}}"#.write(to: u, atomically: true, encoding: .utf8)
        let c = ConfigStore(url: u).config
        XCTAssertEqual(c.sessionsFolder, "~/x")
        XCTAssertEqual(c.capture.fps, 60, "clamped")
        XCTAssertEqual(c.templates, Config.defaultTemplates)
    }

    func testBrokenFileIsNeverOverwritten() throws {
        let u = tmp()
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{ not json".write(to: u, atomically: true, encoding: .utf8)
        let store = ConfigStore(url: u)
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.update { $0.alwaysOnTop = true })
        XCTAssertEqual(try String(contentsOf: u, encoding: .utf8), "{ not json")
    }
}

extension SessionTests {
    // A session on a network share: the volume has no Trash, so trashItem fails with
    // featureUnsupported and delete used to fail with it, leaving the item in place.
    func testDeleteOnVolumeWithoutTrashDeletesPermanentlyWhenConfirmed() throws {
        let s = try Session.create(root: root, config: Config())
        let rec = try s.addItem(title: "New")
        let dir = try s.itemURL(rec.id)
        var asked = 0
        try s.deleteItem(rec.id, discard: Session.trashOrDelete(
            trash: { _ in throw CocoaError(.featureUnsupported) },
            deletePermanently: { _ in asked += 1; return true }))
        XCTAssertEqual(asked, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertTrue(try Session.open(s.url.path).manifest.items.isEmpty)
    }

    func testDeleteOnVolumeWithoutTrashKeepsItemWhenDeclined() throws {
        let s = try Session.create(root: root, config: Config())
        let rec = try s.addItem(title: "New")
        let dir = try s.itemURL(rec.id)
        XCTAssertThrowsError(try s.deleteItem(rec.id, discard: Session.trashOrDelete(
            trash: { _ in throw CocoaError(.featureUnsupported) },
            deletePermanently: { _ in false }))) { XCTAssertEqual(($0 as? CocoaError)?.code, .userCancelled) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(try Session.open(s.url.path).manifest.items.map(\.id), [rec.id])
    }

    func testDeleteThatTrashesNeverAsksToDeletePermanently() throws {
        let s = try Session.create(root: root, config: Config())
        let rec = try s.addItem(title: "New")
        var trashed: URL?
        try s.deleteItem(rec.id, discard: Session.trashOrDelete(
            trash: { trashed = $0 },
            deletePermanently: { _ in XCTFail("asked although the Trash worked"); return false }))
        XCTAssertEqual(trashed?.lastPathComponent, "01-new")
    }
}
