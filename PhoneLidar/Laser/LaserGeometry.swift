import Foundation

/// Side of the portrait screen the line laser shines from (design §14.4).
enum LaserSide: String, Codable, CaseIterable, Identifiable, Sendable {
    case left
    case right

    var id: String { rawValue }

    var label: String { self == .left ? "Laser on left" : "Laser on right" }

    /// Sign of the scale A: buffer rows increase toward the left of the portrait screen, so a laser on the left
    /// moves raised points to larger rows.
    var sign: Double { self == .left ? 1 : -1 }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LaserSide(rawValue: raw) ?? .left
    }
}

/// Calibration of a laser line setup (design §14.4, §14.6). Saved in Documents/Calibration/LaserCalibration.json
/// and embedded in every laser recording. The baseline is always complete (gaps filled), so it holds no NaN.
struct LaserCalibration: Codable, Equatable, Sendable {
    enum HeightSource: String, Codable, Sendable {
        case entered
        case lidar
    }

    enum ScaleSource: String, Codable, Sendable {
        case shim
        case angle
    }

    var date: Date
    /// Lens to belt surface, mm.
    var cameraHeight: Double
    var cameraHeightSource: HeightSource
    /// Laser term K = side·f_y·tan θ (px, signed). The shift scale of profile column k is
    /// A_k = K + (baselineRows[k] − c_y), so d = A_k·h / (H − h) (design §14.4). Nil until a shim or angle calibration.
    var scale: Double?
    var scaleSource: ScaleSource?
    var shimThickness: Double?
    var shimShift: Double?
    var laserAngle: Double?
    var laserSide: LaserSide
    var videoWidth: Int
    var videoHeight: Int
    var columns: LaserColumns
    /// Line row on the empty belt per profile column (buffer px), gaps filled.
    var baselineRows: [Float]
    /// Columns with a measured baseline, %.
    var coverage: Double
    /// Columns filled by interpolation.
    var filledColumns: Int
    /// Locked lens position at calibration (restored when the calibration is used again).
    var lensPosition: Float?
    var fx: Double
    var fy: Double
    var cx: Double
    var cy: Double
    /// Median baseline row of the shim columns (px), to recompute K when the camera height changes.
    var shimBaselineRow: Double? = nil
    /// The camera format was binned at calibration.
    var binned: Bool? = nil
    /// How the baseline was found (nil = empty belt, every calibration before P12).
    var method: Method? = nil
    /// Side walls: wall-top height above the belt, mm.
    var wallHeight: Double? = nil
    /// Side walls: profile columns of both wall tops, ascending (left wall first).
    var wallColumns: [Int]? = nil
    /// Side walls: line row of each wall column at calibration (the reference for the wall re-zero), px.
    var wallRows: [Float]? = nil
    /// Across position (mm) of the inner face of the left and right wall (the map keeps what lies between).
    var wallInnerX: [Double]? = nil
    /// Correct every frame for the line shift measured on the wall tops (side walls only).
    var wallTracking: Bool? = nil
    /// Camera tilt along the travel (degrees, + = right edge of the portrait screen high, level zero applied)
    /// used in an angle scale.
    var cameraTilt: Double? = nil

