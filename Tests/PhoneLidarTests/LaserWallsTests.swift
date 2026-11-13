import XCTest

/// Side-wall calibration and wall re-zero (design §14.9, FR-LAS-11…15). Synthetic camera of `LaserTestSupport`:
/// 400 × 300 buffer, 200 columns (u = 1, 3 … 399), f = 1000 px, c = (200, 150), camera 500 mm above the belt.
final class LaserWallsTests: XCTestCase {
    private let H = 500.0
    private let wallHeight = 100.0
    private let k = 200.0                   // laser term, px
    private let columns = LaserColumns.make(width: 400)

    /// Row of a point at height h above a column whose belt row is v0 (A = K + (v0 − c_y)).
    private func row(v0: Double, height h: Double, laserTerm: Double = 200, cameraHeight: Double = 500) -> Float {
        let a = laserTerm + (v0 - 150)
        return Float(v0 + a * h / (cameraHeight - h))
    }

    /// Belt line v0(u) = 140 + tilt·u, walls on columns 0…9 and 190…199, mat (20 mm) in between.
    private func beltRow(_ kIndex: Int, tilt: Double = 0.05) -> Double { 140 + tilt * Double(columns.u(kIndex)) }

    private func frames(count: Int = 20, noise: Bool = false, tilt: Double = 0.05) -> [[Float]] {
        (0..<count).map { f in
            (0..<columns.count).map { c in
                let wall = c < 10 || c >= 190
                let jitter: Float = noise ? Float((c * 7 + f * 13) % 5) * 0.02 - 0.04 : 0
                return row(v0: beltRow(c, tilt: tilt), height: wall ? wallHeight : 20) + jitter
            }
        }
    }

    // MARK: - Laser term with camera tilt

    func testLaserTermUsesTheAngleToTheCameraAxis() throws {
        XCTAssertEqual(try XCTUnwrap(LaserWalls.laserTerm(laserAngle: 45, side: .left, cameraTilt: 0, fy: 1000)), 1000,
                       accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(LaserWalls.laserTerm(laserAngle: 45, side: .right, cameraTilt: 0, fy: 1000)), -1000,
                       accuracy: 1e-9)
        // Right edge 1° high leans the axis toward the right (−row): a left laser is 44° from the axis.
        XCTAssertEqual(try XCTUnwrap(LaserWalls.laserTerm(laserAngle: 45, side: .left, cameraTilt: 1, fy: 1000)),
                       1000 * tan(44 * Double.pi / 180), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(LaserWalls.laserTerm(laserAngle: 45, side: .right, cameraTilt: 1, fy: 1000)),
                       -1000 * tan(46 * Double.pi / 180), accuracy: 1e-9)
        XCTAssertNil(LaserWalls.laserTerm(laserAngle: 0.5, side: .left, cameraTilt: 0, fy: 1000))
        XCTAssertNil(LaserWalls.laserTerm(laserAngle: 45, side: .left, cameraTilt: 11, fy: 1000))
        XCTAssertNil(LaserWalls.laserTerm(laserAngle: 1.5, side: .left, cameraTilt: 1, fy: 1000))   // 0.5° to the axis
        XCTAssertNil(LaserWalls.laserTerm(laserAngle: 45, side: .left, cameraTilt: .nan, fy: 1000))
    }

    // MARK: - Detection

    func testBothWallTopsAreFound() throws {
        let detection = try XCTUnwrap(LaserWalls.detect(frames: frames(noise: true), raisedSign: 1))
        XCTAssertEqual(detection.left, Array(0...9))
        XCTAssertEqual(detection.right, Array(190...199))
        XCTAssertEqual(detection.columns.count, 20)
    }

    func testARightSideLaserLooksForTheSmallestRows() throws {
        // Mirror the rows around 300: the raised wall tops are now the smallest rows.
        let mirrored = frames().map { $0.map { 300 - $0 } }
        XCTAssertNil(LaserWalls.detect(frames: mirrored, raisedSign: 1))       // the walls are the lowest rows now
        let detection = try XCTUnwrap(LaserWalls.detect(frames: mirrored, raisedSign: -1))
        XCTAssertEqual(detection.left, Array(0...9))
        XCTAssertEqual(detection.right, Array(190...199))
    }

    func testAMissingWallIsRefused() {
        // Without the right wall, the right edge of a flat mat is not raised above the middle: refused.
        var data = frames(tilt: 0)
        for f in data.indices { for c in 190..<200 { data[f][c] = .nan } }
        XCTAssertNil(LaserWalls.detect(frames: data, raisedSign: 1))
    }

