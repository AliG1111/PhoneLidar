import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct ProfilePoint: Codable, Identifiable {
    /// mm (across: from the image centre line, along: from the left edge of the map)
    var position: Double
    /// mean distance from the camera, mm
    var value: Double
    var cells: Int

    var id: Double { position }
}

struct TopoProfiles: Codable {
    var across: [ProfilePoint]
    var along: [ProfilePoint]
}

/// Variance statistics of a topographic map. Distances are mm from the camera.
struct TopoStats: Codable {
    var cellSize: Double
    var columns: Int
    var rows: Int
    var lengthMM: Double
    var widthMM: Double
    var coveragePercent: Double
    var cellsWithData: Int
    var meanHitsPerCell: Double

    var mean: Double
    var variance: Double
    var stdDev: Double
    /// Coefficient of variation, % (distance mode only; nil/absent for heights above a baseline, where the
    /// mean is near zero and a CV has no meaning — older files may hold 0 there).
    var cvPercent: Double?
    var minimum: Double
    var maximum: Double
    var range: Double
    var p1: Double
    var p5: Double
    var median: Double
    var p95: Double
    var p99: Double

    /// Variation of the across-width profile (lane-to-lane differences).
    var acrossStdDev: Double
    var acrossRange: Double
    /// Variation of the along-travel profile (waves along the material).
    var alongStdDev: Double
    var alongRange: Double
    /// What is left after removing both profiles (local roughness / undulation).
    var residualStdDev: Double
    /// Pooled scatter of repeated LiDAR readings of the same cell (measurement noise estimate).
    var repeatStdDev: Double

    var speedMean: Double?
    var speedStdDev: Double?
    var speedMin: Double?
    var speedMax: Double?
    var speedTrackedPercent: Double

    var colorNear: Double
    var colorFar: Double
    var frames: Int
    var duration: Double
    /// True when values are heights above a flat-surface baseline (colorFar = dark-blue/low end,
    /// colorNear = dark-red/high end). False/nil: distances from the camera.
    var heightMode: Bool? = nil
    /// How readings in a cell were combined (design §13.2); absent in maps before P12 = averaged.
    var mapMethod: MapMethod? = nil
    /// Sensor of the values; absent in maps before P12 = LiDAR.
    var sensor: MapSensor? = nil
    /// What the heights are measured from (design §16); absent in maps before P16 (baseline when `heightMode`).
    var heightReference: HeightReferenceMethod? = nil
}

extension TopoStats {
    /// One reading per cell (single frame or camera parallax): no repeat-reading noise exists (FR-SFM-05).
    var isSingleReading: Bool { mapMethod?.isSingleReading == true }

    /// Heights measured from a belt plane (camera height or side walls) rather than the empty-belt baseline.
    var heightAboveBelt: Bool {
        heightMode == true && (heightReference == .cameraHeight || heightReference == .sideWalls)
    }
}

/// Stitches the recorded depth frames into a top-down distance map using the measured travel,
/// averaging every reading that lands in the same cell.
enum TopoMapBuilder {
    struct Output {
        var stats: TopoStats
        var profiles: TopoProfiles
        var summary: [String]
        var mapImage: CGImage
        /// The grid just written to TopoGrid.bin.
        var grid: TopoGridFile
    }

    /// Depth pixels skipped at each edge of the depth map (the LiDAR is least reliable there).
    static func border(width: Int, height: Int) -> Int {
        max(2, min(width, height) / 32)
    }