    enum Method: String, Codable, Sendable {
        case emptyBelt
        case sideWalls

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Method(rawValue: raw) ?? .emptyBelt
        }
    }

    var isSideWalls: Bool { method == .sideWalls }

    static let fileName = "LaserCalibration.json"

    /// Shift scale A_k (px) of profile column `k`: K + (baseline row − c_y); nil without a scale, outside the
    /// columns, or when |A_k| < 1 px.
    func shiftScale(column k: Int) -> Double? {
        guard let scale, scale.isFinite, k >= 0, k < baselineRows.count, baselineRows[k].isFinite else { return nil }
        let a = scale + (Double(baselineRows[k]) - cy)
        return a.isFinite && abs(a) >= 1 ? a : nil
    }

    /// Effective camera height (mm) of profile column `k` (design §14.9): with an angle scale and a camera tilt the
    /// belt is not perpendicular to the optical axis (`LaserWalls.effectiveHeight`); a shim scale absorbs the tilt, so
    /// it and untilted angle scales use `cameraHeight`.
    func effectiveHeight(column k: Int) -> Double {
        guard scaleSource == .angle, let theta = laserAngle, let phi = cameraTilt, phi != 0,
              k >= 0, k < baselineRows.count else { return cameraHeight }
        return LaserWalls.effectiveHeight(cameraHeight: cameraHeight, laserAngle: theta, side: laserSide,
                                          cameraTilt: phi, beltRow: Double(baselineRows[k]), cy: cy, fy: fy)
    }

    /// Effective camera height of every column.
    var effectiveHeights: [Double] {
        (0..<baselineRows.count).map { effectiveHeight(column: $0) }
    }

    /// A_k of every column (NaN where there is none).
    var shiftScales: [Double] {
        (0..<baselineRows.count).map { shiftScale(column: $0) ?? .nan }
    }

    /// The A_k of largest magnitude (sizes the search band).
    var bandScale: Double? {
        shiftScales.filter { $0.isFinite }.max { abs($0) < abs($1) }
    }

    /// This calibration with the scale of `old` (a new empty-belt baseline of the same format): K with its source,
    /// the shim measurement, and the laser angle and camera tilt that an angle scale contains (M2T-2).
    func keepingScale(of old: LaserCalibration) -> LaserCalibration {
        var c = self
        c.scale = old.scale
        c.scaleSource = old.scaleSource
        c.shimThickness = old.shimThickness
        c.shimShift = old.shimShift
        c.shimBaselineRow = old.shimBaselineRow
        c.laserAngle = old.laserAngle
        c.cameraTilt = old.cameraTilt
        return c
    }

    /// Everything a recording needs: camera height, baseline and a usable scale at the middle column.
    var isComplete: Bool {
        guard cameraHeight > 0, baselineRows.count == columns.count, !baselineRows.isEmpty else { return false }
        return shiftScale(column: baselineRows.count / 2) != nil
    }

    /// The calibration fits frames of this size and column layout.
    func matches(width: Int, height: Int, columns: LaserColumns) -> Bool {
        videoWidth == width && videoHeight == height && self.columns == columns
            && baselineRows.count == columns.count
    }

    /// Also checks the camera geometry: focal lengths within 1 % and principal point within 3 px (a binned or cropped
    /// format of the same size has other intrinsics), and the binning when both are known.
    func matches(width: Int, height: Int, columns: LaserColumns, fx: Double, fy: Double, cx: Double, cy: Double,
                 binned: Bool?) -> Bool {
        guard matches(width: width, height: height, columns: columns), self.fx > 0, self.fy > 0 else { return false }
        if let a = self.binned, let b = binned, a != b { return false }
        return abs(fx - self.fx) <= 0.01 * self.fx && abs(fy - self.fy) <= 0.01 * self.fy
            && abs(cx - self.cx) <= 3 && abs(cy - self.cy) <= 3
    }

    /// Median baseline row (buffer px), the laser line's place in the picture.
    var medianBaselineRow: Double? {
        LaserGeometry.median(baselineRows).map(Double.init)
    }

    static var standardURL: URL {
        Baseline.standardFolder.appendingPathComponent(fileName)
    }

    static func loadStandard() -> LaserCalibration? {
        guard let data = try? Data(contentsOf: standardURL),
              var c = try? JSONDecoder.iso.decode(LaserCalibration.self, from: data) else { return nil }
        // Written by a test build before `scale` meant K (no `binned` key then): its scale is not usable (M2R-8).
        if c.binned == nil {
            c.scale = nil
            c.scaleSource = nil
            c.shimShift = nil
            c.shimBaselineRow = nil
        }
        return c
    }

    func saveStandard() throws {
        try FileManager.default.createDirectory(at: Baseline.standardFolder, withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(self).write(to: Self.standardURL, options: .atomic)
    }

    static func removeStandard() throws {
        if FileManager.default.fileExists(atPath: standardURL.path) {
            try FileManager.default.removeItem(at: standardURL)
        }
    }
}

/// Sheet-of-light triangulation maths (design §14.4). All lengths mm, image positions buffer px.
enum LaserGeometry {
    /// Height (mm) above the belt for a shift d (px) of the line from its baseline row: h = H·d / (A + d).
    /// Nil when |A + d| < 1 px or the height is outside [−0.5 H, 0.8 H].
    @inline(__always)
    static func height(shift d: Double, cameraHeight H: Double, scale A: Double) -> Double? {
        let denominator = A + d
        guard H > 0, abs(denominator) >= 1 else { return nil }
        let h = H * d / denominator
        guard h.isFinite, h >= -0.5 * H, h <= 0.8 * H else { return nil }
        return h
    }

    /// Shift (px) of the line on a surface at height h: d = A·h / (H − h).
    static func shift(height h: Double, cameraHeight H: Double, scale A: Double) -> Double {
        guard H - h > 1 else { return .infinity }
        return A * h / (H - h)
    }

