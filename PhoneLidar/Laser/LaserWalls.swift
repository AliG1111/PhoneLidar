import Foundation

/// Side-wall calibration and wall re-zero of the laser line scan (design §14.9): the belt need not be cleared. The
/// wall tops on both sides of the forming line are at a known height h_w above the belt; with the camera height H and
/// the laser term K (from the measured laser angle and camera tilt), each wall column gives the belt row under it,
/// and a straight line through both walls gives the belt row of every column (flat belt). Pure.
enum LaserWalls {
    /// Outer share of the detected columns searched for each wall.
    static let outerShare = 0.25
    /// Rows within this distance of the most raised row of a side belong to its wall top, px.
    static let plateauTolerance: Float = 3
    /// Wall-top columns needed per side.
    static let minimumColumns = 3
    /// A wall top must be raised at least this much above the middle half of the line (median rows), px.
    static let minimumRise: Float = 10
    /// Map margin inside each wall's inner face, mm.
    static let mapMargin = 10.0

    /// Laser term K (px) from the laser angle to vertical (degrees, 1–80, from a digital angle gauge), its side and the
    /// camera tilt along the travel (degrees, + = right edge of the portrait screen high): K = f_y·tan(side·θ − φ).
    /// A raised right edge leans the optical axis toward the right of the screen, which is the −row direction, so it
    /// reduces the angle between a left-side laser and the axis. Nil when the angle to the axis is under 1° or bad.
    static func laserTerm(laserAngle theta: Double, side: LaserSide, cameraTilt phi: Double, fy: Double) -> Double? {
        guard theta >= 1, theta <= 80, phi.isFinite, abs(phi) <= 10, fy > 0 else { return nil }
        let relative = side.sign * theta - phi
        guard abs(relative) >= 1, abs(relative) <= 85 else { return nil }
        return fy * tan(relative * .pi / 180)
    }

    /// Effective camera height (mm) of a column whose belt row is v₀, for an angle scale with camera tilt φ (design
    /// §14.9): the belt is then not perpendicular to the optical axis, and h = H_eff·d / (A + d) with
    /// H_eff = H·cos θ·cos β₀ / (cos(β₀ − φ)·cos(side·θ − φ)), β₀ = atan((v₀ − c_y) / f_y), is exact for rays in the
    /// along/height plane (the ratio of the exact to the untilted height does not depend on the row). φ = 0 gives H.
    static func effectiveHeight(cameraHeight H: Double, laserAngle theta: Double, side: LaserSide, cameraTilt phi: Double,
                                beltRow v0: Double, cy: Double, fy: Double) -> Double {
        guard fy > 0, phi.isFinite, theta.isFinite, v0.isFinite, phi != 0 else { return H }
        let rad = Double.pi / 180
        let b0 = atan((v0 - cy) / fy)
        let denominator = cos(b0 - phi * rad) * cos((side.sign * theta - phi) * rad)
        guard abs(denominator) > 1e-6 else { return H }
        let value = H * cos(theta * rad) * cos(b0) / denominator
        return value.isFinite && value > 0 ? value : H
    }

    struct Detection: Equatable {
        /// Wall-top columns of each side (ascending).
        var left: [Int]
        var right: [Int]
        /// Median row per profile column over the frames (NaN = detected in fewer than half).
        var medians: [Float]

        var columns: [Int] { left + right }
    }

