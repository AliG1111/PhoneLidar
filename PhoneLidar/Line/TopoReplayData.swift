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
/// Per-frame inputs of a replay: frame times (s), travel (mm), raw speeds (mm/s) and the reveal position (travel
/// coordinate p of the newest complete line, NaN = unknown; made non-decreasing by `TopoReplaySource.make`).
struct ReplayFrames: Sendable {
    var times: [Double]
    var travel: [Double]
    var speeds: [Double?]
    var reveal: [Double]
}

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
    /// Travel speed used after the last frame to bring the rest of the recorded material out (mm/s, 0 = none):
    /// the last measured speed, raised so the run-out never takes longer than `maxRunOut`, or a speed that
    /// takes `fallbackRunOut` when no speed was measured.
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

    /// Longest run-out after the last frame, s.
    static let maxRunOut = 60.0
    /// Run-out length when the recording has no measured speed, s.
    static let fallbackRunOut = 3.0

    static func make(grid: TopoGridFile, info: LineRecordingInfo) throws -> TopoReplaySource {
        try make(grid: grid, direction: info.direction, frames: replayFrames(info: info))
    }

    /// Per-frame replay inputs of a LiDAR recording: the reveal position is the material at the downstream edge
    /// of the LiDAR's view.
    static func replayFrames(info: LineRecordingInfo) -> ReplayFrames {
        let sign = info.direction.bufferSign
        let frames = info.frames
        let border = TopoMapBuilder.border(width: info.depthWidth, height: info.depthHeight)
        let depths = frames.map(\.medianDepth).filter { $0 > 0 }.sorted()
        let zTypical = depths.isEmpty ? 1000 : depths[depths.count / 2]
        var reveal = [Double](repeating: .nan, count: frames.count)
        for (i, f) in frames.enumerated() where f.fy > 0 {
            let z = f.medianDepth > 0 ? f.medianDepth : zTypical
            let row = sign > 0 ? Double(info.depthHeight - 1 - border) : Double(border)
            let yDown = (row - Double(f.cy)) * z / Double(f.fy)
            reveal[i] = f.travel - Double(sign) * yDown
        }
        return ReplayFrames(times: frames.map(\.time), travel: frames.map(\.travel), speeds: frames.map(\.speed),
                            reveal: reveal)
    }

    /// Builds the replay from a grid and per-frame inputs (LiDAR or laser, design §6.10, §14.7).
    static func make(grid: TopoGridFile, direction: TravelDirection, frames input: ReplayFrames)
        throws -> TopoReplaySource {
        let sign = direction.bufferSign
        let srcColumns = grid.columns
        let srcRows = grid.rows
        let frameCount = input.times.count
        guard frameCount > 0, input.travel.count == frameCount, input.speeds.count == frameCount,
              input.reveal.count == frameCount, srcColumns >= 2, srcRows >= 2 else { throw LineError.notEnoughData }

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

        // Reveal position per frame, never decreasing.
        var reveal = [Double](repeating: .nan, count: frameCount)
        var running = -Double.infinity
        for i in 0..<frameCount {
            let value = input.reveal[i]
            if value.isFinite { running = max(running, value) }
            reveal[i] = running
        }
        guard let firstValid = reveal.firstIndex(where: { $0.isFinite }) else { throw LineError.notEnoughData }
        for i in 0..<firstValid { reveal[i] = reveal[firstValid] }

        let times = input.times
        let travel = input.travel
        let recordingDuration = max(times.last ?? 0, 0.01)

        // Speed for the run-out: travel over the last second, else over the whole recording.
        var measured = 0.0
        if let lastTime = times.last, let lastTravel = travel.last {
            let startIndex = LineMath.frameIndex(for: lastTime - 1.0, inTimes: times)
            if lastTime - times[startIndex] > 0.2 {
                measured = (lastTravel - travel[startIndex]) / (lastTime - times[startIndex])
            }
            if !(measured > 1), lastTime - times[0] > 0.2 {
                measured = (lastTravel - travel[0]) / (lastTime - times[0])
            }
            if !(measured > 1) || !measured.isFinite { measured = 0 }
        }
        // The rest of the material always comes out by the end of the replay: at the measured speed, faster if
        // that would take more than `maxRunOut`, over `fallbackRunOut` when no speed was measured.
        let pEnd = pStart + Double(columns) * grid.cell
        let remaining = max(0, pEnd - (reveal.last ?? pEnd))
        var runOut = 0.0
        var runOutTime = 0.0
        if remaining > 0 {
            runOutTime = measured > 0 ? min(remaining / measured, maxRunOut) : fallbackRunOut
            runOut = remaining / runOutTime
            if !runOut.isFinite || runOut <= 0 {
                runOut = 0
                runOutTime = 0
            }
        }
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
                                speeds: LineMath.smoothed(input.speeds, radius: 7),
                                recordingDuration: recordingDuration, runOutSpeed: runOut, duration: duration,
                                median: median, robustStdDev: robust,
                                p01: percentile(0.01), p99: percentile(0.99))
    }

    /// Travel coordinate of the newest complete line at replay time t. Reaches `pEnd` at `duration`.
    func revealPosition(at t: Double) -> Double {
        guard let last = revealP.last else { return pEnd }
        if t >= duration { return max(pEnd, last) }
        if t >= recordingDuration {
            return runOutSpeed > 0 ? min(pEnd, last + (t - recordingDuration) * runOutSpeed) : last
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
            return runOutSpeed > 0 ? min(duration, recordingDuration + (p - last) / runOutSpeed) : duration
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
/// 3D surface every screen refresh.
///
/// Only blocks that are complete at the moment shown are ever used: the newest displayed column is the newest
/// block whose whole length has left the LiDAR's view, and gap filling and smoothing for the surface never look
/// at newer columns (see `window`). Statistics and profiles use the measured blocks only (`observed`).
struct TopoDisplayGrid: Sendable {
    /// Longest gap (blocks) filled across a column, between two measured blocks.
    static let maxAcrossGap = 3
    /// Longest gap (blocks) filled along a row, between two measured blocks.
    static let maxAlongGap = 8

    let factor: Int
    let rows: Int
    let columns: Int
    /// Block size along the travel, mm.
    let cellMM: Double
    let pStart: Double
    /// Travel coordinate of the end of the newest material (the last block may be shorter than `cellMM`).
    let pEnd: Double
    /// Strip width (mm) and the centre of each row, mm from the back edge (top of the recording screen).
    /// The last row may be narrower than the others.
    let widthMM: Double
    let rowCenterMM: [Double]
    /// rows × columns block means of the measured cells, mm (NaN = no data).
    let observed: [Float]
    /// `observed` with short gaps across each column filled (between two measured blocks, no edge extension).
    let filled: [Float]
    /// Mean of the measured blocks of each column (NaN = no data).
    let columnMean: [Float]
    /// Replay time at which each column is complete.
    let revealTime: [Double]

    /// Travel coordinate of a column centre.
    func p(ofColumn j: Int) -> Double { pStart + (Double(j) + 0.5) * cellMM }

    /// Newest column whose whole length is complete when the newest complete line is at `newest`
    /// (−1 or less = none yet).
    func newestCompleteColumn(newest: Double) -> Int {
        if newest >= pEnd - 1e-6 { return columns - 1 }
        let complete = ((newest - pStart) / cellMM).rounded(.down)
        guard complete.isFinite else { return -1 }
        return Int(min(max(complete, -1), Double(columns))) - 1
    }

    static func make(source: TopoReplaySource, factor: Int) -> TopoDisplayGrid {
        let k = max(1, factor)
        let rows = max(1, (source.rows + k - 1) / k)
        let columns = max(1, (source.columns + k - 1) / k)
        var observed = [Float](repeating: .nan, count: rows * columns)
        source.values.withUnsafeBufferPointer { src in
            observed.withUnsafeMutableBufferPointer { dst in
                for row in 0..<rows {
                    let rLo = row * k
                    let rHi = min(source.rows, rLo + k)
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
        var filled = observed
        filled.withUnsafeMutableBufferPointer { buffer in
            for col in 0..<columns {
                fillInterior(buffer, count: rows, maxGap: maxAcrossGap) { $0 * columns + col }
            }
        }

        var means = [Float](repeating: .nan, count: columns)
        for col in 0..<columns {
            var sum: Float = 0
            var n = 0
            for row in 0..<rows {
                let v = observed[row * columns + col]
                if v.isFinite {
                    sum += v
                    n += 1
                }
            }
            if n > 0 { means[col] = sum / Float(n) }
        }
        let cellMM = source.cell * Double(k)
        let pEnd = source.pEnd
        let times = (0..<columns).map { j in
            source.revealTime(of: min(source.pStart + Double(j + 1) * cellMM, pEnd))
        }
        let centres = (0..<rows).map { row in
            Double(row * k + min(source.rows, row * k + k)) / 2 * source.cell
        }
        return TopoDisplayGrid(factor: k, rows: rows, columns: columns, cellMM: cellMM, pStart: source.pStart,
                               pEnd: pEnd, widthMM: source.widthMM, rowCenterMM: centres,
                               observed: observed, filled: filled, columnMean: means, revealTime: times)
    }

    /// Surface values of columns jLo…jHi (rows × (jHi − jLo + 1), row-major): `filled` with gaps along each row
    /// of up to `maxAlongGap` blocks interpolated between two measured blocks, optionally 3 × 3 smoothed.
    /// Nothing newer than jHi is read, so the newest column never shows material that is not complete yet.
    func window(jLo: Int, jHi: Int, smooth: Bool) -> [Float] {
        guard jLo >= 0, jHi < columns, jHi >= jLo else { return [] }
        let from = max(0, jLo - Self.maxAlongGap - 1)
        let span = jHi - from + 1
        var buffer = [Float](repeating: .nan, count: rows * span)
        filled.withUnsafeBufferPointer { src in
            buffer.withUnsafeMutableBufferPointer { dst in
                for r in 0..<rows {
                    let s = r * columns + from
                    let d = r * span
                    for c in 0..<span { dst[d + c] = src[s + c] }
                    Self.fillInterior(dst, count: span, maxGap: Self.maxAlongGap) { d + $0 }
                }
            }
        }
        if smooth { buffer = Self.smoothed(buffer, rows: rows, columns: span) }
        let nc = jHi - jLo + 1
        let skip = jLo - from
        var out = [Float](repeating: .nan, count: rows * nc)
        for r in 0..<rows {
            for c in 0..<nc { out[r * nc + c] = buffer[r * span + skip + c] }
        }
        return out
    }

    /// Linear interpolation of gaps of up to `maxGap` values between two finite values (edges are left empty).
    private static func fillInterior(_ values: UnsafeMutableBufferPointer<Float>, count: Int, maxGap: Int,
                                     index: (Int) -> Int) {
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
            }
            last = i
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
