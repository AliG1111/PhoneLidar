import XCTest

final class BaselineTests: XCTestCase {
    private let width = 20
    private let height = 10

    /// Distance (mm) of a tilted flat surface at depth pixel (u, v): it drops 0.5 mm per pixel across
    /// and 0.25 mm per pixel down, like a phone that is not exactly level.
    private func surface(_ u: Int, _ v: Int) -> Float {
        1000 + 0.5 * Float(u) + 0.25 * Float(v)
    }

    private func surfaceFrame(offset: Float = 0) -> [Float] {
        var frame = [Float](repeating: 0, count: width * height)
        for v in 0..<height {
            for u in 0..<width {
                frame[v * width + u] = surface(u, v) + offset
            }
        }
        return frame
    }

    /// 30 frames of the tilted surface. In the 20 frames used to build the baseline, frame 0 is a low
    /// outlier (-400 mm), frame 1 a high outlier (+400 mm) and frames 2 and 3 have no data at all.
    private func calibrationFrames() -> [[Float]] {
        var frames: [[Float]] = []
        for index in 0..<30 {
            switch index {
            case 0: frames.append(surfaceFrame(offset: -400))
            case 1: frames.append(surfaceFrame(offset: 400))
            case 2, 3: frames.append([Float](repeating: 0, count: width * height))
            default: frames.append(surfaceFrame())
            }
        }
        return frames
    }

    private func build(_ frames: [[Float]], verify: Int = 10) throws -> Baseline {
        try Baseline.build(frames: frames, width: width, height: height, verify: verify,
                           tiltX: 0.4, tiltY: -0.2, filtered: true)
    }

    /// The calibration frames with the first `missing` pixels (row-major) never returning data.
    private func calibrationFrames(withoutFirstPixels missing: Int) -> [[Float]] {
        var frames = calibrationFrames()
        for index in frames.indices {
            for pixel in 0..<missing { frames[index][pixel] = 0 }
        }
        return frames
    }

    /// Fails the test unless `error` is `BaselineError.notEnoughFrames`; returns nothing else.
    private func assertNotEnoughFrames(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case BaselineError.notEnoughFrames = error else {
            XCTFail("Expected notEnoughFrames, got \(error)", file: file, line: line)
            return
        }
    }

    /// Fails the test unless `error` is `BaselineError.lowCoverage`; returns its percentage.
    private func lowCoveragePercent(_ error: Error, file: StaticString = #filePath, line: UInt = #line) -> Double? {
        guard case BaselineError.lowCoverage(let percent) = error else {
            XCTFail("Expected lowCoverage, got \(error)", file: file, line: line)
            return nil
        }
        return percent
    }

    // MARK: - Building

    func testTrimmedMeanIgnoresOutliersAndMissingReadings() throws {
        let baseline = try build(calibrationFrames())
        XCTAssertEqual(baseline.values.count, width * height)
        for v in 0..<height {
            for u in 0..<width {
                XCTAssertEqual(baseline.values[v * width + u], surface(u, v), accuracy: 0.001, "pixel (\(u), \(v))")
            }
        }
    }

    func testInfoDescribesTheCalibration() throws {
        let baseline = try build(calibrationFrames())
        let info = baseline.info
        XCTAssertEqual(info.width, width)
        XCTAssertEqual(info.height, height)
        XCTAssertEqual(info.frames, 30)
        XCTAssertEqual(info.coveragePercent, 100, accuracy: 1e-9)
        XCTAssertEqual(info.tiltX, 0.4)
        XCTAssertEqual(info.tiltY, -0.2)
        XCTAssertTrue(info.filteredDepth)

        var distances: [Double] = []
        for v in 0..<height { for u in 0..<width { distances.append(Double(surface(u, v))) } }
        let mean = distances.reduce(0, +) / Double(distances.count)
        let std = (distances.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(distances.count)).squareRoot()
        XCTAssertEqual(info.meanDistance, mean, accuracy: 0.001)
        XCTAssertEqual(info.rawStdDev, std, accuracy: 0.001)
        // P1–P99 range of the 200 values, taken at the nearest-lower rank.
        let sorted = distances.sorted()
        XCTAssertEqual(info.rawRange, sorted[197] - sorted[1], accuracy: 0.001)
        XCTAssertGreaterThan(info.rawRange, 0)
    }

    func testCorrectedFlatSurfaceHasNoSpread() throws {
        let baseline = try build(calibrationFrames())
        XCTAssertEqual(baseline.info.correctedStdDev, 0, accuracy: 0.001)
        XCTAssertGreaterThan(baseline.info.rawStdDev, 1)   // the tilt was removed by the correction
    }

