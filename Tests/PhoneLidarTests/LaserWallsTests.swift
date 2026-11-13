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
        // Goes through LaserWalls.fit with walls on both sides (M2S-9).
        let f = 1512.0, cy = 540.0, trueH = 3300.0, trueHw = 300.0
        let wide = LaserColumns.make(width: 1920)
        let trueK = f * tan(45 * Double.pi / 180)
        let v0 = cy + 300
        func model(_ h: Double) -> Double { v0 + (trueK + v0 - cy) * h / (trueH - h) }
        let wallColumns = Array(0..<10) + Array((wide.count - 10)..<wide.count)
        var medians = [Float](repeating: .nan, count: wide.count)
        for c in wallColumns { medians[c] = Float(model(trueHw)) }
        let detection = LaserWalls.Detection(left: Array(0..<10), right: Array((wide.count - 10)..<wide.count),
                                             medians: medians)
        var worst = 0.0
        for dTheta in [-0.2, 0.2] {
            for dH in [-10.0, 10.0] {
                for dHw in [-2.0, 2.0] {
                    let k = try XCTUnwrap(LaserWalls.laserTerm(laserAngle: 45 + dTheta, side: .left, cameraTilt: 0, fy: f))
                    let fit = try XCTUnwrap(LaserWalls.fit(detection, columns: wide, cameraHeight: trueH + dH,
                                                           wallHeight: trueHw + dHw, laserTerm: k, fx: f, cx: 960,
                                                           cy: cy))
                    let estimatedV0 = Double(fit.rows[wide.count / 2])
                    for h in stride(from: 0.0, through: 200, by: 25) {
                        let a = k + (estimatedV0 - cy)
                        let measured = try XCTUnwrap(LaserGeometry.height(shift: model(h) - estimatedV0,
                                                                          cameraHeight: trueH + dH, scale: a))
                        worst = max(worst, abs(measured - h))
                    }
                }
            }
        }
        XCTAssertLessThanOrEqual(worst, 5.05)
        XCTAssertGreaterThan(worst, 4.0)       // the budget is real, not trivially met
    }

    // MARK: - Camera tilt (ray-traced, M2S-1)

    /// Row of a point at height h on the laser plane seen by a camera tilted φ along the travel (+ = right edge high,
    /// axis leaning toward −row), traced exactly: belt line at row v0, plane at θ from vertical on `side`.
    private func tracedRow(height h: Double, v0: Double, theta: Double, side: LaserSide, tilt phi: Double,
                           H: Double, f: Double, cy: Double) -> Double {
        let rad = Double.pi / 180
        let g0 = atan((v0 - cy) / f) - phi * rad
        let y = H * tan(g0) + side.sign * h * tan(theta * rad)
        return cy + f * tan(atan(y / (H - h)) + phi * rad)
    }

    func testSideWallCalibrationIsExactForATiltedCamera() throws {
        let f = 1512.0, cy = 540.0, cx = 960.0, H = 3300.0, hw = 300.0, theta = 45.0, v0 = cy + 300
        let wide = LaserColumns.make(width: 1920)
        for side in LaserSide.allCases {
            for phi in [-2.0, 1.0, 2.0] {
                let rows: [Float] = (0..<wide.count).map { c in
                    let wall = c < 10 || c >= wide.count - 10
                    return Float(tracedRow(height: wall ? hw : 20, v0: v0, theta: theta, side: side, tilt: phi, H: H,
                                           f: f, cy: cy))
                }
                let k = try XCTUnwrap(LaserWalls.laserTerm(laserAngle: theta, side: side, cameraTilt: phi, fy: f))
                let a = k + (v0 - cy)
                let detection = try XCTUnwrap(LaserWalls.detect(frames: [rows, rows, rows], raisedSign: a > 0 ? 1 : -1))
                let fit = try XCTUnwrap(LaserWalls.fit(detection, columns: wide, cameraHeight: H, wallHeight: hw,
                                                       laserTerm: k, fx: f, cx: cx, cy: cy,
                                                       tilt: (laserAngle: theta, side: side, cameraTilt: phi, fy: f)))
                XCTAssertEqual(Double(fit.rows[wide.count / 2]), v0, accuracy: 1e-3, "\(side) \(phi)°")
                var c = makeLaserCalibration(width: 1920, height: 1080, cameraHeight: H, scale: k, side: side,
                                             fx: f, fy: f, cx: cx, cy: cy)
                c.baselineRows = fit.rows
                c.scaleSource = .angle
                c.laserAngle = theta
                c.cameraTilt = phi
                let column = wide.count / 2
                for h in [0.0, 20, 100, 200] {
                    let row = tracedRow(height: h, v0: v0, theta: theta, side: side, tilt: phi, H: H, f: f, cy: cy)
                    let measured = try XCTUnwrap(LaserGeometry.height(
                        shift: row - Double(c.baselineRows[column]), cameraHeight: c.effectiveHeight(column: column),
                        scale: try XCTUnwrap(c.shiftScale(column: column))))
                    XCTAssertEqual(measured, h, accuracy: 0.01, "\(side) \(phi)° \(h) mm")
                }
            }
        }
    }

    func testEmptyBeltAngleScaleIsExactForATiltedCamera() throws {
        // Measured baseline (the traced belt row), K from the angle and tilt, heights with the effective height.
        let f = 1512.0, cy = 540.0, H = 1000.0, theta = 40.0, v0 = cy - 250
        for side in LaserSide.allCases {
            for phi in [-1.5, 0.0, 1.5] {
                let k = try XCTUnwrap(LaserWalls.laserTerm(laserAngle: theta, side: side, cameraTilt: phi, fy: f))
                var c = makeLaserCalibration(width: 1920, height: 1080, cameraHeight: H, scale: k, baselineRow: Float(v0),
                                             side: side, fx: f, fy: f, cx: 960, cy: cy)
                c.scaleSource = .angle
                c.laserAngle = theta
                c.cameraTilt = phi
                if phi == 0 { XCTAssertEqual(c.effectiveHeight(column: 0), H) }
                for h in [5.0, 50, 150] {
                    let row = tracedRow(height: h, v0: v0, theta: theta, side: side, tilt: phi, H: H, f: f, cy: cy)
                    let measured = try XCTUnwrap(LaserGeometry.height(
                        shift: row - v0, cameraHeight: c.effectiveHeight(column: 0),
                        scale: try XCTUnwrap(c.shiftScale(column: 0))))
                    XCTAssertEqual(measured, h, accuracy: 0.01, "\(side) \(phi)° \(h) mm")
                }
            }
        }
    }

    func testAShimScaleIgnoresTheTilt() {
        var c = makeLaserCalibration()
        c.cameraTilt = 2
        c.laserAngle = 45
        XCTAssertEqual(c.effectiveHeight(column: 3), c.cameraHeight)          // scaleSource .shim
    }

    // MARK: - Robust detection (M2S-6)

    func testASpikeAboveTheWallTopDoesNotHideTheWall() throws {
        var data = frames()
        for f in data.indices {
            data[f][4] += 25            // a bolt or glint, 2 columns
            data[f][5] += 25
        }
        let detection = try XCTUnwrap(LaserWalls.detect(frames: data, raisedSign: 1))
        XCTAssertEqual(detection.left, [0, 1, 2, 3, 6, 7, 8, 9])        // spike left out, inner edge kept
        XCTAssertEqual(detection.right, Array(190...199))
    }

    func testAWallTopThatExtendsPastTheOuterQuarterIsKeptWhole() throws {
        // Left wall columns 0…59 (the outer quarter ends at 49).
        let data: [[Float]] = (0..<5).map { _ in
            (0..<columns.count).map { c in
                row(v0: 150, height: (c < 60 || c >= 190) ? wallHeight : 20)
            }
        }
        let detection = try XCTUnwrap(LaserWalls.detect(frames: data, raisedSign: 1))
        XCTAssertEqual(detection.left, Array(0..<60))
    }

    /// Rows of a ray-traced line across a mat (20 mm) between two walls with lit inner faces (M2T-1): walls' inner
    /// faces at x = ±1830 mm, tops `top` mm wide at h_w = 300 mm, camera at 3.3 m (f = 1512, 1920 wide), untilted, belt
    /// row v0 = c_y + `offset`.
    private func facedRows(top: Double, theta: Double, side: LaserSide,
                           offset: Double) -> (rows: [Float], v0: Double, k: Double) {
        let f = 1512.0, cx = 960.0, cy = 540.0, H = 3300.0, hw = 300.0, mat = 20.0, xw = 1830.0
        let wide = LaserColumns.make(width: 1920)
        let v0 = cy + offset
        let k = f * tan(side.sign * theta * Double.pi / 180)
        let a = k + (v0 - cy)
        func row(_ h: Double) -> Float { Float(v0 + a * h / (H - h)) }
        let rows: [Float] = (0..<wide.count).map { c in
            let x = abs(Double(wide.u(c)) - cx)
            if x < f * xw / (H - mat) { return row(mat) }                       // mat inside the walls
            if x < f * xw / (H - hw) { return row(H - f * xw / x) }             // the lit inner face
            if x <= f * (xw + top) / (H - hw) { return row(hw) }                // the wall top
            return .nan                                                         // outside: not lit
        }
        return (rows, v0, k)
    }

    /// Mat height (20 mm traced) in the middle column after a side-wall calibration on `traced`; nil when refused.
    private func matHeight(_ traced: (rows: [Float], v0: Double, k: Double)) throws -> Double? {
        let f = 1512.0, cy = 540.0, H = 3300.0
        let wide = LaserColumns.make(width: 1920)
        let a = traced.k + (traced.v0 - cy)
        guard let detection = LaserWalls.detect(frames: [traced.rows, traced.rows],
                                                raisedSign: a > 0 ? 1 : -1) else { return nil }
        let fit = try XCTUnwrap(LaserWalls.fit(detection, columns: wide, cameraHeight: H, wallHeight: 300,
                                               laserTerm: traced.k, fx: f, cx: 960, cy: cy))
        let column = wide.count / 2
        let base = Double(fit.rows[column])
        return try XCTUnwrap(LaserGeometry.height(shift: Double(traced.rows[column]) - base, cameraHeight: H,
                                                  scale: traced.k + (base - cy)))
    }

    func testWallTopsBesideALitInnerFaceGiveTheRightHeights() throws {
        // Line 150 px either side of the centre (|A| ≥ 400 px), tops 10–40 mm, lasers 20–45°, both sides.
        for offset in [150.0, -150] {
            for side in LaserSide.allCases {
                for theta in [20.0, 30.0, 45.0] {
                    for top in [10.0, 20.0, 40.0] {
                        let label = "\(offset) px \(side) \(theta)° \(top) mm"
                        let measured = try XCTUnwrap(matHeight(facedRows(top: top, theta: theta, side: side,
                                                                         offset: offset)), label)
                        XCTAssertEqual(measured, 20, accuracy: 0.5, label)
                    }
                }
            }
        }
    }

    func testAShallowInnerFaceIsRefusedOrNearlyRight() throws {
        // |A| = 250 px (a 20° laser against a 300 px line offset): the face climbs only 0.3 px per pixel, so its top
        // columns can join the plateau; the mat stays within 1.5 mm (0.1 px at 13 mm/px) or the calibration is refused.
        for (side, offset) in [(LaserSide.left, -300.0), (.right, 300)] {
            for top in [10.0, 20.0, 40.0] {
                let traced = facedRows(top: top, theta: 20, side: side, offset: offset)
                XCTAssertEqual(abs(traced.k + (traced.v0 - 540)), 250, accuracy: 1)
                guard let measured = try matHeight(traced) else { continue }
                XCTAssertEqual(measured, 20, accuracy: 1.5, "\(side) \(top) mm")
            }
        }
    }

    func testARolledLineKeepsWholeWallTops() throws {
        // A 5° roll moves the raw wall-top rows 2 px across 10 columns; with the roll removed they stay one plateau.
        let detection = try XCTUnwrap(LaserWalls.detect(frames: frames(tilt: 0.0875), raisedSign: 1))
        XCTAssertEqual(detection.left, Array(0...9))
        XCTAssertEqual(detection.right, Array(190...199))
    }

    func testANewBaselineKeepsTheAngleScaleWithItsTilt() {
        // M2T-2, M2V-1: an empty-belt baseline that keeps an angle scale keeps the camera tilt and side K contains.
        var old = makeLaserCalibration(width: 1920, height: 1080, cameraHeight: 3300, scale: 1400, baselineRow: 840,
                                       fx: 1512, fy: 1512, cx: 960, cy: 540)
        old.scaleSource = .angle
        old.laserAngle = 45
        old.cameraTilt = 1
        old.shimThickness = 25
        old.shimShift = 12
        old.shimBaselineRow = 830
        var fresh = makeLaserCalibration(width: 1920, height: 1080, cameraHeight: 3300, scale: nil, baselineRow: 845,
                                         side: .right, fx: 1512, fy: 1512, cx: 960, cy: 540)
        XCTAssertEqual(fresh.effectiveHeight(column: 10), 3300)                 // no scale, no tilt
        XCTAssertEqual(fresh.keepingScale(of: fresh), fresh)                    // nothing to keep
        fresh = fresh.keepingScale(of: old)
        XCTAssertEqual(fresh.laserSide, .left)                                  // the side K belongs to (M2V-1)
        XCTAssertEqual(fresh.scale, 1400)
        XCTAssertEqual(fresh.scaleSource, .angle)
        XCTAssertEqual(fresh.laserAngle, 45)
        XCTAssertEqual(fresh.cameraTilt, 1)
        XCTAssertEqual(fresh.shimThickness, 25)
        XCTAssertEqual(fresh.shimShift, 12)
        XCTAssertEqual(fresh.shimBaselineRow, 830)
        XCTAssertEqual(fresh.baselineRows, Array(repeating: 845, count: fresh.columns.count))  // its own baseline
        XCTAssertLessThan(fresh.effectiveHeight(column: 10), 3300 * 0.985)     // ≈ −2 % for 1°
    }

    // MARK: - Refit and persistence (M2S-2, M2S-9)

    func testRefitForANewCameraHeightMatchesAFreshCalibration() throws {
        let detection = try XCTUnwrap(LaserWalls.detect(frames: frames(), raisedSign: 1))
        func calibration(_ height: Double) throws -> LaserCalibration {
            let fit = try XCTUnwrap(LaserWalls.fit(detection, columns: columns, cameraHeight: height,
                                                   wallHeight: wallHeight, laserTerm: k, fx: 1000, cx: 200, cy: 150))
            var c = makeLaserCalibration(cameraHeight: height, scale: k)
            c.method = .sideWalls
            c.wallHeight = wallHeight
            c.wallColumns = fit.wallColumns
            c.wallRows = fit.wallRows
            c.wallInnerX = fit.innerX
            c.baselineRows = fit.rows
            return c
        }
        let wrong = try calibration(520)
        let fresh = try calibration(500)
        let refit = try XCTUnwrap(LaserWalls.refit(wrong, cameraHeight: 500))
        XCTAssertEqual(refit.cameraHeight, 500)
        for c in [0, 100, 199] {
            XCTAssertEqual(refit.baselineRows[c], fresh.baselineRows[c], accuracy: 1e-4)
        }
        XCTAssertEqual(refit.wallInnerX?[0] ?? 0, fresh.wallInnerX?[0] ?? 1, accuracy: 1e-9)
        XCTAssertNil(LaserWalls.refit(makeLaserCalibration(), cameraHeight: 500))
    }

    func testSideWallFieldsRoundTripAndAnUnknownMethodReadsAsEmptyBelt() throws {
        var c = makeLaserCalibration()
        c.method = .sideWalls
        c.wallHeight = 305.5
        c.wallColumns = [0, 1, 2, 197, 198, 199]
        c.wallRows = [200, 200.5, 201, 199, 199.5, 200]
        c.wallInnerX = [-72.4, 72.4]
        c.wallTracking = false
        c.cameraTilt = -0.35
        c.binned = false
        let data = try JSONEncoder.pretty.encode(c)
        XCTAssertEqual(try JSONDecoder.iso.decode(LaserCalibration.self, from: data), c)
        let unknown = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"sideWalls\"",
                                                                                   with: "\"futureMethod\"")
        XCTAssertEqual(try JSONDecoder.iso.decode(LaserCalibration.self, from: Data(unknown.utf8)).method, .emptyBelt)
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
