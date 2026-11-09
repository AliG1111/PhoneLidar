import Foundation
import SwiftUI
import simd

// MARK: - Colour scale

/// Replay colour scale: blue = below target, green = on target, yellow → red = above target.
/// The stops are sampled from the colour bar of the X-ray mat-density replay so both look the same.
enum ReplayPalette {
    static let stops: [(position: Float, rgb: SIMD3<Float>)] = [
        (0.000, SIMD3<Float>(30, 66, 207)),
        (0.167, SIMD3<Float>(38, 121, 154)),
        (0.333, SIMD3<Float>(50, 175, 100)),
        (0.500, SIMD3<Float>(79, 212, 43)),
        (0.667, SIMD3<Float>(166, 230, 54)),
        (0.750, SIMD3<Float>(209, 230, 53)),
        (0.833, SIMD3<Float>(218, 169, 43)),
        (0.917, SIMD3<Float>(227, 108, 35)),
        (1.000, SIMD3<Float>(230, 51, 28))
    ]

    /// Colour at t (0 = low end, 1 = high end), components 0…1.
    static func rgb(_ t: Float) -> SIMD3<Float> {
        let c = min(max(t, 0), 1)
        for k in 1..<stops.count where c <= stops[k].position {
            let a = stops[k - 1]
            let b = stops[k]
            let f = (c - a.position) / max(b.position - a.position, 1e-6)
            return (a.rgb + (b.rgb - a.rgb) * f) / 255
        }
        return stops[stops.count - 1].rgb / 255
    }

    static let lut: [SIMD4<Float>] = (0..<256).map { i in
        let c = rgb(Float(i) / 255)
        return SIMD4<Float>(c.x, c.y, c.z, 1)
    }

    static let noData = SIMD4<Float>(0.80, 0.80, 0.80, 1)

    static func color(_ t: Float) -> Color {
        let c = rgb(t)
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    /// Gradient for the colour bar, low (left) → high (right).
    static let gradient: [Color] = (0...24).map { color(Float($0) / 24) }
}

// MARK: - Replay source

/// Everything the replay needs, prepared once when the screen opens: the topographic grid re-ordered so that
/// column 0 is the oldest material and the last column the newest, and the position of the newest complete
/// line at every frame.
struct TopoReplaySource: Sendable {
    /// Values are heights above the flat-surface baseline (true) or relative heights from distances (false).
    let heightMode: Bool
    /// Distance from the camera (mm) that relative height 0 refers to (distance mode only).
    let referenceDistance: Double
    /// Grid cell size, mm.
    let cell: Double
    /// Rows across the material: row 0 = top of the recording screen.
    let rows: Int
    /// Columns along the travel: column 0 = oldest material, last column = newest.
    let columns: Int
    /// rows × columns heights (mm), NaN = no data.
    let values: [Float]
    /// Travel coordinate (mm, increases toward newer material) of the left edge of column 0.
    let pStart: Double
    /// Across position (mm from the image centre line) of the top edge of row 0.
    let acrossStart: Double

    let frameTimes: [Double]
    /// Per frame: travel coordinate of the newest line whose LiDAR readings are complete (it has left the
    /// camera's view). Never decreases.
    let revealP: [Double]
    let speeds: [Double?]
    let recordingDuration: Double
    /// Travel speed used after the last frame to bring the rest of the recorded material out (mm/s, 0 = none).
    let runOutSpeed: Double
    /// Replay length including the run-out, s.
    let duration: Double

    /// Median and robust standard deviation of all heights, mm.
    let median: Double
    let robustStdDev: Double
    let p01: Double
    let p99: Double

    var pEnd: Double { pStart + Double(columns) * cell }
    var widthMM: Double { Double(rows) * cell }