    func testSummaryLine() throws {
        let baseline = try build(calibrationFrames())
        XCTAssertTrue(baseline.summary.hasPrefix("Baseline 1006 mm away · flat surface spread "), baseline.summary)
        XCTAssertTrue(baseline.summary.hasSuffix("0.00 mm σ after correction"), baseline.summary)
    }

    func testPixelsWithTooFewReadingsAreFilledFromAFittedPlane() throws {
        var frames = calibrationFrames()
        for index in frames.indices { frames[index][0] = 0 }     // pixel (0, 0) never has data
        let baseline = try build(frames)
        XCTAssertEqual(baseline.values[0], surface(0, 0), accuracy: 0.05)
        XCTAssertEqual(baseline.values[1], surface(1, 0), accuracy: 0.001)
        XCTAssertEqual(baseline.info.coveragePercent, 99.5, accuracy: 1e-9)
    }

    func testBuildNeedsAtLeastTenUsableFrames() throws {
        XCTAssertThrowsError(try build(Array(calibrationFrames().prefix(9)))) { assertNotEnoughFrames($0) }
        XCTAssertNoThrow(try build(Array(calibrationFrames().prefix(10))))
    }

    func testBuildIgnoresFramesOfTheWrongSize() {
        var frames = Array(calibrationFrames().prefix(9))
        frames.append([1, 2, 3])
        frames.append([Float](repeating: 1000, count: width * height + 1))
        // only 9 usable frames remain
        XCTAssertThrowsError(try build(frames)) { assertNotEnoughFrames($0) }
    }

    func testBuildRefusesWhenNoPixelHasData() {
        XCTAssertThrowsError(try build([[Float]](repeating: [Float](repeating: 0, count: width * height), count: 30))) {
            XCTAssertEqual(lowCoveragePercent($0) ?? -1, 0, accuracy: 1e-9)
        }
    }

    func testBuildRefusesWhenTooFewPixelsHaveData() {
        // Only 5 of the 200 pixels (2.5 %) ever have data: far below the 50 % minimum.
        var sparse = [Float](repeating: 0, count: width * height)
        for i in 0..<5 { sparse[i] = 1000 }
        XCTAssertThrowsError(try build([[Float]](repeating: sparse, count: 30))) {
            XCTAssertEqual(lowCoveragePercent($0) ?? -1, 2.5, accuracy: 1e-9)
        }
    }

    // MARK: - Coverage thresholds (A-8)

    func testCoverageThresholdConstants() {
        XCTAssertEqual(Baseline.minimumCoveragePercent, 50)
        XCTAssertEqual(Baseline.goodCoveragePercent, 80)
    }

    func testCalibrationBelowHalfCoverageIsRefused() {
        // 101 of 200 pixels without data: 49.5 % coverage.
        XCTAssertThrowsError(try build(calibrationFrames(withoutFirstPixels: 101))) {
            XCTAssertEqual(lowCoveragePercent($0) ?? -1, 49.5, accuracy: 1e-9)
        }
    }

    func testCalibrationAtExactlyHalfCoverageIsAccepted() throws {
        // The first five rows (100 of 200 pixels) never return data: exactly 50 %.
        let baseline = try build(calibrationFrames(withoutFirstPixels: 100))
        XCTAssertEqual(baseline.info.coveragePercent, 50, accuracy: 1e-9)
        // The rest comes from the fitted plane, which is exact for this tilted flat surface.
        XCTAssertEqual(baseline.values.count, width * height)
        for v in 0..<height {
            for u in 0..<width {
                XCTAssertEqual(baseline.values[v * width + u], surface(u, v), accuracy: 0.05, "pixel (\(u), \(v))")
            }
        }
    }