    func testRaggedFramesAreRefused() {
        XCTAssertNil(LaserWalls.detect(frames: [], raisedSign: 1))
        XCTAssertNil(LaserWalls.detect(frames: [[1, 2, 3], [1, 2]], raisedSign: 1))
        XCTAssertNil(LaserWalls.detect(frames: frames(), raisedSign: 0))
    }

    // MARK: - Fit

    func testFitRecoversTheTiltedBeltLine() throws {
        let detection = try XCTUnwrap(LaserWalls.detect(frames: frames(), raisedSign: 1))
        let fit = try XCTUnwrap(LaserWalls.fit(detection, columns: columns, cameraHeight: H, wallHeight: wallHeight,
                                               laserTerm: k, fx: 1000, cx: 200, cy: 150))
        for c in [0, 50, 100, 150, 199] {
            XCTAssertEqual(Double(fit.rows[c]), beltRow(c), accuracy: 1e-3, "column \(c)")
        }
        XCTAssertLessThan(fit.residual, 1e-3)
        XCTAssertEqual(fit.wallColumns, Array(0...9) + Array(190...199))
        XCTAssertEqual(fit.wallRows.count, 20)
        // Inner faces: column 9 (u 19) and 190 (u 381) at the wall-top height.
        XCTAssertEqual(fit.innerX[0], (19 - 200) * (H - wallHeight) / 1000, accuracy: 1e-9)
        XCTAssertEqual(fit.innerX[1], (381 - 200) * (H - wallHeight) / 1000, accuracy: 1e-9)
    }

    func testTheMatReadsItsHeightAfterAWallCalibration() throws {
        let detection = try XCTUnwrap(LaserWalls.detect(frames: frames(), raisedSign: 1))
        let fit = try XCTUnwrap(LaserWalls.fit(detection, columns: columns, cameraHeight: H, wallHeight: wallHeight,
                                               laserTerm: k, fx: 1000, cx: 200, cy: 150))
        for c in [20, 100, 180] {
            let a = k + (Double(fit.rows[c]) - 150)
            let d = Double(row(v0: beltRow(c), height: 20) - fit.rows[c])
            XCTAssertEqual(try XCTUnwrap(LaserGeometry.height(shift: d, cameraHeight: H, scale: a)), 20, accuracy: 1e-3)
        }
    }

    func testFiveMillimetreBudget() throws {
        // Analysis case of design §14.9 at 3.3 m: 300 mm walls, 45° laser, f = 1512 px, belt line 300 px off centre.
        // Errors: angle ±0.2°, camera height ±10 mm, wall height ±2 mm → worst case within 5.0 mm over 0–200 mm.
        let f = 1512.0, cy = 540.0, trueH = 3300.0, trueHw = 300.0
        let trueK = f * tan(45 * Double.pi / 180)
        let v0 = cy + 300
        func model(_ h: Double) -> Double { v0 + (trueK + v0 - cy) * h / (trueH - h) }
        var worst = 0.0
        for dTheta in [-0.2, 0.2] {
            for dH in [-10.0, 10.0] {
                for dHw in [-2.0, 2.0] {
                    let k = try XCTUnwrap(LaserWalls.laserTerm(laserAngle: 45 + dTheta, side: .left, cameraTilt: 0, fy: f))
                    let H = trueH + dH, hw = trueHw + dHw
                    let r = hw / (H - hw)
                    let estimatedV0 = (model(trueHw) - (k - cy) * r) / (1 + r)
                    for h in stride(from: 0.0, through: 200, by: 25) {
                        let a = k + (estimatedV0 - cy)
                        let measured = try XCTUnwrap(LaserGeometry.height(shift: model(h) - estimatedV0,
                                                                          cameraHeight: H, scale: a))
                        worst = max(worst, abs(measured - h))
                    }
                }
            }
        }
        XCTAssertLessThanOrEqual(worst, 5.05)
        XCTAssertGreaterThan(worst, 4.0)       // the budget is real, not trivially met
    }

    // MARK: - Re-zero

    private func wallCalibration(tracking: Bool = true) -> LaserCalibration {
        var c = makeLaserCalibration(scale: k)
        let detection = LaserWalls.Detection(left: Array(0...9), right: Array(190...199),
                                             medians: (0..<columns.count).map {
                                                 row(v0: 150, height: ($0 < 10 || $0 >= 190) ? wallHeight : 0)
                                             })
        let fit = LaserWalls.fit(detection, columns: columns, cameraHeight: H, wallHeight: wallHeight, laserTerm: k,
                                 fx: 1000, cx: 200, cy: 150)
        c.baselineRows = fit?.rows ?? c.baselineRows
        c.method = .sideWalls
        c.wallHeight = wallHeight
        c.wallColumns = fit?.wallColumns
        c.wallRows = fit?.wallRows
        c.wallInnerX = fit?.innerX
        c.wallTracking = tracking
        return c
    }

