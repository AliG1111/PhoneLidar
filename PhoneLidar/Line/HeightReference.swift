import Foundation
import simd

// Height references for Line scan maps (design §16, FR-HREF). Pure logic: no AVFoundation, in the test target.

/// How heights above the belt are referenced (Line scan › Height reference).
enum HeightReferenceMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    /// LiDAR baseline of the empty flat surface (`Baseline.bin`, design §6.6).
    case emptyBelt
    /// Typed camera height (lens to belt) and the phone's tilt from its level zero; the belt is assumed flat.
    case cameraHeight
    /// Wall tops measured by the LiDAR and the typed wall height above the belt; the belt is assumed flat.
    case sideWalls

    var id: String { rawValue }

    var label: String {
        switch self {
        case .emptyBelt: return "Empty belt"
        case .cameraHeight: return "Camera height"
        case .sideWalls: return "Side walls"
        }
    }

    /// Tolerant: a value written by a newer build reads as `emptyBelt`.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HeightReferenceMethod(rawValue: raw) ?? .emptyBelt
    }
}

/// A band of the picture across the material: fractions of the buffer width (depth u), 0 = top of the portrait
/// screen, 1 = bottom. Covers the whole picture along the travel.
struct WallBand: Codable, Equatable, Sendable {
    var start: Double
    var end: Double

    static let minimumWidth = 0.01
    static let defaultTop = WallBand(start: 0.02, end: 0.10)
    static let defaultBottom = WallBand(start: 0.90, end: 0.98)

    /// Inside 0…1, start < end, at least `minimumWidth` wide (NaN and swapped ends repaired).
    var clamped: WallBand {
        var a = start.isFinite ? min(max(start, 0), 1) : 0
        var b = end.isFinite ? min(max(end, 0), 1) : 1
        if a > b { swap(&a, &b) }
        if b - a < Self.minimumWidth {
            if a + Self.minimumWidth <= 1 { b = a + Self.minimumWidth } else { a = b - Self.minimumWidth }
        }
        return WallBand(start: a, end: b)
    }

    var center: Double { (start + end) / 2 }

    /// Depth columns u covered by the band in a map `width` pixels wide (at least one column).
    func columns(width: Int) -> Range<Int> {
        guard width > 0 else { return 0..<0 }
        let band = clamped
        let lo = min(width - 1, max(0, Int((band.start * Double(width)).rounded(.down))))
        let hi = min(width, max(lo + 1, Int((band.end * Double(width)).rounded(.up))))
        return lo..<hi
    }
}

/// Result of a side-wall calibration: the distance from the camera to each wall top along the belt normal.
struct WallCalibration: Codable, Equatable, Sendable {
    var date: Date
    /// Wall top above the belt, mm (typed; one height for both walls).
    var wallHeight: Double
    /// Camera → wall-top plane along the belt normal, mm.
    var topDistance: Double
    var bottomDistance: Double
    /// LiDAR readings in each wall's cluster and their robust spread (1.4826 · MAD), mm.
    var topReadings: Int
    var bottomReadings: Int
    var topSpread: Double
    var bottomSpread: Double
    /// Phone tilt from the level zero during the capture, degrees (`gravityTilt` signs).
    var tiltX: Double
    var tiltY: Double
    var depthWidth: Int
    var depthHeight: Int
    var filteredDepth: Bool
    var topBand: WallBand
    var bottomBand: WallBand

    /// Walls further apart than this (mm along the normal) are flagged: a tilt across the belt the level zero does
    /// not cover, unequal wall heights or a band off a wall top.
    static let disagreementWarning = 5.0

    /// Camera → belt along the normal, mm: the mean wall-top distance plus the wall height.
    var beltDistance: Double { (topDistance + bottomDistance) / 2 + wallHeight }
    var disagreement: Double { abs(topDistance - bottomDistance) }
}

/// The belt as a plane in camera coordinates: x = buffer x (across, toward the bottom of the portrait screen),
/// y = buffer y (along, toward the left), z = optical axis. `normal` points from the camera to the belt.
struct HeightPlane: Equatable, Sendable {
    var normal: SIMD3<Double>
    /// Camera → belt along `normal`, mm.
    var distance: Double

    /// Height above the belt of a camera-frame point (mm).
    func height(of point: SIMD3<Double>) -> Double {
        distance - simd_dot(normal, point)
    }

    /// Height of a planar depth reading z (mm) at normalised image coordinates (xn, yn) = ((u − cx)/fx, (v − cy)/fy).
    @inline(__always)
    func height(z: Double, xn: Double, yn: Double) -> Double {
        distance - z * (normal.x * xn + normal.y * yn + normal.z)
    }