    func testCoverageBelowEightyPercentIsReportedAsPoor() throws {
        // 42 of 200 pixels without data: 79 % coverage, accepted but below the "good" mark.
        let poor = try build(calibrationFrames(withoutFirstPixels: 42))
        XCTAssertEqual(poor.info.coveragePercent, 79, accuracy: 1e-9)
        XCTAssertLessThan(poor.info.coveragePercent, Baseline.goodCoveragePercent)
        // 40 of 200 pixels without data: exactly 80 %, no warning needed.
        let good = try build(calibrationFrames(withoutFirstPixels: 40))
        XCTAssertEqual(good.info.coveragePercent, 80, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(good.info.coveragePercent, Baseline.goodCoveragePercent)
    }

    func testFullCoverageIsOneHundredPercent() throws {
        XCTAssertEqual(try build(calibrationFrames()).info.coveragePercent, 100, accuracy: 1e-9)
    }

    func testErrorMessagesNameTheCauseAndTheMinimum() {
        let low = BaselineError.lowCoverage(percent: 30).errorDescription ?? ""
        XCTAssertTrue(low.contains("30 %"), low)
        XCTAssertTrue(low.contains("at least 50 %"), low)
        XCTAssertTrue((BaselineError.notEnoughFrames.errorDescription ?? "").contains("not enough LiDAR readings"))
        XCTAssertEqual(BaselineError.cancelled("the phone moved").errorDescription,
                       "Calibration cancelled: the phone moved. Tap Calibrate again when the phone is steady.")
    }

    // MARK: - Heights above the surface

    func testHeightsAreBaselineMinusDistance() throws {
        let baseline = try build(calibrationFrames())
        // A flat surface reads zero height everywhere, whatever the tilt.
        for h in baseline.heights(surfaceFrame()) { XCTAssertEqual(h, 0, accuracy: 0.001) }
        // 5 mm closer to the camera = 5 mm high; 3 mm farther = 3 mm low.
        for h in baseline.heights(surfaceFrame(offset: -5)) { XCTAssertEqual(h, 5, accuracy: 0.001) }
        for h in baseline.heights(surfaceFrame(offset: 3)) { XCTAssertEqual(h, -3, accuracy: 0.001) }
    }

    func testHeightsOfPixelsWithoutDepthAreNaN() throws {
        let baseline = try build(calibrationFrames())
        var frame = surfaceFrame(offset: -2)
        frame[7] = 0
        frame[50] = -1
        let heights = baseline.heights(frame)
        XCTAssertTrue(heights[7].isNaN)
        XCTAssertTrue(heights[50].isNaN)
        XCTAssertEqual(heights[8], 2, accuracy: 0.001)
    }

    func testHeightsKeepTheFrameLengthAndLeaveExtraPixelsNaN() throws {
        let baseline = try build(calibrationFrames())
        let longer = surfaceFrame() + [1000, 1000]
        let heights = baseline.heights(longer)
        XCTAssertEqual(heights.count, width * height + 2)
        XCTAssertTrue(heights[width * height].isNaN)
        XCTAssertTrue(heights[width * height + 1].isNaN)
        XCTAssertEqual(baseline.heights([1000, 1000]).count, 2)
    }

    func testHeightsOfPixelsWithoutABaselineAreNaN() {
        let values: [Float] = [1000, 0, 1000]
        let baseline = Baseline(info: makeInfo(width: 3, height: 1), values: values)
        let heights = baseline.heights([990, 990, 0])
        XCTAssertEqual(heights[0], 10, accuracy: 0.001)
        XCTAssertTrue(heights[1].isNaN)
        XCTAssertTrue(heights[2].isNaN)
    }

    func testMatchesChecksTheDepthMapSize() throws {
        let baseline = try build(calibrationFrames())
        XCTAssertTrue(baseline.matches(width: width, height: height))
        XCTAssertFalse(baseline.matches(width: height, height: width))
        XCTAssertFalse(baseline.matches(width: width, height: height + 1))
    }

    func testSampleIsTheMedianOfTheBaselineWindow() throws {
        let values: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
        let baseline = Baseline(info: makeInfo(width: 3, height: 3), values: values)
        XCTAssertEqual(baseline.sample(u: 1, v: 1, radius: 1), 5)
        XCTAssertEqual(baseline.sample(u: 0, v: 0, radius: 0), 1)
        XCTAssertNil(baseline.sample(u: 3, v: 0, radius: 1))
    }

    // MARK: - Files

    func testSaveAndLoadRoundTrip() throws {
        let baseline = try build(calibrationFrames())
        let folder = try makeTempFolder().appendingPathComponent("Calibration", isDirectory: true)
        try baseline.save(to: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(Baseline.fileName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(Baseline.infoName).path))
        // Baseline.bin is width × height Float32 values.
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(Baseline.fileName)).count, width * height * 4)

