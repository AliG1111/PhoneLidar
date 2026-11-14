import XCTest

/// The single-frame (one reading per cell) build of `TopoMapBuilder` and the method-dependent statistics and text
/// (design §13, FR-SFM-02…05). Uses the synthetic recordings of `TopoMapBuilderTests`: 64 × 48 depth pixels,
/// fx = fy = 100 px, principal point at the centre (cx = 32, cy = 24), reference surface 1000 mm away.
extension TopoMapBuilderTests {
    /// A ramp along the travel (h = 0.1 · q): consecutive frames differ in every depth pixel, so none repeats.
    private func rampSurface(_ q: Double, _ x: Double) -> Double? { 0.1 * q }

    private func text(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    /// Depth as the builder reads it back from Depth.bin (tenths of a millimetre, decoded as Float).
    private func decoded(_ mm: Float) -> Float {
        Float(UInt16(mm * 10 + 0.5)) * 0.1
    }

    // MARK: - FR-SFM-02: one reading per cell

    func testEachCellHoldsTheReadingNearestTheScanLine() throws {
        // Every reading has its own value: 900 + row (+ 50 on odd frames, so no frame repeats the previous one).
        func depth(frame: Int, row: Int) -> Float { decoded(Float(900 + row + 50 * (frame % 2))) }
        var info = try writeRecording(perturb: { i, depth in
            for v in 0..<48 {
                for u in 0..<64 { depth[v * 64 + u] = Float(900 + v + 50 * (i % 2)) }
            }
        })
        info.mapMethod = .singleReading
        let output = try TopoMapBuilder.build(folder: folder, info: info)
        XCTAssertEqual(output.stats.mapMethod, .singleReading)
        XCTAssertTrue(output.stats.isSingleReading)
        XCTAssertEqual(output.stats.meanHitsPerCell, 1, accuracy: 1e-12)
        XCTAssertEqual(output.stats.repeatStdDev, 0)

        // Independent oracle: of all readings landing in a cell, the one whose depth row is nearest the scan row
        // (row 24); on equal distances the earlier frame (and earlier pixel) stays.
        let grid = try loadGrid()
        let border = TopoMapBuilder.border(width: 64, height: 48)
        let scanRow = ScanLineMath.scanRow(cy: 24, height: 48, border: border)
        XCTAssertEqual(scanRow, 24)
        var best = [Float](repeating: .nan, count: grid.columns * grid.rows)
        var bestScore = [Int](repeating: Int.max, count: grid.columns * grid.rows)
        let sign = Double(info.direction.bufferSign)
        for (i, frame) in info.frames.enumerated() {
            let offset = sign * frame.travel
            for v in border..<(48 - border) {
                let yFactor = (Double(v) - 24) / 100
                for u in border..<(64 - border) {
                    let z = depth(frame: i, row: v)
                    let zd = Double(z)
                    let q = offset - yFactor * zd
                    let x = (Double(u) - 32) / 100 * zd
                    let c = ((q - grid.qMin) / grid.cell).rounded(.down)
                    let r = ((x - grid.xMin) / grid.cell).rounded(.down)
                    guard c >= 0, r >= 0, c < Double(grid.columns), r < Double(grid.rows) else { continue }
                    let index = Int(r) * grid.columns + Int(c)
                    let score = abs(v - scanRow)
                    if score < bestScore[index] {
                        bestScore[index] = score
                        best[index] = z
                    }
                }
            }
        }
        var compared = 0
        for index in 0..<best.count {
            if best[index].isNaN {
                XCTAssertTrue(grid.values[index].isNaN, "cell \(index) should be empty")
            } else {
                XCTAssertEqual(grid.values[index], best[index], accuracy: 1e-3, "cell \(index)")
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 500)
        XCTAssertEqual(compared, output.stats.cellsWithData)
    }

    func testAveragedBuildOfTheSameRecordingMixesReadings() throws {
        let info = try writeRecording(perturb: { i, depth in
            for v in 0..<48 {
                for u in 0..<64 { depth[v * 64 + u] = Float(900 + v + 50 * (i % 2)) }
            }
        })
        let averaged = try TopoMapBuilder.build(folder: folder, info: info, method: .averaged).stats
        XCTAssertEqual(averaged.mapMethod, .averaged)
        XCTAssertFalse(averaged.isSingleReading)
        XCTAssertGreaterThan(averaged.meanHitsPerCell, 1.5)
        let single = try TopoMapBuilder.build(folder: folder, info: info, method: .singleReading).stats
        XCTAssertEqual(single.meanHitsPerCell, 1, accuracy: 1e-12)
        XCTAssertEqual(single.cellSize, averaged.cellSize, accuracy: 1e-12)
        XCTAssertEqual(single.cellsWithData, averaged.cellsWithData)
    }

    // MARK: - Method selection

    func testMethodComesFromTheRecordingUnlessGiven() throws {
        var info = try writeRecording(surface: rampSurface)
        XCTAssertNil(info.mapMethod)
        XCTAssertEqual(try TopoMapBuilder.build(folder: folder, info: info).stats.mapMethod, .averaged)

        info.mapMethod = .singleReading
        XCTAssertEqual(try TopoMapBuilder.build(folder: folder, info: info).stats.mapMethod, .singleReading)
        XCTAssertEqual(try TopoMapBuilder.build(folder: folder, info: info, method: .averaged).stats.mapMethod,
                       .averaged)

        info.mapMethod = .averaged
        XCTAssertEqual(try TopoMapBuilder.build(folder: folder, info: info, method: .singleReading).stats.mapMethod,
                       .singleReading)
    }

    func testStatisticsJSONRecordsMethodAndSensor() throws {
        let info = try writeRecording(surface: rampSurface)
        _ = try TopoMapBuilder.build(folder: folder, info: info, method: .singleReading)
        var stats = try JSONDecoder().decode(TopoStats.self, from: Data(contentsOf: folder
            .appendingPathComponent("TopoStats.json")))
        XCTAssertEqual(stats.mapMethod, .singleReading)
        XCTAssertEqual(stats.sensor, .lidar)
        _ = try TopoMapBuilder.build(folder: folder, info: info, method: .averaged)
        stats = try JSONDecoder().decode(TopoStats.self, from: Data(contentsOf: folder
            .appendingPathComponent("TopoStats.json")))
        XCTAssertEqual(stats.mapMethod, .averaged)
        XCTAssertEqual(stats.sensor, .lidar)
    }

    func testStatsFilesWithoutMethodOrSensorStillDecodeAsAveragedLidar() throws {
        let info = try writeRecording(surface: rampSurface)
        _ = try TopoMapBuilder.build(folder: folder, info: info)
        let url = folder.appendingPathComponent("TopoStats.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object.removeValue(forKey: "mapMethod")
        object.removeValue(forKey: "sensor")
        let older = try JSONSerialization.data(withJSONObject: object)
        let stats = try JSONDecoder().decode(TopoStats.self, from: older)
        XCTAssertNil(stats.mapMethod)
        XCTAssertNil(stats.sensor)
        XCTAssertFalse(stats.isSingleReading)
    }

    // MARK: - FR-SFM-03: repeated depth frames

    func testDuplicatedDepthFramesAreSkippedAndCounted() throws {
        var last: [Float] = []
        var info = try writeRecording(perturb: { i, depth in
            if i % 2 == 1 { depth = last } else { last = depth }   // every odd frame repeats the even one before
        }, surface: rampSurface)
        info.mapMethod = .singleReading
        let output = try TopoMapBuilder.build(folder: folder, info: info)
        let expected = "Map method: one reading per cell (no averaging); 40 of 80 frames used, "
            + "40 repeated depth frames skipped"
        XCTAssertTrue(output.summary.contains(expected), output.summary.joined(separator: "\n"))
        XCTAssertEqual(output.summary.filter { $0.hasPrefix("Map method:") }.count, 1)
        XCTAssertEqual(output.stats.meanHitsPerCell, 1, accuracy: 1e-12)
        XCTAssertEqual(output.stats.frames, 80)
    }

    func testSingleReadingLineText() {
        XCTAssertEqual(TopoMapBuilder.singleReadingLine(used: 40, total: 80, repeated: 40),
                       "Map method: one reading per cell (no averaging); 40 of 80 frames used, "
                       + "40 repeated depth frames skipped")
        XCTAssertEqual(TopoMapBuilder.singleReadingLine(used: 1, total: 1, repeated: 0),
                       "Map method: one reading per cell (no averaging); 1 of 1 frames used, "
                       + "0 repeated depth frames skipped")
        // It is a map line: a rebuild replaces it.
        XCTAssertTrue(TopoMapBuilder.isMapSummaryLine(TopoMapBuilder.singleReadingLine(used: 3, total: 4, repeated: 1)))
    }

    func testAMotionlessSceneRepeatsEveryFrameAfterTheFirst() throws {
        var info = try writeRecording()          // flat surface: every frame is the same picture
        info.mapMethod = .singleReading
        let output = try TopoMapBuilder.build(folder: folder, info: info)
        XCTAssertTrue(output.summary.contains(TopoMapBuilder.singleReadingLine(used: 1, total: 80, repeated: 79)),
                      output.summary.joined(separator: "\n"))
    }

    func testAveragedBuildSkipsNothingAndHasNoMethodLine() throws {
        var last: [Float] = []
        let info = try writeRecording(perturb: { i, depth in
            if i % 2 == 1 { depth = last } else { last = depth }
        }, surface: rampSurface)
        let output = try TopoMapBuilder.build(folder: folder, info: info)
        XCTAssertFalse(output.summary.contains { $0.hasPrefix("Map method:") })
        XCTAssertGreaterThan(output.stats.meanHitsPerCell, 1.5)
    }

    // MARK: - FR-SFM-04: ScanLineProfiles.csv

    func testScanLineProfilesFollowTheScanRowOfEachFrame() throws {
        var last: [Float] = []
        var info = try writeRecording(perturb: { i, depth in
            if i % 2 == 1 { depth = last } else { last = depth }
        }, surface: rampSurface)
        info.mapMethod = .singleReading
        let output = try TopoMapBuilder.build(folder: folder, info: info)
        let rows = output.stats.rows
        let lines = try text(ScanLineProfiles.fileName).split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        XCTAssertEqual(lines.last, "")                                 // trailing newline
        let data = lines.dropLast()
        XCTAssertEqual(data.count, 81)                                 // header + one line per frame
        XCTAssertTrue(data[0].hasPrefix("frame,time_s,travel_mm,repeated,"), data[0])

        let sign = Double(info.direction.bufferSign)
        for (i, line) in data.dropFirst().enumerated() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(fields.count, 4 + rows, "frame \(i)")
            XCTAssertEqual(fields[0], "\(i)")
            XCTAssertEqual(try XCTUnwrap(Double(fields[1])), Double(i) / 30, accuracy: 6e-5)
            XCTAssertEqual(try XCTUnwrap(Double(fields[2])), Double(i) * 7.3, accuracy: 6e-3)
            XCTAssertEqual(fields[3], i % 2 == 1 ? "1" : "0", "frame \(i)")
            // The scan row is the row through the principal point: material coordinate q = sign · travel there. An
            // odd (repeated) frame carries the even frame's picture.
            let source = i - i % 2
            let expected = 1000 - 0.1 * sign * Double(source) * 7.3
            let values = fields.dropFirst(4).filter { !$0.isEmpty }.compactMap(Double.init)
            XCTAssertGreaterThan(values.count, rows / 2, "frame \(i)")
            for value in values { XCTAssertEqual(value, expected, accuracy: 0.06, "frame \(i)") }
        }
    }

    func testScanLineProfilesInHeightModeAreHeightsAboveTheBaseline() throws {
        var info = try writeRecording(withBaseline: true, surface: rampSurface)
        info.mapMethod = .singleReading
        let output = try TopoMapBuilder.build(folder: folder, info: info)
        XCTAssertEqual(output.stats.heightMode, true)
        let lines = try text(ScanLineProfiles.fileName).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 81)
        let sign = Double(info.direction.bufferSign)
        for (i, line) in lines.dropFirst().enumerated() {
            let values = line.split(separator: ",", omittingEmptySubsequences: false).dropFirst(4)
                .filter { !$0.isEmpty }.compactMap { Double($0) }
            XCTAssertFalse(values.isEmpty, "frame \(i)")
            for value in values { XCTAssertEqual(value, 0.1 * sign * Double(i) * 7.3, accuracy: 0.06, "frame \(i)") }
        }
    }

    func testAnAveragedRebuildRemovesAStaleScanLineProfilesFile() throws {
        let info = try writeRecording(surface: rampSurface)
        _ = try TopoMapBuilder.build(folder: folder, info: info, method: .singleReading)
        XCTAssertTrue(exists(ScanLineProfiles.fileName))
        _ = try TopoMapBuilder.build(folder: folder, info: info, method: .averaged)
        XCTAssertFalse(exists(ScanLineProfiles.fileName))
    }

    func testFractionalCellsGetDistinctLabelsInTopoMapCSV() throws {
        let grid = TopoGridFile(columns: 4, rows: 2, cell: 0.7, qMin: 0, xMin: -0.7, heightMode: true,
                                values: [1, 2, 3, 4, 5, 6, 7, 8])
        let url = folder.appendingPathComponent("TopoMap.csv")
        try TopoMapBuilder.writeGridCSV(grid, to: url)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "across_mm \\ along_mm,0.35,1.05,1.75,2.45")
        XCTAssertTrue(lines[1].hasPrefix("-0.35,"), lines[1])
        XCTAssertTrue(lines[2].hasPrefix("0.35,"), lines[2])
    }

