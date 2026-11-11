import Foundation

/// Summary of a flat-surface baseline calibration.
struct BaselineInfo: Codable {
    var width: Int
    var height: Int
    var created: Date
    var frames: Int
    /// Mean distance from the camera to the flat surface, mm.
    var meanDistance: Double
    /// How much the flat surface read across the view before correction (std dev and P1–P99 range), mm.
    var rawStdDev: Double
    var rawRange: Double
    /// Std dev across the view of the verification frames after correction, mm (≈ 0 is perfect).
    var correctedStdDev: Double
    var coveragePercent: Double
    var tiltX: Double?
    var tiltY: Double?
    var filteredDepth: Bool
}

/// Why a baseline calibration was not accepted.
enum BaselineError: LocalizedError {
    case notEnoughFrames
    case lowCoverage(percent: Double)
    case cancelled(String)

    var errorDescription: String? {
        switch self {
        case .notEnoughFrames:
            return "Calibration failed: not enough LiDAR readings. Check the surface is in view and 0.3–4 m away."
        case .lowCoverage(let percent):
            return String(format: "Calibration refused: only %.0f %% of the view had steady LiDAR readings (at least %.0f %% needed). "
                          + "Make sure the whole picture shows the empty flat surface, 0.3–4 m away, with nothing moving, then try again.",
                          percent, Baseline.minimumCoveragePercent)
        case .cancelled(let reason):
            return "Calibration cancelled: \(reason). Tap Calibrate again when the phone is steady."
        }
    }
}

/// Per-pixel distance to an empty, flat reference surface. Heights are measured above it:
/// height = baseline − distance (mm, positive = closer to the camera than the surface).
final class Baseline: @unchecked Sendable {
    static let fileName = "Baseline.bin"
    static let infoName = "Baseline.json"
    /// Calibrations with fewer pixels that had steady readings are refused.
    static let minimumCoveragePercent = 50.0
    /// Below this coverage the screen warns that much of the baseline comes from the fitted plane.
    static let goodCoveragePercent = 80.0

    let info: BaselineInfo
    /// mm per depth pixel, row-major info.width × info.height.
    let values: [Float]

    init(info: BaselineInfo, values: [Float]) {
        self.info = info
        self.values = values
    }

