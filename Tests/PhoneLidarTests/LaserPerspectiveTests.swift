import XCTest

/// The perspective term of the laser shift scale (review finding M2-1, design §14.4): a column whose baseline row v₀ is
/// off the principal row c_y has A = K + (v₀ − c_y), with K = side·f_y·tan θ.
final class LaserPerspectiveTests: XCTestCase {
    /// Row of a point at height h on a laser plane at θ from vertical (laser on the left) whose belt line is at row v0.
    private func pinholeRow(height h: Double, v0: Double, theta: Double, H: Double, fy: Double, cy: Double) -> Double {
        let y0 = (v0 - cy) * H / fy
        let y = y0 + h * tan(theta * .pi / 180)
        return cy + fy * y / (H - h)
    }

    func testAngleScaleWithThePerspectiveTermMatchesThePinholeModel() throws {
        let H = 1000.0, fy = 1400.0, cy = 540.0, theta = 45.0
        let k = try XCTUnwrap(LaserGeometry.scaleFromAngle(degrees: theta, side: .left, focal: fy))
        for v0 in [540.0, 960.0, 150.0] {
            let a = k + (v0 - cy)
            for h in [0.5, 10, 50] {
                let shift = pinholeRow(height: h, v0: v0, theta: theta, H: H, fy: fy, cy: cy) - v0
                XCTAssertEqual(try XCTUnwrap(LaserGeometry.height(shift: shift, cameraHeight: H, scale: a)), h,
                               accuracy: 1e-6, "v0 \(v0), h \(h)")
            }
        }
    }

    func testReviewExampleNoLongerReadsThirtyPercentHigh() throws {
        // M2-1: H 1000 mm, f_y 1400 px, c_y 540, 45° on the left, line at row 960: a 10 mm shim moves it 18.38 px.
        let shift = pinholeRow(height: 10, v0: 960, theta: 45, H: 1000, fy: 1400, cy: 540) - 960
        XCTAssertEqual(shift, 18.38, accuracy: 0.01)
        var c = makeLaserCalibration(width: 1920, height: 1080, cameraHeight: 1000, scale: 1400, baselineRow: 960,
                                     fx: 1400, fy: 1400, cx: 960, cy: 540)
        c.scaleSource = .angle
        let a = try XCTUnwrap(c.shiftScale(column: 100))
        XCTAssertEqual(a, 1820, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(LaserGeometry.height(shift: shift, cameraHeight: 1000, scale: a)), 10,
                       accuracy: 1e-6)
    }

    func testShimLaserTermRecoversTheAngleTermAtAnyBaselineRow() throws {
        let H = 800.0, fy = 1500.0, cy = 540.0, theta = 35.0, t = 10.0
        let expected = fy * tan(theta * .pi / 180)
        for v0 in [300.0, 540.0, 900.0] {
            let d = pinholeRow(height: t, v0: v0, theta: theta, H: H, fy: fy, cy: cy) - v0
            let columnScale = try XCTUnwrap(LaserGeometry.scaleFromShim(shift: d, thickness: t, cameraHeight: H))
            let k = LaserGeometry.laserTerm(columnScale: columnScale, baselineRow: v0, cy: cy)
            XCTAssertEqual(k, expected, accuracy: 1e-6, "v0 \(v0)")
        }
    }

    func testShiftScalesFollowTheBaselineRowOfEachColumn() throws {
        var c = makeLaserCalibration(scale: 200, baselineRow: 150)        // c_y = 150
        c.baselineRows[0] = 170
        c.baselineRows[1] = 140
        XCTAssertEqual(try XCTUnwrap(c.shiftScale(column: 0)), 220, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(c.shiftScale(column: 1)), 190, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(c.shiftScale(column: 2)), 200, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(c.bandScale), 220, accuracy: 1e-9)
        XCTAssertNil(c.shiftScale(column: -1))
        XCTAssertNil(c.shiftScale(column: c.baselineRows.count))
        XCTAssertEqual(c.shiftScales.count, c.baselineRows.count)
        // |A_k| < 1 px has no scale.
        c.baselineRows[3] = Float(150 - 199.5)
        XCTAssertNil(c.shiftScale(column: 3))
        XCTAssertTrue(c.shiftScales[3].isNaN)
    }

    func testShimMeasurementReportsTheShimBaselineRow() throws {
        var baseline = [Float](repeating: 150, count: 100)
        for k in 40..<60 { baseline[k] = 160 }
        let frames = (0..<10).map { _ in (0..<100).map { k in (40..<60).contains(k) ? baseline[k] + 8 : baseline[k] } }
        let shim = try XCTUnwrap(LaserGeometry.shimMeasurement(frames: frames, baseline: baseline))
        XCTAssertEqual(shim.shift, 8, accuracy: 1e-6)
        XCTAssertEqual(shim.baselineRow, 160, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(LaserGeometry.shimShift(frames: frames, baseline: baseline)), 8, accuracy: 1e-6)
    }

    func testCalibrationMatchesOnlyTheSameCameraGeometry() {
        let c = makeLaserCalibration(fx: 1000, fy: 1000, cx: 200, cy: 150)
        let columns = c.columns
        XCTAssertTrue(c.matches(width: 400, height: 300, columns: columns, fx: 1005, fy: 995, cx: 202, cy: 148,
                                binned: nil))
        XCTAssertFalse(c.matches(width: 400, height: 300, columns: columns, fx: 1020, fy: 1000, cx: 200, cy: 150,
                                 binned: nil))
        XCTAssertFalse(c.matches(width: 400, height: 300, columns: columns, fx: 1000, fy: 1000, cx: 210, cy: 150,
                                 binned: nil))
        var binned = c
        binned.binned = false
        XCTAssertFalse(binned.matches(width: 400, height: 300, columns: columns, fx: 1000, fy: 1000, cx: 200, cy: 150,
                                      binned: true))
        XCTAssertTrue(binned.matches(width: 400, height: 300, columns: columns, fx: 1000, fy: 1000, cx: 200, cy: 150,
                                     binned: false))
        XCTAssertFalse(c.matches(width: 401, height: 300, columns: columns, fx: 1000, fy: 1000, cx: 200, cy: 150,
                                 binned: nil))
    }

    func testLaserMapUsesEachColumnsScale() throws {
        // Baseline at row 250 (100 px below c_y = 150): A = 200 + 100 = 300 px. A 20 mm block must read 20 mm.
        let folder = try makeTempFolder()
        let calibration = makeLaserCalibration(scale: 200, baselineRow: 250)
        let info = makeLaserInfo(calibration: calibration)
        try info.save(to: folder)
        let shift = Float(LaserGeometry.shift(height: 20, cameraHeight: 500, scale: 300))
        let writer = try ProfilesFileWriter(url: folder.appendingPathComponent(ProfilesFile.fileName),
                                            columns: info.columns)
        for i in 0..<200 {
            let rows = (0..<info.columnCount).map { _ in Float(250) + ((60..<140).contains(i) ? shift : 0) }
            try writer.append(time: Double(i) / 240, travel: Double(i), speed: nil, flags: 0, rows: rows)
        }
        try writer.close()
        let output = try LaserMapBuilder.build(folder: folder, info: info)
        XCTAssertEqual(output.stats.maximum, 20, accuracy: 0.05)
        XCTAssertEqual(output.stats.minimum, 0, accuracy: 0.05)
    }
}
