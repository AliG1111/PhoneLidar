import XCTest
import simd

final class TopoReplaySourceTests: XCTestCase {
    // MARK: - Fixtures

    /// Grid whose cell (row r, column c) holds height `value(r, c)`; NaN = no data.
    private func makeGrid(columns: Int, rows: Int, heightMode: Bool = true, cell: Double = 10,
                          qMin: Double = 0, xMin: Double = -30,
                          value: (Int, Int) -> Float) -> TopoGridFile {
        var values = [Float](repeating: .nan, count: columns * rows)
        for r in 0..<rows {
            for c in 0..<columns {
                values[r * columns + c] = value(r, c)
            }
        }
        return TopoGridFile(columns: columns, rows: rows, cell: cell, qMin: qMin, xMin: xMin,
                            heightMode: heightMode, values: values)
    }

    /// Frames at `dt` second intervals; frame i has travel `startTravel + i · travelStep` (mm).
    /// With the 64 × 48 depth map used here the newest complete line is 210 mm behind the travel
    /// position for right → left travel (view edge: row 45, 21 pixels of 10 mm below the centre).
    private func makeInfo(frameCount: Int, dt: Double, startTravel: Double, travelStep: Double,
                          direction: TravelDirection = .rightToLeft) -> LineRecordingInfo {
        let frames = (0..<frameCount).map { i in
            makeFrame(index: i, time: Double(i) * dt, speed: travelStep / dt,
                      travel: startTravel + Double(i) * travelStep)
        }
        return LineRecordingInfo(depthWidth: 64, depthHeight: 48, videoWidth: 1080, videoHeight: 1920,
                                 filteredDepth: true, shortShutter: true, direction: direction, frames: frames)
    }

    /// 12 columns × 6 rows, height = column index; newest complete line at p = 10 · frame index.
    private func makeStandardSource(direction: TravelDirection = .rightToLeft) throws -> TopoReplaySource {
        let grid = makeGrid(columns: 12, rows: 6) { _, c in Float(c) }
        let info = makeInfo(frameCount: 21, dt: 0.1, startTravel: 210, travelStep: 10, direction: direction)
        return try TopoReplaySource.make(grid: grid, info: info)
    }

    // MARK: - Grid preparation

    func testRightToLeftTravelKeepsColumnsOldestFirst() throws {
        let source = try makeStandardSource()
        XCTAssertTrue(source.heightMode)
        XCTAssertEqual(source.rows, 6)
        XCTAssertEqual(source.columns, 12)
        XCTAssertEqual(source.cell, 10)
        XCTAssertEqual(source.pStart, 0, accuracy: 1e-9)
        XCTAssertEqual(source.pEnd, 120, accuracy: 1e-9)
        XCTAssertEqual(source.widthMM, 60, accuracy: 1e-9)
        XCTAssertEqual(source.acrossStart, -30, accuracy: 1e-9)
        for r in 0..<6 {
            for c in 0..<12 {
                XCTAssertEqual(source.values[r * 12 + c], Float(c))
            }
        }
    }

    func testLeftToRightTravelReversesTheColumns() throws {
        let source = try makeStandardSource(direction: .leftToRight)
        XCTAssertEqual(source.columns, 12)
        // The newest material is at the end: the screen's leftmost column is the newest.
        XCTAssertEqual(source.values[0], 11)
        XCTAssertEqual(source.values[11], 0)
        XCTAssertEqual(source.pStart, -120, accuracy: 1e-9)
        XCTAssertEqual(source.pEnd, 0, accuracy: 1e-9)
    }

    func testEmptyEdgeColumnsAndRowsAreTrimmed() throws {
        // Rows 0 and 5 and columns 0, 1 and 11 hold no data.
        let grid = makeGrid(columns: 12, rows: 6) { r, c in
            (r == 0 || r == 5 || c < 2 || c == 11) ? .nan : Float(10 * r + c)
        }
        let info = makeInfo(frameCount: 21, dt: 0.1, startTravel: 210, travelStep: 10)
        let source = try TopoReplaySource.make(grid: grid, info: info)
        XCTAssertEqual(source.rows, 4)
        XCTAssertEqual(source.columns, 9)
        XCTAssertEqual(source.acrossStart, -30 + 10, accuracy: 1e-9)      // starts at row 1
        XCTAssertEqual(source.pStart, 20, accuracy: 1e-9)                 // starts at column 2
        XCTAssertEqual(source.values[0], 12)                              // row 1, column 2
        XCTAssertEqual(source.values[4 * 9 - 1], 4 * 10 + 10)             // row 4, column 10
    }

    func testNaNCellsStayNaNInsideTheGrid() throws {
        let grid = makeGrid(columns: 12, rows: 6) { r, c in (r == 2 && c == 5) ? .nan : Float(c) }
        let source = try TopoReplaySource.make(grid: grid, info: makeInfo(frameCount: 21, dt: 0.1,
                                                                          startTravel: 210, travelStep: 10))
        XCTAssertTrue(source.values[2 * 12 + 5].isNaN)
        XCTAssertEqual(source.values[2 * 12 + 4], 4)
    }