    /// Finds both wall tops in calibration frames: per column the median row (detected in at least half of the
    /// frames); in the outer quarter of the detected columns on each side, the most raised row (largest
    /// `raisedSign`·row: + for a laser on the left) and the contiguous run of columns within `plateauTolerance` of it.
    /// Nil unless both sides have at least `minimumColumns` columns raised at least `minimumRise` above the median row
    /// of the middle half (so a flat mat edge is not taken for a wall).
    static func detect(frames: [[Float]], raisedSign: Double) -> Detection? {
        guard let count = frames.first?.count, count > 0, frames.allSatisfy({ $0.count == count }),
              raisedSign != 0 else { return nil }
        var medians = [Float](repeating: .nan, count: count)
        var column = [Float]()
        column.reserveCapacity(frames.count)
        for k in 0..<count {
            column.removeAll(keepingCapacity: true)
            for frame in frames where frame[k].isFinite { column.append(frame[k]) }
            guard Double(column.count) >= LaserGeometry.baselineFrameShare * Double(frames.count) else { continue }
            medians[k] = LaserGeometry.median(column) ?? .nan
        }
        let valid = medians.indices.filter { medians[$0].isFinite }
        guard let first = valid.first, let last = valid.last, last - first >= 4 * minimumColumns else { return nil }
        let reach = max(minimumColumns, Int(Double(last - first) * outerShare))
        let sign = Float(raisedSign > 0 ? 1 : -1)
        let quarter = (last - first) / 4
        let middle = ((first + quarter)...(last - quarter)).map { medians[$0] }.filter { $0.isFinite }
        guard let middleRow = LaserGeometry.median(middle) else { return nil }
        // Raised columns: at least `minimumRise` above the middle. A wall top is the widest raised run that reaches
        // into the outer quarter of its side (it may extend past the quarter); a 1–2-column spike cannot win.
        func isRaised(_ k: Int) -> Bool { medians[k].isFinite && sign * (medians[k] - middleRow) >= minimumRise }
        func wall(_ region: ClosedRange<Int>) -> [Int]? {
            var runs: [ClosedRange<Int>] = []
            var k = first
            while k <= last {
                guard isRaised(k) else { k += 1; continue }
                var end = k
                while end + 1 <= last, isRaised(end + 1) { end += 1 }
                if region.overlaps(k...end) { runs.append(k...end) }
                k = end + 1
            }
            guard let run = runs.max(by: { $0.count < $1.count }), run.count >= minimumColumns else { return nil }
            // Plateau: columns within `plateauTolerance` of the run's 80th-percentile level (robust to spikes and to
            // the inner face's ramp); gaps of up to 2 columns (a bolt, a glint) are bridged, so the wall's inner edge
            // is kept; the longest such stretch wins.
            let levels = run.map { sign * medians[$0] }.sorted()
            let level = levels[min(levels.count - 1, Int((Double(levels.count - 1) * 0.8).rounded()))]
            var best: [Int] = []
            var current: [Int] = []
            for j in run where abs(sign * medians[j] - level) <= plateauTolerance {
                if let previous = current.last, j - previous > 3 {
                    if current.count > best.count { best = current }
                    current = []
                }
                current.append(j)
            }
            if current.count > best.count { best = current }
            return best.count >= minimumColumns ? best : nil
        }
        guard let left = wall(first...(first + reach)), let right = wall((last - reach)...last),
              let leftEnd = left.last, let rightStart = right.first, leftEnd < rightStart else { return nil }
        return Detection(left: left, right: right, medians: medians)
    }

    struct Fit: Equatable {
        /// Belt row of every profile column (straight line, no NaN).
        var rows: [Float]
        /// RMS distance of the wall columns' belt rows from the line, px.
        var residual: Double
        /// Across position (mm) of the left and right wall's inner face.
        var innerX: [Double]
        var wallColumns: [Int]
        var wallRows: [Float]
    }

    /// Belt line from the wall tops: for each wall column v₀ = (v_w − (K − c_y)·r) / (1 + r), r = h_w / (H − h_w)
    /// (from v_w = v₀ + A·r with A = K + (v₀ − c_y)); least-squares straight line v₀ = a + b·u through both walls.
    /// `tilt`: laser angle, side, camera tilt and f_y of an angle scale; each wall column then uses its effective
    /// camera height (`effectiveHeight`), found by iterating the fit (the effective height depends on v₀).
    static func fit(_ detection: Detection, columns: LaserColumns, cameraHeight H: Double, wallHeight hw: Double,
                    laserTerm K: Double, fx: Double, cx: Double, cy: Double,
                    tilt: (laserAngle: Double, side: LaserSide, cameraTilt: Double, fy: Double)? = nil) -> Fit? {
        guard H > 0, hw > 0, H - hw > 1, fx > 0, K.isFinite, detection.medians.count == columns.count,
              detection.left.count >= minimumColumns, detection.right.count >= minimumColumns else { return nil }
        var us: [Double] = []
        var walls: [Double] = []
        for k in detection.columns {
            let vw = Double(detection.medians[k])
            guard vw.isFinite else { return nil }
            us.append(Double(columns.u(k)))
            walls.append(vw)
        }
        let n = Double(us.count)
        var a = 0.0
        var b = 0.0
        var vs: [Double] = []
        for iteration in 0..<4 {
            vs = []
            for (i, vw) in walls.enumerated() {
                var effective = H
                if iteration > 0, let tilt {
                    effective = effectiveHeight(cameraHeight: H, laserAngle: tilt.laserAngle, side: tilt.side,
                                                cameraTilt: tilt.cameraTilt, beltRow: a + b * us[i], cy: cy, fy: tilt.fy)
                }
                guard effective - hw > 1 else { return nil }
                let r = hw / (effective - hw)
                vs.append((vw - (K - cy) * r) / (1 + r))
            }
            let mu = us.reduce(0, +) / n
            let mv = vs.reduce(0, +) / n
            var suu = 0.0
            var suv = 0.0
            for (u, v) in zip(us, vs) {
                suu += (u - mu) * (u - mu)
                suv += (u - mu) * (v - mv)
            }
            guard suu > 0 else { return nil }
            b = suv / suu
            a = mv - b * mu
            if tilt == nil { break }
        }
        var squares = 0.0
        for (u, v) in zip(us, vs) { squares += (v - (a + b * u)) * (v - (a + b * u)) }
        let rows = (0..<columns.count).map { Float(a + b * Double(columns.u($0))) }
        guard rows.allSatisfy({ $0.isFinite }), let leftInner = detection.left.last,
              let rightInner = detection.right.first else { return nil }
        let innerX = [leftInner, rightInner].map { (Double(columns.u($0)) - cx) * (H - hw) / fx }
        return Fit(rows: rows, residual: (squares / n).squareRoot(), innerX: innerX, wallColumns: detection.columns,
                   wallRows: detection.columns.map { detection.medians[$0] })
    }