    static func make(grid: TopoGridFile, info: LineRecordingInfo) throws -> TopoReplaySource {
        let sign = info.direction.bufferSign
        let srcColumns = grid.columns
        let srcRows = grid.rows
        guard !info.frames.isEmpty, srcColumns >= 2, srcRows >= 2 else { throw LineError.notEnoughData }

        // Distances become relative heights (+ = closer to the camera than the typical surface).
        var reference = 0.0
        if !grid.heightMode {
            let step = max(1, grid.values.count / 200_000)
            var samples: [Float] = []
            var i = 0
            while i < grid.values.count {
                if grid.values[i].isFinite { samples.append(grid.values[i]) }
                i += step
            }
            guard !samples.isEmpty else { throw LineError.notEnoughData }
            samples.sort()
            reference = Double(samples[samples.count / 2])
        }
        let referenceF = Float(reference)
        let heightMode = grid.heightMode

        // Keep the rows that were covered and the columns that hold data.
        var rowCount = [Int](repeating: 0, count: srcRows)
        var columnCount = [Int](repeating: 0, count: srcColumns)
        grid.values.withUnsafeBufferPointer { values in
            for r in 0..<srcRows {
                let base = r * srcColumns
                for c in 0..<srcColumns where values[base + c].isFinite {
                    rowCount[r] += 1
                    columnCount[c] += 1
                }
            }
        }
        let rowLimit = max(1, Int(Double(rowCount.max() ?? 0) * 0.3))
        guard let r0 = rowCount.firstIndex(where: { $0 >= rowLimit }),
              let r1 = rowCount.lastIndex(where: { $0 >= rowLimit }),
              let c0 = columnCount.firstIndex(where: { $0 > 0 }),
              let c1 = columnCount.lastIndex(where: { $0 > 0 }),
              r1 > r0 + 1, c1 > c0 + 1 else { throw LineError.notEnoughData }
        let rows = r1 - r0 + 1
        let columns = c1 - c0 + 1

        var values = [Float](repeating: .nan, count: rows * columns)
        grid.values.withUnsafeBufferPointer { src in
            values.withUnsafeMutableBufferPointer { dst in
                for r in 0..<rows {
                    let srcBase = (r0 + r) * srcColumns
                    let dstBase = r * columns
                    for j in 0..<columns {
                        let c = sign > 0 ? c0 + j : c1 - j
                        let v = src[srcBase + c]
                        if v.isFinite { dst[dstBase + j] = heightMode ? v : referenceF - v }
                    }
                }
            }
        }
        // Travel coordinate p = sign · q: always increases toward newer material.
        let pStart = sign > 0
            ? grid.qMin + Double(c0) * grid.cell
            : -(grid.qMin + Double(c1 + 1) * grid.cell)
        let acrossStart = grid.xMin + Double(r0) * grid.cell

        // Newest complete line per frame: the downstream edge of the LiDAR's view.
        let frames = info.frames
        let border = TopoMapBuilder.border(width: info.depthWidth, height: info.depthHeight)
        let depths = frames.map(\.medianDepth).filter { $0 > 0 }.sorted()
        let zTypical = depths.isEmpty ? 1000 : depths[depths.count / 2]
        var reveal = [Double](repeating: .nan, count: frames.count)
        var running = -Double.infinity
        for (i, f) in frames.enumerated() {
            if f.fy > 0 {
                let z = f.medianDepth > 0 ? f.medianDepth : zTypical
                let row = sign > 0 ? Double(info.depthHeight - 1 - border) : Double(border)
                let yDown = (row - Double(f.cy)) * z / Double(f.fy)
                running = max(running, f.travel - Double(sign) * yDown)
            }
            reveal[i] = running
        }
        guard let firstValid = reveal.firstIndex(where: { $0.isFinite }) else { throw LineError.notEnoughData }
        for i in 0..<firstValid { reveal[i] = reveal[firstValid] }

        let times = frames.map(\.time)
        let recordingDuration = max(times.last ?? 0, 0.01)

        // Speed for the run-out: travel over the last second, else over the whole recording.
        var runOut = 0.0
        if let last = frames.last {
            let startIndex = LineMath.frameIndex(for: last.time - 1.0, in: frames)
            let a = frames[startIndex]
            if last.time - a.time > 0.2 {
                runOut = (last.travel - a.travel) / (last.time - a.time)
            }
            if !(runOut > 1), last.time > 0.2 {
                runOut = (last.travel - frames[0].travel) / (last.time - frames[0].time)
            }
            if !(runOut > 1) || !runOut.isFinite { runOut = 0 }
        }
        let pEnd = pStart + Double(columns) * grid.cell
        let remaining = max(0, pEnd - (reveal.last ?? pEnd))
        let runOutTime = runOut > 1 ? min(60, remaining / runOut) : 0
        let duration = recordingDuration + runOutTime

        // Height statistics for the default target and tolerance.
        let step = max(1, values.count / 200_000)
        var samples: [Float] = []
        var k = 0
        while k < values.count {
            if values[k].isFinite { samples.append(values[k]) }
            k += step
        }
        guard samples.count >= 10 else { throw LineError.notEnoughData }
        samples.sort()
        func percentile(_ p: Double) -> Double {
            Double(samples[min(samples.count - 1, max(0, Int((Double(samples.count - 1) * p).rounded())))])
        }
        let median = percentile(0.5)
        let robust = max((percentile(0.84) - percentile(0.16)) / 2, 0.05)

        return TopoReplaySource(heightMode: heightMode, referenceDistance: reference, cell: grid.cell,
                                rows: rows, columns: columns, values: values, pStart: pStart,
                                acrossStart: acrossStart, frameTimes: times, revealP: reveal,
                                speeds: LineMath.smoothed(frames.map(\.speed), radius: 7),
                                recordingDuration: recordingDuration, runOutSpeed: runOut, duration: duration,
                                median: median, robustStdDev: robust,
                                p01: percentile(0.01), p99: percentile(0.99))
    }

