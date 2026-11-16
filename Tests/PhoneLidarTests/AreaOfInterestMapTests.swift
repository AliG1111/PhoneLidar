import XCTest

/// Maps built from the area of interest only (design §17.4, FR-AOI-03, FR-AOI-06). Uses the synthetic recordings of
/// `TopoMapBuilderTests`: 64 × 48 depth pixels, fx = fy = 100 px, principal point at the centre, a flat surface
/// 1000 mm away (one pixel = 10 mm = one map cell), border 2 pixels.
extension TopoMapBuilderTests {
    private func area(_ a0: Double, _ a1: Double, _ l0: Double, _ l1: Double) -> ScanArea {
        ScanArea(acrossStart: a0, acrossEnd: a1, alongStart: l0, alongEnd: l1)
    }

    private func fileText(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    func testAreaAcrossKeepsOnlyItsColumns() throws {
        var info = try writeRecording()
        let whole = try TopoMapBuilder.build(folder: folder, info: info).stats
        // 60 columns inside the border at 10 mm each.
        XCTAssertGreaterThan(whole.widthMM, 560)
        info.area = area(0.25, 0.75, 0, 1)
        let half = try TopoMapBuilder.build(folder: folder, info: info).stats
        // Columns 16…47: 32 at 10 mm.
        XCTAssertGreaterThan(half.widthMM, 280)
        XCTAssertLessThan(half.widthMM, 360)
        XCTAssertEqual(half.area, info.area)
        XCTAssertEqual(half.cellSize, whole.cellSize)
    }

    func testAreaAlongLeavesOutAStationaryObject() throws {
        // A stationary object 400 mm closer than the surface fills depth rows 0…11 (the right quarter of the
        // picture) in every frame; the moving surface is everywhere else.
        var info = try writeRecording(perturb: { _, depth in
            for v in 0..<12 {
                for u in 0..<64 { depth[v * 64 + u] = 600 }
            }
        })
        let whole = try TopoMapBuilder.build(folder: folder, info: info).stats
        XCTAssertLessThan(whole.minimum, 950)
        // Along 0.3…1 = depth rows 15…45: the object is outside the area.
        info.area = area(0, 1, 0.3, 1)
        let limited = try TopoMapBuilder.build(folder: folder, info: info).stats
        XCTAssertEqual(limited.minimum, 1000, accuracy: 0.5)
        XCTAssertEqual(limited.maximum, 1000, accuracy: 0.5)
    }

    func testAnExplicitAreaOverridesTheRecordingsArea() throws {
        var info = try writeRecording()
        info.area = area(0.25, 0.75, 0, 1)
        let output = try TopoMapBuilder.build(folder: folder, info: info, area: .whole)
        XCTAssertGreaterThan(output.stats.widthMM, 560)
        XCTAssertEqual(output.stats.area, .whole)
        XCTAssertFalse(output.summary.contains { $0.hasPrefix("Area of interest:") })
        XCTAssertFalse(try fileText("TopoStats.csv").contains("area_left"))
    }

    func testAreaIsRecordedInStatsFilesAndSummary() throws {
        let info = try writeRecording()
        let chosen = area(0.25, 0.75, 0.1, 0.9)
        let output = try TopoMapBuilder.build(folder: folder, info: info, area: chosen)
        XCTAssertEqual(output.stats.area, chosen)
        let csv = try fileText("TopoStats.csv")
        // Picture edges: left = 1 − alongEnd, right = 1 − alongStart, top/bottom = across.
        for row in ["area_left,10.0,%", "area_right,90.0,%", "area_top,25.0,%", "area_bottom,75.0,%"] {
            XCTAssertTrue(csv.contains(row), "\(row) missing in\n\(csv)")
        }
        let stats = try JSONDecoder.iso.decode(TopoStats.self,
                                               from: Data(contentsOf: folder.appendingPathComponent("TopoStats.json")))
        XCTAssertEqual(stats.area, chosen)
        let line = try XCTUnwrap(output.summary.first { $0.hasPrefix("Area of interest:") })
        XCTAssertEqual(line, chosen.summaryLine)
        // A later rebuild replaces the line (it is a map line).
        let rebuilt = TopoMapBuilder.recordSummary(existing: [info.summaryLine] + output.summary, info: info,
                                                   map: ["Scanned 1 m"])
        XCTAssertFalse(rebuilt.contains(line))
    }

    func testWholePictureAreasGiveTheSameMap() throws {
        let info = try writeRecording(surface: { q, x in 5 * sin(q / 40) + 0.02 * x })
        let reference = try TopoMapBuilder.build(folder: folder, info: info)
        for candidate in [ScanArea.whole, area(0.0004, 0.9996, 0.0003, 0.9999)] {
            let output = try TopoMapBuilder.build(folder: folder, info: info, area: candidate)
            XCTAssertEqual(output.grid.columns, reference.grid.columns)
            XCTAssertEqual(output.grid.rows, reference.grid.rows)
            XCTAssertEqual(output.grid.qMin, reference.grid.qMin)
            XCTAssertEqual(output.grid.xMin, reference.grid.xMin)
            XCTAssertEqual(output.stats.cellSize, reference.stats.cellSize)
            XCTAssertEqual(output.stats.mean, reference.stats.mean)
            XCTAssertEqual(output.stats.stdDev, reference.stats.stdDev)
            XCTAssertFalse(output.summary.contains { $0.hasPrefix("Area of interest:") })
        }
        XCTAssertEqual(reference.stats.area, .whole)
    }

    func testSingleReadingScanRowMovesIntoTheArea() throws {
        var info = try writeRecording(surface: { q, _ in 0.1 * q })
        info.mapMethod = .singleReading
        // Along 0…0.3 = depth rows 2…13: the centre row 24 is outside, so the scan row is 13.
        info.area = area(0, 1, 0, 0.3)
        let output = try TopoMapBuilder.build(folder: folder, info: info)
        XCTAssertEqual(output.stats.mapMethod, .singleReading)
        XCTAssertEqual(output.stats.meanHitsPerCell, 1, accuracy: 1e-12)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(ScanLineProfiles.fileName).path))
    }

    func testAnAreaOutsideTheSideWallsIsRefusedWithAReason() throws {
        var info = try writeRecording()
        var reference = HeightReference(method: .sideWalls, wallHeight: 300, levelZeroX: 0, levelZeroY: 0)
        reference.walls = WallCalibration(date: Date(timeIntervalSince1970: 0), wallHeight: 300, topDistance: 700,
                                          bottomDistance: 700, topReadings: 500, bottomReadings: 500, topSpread: 2,
                                          bottomSpread: 2, tiltX: 0, tiltY: 0, depthWidth: 64, depthHeight: 48,
                                          filteredDepth: true, topBand: WallBand(start: 0, end: 0.25),
                                          bottomBand: WallBand(start: 0.75, end: 1))
        try reference.save(to: folder)
        // Inside the walls (columns 16…47) and the area (32…63): columns 32…47, 160 mm.
        info.area = area(0.5, 1, 0, 1)
        let inside = try TopoMapBuilder.build(folder: folder, info: info).stats
        XCTAssertGreaterThan(inside.widthMM, 120)
        XCTAssertLessThan(inside.widthMM, 200)
        info.area = area(0.8, 1, 0, 1)
        XCTAssertThrowsError(try TopoMapBuilder.build(folder: folder, info: info)) { error in
            assertLineError(error, .configuration(MapPixels.unusableMessage(sideWalls: true)))
        }
    }
}
