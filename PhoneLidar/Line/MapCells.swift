import Foundation

/// How readings that land in the same map cell become the cell's value (design §13.2).
enum MapMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Mean of every reading that lands in the cell (every map built before P11).
    case averaged
    /// One reading per cell: the best-placed reading by the builder's score; nothing is averaged.
    case singleReading

    var id: String { rawValue }

    var label: String {
        switch self {
        case .averaged: return "Averaged"
        case .singleReading: return "Single frame (no averaging)"
        }
    }

    /// Tolerant: a value written by a newer build reads as `averaged`.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MapMethod(rawValue: raw) ?? .averaged
    }
}

/// Which sensor produced a map's values (design §14.6). Absent in maps written before P11 (LiDAR).
enum MapSensor: String, Codable, Sendable {
    case lidar
    case laserLine

    /// Tolerant: a value written by a newer build reads as `lidar`.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MapSensor(rawValue: raw) ?? .lidar
    }
}

/// Readings accumulated into a regular grid before the empty margin is trimmed (design §13.3).
/// Coordinates: q along the travel, x across, both mm; cell (r, c) covers [qMin + c·cell, qMin + (c+1)·cell) ×
/// [xMin + r·cell, xMin + (r+1)·cell). Values are kept relative to `zRef` (Float precision for distances).
struct MapCells {
    let method: MapMethod
    let columns: Int
    let rows: Int
    /// Cell size, mm.
    let cell: Double
    let qMin: Double
    let xMin: Double
    let zRef: Float
    /// `averaged`: running mean of value − zRef. `singleReading`: value − zRef of the kept reading.
    var means: [Float]
    /// `averaged`: Welford sum of squared differences. Empty for `singleReading`.
    var m2s: [Float]
    /// Readings in the cell (`singleReading`: 0 or 1).
    var hits: [UInt16]
    /// `singleReading`: score of the kept reading (lower = better placed). Empty for `averaged`.
    var scores: [Float]

    init(method: MapMethod, columns: Int, rows: Int, cell: Double, qMin: Double, xMin: Double, zRef: Float) {
        self.method = method
        self.columns = max(0, columns)
        self.rows = max(0, rows)
        self.cell = cell
        self.qMin = qMin
        self.xMin = xMin
        self.zRef = zRef
        let n = self.columns * self.rows
        means = [Float](repeating: 0, count: n)
        hits = [UInt16](repeating: 0, count: n)
        m2s = method == .averaged ? [Float](repeating: 0, count: n) : []
        scores = method == .singleReading ? [Float](repeating: .infinity, count: n) : []
    }

    var count: Int { columns * rows }

    /// Index of the cell holding (q, x), nil outside the grid (floor, not truncation: readings just below
    /// qMin/xMin are outside).
    func index(q: Double, x: Double) -> Int? {
        Self.index(q: q, x: x, qMin: qMin, xMin: xMin, cell: cell, columns: columns, rows: rows)
    }

    /// Centre (q, x) of cell `index`, mm.
    func center(ofIndex index: Int) -> (q: Double, x: Double) {
        let c = index % max(1, columns)
        let r = index / max(1, columns)
        return (qMin + (Double(c) + 0.5) * cell, xMin + (Double(r) + 0.5) * cell)
    }

    @inline(__always)
    static func index(q: Double, x: Double, qMin: Double, xMin: Double, cell: Double,
                      columns: Int, rows: Int) -> Int? {
        guard cell > 0 else { return nil }
        let c = ((q - qMin) / cell).rounded(.down)
        let r = ((x - xMin) / cell).rounded(.down)
        guard c >= 0, r >= 0, c < Double(columns), r < Double(rows) else { return nil }   // also rejects NaN
        return Int(r) * columns + Int(c)
    }

    /// Runs `body` with an accumulator that writes straight into the cell storage (no copy-on-write check per
    /// reading). The accumulator must not escape `body`.
    mutating func withAccumulator<R>(_ body: (Accumulator) throws -> R) rethrows -> R {
        let single = method == .singleReading
        let zRef = self.zRef
        let geometry = (qMin, xMin, cell, columns, rows)
        return try means.withUnsafeMutableBufferPointer { meanBuf in
            try m2s.withUnsafeMutableBufferPointer { m2Buf in
                try hits.withUnsafeMutableBufferPointer { hitBuf in
                    try scores.withUnsafeMutableBufferPointer { scoreBuf in
                        try body(Accumulator(single: single, zRef: zRef, qMin: geometry.0, xMin: geometry.1,
                                             cell: geometry.2, columns: geometry.3, rows: geometry.4,
                                             means: meanBuf, m2s: m2Buf, hits: hitBuf, scores: scoreBuf))
                    }
                }
            }
        }
    }

    /// Writes readings into a `MapCells` storage during `withAccumulator`.
    struct Accumulator {
        let single: Bool
        let zRef: Float
        let qMin: Double
        let xMin: Double
        let cell: Double
        let columns: Int
        let rows: Int
        let means: UnsafeMutableBufferPointer<Float>
        let m2s: UnsafeMutableBufferPointer<Float>
        let hits: UnsafeMutableBufferPointer<UInt16>
        let scores: UnsafeMutableBufferPointer<Float>

        @inline(__always)
        func index(q: Double, x: Double) -> Int? {
            MapCells.index(q: q, x: x, qMin: qMin, xMin: xMin, cell: cell, columns: columns, rows: rows)
        }

