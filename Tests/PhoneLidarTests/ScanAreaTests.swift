import CoreGraphics
import XCTest

/// The area of interest (design §17, FR-AOI): the pure model, editing, depth pixels, zones and the recording header.
final class ScanAreaTests: XCTestCase {
    private func area(_ a0: Double, _ a1: Double, _ l0: Double, _ l1: Double) -> ScanArea {
        ScanArea(acrossStart: a0, acrossEnd: a1, alongStart: l0, alongEnd: l1)
    }

    private func assertEqual(_ a: ScanArea, _ b: ScanArea, accuracy: Double = 1e-9,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.acrossStart, b.acrossStart, accuracy: accuracy, "acrossStart", file: file, line: line)
        XCTAssertEqual(a.acrossEnd, b.acrossEnd, accuracy: accuracy, "acrossEnd", file: file, line: line)
        XCTAssertEqual(a.alongStart, b.alongStart, accuracy: accuracy, "alongStart", file: file, line: line)
        XCTAssertEqual(a.alongEnd, b.alongEnd, accuracy: accuracy, "alongEnd", file: file, line: line)
    }

    // MARK: Model

    func testNormalizedSortsAndClampsEachSide() {
        assertEqual(area(0.8, 0.2, 1.4, -0.3).normalized, area(0.2, 0.8, 0, 1))
    }

    func testNormalizedWidensATooSmallSideAboutItsCentre() {
        assertEqual(area(0.5, 0.52, 0.3, 0.3).normalized, area(0.46, 0.56, 0.25, 0.35))
        // Near an edge the widened side stays inside the picture.
        assertEqual(area(0.98, 1, 0, 0.01).normalized, area(0.9, 1, 0, 0.1))
        XCTAssertGreaterThanOrEqual(area(0.42, 0.42, 0, 1).normalized.acrossEnd
                                    - area(0.42, 0.42, 0, 1).normalized.acrossStart, ScanArea.minimumSpan - 1e-12)
    }

    func testNormalizedIsStable() {
        let once = area(0.97, 0.99, 0.01, 0.02).normalized
        assertEqual(once.normalized, once)
    }

    func testNonFiniteValuesGiveTheWholeSide() {
        assertEqual(area(.nan, 0.5, 0.2, .infinity).normalized, .whole)
    }

    func testIsWhole() {
        XCTAssertTrue(ScanArea.whole.isWhole)
        XCTAssertTrue(area(0.0005, 0.9995, 0, 1).isWhole)
        XCTAssertFalse(area(0.01, 1, 0, 1).isWhole)
        XCTAssertFalse(area(0, 1, 0, 0.95).isWhole)
    }

    func testPictureRectFollowsTheScreenConventions() {
        // Across = top → bottom of the portrait picture; along = right → left (0 = right edge).
        let r = area(0.1, 0.6, 0.2, 0.5).pictureRect
        XCTAssertEqual(Double(r.minX), 0.5, accuracy: 1e-12)
        XCTAssertEqual(Double(r.maxX), 0.8, accuracy: 1e-12)
        XCTAssertEqual(Double(r.minY), 0.1, accuracy: 1e-12)
        XCTAssertEqual(Double(r.maxY), 0.6, accuracy: 1e-12)
        assertEqual(ScanArea(picture: r), area(0.1, 0.6, 0.2, 0.5))
    }

    func testTextAndSummaryLine() {
        XCTAssertEqual(ScanArea.whole.text, "Whole picture")
        XCTAssertNil(ScanArea.whole.summaryLine)
        let a = area(0.1, 0.9, 0.05, 0.75)
        XCTAssertEqual(a.text, "25–95 % from the left, 10–90 % from the top")
        let line = a.summaryLine ?? ""
        XCTAssertEqual(line, "Area of interest: 25–95 % from the left, 10–90 % from the top of the picture; "
                       + "the rest of the picture is not in the map")
        XCTAssertTrue(TopoMapBuilder.isMapSummaryLine(line))
    }

    func testContainsIncludesTheEdges() {
        let a = area(0.2, 0.4, 0.5, 0.9)
        XCTAssertTrue(a.contains(across: 0.2, along: 0.9))
        XCTAssertTrue(a.contains(across: 0.3, along: 0.7))
        XCTAssertFalse(a.contains(across: 0.19, along: 0.7))
        XCTAssertFalse(a.contains(across: 0.3, along: 0.91))
    }

    // MARK: Codable

    func testCodableRoundTripAndAbsentKeys() throws {
        let a = area(0.1, 0.8, 0.25, 0.9)
        let decoded = try JSONDecoder.iso.decode(ScanArea.self, from: JSONEncoder.pretty.encode(a))
        XCTAssertEqual(decoded, a)
        let partial = try JSONDecoder.iso.decode(ScanArea.self, from: Data(#"{"acrossStart":0.3}"#.utf8))
        assertEqual(partial, area(0.3, 1, 0, 1))
        XCTAssertThrowsError(try JSONDecoder.iso.decode(ScanArea.self, from: Data(#"{"alongEnd":"x"}"#.utf8)))
    }

    // MARK: Zones

    func testWholePictureHasEveryZone() {
        XCTAssertEqual(ScanArea.whole.zoneMask(columns: 6, rows: 4), [Bool](repeating: true, count: 24))
    }

    func testZonesWhoseCentreIsInside() {
        // Across 0…0.5 → columns 0–2 (centres 1/12, 3/12, 5/12); along 0.5…1 → rows 2–3.
        let mask = area(0, 0.5, 0.5, 1).zoneMask(columns: 6, rows: 4)
        let inside = mask.enumerated().filter(\.element).map(\.offset)
        XCTAssertEqual(inside, [12, 13, 14, 18, 19, 20])
    }

    func testASmallAreaBetweenCentresKeepsTheZoneHoldingItsCentre() {
        // Across 0.42…0.52 lies between the column centres 0.417 and 0.583, along 0…0.1 before the first row
        // centre 0.125: no centre is inside, so the zone holding the area's centre counts.
        let mask = area(0.42, 0.52, 0.0, 0.1).zoneMask(columns: 6, rows: 4)
        XCTAssertEqual(mask.filter { $0 }.count, 1)
        XCTAssertTrue(mask[0 * 6 + 2])       // centre across 0.47 → column 2, along 0.05 → row 0
    }

    func testFastestOnlyAmongMaskedZones() throws {
        let speeds: [Double?] = [100, -500, nil, 300]
        XCTAssertEqual(try XCTUnwrap(LineMotionMath.fastest(speeds, in: nil)).index, 1)
        let masked = try XCTUnwrap(LineMotionMath.fastest(speeds, in: [true, false, true, true]))
        XCTAssertEqual(masked.index, 3)
        XCTAssertEqual(masked.speed, 300)
        XCTAssertNil(LineMotionMath.fastest(speeds, in: [false, false, true, false]))
        // A mask of the wrong length is ignored (every zone counts).
        XCTAssertEqual(try XCTUnwrap(LineMotionMath.fastest(speeds, in: [true])).index, 1)
    }

    // MARK: Editing

    private let reach = 0.05

    func testGrabEdgesCornersInsideAndOutside() {
        let a = area(0.2, 0.8, 0.2, 0.8)       // picture rect x 0.2…0.8, y 0.2…0.8
        XCTAssertEqual(a.grab(at: CGPoint(x: 0.21, y: 0.5), reachX: reach, reachY: reach), .left)
        XCTAssertEqual(a.grab(at: CGPoint(x: 0.83, y: 0.5), reachX: reach, reachY: reach), .right)
        XCTAssertEqual(a.grab(at: CGPoint(x: 0.5, y: 0.18), reachX: reach, reachY: reach), .top)
        XCTAssertEqual(a.grab(at: CGPoint(x: 0.5, y: 0.79), reachX: reach, reachY: reach), .bottom)
        XCTAssertEqual(a.grab(at: CGPoint(x: 0.81, y: 0.79), reachX: reach, reachY: reach), [.right, .bottom])
        XCTAssertEqual(a.grab(at: CGPoint(x: 0.5, y: 0.5), reachX: reach, reachY: reach), .all)
        XCTAssertEqual(a.grab(at: CGPoint(x: 0.05, y: 0.5), reachX: reach, reachY: reach), [])
        XCTAssertEqual(a.grab(at: CGPoint(x: CGFloat.nan, y: 0.5), reachX: reach, reachY: reach), [])
    }

    func testReachIsAtMostAThirdOfTheSide() {
        // A 0.1-wide area: reach 0.05 would cover all of it, so it is cut to 0.033 and the middle moves the area.
        let a = area(0, 1, 0.45, 0.55)          // picture x 0.45…0.55
        XCTAssertEqual(a.grab(at: CGPoint(x: 0.5, y: 0.5), reachX: reach, reachY: reach), .all)
        XCTAssertEqual(a.grab(at: CGPoint(x: 0.46, y: 0.5), reachX: reach, reachY: reach), .left)
    }

    func testDraggingAnEdgeStopsAtThePictureAndTheMinimumSpan() {
        let a = area(0.2, 0.8, 0.2, 0.8)
        assertEqual(ScanArea(picture: CGRect(x: 0.3, y: 0.2, width: 0.5, height: 0.6)),
                    a.dragged(.left, dx: 0.1, dy: 0.4), accuracy: 1e-12)
        XCTAssertEqual(Double(a.dragged(.left, dx: -0.5, dy: 0).pictureRect.minX), 0, accuracy: 1e-12)
        XCTAssertEqual(Double(a.dragged(.right, dx: -0.9, dy: 0).pictureRect.width), ScanArea.minimumSpan,
                       accuracy: 1e-9)
        XCTAssertEqual(Double(a.dragged(.bottom, dx: 0, dy: 0.5).pictureRect.maxY), 1, accuracy: 1e-12)
        let corner = a.dragged([.top, .right], dx: 0.1, dy: -0.1).pictureRect
        XCTAssertEqual(Double(corner.maxX), 0.9, accuracy: 1e-12)
        XCTAssertEqual(Double(corner.minY), 0.1, accuracy: 1e-12)
    }

    func testMovingKeepsTheSizeAndStopsAtThePictureEdges() {
        let a = area(0.2, 0.6, 0.1, 0.4)        // picture x 0.6…0.9, y 0.2…0.6
        let moved = a.dragged(.all, dx: 0.5, dy: -0.5).pictureRect
        XCTAssertEqual(Double(moved.maxX), 1, accuracy: 1e-12)
        XCTAssertEqual(Double(moved.width), 0.3, accuracy: 1e-12)
        XCTAssertEqual(Double(moved.minY), 0, accuracy: 1e-12)
        XCTAssertEqual(Double(moved.height), 0.4, accuracy: 1e-12)
        assertEqual(a.dragged([], dx: 0.3, dy: 0.3), a.normalized)
        assertEqual(a.dragged(.left, dx: .nan, dy: 0), a.normalized)
    }

    // MARK: Depth pixels

    func testWholePictureGivesTheBorderRanges() {
        let p = MapPixels.make(width: 320, height: 240, border: 10, keptAcross: nil, area: .whole)
        XCTAssertEqual(p.columns, 10..<310)
        XCTAssertEqual(p.rows, 10..<230)
        XCTAssertEqual(p.gridColumns, 10..<310)
        XCTAssertTrue(p.wholePicture)
        XCTAssertTrue(p.isUsable)
    }

    func testAreaLimitsColumnsAndRows() {
        let p = MapPixels.make(width: 320, height: 240, border: 10, keptAcross: nil, area: area(0.25, 0.5, 0.5, 1))
        XCTAssertEqual(p.columns, 80..<160)
        XCTAssertEqual(p.rows, 120..<230)
        XCTAssertFalse(p.wholePicture)
    }

    func testSideWallsNarrowTheReadingsButNotTheGrid() {
        let p = MapPixels.make(width: 64, height: 48, border: 2, keptAcross: 0.25...0.75, area: area(0.5, 1, 0, 1))
        XCTAssertEqual(p.columns, 32..<48)
        XCTAssertEqual(p.gridColumns, 32..<62)
        XCTAssertEqual(p.rows, 2..<46)
        // The same as MapHeightModel.columns when the area is the whole picture.
        let walls = MapPixels.make(width: 64, height: 48, border: 2, keptAcross: 0.25...0.75, area: .whole)
        XCTAssertEqual(walls.columns, 16..<48)
    }

    func testAnAreaOutsideTheWallsIsNotUsable() {
        let p = MapPixels.make(width: 64, height: 48, border: 2, keptAcross: 0.3...0.6, area: area(0.7, 1, 0, 1))
        XCTAssertFalse(p.isUsable)
        XCTAssertTrue(p.columns.isEmpty)
        XCTAssertTrue(MapPixels.unusableMessage(sideWalls: true).contains("side walls"))
    }

    func testScanRowStaysInsideTheAreaRows() {
        XCTAssertEqual(ScanLineMath.scanRow(cy: 24, rows: 2..<46), 24)
        XCTAssertEqual(ScanLineMath.scanRow(cy: 24, rows: 2..<14), 13)
        XCTAssertEqual(ScanLineMath.scanRow(cy: 24, rows: 30..<46), 30)
        XCTAssertEqual(ScanLineMath.scanRow(cy: .nan, rows: 30..<46), 37)
        // The border form is unchanged.
        XCTAssertEqual(ScanLineMath.scanRow(cy: 100, height: 48, border: 2), 45)
    }

    // MARK: Recording.json

    func testHeaderStoresTheAreaAndInfoReadsItBack() throws {
        let url = try makeTempFolder().appendingPathComponent("Recording.json")
        let a = area(0.1, 0.9, 0.2, 0.8)
        let header = LineRecordingHeader(depthWidth: 64, depthHeight: 48, videoWidth: 1920, videoHeight: 1440,
                                         filteredDepth: true, shortShutter: true, direction: .rightToLeft,
                                         tileColumns: 6, tileRows: 4, area: a)
        let writer = try RecordingJSONWriter(url: url, header: header)
        try writer.append(makeFrame(index: 0))
        try writer.close()
        let info = try JSONDecoder.iso.decode(LineRecordingInfo.self, from: Data(contentsOf: url))
        XCTAssertEqual(info.area, a)
    }

    func testRecordingsWithoutAnAreaReadAsWholePicture() throws {
        let url = try makeTempFolder().appendingPathComponent("Recording.json")
        let header = LineRecordingHeader(depthWidth: 64, depthHeight: 48, videoWidth: 1920, videoHeight: 1440,
                                         filteredDepth: true, shortShutter: true, direction: .rightToLeft,
                                         tileColumns: 6, tileRows: 4)
        let writer = try RecordingJSONWriter(url: url, header: header)
        try writer.close()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("\"area\""), text)
        XCTAssertNil(try JSONDecoder.iso.decode(LineRecordingInfo.self, from: Data(contentsOf: url)).area)
    }
}