    /// Belt normal in camera coordinates from the phone tilt relative to the level zero (degrees, `gravityTilt`
    /// signs: +x = right edge of the portrait screen high, +y = top edge high). Gravity in device coordinates is
    /// (−sin x, −sin y, −√(1 − sin²x − sin²y)); camera x = −device y, camera y = −device x, camera z = −device z.
    static func normal(tiltX: Double, tiltY: Double) -> SIMD3<Double> {
        let sx = sin(tiltX * .pi / 180)
        let sy = sin(tiltY * .pi / 180)
        let z = max(0, 1 - sx * sx - sy * sy).squareRoot()
        let n = SIMD3<Double>(sy, sx, z)
        let length = simd_length(n)
        return length > 0 ? n / length : SIMD3<Double>(0, 0, 1)
    }
}

/// The height reference chosen on the Line scan screen. Kept in *Calibration › HeightReference.json* and copied
/// into a recording (with the level zero in use) when the method is `cameraHeight` or `sideWalls`.
struct HeightReference: Codable, Equatable, Sendable {
    static let fileName = "HeightReference.json"

    var method: HeightReferenceMethod = .emptyBelt
    /// Lens to belt, mm (typed).
    var cameraHeight: Double?
    /// Wall top above the belt, mm (typed).
    var wallHeight: Double?
    var topBand: WallBand?
    var bottomBand: WallBand?
    var walls: WallCalibration?
    /// Line scan level zero (degrees) when copied into a recording; nil = gravity is the belt normal.
    var levelZeroX: Double?
    var levelZeroY: Double?

    /// Camera → belt along the normal (mm), nil when the chosen plane method is not set up.
    var beltDistance: Double? {
        switch method {
        case .emptyBelt:
            return nil
        case .cameraHeight:
            guard let h = cameraHeight, h.isFinite, h > 0 else { return nil }
            return h
        case .sideWalls:
            guard let walls, walls.beltDistance.isFinite, walls.beltDistance > 0 else { return nil }
            return walls.beltDistance
        }
    }

    /// True for a plane method (camera height or side walls) that is ready to use.
    var isPlaneReady: Bool { beltDistance != nil }

    /// Side walls: the part of the picture between the inner edges of the two wall bands (fractions of the buffer
    /// width); maps keep only these columns. Nil for other methods or before a wall calibration.
    var keptAcross: ClosedRange<Double>? {
        guard method == .sideWalls, let walls else { return nil }
        let a = walls.topBand.clamped.end
        let b = walls.bottomBand.clamped.start
        return a < b ? a...b : nil
    }

    /// The belt plane for a recording: the median phone tilt of its frames relative to the stored level zero
    /// (the wall calibration's tilt, then level, when the frames have none).
    func plane(frames: [LineFrameInfo]) -> HeightPlane? {
        guard let distance = beltDistance else { return nil }
        let zx = levelZeroX ?? 0
        let zy = levelZeroY ?? 0
        let xs = frames.compactMap { f in f.tiltX.map { $0 - zx } }.filter(\.isFinite)
        let ys = frames.compactMap { f in f.tiltY.map { $0 - zy } }.filter(\.isFinite)
        let tiltX = HeightMath.median(xs) ?? walls?.tiltX ?? 0
        let tiltY = HeightMath.median(ys) ?? walls?.tiltY ?? 0
        return HeightPlane(normal: HeightPlane.normal(tiltX: tiltX, tiltY: tiltY), distance: distance)
    }

    static var standardFolder: URL { Baseline.standardFolder }

    /// The reference saved in `folder`, nil if missing or unreadable.
    static func load(from folder: URL) -> HeightReference? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder.iso.decode(HeightReference.self, from: data)
    }

    func save(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Map summary line (a map line, replaced on rebuild).
    func summaryLine(plane: HeightPlane) -> String {
        let tiltX = asin(max(-1, min(1, plane.normal.y))) * 180 / .pi
        let tiltY = asin(max(-1, min(1, plane.normal.x))) * 180 / .pi
        let tilt = String(format: "phone tilt ↔ %+.1f° ↕ %+.1f° from the level zero", tiltX, tiltY)
        switch method {
        case .sideWalls:
            if let walls {
                return String(format: "Height reference: side walls, belt %.0f mm from the camera (walls %.0f mm "
                              + "high, the two walls differ by %.1f mm); %@", plane.distance, walls.wallHeight,
                              walls.disagreement, tilt)
            }
            return String(format: "Height reference: side walls, belt %.0f mm from the camera; %@",
                          plane.distance, tilt)
        default:
            return String(format: "Height reference: camera height %.0f mm; %@", plane.distance, tilt)
        }
    }
}