    /// Travel coordinate of the newest complete line at replay time t.
    func revealPosition(at t: Double) -> Double {
        guard let last = revealP.last else { return pEnd }
        if t >= recordingDuration {
            if runOutSpeed > 1 { return min(pEnd, last + (t - recordingDuration) * runOutSpeed) }
            return t >= duration ? pEnd : last
        }
        if t <= (frameTimes.first ?? 0) { return revealP[0] }
        let i = Self.index(for: t, in: frameTimes)
        guard i + 1 < frameTimes.count else { return last }
        let t0 = frameTimes[i]
        let t1 = frameTimes[i + 1]
        let f = t1 > t0 ? (t - t0) / (t1 - t0) : 0
        return revealP[i] + (revealP[i + 1] - revealP[i]) * f
    }

    /// Replay time at which the line at travel coordinate p becomes complete.
    func revealTime(of p: Double) -> Double {
        guard let last = revealP.last else { return 0 }
        if p <= revealP[0] { return frameTimes.first ?? 0 }
        if p > last {
            return runOutSpeed > 1 ? min(duration, recordingDuration + (p - last) / runOutSpeed) : duration
        }
        // First frame whose reveal position reaches p (reveal positions never decrease).
        var lo = 0
        var hi = revealP.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if revealP[mid] >= p { hi = mid } else { lo = mid + 1 }
        }
        guard lo > 0 else { return frameTimes[0] }
        let p0 = revealP[lo - 1]
        let p1 = revealP[lo]
        let f = p1 > p0 ? (p - p0) / (p1 - p0) : 1
        return frameTimes[lo - 1] + (frameTimes[lo] - frameTimes[lo - 1]) * f
    }

    func frameIndex(at t: Double) -> Int {
        Self.index(for: min(t, recordingDuration), in: frameTimes)
    }

