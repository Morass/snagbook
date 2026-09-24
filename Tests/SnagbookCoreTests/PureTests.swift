import XCTest
@testable import SnagbookCore

final class NamingTests: XCTestCase {
    func testSlug() {
        XCTAssertEqual(Naming.slug("Main menu: the Start button!"), "main-menu-the-start-button")
        XCTAssertEqual(Naming.slug("Příliš žluťoučký kůň"), "prilis-zlutoucky-kun")
        XCTAssertEqual(Naming.slug("🐞🐞"), "")
        XCTAssertEqual(Naming.slug(String(repeating: "abc ", count: 30)).count <= 40, true)
        XCTAssertFalse(Naming.slug(String(repeating: "abc ", count: 30)).hasSuffix("-"))
    }

    func testItemFolder() {
        XCTAssertEqual(Naming.itemFolder(id: 3, title: "Item 3"), "03-item-3")
        XCTAssertEqual(Naming.itemFolder(id: 120, title: "🐞"), "120")
    }

    func testSessionFolderFormat() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let d = ISO8601DateFormatter().date(from: "2026-09-04T07:05:00Z")!
        XCTAssertEqual(Naming.sessionFolder(format: "{hash}_{dd}-{MM}-{yyyy}", date: d, hash: "deadbeef", calendar: cal), "deadbeef_04-09-2026")
        XCTAssertEqual(Naming.sessionFolder(format: "{yyyy}{MM}{dd}-{HH}{mm}/../x", date: d, hash: "h", calendar: cal), "20260904-0705-..-x")
        XCTAssertEqual(Naming.sessionFolder(format: "...", date: d, hash: "h", calendar: cal), "h")
    }

    func testRandomHashShape() {
        let h = Naming.randomHash()
        XCTAssertEqual(h.count, 8)
        XCTAssertTrue(h.allSatisfy { $0.isHexDigit })
    }

    func testPathsExpandAndAbbreviate() {
        let home = Paths.home
        XCTAssertEqual(Paths.expand("~/a/b"), home + "/a/b")
        XCTAssertEqual(Paths.abbreviate(home + "/a/b"), "~/a/b")
        XCTAssertEqual(Paths.abbreviate(home + "x/b"), home + "x/b", "a sibling with the same prefix is not inside home")
        XCTAssertEqual(Paths.abbreviate("/tmp/x"), "/tmp/x")
    }
}

final class FrontMatterTests: XCTestCase {
    func testSplitAndJoin() {
        let text = "---\ntitle: \"A \\\"quoted\\\" title\"\nstatus: open\n---\n\nBody\n"
        let p = FrontMatter.split(text)
        XCTAssertEqual(p.fields.map(\.key), ["title", "status"])
        XCTAssertEqual(p.fields[0].value, "A \"quoted\" title")
        XCTAssertEqual(p.body, "Body\n")
        XCTAssertEqual(FrontMatter.join(raw: p.raw, updates: [], body: p.body), text)
    }

    func testNoFrontMatterIsAllBody() {
        XCTAssertEqual(FrontMatter.split("# Just text\n").body, "# Just text\n")
        XCTAssertEqual(FrontMatter.split("---\nnot closed\n").body, "---\nnot closed\n")
    }

    func testHeaderPlaceholders() {
        let d = ISO8601DateFormatter().date(from: "2026-09-24T12:00:00Z")!
        let h = Header.render("{session} {readme} {items} {date}", session: "~/s/x", date: d, items: 3)
        XCTAssertTrue(h.hasPrefix("~/s/x ~/s/x/README.md 3 2026-09-2"), h)
    }
}