    func testShiftFromBothWallsIsALine() throws {
        let c = wallCalibration()
        var rows = [Float](repeating: .nan, count: columns.count)
        for i in 0..<10 { rows[i] = (c.wallRows?[i] ?? 0) + 2 }
        for i in 190..<200 { rows[i] = (c.wallRows?[i - 180] ?? 0) + 4 }
        let shift = try XCTUnwrap(LaserWalls.shift(rows: rows, calibration: c))
        // Left median u = 10 (columns 0…9: u 1…19), right median u = 390.
        XCTAssertEqual(shift.offset + shift.slope * 10, 2, accuracy: 1e-6)
        XCTAssertEqual(shift.offset + shift.slope * 390, 4, accuracy: 1e-6)
    }

    func testShiftFromOneWallIsAnOffset() throws {
        let c = wallCalibration()
        var rows = [Float](repeating: .nan, count: columns.count)
        for i in 190..<200 { rows[i] = (c.wallRows?[i - 180] ?? 0) - 1.5 }
        let shift = try XCTUnwrap(LaserWalls.shift(rows: rows, calibration: c))
        XCTAssertEqual(shift.offset, -1.5, accuracy: 1e-6)
        XCTAssertEqual(shift.slope, 0)
        rows[190] = .nan
        for i in 191..<200 { rows[i] = .nan }
        XCTAssertNil(LaserWalls.shift(rows: rows, calibration: c))
        XCTAssertNil(LaserWalls.shift(rows: rows, calibration: makeLaserCalibration()))
    }

    func testMatColumnsAndMapCropStayInsideTheWalls() throws {
        let c = wallCalibration()
        let mat = try XCTUnwrap(LaserWalls.matColumns(calibration: c))
        // Feet of the faces at belt level: u = 200 + 1000·(∓72.4)/500 = 55.2 / 344.8 → columns 28…171.
        XCTAssertEqual(mat, 28..<172)
        XCTAssertTrue(LaserWalls.isInsideWalls(x: 0, calibration: c))
        XCTAssertFalse(LaserWalls.isInsideWalls(x: -63, calibration: c))     // inside the 10 mm margin of −72.4
        XCTAssertTrue(LaserWalls.isInsideWalls(x: -62, calibration: c))
        XCTAssertTrue(LaserWalls.isInsideWalls(x: 1000, calibration: makeLaserCalibration()))
        XCTAssertNil(LaserWalls.matColumns(calibration: makeLaserCalibration()))
    }

    // MARK: - Map with side walls

    private func writeShakenRecording(_ info: LaserRecordingInfo, folder: URL) throws {
        try info.save(to: folder)
        let writer = try ProfilesFileWriter(url: folder.appendingPathComponent(ProfilesFile.fileName),
                                            columns: info.columns)
        for i in 0..<200 {
            let shake: Float = (50..<150).contains(i) ? 3 : 0           // the whole picture moves 3 px
            let rows = (0..<info.columnCount).map { c -> Float in
                row(v0: 150, height: (c < 10 || c >= 190) ? wallHeight : 0) + shake
            }
            try writer.append(time: Double(i) / 240, travel: Double(i), speed: nil, flags: 0, rows: rows)
        }
        try writer.close()
    }

    func testWallReZeroRemovesAShakeAndTheMapLeavesOutTheWalls() throws {
        let folder = try makeTempFolder()
        let info = makeLaserInfo(calibration: wallCalibration())
        try writeShakenRecording(info, folder: folder)
        let output = try LaserMapBuilder.build(folder: folder, info: info)
        XCTAssertEqual(output.stats.maximum, 0, accuracy: 0.01)
        XCTAssertEqual(output.stats.minimum, 0, accuracy: 0.01)
        XCTAssertTrue(output.summary.contains { $0.hasPrefix("Wall re-zero: 100 % of frames measured") },
                      output.summary.joined(separator: "\n"))
        XCTAssertLessThan(output.stats.widthMM, 2 * 62.4 + 2)               // the walls are cropped off
    }

    func testWithoutWallReZeroTheShakeReadsAsHeight() throws {
        let folder = try makeTempFolder()
        let info = makeLaserInfo(calibration: wallCalibration(tracking: false))
        try writeShakenRecording(info, folder: folder)
        let output = try LaserMapBuilder.build(folder: folder, info: info)
        // 3 px on A = 200 px at 500 mm: h = 500·3 / 203 = 7.39 mm.
        XCTAssertEqual(output.stats.maximum, 500 * 3 / 203, accuracy: 0.05)
        XCTAssertFalse(output.summary.contains { $0.hasPrefix("Wall re-zero:") })
        XCTAssertTrue(TopoMapBuilder.isMapSummaryLine("Wall re-zero: 100 % of frames measured"))
    }
}
