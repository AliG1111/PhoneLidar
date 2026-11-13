import XCTest

/// Sheet-of-light triangulation maths, baseline and shim calibration, search band and travel (design §14.4–§14.5,
/// FR-LAS-04…06).
final class LaserGeometryTests: XCTestCase {
    private let H = 1000.0

    // MARK: - Height and shift

    func testHeightAndShiftAreInverse() throws {
        for scale in [200.0, -200.0, 35.5, -1500.0] {
            for h in [-100.0, -1.0, 0.0, 0.5, 10.0, 250.0, 700.0] {
                let d = LaserGeometry.shift(height: h, cameraHeight: H, scale: scale)
                let back = try XCTUnwrap(LaserGeometry.height(shift: d, cameraHeight: H, scale: scale),
                                         "A = \(scale), h = \(h)")
                XCTAssertEqual(back, h, accuracy: 1e-9, "A = \(scale), h = \(h)")
            }
        }
    }

    func testShiftOfAKnownHeight() {
        // d = A·h / (H − h) = 200 · 20 / 980
        XCTAssertEqual(LaserGeometry.shift(height: 20, cameraHeight: H, scale: 200), 4000.0 / 980, accuracy: 1e-12)
        XCTAssertEqual(LaserGeometry.shift(height: 0, cameraHeight: H, scale: 200), 0)
    }

    func testShiftOfASurfaceAtTheLensIsInfinite() {
        XCTAssertEqual(LaserGeometry.shift(height: 999, cameraHeight: H, scale: 200), .infinity)
        XCTAssertEqual(LaserGeometry.shift(height: 1500, cameraHeight: H, scale: 200), .infinity)
        XCTAssertTrue(LaserGeometry.shift(height: 998, cameraHeight: H, scale: 200).isFinite)
    }

    func testHeightRejectsADegenerateDenominator() {
        // |A + d| = 0.5 px
        XCTAssertNil(LaserGeometry.height(shift: -199.5, cameraHeight: H, scale: 200))
        XCTAssertNil(LaserGeometry.height(shift: -200, cameraHeight: H, scale: 200))
    }

    func testHeightRangeIsMinusHalfToPointEightOfTheCameraHeight() throws {
        // A = 300: d = 1200 gives h = 800 = 0.8 H exactly; d = −100 gives h = −500 = −0.5 H exactly.
        XCTAssertEqual(try XCTUnwrap(LaserGeometry.height(shift: 1200, cameraHeight: H, scale: 300)), 800,
                       accuracy: 1e-9)
        XCTAssertNil(LaserGeometry.height(shift: 1300, cameraHeight: H, scale: 300))
        XCTAssertEqual(try XCTUnwrap(LaserGeometry.height(shift: -100, cameraHeight: H, scale: 300)), -500,
                       accuracy: 1e-9)
        XCTAssertNil(LaserGeometry.height(shift: -101, cameraHeight: H, scale: 300))
    }

    func testHeightRejectsABadCameraHeight() {
        XCTAssertNil(LaserGeometry.height(shift: 1, cameraHeight: 0, scale: 200))
        XCTAssertNil(LaserGeometry.height(shift: 1, cameraHeight: -5, scale: 200))
    }

    func testHeightRejectsNonFiniteShifts() {
        XCTAssertNil(LaserGeometry.height(shift: .nan, cameraHeight: H, scale: 200))
        XCTAssertNil(LaserGeometry.height(shift: .infinity, cameraHeight: H, scale: 200))
    }

    // MARK: - Scale

    func testScaleFromShimThenHeightOfTheShimShiftIsTheThickness() throws {
        let thickness = 10.0
        let d = LaserGeometry.shift(height: thickness, cameraHeight: H, scale: 200)
        let scale = try XCTUnwrap(LaserGeometry.scaleFromShim(shift: d, thickness: thickness, cameraHeight: H))
        XCTAssertEqual(scale, 200, accuracy: 1e-9)
        let measured = try XCTUnwrap(LaserGeometry.height(shift: d, cameraHeight: H, scale: scale))
        XCTAssertEqual(measured, thickness, accuracy: 1e-9)
    }