    /// Refits a side-wall calibration from its stored wall rows (e.g. after a new camera height): same walls, K, wall
    /// height and intrinsics. Nil when the calibration has no walls or the fit fails.
    static func refit(_ c: LaserCalibration, cameraHeight H: Double) -> LaserCalibration? {
        guard c.isSideWalls, let k = c.scale, let hw = c.wallHeight, let wallColumns = c.wallColumns,
              let wallRows = c.wallRows, wallColumns.count == wallRows.count, wallColumns.count >= 2 * minimumColumns
        else { return nil }
        var split = 1
        var widest = -1
        for i in 1..<wallColumns.count where wallColumns[i] - wallColumns[i - 1] > widest {
            widest = wallColumns[i] - wallColumns[i - 1]
            split = i
        }
        var medians = [Float](repeating: .nan, count: c.columns.count)
        for (k, row) in zip(wallColumns, wallRows) where k >= 0 && k < medians.count { medians[k] = row }
        let detection = Detection(left: Array(wallColumns[..<split]), right: Array(wallColumns[split...]),
                                  medians: medians)
        let tilt = c.laserAngle.map { (laserAngle: $0, side: c.laserSide, cameraTilt: c.cameraTilt ?? 0, fy: c.fy) }
        guard let fit = fit(detection, columns: c.columns, cameraHeight: H, wallHeight: hw, laserTerm: k, fx: c.fx,
                            cx: c.cx, cy: c.cy, tilt: tilt) else { return nil }
        var out = c
        out.cameraHeight = H
        out.baselineRows = fit.rows
        out.wallInnerX = fit.innerX
        return out
    }

    /// Line shift c(u) = offset + slope·u (px) of one frame against the calibration, from the wall columns: per side the
    /// median of (row − calibration wall row) over the columns with a detection (at least 2); both sides → the straight
    /// line through the two medians (at each side's median column position); one side → that side's median as a
    /// uniform offset. Nil when neither side has 2 detections or the calibration has no walls.
    static func shift(rows: [Float], calibration c: LaserCalibration) -> (offset: Double, slope: Double)? {
        guard let wallColumns = c.wallColumns, let wallRows = c.wallRows, wallColumns.count == wallRows.count,
              wallColumns.count >= 2 else { return nil }
        // Left wall columns come first (ascending); split where the gap between consecutive columns is largest.
        var split = 1
        var widest = -1
        for i in 1..<wallColumns.count where wallColumns[i] - wallColumns[i - 1] > widest {
            widest = wallColumns[i] - wallColumns[i - 1]
            split = i
        }
        func side(_ range: Range<Int>) -> (u: Double, s: Double)? {
            var shifts: [Float] = []
            var us: [Float] = []
            for i in range {
                let k = wallColumns[i]
                guard k >= 0, k < rows.count, rows[k].isFinite, wallRows[i].isFinite else { continue }
                shifts.append(rows[k] - wallRows[i])
                us.append(Float(c.columns.u(k)))
            }
            guard shifts.count >= 2, let s = LaserGeometry.median(shifts), let u = LaserGeometry.median(us) else {
                return nil
            }
            return (Double(u), Double(s))
        }
        let left = side(0..<split)
        let right = side(split..<wallColumns.count)
        switch (left, right) {
        case let (l?, r?) where r.u > l.u:
            let slope = (r.s - l.s) / (r.u - l.u)
            return (l.s - slope * l.u, slope)
        case let (l?, nil):
            return (l.s, 0)
        case let (nil, r?):
            return (r.s, 0)
        default:
            return nil
        }
    }

    /// Profile columns between the feet of the walls' inner faces (where the belt or mat is seen): u strictly between
    /// c_x + f_x·x_inner / H of both walls. Nil without walls.
    static func matColumns(calibration c: LaserCalibration) -> Range<Int>? {
        guard let inner = c.wallInnerX, inner.count == 2, c.fx > 0, c.cameraHeight > 0 else { return nil }
        let feet = inner.map { c.cx + c.fx * $0 / c.cameraHeight }
        var lo = Int.max
        var hi = Int.min
        for k in 0..<c.columns.count {
            let u = Double(c.columns.u(k))
            if u > feet[0] && u < feet[1] {
                lo = min(lo, k)
                hi = max(hi, k)
            }
        }
        return lo <= hi ? lo..<(hi + 1) : nil
    }

    /// The map keeps readings strictly inside the walls' inner faces, `mapMargin` clear of each.
    static func isInsideWalls(x: Double, calibration c: LaserCalibration) -> Bool {
        guard let inner = c.wallInnerX, inner.count == 2 else { return true }
        return x > inner[0] + mapMargin && x < inner[1] - mapMargin
    }
}
