import XCTest

/// Map method and sensor coding, the accumulation grid, and the pure helpers of the single-frame LiDAR map
/// (design §13.2–§13.5, FR-SFM-02/03/04).
final class MapMethodTests: XCTestCase {
    private struct Holder: Codable {
        var method: MapMethod
        var sensor: MapSensor
    }

    func testRawValuesAreTheFileValues() {
        XCTAssertEqual(MapMethod.averaged.rawValue, "averaged")
        XCTAssertEqual(MapMethod.singleReading.rawValue, "singleReading")
        XCTAssertEqual(MapSensor.lidar.rawValue, "lidar")
        XCTAssertEqual(MapSensor.laserLine.rawValue, "laserLine")
        XCTAssertEqual(MapMethod.allCases.count, 2)
        XCTAssertNotEqual(MapMethod.averaged.label, MapMethod.singleReading.label)
        XCTAssertEqual(MapMethod.averaged.id, "averaged")
    }

    func testRoundTrip() throws {
        for method in MapMethod.allCases {
            for sensor in [MapSensor.lidar, .laserLine] {
                let data = try JSONEncoder().encode(Holder(method: method, sensor: sensor))
                let back = try JSONDecoder().decode(Holder.self, from: data)
                XCTAssertEqual(back.method, method)
                XCTAssertEqual(back.sensor, sensor)
            }
        }
    }