    /// Where the current calibration is kept (also visible in the Files app).
    static var standardFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Calibration", isDirectory: true)
    }

    /// The baseline saved in `folder`, or nil if it is missing or invalid. Width and height must be positive and at
    /// most `DepthFileReader.maxDimension` (a hand-edited Baseline.json can hold any numbers: the byte count is
    /// checked for overflow, Z-4), and Baseline.bin must hold exactly width × height Float32 values.
    static func load(from folder: URL) -> Baseline? {
        guard let infoData = try? Data(contentsOf: folder.appendingPathComponent(infoName)),
              let info = try? JSONDecoder.iso.decode(BaselineInfo.self, from: infoData),
              let bytes = expectedByteCount(width: info.width, height: info.height),
              let raw = try? Data(contentsOf: folder.appendingPathComponent(fileName)),
              raw.count == bytes else { return nil }
        let values: [Float] = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return Baseline(info: info, values: values)
    }

    /// Bytes of Baseline.bin for a width × height map, or nil for a size no LiDAR depth map has.
    static func expectedByteCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0,
              width <= DepthFileReader.maxDimension, height <= DepthFileReader.maxDimension else { return nil }
        let pixels = width.multipliedReportingOverflow(by: height)
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !pixels.overflow, !bytes.overflow else { return nil }
        return bytes.partialValue
    }

    func save(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let raw = values.withUnsafeBytes { Data($0) }
        try raw.write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
        try JSONEncoder.pretty.encode(info).write(to: folder.appendingPathComponent(Self.infoName), options: .atomic)
    }

    static func delete(from folder: URL) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(fileName))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(infoName))
    }

    func matches(width: Int, height: Int) -> Bool {
        info.width == width && info.height == height
    }

    /// Heights above the baseline for a whole frame (NaN = no data).
    func heights(_ millimetres: [Float]) -> [Float] {
        let count = min(millimetres.count, values.count)
        var out = [Float](repeating: .nan, count: millimetres.count)
        for i in 0..<count {
            let z = millimetres[i]
            let b = values[i]
            if z > 0 && b > 0 { out[i] = b - z }
        }
        return out
    }

    /// Median baseline distance in a window around (u, v).
    func sample(u: Int, v: Int, radius: Int) -> Float? {
        DepthFileReader.sample(values, width: info.width, height: info.height, u: u, v: v, radius: radius)
    }

    /// Builds a baseline from frames of the empty flat surface. The last `verify` frames are not used
    /// for the baseline; they measure how flat the corrected result is.
    /// Pixels with too few readings (LiDAR dropouts, dark or shiny spots, edges) are filled from a plane
    /// fitted to the pixels that had readings; `coveragePercent` is the share that had readings.
    /// Throws when fewer than `minimumCoveragePercent` of the pixels had readings.
    static func build(frames: [[Float]], width: Int, height: Int, verify: Int,
                      tiltX: Double?, tiltY: Double?, filtered: Bool) throws -> Baseline {
        let pixelCount = width * height
        let usable = frames.filter { $0.count == pixelCount }
        guard usable.count >= 10, pixelCount > 0 else { throw BaselineError.notEnoughFrames }
        let verifyCount = min(verify, usable.count / 3)
        let buildFrames = Array(usable.prefix(usable.count - verifyCount))
        let verifyFrames = Array(usable.suffix(verifyCount))

        // Per-pixel trimmed mean (middle half of the readings).
        var values = [Float](repeating: 0, count: pixelCount)
        var column: [Float] = []
        column.reserveCapacity(buildFrames.count)
        let minimumReadings = max(3, buildFrames.count / 3)
        var validCount = 0
        for i in 0..<pixelCount {
            column.removeAll(keepingCapacity: true)
            for frame in buildFrames {
                let z = frame[i]
                if z > 0 { column.append(z) }
            }
            guard column.count >= minimumReadings else { continue }
            column.sort()
            let lo = column.count / 4
            let hi = max(lo + 1, column.count - column.count / 4)
            var sum: Float = 0
            for k in lo..<hi { sum += column[k] }
            values[i] = sum / Float(hi - lo)
            validCount += 1
        }
        let coverage = 100 * Double(validCount) / Double(pixelCount)
        guard validCount > 0, coverage >= minimumCoveragePercent else {
            throw BaselineError.lowCoverage(percent: coverage)
        }

        // Spread of the flat surface across the view, before correction.
        var valid: [Float] = []
        valid.reserveCapacity(validCount)
        for v in values where v > 0 { valid.append(v) }
        let mean = valid.reduce(0.0) { $0 + Double($1) } / Double(valid.count)
        let variance = valid.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(valid.count)
        let sorted = valid.sorted()
        let p1 = Double(sorted[Int(Double(sorted.count - 1) * 0.01)])
        let p99 = Double(sorted[Int(Double(sorted.count - 1) * 0.99)])

        // Fill pixels without enough readings from a plane fitted to the rest (pixel coordinates).
        if validCount < pixelCount, let plane = fitPlane(values, width: width, height: height) {
            for v in 0..<height {
                for u in 0..<width where values[v * width + u] <= 0 {
                    let z = plane.a * Double(u) + plane.b * Double(v) + plane.c
                    if z.isFinite, z > 0, z < 65_000 { values[v * width + u] = Float(z) }
                }
            }
        }

        // Flatness after correction, measured on frames not used for the baseline.
        let check = verifyFrames.isEmpty ? Array(buildFrames.suffix(10)) : verifyFrames
        var stdSum = 0.0
        var stdN = 0
        for frame in check {
            var s = 0.0, ss = 0.0, n = 0.0
            var i = 0
            while i < pixelCount {
                let z = frame[i]
                let b = values[i]
                if z > 0 && b > 0 {
                    let h = Double(b - z)
                    s += h
                    ss += h * h
                    n += 1
                }
                i += 2
            }
            if n > 10 {
                let m = s / n
                stdSum += max(0, ss / n - m * m).squareRoot()
                stdN += 1
            }
        }

        let info = BaselineInfo(width: width, height: height, created: Date(), frames: usable.count,
                                meanDistance: mean, rawStdDev: variance.squareRoot(), rawRange: p99 - p1,
                                correctedStdDev: stdN > 0 ? stdSum / Double(stdN) : 0,
                                coveragePercent: coverage,
                                tiltX: tiltX, tiltY: tiltY, filteredDepth: filtered)
        return Baseline(info: info, values: values)
    }

    /// Least-squares plane z = a·u + b·v + c through the valid (> 0) values.
    private static func fitPlane(_ values: [Float], width: Int, height: Int) -> (a: Double, b: Double, c: Double)? {
        var n = 0.0, su = 0.0, sv = 0.0, sz = 0.0
        var suu = 0.0, svv = 0.0, suv = 0.0, suz = 0.0, svz = 0.0
        for v in Swift.stride(from: 0, to: height, by: 2) {
            for u in Swift.stride(from: 0, to: width, by: 2) {
                let z = Double(values[v * width + u])
                guard z > 0 else { continue }
                let du = Double(u), dv = Double(v)
                n += 1; su += du; sv += dv; sz += z
                suu += du * du; svv += dv * dv; suv += du * dv; suz += du * z; svz += dv * z
            }
        }
        guard n >= 3 else { return nil }
        return solve3([[suu, suv, su], [suv, svv, sv], [su, sv, n]], [suz, svz, sz])
    }

    /// Cramer's rule for a 3×3 linear system.
    static func solve3(_ m: [[Double]], _ r: [Double]) -> (a: Double, b: Double, c: Double)? {
        func det(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1])
                - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let d = det(m)
        guard abs(d) > 1e-12 else { return nil }
        var ma = m, mb = m, mc = m
        for i in 0..<3 {
            ma[i][0] = r[i]
            mb[i][1] = r[i]
            mc[i][2] = r[i]
        }
        return (det(ma) / d, det(mb) / d, det(mc) / d)
    }

    /// One-line description for the screen.
    var summary: String {
        String(format: "Baseline %.0f mm away · flat surface spread %.1f mm σ (%.1f mm range) → %.2f mm σ after correction",
               info.meanDistance, info.rawStdDev, info.rawRange, info.correctedStdDev)
    }
}
