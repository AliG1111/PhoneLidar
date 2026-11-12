import Foundation

/// Columns of a laser profile in the video buffer: u = first + k·stride for k in 0..<count (design §14.3).
struct LaserColumns: Codable, Equatable, Sendable {
    var first: Int
    var stride: Int
    var count: Int

    /// Every `stride`-th column of a buffer `width` pixels wide, starting at stride / 2 (centred in each step).
    static func make(width: Int, stride: Int = 2) -> LaserColumns {
        let s = max(1, stride)
        let first = s / 2
        let count = width > first ? (width - first + s - 1) / s : 0
        return LaserColumns(first: first, stride: s, count: count)
    }

    /// Buffer column of profile column `k`.
    @inline(__always)
    func u(_ k: Int) -> Int { first + k * stride }
}

/// Finds the laser line in a luma plane: per column the brightest row of a band, checked against the local
/// background, refined to a sub-pixel centre of gravity (design §14.3). Pure; called on the capture data queue.
enum LaserLineDetector {
    /// Peak above the darkest value near it (grey levels) needed for a detection.
    static let minContrast = 30
    /// Rows on each side of the peak searched for the background.
    static let backgroundRadius = 12
    /// Rows on each side of the peak that can count towards the centre.
    static let maxHalfWidth = 10

    struct Result {
        /// Sub-pixel buffer row of the line per profile column (NaN = no detection).
        var rows: [Float]
        var detected: Int

        var detectedFraction: Double { rows.isEmpty ? 0 : Double(detected) / Double(rows.count) }
    }

    /// Detects the line in rows [rowLo, rowHi) of an 8-bit luma plane (`rowBytes` per row).
    static func detect(luma: UnsafePointer<UInt8>, width: Int, height: Int, rowBytes: Int, columns: LaserColumns,
                       rowLo: Int, rowHi: Int, minContrast: Int = minContrast) -> Result {
        let n = max(0, columns.count)
        var rows = [Float](repeating: .nan, count: n)
        let lo = max(0, rowLo)
        let hi = min(height, rowHi)
        // Columns inside the buffer (u increases with k, so they are a prefix).
        var usable = 0
        while usable < n && columns.u(usable) < width && columns.u(usable) >= 0 { usable += 1 }
        guard hi - lo >= 3, usable > 0, rowBytes >= width else { return Result(rows: rows, detected: 0) }

        // Pass 1, row by row (contiguous memory): brightest value and its first row per column.
        var peak = [UInt8](repeating: 0, count: usable)
        var arg = [Int32](repeating: -1, count: usable)
        peak.withUnsafeMutableBufferPointer { peakBuf in
            arg.withUnsafeMutableBufferPointer { argBuf in
                for v in lo..<hi {
                    let row = luma + v * rowBytes
                    var u = columns.first
                    for k in 0..<usable {
                        let value = row[u]
                        if value > peakBuf[k] {
                            peakBuf[k] = value
                            argBuf[k] = Int32(v)
                        }
                        u += columns.stride
                    }
                }
            }
        }

        // Pass 2, per column: background, contrast check and centre of gravity above half-height.
        var detected = 0
        for k in 0..<usable {
            let v0 = Int(arg[k])
            guard v0 >= 0 else { continue }
            let u = columns.u(k)
            let p = Int(peak[k])
            var background = p
            let bLo = max(lo, v0 - backgroundRadius)
            let bHi = min(hi - 1, v0 + backgroundRadius)
            for v in bLo...bHi {
                background = min(background, Int(luma[v * rowBytes + u]))
            }
            guard p - background >= minContrast else { continue }
            let threshold = Double(background) + Double(p - background) / 2
            var weight = Double(p) - threshold
            var moment = Double(v0) * weight
            var v = v0 - 1
            while v >= lo && v >= v0 - maxHalfWidth {
                let w = Double(luma[v * rowBytes + u]) - threshold
                if w <= 0 { break }
                weight += w
                moment += Double(v) * w
                v -= 1
            }
            v = v0 + 1
            while v < hi && v <= v0 + maxHalfWidth {
                let w = Double(luma[v * rowBytes + u]) - threshold
                if w <= 0 { break }
                weight += w
                moment += Double(v) * w
                v += 1
            }
            guard weight > 0 else { continue }
            rows[k] = Float(moment / weight)
            detected += 1
        }
        return Result(rows: rows, detected: detected)
    }

    /// Same as `detect(luma:…)` on an array (tests, synthetic images).
    static func detect(pixels: [UInt8], width: Int, height: Int, columns: LaserColumns, rowLo: Int = 0,
                       rowHi: Int? = nil, minContrast: Int = minContrast) -> Result {
        guard pixels.count >= width * height, width > 0, height > 0 else {
            return Result(rows: [Float](repeating: .nan, count: max(0, columns.count)), detected: 0)
        }
        return pixels.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                return Result(rows: [Float](repeating: .nan, count: max(0, columns.count)), detected: 0)
            }
            return detect(luma: base, width: width, height: height, rowBytes: width, columns: columns,
                          rowLo: rowLo, rowHi: rowHi ?? height, minContrast: minContrast)
        }
    }
}