    func testScaleFromShimKeepsTheSignOfTheShift() throws {
        let d = LaserGeometry.shift(height: 10, cameraHeight: H, scale: -200)
        XCTAssertLessThan(d, 0)
        let scale = try XCTUnwrap(LaserGeometry.scaleFromShim(shift: d, thickness: 10, cameraHeight: H))
        XCTAssertEqual(scale, -200, accuracy: 1e-9)
    }

    func testScaleFromShimRejections() {
        XCTAssertNil(LaserGeometry.scaleFromShim(shift: 2, thickness: 0, cameraHeight: H))
        XCTAssertNil(LaserGeometry.scaleFromShim(shift: 2, thickness: -3, cameraHeight: H))
        XCTAssertNil(LaserGeometry.scaleFromShim(shift: 2, thickness: 1000, cameraHeight: H))   // H must exceed t
        XCTAssertNil(LaserGeometry.scaleFromShim(shift: 2, thickness: 2000, cameraHeight: H))
        XCTAssertNil(LaserGeometry.scaleFromShim(shift: 0.4, thickness: 10, cameraHeight: H))   // |d| < 0.5 px
        XCTAssertNil(LaserGeometry.scaleFromShim(shift: .nan, thickness: 10, cameraHeight: H))
        XCTAssertNil(LaserGeometry.scaleFromShim(shift: .infinity, thickness: 10, cameraHeight: H))
        // |A| < 1: 0.5 · (101 − 100) / 100 = 0.005
        XCTAssertNil(LaserGeometry.scaleFromShim(shift: 0.5, thickness: 100, cameraHeight: 101))
        // |d| = 0.5 exactly is accepted: 0.5 · 990 / 10 = 49.5
        XCTAssertEqual(LaserGeometry.scaleFromShim(shift: 0.5, thickness: 10, cameraHeight: H) ?? 0, 49.5,
                       accuracy: 1e-9)
    }

    func testScaleFromAngleSignFollowsTheLaserSide() throws {
        let left = try XCTUnwrap(LaserGeometry.scaleFromAngle(degrees: 30, side: .left, focal: 1000))
        let right = try XCTUnwrap(LaserGeometry.scaleFromAngle(degrees: 30, side: .right, focal: 1000))
        XCTAssertEqual(left, 1000 * tan(30 * Double.pi / 180), accuracy: 1e-9)
        XCTAssertEqual(left, 577.35, accuracy: 0.01)
        XCTAssertEqual(right, -left, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(LaserGeometry.scaleFromAngle(degrees: 45, side: .left, focal: 800)), 800,
                       accuracy: 1e-9)
    }

    func testScaleFromAngleRejections() {
        XCTAssertNil(LaserGeometry.scaleFromAngle(degrees: 0.5, side: .left, focal: 1000))
        XCTAssertNil(LaserGeometry.scaleFromAngle(degrees: 80.5, side: .left, focal: 1000))
        XCTAssertNil(LaserGeometry.scaleFromAngle(degrees: 30, side: .left, focal: 0))
        XCTAssertNil(LaserGeometry.scaleFromAngle(degrees: 30, side: .right, focal: -10))
        XCTAssertNotNil(LaserGeometry.scaleFromAngle(degrees: 1, side: .left, focal: 1000))
        XCTAssertNotNil(LaserGeometry.scaleFromAngle(degrees: 80, side: .left, focal: 1000))
    }