enum HeightMath {
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// Distance of the closest cluster of `values` (mm along the belt normal): seeded at the 5th percentile, then
    /// moved to the median of the values within ±`halfWindow` until it settles (a wall top is the closest surface
    /// in its band; mixed edge pixels and the belt or mat behind lie farther away). Nil with fewer than 50 finite
    /// positive values. `spread` = 1.4826 · median absolute deviation of the cluster.
    static func closestCluster(_ values: [Float], halfWindow: Double = 20)
        -> (distance: Double, readings: Int, spread: Double)? {
        let sorted = values.filter { $0.isFinite && $0 > 0 }.map(Double.init).sorted()
        guard sorted.count >= 50 else { return nil }
        func lowerBound(_ x: Double) -> Int {
            var lo = 0, hi = sorted.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if sorted[mid] < x { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        var center = sorted[min(sorted.count - 1, sorted.count / 20)]
        var range = 0..<0
        for _ in 0..<30 {
            let lo = lowerBound(center - halfWindow)
            let hi = lowerBound(center + halfWindow + 1e-9)
            guard hi > lo else { break }
            range = lo..<hi
            let window = sorted[range]
            let mid = window.count / 2
            let next = window.count % 2 == 1 ? window[window.startIndex + mid]
                : (window[window.startIndex + mid - 1] + window[window.startIndex + mid]) / 2
            let moved = abs(next - center)
            center = next
            if moved < 0.01 { break }
        }
        guard !range.isEmpty else { return nil }
        let deviations = sorted[range].map { abs($0 - center) }
        let mad = median(deviations) ?? 0
        return (center, range.count, 1.4826 * mad)
    }
}

/// Collects the wall-band readings of a side-wall calibration, one depth frame at a time (Line scan data queue).
struct WallCapture: Sendable {
    let target: Int
    let topBand: WallBand
    let bottomBand: WallBand
    let wallHeight: Double
    let zeroX: Double
    let zeroY: Double
    let filtered: Bool
    /// Frames delivered since the start, used or not.
    var seen = 0
    var frames = 0
    var width = 0
    var height = 0
    var top: [Float] = []
    var bottom: [Float] = []
    var tiltX: [Double] = []
    var tiltY: [Double] = []

    init(target: Int, topBand: WallBand, bottomBand: WallBand, wallHeight: Double, zeroX: Double, zeroY: Double,
         filtered: Bool) {
        self.target = target
        // The band nearer the top of the screen is the top wall.
        let a = topBand.clamped
        let b = bottomBand.clamped
        self.topBand = a.center <= b.center ? a : b
        self.bottomBand = a.center <= b.center ? b : a
        self.wallHeight = wallHeight
        self.zeroX = zeroX
        self.zeroY = zeroY
        self.filtered = filtered
    }

    var isComplete: Bool { frames >= target }

    /// Adds one depth frame (mm, planar, row-major width × height) with its intrinsics (depth pixels) and the phone's
    /// gravity tilt (degrees). A frame of another size than the first, or without a tilt, is skipped.
    mutating func add(depth: [Float], width: Int, height: Int, fx: Double, fy: Double, cx: Double, cy: Double,
                      tiltX: Double?, tiltY: Double?) {
        seen += 1
        guard let tx = tiltX, let ty = tiltY, tx.isFinite, ty.isFinite, fx > 0, fy > 0,
              width > 8, height > 8, depth.count >= width * height else { return }
        if frames == 0 {
            self.width = width
            self.height = height
        }
        guard width == self.width, height == self.height else { return }
        let rx = tx - zeroX
        let ry = ty - zeroY
        let n = HeightPlane.normal(tiltX: rx, tiltY: ry)
        let border = max(2, min(width, height) / 32)
        func collect(_ band: WallBand, into out: inout [Float]) {
            let columns = band.columns(width: width)
            for v in border..<(height - border) {
                let yn = (Double(v) - cy) / fy
                let base = v * width
                for u in columns {
                    let z = depth[base + u]
                    guard z > 0, z.isFinite else { continue }
                    let xn = (Double(u) - cx) / fx
                    out.append(Float(Double(z) * (n.x * xn + n.y * yn + n.z)))
                }
            }
        }
        collect(topBand, into: &top)
        collect(bottomBand, into: &bottom)
        self.tiltX.append(rx)
        self.tiltY.append(ry)
        frames += 1
    }

    /// The calibration, or an error that says what to fix.
    func build(date: Date = Date()) throws -> WallCalibration {
        guard frames > 0 else { throw WallCalibrationError.noFrames }
        guard let t = HeightMath.closestCluster(top), t.readings >= 100 else {
            throw WallCalibrationError.tooFewReadings("top")
        }
        guard let b = HeightMath.closestCluster(bottom), b.readings >= 100 else {
            throw WallCalibrationError.tooFewReadings("bottom")
        }
        guard wallHeight.isFinite, wallHeight > 0 else { throw WallCalibrationError.noWallHeight }
        let calibration = WallCalibration(
            date: date, wallHeight: wallHeight, topDistance: t.distance, bottomDistance: b.distance,
            topReadings: t.readings, bottomReadings: b.readings, topSpread: t.spread, bottomSpread: b.spread,
            tiltX: HeightMath.median(tiltX) ?? 0, tiltY: HeightMath.median(tiltY) ?? 0,
            depthWidth: width, depthHeight: height, filteredDepth: filtered, topBand: topBand, bottomBand: bottomBand)
        guard calibration.beltDistance > wallHeight, calibration.beltDistance < 10_000 else {
            throw WallCalibrationError.implausible(calibration.beltDistance)
        }
        return calibration
    }
}

enum WallCalibrationError: LocalizedError, Equatable {
    case noFrames
    case tooFewReadings(String)
    case noWallHeight
    case implausible(Double)
    case cancelled(String)

    var errorDescription: String? {
        switch self {
        case .noFrames:
            return "Calibration refused: no depth frames with a tilt reading arrived. Keep the phone still and try again."
        case .tooFewReadings(let which):
            return "Calibration refused: the \(which) wall band had too few steady LiDAR readings. Drag the band onto "
                + "the wall top (the closest, dark-red stripe in the depth picture) and try again."
        case .noWallHeight:
            return "Enter the wall height above the belt (mm) and tap Set first."
        case .implausible(let distance):
            return String(format: "Calibration refused: the belt would be %.0f mm from the camera. Check the wall "
                          + "height and that both bands are on the wall tops.", distance)
        case .cancelled(let reason):
            return "Calibration cancelled: \(reason). Tap Calibrate again when the phone is steady."
        }
    }
}

/// How depth readings become map values (design §16.4): distances, heights above the empty-belt baseline, or
/// heights above a belt plane (camera height or side walls).
struct MapHeightModel {
    enum Kind {
        case distance
        case baseline([Float])
        case plane(HeightPlane)
    }

    var kind: Kind
    var reference: HeightReference?
    /// Fractions of the buffer width kept in the map (side walls), nil = all.
    var keptAcross: ClosedRange<Double>?

    var isHeight: Bool {
        if case .distance = kind { return false }
        return true
    }

    var method: HeightReferenceMethod? {
        switch kind {
        case .distance: return nil
        case .baseline: return .emptyBelt
        case .plane: return reference?.method
        }
    }

    var plane: HeightPlane? {
        if case .plane(let p) = kind { return p }
        return nil
    }

    var baselineValues: [Float]? {
        if case .baseline(let values) = kind { return values }
        return nil
    }

    /// The model for a recording folder: a ready camera-height or side-wall reference (`HeightReference.json`)
    /// first, then a matching `Baseline.bin`, else distances.
    static func load(folder: URL, width: Int, height: Int, frames: [LineFrameInfo]) -> MapHeightModel {
        if let reference = HeightReference.load(from: folder), reference.method != .emptyBelt,
           let plane = reference.plane(frames: frames) {
            return MapHeightModel(kind: .plane(plane), reference: reference, keptAcross: reference.keptAcross)
        }
        if let baseline = Baseline.load(from: folder), baseline.matches(width: width, height: height) {
            return MapHeightModel(kind: .baseline(baseline.values), reference: nil, keptAcross: nil)
        }
        return MapHeightModel(kind: .distance, reference: nil, keptAcross: nil)
    }

    /// Depth columns used by a map `width` pixels wide with `border` columns skipped at each edge.
    func columns(width: Int, border: Int) -> Range<Int> {
        var lo = border
        var hi = width - border
        if let kept = keptAcross {
            lo = max(lo, Int((kept.lowerBound * Double(width)).rounded(.up)))
            hi = min(hi, Int((kept.upperBound * Double(width)).rounded(.down)))
        }
        return lo < hi ? lo..<hi : lo..<lo
    }

    /// Summary line for plane references (nil otherwise).
    var summaryLine: String? {
        guard let plane, let reference else { return nil }
        return reference.summaryLine(plane: plane)
    }
}