        /// Adds a reading (absolute value, mm) to cell `index`. `averaged`: running mean and variance (Welford),
        /// at most 65,535 readings per cell. `singleReading`: the reading replaces the cell's when the cell is empty
        /// or `score` is strictly lower, so of equal scores the first one stays.
        @inline(__always)
        func add(_ value: Float, at index: Int, score: Float) {
            guard value.isFinite else { return }
            let n = hits[index]
            let d = value - zRef
            if single {
                if n == 0 || score < scores[index] {
                    means[index] = d
                    hits[index] = 1
                    scores[index] = score
                }
            } else {
                if n == UInt16.max { return }
                let k = Float(n) + 1
                let delta = d - means[index]
                means[index] += delta / k
                m2s[index] += delta * (d - means[index])
                hits[index] = n + 1
            }
        }
    }
}

/// Pure helpers of the single-frame LiDAR map (design §13.3–§13.4).
enum ScanLineMath {
    /// Share of identical pixels at or above which a depth frame repeats the previous one.
    static let repeatFraction = 0.90
    /// Pixels valid in both frames needed before a frame can count as a repeat.
    static let repeatMinimumPixels = 100

    /// Pixels with a reading (> 0) in both frames, and how many of them hold exactly the same value.
    static func identicalCount(_ frame: [Float], _ previous: [Float]) -> (same: Int, both: Int) {
        let n = min(frame.count, previous.count)
        var same = 0
        var both = 0
        frame.withUnsafeBufferPointer { a in
            previous.withUnsafeBufferPointer { b in
                for i in 0..<n {
                    let x = a[i]
                    let y = b[i]
                    if x > 0 && y > 0 {
                        both += 1
                        if x == y { same += 1 }
                    }
                }
            }
        }
        return (same, both)
    }

    /// True when `frame` repeats `previous` (older laser data delivered again): at least `repeatMinimumPixels`
    /// pixels valid in both and at least `repeatFraction` of them identical. Depth.bin stores 0.1 mm steps, so
    /// equal readings are exactly equal after decoding.
    static func isRepeat(_ frame: [Float], previous: [Float]) -> Bool {
        let counts = identicalCount(frame, previous)
        guard counts.both >= repeatMinimumPixels else { return false }
        return Double(counts.same) >= repeatFraction * Double(counts.both)
    }

    /// The scan line: the depth row nearest the principal point row `cy` (where the view looks straight down),
    /// kept inside the border.
    static func scanRow(cy: Float, height: Int, border: Int) -> Int {
        let lo = border
        let hi = max(lo, height - 1 - border)
        guard cy.isFinite else { return (lo + hi) / 2 }
        return min(hi, max(lo, Int(cy.rounded())))
    }
}

/// One frame's scan-row readings for `ScanLineProfiles.csv`: across positions (mm, from each pixel's own
/// distance) and values (height or distance, mm), pixels with a reading only.
struct ScanRowSample {
    var frame: Int
    var time: Double
    var travel: Double
    var repeated: Bool
    var across: [Float] = []
    var values: [Float] = []
}

/// `ScanLineProfiles.csv` of a single-reading LiDAR map (design §13.5).
enum ScanLineProfiles {
    static let fileName = "ScanLineProfiles.csv"

    /// For each map row, the value of the sample nearest the row centre (within half a cell), else nil.
    static func profile(_ sample: ScanRowSample, geometry: TopoMapBuilder.Geometry) -> [Float?] {
        let rows = geometry.rows
        guard rows > 0, geometry.cell > 0 else { return [] }
        var best = [Float?](repeating: nil, count: rows)
        var distance = [Double](repeating: .infinity, count: rows)
        for (k, x) in sample.across.enumerated() where k < sample.values.count {
            let offset = (Double(x) - geometry.xMin) / geometry.cell
            let r = offset.rounded(.down)
            guard r >= 0, r < Double(rows) else { continue }
            let row = Int(r)
            let d = abs(offset - (r + 0.5))          // in cells, ≤ 0.5 inside the row
            if d < distance[row] {
                distance[row] = d
                best[row] = sample.values[k]
            }
        }
        return best
    }

    static func header(geometry: TopoMapBuilder.Geometry) -> [String] {
        var header = ["frame", "time_s", "travel_mm", "repeated"]
        header.reserveCapacity(4 + geometry.rows)
        let label = abs(geometry.cell - geometry.cell.rounded()) < 1e-9 ? "%.0f" : "%.2f"
        for r in 0..<geometry.rows {
            header.append(String(format: label, geometry.xMin + (Double(r) + 0.5) * geometry.cell))
        }
        return header
    }

    static func write(_ samples: [ScanRowSample], geometry: TopoMapBuilder.Geometry, to url: URL) throws {
        let writer = try TextFileWriter(url: url)
        try writer.line(header(geometry: geometry).joined(separator: ","))
        var fields = [String]()
        fields.reserveCapacity(4 + geometry.rows)
        for sample in samples {
            fields.removeAll(keepingCapacity: true)
            fields.append("\(sample.frame)")
            fields.append(String(format: "%.4f", sample.time))
            fields.append(String(format: "%.2f", sample.travel))
            fields.append(sample.repeated ? "1" : "0")
            for value in profile(sample, geometry: geometry) {
                if let value, value.isFinite {
                    fields.append(String(format: "%.1f", value))
                } else {
                    fields.append("")
                }
            }
            try writer.line(fields.joined(separator: ","))
        }
        try writer.close()
    }
}
