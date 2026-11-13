import CoreGraphics
import XCTest

/// `LaserMapBuilder` on synthetic laser recordings (design §14.7, FR-LAS-08/09). The recordings are written with the
/// real `LaserRecordingInfo.save` and `ProfilesFileWriter`.
///
/// Geometry of the synthetic camera: 400 × 300 video buffer, 200 profile columns (u = 1, 3 … 399), fx = fy = 1000 px,
/// principal point (200, 150), camera 500 mm above the belt, laser term K = 200 px (A_k = K with the baseline at c_y), laser line on the empty belt at row 150
/// (the principal row, so the belt has along position 0). One map cell is 1 mm (the across spacing of the columns at
/// the belt: 2 · 500 / 1000 mm).
final class LaserMapBuilderTests: XCTestCase {
    private var folder: URL!
    private let blockHeight = 20.0

    override func setUpWithError() throws {
        folder = try makeTempFolder()
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    /// Saves `info` and a Profiles.bin of `frameCount` frames. `rowAt(frame, column)` is the detected row; every
    /// `trackedEvery`-th frame is flagged tracked (a speed of `travelStep · 240` mm/s, none on frames at 8 mod 16).
    private func writeRecording(_ info: LaserRecordingInfo, frameCount: Int, travelStep: Double = 1,
                                trackedEvery: Int = 0, rowAt: (Int, Int) -> Float) throws {
        try info.save(to: folder)
        let writer = try ProfilesFileWriter(url: folder.appendingPathComponent(ProfilesFile.fileName),
                                            columns: info.columns)
        for i in 0..<frameCount {
            let tracked = trackedEvery > 0 && i % trackedEvery == 0
            let hasSpeed = tracked && i % 16 != 8
            let profile = (0..<info.columnCount).map { rowAt(i, $0) }
            try writer.append(time: Double(i) / 240, travel: Double(i) * travelStep,
                              speed: hasSpeed ? travelStep * 240 : nil,
                              flags: (tracked ? ProfilesFile.trackedFlag : 0) | (hasSpeed ? ProfilesFile.speedFlag : 0),
                              rows: profile)
        }
        try writer.close()
    }

    /// Belt at the baseline row; frames 100…200 show a `blockHeight`-mm block over the columns u = 120 … 279.
    private func writeBlockRecording(_ info: LaserRecordingInfo) throws {
        let calibration = info.calibration
        // Baseline row = c_y here, so every column's A_k equals K; use the column scale as the builder does.
        let shift = Float(LaserGeometry.shift(height: blockHeight, cameraHeight: calibration.cameraHeight,
                                              scale: calibration.shiftScale(column: 0) ?? 0))
        try writeRecording(info, frameCount: 300, trackedEvery: 8) { i, k in
            (100...200).contains(i) && (120..<280).contains(calibration.columns.u(k)) ? 150 + shift : 150
        }
    }

    private func loadGrid() throws -> TopoGridFile {
        try XCTUnwrap(TopoGridFile.load(from: folder))
    }

    /// Values of the cells whose centre lies at m = sign · q inside `m` and at across position x inside `x`.
    private func cellValues(_ grid: TopoGridFile, sign: Double, m: ClosedRange<Double>, x: ClosedRange<Double>)
        -> [Float] {
        var out: [Float] = []
        for r in 0..<grid.rows {
            let xc = grid.xMin + (Double(r) + 0.5) * grid.cell
            guard x.contains(xc) else { continue }
            for c in 0..<grid.columns {
                let qc = grid.qMin + (Double(c) + 0.5) * grid.cell
                if m.contains(sign * qc) { out.append(grid.values[r * grid.columns + c]) }
            }
        }
        return out
    }

    // MARK: - Heights on a belt with a block

    private func assertBlockMap(direction: TravelDirection) throws {
        let info = makeLaserInfo(direction: direction, mapMethod: .singleReading)
        try writeBlockRecording(info)
        let output = try LaserMapBuilder.build(folder: folder, info: info)
        let grid = try loadGrid()
        let sign = Double(direction.bufferSign)
        XCTAssertTrue(grid.heightMode)
        XCTAssertEqual(grid.cell, 1, accuracy: 1e-9)

        // On the block, heights are its 20 mm (the stored rows are in 1/32 px, so 20.02 mm).
        let onBlock = cellValues(grid, sign: sign, m: 115...190, x: -30...30)
        XCTAssertGreaterThan(onBlock.count, 4000)
        for value in onBlock { XCTAssertEqual(value, 20, accuracy: 0.1) }

        // On the belt, beside the block along the travel and beside it across, heights are 0.
        for (m, x) in [(10.0...80.0, -30.0...30.0), (230.0...290.0, -30.0...30.0), (115.0...190.0, 43.0...48.0),
                       (115.0...190.0, -48.0 ... -43.0)] {
            let belt = cellValues(grid, sign: sign, m: m, x: x)
            XCTAssertGreaterThan(belt.count, 100, "\(m) \(x)")
            for value in belt { XCTAssertEqual(value, 0, accuracy: 1e-3, "\(m) \(x)") }
        }

        let stats = output.stats
        XCTAssertEqual(stats.maximum, 20, accuracy: 0.1)
        XCTAssertEqual(stats.minimum, 0, accuracy: 1e-3)
        XCTAssertEqual(stats.lengthMM, 300, accuracy: 3)
        XCTAssertEqual(stats.widthMM, 200, accuracy: 1)
    }

    func testRightToLeftBlockIsMeasuredWithItsHeightAndTheBeltAtZero() throws {
        try assertBlockMap(direction: .rightToLeft)
    }

    func testLeftToRightBlockIsMeasuredWithItsHeightAndTheBeltAtZero() throws {
        try assertBlockMap(direction: .leftToRight)
    }

    func testStatisticsOfALaserMap() throws {
        let info = makeLaserInfo(mapMethod: .singleReading)
        try writeBlockRecording(info)
        let output = try LaserMapBuilder.build(folder: folder, info: info)
        let stats = output.stats
        XCTAssertEqual(stats.sensor, .laserLine)
        XCTAssertEqual(stats.mapMethod, .singleReading)
        XCTAssertEqual(stats.heightMode, true)
        XCTAssertNil(stats.cvPercent)
        XCTAssertEqual(stats.cellSize, 1, accuracy: 1e-9)
        XCTAssertEqual(stats.meanHitsPerCell, 1, accuracy: 1e-12)
        XCTAssertEqual(stats.frames, 300)
        XCTAssertEqual(stats.duration, 299.0 / 240, accuracy: 1e-9)
        XCTAssertEqual(stats.speedMean ?? 0, 240, accuracy: 1e-3)
        XCTAssertEqual(stats.speedTrackedPercent, 50, accuracy: 1e-9)
        XCTAssertGreaterThan(stats.coveragePercent, 90)

        let reread = try JSONDecoder().decode(TopoStats.self, from: Data(contentsOf: folder
            .appendingPathComponent("TopoStats.json")))
        XCTAssertEqual(reread.sensor, .laserLine)
        XCTAssertEqual(reread.mapMethod, .singleReading)
    }

    func testSummaryAndFiles() throws {
        let info = makeLaserInfo(mapMethod: .singleReading)
        try writeBlockRecording(info)
        let output = try LaserMapBuilder.build(folder: folder, info: info)
        XCTAssertTrue(output.summary.contains(
            "Laser line: 300 profiles at 240 fps, 100 % of columns detected, height scale from a 10.0 mm shim, "
            + "camera height 500 mm"), output.summary.joined(separator: "\n"))
        XCTAssertTrue(output.summary.contains(
            "Map method: one reading per cell (no averaging), the laser reading nearest the cell centre"))
        XCTAssertTrue(output.summary.first?.hasPrefix("Scanned ") == true)
        XCTAssertTrue(output.summary.contains { $0.hasPrefix("Height above baseline mean") })

        for name in ["TopoMapGrid.png", "TopoMap.csv", "TopoGrid.bin", "TopoStats.csv", "AcrossProfile.csv",
                     "AlongProfile.csv", "TopoStats.json", "TopoProfiles.json"] {
            XCTAssertTrue(exists(name), name)
        }
        XCTAssertFalse(exists(ScanLineProfiles.fileName))     // LiDAR single-frame maps only
        XCTAssertFalse(exists("TopoMap.png"))                 // no composite was asked for
        let csv = try String(contentsOf: folder.appendingPathComponent("TopoStats.csv"), encoding: .utf8)
        XCTAssertTrue(csv.contains("\nrepeat_reading_std_dev,,mm\n"))
        XCTAssertTrue(csv.contains("\nvalues,height_above_flat_baseline,\n"))
    }

    func testCompositeIsCalledOnceAndItsPictureIsStaged() throws {
        let info = makeLaserInfo(mapMethod: .singleReading)
        try writeBlockRecording(info)
        var calls = 0
        var sensor: MapSensor?
        _ = try LaserMapBuilder.build(folder: folder, info: info, composite: { image, stats in
            calls += 1
            sensor = stats.sensor
            XCTAssertGreaterThan(image.width, 0)
            return Data("png".utf8)
        })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(sensor, .laserLine)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("TopoMap.png")), Data("png".utf8))
    }

    func testReadingsOutsideTheHeightRangeAreDroppedAndCounted() throws {
        let info = makeLaserInfo(mapMethod: .singleReading)
        let calibration = info.calibration
        // Every tenth column reads a line 1000 px away: h = 416 mm, above 0.8 H.
        try writeRecording(info, frameCount: 60) { _, k in k % 10 == 0 ? 1150 : 150 }
        let output = try LaserMapBuilder.build(folder: folder, info: info)
        XCTAssertNil(LaserGeometry.height(shift: 1000, cameraHeight: calibration.cameraHeight, scale: 200))
        XCTAssertTrue(output.summary.contains { $0.contains("90 % of columns detected") },
                      output.summary.joined(separator: "\n"))
        XCTAssertEqual(output.stats.maximum, 0, accuracy: 1e-3)
    }

    // MARK: - Single reading versus averaged

    /// A flat belt; odd frames read the line half a pixel lower (1.25 mm high). Frames are 0.5 mm apart, so every cell
    /// gets an even frame exactly at its centre and an odd one a quarter of a cell away.
    private func writeAlternatingRecording(_ info: LaserRecordingInfo) throws {
        try writeRecording(info, frameCount: 600, travelStep: 0.5) { i, _ in i % 2 == 1 ? 150.5 : 150 }
    }

    func testSingleReadingKeepsTheReadingNearestTheCellCentre() throws {
        let info = makeLaserInfo(mapMethod: .singleReading)
        try writeAlternatingRecording(info)
        let output = try LaserMapBuilder.build(folder: folder, info: info)
        XCTAssertEqual(output.stats.meanHitsPerCell, 1, accuracy: 1e-12)
        XCTAssertEqual(output.stats.cellSize, 1, accuracy: 1e-9)
        let finite = try loadGrid().values.filter { $0.isFinite }
        XCTAssertGreaterThan(finite.count, 10_000)
        for value in finite { XCTAssertEqual(value, 0, accuracy: 1e-3) }
    }

    func testAveragedMapMixesBothReadingsOfACell() throws {
        let info = makeLaserInfo(mapMethod: .singleReading)
        try writeAlternatingRecording(info)
        let output = try LaserMapBuilder.build(folder: folder, info: info, method: .averaged)
        XCTAssertEqual(output.stats.mapMethod, .averaged)
        XCTAssertEqual(output.stats.meanHitsPerCell, 2, accuracy: 0.01)
        let expected = 0.5 * 500 * 0.5 / 200.5          // half of h = H·d / (A + d) for d = 0.5 px
        let finite = try loadGrid().values.filter { $0.isFinite }
        XCTAssertGreaterThan(finite.count, 10_000)
        for value in finite { XCTAssertEqual(Double(value), expected, accuracy: 0.01) }
        XCTAssertFalse(output.summary.contains { $0.hasPrefix("Map method:") })
    }

    func testMethodComesFromTheRecordingUnlessGiven() throws {
        var info = makeLaserInfo(mapMethod: .averaged)
        try writeAlternatingRecording(info)
        XCTAssertEqual(try LaserMapBuilder.build(folder: folder, info: info).stats.mapMethod, .averaged)
        XCTAssertEqual(try LaserMapBuilder.build(folder: folder, info: info, method: .singleReading).stats.mapMethod,
                       .singleReading)
        info.mapMethod = .singleReading
        XCTAssertEqual(try LaserMapBuilder.build(folder: folder, info: info).stats.mapMethod, .singleReading)
    }

    // MARK: - Refusals

    func testRecordingWithoutAScaleIsRejected() throws {
        let info = makeLaserInfo(calibration: makeLaserCalibration(scale: nil))
        try writeRecording(info, frameCount: 60) { _, _ in 150 }
        XCTAssertThrowsError(try LaserMapBuilder.build(folder: folder, info: info)) {
            assertLineError($0, LaserMapBuilder.calibrationIncomplete)
        }
    }

    func testColumnLayoutThatDiffersFromProfilesBinIsRejected() throws {
        var info = makeLaserInfo()
        try writeRecording(info, frameCount: 60) { _, _ in 150 }
        info.columnCount -= 1
        XCTAssertThrowsError(try LaserMapBuilder.build(folder: folder, info: info)) {
            assertLineError($0, LaserMapBuilder.calibrationMismatch)
        }
    }

    func testBaselineOfAnotherLengthIsRejected() throws {
        var info = makeLaserInfo()
        try writeRecording(info, frameCount: 60) { _, _ in 150 }
        info.calibration.baselineRows.removeLast()
        XCTAssertThrowsError(try LaserMapBuilder.build(folder: folder, info: info)) {
            assertLineError($0, LaserMapBuilder.calibrationMismatch)
        }
    }

    func testFewerThanTwoFramesAreRejected() throws {
        let info = makeLaserInfo()
        try writeRecording(info, frameCount: 1) { _, _ in 150 }
        XCTAssertThrowsError(try LaserMapBuilder.build(folder: folder, info: info)) {
            assertLineError($0, .notEnoughData)
        }
    }

    func testRecordingWithoutDetectedLinesIsRejected() throws {
        let info = makeLaserInfo()
        try writeRecording(info, frameCount: 60) { _, _ in .nan }
        XCTAssertThrowsError(try LaserMapBuilder.build(folder: folder, info: info)) {
            assertLineError($0, LaserMapBuilder.lineNotFound)
        }
    }

    func testMissingIntrinsicsAreRejected() throws {
        var info = makeLaserInfo()
        try writeRecording(info, frameCount: 60) { _, _ in 150 }
        info.fx = 0
        XCTAssertThrowsError(try LaserMapBuilder.build(folder: folder, info: info)) {
            assertLineError($0, LaserMapBuilder.intrinsicsMissing)
        }
    }

    func testMissingProfilesFileThrows() {
        XCTAssertThrowsError(try LaserMapBuilder.build(folder: folder, info: makeLaserInfo()))
    }

    // MARK: - Cell size

    func testCellIsTheLargestOfAcrossSpacingTravelStepAndMinimum() {
        XCTAssertEqual(LaserMapBuilder.cellSize(acrossSpacing: 1, steps: [], length: 100, width: 100), 1,
                       accuracy: 1e-12)
        XCTAssertEqual(LaserMapBuilder.cellSize(acrossSpacing: 0.3, steps: [Double](repeating: 0.5, count: 5),
                                                length: 100, width: 100), 0.5, accuracy: 1e-12)
        XCTAssertEqual(LaserMapBuilder.cellSize(acrossSpacing: 0.05, steps: [0.01], length: 100, width: 100), 0.2,
                       accuracy: 1e-12)
        XCTAssertEqual(LaserMapBuilder.minimumCell, 0.2)
    }

    func testCellIsRoundedUpToATenthOfAMillimetre() {
        XCTAssertEqual(LaserMapBuilder.cellSize(acrossSpacing: 0.31, steps: [], length: 100, width: 100), 0.4,
                       accuracy: 1e-12)
        XCTAssertEqual(LaserMapBuilder.cellSize(acrossSpacing: 0.3, steps: [], length: 100, width: 100), 0.3,
                       accuracy: 1e-12)
        XCTAssertEqual(LaserMapBuilder.cellSize(acrossSpacing: 0.96, steps: [], length: 100, width: 100), 1,
                       accuracy: 1e-12)
        XCTAssertEqual(LaserMapBuilder.cellSize(acrossSpacing: 1.04, steps: [], length: 100, width: 100), 1.1,
                       accuracy: 1e-12)
    }

    func testTravelStepIsTheNinetiethPercentile() {
        // Index (n − 1) · 0.9 rounded: 8 of 10 values.
        let ones = [Double](repeating: 1, count: 8)
        XCTAssertEqual(LaserMapBuilder.cellSize(acrossSpacing: 0.5, steps: ones + [5, 5], length: 100, width: 100), 5,
                       accuracy: 1e-12)
        XCTAssertEqual(LaserMapBuilder.cellSize(acrossSpacing: 0.5, steps: ones + [1, 5], length: 100, width: 100), 1,
                       accuracy: 1e-12)
    }

    func testUnusableStepsAndSpacingAreIgnored() {
        XCTAssertEqual(LaserMapBuilder.cellSize(acrossSpacing: 0.5, steps: [0, -3, .nan, .infinity, 2],
                                                length: 100, width: 100), 2, accuracy: 1e-12)
        XCTAssertEqual(LaserMapBuilder.cellSize(acrossSpacing: .nan, steps: [], length: 100, width: 100), 0.2,
                       accuracy: 1e-12)
        XCTAssertEqual(LaserMapBuilder.cellSize(acrossSpacing: 1, steps: [], length: -5, width: -5), 1,
                       accuracy: 1e-12)
    }

    func testCellGrowsByAQuarterUntilTheGridFits() {
        func count(_ c: Double) -> Double {
            (((10_000 + c) / c).rounded(.up) + 1) * (((5_000 + c) / c).rounded(.up) + 1)
        }
        let cell = LaserMapBuilder.cellSize(acrossSpacing: 1, steps: [], length: 10_000, width: 5_000)
        XCTAssertLessThanOrEqual(count(cell), Double(TopoGridFile.maxCells))
        // Each ×1.25 step is rounded up to 0.1 mm (M2R-1): 1 → 1.3 → 1.7 → 2.2 → 2.8 → 3.5 → 4.4.
        var expected = 1.0
        var previous = expected
        while count(expected) > Double(TopoGridFile.maxCells) {
            previous = expected
            expected = ((expected * 1.25 * 10) - 1e-6).rounded(.up) / 10
        }
        XCTAssertEqual(cell, expected, accuracy: 1e-9)
        XCTAssertEqual(cell, 4.4, accuracy: 1e-9)
        XCTAssertGreaterThan(count(previous), Double(TopoGridFile.maxCells))
        XCTAssertEqual((cell * 10).rounded(), cell * 10, accuracy: 1e-9)      // a multiple of 0.1 mm
    }

    // MARK: - Text

    func testLaserLineTextNamesTheScaleSource() {
        let shim = makeLaserInfo()
        XCTAssertEqual(LaserMapBuilder.laserLine(info: shim, frames: 1234, detectedPercent: 97.4),
                       "Laser line: 1234 profiles at 240 fps, 97 % of columns detected, height scale from a "
                       + "10.0 mm shim, camera height 500 mm")
        var calibration = makeLaserCalibration()
        calibration.scaleSource = .angle
        calibration.laserAngle = 25
        calibration.shimThickness = nil
        XCTAssertEqual(LaserMapBuilder.laserLine(info: makeLaserInfo(calibration: calibration), frames: 10,
                                                 detectedPercent: 50),
                       "Laser line: 10 profiles at 240 fps, 50 % of columns detected, height scale from a "
                       + "25.0° laser angle, camera height 500 mm")
        calibration.laserAngle = nil
        XCTAssertTrue(LaserMapBuilder.laserLine(info: makeLaserInfo(calibration: calibration), frames: 10,
                                                detectedPercent: 50).contains("height scale not recorded"))
    }

    func testLaserLineIsAMapLine() {
        let line = LaserMapBuilder.laserLine(info: makeLaserInfo(), frames: 5, detectedPercent: 80)
        XCTAssertTrue(TopoMapBuilder.isMapSummaryLine(line))
    }

    func testRecordSummaryRefreshesTheRecordingLineAndReplacesTheMapLines() {
        let info = makeLaserInfo(frameCount: 300, duration: 1.2)
        let existing = [
            "100 profiles, 0.4 s at 240 fps, material travel Right → Left",
            "Scanned 0.10 m long × 0.10 m wide, 1 mm cells, 50% coverage",
            "Laser line: 100 profiles at 240 fps, 90 % of columns detected, height scale not recorded, "
                + "camera height 500 mm",
            "Map method: one reading per cell (no averaging), the laser reading nearest the cell centre",
            "Some other note"
        ]
        let map = ["Scanned 0.30 m long × 0.20 m wide, 1 mm cells, 99% coverage", "Laser line: new"]
        let result = LaserMapBuilder.recordSummary(existing: existing, info: info, map: map)
        XCTAssertEqual(result, [info.summaryLine, map[0], map[1], "Some other note"])
        XCTAssertEqual(result[0], "300 profiles, 1.2 s at 240 fps, material travel Right → Left")
    }

    func testRecordSummaryWithoutAnExistingLineStartsWithTheRecordingLine() {
        let info = makeLaserInfo(frameCount: 5, duration: 0.1)
        let result = LaserMapBuilder.recordSummary(existing: [], info: info, map: ["Scanned x"])
        XCTAssertEqual(result, [info.summaryLine, "Scanned x"])
    }

    // MARK: - Replay (FR-LAS-09)

    func testReplayUsesTheTrackedFramesAndRevealsAtTheLaserLine() throws {
        // Baseline row 160: the line is 10 px · 500 / 1000 = 5 mm further along than the principal row.
        let info = makeLaserInfo(calibration: makeLaserCalibration(baselineRow: 160))
        try writeRecording(info, frameCount: 300, trackedEvery: 8) { _, _ in 160 }
        let frames = try LaserMapBuilder.replayFrames(folder: folder, info: info)
        XCTAssertEqual(frames.times.count, 38)                  // frames 0, 8 … 296
        XCTAssertEqual(frames.travel.count, 38)
        XCTAssertEqual(frames.speeds.count, 38)
        XCTAssertEqual(frames.reveal.count, 38)
        XCTAssertEqual(frames.times[1], 8.0 / 240, accuracy: 1e-12)
        XCTAssertEqual(frames.travel[1], 8, accuracy: 1e-12)
        XCTAssertEqual(frames.times.last ?? 0, 296.0 / 240, accuracy: 1e-12)
        XCTAssertEqual(frames.speeds[0] ?? 0, 240, accuracy: 1e-3)
        XCTAssertNil(frames.speeds[1])                          // tracked, but no texture lock (frame 8)
        for (travel, reveal) in zip(frames.travel, frames.reveal) {
            XCTAssertEqual(reveal, travel - 5, accuracy: 1e-9)
        }
    }

    func testReplayRevealFollowsTheTravelDirection() throws {
        let info = makeLaserInfo(calibration: makeLaserCalibration(baselineRow: 160), direction: .leftToRight)
        try writeRecording(info, frameCount: 100, trackedEvery: 8) { _, _ in 160 }
        let frames = try LaserMapBuilder.replayFrames(folder: folder, info: info)
        for (travel, reveal) in zip(frames.travel, frames.reveal) {
            XCTAssertEqual(reveal, travel + 5, accuracy: 1e-9)
        }
    }

    func testReplayUsesEveryFrameWhenFewerThanTwoAreTracked() throws {
        let info = makeLaserInfo()
        try writeRecording(info, frameCount: 50, trackedEvery: 0) { _, _ in 150 }
        XCTAssertEqual(try LaserMapBuilder.replayFrames(folder: folder, info: info).times.count, 50)
        try writeRecording(info, frameCount: 50, trackedEvery: 100) { _, _ in 150 }       // frame 0 only
        XCTAssertEqual(try LaserMapBuilder.replayFrames(folder: folder, info: info).times.count, 50)
    }

    func testReplaySourceCanBePreparedFromTheLaserMap() throws {
        let info = makeLaserInfo(mapMethod: .singleReading)
        try writeBlockRecording(info)
        _ = try LaserMapBuilder.build(folder: folder, info: info)
        let grid = try loadGrid()
        let frames = try LaserMapBuilder.replayFrames(folder: folder, info: info)
        let source = try TopoReplaySource.make(grid: grid, direction: info.direction, frames: frames)
        XCTAssertTrue(source.heightMode)
        XCTAssertEqual(source.cell, 1, accuracy: 1e-9)
        XCTAssertGreaterThan(source.columns, 290)
        XCTAssertGreaterThan(source.duration, 1.2)
        XCTAssertEqual(source.p99, 20, accuracy: 0.2)
        // The newest complete line never goes backwards.
        for (a, b) in zip(source.revealP, source.revealP.dropFirst()) { XCTAssertLessThanOrEqual(a, b) }
    }
}