final class MarksTests: XCTestCase {
    func testHitTesting() {
        let ring = Mark(tool: .ellipse, points: [Pt(0, 0), Pt(100, 50)], color: "#ff0000", width: 4)
        XCTAssertTrue(ring.hit(Pt(100, 25), tolerance: 2))
        XCTAssertFalse(ring.hit(Pt(50, 25), tolerance: 2), "the middle of a circle is not the circle")
        let box = Mark(tool: .rect, points: [Pt(10, 10), Pt(60, 60)], color: "#ff0000", width: 4)
        XCTAssertTrue(box.hit(Pt(10, 30), tolerance: 2))
        XCTAssertFalse(box.hit(Pt(35, 35), tolerance: 2))
        let blur = Mark(tool: .pixelate, points: [Pt(10, 10), Pt(60, 60)], color: "#000000", width: 1)
        XCTAssertTrue(blur.hit(Pt(35, 35), tolerance: 2), "a blur is solid")
        let arrow = Mark(tool: .arrow, points: [Pt(0, 0), Pt(100, 0)], color: "#ff0000", width: 4)
        XCTAssertTrue(arrow.hit(Pt(50, 3), tolerance: 2))
        XCTAssertFalse(arrow.hit(Pt(50, 20), tolerance: 2))
        let pen = Mark(tool: .pen, points: [Pt(0, 0), Pt(10, 10), Pt(20, 0)], color: "#ff0000", width: 4)
        XCTAssertTrue(pen.hit(Pt(15, 5), tolerance: 2))
    }

    func testConstrainAndCounters() {
        let sq = Geometry.constrain(Pt(0, 0), Pt(30, -10), tool: .rect)
        XCTAssertEqual(sq, Pt(30, -30))
        let a = Geometry.constrain(Pt(0, 0), Pt(10, 1), tool: .arrow)
        XCTAssertEqual(a.y, 0, accuracy: 1e-9)
        var doc = MarkDocument(width: 100, height: 100)
        XCTAssertEqual(doc.nextCounter, 1)
        doc.marks.append(Mark(tool: .counter, points: [Pt(5, 5)], color: "#ff0000", width: 4, number: 4))
        XCTAssertEqual(doc.nextCounter, 5)
    }

    func testOutputBoxClampsCrop() {
        var d = MarkDocument(width: 200, height: 100)
        XCTAssertEqual(d.outputBox, Box(x: 0, y: 0, w: 200, h: 100))
        d.crop = Box(x: 150, y: -20, w: 100, h: 60)
        XCTAssertEqual(d.outputBox, Box(x: 150, y: 0, w: 50, h: 40))
        d.crop = Box(x: 500, y: 500, w: 10, h: 10)
        XCTAssertEqual(d.outputBox, Box(x: 0, y: 0, w: 200, h: 100), "a crop outside the picture is ignored")
    }

    func testCodableRoundTripAndCompanions() throws {
        let d = MarkDocument(width: 10, height: 20, crop: nil, marks: [Mark(tool: .text, points: [Pt(1, 2)], color: "#fff", width: 18, text: "hi")])
        XCTAssertEqual(try MarkDocument.decode(d.encoded()), d)
        let c = MarkDocument.companions(of: "media/shot-001.png")
        XCTAssertEqual(c.orig, "media/shot-001.orig.png")
        XCTAssertEqual(c.marks, "media/shot-001.marks.json")
    }

    func testSimplifyKeepsEnds() {
        let pts = (0...100).map { Pt(Double($0) * 0.1, 0) }
        let s = Geometry.simplify(pts, minStep: 1)
        XCTAssertEqual(s.first, pts.first)
        XCTAssertEqual(s.last, pts.last)
        XCTAssertLessThan(s.count, 15)
    }
}

final class CaptureMathTests: XCTestCase {
    func testOutputSizeIsEvenAndCapped() {
        XCTAssertTrue(CaptureMath.outputSize(width: 5120, height: 2880, maxLongEdge: 1920) == (1920, 1080))
        XCTAssertTrue(CaptureMath.outputSize(width: 801, height: 601, maxLongEdge: 1920) == (800, 600))
        XCTAssertTrue(CaptureMath.outputSize(width: 1, height: 1, maxLongEdge: 1920) == (2, 2))
    }