        let loaded = try XCTUnwrap(Baseline.load(from: folder))
        XCTAssertEqual(loaded.values, baseline.values)
        XCTAssertEqual(loaded.info.width, width)
        XCTAssertEqual(loaded.info.height, height)
        XCTAssertEqual(loaded.info.frames, 30)
        XCTAssertEqual(loaded.info.meanDistance, baseline.info.meanDistance, accuracy: 1e-9)
        XCTAssertEqual(loaded.info.tiltX, 0.4)
        XCTAssertEqual(loaded.info.tiltY, -0.2)
        XCTAssertEqual(loaded.info.filteredDepth, true)
        XCTAssertEqual(loaded.info.created.timeIntervalSince1970, baseline.info.created.timeIntervalSince1970, accuracy: 1)
    }

    func testLoadRejectsMissingOrInconsistentFiles() throws {
        let baseline = try build(calibrationFrames())
        let folder = try makeTempFolder()
        XCTAssertNil(Baseline.load(from: folder))
        try baseline.save(to: folder)
        XCTAssertNotNil(Baseline.load(from: folder))

        // Truncated Baseline.bin
        let binURL = folder.appendingPathComponent(Baseline.fileName)
        let data = try Data(contentsOf: binURL)
        try data.dropLast(4).write(to: binURL)
        XCTAssertNil(Baseline.load(from: folder))
        try data.write(to: binURL)
        XCTAssertNotNil(Baseline.load(from: folder))

        // Missing or unreadable Baseline.json
        let jsonURL = folder.appendingPathComponent(Baseline.infoName)
        try Data("not json".utf8).write(to: jsonURL)
        XCTAssertNil(Baseline.load(from: folder))
        try FileManager.default.removeItem(at: jsonURL)
        XCTAssertNil(Baseline.load(from: folder))
    }

    func testLoadRejectsHandEditedSizesWithoutCrashing() throws {
        // Z-4: width × height × 4 used to be computed unchecked from Baseline.json.
        let baseline = try build(calibrationFrames())
        let folder = try makeTempFolder()
        try baseline.save(to: folder)
        let jsonURL = folder.appendingPathComponent(Baseline.infoName)
        let original = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any]
        for (w, h) in [(Int.max, 2), (Int.max / 2, Int.max / 2), (-width, -height), (0, height), (9000, 1),
                       (DepthFileReader.maxDimension + 1, height)] {
            var edited = try XCTUnwrap(original)
            edited["width"] = w
            edited["height"] = h
            try JSONSerialization.data(withJSONObject: edited).write(to: jsonURL)
            XCTAssertNil(Baseline.load(from: folder), "\(w) × \(h)")
        }
        // The real size still loads.
        try JSONSerialization.data(withJSONObject: try XCTUnwrap(original)).write(to: jsonURL)
        XCTAssertNotNil(Baseline.load(from: folder))
    }

    func testExpectedByteCount() {
        XCTAssertEqual(Baseline.expectedByteCount(width: 256, height: 192), 256 * 192 * 4)
        XCTAssertEqual(Baseline.expectedByteCount(width: DepthFileReader.maxDimension, height: DepthFileReader.maxDimension),
                       DepthFileReader.maxDimension * DepthFileReader.maxDimension * 4)
        XCTAssertNil(Baseline.expectedByteCount(width: DepthFileReader.maxDimension + 1, height: 1))
        XCTAssertNil(Baseline.expectedByteCount(width: 1, height: 0))
        XCTAssertNil(Baseline.expectedByteCount(width: -1, height: -1))
        XCTAssertNil(Baseline.expectedByteCount(width: Int.max, height: Int.max))
    }

    func testDeleteRemovesBothFiles() throws {
        let baseline = try build(calibrationFrames())
        let folder = try makeTempFolder()
        try baseline.save(to: folder)
        Baseline.delete(from: folder)
        XCTAssertNil(Baseline.load(from: folder))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(Baseline.fileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(Baseline.infoName).path))
        Baseline.delete(from: folder)     // deleting again is harmless
    }

    // MARK: - Linear solve

    func testSolve3SolvesAWellConditionedSystem() throws {
        // [[2,1,0],[1,3,1],[0,1,4]] · (1, 2, 3) = (4, 10, 14)
        let solution = try XCTUnwrap(Baseline.solve3([[2, 1, 0], [1, 3, 1], [0, 1, 4]], [4, 10, 14]))
        XCTAssertEqual(solution.a, 1, accuracy: 1e-9)
        XCTAssertEqual(solution.b, 2, accuracy: 1e-9)
        XCTAssertEqual(solution.c, 3, accuracy: 1e-9)
    }

    func testSolve3OfTheIdentityReturnsTheRightHandSide() throws {
        let solution = try XCTUnwrap(Baseline.solve3([[1, 0, 0], [0, 1, 0], [0, 0, 1]], [2, -1, 5]))
        XCTAssertEqual(solution.a, 2, accuracy: 1e-12)
        XCTAssertEqual(solution.b, -1, accuracy: 1e-12)
        XCTAssertEqual(solution.c, 5, accuracy: 1e-12)
    }

    func testSolve3RejectsASingularSystem() {
        XCTAssertNil(Baseline.solve3([[1, 2, 3], [2, 4, 6], [1, 0, 1]], [1, 2, 3]))
    }

    private func makeInfo(width: Int, height: Int) -> BaselineInfo {
        BaselineInfo(width: width, height: height, created: Date(), frames: 10, meanDistance: 1000,
                     rawStdDev: 0, rawRange: 0, correctedStdDev: 0, coveragePercent: 100,
                     tiltX: nil, tiltY: nil, filteredDepth: false)
    }
}
