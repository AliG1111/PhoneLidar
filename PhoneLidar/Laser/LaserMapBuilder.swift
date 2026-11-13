import Foundation
import CoreGraphics

/// Topographic map of a laser line recording (design §14.7): heights above the belt from `Profiles.bin`, one
/// reading per cell by default (the reading nearest the cell centre) or averaged. Pure; runs off the main thread.
enum LaserMapBuilder {
    /// Smallest map cell, mm.
    static let minimumCell = 0.2

    static let calibrationMismatch = LineError.configuration(
        "The laser calibration in LaserRecording.json does not match Profiles.bin (column layout or camera size).")
    static let calibrationIncomplete = LineError.configuration(
        "The laser calibration in LaserRecording.json has no camera height or height scale.")
    static let lineNotFound = LineError.configuration(
        "The laser line was not found in this recording (or every reading was outside the height range). Check the "
        + "laser, the exposure and the calibration, then record again.")

    /// One laser reading in map coordinates.
    private struct Reading {
        var q: Double
        var x: Double
        var height: Double
    }

    /// Calls `body` for every valid reading of frame `index`: map position (q along, x across, mm) and height (mm).
    @inline(__always)
    private static func readings(_ records: ProfilesFileReader.Records, index: Int, columns: LaserColumns,
                                 baseline: [Float], calibration H: Double, scales: [Double], fx: Double, fy: Double,
                                 cx: Double, cy: Double, sign: Double, body: (Reading) -> Void) {
        let travel = records.travel(index)
        guard travel.isFinite else { return }
        for k in 0..<columns.count {
            let row = records.row(index, k)
            let base = baseline[k]
            let a = scales[k]
            guard row.isFinite, base.isFinite, a.isFinite,
                  let h = LaserGeometry.height(shift: Double(row - base), cameraHeight: H, scale: a) else { continue }
            let x = LaserGeometry.across(u: Double(columns.u(k)), height: h, cameraHeight: H, fx: fx, cx: cx)
            let y = LaserGeometry.along(v: Double(row), height: h, cameraHeight: H, fy: fy, cy: cy)
            body(Reading(q: sign * travel - y, x: x, height: h))
        }
    }

    /// Builds the map and writes its files (the FR-TOPO-04 set). `method` nil = the recording's.
    static func build(folder: URL, info: LaserRecordingInfo, method: MapMethod? = nil,
                      composite: ((CGImage, TopoStats) throws -> Data)? = nil) throws -> TopoMapBuilder.Output {
        let reader = try ProfilesFileReader(url: folder.appendingPathComponent(ProfilesFile.fileName))
        let columns = info.columns
        let calibration = info.calibration
        guard reader.columns == columns, calibration.columns == columns,
              calibration.baselineRows.count == columns.count, info.fx > 0, info.fy > 0 else {
            throw calibrationMismatch
        }
        guard calibration.isComplete else { throw calibrationIncomplete }
        guard reader.frameCount >= 2 else { throw LineError.notEnoughData }
        let H = calibration.cameraHeight
        let baseline = calibration.baselineRows
        let scales = calibration.shiftScales
        let sign = Double(info.direction.bufferSign)
        let frames = reader.frameCount
        let method = method ?? info.mapMethod

        // Pass 1: extent, travel steps, detection share, speed readings of tracked frames.
        var qMin = Double.infinity, qMax = -Double.infinity, xMin = Double.infinity, xMax = -Double.infinity
        var steps: [Double] = []
        steps.reserveCapacity(frames)
        var valid = 0
        var speeds: [Double?] = []
        var travelLo = Double.infinity, travelHi = -Double.infinity
        var duration = 0.0
        reader.withRecords { records in
            var previousTravel: Double?
            for i in 0..<frames {
                let travel = records.travel(i)
                if travel.isFinite {
                    if let p = previousTravel, abs(travel - p) > 0 { steps.append(abs(travel - p)) }
                    previousTravel = travel
                    travelLo = min(travelLo, travel)
                    travelHi = max(travelHi, travel)
                }
                if records.flags(i) & ProfilesFile.trackedFlag != 0 { speeds.append(records.speed(i)) }
                readings(records, index: i, columns: columns, baseline: baseline, calibration: H, scales: scales,
                         fx: info.fx, fy: info.fy, cx: info.cx, cy: info.cy, sign: sign) { r in
                    qMin = min(qMin, r.q)
                    qMax = max(qMax, r.q)
                    xMin = min(xMin, r.x)
                    xMax = max(xMax, r.x)
                    valid += 1
                }
            }
            let t = records.time(frames - 1)
            duration = t.isFinite ? t : 0
        }
        guard valid >= 10, qMin.isFinite, xMin.isFinite else { throw lineNotFound }

        let cell = cellSize(acrossSpacing: Double(columns.stride) * H / info.fx, steps: steps,
                            length: qMax - qMin, width: xMax - xMin)
        // Half a cell of margin on each side; the empty margin is trimmed by `finish`.
        qMin -= cell / 2
        xMin -= cell / 2
        let cols = Int(((qMax - qMin) / cell).rounded(.up)) + 1
        let rows = Int(((xMax - xMin) / cell).rounded(.up)) + 1
        var cells = MapCells(method: method, columns: cols, rows: rows, cell: cell, qMin: qMin, xMin: xMin, zRef: 0)

        // Pass 2: every reading; single reading keeps the one nearest its cell centre.
        let single = method == .singleReading
        cells.withAccumulator { acc in
            reader.withRecords { records in
                for i in 0..<frames {
                    readings(records, index: i, columns: columns, baseline: baseline, calibration: H, scales: scales,
                             fx: info.fx, fy: info.fy, cx: info.cx, cy: info.cy, sign: sign) { r in
                        guard let idx = acc.index(q: r.q, x: r.x) else { return }
                        var score: Float = 0
                        if single {
                            let qc = acc.qMin + (Double(idx % acc.columns) + 0.5) * acc.cell
                            let xc = acc.xMin + (Double(idx / acc.columns) + 0.5) * acc.cell
                            score = Float(abs(r.q - qc) + abs(r.x - xc))
                        }
                        acc.add(Float(r.height), at: idx, score: score)
                    }
                }
            }
        }

        let detected = 100 * Double(valid) / Double(frames * columns.count)
        var lines = [laserLine(info: info, frames: frames, detectedPercent: detected)]
        if single {
            lines.append("Map method: one reading per cell (no averaging), the laser reading nearest the cell centre")
        }
        let travelRange = travelHi >= travelLo ? travelHi - travelLo : 0
        return try TopoMapBuilder.finish(cells: cells, heightMode: true, sensor: .laserLine, speeds: speeds,
                                         frameCount: frames, duration: duration, travel: travelRange,
                                         extraLines: lines, folder: folder, composite: composite)
    }