    /// Builds the map and writes its files. `composite` encodes TopoMap.png (title, legend, statistics) from the
    /// map image; when given, TopoMap.png is staged with the other files, so it never pairs an old picture with
    /// new statistics.
    /// `method` overrides the recording's `mapMethod` (nil = the recording's, else averaged; design §13.2).
    static func build(folder: URL, info: LineRecordingInfo, method: MapMethod? = nil,
                      composite: ((CGImage, TopoStats) throws -> Data)? = nil) throws -> Output {
        let method = method ?? info.mapMethod ?? .averaged
        guard method != .cameraParallax else {
            throw LineError.configuration("A camera-parallax map is built by the parallax builder.")
        }
        let reader = try DepthFileReader(url: folder.appendingPathComponent("Depth.bin"))
        let frames = Array(info.frames.prefix(reader.frameCount))
        // A height reference saved with the recording turns distances into heights above the belt: a camera-height
        // or side-wall plane (HeightReference.json), else the empty-belt baseline (Baseline.bin; design §16.4).
        let model = MapHeightModel.load(folder: folder, width: reader.width, height: reader.height, frames: frames)
        let heightMode = model.isHeight
        let baseValues = model.baselineValues ?? []
        let plane = model.plane
        guard frames.count >= 2 else { throw LineError.notEnoughData }
        let w = reader.width
        let h = reader.height
        let depths = frames.map(\.medianDepth).filter { $0 > 0 }.sorted()
        guard !depths.isEmpty else { throw LineError.notEnoughData }
        let zTypical = depths[depths.count / 2]
        let border = Self.border(width: w, height: h)
        guard w > 2 * border + 4, h > 2 * border + 4 else { throw LineError.badFile }
        let sign = Double(info.direction.bufferSign)

        guard let extent = Self.extent(frames: frames, width: w, height: h, border: border, sign: sign,
                                       typicalDepth: zTypical) else { throw LineError.notEnoughData }
        let qMin = extent.q.lowerBound, qMax = extent.q.upperBound
        let xMin = extent.x.lowerBound, xMax = extent.x.upperBound

        // At least one depth-pixel footprint everywhere in the frame (rounded up to whole mm), so neighbouring
        // pixels of one frame never skip a cell: no empty stripes and full coverage of stationary material.
        let footprint = Self.pixelFootprint(reader: reader, frames: frames, border: border, sign: sign,
                                            qRange: qMin...qMax, xRange: xMin...xMax, typicalDepth: zTypical)
        // The 1 µm tolerance keeps an exact footprint (e.g. 10.000000000000002 from rounding) at 10 mm.
        var cell = max(2.0, (footprint - 1e-6).rounded(.up))
        var cols = Int(((qMax - qMin) / cell).rounded(.up)) + 1
        var rows = Int(((xMax - xMin) / cell).rounded(.up)) + 1
        while cols * rows > TopoGridFile.maxCells {
            cell *= 1.25
            cols = Int(((qMax - qMin) / cell).rounded(.up)) + 1
            rows = Int(((xMax - xMin) / cell).rounded(.up)) + 1
        }
        let zRef: Float = heightMode ? 0 : Float(zTypical)
        let single = method == .singleReading
        // Side walls: only the columns between the wall bands (FR-HREF-07).
        let columns = model.columns(width: w, border: border)
        var cells = MapCells(method: method, columns: cols, rows: rows, cell: cell, qMin: qMin, xMin: xMin, zRef: zRef)

        // Single reading: each cell keeps the reading whose depth row was closest to the scan line (design §13.3);
        // frames that repeat the previous depth frame add nothing (§13.4). The scan rows feed ScanLineProfiles.csv.
        var scanRows: [ScanRowSample] = []
        var usedFrames = 0
        var repeatedFrames = 0
        var previous: [Float]?
        cells.withAccumulator { acc in
            baseValues.withUnsafeBufferPointer { baseBuf in
                for (i, f) in frames.enumerated() {
                    guard let depth = reader.frame(i) else { continue }
                    let repeated = single && previous.map { ScanLineMath.isRepeat(depth, previous: $0) } == true
                    if single { previous = depth }
                    let fx = Double(f.fx), fy = Double(f.fy), cx = Double(f.cx), cy = Double(f.cy)
                    guard fx > 0, fy > 0 else { continue }
                    let offset = sign * f.travel
                    let scanRow = ScanLineMath.scanRow(cy: f.cy, height: h, border: border)
                    if single {
                        var sample = ScanRowSample(frame: f.index, time: f.time, travel: f.travel, repeated: repeated)
                        let rowBase = scanRow * w
                        let scanYn = (Double(scanRow) - cy) / fy
                        for u in columns {
                            let z = depth[rowBase + u]
                            if z <= 0 { continue }
                            var value = z
                            let xn = (Double(u) - cx) / fx
                            if let plane {
                                value = Float(plane.height(z: Double(z), xn: xn, yn: scanYn))
                            } else if heightMode {
                                let b = baseValues[rowBase + u]
                                if !(b > 0 && b.isFinite) { continue }
                                value = b - z
                            }
                            sample.across.append(Float(xn * Double(z)))
                            sample.values.append(value)
                        }
                        scanRows.append(sample)
                        if repeated {
                            repeatedFrames += 1
                            continue
                        }
                    }
                    usedFrames += 1
                    depth.withUnsafeBufferPointer { zBuf in
                        for v in border..<(h - border) {
                            let yFactor = (Double(v) - cy) / fy
                            let rowBase = v * w
                            let score = Float(abs(v - scanRow))
                            for u in columns {
                                let z = zBuf[rowBase + u]
                                if z <= 0 { continue }
                                var value = z
                                let xFactor = (Double(u) - cx) / fx
                                let zd = Double(z)
                                if let plane {
                                    value = Float(plane.height(z: zd, xn: xFactor, yn: yFactor))
                                } else if heightMode {
                                    let b = baseBuf[rowBase + u]
                                    if !(b > 0 && b.isFinite) { continue }   // no NaN/inf from a damaged baseline
                                    value = b - z
                                }
                                let q = offset - yFactor * zd
                                let x = xFactor * zd
                                guard let idx = acc.index(q: q, x: x) else { continue }
                                acc.add(value, at: idx, score: score)
                            }
                        }
                    }
                }
            }
        }

        var extraLines: [String] = []
        if let line = model.summaryLine { extraLines.append(line) }
        if single {
            extraLines.append(Self.singleReadingLine(used: usedFrames, total: frames.count, repeated: repeatedFrames))
        }
        let samples = scanRows
        scanRows = []
        let output = try finish(cells: cells, heightMode: heightMode, sensor: .lidar, speeds: frames.map(\.speed),
                                frameCount: frames.count, duration: frames.last?.time ?? 0,
                                travel: Self.travelRange(frames), extraLines: extraLines, folder: folder,
                                heightReference: model.method, composite: composite) { geometry in
            guard single else { return [] }
            return [(ScanLineProfiles.fileName, { url in
                try ScanLineProfiles.write(samples, geometry: geometry, to: url)
            })]
        }
        if !single {
            // A profile file from an earlier single-reading build no longer matches this map. It is derived data
            // (rebuilt from Depth.bin by a single-reading rebuild), so removing it loses no measurement.
            let stale = folder.appendingPathComponent(ScanLineProfiles.fileName)
            if FileManager.default.fileExists(atPath: stale.path) { try? FileManager.default.removeItem(at: stale) }
        }
        return output
    }