    private static func index(for t: Double, in times: [Double]) -> Int {
        guard !times.isEmpty else { return 0 }
        var lo = 0
        var hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if times[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

// MARK: - Display grid

/// The replay grid averaged into square blocks of `factor` × `factor` cells, small enough to rebuild the
/// 3D surface every screen refresh. Gaps are filled from neighbouring cells.
struct TopoDisplayGrid: Sendable {
    let factor: Int
    let rows: Int
    let columns: Int
    /// Block size, mm.
    let cellMM: Double
    let pStart: Double
    /// rows × columns heights, mm (NaN = no data).
    let raw: [Float]
    /// 3 × 3 smoothed copy of `raw`.
    let smooth: [Float]
    /// Mean height of each column (NaN = no data).
    let columnMean: [Float]
    /// Replay time at which each column becomes complete.
    let revealTime: [Double]

    /// Travel coordinate of a column centre.
    func p(ofColumn j: Int) -> Double { pStart + (Double(j) + 0.5) * cellMM }

    static func make(source: TopoReplaySource, factor: Int) -> TopoDisplayGrid {
        let k = max(1, factor)
        let rows = max(1, source.rows / k)
        let columns = max(1, (source.columns + k - 1) / k)
        var raw = [Float](repeating: .nan, count: rows * columns)
        source.values.withUnsafeBufferPointer { src in
            raw.withUnsafeMutableBufferPointer { dst in
                for row in 0..<rows {
                    let rLo = row * k
                    let rHi = row == rows - 1 ? source.rows : min(source.rows, rLo + k)
                    for col in 0..<columns {
                        let cLo = col * k
                        let cHi = min(source.columns, cLo + k)
                        var sum: Float = 0
                        var n = 0
                        for r in rLo..<rHi {
                            let base = r * source.columns
                            for c in cLo..<cHi {
                                let v = src[base + c]
                                if v.isFinite {
                                    sum += v
                                    n += 1
                                }
                            }
                        }
                        if n > 0 { dst[row * columns + col] = sum / Float(n) }
                    }
                }
            }
        }
        fillGaps(&raw, rows: rows, columns: columns)
        let smooth = smoothed(raw, rows: rows, columns: columns)

        var means = [Float](repeating: .nan, count: columns)
        for col in 0..<columns {
            var sum: Float = 0
            var n = 0
            for row in 0..<rows {
                let v = raw[row * columns + col]
                if v.isFinite {
                    sum += v
                    n += 1
                }
            }
            if n > 0 { means[col] = sum / Float(n) }
        }
        let cellMM = source.cell * Double(k)
        let times = (0..<columns).map { source.revealTime(of: source.pStart + (Double($0) + 0.5) * cellMM) }
        return TopoDisplayGrid(factor: k, rows: rows, columns: columns, cellMM: cellMM, pStart: source.pStart,
                               raw: raw, smooth: smooth, columnMean: means, revealTime: times)
    }

    /// Linear interpolation across each column, then along each row for gaps up to 8 blocks.
    private static func fillGaps(_ values: inout [Float], rows: Int, columns: Int) {
        func fill(count: Int, maxGap: Int, index: (Int) -> Int) {
            var last = -1
            for i in 0..<count {
                guard values[index(i)].isFinite else { continue }
                if last >= 0, i - last > 1, i - last - 1 <= maxGap {
                    let a = values[index(last)]
                    let b = values[index(i)]
                    for m in (last + 1)..<i {
                        let f = Float(m - last) / Float(i - last)
                        values[index(m)] = a + (b - a) * f
                    }
                } else if last < 0, i > 0, i <= maxGap {
                    for m in 0..<i { values[index(m)] = values[index(i)] }
                }
                last = i
            }
            if last >= 0, last < count - 1, count - 1 - last <= maxGap {
                for m in (last + 1)..<count { values[index(m)] = values[index(last)] }
            }
        }
        for col in 0..<columns {
            fill(count: rows, maxGap: rows) { $0 * columns + col }
        }
        for row in 0..<rows {
            fill(count: columns, maxGap: 8) { row * columns + $0 }
        }
    }

    private static func smoothed(_ values: [Float], rows: Int, columns: Int) -> [Float] {
        var out = values
        for row in 0..<rows {
            for col in 0..<columns where values[row * columns + col].isFinite {
                var sum: Float = 0
                var n = 0
                for r in max(0, row - 1)...min(rows - 1, row + 1) {
                    for c in max(0, col - 1)...min(columns - 1, col + 1) {
                        let v = values[r * columns + c]
                        if v.isFinite {
                            sum += v
                            n += 1
                        }
                    }
                }
                out[row * columns + col] = sum / Float(n)
            }
        }
        return out
    }
}

// MARK: - Number helpers

enum ReplayNumbers {
    /// 1, 2, 2.5 or 5 × 10ⁿ closest to value.
    static func nice(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let exponent = floor(log10(value))
        let base = pow(10, exponent)
        let f = value / base
        let n: Double
        if f < 1.5 { n = 1 } else if f < 2.25 { n = 2 } else if f < 3.5 { n = 2.5 } else if f < 7.5 { n = 5 } else { n = 10 }
        return n * base
    }

    /// Evenly spaced round tick values covering lo…hi (about `count` of them).
    static func ticks(_ lo: Double, _ hi: Double, count: Int) -> [Double] {
        guard hi > lo, count > 0 else { return [lo] }
        let step = nice((hi - lo) / Double(count))
        var out: [Double] = []
        var v = ceil(lo / step) * step
        while v <= hi + step * 1e-6 {
            out.append(abs(v) < step * 1e-6 ? 0 : v)
            v += step
        }
        return out
    }

    /// Decimals that show a step size cleanly.
    static func decimals(for step: Double) -> Int {
        guard step > 0, step.isFinite else { return 1 }
        var scaled = step
        var digits = 0
        while digits < 4, abs(scaled.rounded() - scaled) > 1e-6 * max(1, scaled) {
            scaled *= 10
            digits += 1
        }
        return digits
    }

    static func text(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }
}