    func testOnlySingleReadingBuildsWriteTheScanLineProfiles() throws {
        let info = try writeRecording(surface: rampSurface)
        _ = try TopoMapBuilder.build(folder: folder, info: info, method: .averaged)
        XCTAssertFalse(exists(ScanLineProfiles.fileName))
        _ = try TopoMapBuilder.build(folder: folder, info: info, method: .singleReading)
        XCTAssertTrue(exists(ScanLineProfiles.fileName))
        // The set of files of the averaged build is part of the single-reading set.
        for name in ["TopoMapGrid.png", "TopoMap.csv", "TopoGrid.bin", "TopoStats.csv", "AcrossProfile.csv",
                     "AlongProfile.csv", "TopoStats.json", "TopoProfiles.json"] {
            XCTAssertTrue(exists(name), name)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".partial") }
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }

    // MARK: - FR-SFM-05: statistics and text

    func testStatsCSVLeavesTheRepeatReadingNoiseBlankForSingleReadingMaps() {
        var stats = makeStats(heightMode: true, speed: true)
        stats.mapMethod = .singleReading
        let single = TopoMapBuilder.statsCSV(stats).split(separator: "\n").map(String.init)
        XCTAssertTrue(single.contains("repeat_reading_std_dev,,mm"), single.joined(separator: "\n"))
        XCTAssertTrue(single.contains("readings_per_cell_mean,12.3,"))
        stats.mapMethod = .averaged
        let averaged = TopoMapBuilder.statsCSV(stats).split(separator: "\n").map(String.init)
        XCTAssertTrue(averaged.contains("repeat_reading_std_dev,0.050,mm"))
        stats.mapMethod = nil
        XCTAssertTrue(TopoMapBuilder.statsCSV(stats).contains("repeat_reading_std_dev,0.050,mm"))
    }

    func testSummaryLineForSingleReadingMapsHasNoRepeatNoise() {
        var stats = makeStats(heightMode: true, speed: true)
        stats.meanHitsPerCell = 1
        stats.mapMethod = .singleReading
        let lines = TopoMapBuilder.summaryLines(stats)
        XCTAssertEqual(lines[5], "Local residual std dev 0.30 mm; 1.0 reading per cell")
        XCTAssertFalse(lines.contains { $0.contains("repeat-reading noise") })
        stats.mapMethod = .averaged
        stats.meanHitsPerCell = 12.34
        XCTAssertEqual(TopoMapBuilder.summaryLines(stats)[5],
                       "Local residual std dev 0.30 mm; repeat-reading noise 0.05 mm; 12.3 readings per cell")
    }

    func testCellTextShowsWholeMillimetresWithoutADecimal() {
        XCTAssertEqual(TopoMapBuilder.cellText(10), "10")
        XCTAssertEqual(TopoMapBuilder.cellText(2), "2")
        XCTAssertEqual(TopoMapBuilder.cellText(10.04), "10")
        XCTAssertEqual(TopoMapBuilder.cellText(1.3), "1.3")
        XCTAssertEqual(TopoMapBuilder.cellText(0.4), "0.4")
        XCTAssertEqual(TopoMapBuilder.cellText(12.5), "12.5")
        XCTAssertEqual(TopoMapBuilder.cellText(5.96), "6")
    }

    func testSummaryLinesUseTheCellTextOfFineCells() {
        var stats = makeStats(heightMode: true, speed: true)
        stats.cellSize = 1.3
        XCTAssertEqual(TopoMapBuilder.summaryLines(stats)[0],
                       "Scanned 1.20 m long × 0.60 m wide, 1.3 mm cells, 85% coverage")
    }

    func testMethodAndLaserLinesAreMapLinesForRebuilds() {
        XCTAssertTrue(TopoMapBuilder.isMapSummaryLine("Map method: one reading per cell (no averaging) …"))
        XCTAssertTrue(TopoMapBuilder.isMapSummaryLine("Laser line: 1234 profiles at 240 fps"))
        XCTAssertTrue(TopoMapBuilder.isMapSummaryLine("Camera parallax: 10 of 12 frame pairs scaled by the LiDAR"))
        XCTAssertTrue(TopoMapBuilder.isMapSummaryLine("Height reference: camera height 1500 mm"))
        XCTAssertTrue(TopoMapBuilder.isMapSummaryLine("Height above the belt mean 12.00 mm, std dev 1.00 mm"))
        XCTAssertFalse(TopoMapBuilder.isMapSummaryLine("1234 profiles, 5.1 s at 240 fps, material travel Right → Left"))
    }

    // MARK: - finish

    func testFinishWritesTheMapFilesOfACellGrid() throws {
        // A 12 × 5 grid of single readings, heights = column, through the shared finishing step.
        var cells = MapCells(method: .singleReading, columns: 14, rows: 7, cell: 2, qMin: 0, xMin: -7, zRef: 0)
        cells.withAccumulator { acc in
            for r in 1...5 {
                for c in 1...12 {
                    let idx = r * acc.columns + c
                    acc.add(Float(c), at: idx, score: 0)
                }
            }
        }
        let output = try TopoMapBuilder.finish(cells: cells, heightMode: true, sensor: .cameraParallax,
                                               speeds: [100, nil], frameCount: 2, duration: 1, travel: 24,
                                               extraLines: ["extra"], folder: folder, composite: nil)
        // The empty margin is trimmed.
        XCTAssertEqual(output.stats.columns, 12)
        XCTAssertEqual(output.stats.rows, 5)
        XCTAssertEqual(output.stats.cellsWithData, 60)
        XCTAssertEqual(output.stats.sensor, .cameraParallax)
        XCTAssertEqual(output.stats.mapMethod, .singleReading)
        XCTAssertEqual(output.stats.heightMode, true)
        XCTAssertEqual(output.stats.meanHitsPerCell, 1, accuracy: 1e-12)
        XCTAssertEqual(output.stats.mean, 6.5, accuracy: 1e-6)
        XCTAssertEqual(output.stats.speedTrackedPercent, 50, accuracy: 1e-9)
        XCTAssertEqual(output.summary.last, "extra")
        XCTAssertEqual(output.grid.qMin, 2, accuracy: 1e-9)
        XCTAssertEqual(output.grid.xMin, -5, accuracy: 1e-9)
        let grid = try loadGrid()
        XCTAssertEqual(grid.values.filter { $0.isFinite }.count, 60)
        XCTAssertEqual(grid.values[0], 1)
        XCTAssertEqual(grid.values[11], 12)
    }

    func testFinishRejectsAGridWithTooFewCells() {
        var cells = MapCells(method: .averaged, columns: 5, rows: 5, cell: 1, qMin: 0, xMin: 0, zRef: 0)
        cells.withAccumulator { acc in
            for i in 0..<9 { acc.add(1, at: i, score: 0) }
        }
        XCTAssertThrowsError(try TopoMapBuilder.finish(cells: cells, heightMode: true, sensor: .lidar, speeds: [],
                                                       frameCount: 0, duration: 0, travel: 0, extraLines: [],
                                                       folder: folder, composite: nil)) {
            assertLineError($0, .notEnoughData)
        }
        let empty = MapCells(method: .averaged, columns: 0, rows: 0, cell: 1, qMin: 0, xMin: 0, zRef: 0)
        XCTAssertThrowsError(try TopoMapBuilder.finish(cells: empty, heightMode: true, sensor: .lidar, speeds: [],
                                                       frameCount: 0, duration: 0, travel: 0, extraLines: [],
                                                       folder: folder, composite: nil)) {
            assertLineError($0, .notEnoughData)
        }
    }
}