    /// Map coordinates (mm) covered by the frames' depth views, padded by 6 % of the width for relief nearer or
    /// farther than the typical distance: q runs left → right as seen on the portrait screen and stays fixed to the
    /// material (q = sign·travel − y); x runs top → bottom of the screen (across the material). Nil without a frame
    /// with valid intrinsics.
    static func extent(frames: [LineFrameInfo], width w: Int, height h: Int, border: Int, sign: Double,
                       typicalDepth zTypical: Double) -> (q: ClosedRange<Double>, x: ClosedRange<Double>)? {
        var qMin = Double.infinity
        var qMax = -Double.infinity
        var xMin = Double.infinity
        var xMax = -Double.infinity
        for f in frames {
            let z = f.medianDepth > 0 ? f.medianDepth : zTypical
            let fx = Double(f.fx), fy = Double(f.fy), cx = Double(f.cx), cy = Double(f.cy)
            guard fx > 0, fy > 0 else { continue }
            let yLo = (Double(border) - cy) * z / fy
            let yHi = (Double(h - 1 - border) - cy) * z / fy
            let xLo = (Double(border) - cx) * z / fx
            let xHi = (Double(w - 1 - border) - cx) * z / fx
            qMin = min(qMin, sign * f.travel - yHi)
            qMax = max(qMax, sign * f.travel - yLo)
            xMin = min(xMin, xLo)
            xMax = max(xMax, xHi)
        }
        guard qMin.isFinite, qMax > qMin, xMin.isFinite, xMax > xMin else { return nil }
        let pad = (xMax - xMin) * 0.06
        return ((qMin - pad)...(qMax + pad), (xMin - pad)...(xMax + pad))
    }

    /// The trimmed grid a map was written with (for files that need its rows or columns).
    struct Geometry {
        var columns: Int
        var rows: Int
        var cell: Double
        var qMin: Double
        var xMin: Double
    }

    /// Summary line of a single-reading LiDAR map (design §13.6); a map line, replaced on rebuild.
    static func singleReadingLine(used: Int, total: Int, repeated: Int) -> String {
        String(format: "Map method: one reading per cell (no averaging); %ld of %ld frames used, "
               + "%ld repeated depth frames skipped", used, total, repeated)
    }