    func testDistancesBecomeHeightsRelativeToTheMedianDistance() throws {
        // Mostly 1000 mm with one column 10 mm closer: relative heights 0 and +10.
        let grid = makeGrid(columns: 12, rows: 6, heightMode: false) { _, c in c == 6 ? 990 : 1000 }
        let source = try TopoReplaySource.make(grid: grid, info: makeInfo(frameCount: 21, dt: 0.1,
                                                                          startTravel: 210, travelStep: 10))
        XCTAssertFalse(source.heightMode)
        XCTAssertEqual(source.referenceDistance, 1000, accuracy: 1e-9)
        XCTAssertEqual(source.values[0], 0)
        XCTAssertEqual(source.values[6], 10)      // closer to the camera = positive
        XCTAssertEqual(source.median, 0, accuracy: 1e-6)
    }

    func testHeightStatisticsForTheDefaultTarget() throws {
        let source = try makeStandardSource()
        // 72 samples, 6 of each value 0…11; nearest-rank percentiles of the sorted list.
        XCTAssertEqual(source.median, 6, accuracy: 1e-9)
        XCTAssertEqual(source.robustStdDev, 4.5, accuracy: 1e-9)    // (P84 − P16) / 2 = (10 − 1) / 2
        XCTAssertEqual(source.p01, 0, accuracy: 1e-9)
        XCTAssertEqual(source.p99, 11, accuracy: 1e-9)
    }

    func testRobustStdDevHasAFloorForFlatSurfaces() throws {
        let grid = makeGrid(columns: 12, rows: 6) { _, _ in 2 }
        let source = try TopoReplaySource.make(grid: grid, info: makeInfo(frameCount: 21, dt: 0.1,
                                                                          startTravel: 210, travelStep: 10))
        XCTAssertEqual(source.median, 2, accuracy: 1e-9)
        XCTAssertEqual(source.robustStdDev, 0.05, accuracy: 1e-9)
    }

    // MARK: - Rejected input

    func testSourceNeedsFramesAndAGridOfAtLeastTwoByTwo() {
        let grid = makeGrid(columns: 12, rows: 6) { _, c in Float(c) }
        let noFrames = makeInfo(frameCount: 0, dt: 0.1, startTravel: 0, travelStep: 10)
        XCTAssertThrowsError(try TopoReplaySource.make(grid: grid, info: noFrames)) {
            assertLineError($0, .notEnoughData)
        }
        let info = makeInfo(frameCount: 21, dt: 0.1, startTravel: 210, travelStep: 10)
        for (columns, rows) in [(1, 6), (12, 1)] {
            let thin = makeGrid(columns: columns, rows: rows) { _, c in Float(c) }
            XCTAssertThrowsError(try TopoReplaySource.make(grid: thin, info: info)) {
                assertLineError($0, .notEnoughData)
            }
        }
    }

    func testAllNaNGridIsRejectedInBothModes() {
        let info = makeInfo(frameCount: 21, dt: 0.1, startTravel: 210, travelStep: 10)
        for heightMode in [true, false] {
            let grid = makeGrid(columns: 12, rows: 6, heightMode: heightMode) { _, _ in .nan }
            XCTAssertThrowsError(try TopoReplaySource.make(grid: grid, info: info)) {
                assertLineError($0, .notEnoughData)
            }
        }
    }

    func testGridWithFewerThanTenValuesIsRejected() {
        let info = makeInfo(frameCount: 21, dt: 0.1, startTravel: 210, travelStep: 10)
        let grid = makeGrid(columns: 3, rows: 3) { _, _ in 1 }      // 9 values
        XCTAssertThrowsError(try TopoReplaySource.make(grid: grid, info: info)) {
            assertLineError($0, .notEnoughData)
        }
    }

    func testFramesWithoutIntrinsicsAreRejected() {
        let grid = makeGrid(columns: 12, rows: 6) { _, c in Float(c) }
        var info = makeInfo(frameCount: 21, dt: 0.1, startTravel: 210, travelStep: 10)
        info.frames = info.frames.map { frame in
            var copy = frame
            copy.fy = 0
            return copy
        }
        XCTAssertThrowsError(try TopoReplaySource.make(grid: grid, info: info)) {
            assertLineError($0, .notEnoughData)
        }
    }

    // MARK: - Newest-line timing

    func testRevealPositionIsTheViewEdgeBehindTheTravelPosition() throws {
        let source = try makeStandardSource()
        XCTAssertEqual(source.frameTimes.count, 21)
        for (i, p) in source.revealP.enumerated() {
            XCTAssertEqual(p, 10 * Double(i), accuracy: 1e-9, "frame \(i)")
        }
        XCTAssertEqual(source.recordingDuration, 2.0, accuracy: 1e-9)
    }

    func testRevealPositionNeverDecreasesWhenTheMaterialMovesBackwards() throws {
        let grid = makeGrid(columns: 12, rows: 6) { _, c in Float(c) }
        var info = makeInfo(frameCount: 21, dt: 0.1, startTravel: 210, travelStep: 10)
        info.frames[10].travel -= 50       // a backwards jitter
        let source = try TopoReplaySource.make(grid: grid, info: info)
        for i in 1..<source.revealP.count {
            XCTAssertGreaterThanOrEqual(source.revealP[i], source.revealP[i - 1])
        }
        XCTAssertEqual(source.revealP[10], source.revealP[9], accuracy: 1e-9)
    }