    /// Cell (mm): max(across column spacing, 90th-percentile travel step, `minimumCell`), rounded up to 0.1 mm,
    /// ×1.25 until the grid has at most `TopoGridFile.maxCells` cells.
    static func cellSize(acrossSpacing: Double, steps: [Double], length: Double, width: Double) -> Double {
        let sorted = steps.filter { $0.isFinite && $0 > 0 }.sorted()
        let p90 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.9).rounded()))]
        var cell = max(acrossSpacing.isFinite ? acrossSpacing : 0, p90, minimumCell)
        cell = ((cell * 10) - 1e-6).rounded(.up) / 10
        func cells(_ c: Double) -> Double {
            (((max(0, length) + c) / c).rounded(.up) + 1) * (((max(0, width) + c) / c).rounded(.up) + 1)
        }
        while cells(cell) > Double(TopoGridFile.maxCells) { cell *= 1.25 }
        return cell
    }

    /// "Laser line: 1,234 profiles at 240 fps, 97 % of columns detected, height scale from a 10.0 mm shim,
    /// camera height 1000 mm" (a map line, replaced on rebuild).
    static func laserLine(info: LaserRecordingInfo, frames: Int, detectedPercent: Double) -> String {
        let c = info.calibration
        let scale: String
        if c.scaleSource == .shim, let t = c.shimThickness {
            scale = String(format: "height scale from a %.1f mm shim", t)
        } else if let angle = c.laserAngle {
            scale = String(format: "height scale from a %.1f° laser angle", angle)
        } else {
            scale = "height scale not recorded"
        }
        return String(format: "Laser line: %ld profiles at %.0f fps, %.0f %% of columns detected, %@, "
                      + "camera height %.0f mm", frames, info.activeFrameRate, detectedPercent, scale, c.cameraHeight)
    }

    /// Replay inputs (design §14.7): tracked frames (≈ 30 Hz; every frame if none is flagged), revealing the
    /// material at the laser line.
    static func replayFrames(folder: URL, info: LaserRecordingInfo) throws -> ReplayFrames {
        let reader = try ProfilesFileReader(url: folder.appendingPathComponent(ProfilesFile.fileName))
        let H = info.calibration.cameraHeight
        let lineRow = info.calibration.medianBaselineRow ?? info.cy
        let yLine = info.fy > 0 ? (lineRow - info.cy) * H / info.fy : 0
        let sign = Double(info.direction.bufferSign)
        return reader.withRecords { records in
            var indices = (0..<reader.frameCount).filter { records.flags($0) & ProfilesFile.trackedFlag != 0 }
            if indices.count < 2 { indices = Array(0..<reader.frameCount) }
            var frames = ReplayFrames(times: [], travel: [], speeds: [], reveal: [])
            for i in indices {
                let t = records.time(i)
                let travel = records.travel(i)
                guard t.isFinite, travel.isFinite else { continue }
                frames.times.append(t)
                frames.travel.append(travel)
                frames.speeds.append(records.speed(i))
                frames.reveal.append(travel - sign * yLine)
            }
            return frames
        }
    }

    /// The scan record's summary after a map build: the recording line kept (refreshed from `info`), map lines
    /// replaced.
    static func recordSummary(existing: [String], info: LaserRecordingInfo, map: [String]) -> [String] {
        var lines = existing.filter { !TopoMapBuilder.isMapSummaryLine($0) }
        if let i = lines.firstIndex(where: LaserRecordingInfo.isSummaryLine) {
            lines[i] = info.summaryLine
        }
        if lines.isEmpty { lines = [info.summaryLine] }
        lines.insert(contentsOf: map, at: 1)
        return lines
    }
}