    func testStillTimes() {
        XCTAssertEqual(CaptureMath.stillTimes(duration: 3.5, max: 60), [0, 1, 2, 3])
        XCTAssertEqual(CaptureMath.stillTimes(duration: 3.0, max: 60), [0, 1, 2, 2.95])
        let long = CaptureMath.stillTimes(duration: 600, max: 60)
        XCTAssertEqual(long.count, 60)
        XCTAssertEqual(long.first, 0)
        XCTAssertEqual(long.last!, 599.95, accuracy: 1e-9)
        XCTAssertEqual(CaptureMath.stillTimes(duration: 0.4, max: 60), [0])
        XCTAssertEqual(CaptureMath.stillTimes(duration: 10, max: 0), [])
    }

    func testSheetAndGrid() {
        XCTAssertEqual(CaptureMath.sheetTimes(duration: 60).count, 16)
        XCTAssertEqual(CaptureMath.sheetTimes(duration: 1).count, 3)
        XCTAssertTrue(CaptureMath.grid(16) == (4, 4))
        XCTAssertTrue(CaptureMath.grid(3) == (2, 2))
        XCTAssertTrue(CaptureMath.grid(5) == (3, 2))
    }

    func testStamps() {
        XCTAssertEqual(CaptureMath.stamp(7.46), "0:07.5")
        XCTAssertEqual(CaptureMath.stamp(3723), "1:02:03.0")
        XCTAssertEqual(CaptureMath.duration(65.4), "1:05")
    }

    func testBitRateBounds() {
        XCTAssertEqual(CaptureMath.bitRate(width: 100, height: 100, fps: 15), 600_000)
        XCTAssertEqual(CaptureMath.bitRate(width: 1920, height: 1080, fps: 15), 3_110_400)
        XCTAssertEqual(CaptureMath.bitRate(width: 7680, height: 4320, fps: 60), 6_000_000)
    }

    func testRegionConversionRoundTrip() {
        // A 1440x900 screen to the right of the main one, and a region near its top.
        let screen = Box(x: 1440, y: 0, w: 1440, h: 900)
        let region = Box(x: 1500, y: 700, w: 200, h: 100)
        let local = RegionMath.displayLocal(region, screen: screen)
        XCTAssertEqual(local, Box(x: 60, y: 100, w: 200, h: 100))
        XCTAssertEqual(RegionMath.global(local, screen: screen), region)
        // clipped to the screen
        XCTAssertEqual(RegionMath.displayLocal(Box(x: 1400, y: 850, w: 100, h: 100), screen: screen), Box(x: 0, y: 0, w: 60, h: 50))
    }

    func testSnapToPixels() {
        let r = RegionMath.snapped(Box(x: 10.3, y: 5.2, w: 100.1, h: 50.1), scale: 2, bounds: Box(x: 0, y: 0, w: 1000, h: 1000))
        XCTAssertEqual(r, Box(x: 10.0, y: 5.0, w: 100.5, h: 50.5))
    }
}

final class ByteRangeTests: XCTestCase {
    func testForms() {
        XCTAssertTrue(ByteRange.parse("bytes=0-9", size: 100)! == (0, 9))
        XCTAssertTrue(ByteRange.parse("bytes=90-", size: 100)! == (90, 99))
        XCTAssertTrue(ByteRange.parse("bytes=-10", size: 100)! == (90, 99))
        XCTAssertTrue(ByteRange.parse("bytes=50-5000", size: 100)! == (50, 99))
    }

    func testUnservable() {
        XCTAssertNil(ByteRange.parse("bytes=100-", size: 100))
        XCTAssertNil(ByteRange.parse("bytes=9-0", size: 100))
        XCTAssertNil(ByteRange.parse("bytes=0-1,5-6", size: 100))
        XCTAssertNil(ByteRange.parse("items=0-1", size: 100))
        XCTAssertNil(ByteRange.parse("bytes=a-b", size: 100))
        XCTAssertNil(ByteRange.parse("bytes=0-9", size: 0))
    }
}