    func testLaserSideSignLabelAndTolerantDecoding() throws {
        struct Holder: Codable { var side: LaserSide }
        XCTAssertEqual(LaserSide.left.sign, 1)
        XCTAssertEqual(LaserSide.right.sign, -1)
        XCTAssertNotEqual(LaserSide.left.label, LaserSide.right.label)
        let right = try JSONDecoder().decode(Holder.self, from: Data(#"{"side":"right"}"#.utf8))
        XCTAssertEqual(right.side, .right)
        let unknown = try JSONDecoder().decode(Holder.self, from: Data(#"{"side":"up"}"#.utf8))
        XCTAssertEqual(unknown.side, .left)
    }

    // MARK: - Across and along

    func testAcrossAndAlongScaleWithTheDistanceToTheSurface() {
        // (u − cx)(H − h)/fx with 100 px off the axis at fx = 1000
        XCTAssertEqual(LaserGeometry.across(u: 600, height: 0, cameraHeight: H, fx: 1000, cx: 500), 100,
                       accuracy: 1e-12)
        XCTAssertEqual(LaserGeometry.across(u: 600, height: 100, cameraHeight: H, fx: 1000, cx: 500), 90,
                       accuracy: 1e-12)
        XCTAssertEqual(LaserGeometry.across(u: 400, height: 0, cameraHeight: H, fx: 1000, cx: 500), -100,
                       accuracy: 1e-12)
        XCTAssertEqual(LaserGeometry.along(v: 450, height: 0, cameraHeight: H, fy: 1000, cy: 500), -50,
                       accuracy: 1e-12)
        XCTAssertEqual(LaserGeometry.along(v: 550, height: 200, cameraHeight: H, fy: 1000, cy: 500), 40,
                       accuracy: 1e-12)
    }

    // MARK: - Median and gaps

    func testMedian() {
        XCTAssertEqual(LaserGeometry.median([3, 1, 2]), 2)
        XCTAssertEqual(LaserGeometry.median([4, 1, 3, 2]), 2.5)
        XCTAssertEqual(LaserGeometry.median([.nan, 5]), 5)
        XCTAssertEqual(LaserGeometry.median([.infinity, 1, 3]), 2)
        XCTAssertNil(LaserGeometry.median([]))
        XCTAssertNil(LaserGeometry.median([.nan, .nan]))
    }

    func testFillGapsInterpolatesInteriorGaps() {
        let result = LaserGeometry.fillGaps([1, .nan, .nan, 4])
        XCTAssertEqual(result.rows, [1, 2, 3, 4])
        XCTAssertEqual(result.count, 2)
    }

    func testFillGapsExtendsTheNearestValueAtTheEdges() {
        let result = LaserGeometry.fillGaps([.nan, 2, .nan, 4, .nan, .nan])
        XCTAssertEqual(result.rows, [2, 2, 3, 4, 4, 4])
        XCTAssertEqual(result.count, 4)
    }

    func testFillGapsLeavesCompleteAndEmptyInputAlone() {
        let complete = LaserGeometry.fillGaps([1, 2, 3])
        XCTAssertEqual(complete.rows, [1, 2, 3])
        XCTAssertEqual(complete.count, 0)
        let empty = LaserGeometry.fillGaps([.nan, .nan])
        XCTAssertTrue(empty.rows.allSatisfy { $0.isNaN })
        XCTAssertEqual(empty.count, 0)
        XCTAssertEqual(LaserGeometry.fillGaps([]).rows, [])
    }

    // MARK: - Baseline

    func testBaselineIsThePerColumnMedianOfTheFramesThatDetectedIt() throws {
        let frames: [[Float]] = [
            [10, 10, 10, .nan],
            [12, 10, .nan, .nan],
            [11, 10, .nan, .nan]
        ]
        let result = try XCTUnwrap(LaserGeometry.baseline(frames: frames))
        // Column 2 was seen in 1 of 3 frames (needs half), column 3 never: both are filled from column 1.
        XCTAssertEqual(result.rows, [11, 10, 10, 10])
        XCTAssertEqual(result.coverage, 50, accuracy: 1e-9)
        XCTAssertEqual(result.filled, 2)
    }

    func testBaselineColumnSeenInExactlyHalfTheFramesCounts() throws {
        let frames: [[Float]] = [[10, 10], [20, .nan]]
        let result = try XCTUnwrap(LaserGeometry.baseline(frames: frames))
        XCTAssertEqual(result.rows, [15, 10])
        XCTAssertEqual(result.coverage, 100, accuracy: 1e-9)
        XCTAssertEqual(result.filled, 0)
    }

    func testBaselineIsRefusedBelowHalfCoverage() {
        let frames: [[Float]] = [[10, .nan, .nan, .nan], [10, .nan, .nan, .nan]]
        XCTAssertNil(LaserGeometry.baseline(frames: frames))   // 25 %
    }

    func testBaselineRefusesEmptyOrRaggedInput() {
        XCTAssertNil(LaserGeometry.baseline(frames: []))
        XCTAssertNil(LaserGeometry.baseline(frames: [[]]))
        XCTAssertNil(LaserGeometry.baseline(frames: [[1, 2], [1]]))
    }

    // MARK: - Shim shift

    /// `frameCount` frames of `columns` columns on a flat baseline of 50 px; columns in `shim` read `shift` px
    /// lower in the picture, with a symmetric ±0.4 px spread over the frames (the median stays exact).
    private func shimFrames(columns: Int = 100, frameCount: Int = 5, shim: Range<Int>, shift: Float)
        -> (frames: [[Float]], baseline: [Float]) {
        let baseline = [Float](repeating: 50, count: columns)
        let frames: [[Float]] = (0..<frameCount).map { f in
            let noise = Float(f - frameCount / 2) * 0.2
            return (0..<columns).map { k in 50 + (shim.contains(k) ? shift + noise : 0) }
        }
        return (frames, baseline)
    }

    func testShimShiftIsTheMedianShiftOfTheShimColumns() throws {
        let (frames, baseline) = shimFrames(shim: 20..<50, shift: 6)
        XCTAssertEqual(try XCTUnwrap(LaserGeometry.shimShift(frames: frames, baseline: baseline)), 6, accuracy: 1e-5)
    }

    func testShimShiftKeepsTheSign() throws {
        let (frames, baseline) = shimFrames(shim: 60..<80, shift: -4)
        XCTAssertEqual(try XCTUnwrap(LaserGeometry.shimShift(frames: frames, baseline: baseline)), -4, accuracy: 1e-5)
    }

    func testShimShiftNeedsTenColumns() {
        let (frames, baseline) = shimFrames(shim: 20..<25, shift: 6)
        XCTAssertNil(LaserGeometry.shimShift(frames: frames, baseline: baseline))
        let (nine, baselineNine) = shimFrames(columns: 20, shim: 5..<14, shift: 6)
        XCTAssertNil(LaserGeometry.shimShift(frames: nine, baseline: baselineNine))
        let (ten, baselineTen) = shimFrames(columns: 20, shim: 5..<15, shift: 6)
        XCTAssertNotNil(LaserGeometry.shimShift(frames: ten, baseline: baselineTen))
    }

    func testShimShiftOfAnUnchangedLineIsNil() {
        let (frames, baseline) = shimFrames(shim: 0..<0, shift: 0)
        XCTAssertNil(LaserGeometry.shimShift(frames: frames, baseline: baseline))
    }

    func testShimShiftRefusesMismatchedInput() {
        let (frames, baseline) = shimFrames(shim: 20..<50, shift: 6)
        XCTAssertNil(LaserGeometry.shimShift(frames: [], baseline: baseline))
        XCTAssertNil(LaserGeometry.shimShift(frames: frames, baseline: []))
        XCTAssertNil(LaserGeometry.shimShift(frames: frames, baseline: Array(baseline.dropLast())))
    }

    // MARK: - Band and tracking rows

    func testBandAddsTheShiftOfTheMaximumHeightOnBothSides() {
        let flat = [Float](repeating: 100, count: 50)
        // margin = |200 · 50 / 950| = 10.53 px
        var band = LaserGeometry.band(baseline: flat, maxHeight: 50, cameraHeight: H, scale: 200, height: 500)
        XCTAssertEqual(band.lo, 89)
        XCTAssertEqual(band.hi, 112)
        // The baseline's own spread widens the band: lowest 90, highest 110.
        let sloped = (0..<50).map { Float(90) + Float($0) * 20 / 49 }
        band = LaserGeometry.band(baseline: sloped, maxHeight: 50, cameraHeight: H, scale: 200, height: 500)
        XCTAssertEqual(band.lo, 79)
        XCTAssertEqual(band.hi, 122)
    }

    func testBandMarginIsAtLeastEightPixelsAndIgnoresTheScaleSign() {
        let flat = [Float](repeating: 100, count: 10)
        var band = LaserGeometry.band(baseline: flat, maxHeight: 10, cameraHeight: H, scale: 200, height: 500)
        XCTAssertEqual(band.lo, 92)
        XCTAssertEqual(band.hi, 109)
        band = LaserGeometry.band(baseline: flat, maxHeight: 50, cameraHeight: H, scale: -200, height: 500)
        XCTAssertEqual(band.lo, 89)
        XCTAssertEqual(band.hi, 112)
    }

    func testBandIsClampedToTheFrame() {
        let flat = [Float](repeating: 100, count: 10)
        var band = LaserGeometry.band(baseline: flat, maxHeight: 5000, cameraHeight: H, scale: 200, height: 500)
        XCTAssertEqual(band.lo, 0)
        XCTAssertEqual(band.hi, 500)
        band = LaserGeometry.band(baseline: [Float](repeating: 495, count: 10), maxHeight: 50, cameraHeight: H,
                                  scale: 200, height: 500)
        XCTAssertEqual(band.lo, 484)
        XCTAssertEqual(band.hi, 500)
    }

    func testBandWithoutABaselineIsTheWholeFrame() {
        let baselines: [[Float]] = [[], [.nan, .nan]]
        for baseline in baselines {
            let band = LaserGeometry.band(baseline: baseline, maxHeight: 50, cameraHeight: H, scale: 200, height: 500)
            XCTAssertEqual(band.lo, 0)
            XCTAssertEqual(band.hi, 500)
        }
    }

    func testTrackingRowsAreTheLargerSideOutsideTheBandWithEightRowsClear() throws {
        // Above: 0..<292 (292 rows); below: 348..<1000 (652 rows).
        XCTAssertEqual(LaserGeometry.trackingRows(band: (lo: 300, hi: 340), height: 1000), 348..<1000)
        // Above: 0..<692 (692 rows); below: 758..<1000 (242 rows).
        XCTAssertEqual(LaserGeometry.trackingRows(band: (lo: 700, hi: 750), height: 1000), 0..<692)
    }

    func testTrackingRowsNeedTheEstimatorMinimum() {
        XCTAssertEqual(SpeedEstimator.minimumTrackingRows, 216)
        // Both sides are 92 rows.
        XCTAssertNil(LaserGeometry.trackingRows(band: (lo: 100, hi: 900), height: 1000))
        // Exactly 216 rows above: 0..<216 needs lo = 224.
        XCTAssertEqual(LaserGeometry.trackingRows(band: (lo: 224, hi: 995), height: 1000), 0..<216)
        XCTAssertNil(LaserGeometry.trackingRows(band: (lo: 223, hi: 995), height: 1000))
        // A 172-row crop (M2-2 example) is refused: the coarse search would have no forward room.
        XCTAssertNil(LaserGeometry.trackingRows(band: (lo: 180, hi: 901), height: 1080))
        // A band that reaches the end of the frame leaves nothing below.
        XCTAssertEqual(LaserGeometry.trackingRows(band: (lo: 500, hi: 1000), height: 1000), 0..<492)
    }

    // MARK: - Calibration

    func testCalibrationIsCompleteWithScaleHeightAndBaseline() {
        XCTAssertTrue(makeLaserCalibration().isComplete)
        XCTAssertTrue(makeLaserCalibration(scale: -35).isComplete)
    }

    func testCalibrationIncompleteCases() {
        XCTAssertFalse(makeLaserCalibration(scale: nil).isComplete)
        XCTAssertFalse(makeLaserCalibration(scale: 0.5).isComplete)
        XCTAssertFalse(makeLaserCalibration(scale: Double.nan).isComplete)
        XCTAssertFalse(makeLaserCalibration(cameraHeight: 0).isComplete)
        var wrongBaseline = makeLaserCalibration()
        wrongBaseline.baselineRows.removeLast()
        XCTAssertFalse(wrongBaseline.isComplete)
        var empty = makeLaserCalibration()
        empty.columns = LaserColumns(first: 0, stride: 1, count: 0)
        empty.baselineRows = []
        XCTAssertFalse(empty.isComplete)
    }

    func testCalibrationMatchesFramesOfTheSameSizeAndColumns() {
        let c = makeLaserCalibration(width: 400, height: 300, stride: 2)
        XCTAssertTrue(c.matches(width: 400, height: 300, columns: LaserColumns.make(width: 400, stride: 2)))
        XCTAssertFalse(c.matches(width: 401, height: 300, columns: c.columns))
        XCTAssertFalse(c.matches(width: 400, height: 299, columns: c.columns))
        XCTAssertFalse(c.matches(width: 400, height: 300, columns: LaserColumns.make(width: 400, stride: 4)))
        var short = c
        short.baselineRows.removeLast()
        XCTAssertFalse(short.matches(width: 400, height: 300, columns: c.columns))
    }

    func testMedianBaselineRow() {
        var c = makeLaserCalibration()
        c.baselineRows = [10, 30, 20]
        XCTAssertEqual(c.medianBaselineRow, 20)
        c.baselineRows = []
        XCTAssertNil(c.medianBaselineRow)
    }

    func testCalibrationJSONRoundTrip() throws {
        var c = makeLaserCalibration(side: .right)
        c.baselineRows = (0..<c.columns.count).map { 150 + Float($0 % 7) * 0.25 }
        c.laserAngle = 31.5
        c.scaleSource = .angle
        c.shimShift = 2.5
        c.filledColumns = 3
        c.coverage = 98.5
        c.shimBaselineRow = 151.5
        c.binned = true
        let data = try JSONEncoder.pretty.encode(c)
        let back = try JSONDecoder.iso.decode(LaserCalibration.self, from: data)
        XCTAssertEqual(back, c)
    }

    func testCalibrationWithoutTheNewOptionalKeysStillDecodes() throws {
        var c = makeLaserCalibration()
        c.shimBaselineRow = nil
        c.binned = nil
        let json = String(decoding: try JSONEncoder.pretty.encode(c), as: UTF8.self)
        XCTAssertFalse(json.contains("binned"))
        XCTAssertFalse(json.contains("shimBaselineRow"))
        let back = try JSONDecoder.iso.decode(LaserCalibration.self, from: Data(json.utf8))
        XCTAssertNil(back.binned)
        XCTAssertNil(back.shimBaselineRow)
        XCTAssertEqual(back, c)
    }

    func testColumnsLayout() {
        let c = LaserColumns.make(width: 1920, stride: 2)
        XCTAssertEqual(c.first, 1)
        XCTAssertEqual(c.stride, 2)
        XCTAssertEqual(c.count, 960)
        XCTAssertEqual(c.u(0), 1)
        XCTAssertEqual(c.u(959), 1919)
    }

    // MARK: - Travel

    func testTravelBetweenTrackedFramesIsLinearInTime() {
        var travel = LaserTravel()
        for i in 0..<10 { _ = travel.addTracked(speed: 100, time: Double(i) / 30) }
        let last = 9.0 / 30
        XCTAssertEqual(travel.lastTrackedTime ?? -1, last, accuracy: 1e-12)
        XCTAssertEqual(travel.travel(at: last), 30, accuracy: 1e-9)
        XCTAssertEqual(travel.travel(at: last + 0.02), 32, accuracy: 1e-9)
        XCTAssertEqual(travel.travel(at: last + 0.5), 80, accuracy: 1e-9)
        XCTAssertEqual(travel.travel(at: last + 0.9), 120, accuracy: 1e-9)
        // Earlier than the last tracked frame: no extrapolation backwards.
        XCTAssertEqual(travel.travel(at: last - 0.01), 30, accuracy: 1e-9)
    }

    func testNothingTrackedYetMeansNoTravel() {
        let travel = LaserTravel()
        XCTAssertEqual(travel.travel(at: 5), 0)
        XCTAssertNil(travel.heldSpeed)
        XCTAssertNil(travel.lastTrackedTime)
    }

    func testFirstTrackedFrameReturnsItsSpeed() {
        var travel = LaserTravel()
        XCTAssertEqual(travel.addTracked(speed: 80, time: 2), 80)
        XCTAssertEqual(travel.heldSpeed, 80)
        // The first tracked frame adds no interval; the held speed runs from it.
        XCTAssertEqual(travel.travel(at: 2.25), 20, accuracy: 1e-9)
        var none = LaserTravel()
        XCTAssertNil(none.addTracked(speed: nil, time: 1))
    }

    func testSpeedIsHeldThroughFramesWithoutTextureLock() {
        var travel = LaserTravel()
        _ = travel.addTracked(speed: 100, time: 0)
        _ = travel.addTracked(speed: 100, time: 0.1)
        _ = travel.addTracked(speed: nil, time: 0.2)
        XCTAssertEqual(travel.heldSpeed, 100)
        XCTAssertEqual(travel.lastTrackedTime ?? -1, 0.2, accuracy: 1e-12)
        XCTAssertEqual(travel.travel(at: 0.2), 20, accuracy: 1e-9)
        XCTAssertEqual(travel.travel(at: 0.25), 25, accuracy: 1e-9)
    }

    func testIntervalsOfASecondOrMoreAddNoTravel() {
        var travel = LaserTravel()
        _ = travel.addTracked(speed: 100, time: 0)
        _ = travel.addTracked(speed: 100, time: 0.5)
        XCTAssertEqual(travel.travel(at: 0.5), 50, accuracy: 1e-9)
        XCTAssertEqual(travel.travel(at: 0.5 + 0.999), 50 + 99.9, accuracy: 1e-9)
        XCTAssertEqual(travel.travel(at: 0.5 + 1.0), 50, accuracy: 1e-9)
        XCTAssertEqual(travel.travel(at: 10), 50, accuracy: 1e-9)
        // A tracked frame after a long gap adds nothing either.
        _ = travel.addTracked(speed: 100, time: 2.0)
        XCTAssertEqual(travel.travel(at: 2.0), 50, accuracy: 1e-9)
        XCTAssertEqual(travel.travel(at: 2.1), 60, accuracy: 1e-9)
    }

    func testClearingTheHeldSpeedStopsTheExtrapolation() {
        var travel = LaserTravel()
        _ = travel.addTracked(speed: 100, time: 0)
        _ = travel.addTracked(speed: 100, time: 0.1)
        travel.clearHeldSpeed()
        XCTAssertNil(travel.heldSpeed)
        XCTAssertEqual(travel.travel(at: 0.15), 10, accuracy: 1e-9)
    }

    func testBeginRecordingKeepsARecentHeldSpeedAndDropsAnOldOne() {
        var recent = LaserTravel()
        _ = recent.addTracked(speed: 100, time: 0)
        _ = recent.addTracked(speed: 100, time: 0.1)
        recent.beginRecording()
        XCTAssertEqual(recent.heldSpeed, 100)

        var old = LaserTravel()
        _ = old.addTracked(speed: 100, time: 0)
        for i in 1...5 { _ = old.addTracked(speed: nil, time: Double(i) * 0.5) }
        XCTAssertEqual(old.heldSpeed, 100)
        old.beginRecording()
        XCTAssertNil(old.heldSpeed)
    }
}