    /// Shift scale A of the shim's columns from a shim of thickness t (mm) that shifted the line by d (px):
    /// A = d·(H − t) / t. The calibration stores the laser term K = A − (v₀ − c_y) (`laserTerm`).
    static func scaleFromShim(shift d: Double, thickness t: Double, cameraHeight H: Double) -> Double? {
        guard t > 0, H > t, abs(d) >= 0.5, d.isFinite else { return nil }
        let a = d * (H - t) / t
        return a.isFinite && abs(a) >= 1 ? a : nil
    }

    /// Laser term K = ±f_y·tan θ from the laser angle to the optical axis (degrees, 1–80) and its side
    /// (a column's A_k adds its baseline row − c_y, the perspective term).
    static func scaleFromAngle(degrees: Double, side: LaserSide, focal fy: Double) -> Double? {
        guard degrees >= 1, degrees <= 80, fy > 0 else { return nil }
        return side.sign * fy * tan(degrees * .pi / 180)
    }

    /// Laser term K from a column scale A measured where the baseline row is v₀: K = A − (v₀ − c_y).
    static func laserTerm(columnScale a: Double, baselineRow v0: Double, cy: Double) -> Double {
        a - (v0 - cy)
    }

    /// Across position (mm from the principal point line) of column u at height h.
    @inline(__always)
    static func across(u: Double, height h: Double, cameraHeight H: Double, fx: Double, cx: Double) -> Double {
        (u - cx) * (H - h) / fx
    }

    /// Along position (mm, + = increasing buffer rows) of row v at height h.
    @inline(__always)
    static func along(v: Double, height h: Double, cameraHeight H: Double, fy: Double, cy: Double) -> Double {
        (v - cy) * (H - h) / fy
    }

    static func median(_ values: [Float]) -> Float? {
        let finite = values.filter { $0.isFinite }.sorted()
        guard !finite.isEmpty else { return nil }
        let m = finite.count / 2
        return finite.count % 2 == 1 ? finite[m] : (finite[m - 1] + finite[m]) / 2
    }

    struct BaselineResult: Equatable {
        /// Line row per column, gaps filled (no NaN).
        var rows: [Float]
        /// Columns measured, %.
        var coverage: Double
        var filled: Int
    }

    /// Columns measured in at least this share of the calibration frames get a baseline value.
    static let baselineFrameShare = 0.5
    /// Coverage (%) below which a baseline is refused.
    static let minimumBaselineCoverage = 50.0

    /// Baseline from calibration frames (each the detected rows per column): per column the median of the frames
    /// that detected it, when at least half did; gaps filled by interpolation. Nil when coverage is below 50 %.
    static func baseline(frames: [[Float]]) -> BaselineResult? {
        guard let count = frames.first?.count, count > 0, frames.allSatisfy({ $0.count == count }) else { return nil }
        var rows = [Float](repeating: .nan, count: count)
        var column = [Float]()
        column.reserveCapacity(frames.count)
        var measured = 0
        for k in 0..<count {
            column.removeAll(keepingCapacity: true)
            for frame in frames where frame[k].isFinite { column.append(frame[k]) }
            guard Double(column.count) >= baselineFrameShare * Double(frames.count),
                  let m = median(column) else { continue }
            rows[k] = m
            measured += 1
        }
        let coverage = 100 * Double(measured) / Double(count)
        guard coverage >= minimumBaselineCoverage else { return nil }
        let filled = fillGaps(rows)
        return BaselineResult(rows: filled.rows, coverage: coverage, filled: filled.count)
    }

    /// Fills NaN entries by linear interpolation between the nearest values on each side; before the first and
    /// after the last value, the nearest value. All-NaN input stays NaN.
    static func fillGaps(_ input: [Float]) -> (rows: [Float], count: Int) {
        var rows = input
        let known = rows.indices.filter { rows[$0].isFinite }
        guard let first = known.first, let last = known.last else { return (rows, 0) }
        var filled = 0
        for i in 0..<first {
            rows[i] = rows[first]
            filled += 1
        }
        for i in (last + 1)..<rows.count {
            rows[i] = rows[last]
            filled += 1
        }
        var previous = first
        for i in known.dropFirst() {
            if i > previous + 1 {
                let a = rows[previous]
                let b = rows[i]
                for j in (previous + 1)..<i {
                    let t = Float(j - previous) / Float(i - previous)
                    rows[j] = a + (b - a) * t
                    filled += 1
                }
            }
            previous = i
        }
        return (rows, filled)
    }

    /// Columns needed under a shim.
    static let minimumShimColumns = 10

    /// Shift (px) of a shim from calibration frames (`shimMeasurement`).
    static func shimShift(frames: [[Float]], baseline: [Float]) -> Double? {
        shimMeasurement(frames: frames, baseline: baseline)?.shift
    }