    func testRevealTimeIsTheTimeThePositionIsReached() throws {
        let source = try makeStandardSource()
        XCTAssertEqual(source.revealTime(of: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(source.revealTime(of: 5), 0.05, accuracy: 1e-9)
        XCTAssertEqual(source.revealTime(of: 10), 0.1, accuracy: 1e-9)
        XCTAssertEqual(source.revealTime(of: 100), 1.0, accuracy: 1e-9)
        XCTAssertEqual(source.revealTime(of: -50), 0, accuracy: 1e-9)       // before the first line
    }

    func testRevealPositionInterpolatesBetweenFrames() throws {
        let source = try makeStandardSource()
        XCTAssertEqual(source.revealPosition(at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(source.revealPosition(at: 0.05), 5, accuracy: 1e-9)
        XCTAssertEqual(source.revealPosition(at: 1.0), 100, accuracy: 1e-9)
        XCTAssertEqual(source.revealPosition(at: 1.234), 123.4, accuracy: 1e-6)
    }

    func testRevealPositionAndTimeAreInverseOfEachOther() throws {
        let source = try makeStandardSource()
        for t in stride(from: 0.0, through: 1.9, by: 0.137) {
            let p = source.revealPosition(at: t)
            XCTAssertEqual(source.revealTime(of: p), t, accuracy: 1e-9, "t = \(t)")
        }
    }

    func testFrameIndexAtTime() throws {
        let source = try makeStandardSource()
        XCTAssertEqual(source.frameIndex(at: 0), 0)
        XCTAssertEqual(source.frameIndex(at: 0.5), 5)
        XCTAssertEqual(source.frameIndex(at: 0.51), 5)
        XCTAssertEqual(source.frameIndex(at: 1.99), 19)
        XCTAssertEqual(source.frameIndex(at: 50), 20)      // beyond the recording: the last frame
        XCTAssertEqual(source.frameIndex(at: -1), 0)
    }

    func testSpeedsAreSmoothed() throws {
        let source = try makeStandardSource()
        XCTAssertEqual(source.speeds.count, 21)
        for speed in source.speeds { XCTAssertEqual(try XCTUnwrap(speed), 100, accuracy: 1e-9) }
    }

    // MARK: - Run-out after the last frame

    /// 31 frames over one second moving 5 mm each: the newest complete line (p = −60 mm at the end) is still
    /// 180 mm short of the end of the grid, which takes 1.2 s at the last speed of 150 mm/s.
    private func makeRunOutSource() throws -> TopoReplaySource {
        let grid = makeGrid(columns: 12, rows: 6) { _, c in Float(c) }
        let info = makeInfo(frameCount: 31, dt: 1.0 / 30, startTravel: 0, travelStep: 5)
        return try TopoReplaySource.make(grid: grid, info: info)
    }

    func testMaterialStillInViewRunsOutAtTheLastMeasuredSpeed() throws {
        let source = try makeRunOutSource()
        XCTAssertEqual(source.recordingDuration, 1.0, accuracy: 1e-9)
        XCTAssertEqual(source.runOutSpeed, 150, accuracy: 1e-6)
        XCTAssertEqual(source.duration, 2.2, accuracy: 1e-6)
        XCTAssertEqual(source.revealP.last ?? 0, -60, accuracy: 1e-9)
    }

    func testRevealPositionDuringTheRunOut() throws {
        let source = try makeRunOutSource()
        XCTAssertEqual(source.revealPosition(at: 1.0), -60, accuracy: 1e-6)
        XCTAssertEqual(source.revealPosition(at: 1.6), 30, accuracy: 1e-6)           // −60 + 0.6 s · 150 mm/s
        XCTAssertEqual(source.revealPosition(at: 2.2), 120, accuracy: 1e-6)          // the end of the grid
        XCTAssertEqual(source.revealPosition(at: 100), 120, accuracy: 1e-6)          // never beyond it
        XCTAssertEqual(source.revealTime(of: 30), 1.6, accuracy: 1e-6)
        XCTAssertEqual(source.revealTime(of: 500), 2.2, accuracy: 1e-6)              // clamped to the duration
    }

    func testRevealPositionReachesTheEndOfTheMapAtTheDuration() throws {
        let source = try makeRunOutSource()
        XCTAssertEqual(source.revealPosition(at: source.duration), source.pEnd, accuracy: 1e-9)
        XCTAssertEqual(source.revealTime(of: source.pEnd), source.duration, accuracy: 1e-6)
    }

    func testMaterialWithNothingLeftToRevealHasNoRunOut() throws {
        // The standard source's newest complete line (p = 200) is already past the end of the grid (p = 120).
        let source = try makeStandardSource()
        XCTAssertEqual(source.runOutSpeed, 0)
        XCTAssertEqual(source.duration, source.recordingDuration, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(source.revealPosition(at: source.duration), source.pEnd)
    }

    func testSlowMaterialIsSpedUpSoTheRunOutTakesAtMostSixtySeconds() throws {
        // 2 mm/s over one second: the last 328 mm would take 164 s at the measured speed (B-2).
        let grid = makeGrid(columns: 12, rows: 6) { _, c in Float(c) }
        let info = makeInfo(frameCount: 31, dt: 1.0 / 30, startTravel: 0, travelStep: 2.0 / 30)
        let source = try TopoReplaySource.make(grid: grid, info: info)
        XCTAssertEqual(TopoReplaySource.maxRunOut, 60)
        let remaining = source.pEnd - (source.revealP.last ?? 0)
        XCTAssertEqual(remaining, 328, accuracy: 1e-6)
        XCTAssertEqual(source.runOutSpeed, remaining / 60, accuracy: 1e-6)
        XCTAssertEqual(source.duration, source.recordingDuration + 60, accuracy: 1e-6)
        // Half way through the run-out half of the remaining material is revealed, and the end is reached on time.
        let last = source.revealP.last ?? 0
        XCTAssertEqual(source.revealPosition(at: source.recordingDuration + 30), last + remaining / 2, accuracy: 1e-6)
        XCTAssertEqual(source.revealPosition(at: source.duration), source.pEnd, accuracy: 1e-9)
        XCTAssertEqual(source.revealTime(of: source.pEnd), source.duration, accuracy: 1e-6)
    }

    func testRunOutNeverTakesLongerThanTheMeasuredSpeedWould() throws {
        // Fast material keeps its own speed (150 mm/s) and finishes in 1.2 s, well inside the 60 s limit.
        let source = try makeRunOutSource()
        XCTAssertEqual(source.runOutSpeed, 150, accuracy: 1e-6)
        XCTAssertLessThan(source.duration - source.recordingDuration, TopoReplaySource.maxRunOut)
    }

    func testStationaryMaterialRunsOutOverThreeSeconds() throws {
        // No travel was measured, so there is no speed to run out at: the rest of the map comes out over 3 s.
        let grid = makeGrid(columns: 12, rows: 6) { _, c in Float(c) }
        let info = makeInfo(frameCount: 31, dt: 1.0 / 30, startTravel: 0, travelStep: 0)
        let source = try TopoReplaySource.make(grid: grid, info: info)
        XCTAssertEqual(TopoReplaySource.fallbackRunOut, 3)
        let remaining = source.pEnd - (source.revealP.last ?? 0)
        XCTAssertEqual(remaining, 330, accuracy: 1e-6)
        XCTAssertEqual(source.runOutSpeed, remaining / 3, accuracy: 1e-6)
        XCTAssertEqual(source.duration, source.recordingDuration + 3, accuracy: 1e-9)
        XCTAssertEqual(source.revealPosition(at: source.duration), source.pEnd, accuracy: 1e-9)
        XCTAssertEqual(source.revealPosition(at: source.recordingDuration + 1.5),
                       (source.revealP.last ?? 0) + remaining / 2, accuracy: 1e-6)
    }

    func testBackwardsMaterialRunsOutOverThreeSeconds() throws {
        // Net travel below 1 mm/s (here: backwards) counts as "no speed" as well.
        let grid = makeGrid(columns: 12, rows: 6) { _, c in Float(c) }
        let info = makeInfo(frameCount: 31, dt: 1.0 / 30, startTravel: 0, travelStep: -1)
        let source = try TopoReplaySource.make(grid: grid, info: info)
        XCTAssertEqual(source.duration, source.recordingDuration + TopoReplaySource.fallbackRunOut, accuracy: 1e-9)
        XCTAssertEqual(source.revealPosition(at: source.duration), source.pEnd, accuracy: 1e-9)
    }
}

// MARK: - Display grid

final class TopoDisplayGridTests: XCTestCase {
    private func makeSource(columns: Int, rows: Int, frameCount: Int = 41,
                            value: (Int, Int) -> Float) throws -> TopoReplaySource {
        var values = [Float](repeating: .nan, count: columns * rows)
        for r in 0..<rows {
            for c in 0..<columns {
                values[r * columns + c] = value(r, c)
            }
        }
        let grid = TopoGridFile(columns: columns, rows: rows, cell: 10, qMin: 0, xMin: -30,
                                heightMode: true, values: values)
        let frames = (0..<frameCount).map { i in
            makeFrame(index: i, time: Double(i) / 10, speed: 100, travel: 210 + 10 * Double(i))
        }
        let info = LineRecordingInfo(depthWidth: 64, depthHeight: 48, videoWidth: 1080, videoHeight: 1920,
                                     filteredDepth: true, shortShutter: true, direction: .rightToLeft,
                                     frames: frames)
        return try TopoReplaySource.make(grid: grid, info: info)
    }

    func testBlocksAreAveragedFromFactorByFactorCells() throws {
        // value = 10 · row + column on a 4 × 8 grid.
        let source = try makeSource(columns: 8, rows: 4) { r, c in Float(10 * r + c) }
        let display = TopoDisplayGrid.make(source: source, factor: 2)
        XCTAssertEqual(display.factor, 2)
        XCTAssertEqual(display.rows, 2)
        XCTAssertEqual(display.columns, 4)
        XCTAssertEqual(display.cellMM, 20, accuracy: 1e-9)
        XCTAssertEqual(display.pStart, source.pStart, accuracy: 1e-9)
        XCTAssertEqual(display.observed[0 * 4 + 0], 5.5)       // 0, 1, 10, 11
        XCTAssertEqual(display.observed[0 * 4 + 1], 7.5)       // 2, 3, 12, 13
        XCTAssertEqual(display.observed[1 * 4 + 0], 25.5)      // 20, 21, 30, 31
        XCTAssertEqual(display.observed[1 * 4 + 3], 31.5)      // 26, 27, 36, 37
    }

    func testFactorOneKeepsEveryCell() throws {
        let source = try makeSource(columns: 8, rows: 4) { r, c in Float(10 * r + c) }
        let display = TopoDisplayGrid.make(source: source, factor: 1)
        XCTAssertEqual(display.observed, source.values)
        XCTAssertEqual(display.filled, source.values)
        XCTAssertEqual(display.cellMM, 10, accuracy: 1e-9)
    }

    func testFactorBelowOneIsTreatedAsOne() throws {
        let source = try makeSource(columns: 8, rows: 4) { r, c in Float(10 * r + c) }
        let display = TopoDisplayGrid.make(source: source, factor: 0)
        XCTAssertEqual(display.factor, 1)
        XCTAssertEqual(display.observed, source.values)
    }

    func testLeftOverCellsFormPartialLastBlocks() throws {
        // 5 rows × 7 columns, factor 2: 3 block rows (the last holds 1 row), 4 block columns (the last holds 1) (B-15).
        let source = try makeSource(columns: 7, rows: 5) { r, c in Float(10 * r + c) }
        let display = TopoDisplayGrid.make(source: source, factor: 2)
        XCTAssertEqual(display.rows, 3)
        XCTAssertEqual(display.columns, 4)
        XCTAssertEqual(display.observed[0 * 4 + 0], 5.5)       // rows 0–1, columns 0–1
        XCTAssertEqual(display.observed[1 * 4 + 0], 25.5)      // rows 2–3, columns 0–1: 20, 21, 30, 31
        XCTAssertEqual(display.observed[2 * 4 + 0], 40.5)      // row 4, columns 0–1: 40, 41
        XCTAssertEqual(display.observed[0 * 4 + 3], 11)        // rows 0–1, column 6: 6, 16
        XCTAssertEqual(display.observed[1 * 4 + 3], 31)        // rows 2–3, column 6: 26, 36
        XCTAssertEqual(display.observed[2 * 4 + 3], 46)        // row 4, column 6: 46
    }

    func testStripWidthAndRowCentresFollowTheTrueRowCount() throws {
        let source = try makeSource(columns: 7, rows: 5) { r, c in Float(10 * r + c) }
        let display = TopoDisplayGrid.make(source: source, factor: 2)
        XCTAssertEqual(display.widthMM, 50, accuracy: 1e-9)           // 5 rows of 10 mm, not 6
        XCTAssertEqual(display.rowCenterMM.count, 3)
        XCTAssertEqual(display.rowCenterMM[0], 10, accuracy: 1e-9)    // rows 0–1: centre at 10 mm
        XCTAssertEqual(display.rowCenterMM[1], 30, accuracy: 1e-9)    // rows 2–3: centre at 30 mm
        XCTAssertEqual(display.rowCenterMM[2], 45, accuracy: 1e-9)    // row 4 alone: centre at 45 mm
        // Along the travel the last block is shorter than the others: the newest material ends at pEnd.
        XCTAssertEqual(display.pEnd, source.pEnd, accuracy: 1e-9)
        XCTAssertEqual(display.pStart + 3 * display.cellMM, 60, accuracy: 1e-9)
        XCTAssertEqual(display.pEnd, 70, accuracy: 1e-9)
    }

    func testColumnMeansAverageEachBlockColumn() throws {
        let source = try makeSource(columns: 8, rows: 4) { r, c in Float(10 * r + c) }
        let display = TopoDisplayGrid.make(source: source, factor: 2)
        // Block column 0 holds 5.5 (top) and 25.5 (bottom).
        XCTAssertEqual(display.columnMean[0], 15.5)
        XCTAssertEqual(display.columnMean[3], 21.5)      // (11.5 + 31.5) / 2
    }

    func testColumnMeansUseMeasuredBlocksOnly() throws {
        // Column 4: rows 1–3 have no data and are filled across the column, but the filled values are not statistics.
        let source = try makeAcrossGapSource()
        let display = TopoDisplayGrid.make(source: source, factor: 1)
        XCTAssertEqual(display.filled[2 * 12 + 4], 4, accuracy: 1e-5)     // interpolated for the surface
        XCTAssertTrue(display.observed[2 * 12 + 4].isNaN)                 // but not observed
        // Measured rows 0 and 4…9: 0, 8, 10, 12, 14, 16, 18.
        XCTAssertEqual(display.columnMean[4], 78.0 / 7.0, accuracy: 1e-4)
    }

    func testSmoothedWindowAveragesTheThreeByThreeNeighbourhood() throws {
        let source = try makeSource(columns: 8, rows: 4) { r, c in Float(10 * r + c) }
        let display = TopoDisplayGrid.make(source: source, factor: 2)
        // 2 × 4 blocks: top row 5.5, 7.5, 9.5, 11.5, bottom row 25.5, 27.5, 29.5, 31.5.
        let smooth = display.window(jLo: 0, jHi: 3, smooth: true)
        XCTAssertEqual(smooth.count, 2 * 4)
        XCTAssertEqual(smooth[0], (5.5 + 7.5 + 25.5 + 27.5) / 4, accuracy: 1e-5)
        XCTAssertEqual(smooth[1], (5.5 + 7.5 + 9.5 + 25.5 + 27.5 + 29.5) / 6, accuracy: 1e-5)
        // Without smoothing the window is the block means themselves.
        let plain = display.window(jLo: 0, jHi: 3, smooth: false)
        XCTAssertEqual(plain, display.observed)
    }

    func testSmoothingNeverReadsColumnsNewerThanTheWindow() throws {
        let source = try makeSource(columns: 8, rows: 4) { r, c in Float(10 * r + c) }
        let display = TopoDisplayGrid.make(source: source, factor: 2)
        // Newest column of the window is block column 1: its average uses block columns 0 and 1 only.
        let limited = display.window(jLo: 0, jHi: 1, smooth: true)
        XCTAssertEqual(limited.count, 2 * 2)
        XCTAssertEqual(limited[1], (5.5 + 7.5 + 25.5 + 27.5) / 4, accuracy: 1e-5)
        // With block column 2 available the same cell averages six blocks instead.
        let wider = display.window(jLo: 0, jHi: 2, smooth: true)
        XCTAssertEqual(wider[1], (5.5 + 7.5 + 9.5 + 25.5 + 27.5 + 29.5) / 6, accuracy: 1e-5)
    }

    func testWindowRejectsAnInvalidRange() throws {
        let source = try makeSource(columns: 8, rows: 4) { r, c in Float(10 * r + c) }
        let display = TopoDisplayGrid.make(source: source, factor: 2)
        XCTAssertTrue(display.window(jLo: -1, jHi: 2, smooth: false).isEmpty)
        XCTAssertTrue(display.window(jLo: 0, jHi: 4, smooth: false).isEmpty)
        XCTAssertTrue(display.window(jLo: 3, jHi: 2, smooth: false).isEmpty)
    }

    func testRevealTimeOfEachColumnIsWhenItsLastLineIsComplete() throws {
        // Newest complete line at p = 10 · t / 0.1 = 100 · t, so a column ending at p is complete at p / 100 s.
        let source = try makeSource(columns: 12, rows: 6) { _, c in Float(c) }
        let display = TopoDisplayGrid.make(source: source, factor: 1)
        for j in 0..<12 {
            XCTAssertEqual(display.revealTime[j], (Double(j) + 1) / 10, accuracy: 1e-9, "column \(j)")
            XCTAssertEqual(display.p(ofColumn: j), (Double(j) + 0.5) * 10, accuracy: 1e-9)
        }
        let coarse = TopoDisplayGrid.make(source: source, factor: 2)
        XCTAssertEqual(coarse.revealTime.count, 6)
        for j in 0..<6 {
            XCTAssertEqual(coarse.revealTime[j], (Double(j) + 1) * 2 / 10, accuracy: 1e-9, "block column \(j)")
        }
    }

    func testRevealTimeOfAPartialLastBlockIsWhenTheEndOfTheMapIsComplete() throws {
        // 7 columns, factor 2: the last block holds one column and ends at pEnd = 70, complete at 0.7 s.
        let source = try makeSource(columns: 7, rows: 5) { r, c in Float(10 * r + c) }
        let display = TopoDisplayGrid.make(source: source, factor: 2)
        XCTAssertEqual(display.revealTime[3], 0.7, accuracy: 1e-9)
        XCTAssertEqual(display.revealTime[2], 0.6, accuracy: 1e-9)
    }

    func testNewestCompleteColumnIsTheNewestBlockWhoseWholeLengthHasLeftTheView() throws {
        // 12 columns of 10 mm, blocks of 20 mm: 6 block columns covering p = 0…120.
        let source = try makeSource(columns: 12, rows: 6) { _, c in Float(c) }
        let display = TopoDisplayGrid.make(source: source, factor: 2)
        XCTAssertLessThanOrEqual(display.newestCompleteColumn(newest: -50), -1)     // before the map: none yet
        XCTAssertLessThanOrEqual(display.newestCompleteColumn(newest: 0), -1)
        XCTAssertLessThanOrEqual(display.newestCompleteColumn(newest: 19.9), -1)
        XCTAssertEqual(display.newestCompleteColumn(newest: 20), 0)       // block 0 (p 0…20) is complete
        XCTAssertEqual(display.newestCompleteColumn(newest: 59.9), 1)     // block 2 (p 40…60) is not yet
        XCTAssertEqual(display.newestCompleteColumn(newest: 60), 2)
        XCTAssertEqual(display.newestCompleteColumn(newest: 119.9), 4)
        XCTAssertEqual(display.newestCompleteColumn(newest: 120), 5)      // the end of the map: all blocks
        XCTAssertEqual(display.newestCompleteColumn(newest: 5000), 5)
    }

    func testNewestCompleteColumnCountsAPartialLastBlockOnlyAtTheEndOfTheMap() throws {
        let source = try makeSource(columns: 7, rows: 5) { r, c in Float(10 * r + c) }
        let display = TopoDisplayGrid.make(source: source, factor: 2)       // blocks end at 20, 40, 60, 70
        XCTAssertEqual(display.newestCompleteColumn(newest: 65), 2)
        XCTAssertEqual(display.newestCompleteColumn(newest: 69.9), 2)
        XCTAssertEqual(display.newestCompleteColumn(newest: 70), 3)
    }

    /// 12 columns × 10 rows of 100 mm with gaps down some columns (cell values are the row index × 2 unless noted):
    /// column 2 has no data in rows 0–1 (an edge), column 4 in rows 1–3 (a gap of 3), column 6 in rows 1–4 (a gap of 4),
    /// column 8 in rows 7–9 (the far edge).
    private func makeAcrossGapSource() throws -> TopoReplaySource {
        try makeSource(columns: 12, rows: 10) { r, c in
            switch c {
            case 2: return r < 2 ? .nan : 3
            case 4: return (1...3).contains(r) ? .nan : Float(2 * r)
            case 6: return (1...4).contains(r) ? .nan : Float(2 * r)
            case 8: return r >= 7 ? .nan : 1
            default: return 100
            }
        }
    }

    func testAcrossGapsOfUpToThreeBlocksAreInterpolatedBetweenMeasuredBlocks() throws {
        XCTAssertEqual(TopoDisplayGrid.maxAcrossGap, 3)
        let display = TopoDisplayGrid.make(source: try makeAcrossGapSource(), factor: 1)
        XCTAssertEqual(display.rows, 10)
        // Column 4: 0 mm at row 0 and 8 mm at row 4, three empty rows between: 2, 4, 6.
        XCTAssertEqual(display.filled[0 * 12 + 4], 0)
        XCTAssertEqual(display.filled[1 * 12 + 4], 2, accuracy: 1e-5)
        XCTAssertEqual(display.filled[2 * 12 + 4], 4, accuracy: 1e-5)
        XCTAssertEqual(display.filled[3 * 12 + 4], 6, accuracy: 1e-5)
        XCTAssertEqual(display.filled[4 * 12 + 4], 8)
        // The measured values are left alone.
        XCTAssertEqual(display.observed[0 * 12 + 4], 0)
        XCTAssertEqual(display.observed[4 * 12 + 4], 8)
    }

    func testAcrossGapsLongerThanThreeBlocksStayEmpty() throws {
        let display = TopoDisplayGrid.make(source: try makeAcrossGapSource(), factor: 1)
        // Column 6: four empty rows between 0 mm (row 0) and 10 mm (row 5).
        for r in 1...4 {
            XCTAssertTrue(display.filled[r * 12 + 6].isNaN, "row \(r)")
        }
        XCTAssertEqual(display.filled[0 * 12 + 6], 0)
        XCTAssertEqual(display.filled[5 * 12 + 6], 10)
    }

    func testAcrossGapsAtTheEdgesAreNotExtended() throws {
        let display = TopoDisplayGrid.make(source: try makeAcrossGapSource(), factor: 1)
        // Column 2: nothing measured in rows 0–1; the first measured block (row 2) is not copied outwards.
        XCTAssertTrue(display.filled[0 * 12 + 2].isNaN)
        XCTAssertTrue(display.filled[1 * 12 + 2].isNaN)
        XCTAssertEqual(display.filled[2 * 12 + 2], 3)
        // Column 8: nothing measured in rows 7–9; the last measured block (row 6) is not copied outwards.
        XCTAssertEqual(display.filled[6 * 12 + 8], 1)
        for r in 7...9 {
            XCTAssertTrue(display.filled[r * 12 + 8].isNaN, "row \(r)")
        }
    }

    func testGapsAlongTheTravelAreFilledUpToEightBlocksOnly() throws {
        XCTAssertEqual(TopoDisplayGrid.maxAlongGap, 8)
        // 30 columns: data in 0–4 (10), 13–17 (20) and 27–29 (30); columns 5–12 (8 blocks) and 18–26 (9 blocks) are empty.
        let source = try makeSource(columns: 30, rows: 4, frameCount: 61) { _, c in
            switch c {
            case 0...4: return 10
            case 13...17: return 20
            case 27...29: return 30
            default: return .nan
            }
        }
        let display = TopoDisplayGrid.make(source: source, factor: 1)
        let surface = display.window(jLo: 0, jHi: 29, smooth: false)
        XCTAssertEqual(surface.count, 4 * 30)
        // The 8-block gap is filled linearly between column 4 (10) and column 13 (20).
        for c in 5...12 {
            let expected = 10 + 10 * Float(c - 4) / 9
            XCTAssertEqual(surface[c], expected, accuracy: 1e-4, "column \(c)")
            XCTAssertEqual(surface[3 * 30 + c], expected, accuracy: 1e-4, "column \(c), last row")
        }
        // The 9-block gap stays empty.
        for c in 18...26 {
            XCTAssertTrue(surface[c].isNaN, "column \(c)")
        }
        // The measured columns are unchanged and the statistics never see the filled blocks.
        XCTAssertEqual(surface[0], 10)
        XCTAssertEqual(surface[13], 20)
        XCTAssertEqual(display.columnMean[0], 10)
        for c in 5...12 {
            XCTAssertTrue(display.observed[c].isNaN, "column \(c)")
            XCTAssertTrue(display.columnMean[c].isNaN, "column \(c)")
        }
        for c in 18...26 {
            XCTAssertTrue(display.columnMean[c].isNaN, "column \(c)")
        }
    }

    func testNoGapIsFilledFromMaterialNewerThanTheWindow() throws {
        let source = try makeSource(columns: 30, rows: 4, frameCount: 61) { _, c in
            switch c {
            case 0...4: return 10
            case 13...17: return 20
            default: return .nan
            }
        }
        let display = TopoDisplayGrid.make(source: source, factor: 1)
        // Column 13, the far side of the gap, is not part of a window ending at column 8: nothing is invented.
        let early = display.window(jLo: 0, jHi: 8, smooth: false)
        for c in 5...8 {
            XCTAssertTrue(early[c].isNaN, "column \(c)")
        }
        // Once column 13 is complete the gap is filled.
        let later = display.window(jLo: 0, jHi: 13, smooth: false)
        XCTAssertEqual(later[8], 10 + 10 * 4 / 9, accuracy: 1e-4)
        XCTAssertEqual(later[13], 20)
    }

    func testWindowOfLaterColumnsMatchesTheSameColumnsOfTheFullWindow() throws {
        let source = try makeSource(columns: 30, rows: 4, frameCount: 61) { _, c in
            switch c {
            case 0...4: return 10
            case 13...17: return 20
            case 27...29: return 30
            default: return .nan
            }
        }
        let display = TopoDisplayGrid.make(source: source, factor: 1)
        for smooth in [false, true] {
            let full = display.window(jLo: 0, jHi: 29, smooth: smooth)
            let part = display.window(jLo: 10, jHi: 29, smooth: smooth)
            XCTAssertEqual(part.count, 4 * 20)
            for r in 0..<4 {
                for c in 0..<20 {
                    let a = full[r * 30 + 10 + c]
                    let b = part[r * 20 + c]
                    XCTAssertTrue((a.isNaN && b.isNaN) || abs(a - b) < 1e-4, "row \(r), column \(10 + c): \(a) vs \(b)")
                }
            }
        }
    }
}

// MARK: - Numbers and palette

final class ReplayNumbersTests: XCTestCase {
    func testNiceRoundsToOneTwoTwoPointFiveFiveOrTen() {
        let cases: [(Double, Double)] = [
            (1, 1), (1.4, 1), (1.5, 2), (2.2, 2), (2.25, 2.5), (3.4, 2.5), (3.5, 5), (7.4, 5), (7.5, 10),
            (14, 10), (23, 25), (19, 20), (1234, 1000), (0.7, 0.5), (0.012, 0.01), (950, 1000)
        ]
        for (input, expected) in cases {
            XCTAssertEqual(ReplayNumbers.nice(input), expected, accuracy: expected * 1e-9, "nice(\(input))")
        }
    }

    func testNiceFallsBackToOneForInvalidInput() {
        XCTAssertEqual(ReplayNumbers.nice(0), 1)
        XCTAssertEqual(ReplayNumbers.nice(-3), 1)
        XCTAssertEqual(ReplayNumbers.nice(.nan), 1)
        XCTAssertEqual(ReplayNumbers.nice(.infinity), 1)
    }

    func testTicksAreRoundValuesCoveringTheRange() {
        XCTAssertEqual(ReplayNumbers.ticks(0, 10, count: 5), [0, 2, 4, 6, 8, 10])
        XCTAssertEqual(ReplayNumbers.ticks(3, 97, count: 4), [25, 50, 75])
        let symmetric = ReplayNumbers.ticks(-1, 1, count: 4)
        XCTAssertEqual(symmetric.count, 5)
        for (tick, expected) in zip(symmetric, [-1.0, -0.5, 0, 0.5, 1]) {
            XCTAssertEqual(tick, expected, accuracy: 1e-12)
        }
        XCTAssertEqual(symmetric[2], 0)      // zero is exactly zero, not a tiny residue
    }

    func testTicksOfADegenerateRangeIsJustTheLowerEnd() {
        XCTAssertEqual(ReplayNumbers.ticks(5, 5, count: 4), [5])
        XCTAssertEqual(ReplayNumbers.ticks(5, 1, count: 4), [5])
        XCTAssertEqual(ReplayNumbers.ticks(0, 10, count: 0), [0])
    }

    func testDecimalsShowTheStepCleanly() {
        XCTAssertEqual(ReplayNumbers.decimals(for: 100), 0)
        XCTAssertEqual(ReplayNumbers.decimals(for: 1), 0)
        XCTAssertEqual(ReplayNumbers.decimals(for: 0.5), 1)
        XCTAssertEqual(ReplayNumbers.decimals(for: 2.5), 1)
        XCTAssertEqual(ReplayNumbers.decimals(for: 0.1), 1)
        XCTAssertEqual(ReplayNumbers.decimals(for: 0.25), 2)
        XCTAssertEqual(ReplayNumbers.decimals(for: 0.01), 2)
        XCTAssertEqual(ReplayNumbers.decimals(for: 0.125), 3)
        XCTAssertEqual(ReplayNumbers.decimals(for: 0.00001), 4)      // capped at four
        XCTAssertEqual(ReplayNumbers.decimals(for: 0), 1)
        XCTAssertEqual(ReplayNumbers.decimals(for: .infinity), 1)
    }

    func testTextUsesTheGivenDecimals() {
        XCTAssertEqual(ReplayNumbers.text(3.14159, decimals: 2), "3.14")
        XCTAssertEqual(ReplayNumbers.text(12, decimals: 1), "12.0")
    }
}

final class ReplayPaletteTests: XCTestCase {
    private func assertColor(_ actual: SIMD3<Float>, _ r: Float, _ g: Float, _ b: Float,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, r / 255, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(actual.y, g / 255, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(actual.z, b / 255, accuracy: 1e-5, file: file, line: line)
    }

    func testEndpointsAndOnTargetColours() {
        assertColor(ReplayPalette.rgb(0), 30, 66, 207)           // blue = far below target
        assertColor(ReplayPalette.rgb(0.5), 79, 212, 43)         // green = on target
        assertColor(ReplayPalette.rgb(1), 230, 51, 28)           // red = far above target
    }

    func testValuesOutsideZeroToOneAreClamped() {
        XCTAssertEqual(ReplayPalette.rgb(-5), ReplayPalette.rgb(0))
        XCTAssertEqual(ReplayPalette.rgb(7), ReplayPalette.rgb(1))
    }

    func testColoursInterpolateLinearlyBetweenStops() {
        // Half way between the first two stops (0 and 0.167).
        assertColor(ReplayPalette.rgb(0.0835), 34, 93.5, 180.5)
    }

    func testStopsAreOrderedAndSpanTheScale() {
        let positions = ReplayPalette.stops.map(\.position)
        XCTAssertEqual(positions.first, 0)
        XCTAssertEqual(positions.last, 1)
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertEqual(Set(positions).count, positions.count)
    }

    func testLookUpTableCoversTheScale() {
        XCTAssertEqual(ReplayPalette.lut.count, 256)
        let first = ReplayPalette.lut[0]
        let last = ReplayPalette.lut[255]
        XCTAssertEqual(first.x, 30 / 255, accuracy: 1e-5)
        XCTAssertEqual(last.x, 230 / 255, accuracy: 1e-5)
        XCTAssertEqual(first.w, 1)
        XCTAssertEqual(last.w, 1)
        XCTAssertEqual(ReplayPalette.gradient.count, 25)
    }
}