    /// Trims the accumulated grid to the observed extent, computes statistics and profiles, renders the map image
    /// and writes every map file (staged, renamed together). Shared by the LiDAR builds and the parallax builder.
    /// `speeds` holds one entry per frame that could have a speed (nil = no reading); `extraFiles` adds files that
    /// depend on the trimmed grid, written in the same staged set.
    static func finish(cells: MapCells, heightMode: Bool, sensor: MapSensor, speeds: [Double?], frameCount: Int,
                       duration: Double, travel: Double, extraLines: [String], folder: URL,
                       heightReference: HeightReferenceMethod? = nil,
                       composite: ((CGImage, TopoStats) throws -> Data)?,
                       extraFiles: (Geometry) -> [(name: String, write: (URL) throws -> Void)] = { _ in [] })
        throws -> Output {
        var cols = cells.columns
        var rows = cells.rows
        let cell = cells.cell
        var qMin = cells.qMin
        var xMin = cells.xMin
        let zRef = cells.zRef
        var means = cells.means
        var m2s = cells.m2s.isEmpty ? [Float](repeating: 0, count: cells.count) : cells.m2s
        var hits = cells.hits
        guard cols > 0, rows > 0, means.count == cols * rows, hits.count == cols * rows,
              m2s.count == cols * rows else { throw LineError.notEnoughData }
        // Trim the empty margin around the data (the padding above only leaves room for relief), so the map,
        // its length, width and coverage describe the observed material only.
        var rLo = rows, rHi = -1, cLo = cols, cHi = -1
        hits.withUnsafeBufferPointer { hitBuf in
            for r in 0..<rows {
                let base = r * cols
                var first = -1
                var last = -1
                for c in 0..<cols where hitBuf[base + c] > 0 {
                    if first < 0 { first = c }
                    last = c
                }
                guard first >= 0 else { continue }
                rLo = min(rLo, r)
                rHi = max(rHi, r)
                cLo = min(cLo, first)
                cHi = max(cHi, last)
            }
        }
        guard rHi >= rLo, cHi >= cLo else { throw LineError.notEnoughData }
        let fullColumns = cols
        cols = cHi - cLo + 1
        rows = rHi - rLo + 1
        qMin += Double(cLo) * cell
        xMin += Double(rLo) * cell
        let mapCells = cols * rows
        var grid = [Float](repeating: .nan, count: mapCells)
        var cellHits = [UInt16](repeating: 0, count: mapCells)
        var cellM2 = [Float](repeating: 0, count: mapCells)
        for r in 0..<rows {
            let src = (rLo + r) * fullColumns + cLo
            let dst = r * cols
            for c in 0..<cols where hits[src + c] > 0 {
                grid[dst + c] = zRef + means[src + c]
                cellHits[dst + c] = hits[src + c]
                cellM2[dst + c] = m2s[src + c]
            }
        }
        means = []
        m2s = []
        hits = []

        // Cell values, profiles and overall statistics.
        var values: [Float] = []
        values.reserveCapacity(mapCells)
        var rowSum = [Double](repeating: 0, count: rows)
        var rowN = [Int](repeating: 0, count: rows)
        var colSum = [Double](repeating: 0, count: cols)
        var colN = [Int](repeating: 0, count: cols)
        var hitTotal = 0.0
        var repeatVarianceSum = 0.0
        var repeatN = 0
        var sum = 0.0
        for r in 0..<rows {
            for c in 0..<cols {
                let idx = r * cols + c
                let n = cellHits[idx]
                if n == 0 { continue }
                let z = grid[idx]
                values.append(z)
                let zd = Double(z)
                sum += zd
                rowSum[r] += zd
                rowN[r] += 1
                colSum[c] += zd
                colN[c] += 1
                hitTotal += Double(n)
                if n >= 3 {
                    repeatVarianceSum += Double(cellM2[idx]) / Double(n - 1)
                    repeatN += 1
                }
            }
        }
        cellM2 = []
        guard values.count >= 10 else { throw LineError.notEnoughData }
        let count = Double(values.count)
        let mean = sum / count
        var sq = 0.0
        for v in values {
            let d = Double(v) - mean
            sq += d * d
        }
        let variance = sq / count
        let sorted = values.sorted()
        values = []
        func percentile(_ p: Double) -> Double {
            Double(sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))])
        }

        let minRowCells = max(1, (rowN.max() ?? 0) / 10)
        let minColCells = max(1, (colN.max() ?? 0) / 10)
        var rowMean = [Double?](repeating: nil, count: rows)
        var colMean = [Double?](repeating: nil, count: cols)
        var across: [ProfilePoint] = []
        var along: [ProfilePoint] = []
        for r in 0..<rows where rowN[r] >= minRowCells {
            let m = rowSum[r] / Double(rowN[r])
            rowMean[r] = m
            across.append(ProfilePoint(position: xMin + (Double(r) + 0.5) * cell, value: m, cells: rowN[r]))
        }
        for c in 0..<cols where colN[c] >= minColCells {
            let m = colSum[c] / Double(colN[c])
            colMean[c] = m
            along.append(ProfilePoint(position: (Double(c) + 0.5) * cell, value: m, cells: colN[c]))
        }
        func spread(_ points: [ProfilePoint]) -> (std: Double, range: Double) {
            guard points.count >= 2 else { return (0, 0) }
            let m = points.reduce(0) { $0 + $1.value } / Double(points.count)
            let v = points.reduce(0) { $0 + ($1.value - m) * ($1.value - m) } / Double(points.count)
            let lo = points.map(\.value).min() ?? 0
            let hi = points.map(\.value).max() ?? 0
            return (v.squareRoot(), hi - lo)
        }
        let acrossSpread = spread(across)
        let alongSpread = spread(along)

        var residualSq = 0.0
        var residualN = 0
        for r in 0..<rows {
            guard let rm = rowMean[r] else { continue }
            for c in 0..<cols {
                guard let cm = colMean[c] else { continue }
                let idx = r * cols + c
                if cellHits[idx] == 0 { continue }
                let e = Double(grid[idx]) - rm - cm + mean
                residualSq += e * e
                residualN += 1
            }
        }

        let readings = speeds.compactMap { $0 }
        var speedMean: Double?
        var speedStd: Double?
        if !readings.isEmpty {
            let m = readings.reduce(0, +) / Double(readings.count)
            speedMean = m
            speedStd = (readings.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(readings.count)).squareRoot()
        }

        let p1Value = percentile(0.01)
        let p99Value = percentile(0.99)
        let near: Double
        let far: Double
        if heightMode {
            far = p1Value                          // dark blue = lowest
            near = max(p99Value, p1Value + 0.5)    // dark red = highest
        } else {
            near = p1Value                         // dark red = closest
            far = max(p99Value, p1Value + 1)       // dark blue = farthest
        }

        let stats = TopoStats(
            cellSize: cell, columns: cols, rows: rows,
            lengthMM: Double(cols) * cell, widthMM: Double(rows) * cell,
            coveragePercent: 100 * count / Double(mapCells),
            cellsWithData: sorted.count,
            meanHitsPerCell: hitTotal / count,
            mean: mean, variance: variance, stdDev: variance.squareRoot(),
            cvPercent: !heightMode && mean > 0 ? 100 * variance.squareRoot() / mean : nil,
            minimum: Double(sorted.first ?? 0), maximum: Double(sorted.last ?? 0),
            range: Double((sorted.last ?? 0) - (sorted.first ?? 0)),
            p1: p1Value, p5: percentile(0.05), median: percentile(0.5), p95: percentile(0.95), p99: p99Value,
            acrossStdDev: acrossSpread.std, acrossRange: acrossSpread.range,
            alongStdDev: alongSpread.std, alongRange: alongSpread.range,
            residualStdDev: residualN > 0 ? (residualSq / Double(residualN)).squareRoot() : 0,
            repeatStdDev: repeatN > 0 ? (repeatVarianceSum / Double(repeatN)).squareRoot() : 0,
            speedMean: speedMean, speedStdDev: speedStd,
            speedMin: readings.min(), speedMax: readings.max(),
            speedTrackedPercent: speeds.isEmpty ? 0 : 100 * Double(readings.count) / Double(speeds.count),
            colorNear: near, colorFar: far,
            frames: frameCount, duration: duration,
            heightMode: heightMode, mapMethod: cells.method, sensor: sensor,
            heightReference: heightMode ? heightReference : nil)
        let profiles = TopoProfiles(across: across, along: along)
        let gridFile = TopoGridFile(columns: cols, rows: rows, cell: cell, qMin: qMin, xMin: xMin,
                                    heightMode: heightMode, values: grid)

        // Colour image (downsampled if very long; a partial block at the end still gets a pixel).
        let factor = max(1, Int((Double(cols) / 12_000).rounded(.up)))
        let imageWidth = (cols + factor - 1) / factor
        let imageHeight = (rows + factor - 1) / factor
        var rgba = [UInt8](repeating: 0, count: imageWidth * imageHeight * 4)
        let nearF = Float(near), farF = Float(far)
        for iy in 0..<imageHeight {
            for ix in 0..<imageWidth {
                var total: Float = 0
                var n = 0
                for dy in 0..<factor {
                    let r = iy * factor + dy
                    if r >= rows { break }
                    for dx in 0..<factor {
                        let c = ix * factor + dx
                        if c >= cols { break }
                        let v = grid[r * cols + c]
                        if v.isFinite {
                            total += v
                            n += 1
                        }
                    }
                }
                guard n > 0 else { continue }
                let index = heightMode
                    ? DepthColors.index(value: total / Float(n), low: farF, high: nearF)
                    : DepthColors.index(distance: total / Float(n), near: nearF, far: farF)
                let color = DepthColors.lut[index]
                let o = (iy * imageWidth + ix) * 4
                rgba[o] = color.0
                rgba[o + 1] = color.1
                rgba[o + 2] = color.2
                rgba[o + 3] = 255
            }
        }
        guard let image = DepthColors.makeImage(rgba: rgba, width: imageWidth, height: imageHeight) else {
            throw LineError.notEnoughData
        }

        // Files: every output is written under a temporary name first and only renamed once all of them
        // succeeded, so a failure never leaves a mix of new and old files.
        let valueName = heightMode ? "mean_height_mm" : "mean_distance_mm"
        var files: [(name: String, write: (URL) throws -> Void)] = [
            ("TopoMapGrid.png", { url in
                guard Self.writePNG(image, to: url) else { throw LineError.badFile }
            }),
            ("TopoMap.csv", { url in try Self.writeGridCSV(gridFile, to: url) }),
            (TopoGridFile.fileName, { url in try gridFile.write(to: url) }),
            ("TopoStats.csv", { url in try Self.statsCSV(stats).write(to: url, atomically: false, encoding: .utf8) }),
            ("AcrossProfile.csv", { url in
                try Self.profileCSV(across, header: "across_mm", valueName: valueName)
                    .write(to: url, atomically: false, encoding: .utf8)
            }),
            ("AlongProfile.csv", { url in
                try Self.profileCSV(along, header: "along_mm", valueName: valueName)
                    .write(to: url, atomically: false, encoding: .utf8)
            }),
            ("TopoStats.json", { url in try JSONEncoder.pretty.encode(stats).write(to: url) }),
            ("TopoProfiles.json", { url in try JSONEncoder().encode(profiles).write(to: url) })
        ]
        if let composite {
            let png = try composite(image, stats)
            files.append(("TopoMap.png", { url in try png.write(to: url) }))
        }
        let extras = extraFiles(Geometry(columns: cols, rows: rows, cell: cell, qMin: qMin, xMin: xMin))
        files.append(contentsOf: extras)
        try Self.writeAll(in: folder, files)

        return Output(stats: stats, profiles: profiles, summary: summaryLines(stats, travel: travel) + extraLines,
                      mapImage: image, grid: gridFile)
    }

    /// Largest distance (mm) on the surface between neighbouring depth pixels anywhere in the frame: the smallest
    /// map cell that every frame fills without gaps between its own readings.
    ///
    /// A pixel at depth z (planar distance from the camera, as stored in Depth.bin) spans z/f on a surface parallel
    /// to the sensor. On a surface tilted by θ relative to the sensor, the pixel at normalised off-axis position
    /// a = (u − c)/f spans (z/f)/(1 − a·tan θ) (from x = a·z on the plane z = z₀ + x·tan θ), so the footprint grows
    /// towards the frame edge that is farther away. The bound combines
    /// - z: the farthest depth that lands on the map — the 99.5th percentile of the readings in up to 48 frames
    ///   (ignoring stray single readings), never less than the typical distance;
    /// - a: the outermost pixel edge used (inside the border), per axis and frame, taken as |a|;
    /// - θ: the 95th percentile of the per-frame phone-to-surface tilt from the LiDAR plane fit, capped at 20°;
    ///   frames without a tilt (older recordings) count as level.
    static func pixelFootprint(reader: DepthFileReader, frames: [LineFrameInfo], border: Int, sign: Double,
                               qRange: ClosedRange<Double>, xRange: ClosedRange<Double>,
                               typicalDepth: Double) -> Double {
        let w = reader.width
        let h = reader.height
        guard w > 2 * border, h > 2 * border else { return 0 }

        // Depth.bin stores 0.1 mm steps (UInt16), so a 0.1 mm histogram gives exact percentiles.
        let maxBin = Int(UInt16.max)
        var histogram = [Int](repeating: 0, count: maxBin + 1)
        var total = 0
        let step = max(1, frames.count / 48)
        for i in stride(from: 0, to: frames.count, by: step) {
            let f = frames[i]
            let fx = Double(f.fx), fy = Double(f.fy), cx = Double(f.cx), cy = Double(f.cy)
            guard fx > 0, fy > 0, let depth = reader.frame(i) else { continue }
            let offset = sign * f.travel
            depth.withUnsafeBufferPointer { zBuf in
                for v in border..<(h - border) {
                    let yFactor = (Double(v) - cy) / fy
                    let rowBase = v * w
                    for u in border..<(w - border) {
                        let z = zBuf[rowBase + u]
                        if z <= 0 { continue }
                        let zd = Double(z)
                        guard qRange.contains(offset - yFactor * zd),
                              xRange.contains((Double(u) - cx) / fx * zd) else { continue }
                        histogram[min(maxBin, Int((zd * 10).rounded()))] += 1
                        total += 1
                    }
                }
            }
        }
        var farDepth = typicalDepth
        if total > 0 {
            let target = Int((Double(total - 1) * 0.995).rounded())
            var cumulative = 0
            for (bin, n) in histogram.enumerated() where n > 0 {
                cumulative += n
                if cumulative > target {
                    farDepth = max(farDepth, Double(bin) / 10)
                    break
                }
            }
        }

        let tilts = frames.map { max(abs($0.surfaceTiltX ?? 0), abs($0.surfaceTiltY ?? 0)) }.sorted()
        let tiltIndex = min(tilts.count - 1, max(0, Int((Double(tilts.count - 1) * 0.95).rounded())))
        let tilt = tilts.isEmpty ? 0 : min(20, tilts[tiltIndex])
        let tanTilt = tan(tilt * .pi / 180)

        var perDepth = 0.0     // footprint per mm of depth
        for f in frames {
            let fx = Double(f.fx), fy = Double(f.fy), cx = Double(f.cx), cy = Double(f.cy)
            guard fx > 0, fy > 0 else { continue }
            let a = max(abs(Double(border) - cx), abs(Double(w - border) - cx)) / fx
            let b = max(abs(Double(border) - cy), abs(Double(h - border) - cy)) / fy
            perDepth = max(perDepth, 1 / fx / max(0.5, 1 - a * tanTilt), 1 / fy / max(0.5, 1 - b * tanTilt))
        }
        return farDepth * perDepth
    }

    /// Writes each file to a hidden temporary name, then renames them all into place.
    private static func writeAll(in folder: URL, _ files: [(name: String, write: (URL) throws -> Void)]) throws {
        let manager = FileManager.default
        var staged: [(temp: URL, final: URL)] = []
        do {
            for file in files {
                let temp = folder.appendingPathComponent(".\(file.name).partial")
                staged.append((temp, folder.appendingPathComponent(file.name)))
                try? manager.removeItem(at: temp)
                try file.write(temp)
            }
            for item in staged {
                if manager.fileExists(atPath: item.final.path) {
                    _ = try manager.replaceItemAt(item.final, withItemAt: item.temp)
                } else {
                    try manager.moveItem(at: item.temp, to: item.final)
                }
            }
        } catch {
            for item in staged { try? manager.removeItem(at: item.temp) }
            throw error
        }
    }

    // MARK: - Text

    /// Distance (mm) between the smallest and largest recorded travel of the frames: 0 when the material did not
    /// move in the map.
    static func travelRange(_ frames: [LineFrameInfo]) -> Double {
        guard let first = frames.first else { return 0 }
        var lo = first.travel
        var hi = first.travel
        for f in frames {
            lo = min(lo, f.travel)
            hi = max(hi, f.travel)
        }
        let range = hi - lo
        return range.isFinite ? range : 0
    }

    /// Summary lines of a map. `travel` is `travelRange` of the frames used: without any speed reading it says
    /// whether the map has zero travel or travel integrated from a speed held from before Record (a speed at most
    /// 2 s old at Record, Y-1, or any held speed in recordings from builds before Z-1).
    static func summaryLines(_ s: TopoStats, travel: Double = 0) -> [String] {
        var lines = [
            String(format: "Scanned %.2f m long × %.2f m wide, %@ mm cells, %.0f%% coverage",
                   s.lengthMM / 1000, s.widthMM / 1000, cellText(s.cellSize), s.coveragePercent),
            String(format: s.heightAboveBelt
                   ? "Height above the belt mean %.2f mm, std dev %.2f mm, variance %.2f mm²"
                   : s.heightMode == true
                   ? "Height above baseline mean %.2f mm, std dev %.2f mm, variance %.2f mm²"
                   : "Distance mean %.1f mm, std dev %.2f mm, variance %.2f mm²",
                   s.mean, s.stdDev, s.variance),
            String(format: "Range %.1f mm (min %.1f, max %.1f); P5–P95 %.1f mm",
                   s.range, s.minimum, s.maximum, s.p95 - s.p5),
            String(format: "Across-width profile: std dev %.2f mm, range %.1f mm", s.acrossStdDev, s.acrossRange),
            String(format: "Along-travel profile: std dev %.2f mm, range %.1f mm", s.alongStdDev, s.alongRange),
            s.isSingleReading
                ? String(format: "Local residual std dev %.2f mm; %.1f reading per cell", s.residualStdDev,
                         s.meanHitsPerCell)
                : String(format: "Local residual std dev %.2f mm; repeat-reading noise %.2f mm; %.1f readings per cell",
                         s.residualStdDev, s.repeatStdDev, s.meanHitsPerCell)
        ]
        if let m = s.speedMean, let sd = s.speedStdDev {
            lines.append(String(format: "Speed mean %.0f mm/s (%.2f m/min), std dev %.1f mm/s, tracked %.0f%% of frames",
                                m, m * 0.06, sd, s.speedTrackedPercent))
        } else if travel >= 0.5 {
            lines.append(String(format: "Speed: no texture lock; map travel %.0f mm comes from the speed held from "
                                + "before Record", travel))
        } else {
            lines.append("Speed: no texture lock (map uses zero travel)")
        }
        if s.heightAboveBelt {
            lines.append(String(format: "Colours: dark blue %.1f mm (low) → dark red %.1f mm (high) above the belt",
                                s.colorFar, s.colorNear))
        } else if s.heightMode == true {
            lines.append(String(format: "Colours: dark blue %.1f mm (low) → dark red %.1f mm (high) above the baseline",
                                s.colorFar, s.colorNear))
        } else {
            lines.append(String(format: "Colours: dark red %.0f mm (near) → dark blue %.0f mm (far); no baseline",
                                s.colorNear, s.colorFar))
        }
        return lines
    }

    /// Lines written by `summaryLines` (or a failed build), recognised so a rebuild can replace them in the
    /// scan record without touching other summary lines.
    private static let mapSummaryPrefixes = [
        "Scanned ", "Height above baseline mean", "Height above the belt mean", "Distance mean", "Range ",
        "Across-width profile", "Along-travel profile", "Local residual", "Speed mean", "Speed: no texture lock",
        "Colours:", "Map not built", "Map method:", "Height reference:", "Camera parallax:",
        // Lines of maps from the removed Laser line scan (P16), replaced when such a scan is rebuilt.
        "Laser line:", "Wall re-zero:",
        // Written by Line scan when Recording.json could not be read; obsolete once a map builds from it.
        "Recording.json could not be read back"
    ]

    /// Summary line added when Recording.json was repaired after being cut off (`LineRecordingInfo.repaired`,
    /// kept in the file, so every later rebuild adds it again). Same text as Line scan uses after recording.
    /// Not a map line: it stays through later rebuilds, once (`recordSummary`).
    static let recordingRepairedNote = "Recording.json was repaired after a write problem; the last frames may be missing."

    static func isMapSummaryLine(_ line: String) -> Bool {
        mapSummaryPrefixes.contains { line.hasPrefix($0) }
    }

    /// The scan record's summary after a rebuild: the recording line(s) kept, the map lines replaced.
    /// `recordingRepairedNote` appears once: a rebuild of a repaired recording brings it again in `map`.
    /// The frames-and-duration line is refreshed from `info` (Recording.json as read back), so it never shows
    /// frames that did not reach the file (Z-3).
    static func recordSummary(existing: [String], info: LineRecordingInfo, map: [String]) -> [String] {
        var lines = existing.filter { !isMapSummaryLine($0) }
        if map.contains(recordingRepairedNote) {
            lines.removeAll { $0 == recordingRepairedNote }
        }
        if let i = lines.firstIndex(where: LineRecordingInfo.isSummaryLine) {
            lines[i] = info.summaryLine
        }
        if lines.isEmpty {
            lines = [info.summaryLine]
        }
        lines.insert(contentsOf: map, at: 1)
        return lines
    }

    static func statsCSV(_ s: TopoStats) -> String {
        func f(_ v: Double?, _ digits: Int = 2) -> String {
            guard let v else { return "" }
            return String(format: "%.\(digits)f", v)
        }
        let p = s.heightMode == true ? "height" : "distance"
        let rows: [[String]] = [
            ["metric", "value", "unit"],
            ["values", s.heightAboveBelt
                ? (s.heightReference == .sideWalls ? "height_above_belt_side_walls" : "height_above_belt_camera_height")
                : s.heightMode == true ? "height_above_flat_baseline" : "distance_from_camera", ""],
            ["frames", "\(s.frames)", ""],
            ["duration", f(s.duration, 2), "s"],
            ["cell_size", f(s.cellSize, 1), "mm"],
            ["map_length", f(s.lengthMM, 0), "mm"],
            ["map_width", f(s.widthMM, 0), "mm"],
            ["coverage", f(s.coveragePercent, 1), "%"],
            ["cells_with_data", "\(s.cellsWithData)", ""],
            ["readings_per_cell_mean", f(s.meanHitsPerCell, 1), ""],
            [p + "_mean", f(s.mean, 2), "mm"],
            [p + "_variance", f(s.variance, 3), "mm^2"],
            [p + "_std_dev", f(s.stdDev, 3), "mm"],
            [p + "_cv", s.heightMode == true ? "" : f(s.cvPercent, 3), "%"],
            [p + "_min", f(s.minimum, 1), "mm"],
            [p + "_max", f(s.maximum, 1), "mm"],
            [p + "_range", f(s.range, 1), "mm"],
            [p + "_p1", f(s.p1, 1), "mm"],
            [p + "_p5", f(s.p5, 1), "mm"],
            [p + "_median", f(s.median, 1), "mm"],
            [p + "_p95", f(s.p95, 1), "mm"],
            [p + "_p99", f(s.p99, 1), "mm"],
            ["across_profile_std_dev", f(s.acrossStdDev, 3), "mm"],
            ["across_profile_range", f(s.acrossRange, 2), "mm"],
            ["along_profile_std_dev", f(s.alongStdDev, 3), "mm"],
            ["along_profile_range", f(s.alongRange, 2), "mm"],
            ["residual_std_dev", f(s.residualStdDev, 3), "mm"],
            ["repeat_reading_std_dev", s.isSingleReading ? "" : f(s.repeatStdDev, 3), "mm"],
            ["speed_mean", f(s.speedMean, 1), "mm/s"],
            ["speed_std_dev", f(s.speedStdDev, 2), "mm/s"],
            ["speed_min", f(s.speedMin, 1), "mm/s"],
            ["speed_max", f(s.speedMax, 1), "mm/s"],
            ["speed_tracked", f(s.speedTrackedPercent, 1), "%"],
            ["colour_dark_red", f(s.colorNear, 1), "mm"],
            ["colour_dark_blue", f(s.colorFar, 1), "mm"]
        ]
        return CSV.make(rows)
    }

    /// Cell size for text: whole millimetres as "10", finer cells (camera-parallax maps) as "5.3".
    static func cellText(_ cell: Double) -> String {
        abs(cell - cell.rounded()) < 0.05 ? String(format: "%.0f", cell) : String(format: "%.1f", cell)
    }

    static func profileCSV(_ points: [ProfilePoint], header: String, valueName: String) -> String {
        var rows: [[String]] = [[header, valueName, "cells"]]
        for p in points {
            rows.append([String(format: "%.1f", p.position), String(format: "%.2f", p.value), "\(p.cells)"])
        }
        return CSV.make(rows)
    }

    @inline(__always)
    private static func tenths(_ v: Float) -> String {
        let t = Int((v * 10).rounded())
        let a = abs(t)
        return (t < 0 ? "-" : "") + "\(a / 10).\(a % 10)"
    }

    /// Rows = across (top → bottom of the screen, mm from the image centre line), columns = along (left → right,
    /// mm from the left edge of the map). Blank = no data. Same cells as TopoGrid.bin.
    static func writeGridCSV(_ grid: TopoGridFile, to url: URL) throws {
        let rows = grid.rows
        let cols = grid.columns
        let writer = try TextFileWriter(url: url)
        // Whole-millimetre cells keep their whole-millimetre labels; finer cells (parallax maps) get 0.01 mm labels so
        // neighbouring labels stay distinct.
        let label = abs(grid.cell - grid.cell.rounded()) < 1e-9 ? "%.0f" : "%.2f"
        var header = ["across_mm \\ along_mm"]
        header.reserveCapacity(cols + 1)
        for c in 0..<cols { header.append(String(format: label, (Double(c) + 0.5) * grid.cell)) }
        try writer.line(header.joined(separator: ","))
        var fields = [String]()
        fields.reserveCapacity(cols + 1)
        for r in 0..<rows {
            fields.removeAll(keepingCapacity: true)
            fields.append(String(format: label, grid.xMin + (Double(r) + 0.5) * grid.cell))
            for c in 0..<cols {
                let v = grid.values[r * cols + c]
                fields.append(v.isFinite ? tenths(v) : "")
            }
            try writer.line(fields.joined(separator: ","))
        }
        try writer.close()
    }

    @discardableResult
    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