    /// Shim from calibration frames: per column the median shift from the baseline; the shim is the columns with
    /// |d| ≥ max(1.5 px, half the 95th percentile of |d|); its shift is their median (≥ 10 columns), and
    /// `baselineRow` the median baseline row of those columns.
    static func shimMeasurement(frames: [[Float]], baseline: [Float]) -> (shift: Double, baselineRow: Double)? {
        let count = baseline.count
        guard count > 0, !frames.isEmpty, frames.allSatisfy({ $0.count == count }) else { return nil }
        var shifts = [Float](repeating: .nan, count: count)
        var column = [Float]()
        for k in 0..<count where baseline[k].isFinite {
            column.removeAll(keepingCapacity: true)
            for frame in frames where frame[k].isFinite { column.append(frame[k] - baseline[k]) }
            guard Double(column.count) >= baselineFrameShare * Double(frames.count) else { continue }
            shifts[k] = median(column) ?? .nan
        }
        let magnitudes = shifts.filter { $0.isFinite }.map { abs($0) }.sorted()
        guard !magnitudes.isEmpty else { return nil }
        let p95 = magnitudes[min(magnitudes.count - 1, Int((Double(magnitudes.count - 1) * 0.95).rounded()))]
        let limit = max(1.5, p95 / 2)
        let shimColumns = shifts.indices.filter { shifts[$0].isFinite && abs(shifts[$0]) >= limit }
        guard shimColumns.count >= minimumShimColumns,
              let m = median(shimColumns.map { shifts[$0] }),
              let row = median(shimColumns.map { baseline[$0] }) else { return nil }
        return (Double(m), Double(row))
    }

    /// Row band to search with a baseline: from the lowest baseline row minus the shift of `maxHeight` to the
    /// highest plus that shift (both directions, at least 8 px), clamped to [0, height).
    static func band(baseline: [Float], maxHeight: Double, cameraHeight H: Double, scale A: Double,
                     height: Int) -> (lo: Int, hi: Int) {
        let finite = baseline.filter { $0.isFinite }
        guard let lowest = finite.min(), let highest = finite.max(), height > 0 else { return (0, height) }
        var margin = abs(shift(height: min(maxHeight, 0.79 * H), cameraHeight: H, scale: A))
        if !margin.isFinite { margin = Double(height) }
        margin = max(8, margin)
        let lo = max(0, Int((Double(lowest) - margin).rounded(.down)))
        let hi = min(height, Int((Double(highest) + margin).rounded(.up)) + 1)
        return (lo, max(lo, hi))
    }

    /// Rows for texture tracking: the larger part of the frame outside the laser band (8 px clear of it), when it
    /// holds at least `SpeedEstimator.minimumTrackingRows` rows.
    static func trackingRows(band: (lo: Int, hi: Int), height: Int) -> Range<Int>? {
        let above = 0..<max(0, band.lo - 8)
        let below = min(height, band.hi + 8)..<height
        let best = above.count >= below.count ? above : below
        return best.count >= SpeedEstimator.minimumTrackingRows ? best : nil
    }
}

/// Travel of a laser recording (design §14.5): a `LineSpeedTracker` fed on tracked frames; any frame's travel is the
/// travel at the last tracked frame plus the held speed × the time since. Owned by the capture data queue.
struct LaserTravel {
    private var tracker = LineSpeedTracker()
    /// Time (s) of the last tracked frame.
    private(set) var lastTrackedTime: Double?

    var heldSpeed: Double? { tracker.lastValidSpeed }

    /// Adds a tracked frame's reading (nil = no texture lock) at time t (s); returns the smoothed speed.
    mutating func addTracked(speed: Double?, time: Double) -> Double? {
        let dt = lastTrackedTime.map { time - $0 } ?? 0
        lastTrackedTime = time
        return tracker.add(rawSpeed: speed, dt: dt)
    }

    /// Travel (mm) at time t (s): travel at the last tracked frame + held speed × elapsed time (intervals of a
    /// second or more add nothing, as `LineMotionMath.isTravelInterval`).
    func travel(at time: Double) -> Double {
        guard let t0 = lastTrackedTime else { return tracker.travel }
        let dt = time - t0
        guard LineMotionMath.isTravelInterval(dt) else { return tracker.travel }
        return tracker.travel + (tracker.lastValidSpeed ?? 0) * dt
    }

    mutating func clearHeldSpeed() {
        tracker.clearHeldSpeed()
    }

    mutating func beginRecording() {
        tracker.beginRecording()
    }
}