    func testValuesFromANewerBuildAreReadTolerantly() throws {
        let data = Data(#"{"method":"median","sensor":"radar"}"#.utf8)
        let back = try JSONDecoder().decode(Holder.self, from: data)
        XCTAssertEqual(back.method, .averaged)
        XCTAssertEqual(back.sensor, .lidar)
    }

    func testKnownValuesDecode() throws {
        let data = Data(#"{"method":"singleReading","sensor":"laserLine"}"#.utf8)
        let back = try JSONDecoder().decode(Holder.self, from: data)
        XCTAssertEqual(back.method, .singleReading)
        XCTAssertEqual(back.sensor, .laserLine)
    }
}

final class MapCellsTests: XCTestCase {
    private func makeCells(method: MapMethod = .averaged, columns: Int = 4, rows: Int = 3, cell: Double = 10,
                           qMin: Double = -5, xMin: Double = 20, zRef: Float = 0) -> MapCells {
        MapCells(method: method, columns: columns, rows: rows, cell: cell, qMin: qMin, xMin: xMin, zRef: zRef)
    }

    // MARK: - Storage

    func testAveragedStorage() {
        let cells = makeCells(method: .averaged)
        XCTAssertEqual(cells.count, 12)
        XCTAssertEqual(cells.means.count, 12)
        XCTAssertEqual(cells.hits.count, 12)
        XCTAssertEqual(cells.m2s.count, 12)
        XCTAssertTrue(cells.scores.isEmpty)
        XCTAssertTrue(cells.hits.allSatisfy { $0 == 0 })
    }

    func testSingleReadingStorage() {
        let cells = makeCells(method: .singleReading)
        XCTAssertEqual(cells.means.count, 12)
        XCTAssertEqual(cells.hits.count, 12)
        XCTAssertTrue(cells.m2s.isEmpty)
        XCTAssertEqual(cells.scores.count, 12)
        XCTAssertTrue(cells.scores.allSatisfy { $0 == .infinity })
    }

    func testNegativeSizesBecomeAnEmptyGrid() {
        let cells = makeCells(columns: -3, rows: 5)
        XCTAssertEqual(cells.columns, 0)
        XCTAssertEqual(cells.count, 0)
        XCTAssertNil(cells.index(q: 0, x: 25))
    }

    // MARK: - Index and centre

    func testIndexFloorsAndUsesRowMajorOrder() {
        let cells = makeCells()
        XCTAssertEqual(cells.index(q: -5, x: 20), 0)
        XCTAssertEqual(cells.index(q: 4.999, x: 20), 0)
        XCTAssertEqual(cells.index(q: 5, x: 20), 1)
        XCTAssertEqual(cells.index(q: 34.999, x: 20), 3)
        XCTAssertEqual(cells.index(q: 15, x: 35), 6)           // column 2, row 1
        XCTAssertEqual(cells.index(q: 34.999, x: 49.999), 11)  // last cell
    }

    func testReadingsJustOutsideTheGridAreDropped() {
        let cells = makeCells()
        XCTAssertNil(cells.index(q: -5.0001, x: 25))            // floor, not truncation toward zero
        XCTAssertNil(cells.index(q: 35, x: 25))
        XCTAssertNil(cells.index(q: 0, x: 19.999))
        XCTAssertNil(cells.index(q: 0, x: 50))
    }

    func testNonFiniteReadingsAreOutside() {
        let cells = makeCells()
        XCTAssertNil(cells.index(q: .nan, x: 25))
        XCTAssertNil(cells.index(q: 0, x: .nan))
        XCTAssertNil(cells.index(q: .infinity, x: 25))
        XCTAssertNil(cells.index(q: -.infinity, x: 25))
        XCTAssertNil(cells.index(q: 0, x: .infinity))
    }

    func testNoCellSizeMeansNoIndex() {
        XCTAssertNil(makeCells(cell: 0).index(q: 0, x: 25))
        XCTAssertNil(makeCells(cell: -10).index(q: 0, x: 25))
    }

    func testCentreOfIndex() {
        let cells = makeCells()
        let first = cells.center(ofIndex: 0)
        XCTAssertEqual(first.q, 0, accuracy: 1e-12)
        XCTAssertEqual(first.x, 25, accuracy: 1e-12)
        let c = cells.center(ofIndex: 6)                         // column 2, row 1
        XCTAssertEqual(c.q, 20, accuracy: 1e-12)
        XCTAssertEqual(c.x, 35, accuracy: 1e-12)
        // The centre of a cell lies in that cell.
        for index in 0..<cells.count {
            let centre = cells.center(ofIndex: index)
            XCTAssertEqual(cells.index(q: centre.q, x: centre.x), index)
        }
    }

    // MARK: - Averaged accumulation

    func testAveragedCellIsTheRunningMeanWithWelfordVariance() {
        var cells = makeCells(columns: 2, rows: 1, cell: 1, qMin: 0, xMin: 0, zRef: 100)
        cells.withAccumulator { acc in
            acc.add(110, at: 0, score: 0)
            acc.add(120, at: 0, score: 0)
            acc.add(130, at: 0, score: 0)
        }
        XCTAssertEqual(cells.hits, [3, 0])
        XCTAssertEqual(cells.means[0], 20)                      // mean of 10, 20, 30 relative to zRef
        XCTAssertEqual(cells.m2s[0], 200)                       // 100 + 0 + 100
        XCTAssertEqual(cells.means[1], 0)
        XCTAssertEqual(cells.m2s[1], 0)
    }

    func testNonFiniteValuesAreIgnored() {
        var cells = makeCells(columns: 2, rows: 1, cell: 1, qMin: 0, xMin: 0)
        cells.withAccumulator { acc in
            acc.add(.nan, at: 0, score: 0)
            acc.add(.infinity, at: 0, score: 0)
            acc.add(-.infinity, at: 1, score: 0)
            acc.add(5, at: 1, score: 0)
        }
        XCTAssertEqual(cells.hits, [0, 1])
        XCTAssertEqual(cells.means[1], 5)
    }

    func testAveragedCellCountsAtMostSixtyFiveThousandFiveHundredThirtyFiveReadings() {
        var cells = makeCells(columns: 1, rows: 1, cell: 1, qMin: 0, xMin: 0)
        cells.withAccumulator { acc in
            for _ in 0..<65_535 { acc.add(5, at: 0, score: 0) }
            XCTAssertEqual(acc.hits[0], UInt16.max)
            acc.add(1000, at: 0, score: 0)                      // beyond the cap: ignored, no overflow
        }
        XCTAssertEqual(cells.hits[0], UInt16.max)
        XCTAssertEqual(cells.means[0], 5)
        XCTAssertEqual(cells.m2s[0], 0)
    }

    // MARK: - Single reading

    func testSingleReadingKeepsTheStrictlyLowestScore() {
        var cells = makeCells(method: .singleReading, columns: 2, rows: 1, cell: 1, qMin: 0, xMin: 0, zRef: 100)
        cells.withAccumulator { acc in
            acc.add(110, at: 0, score: 5)       // first reading in an empty cell is kept
            acc.add(120, at: 0, score: 5)       // equal score: the first one stays
            XCTAssertEqual(acc.means[0], 10)
            acc.add(130, at: 0, score: 4)       // lower score replaces
            acc.add(140, at: 0, score: 4.5)     // higher score does not
        }
        XCTAssertEqual(cells.hits, [1, 0])      // never more than one reading per cell
        XCTAssertEqual(cells.means[0], 30)
        XCTAssertEqual(cells.scores[0], 4)
        XCTAssertEqual(cells.scores[1], .infinity)
        XCTAssertTrue(cells.m2s.isEmpty)
    }

    func testSingleReadingWithAnInfiniteScoreIsKeptUntilABetterOneComes() {
        var cells = makeCells(method: .singleReading, columns: 1, rows: 1, cell: 1, qMin: 0, xMin: 0)
        cells.withAccumulator { acc in
            acc.add(7, at: 0, score: .infinity)
        }
        XCTAssertEqual(cells.hits[0], 1)
        XCTAssertEqual(cells.means[0], 7)
        cells.withAccumulator { acc in
            acc.add(8, at: 0, score: 100)
        }
        XCTAssertEqual(cells.hits[0], 1)
        XCTAssertEqual(cells.means[0], 8)
    }

    func testSingleReadingIgnoresNonFiniteValues() {
        var cells = makeCells(method: .singleReading, columns: 1, rows: 1, cell: 1, qMin: 0, xMin: 0)
        cells.withAccumulator { acc in
            acc.add(.nan, at: 0, score: 0)
        }
        XCTAssertEqual(cells.hits[0], 0)
    }

    func testAccumulatorLocatesCellsLikeTheGrid() {
        var cells = makeCells(method: .singleReading)
        let expected = cells.index(q: 15, x: 35)
        cells.withAccumulator { acc in
            XCTAssertTrue(acc.single)
            XCTAssertEqual(acc.index(q: 15, x: 35), expected)
            XCTAssertNil(acc.index(q: .nan, x: 35))
            XCTAssertNil(acc.index(q: 1000, x: 35))
        }
    }
}

final class ScanLineMathTests: XCTestCase {
    // MARK: - Repeated frames

    func testIdenticalCountCountsPixelsValidInBothFrames() {
        let counts = ScanLineMath.identicalCount([0, 1, 2, -1, 5, .nan], [0, 1, 3, 4, 5, 6])
        // Valid in both: indices 1, 2, 4 (index 3 is invalid in the frame, 5 is NaN, 0 is no reading).
        XCTAssertEqual(counts.both, 3)
        XCTAssertEqual(counts.same, 2)
    }

    func testIdenticalCountUsesTheShorterFrame() {
        let counts = ScanLineMath.identicalCount([1, 1, 1, 1], [1, 1])
        XCTAssertEqual(counts.both, 2)
        XCTAssertEqual(counts.same, 2)
        let none = ScanLineMath.identicalCount([], [1, 2])
        XCTAssertEqual(none.both, 0)
        XCTAssertEqual(none.same, 0)
    }

    private func frame(_ count: Int, _ value: Float = 1000) -> [Float] {
        [Float](repeating: value, count: count)
    }

    func testAFrameEqualToThePreviousOneIsARepeat() {
        XCTAssertTrue(ScanLineMath.isRepeat(frame(200), previous: frame(200)))
        XCTAssertTrue(ScanLineMath.isRepeat(frame(100), previous: frame(100)))
    }

    func testFewerThanAHundredSharedPixelsNeverCountAsARepeat() {
        XCTAssertFalse(ScanLineMath.isRepeat(frame(99), previous: frame(99)))
        XCTAssertFalse(ScanLineMath.isRepeat([], previous: []))
    }

    func testAtLeastNinetyPercentIdenticalIsARepeat() {
        var changed = frame(200)
        for i in 0..<20 { changed[i] = 900 }                    // 180 of 200 identical = 90 %
        XCTAssertTrue(ScanLineMath.isRepeat(changed, previous: frame(200)))
        changed[20] = 900                                        // 179 of 200
        XCTAssertFalse(ScanLineMath.isRepeat(changed, previous: frame(200)))
    }

    func testOnlyPixelsValidInBothFramesCount() {
        // 100 shared valid pixels, all identical; 150 more pixels have no reading in the previous frame.
        var previous = frame(250)
        for i in 100..<250 { previous[i] = 0 }
        XCTAssertTrue(ScanLineMath.isRepeat(frame(250), previous: previous))
        // With 99 shared pixels it is not enough.
        previous[99] = 0
        XCTAssertFalse(ScanLineMath.isRepeat(frame(250), previous: previous))
    }

    func testDifferentFramesAreNotRepeats() {
        let a = (0..<300).map { Float(1000 + $0) }
        let b = (0..<300).map { Float(1010 + $0) }
        XCTAssertFalse(ScanLineMath.isRepeat(a, previous: b))
    }

    func testThresholdsAreTheDocumentedOnes() {
        XCTAssertEqual(ScanLineMath.repeatFraction, 0.9)
        XCTAssertEqual(ScanLineMath.repeatMinimumPixels, 100)
    }

    // MARK: - Scan row

    func testScanRowIsTheRowNearestThePrincipalPoint() {
        XCTAssertEqual(ScanLineMath.scanRow(cy: 24, height: 48, border: 2), 24)
        XCTAssertEqual(ScanLineMath.scanRow(cy: 24.4, height: 48, border: 2), 24)
        XCTAssertEqual(ScanLineMath.scanRow(cy: 24.6, height: 48, border: 2), 25)
        XCTAssertEqual(ScanLineMath.scanRow(cy: 180.25, height: 360, border: 11), 180)
    }

    func testScanRowStaysInsideTheBorder() {
        XCTAssertEqual(ScanLineMath.scanRow(cy: -5, height: 48, border: 2), 2)
        XCTAssertEqual(ScanLineMath.scanRow(cy: 0, height: 48, border: 2), 2)
        XCTAssertEqual(ScanLineMath.scanRow(cy: 100, height: 48, border: 2), 45)
        XCTAssertEqual(ScanLineMath.scanRow(cy: 46, height: 48, border: 2), 45)
    }

    func testScanRowWithoutAUsablePrincipalPointIsTheMiddle() {
        XCTAssertEqual(ScanLineMath.scanRow(cy: .nan, height: 48, border: 2), 23)
        XCTAssertEqual(ScanLineMath.scanRow(cy: .infinity, height: 48, border: 2), 23)
        XCTAssertEqual(ScanLineMath.scanRow(cy: -.infinity, height: 48, border: 2), 23)
    }

    func testScanRowOfAFrameThatIsAllBorder() {
        XCTAssertEqual(ScanLineMath.scanRow(cy: 2, height: 4, border: 2), 2)
        XCTAssertEqual(ScanLineMath.scanRow(cy: .nan, height: 4, border: 2), 2)
    }
}

final class ScanLineProfilesTests: XCTestCase {
    /// Four rows of 10 mm centred at −15, −5, 5 and 15 mm.
    private let geometry = TopoMapBuilder.Geometry(columns: 30, rows: 4, cell: 10, qMin: 100, xMin: -20)

    func testProfileTakesTheSampleNearestEachRowCentre() {
        let sample = ScanRowSample(frame: 0, time: 0, travel: 0, repeated: false,
                                   across: [-14, -16.5, -4.9, 14.9, 20, -20.0001, .nan],
                                   values: [1, 2, 3, 4, 5, 6, 7])
        let profile = ScanLineProfiles.profile(sample, geometry: geometry)
        XCTAssertEqual(profile.count, 4)
        XCTAssertEqual(profile[0], 1)       // −14 is 1 mm from the centre, −16.5 is 1.5 mm
        XCTAssertEqual(profile[1], 3)
        XCTAssertNil(profile[2])            // nothing within the row
        XCTAssertEqual(profile[3], 4)       // 20 mm and −20.0001 mm are outside, NaN is skipped
    }

    func testEqualDistancesKeepTheFirstSample() {
        let sample = ScanRowSample(frame: 0, time: 0, travel: 0, repeated: false,
                                   across: [-14, -16], values: [1, 2])
        XCTAssertEqual(ScanLineProfiles.profile(sample, geometry: geometry)[0], 1)
    }

    func testValuesWithoutAnAcrossPositionAreIgnored() {
        let sample = ScanRowSample(frame: 0, time: 0, travel: 0, repeated: false,
                                   across: [-14, -4.9, 4.9], values: [1, 2])
        let profile = ScanLineProfiles.profile(sample, geometry: geometry)
        XCTAssertEqual(profile[0], 1)
        XCTAssertEqual(profile[1], 2)
        XCTAssertNil(profile[2])
    }

    func testEmptySampleAndDegenerateGeometry() {
        let empty = ScanRowSample(frame: 0, time: 0, travel: 0, repeated: false)
        XCTAssertEqual(ScanLineProfiles.profile(empty, geometry: geometry).count, 4)
        XCTAssertTrue(ScanLineProfiles.profile(empty, geometry: geometry).allSatisfy { $0 == nil })
        let noRows = TopoMapBuilder.Geometry(columns: 3, rows: 0, cell: 10, qMin: 0, xMin: 0)
        XCTAssertTrue(ScanLineProfiles.profile(empty, geometry: noRows).isEmpty)
        let noCell = TopoMapBuilder.Geometry(columns: 3, rows: 4, cell: 0, qMin: 0, xMin: 0)
        XCTAssertTrue(ScanLineProfiles.profile(empty, geometry: noCell).isEmpty)
    }

    func testHeaderNamesTheMapRowsByTheirAcrossPosition() {
        XCTAssertEqual(ScanLineProfiles.header(geometry: geometry),
                       ["frame", "time_s", "travel_mm", "repeated", "-15", "-5", "5", "15"])
    }

    func testWriteProducesOneLinePerSample() throws {
        let url = try makeTempFolder().appendingPathComponent(ScanLineProfiles.fileName)
        let samples = [
            ScanRowSample(frame: 7, time: 0.125, travel: 12.5, repeated: false,
                          across: [-14, -4.9, 14.9], values: [1, 3, 4]),
            ScanRowSample(frame: 8, time: 0.25, travel: 25, repeated: true)
        ]
        try ScanLineProfiles.write(samples, geometry: geometry, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, """
            frame,time_s,travel_mm,repeated,-15,-5,5,15
            7,0.1250,12.50,0,1.0,3.0,,4.0
            8,0.2500,25.00,1,,,,

            """)
    }

    func testWriteLeavesNonFiniteValuesBlank() throws {
        let url = try makeTempFolder().appendingPathComponent(ScanLineProfiles.fileName)
        let samples = [ScanRowSample(frame: 0, time: 0, travel: 0, repeated: false, across: [-14, 14.9],
                                     values: [.nan, 2.26])]
        try ScanLineProfiles.write(samples, geometry: geometry, to: url)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[1], "0,0.0000,0.00,0,,,,2.3")     // 2.26 → "%.1f"
    }
}
