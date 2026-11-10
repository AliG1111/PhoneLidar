import CoreGraphics
import XCTest

/// End-to-end tests of the topographic map builder on synthetic recordings. The recordings are written
/// with the real `DepthFileWriter`, so these also exercise Depth.bin, Baseline.bin and TopoGrid.bin.
///
/// Geometry of the synthetic camera: depth map 64 × 48 pixels, focal length 100 px, principal point at the
/// centre, flat reference surface 1000 mm away (one pixel = 10 mm on the surface = one map cell).
final class TopoMapBuilderTests: XCTestCase {
    private let referenceDistance = 1000.0
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try makeTempFolder()
    }

    /// Writes Depth.bin (and optionally Baseline.bin/json) for material that moves past the camera, and returns
    /// the matching recording info.
    ///
    /// - `surface(q, x)`: height of the material above the reference surface (mm) at material coordinate `q`
    ///   (along the travel, fixed to the material) and across position `x`; nil = no depth reading.
    /// - `mask(u, v)`: which depth pixels return data at all.
    @discardableResult
    private func writeRecording(width: Int = 64, height: Int = 48, frameCount: Int = 80,
                                depthFrameCount: Int? = nil, travelStep: Double = 7.3,
                                direction: TravelDirection = .rightToLeft, withBaseline: Bool = false,
                                baselineSize: (Int, Int)? = nil,
                                speed: (Int) -> Double? = { _ in 219 },
                                mask: (Int, Int) -> Bool = { _, _ in true },
                                surface: (Double, Double) -> Double? = { _, _ in 0 }) throws -> LineRecordingInfo {
        let fx = 100.0
        let cx = Double(width) / 2
        let cy = Double(height) / 2
        let sign = Double(direction.bufferSign)
        let writer = try DepthFileWriter(url: folder.appendingPathComponent("Depth.bin"), width: width, height: height)
        var frames: [LineFrameInfo] = []
        for i in 0..<frameCount {
            let travel = Double(i) * travelStep
            frames.append(makeFrame(index: i, time: Double(i) / 30, speed: speed(i), travel: travel,
                                    medianDepth: referenceDistance, fx: Float(fx), fy: Float(fx),
                                    cx: Float(cx), cy: Float(cy)))
            guard i < (depthFrameCount ?? frameCount) else { continue }
            var depth = [Float](repeating: 0, count: width * height)
            for v in 0..<height {
                let q = sign * travel - (Double(v) - cy) / fx * referenceDistance
                for u in 0..<width where mask(u, v) {
                    let x = (Double(u) - cx) / fx * referenceDistance
                    if let h = surface(q, x) {
                        depth[v * width + u] = Float(referenceDistance - h)
                    }
                }
            }
            try writer.append(millimetres: depth)
        }
        writer.close()

        if withBaseline {
            let (bw, bh) = baselineSize ?? (width, height)
            let info = BaselineInfo(width: bw, height: bh, created: Date(), frames: 90,
                                    meanDistance: referenceDistance, rawStdDev: 0, rawRange: 0,
                                    correctedStdDev: 0, coveragePercent: 100, tiltX: nil, tiltY: nil,
                                    filteredDepth: true)
            let baseline = Baseline(info: info, values: [Float](repeating: Float(referenceDistance), count: bw * bh))
            try baseline.save(to: folder)
        }
        return LineRecordingInfo(depthWidth: width, depthHeight: height, videoWidth: 1080, videoHeight: 1920,
                                 filteredDepth: true, shortShutter: true, direction: direction, frames: frames)
    }

    private func loadGrid() throws -> TopoGridFile {
        try XCTUnwrap(TopoGridFile.load(from: folder))
    }

    /// Mean of the finite cells of each column, with the column's map coordinate q (mm) at its centre.
    private func columnMeans(_ grid: TopoGridFile) -> [(q: Double, mean: Double)] {
        var out: [(q: Double, mean: Double)] = []
        for c in 0..<grid.columns {
            var sum = 0.0
            var n = 0
            for r in 0..<grid.rows {
                let v = grid.values[r * grid.columns + c]
                if v.isFinite {
                    sum += Double(v)
                    n += 1
                }
            }
            if n > 0 { out.append((grid.qMin + (Double(c) + 0.5) * grid.cell, sum / Double(n))) }
        }
        return out
    }

    /// Mean of the finite cells of each row, with the row's across position x (mm) at its centre.
    private func rowMeans(_ grid: TopoGridFile) -> [(x: Double, mean: Double)] {
        var out: [(x: Double, mean: Double)] = []
        for r in 0..<grid.rows {
            var sum = 0.0
            var n = 0
            for c in 0..<grid.columns {
                let v = grid.values[r * grid.columns + c]
                if v.isFinite {
                    sum += Double(v)
                    n += 1
                }
            }
            if n > 0 { out.append((grid.xMin + (Double(r) + 0.5) * grid.cell, sum / Double(n))) }
        }
        return out
    }

    private func rowHasData(_ grid: TopoGridFile, row: Int) -> Bool {
        (0..<grid.columns).contains { grid.values[row * grid.columns + $0].isFinite }
    }

    private func columnHasData(_ grid: TopoGridFile, column: Int) -> Bool {
        (0..<grid.rows).contains { grid.values[$0 * grid.columns + column].isFinite }
    }

    // MARK: - Statistics

    func testFlatSurfaceInDistanceModeHasNoVariance() throws {
        let info = try writeRecording()
        let output = try TopoMapBuilder.build(folder: folder, info: info)
        let s = output.stats
        XCTAssertEqual(s.heightMode, false)
        XCTAssertEqual(s.mean, 1000, accuracy: 0.01)
        XCTAssertEqual(s.variance, 0, accuracy: 1e-3)
        XCTAssertEqual(s.stdDev, 0, accuracy: 1e-3)
        XCTAssertEqual(try XCTUnwrap(s.cvPercent), 0, accuracy: 1e-3)
        XCTAssertEqual(s.minimum, 1000, accuracy: 0.01)
        XCTAssertEqual(s.maximum, 1000, accuracy: 0.01)
        XCTAssertEqual(s.range, 0, accuracy: 0.01)
        for p in [s.p1, s.p5, s.median, s.p95, s.p99] { XCTAssertEqual(p, 1000, accuracy: 0.01) }
        XCTAssertEqual(s.acrossStdDev, 0, accuracy: 1e-3)
        XCTAssertEqual(s.alongStdDev, 0, accuracy: 1e-3)
        XCTAssertEqual(s.residualStdDev, 0, accuracy: 1e-3)
        XCTAssertEqual(s.repeatStdDev, 0, accuracy: 1e-3)
        // Colour scale: dark red = closest (P1), dark blue = at least 1 mm farther.
        XCTAssertEqual(s.colorNear, 1000, accuracy: 0.01)
        XCTAssertEqual(s.colorFar, 1001, accuracy: 0.01)
    }

    func testTwoLevelSurfaceInDistanceModeGivesKnownMeanVarianceAndPercentiles() throws {
        // Half of the width (x >= 0) is 10 mm closer to the camera: distances 990 and 1000 mm.
        let info = try writeRecording(surface: { _, x in x >= 0 ? 10 : 0 })
        let s = try TopoMapBuilder.build(folder: folder, info: info).stats
        XCTAssertEqual(s.mean, 995, accuracy: 0.4)
        XCTAssertEqual(s.stdDev, 5, accuracy: 0.2)
        XCTAssertEqual(s.variance, s.stdDev * s.stdDev, accuracy: 1e-6)
        XCTAssertEqual(s.variance, 25, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(s.cvPercent), 100 * s.stdDev / s.mean, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(s.cvPercent), 0.5025, accuracy: 0.03)
        XCTAssertEqual(s.minimum, 990, accuracy: 0.01)
        XCTAssertEqual(s.maximum, 1000, accuracy: 0.01)
        XCTAssertEqual(s.range, 10, accuracy: 0.02)
        XCTAssertEqual(s.p1, 990, accuracy: 0.01)
        XCTAssertEqual(s.p5, 990, accuracy: 0.01)
        XCTAssertEqual(s.p95, 1000, accuracy: 0.01)
        XCTAssertEqual(s.p99, 1000, accuracy: 0.01)
        XCTAssertTrue(s.p1 <= s.p5 && s.p5 <= s.median && s.median <= s.p95 && s.p95 <= s.p99)
        XCTAssertEqual(s.colorNear, s.p1, accuracy: 1e-9)
        XCTAssertEqual(s.colorFar, s.p99, accuracy: 1e-9)
        // The step is across the material, so almost all variation is in the across profile.
        XCTAssertEqual(s.acrossStdDev, 5, accuracy: 0.3)
        XCTAssertLessThan(s.alongStdDev, 1.0)
        XCTAssertLessThan(s.residualStdDev, 1.0)
    }

    func testHeightModeWithABaselineReportsHeightsAboveTheSurface() throws {
        let info = try writeRecording(withBaseline: true, surface: { _, x in x >= 0 ? 5 : 0 })
        let output = try TopoMapBuilder.build(folder: folder, info: info)
        let s = output.stats
        XCTAssertEqual(s.heightMode, true)
        XCTAssertEqual(s.mean, 2.5, accuracy: 0.15)
        XCTAssertEqual(s.stdDev, 2.5, accuracy: 0.1)
        XCTAssertEqual(s.variance, 6.25, accuracy: 0.6)
        XCTAssertNil(s.cvPercent)      // the coefficient of variation is only reported for distances (B-7)
        XCTAssertEqual(s.minimum, 0, accuracy: 0.01)
        XCTAssertEqual(s.maximum, 5, accuracy: 0.01)
        XCTAssertEqual(s.range, 5, accuracy: 0.02)
        XCTAssertEqual(s.p1, 0, accuracy: 0.01)
        XCTAssertEqual(s.p99, 5, accuracy: 0.01)
        // Colours: dark blue = lowest (P1), dark red = highest (P99).
        XCTAssertEqual(s.colorFar, 0, accuracy: 0.01)
        XCTAssertEqual(s.colorNear, 5, accuracy: 0.01)
        XCTAssertEqual(s.repeatStdDev, 0, accuracy: 1e-3)
        XCTAssertEqual(output.summary[1].hasPrefix("Height above baseline mean"), true)
    }

    func testBaselineOfAnotherSizeIsIgnored() throws {
        let info = try writeRecording(withBaseline: true, baselineSize: (32, 24))
        let s = try TopoMapBuilder.build(folder: folder, info: info).stats
        XCTAssertEqual(s.heightMode, false)
        XCTAssertEqual(s.mean, 1000, accuracy: 0.01)
    }

    func testSpeedStatistics() throws {
        // Every other frame has a speed: 100 and 300 mm/s alternating on the tracked frames.
        let info = try writeRecording(frameCount: 40, speed: { i in
            i % 2 == 0 ? (i % 4 == 0 ? 100 : 300) : nil
        })
        let s = try TopoMapBuilder.build(folder: folder, info: info).stats
        XCTAssertEqual(try XCTUnwrap(s.speedMean), 200, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(s.speedStdDev), 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(s.speedMin), 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(s.speedMax), 300, accuracy: 1e-9)
        XCTAssertEqual(s.speedTrackedPercent, 50, accuracy: 1e-9)
    }

    func testNoSpeedsLeavesTheSpeedStatisticsEmpty() throws {
        let info = try writeRecording(frameCount: 40, speed: { _ in nil })
        let s = try TopoMapBuilder.build(folder: folder, info: info).stats
        XCTAssertNil(s.speedMean)
        XCTAssertNil(s.speedStdDev)
        XCTAssertNil(s.speedMin)
        XCTAssertNil(s.speedMax)
        XCTAssertEqual(s.speedTrackedPercent, 0)
    }

    func testRecordingSizeAndCoverageStatistics() throws {
        let info = try writeRecording()
        let output = try TopoMapBuilder.build(folder: folder, info: info)
        let s = output.stats
        XCTAssertEqual(s.frames, 80)
        XCTAssertEqual(s.duration, 79.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(s.cellSize, 10, accuracy: 1e-9)           // one depth pixel on the surface
        XCTAssertEqual(s.lengthMM, Double(s.columns) * s.cellSize, accuracy: 1e-9)
        XCTAssertEqual(s.widthMM, Double(s.rows) * s.cellSize, accuracy: 1e-9)
        // Length and width describe the observed material only (B-4): the travelled distance (79 × 7.3 mm)
        // plus the 430 mm between the first and last depth row seen, and the 590 mm between the first and last
        // depth column seen — each within one cell of the cell-aligned extent.
        XCTAssertEqual(s.lengthMM, 79 * 7.3 + 430, accuracy: 20)
        XCTAssertEqual(s.widthMM, 590, accuracy: 20)
        XCTAssertGreaterThan(s.coveragePercent, 98)
        XCTAssertLessThanOrEqual(s.coveragePercent, 100)
        XCTAssertGreaterThan(s.meanHitsPerCell, 1)
        XCTAssertEqual(s.coveragePercent, 100 * Double(s.cellsWithData) / Double(s.columns * s.rows), accuracy: 1e-9)
        XCTAssertEqual(output.mapImage.width, s.columns)
        XCTAssertEqual(output.mapImage.height, s.rows)
        XCTAssertEqual(output.summary.count, 8)
    }

    func testOnlyAsManyFramesAsDepthDataExistAreUsed() throws {
        let info = try writeRecording(frameCount: 80, depthFrameCount: 30)
        XCTAssertEqual(info.frames.count, 80)
        let s = try TopoMapBuilder.build(folder: folder, info: info).stats
        XCTAssertEqual(s.frames, 30)
    }

    // MARK: - Stitching geometry

    private func assertRidgeIsStitchedAtItsMaterialPosition(direction: TravelDirection, heightMode: Bool) throws {
        // A 200 mm long ridge, 5 mm high, fixed to the material at q = ±300 mm (the sign follows the direction
        // because q = sign · travel − y).
        let centre = 300.0 * Double(direction.bufferSign)
        let info = try writeRecording(direction: direction, withBaseline: heightMode, surface: { q, _ in
            abs(q - centre) <= 100 ? 5 : 0
        })
        _ = try TopoMapBuilder.build(folder: folder, info: info)
        let grid = try loadGrid()
        XCTAssertEqual(grid.heightMode, heightMode)
        let base: Double = heightMode ? 0 : 1000
        let ridge: Double = heightMode ? 5 : 995
        var onRidge = 0
        var offRidge = 0
        for column in columnMeans(grid) {
            let distance = abs(column.q - centre)
            if distance <= 80 {
                XCTAssertEqual(column.mean, ridge, accuracy: 0.5, "q = \(column.q)")
                onRidge += 1
            } else if distance >= 120 && distance <= 250 {
                XCTAssertEqual(column.mean, base, accuracy: 0.5, "q = \(column.q)")
                offRidge += 1
            }
        }
        XCTAssertGreaterThan(onRidge, 10)
        XCTAssertGreaterThan(offRidge, 20)
    }

    func testRightToLeftTravelStitchesMaterialFeaturesAtTheirPositionInHeightMode() throws {
        try assertRidgeIsStitchedAtItsMaterialPosition(direction: .rightToLeft, heightMode: true)
    }

    func testLeftToRightTravelStitchesMaterialFeaturesAtTheirPositionInHeightMode() throws {
        try assertRidgeIsStitchedAtItsMaterialPosition(direction: .leftToRight, heightMode: true)
    }

    func testRidgeIsStitchedInDistanceMode() throws {
        try assertRidgeIsStitchedAtItsMaterialPosition(direction: .rightToLeft, heightMode: false)
    }

    func testAcrossPositionsMapToRowsTopToBottom() throws {
        // The right half of the material (x >= 0, bottom of the screen) is 5 mm high.
        let info = try writeRecording(withBaseline: true, surface: { _, x in x >= 0 ? 5 : 0 })
        _ = try TopoMapBuilder.build(folder: folder, info: info)
        let grid = try loadGrid()
        var high = 0
        var low = 0
        for row in rowMeans(grid) {
            if row.x >= 20 {
                XCTAssertEqual(row.mean, 5, accuracy: 0.1, "x = \(row.x)")
                high += 1
            } else if row.x <= -20 {
                XCTAssertEqual(row.mean, 0, accuracy: 0.1, "x = \(row.x)")
                low += 1
            }
        }
        XCTAssertGreaterThan(high, 15)
        XCTAssertGreaterThan(low, 15)
    }

    func testProfilesFollowTheSurface() throws {
        let info = try writeRecording(withBaseline: true, surface: { _, x in x >= 0 ? 5 : 0 })
        let output = try TopoMapBuilder.build(folder: folder, info: info)
        let across = output.profiles.across
        XCTAssertGreaterThan(across.count, 40)
        XCTAssertEqual(across.map(\.position), across.map(\.position).sorted())
        for point in across where point.position >= 20 { XCTAssertEqual(point.value, 5, accuracy: 0.1) }
        for point in across where point.position <= -20 { XCTAssertEqual(point.value, 0, accuracy: 0.1) }
        // Along the travel the surface is uniform, so every column has the same mean.
        let along = output.profiles.along
        XCTAssertGreaterThan(along.count, 50)
        let values = along.map(\.value)
        XCTAssertLessThan((values.max() ?? 0) - (values.min() ?? 0), 0.6)
        XCTAssertTrue(along.allSatisfy { $0.cells > 0 })
    }

    // MARK: - Files written

    func testBuildWritesTheDocumentedFiles() throws {
        let info = try writeRecording(withBaseline: true, surface: { _, x in x >= 0 ? 5 : 0 })
        let output = try TopoMapBuilder.build(folder: folder, info: info)
        let names = ["TopoMapGrid.png", "TopoMap.csv", "TopoGrid.bin", "TopoStats.csv", "AcrossProfile.csv",
                     "AlongProfile.csv", "TopoStats.json", "TopoProfiles.json"]
        for name in names {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), name)
        }

        // TopoGrid.bin describes the same cells as the statistics.
        let grid = try loadGrid()
        XCTAssertEqual(grid.columns, output.stats.columns)
        XCTAssertEqual(grid.rows, output.stats.rows)
        XCTAssertEqual(grid.cell, output.stats.cellSize, accuracy: 1e-9)
        XCTAssertTrue(grid.heightMode)
        XCTAssertEqual(grid.values.filter { $0.isFinite }.count, output.stats.cellsWithData)

        // TopoMap.csv: a header plus one line per row, each with a label and one field per column.
        let csv = try String(contentsOf: folder.appendingPathComponent("TopoMap.csv"), encoding: .utf8)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, grid.rows + 1)
        for line in lines {
            XCTAssertEqual(line.split(separator: ",", omittingEmptySubsequences: false).count, grid.columns + 1)
        }
        XCTAssertTrue(lines[0].hasPrefix("across_mm \\ along_mm,5,15,25"), String(lines[0]))
        // Rows are labelled from the observed edge of the material: the first depth column seen is at −300 mm.
        XCTAssertTrue(lines[1].hasPrefix("-300,"), String(lines[1]))
        XCTAssertTrue(csv.contains(",5.0"))
        XCTAssertTrue(csv.contains(",0.0"))

        // TopoStats.json and TopoProfiles.json decode back to the returned values.
        let stats = try JSONDecoder().decode(TopoStats.self,
                                             from: Data(contentsOf: folder.appendingPathComponent("TopoStats.json")))
        XCTAssertEqual(stats.mean, output.stats.mean, accuracy: 1e-9)
        XCTAssertEqual(stats.columns, output.stats.columns)
        XCTAssertEqual(stats.heightMode, true)
        let profiles = try JSONDecoder().decode(TopoProfiles.self,
                                                from: Data(contentsOf: folder.appendingPathComponent("TopoProfiles.json")))
        XCTAssertEqual(profiles.across.count, output.profiles.across.count)
        XCTAssertEqual(profiles.along.count, output.profiles.along.count)

        let acrossCSV = try String(contentsOf: folder.appendingPathComponent("AcrossProfile.csv"), encoding: .utf8)
        XCTAssertTrue(acrossCSV.hasPrefix("across_mm,mean_height_mm,cells\n"))
        let alongCSV = try String(contentsOf: folder.appendingPathComponent("AlongProfile.csv"), encoding: .utf8)
        XCTAssertTrue(alongCSV.hasPrefix("along_mm,mean_height_mm,cells\n"))
        let statsCSV = try String(contentsOf: folder.appendingPathComponent("TopoStats.csv"), encoding: .utf8)
        XCTAssertTrue(statsCSV.contains("\nheight_mean,"))
    }

    func testDistanceModeFilesUseDistanceNames() throws {
        let info = try writeRecording()
        _ = try TopoMapBuilder.build(folder: folder, info: info)
        let acrossCSV = try String(contentsOf: folder.appendingPathComponent("AcrossProfile.csv"), encoding: .utf8)
        XCTAssertTrue(acrossCSV.hasPrefix("across_mm,mean_distance_mm,cells\n"))
        let statsCSV = try String(contentsOf: folder.appendingPathComponent("TopoStats.csv"), encoding: .utf8)
        XCTAssertTrue(statsCSV.contains("\ndistance_mean,1000.00,mm\n"), statsCSV)
        XCTAssertFalse(try loadGrid().heightMode)
    }

    // MARK: - Observed extent, coverage and origins (B-4)

    func testGapFreeScanHasFullCoverageAndNoEmptyMargin() throws {
        let info = try writeRecording(withBaseline: true, surface: { _, x in x >= 0 ? 5 : 0 })
        let output = try TopoMapBuilder.build(folder: folder, info: info)
        let s = output.stats
        // Every cell between the first and last reading has data; the padding around them is not counted.
        XCTAssertGreaterThan(s.coveragePercent, 98)
        XCTAssertLessThanOrEqual(s.coveragePercent, 100)
        let grid = try loadGrid()
        XCTAssertTrue(rowHasData(grid, row: 0))
        XCTAssertTrue(rowHasData(grid, row: grid.rows - 1))
        XCTAssertTrue(columnHasData(grid, column: 0))
        XCTAssertTrue(columnHasData(grid, column: grid.columns - 1))
        // The map is exactly the observed extent: 60 depth columns of 10 mm across the material.
        XCTAssertEqual(s.widthMM, 600, accuracy: 10.5)
        XCTAssertEqual(s.lengthMM, 79 * 7.3 + 430, accuracy: 20)
    }

    func testHolesInTheDataLowerTheCoverageButPaddingDoesNot() throws {
        // Depth columns 10…19 never return data: 10 of the 60 map rows are empty inside the observed extent.
        let info = try writeRecording(mask: { u, _ in u < 10 || u >= 20 })
        let s = try TopoMapBuilder.build(folder: folder, info: info).stats
        XCTAssertEqual(s.rows, 60)
        XCTAssertEqual(s.coveragePercent, 100 * 50.0 / 60.0, accuracy: 1.5)
        XCTAssertEqual(s.coveragePercent, 100 * Double(s.cellsWithData) / Double(s.columns * s.rows), accuracy: 1e-9)
    }

    func testProfilesStartAtTheObservedEdgesOfTheMaterial() throws {
        let info = try writeRecording()
        let output = try TopoMapBuilder.build(folder: folder, info: info)
        let cell = output.stats.cellSize
        // Along the travel: the first column of the map is the start of the material.
        let along = try XCTUnwrap(output.profiles.along.first)
        XCTAssertEqual(along.position, cell / 2, accuracy: 1e-9)
        let lastAlong = try XCTUnwrap(output.profiles.along.last)
        XCTAssertEqual(lastAlong.position, output.stats.lengthMM - cell / 2, accuracy: 1e-6)
        // Across the material: from the first to the last depth column seen (−300 … 290 mm).
        let first = try XCTUnwrap(output.profiles.across.first)
        let last = try XCTUnwrap(output.profiles.across.last)
        XCTAssertEqual(first.position, -300, accuracy: 6)
        XCTAssertEqual(last.position, 290, accuracy: 6)
    }

    private func assertGridOriginsFollowTheObservedExtent(direction: TravelDirection) throws {
        let info = try writeRecording(direction: direction)
        let output = try TopoMapBuilder.build(folder: folder, info: info)
        let grid = try loadGrid()
        XCTAssertEqual(grid.columns, output.stats.columns)
        XCTAssertEqual(grid.rows, output.stats.rows)
        // The first sample is at q = −210 mm (right → left) or −576.7 − 210 mm (left → right); the grid starts
        // at the left edge of the cell holding it, which is less than one cell before it.
        let firstSampleQ = direction == .rightToLeft ? -210.0 : -(79 * 7.3) - 210
        XCTAssertLessThanOrEqual(grid.qMin, firstSampleQ + 1e-6)
        XCTAssertGreaterThan(grid.qMin, firstSampleQ - grid.cell - 1e-6)
        XCTAssertLessThanOrEqual(grid.xMin, -300 + 1e-6)
        XCTAssertGreaterThan(grid.xMin, -300 - grid.cell - 1e-6)
    }

    func testGridOriginsFollowTheObservedExtentRightToLeft() throws {
        try assertGridOriginsFollowTheObservedExtent(direction: .rightToLeft)
    }

    func testGridOriginsFollowTheObservedExtentLeftToRight() throws {
        try assertGridOriginsFollowTheObservedExtent(direction: .leftToRight)
    }

    // MARK: - Image size (B-16)

    func testLongMapIsDownsampledWithPartialBlocksRoundedUp() throws {
        // 1.6 m between frames: a map of about 12,700 columns, more than the 12,000 one image holds, so every
        // pixel of the picture covers 2 × 2 cells. Depth column 61 returns nothing, leaving an odd 59 rows.
        let info = try writeRecording(travelStep: 1600, mask: { u, _ in u != 61 })
        let output = try TopoMapBuilder.build(folder: folder, info: info)
        let s = output.stats
        XCTAssertGreaterThan(s.columns, 12_000)
        XCTAssertEqual(s.rows, 59)
        XCTAssertEqual(output.mapImage.width, (s.columns + 1) / 2)
        XCTAssertEqual(output.mapImage.height, 30)      // 59 rows → 29 full blocks and one partial block
    }

    // MARK: - Optional CV (B-7)

    func testCVIsBlankInTheCSVAndOmittedFromTheJSONInHeightMode() throws {
        let info = try writeRecording(withBaseline: true, surface: { _, x in x >= 0 ? 5 : 0 })
        _ = try TopoMapBuilder.build(folder: folder, info: info)
        let csv = try String(contentsOf: folder.appendingPathComponent("TopoStats.csv"), encoding: .utf8)
        XCTAssertTrue(csv.contains("\nheight_cv,,%\n"), csv)
        let data = try Data(contentsOf: folder.appendingPathComponent("TopoStats.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["cvPercent"])
        XCTAssertEqual(object["heightMode"] as? Bool, true)
        XCTAssertNotNil(object["stdDev"])
        XCTAssertNil(try JSONDecoder().decode(TopoStats.self, from: data).cvPercent)
    }

    func testCVIsWrittenInDistanceMode() throws {
        let info = try writeRecording(surface: { _, x in x >= 0 ? 10 : 0 })
        let output = try TopoMapBuilder.build(folder: folder, info: info)
        let csv = try String(contentsOf: folder.appendingPathComponent("TopoStats.csv"), encoding: .utf8)
        XCTAssertTrue(csv.contains("\ndistance_cv,0."), csv)
        let data = try Data(contentsOf: folder.appendingPathComponent("TopoStats.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cv = try XCTUnwrap(object["cvPercent"] as? Double)
        XCTAssertEqual(cv, try XCTUnwrap(output.stats.cvPercent), accuracy: 1e-9)
        XCTAssertGreaterThan(cv, 0)
    }

    func testOlderStatsFilesWithAZeroCVStillDecode() throws {
        let info = try writeRecording(withBaseline: true)
        _ = try TopoMapBuilder.build(folder: folder, info: info)
        let data = try Data(contentsOf: folder.appendingPathComponent("TopoStats.json"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["cvPercent"] = 0
        let older = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try JSONDecoder().decode(TopoStats.self, from: older).cvPercent, 0)
    }

    // MARK: - Damaged baseline

    func testNonFiniteBaselinePixelsAreSkippedSoNoNaNReachesTheOutputs() throws {
        let info = try writeRecording(withBaseline: true)
        // Overwrite Baseline.bin with a baseline that has NaN at depth columns 10 and 11 and infinity at column 20.
        var values = [Float](repeating: Float(referenceDistance), count: 64 * 48)
        for v in 0..<48 {
            values[v * 64 + 10] = .nan
            values[v * 64 + 11] = .nan
            values[v * 64 + 20] = .infinity
        }
        let baselineInfo = BaselineInfo(width: 64, height: 48, created: Date(), frames: 90,
                                        meanDistance: referenceDistance, rawStdDev: 0, rawRange: 0,
                                        correctedStdDev: 0, coveragePercent: 100, tiltX: nil, tiltY: nil,
                                        filteredDepth: true)
        try Baseline(info: baselineInfo, values: values).save(to: folder)

        let output = try TopoMapBuilder.build(folder: folder, info: info)
        let s = output.stats
        XCTAssertEqual(s.heightMode, true)
        XCTAssertTrue(s.mean.isFinite && s.stdDev.isFinite && s.minimum.isFinite && s.maximum.isFinite)
        XCTAssertEqual(s.mean, 0, accuracy: 1e-3)
        // Three of the 60 map rows have no readings.
        XCTAssertEqual(s.coveragePercent, 100 * 57.0 / 60.0, accuracy: 1.5)
        let csv = try String(contentsOf: folder.appendingPathComponent("TopoMap.csv"), encoding: .utf8).lowercased()
        XCTAssertFalse(csv.contains("nan"))
        XCTAssertFalse(csv.contains("inf"))
        XCTAssertFalse(try loadGrid().values.contains { $0.isInfinite })
    }

    // MARK: - Output files are replaced as a set (B-17)

    func testBuildLeavesNoTemporaryFilesBehind() throws {
        let info = try writeRecording(withBaseline: true)
        _ = try TopoMapBuilder.build(folder: folder, info: info)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)      // includes hidden files
        XCTAssertTrue(names.filter { $0.hasSuffix(".partial") }.isEmpty, "\(names)")
        XCTAssertTrue(names.contains("TopoStats.json"))
    }

    func testRebuildReplacesTheExistingOutputs() throws {
        let info = try writeRecording(withBaseline: true, surface: { _, x in x >= 0 ? 5 : 0 })
        let first = try TopoMapBuilder.build(folder: folder, info: info)
        let statsURL = folder.appendingPathComponent("TopoStats.json")
        let csvURL = folder.appendingPathComponent("TopoMap.csv")
        try Data("old".utf8).write(to: statsURL)
        try Data("old".utf8).write(to: csvURL)
        let second = try TopoMapBuilder.build(folder: folder, info: info)
        XCTAssertEqual(second.stats.mean, first.stats.mean, accuracy: 1e-9)
        let stats = try JSONDecoder().decode(TopoStats.self, from: Data(contentsOf: statsURL))
        XCTAssertEqual(stats.mean, first.stats.mean, accuracy: 1e-9)
        XCTAssertGreaterThan(try Data(contentsOf: csvURL).count, 1000)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(names.filter { $0.hasSuffix(".partial") }.isEmpty, "\(names)")
    }

    func testFailedBuildKeepsThePreviousOutputs() throws {
        let info = try writeRecording(withBaseline: true)
        _ = try TopoMapBuilder.build(folder: folder, info: info)
        let statsURL = folder.appendingPathComponent("TopoStats.json")
        let before = try Data(contentsOf: statsURL)
        var tooShort = info
        tooShort.frames = Array(info.frames.prefix(1))
        XCTAssertThrowsError(try TopoMapBuilder.build(folder: folder, info: tooShort))
        XCTAssertEqual(try Data(contentsOf: statsURL), before)
        XCTAssertNotNil(TopoGridFile.load(from: folder))
    }

    // MARK: - Empty and unusable input

    func testRecordingWithoutAnyDepthDataIsRejected() throws {
        let info = try writeRecording(surface: { _, _ in nil })      // every pixel is "no data"
        XCTAssertThrowsError(try TopoMapBuilder.build(folder: folder, info: info)) {
            assertLineError($0, .notEnoughData)
        }
        XCTAssertNil(TopoGridFile.load(from: folder))
    }

    func testTooFewMapCellsAreRejected() throws {
        // Two frames and a single valid pixel: two cells with data, fewer than the minimum of ten.
        let info = try writeRecording(frameCount: 2, mask: { u, v in u == 32 && v == 24 })
        XCTAssertThrowsError(try TopoMapBuilder.build(folder: folder, info: info)) {
            assertLineError($0, .notEnoughData)
        }
    }

    func testFewerThanTwoFramesAreRejected() throws {
        let info = try writeRecording(frameCount: 1)
        XCTAssertThrowsError(try TopoMapBuilder.build(folder: folder, info: info)) {
            assertLineError($0, .notEnoughData)
        }
    }

    func testRecordingWithoutAMedianDepthIsRejected() throws {
        var info = try writeRecording()
        info.frames = info.frames.map { frame in
            var copy = frame
            copy.medianDepth = 0
            return copy
        }
        XCTAssertThrowsError(try TopoMapBuilder.build(folder: folder, info: info)) {
            assertLineError($0, .notEnoughData)
        }
    }

    func testFramesWithoutIntrinsicsAreRejected() throws {
        var info = try writeRecording()
        info.frames = info.frames.map { frame in
            var copy = frame
            copy.fx = 0
            copy.fy = 0
            return copy
        }
        XCTAssertThrowsError(try TopoMapBuilder.build(folder: folder, info: info)) {
            assertLineError($0, .notEnoughData)
        }
    }

    func testATinyDepthMapIsRejectedAsABadFile() throws {
        let info = try writeRecording(width: 8, height: 8, frameCount: 4)
        XCTAssertThrowsError(try TopoMapBuilder.build(folder: folder, info: info)) {
            assertLineError($0, .badFile)
        }
    }

    func testMissingDepthFileThrows() {
        let info = LineRecordingInfo(depthWidth: 64, depthHeight: 48, videoWidth: 1080, videoHeight: 1920,
                                     filteredDepth: true, shortShutter: true, direction: .rightToLeft,
                                     frames: [makeFrame(index: 0), makeFrame(index: 1, time: 0.1)])
        XCTAssertThrowsError(try TopoMapBuilder.build(folder: folder, info: info))
    }

    // MARK: - Text output

    private func makeStats(heightMode: Bool?, speed: Bool) -> TopoStats {
        TopoStats(cellSize: 10, columns: 120, rows: 60, lengthMM: 1200, widthMM: 600, coveragePercent: 85,
                  cellsWithData: 6120, meanHitsPerCell: 12.34,
                  mean: heightMode == true ? 2.5 : 1000, variance: 6.25, stdDev: 2.5, cvPercent: 0.25,
                  minimum: 0, maximum: 5, range: 5, p1: 0, p5: 0, median: 2.5, p95: 5, p99: 5,
                  acrossStdDev: 1.25, acrossRange: 5, alongStdDev: 0.1, alongRange: 0.5,
                  residualStdDev: 0.3, repeatStdDev: 0.05,
                  speedMean: speed ? 219 : nil, speedStdDev: speed ? 1.5 : nil,
                  speedMin: speed ? 210 : nil, speedMax: speed ? 230 : nil,
                  speedTrackedPercent: speed ? 100 : 0,
                  colorNear: heightMode == true ? 5 : 990, colorFar: heightMode == true ? 0 : 1000,
                  frames: 80, duration: 2.5, heightMode: heightMode)
    }

    func testSummaryLinesInHeightMode() {
        let lines = TopoMapBuilder.summaryLines(makeStats(heightMode: true, speed: true))
        XCTAssertEqual(lines, [
            "Scanned 1.20 m long × 0.60 m wide, 10 mm cells, 85% coverage",
            "Height above baseline mean 2.50 mm, std dev 2.50 mm, variance 6.25 mm²",
            "Range 5.0 mm (min 0.0, max 5.0); P5–P95 5.0 mm",
            "Across-width profile: std dev 1.25 mm, range 5.0 mm",
            "Along-travel profile: std dev 0.10 mm, range 0.5 mm",
            "Local residual std dev 0.30 mm; repeat-reading noise 0.05 mm; 12.3 readings per cell",
            "Speed mean 219 mm/s (13.14 m/min), std dev 1.5 mm/s, tracked 100% of frames",
            "Colours: dark blue 0.0 mm (low) → dark red 5.0 mm (high) above the baseline"
        ])
    }

    func testSummaryLinesInDistanceModeWithoutSpeed() {
        for mode in [false, nil] as [Bool?] {
            let lines = TopoMapBuilder.summaryLines(makeStats(heightMode: mode, speed: false))
            XCTAssertEqual(lines.count, 8)
            XCTAssertEqual(lines[1], "Distance mean 1000.0 mm, std dev 2.50 mm, variance 6.25 mm²")
            XCTAssertEqual(lines[6], "Speed: no texture lock (map uses zero travel)")
            XCTAssertEqual(lines[7], "Colours: dark red 990 mm (near) → dark blue 1000 mm (far); no baseline")
        }
    }

    func testStatsCSVNamesFollowTheMode() {
        let height = TopoMapBuilder.statsCSV(makeStats(heightMode: true, speed: true))
        let heightLines = height.split(separator: "\n").map(String.init)
        XCTAssertEqual(heightLines.count, 35)
        XCTAssertEqual(heightLines[0], "metric,value,unit")
        XCTAssertEqual(heightLines[1], "values,height_above_flat_baseline,")
        XCTAssertTrue(heightLines.contains("frames,80,"))
        XCTAssertTrue(heightLines.contains("duration,2.50,s"))
        XCTAssertTrue(heightLines.contains("height_mean,2.50,mm"))
        XCTAssertTrue(heightLines.contains("height_variance,6.250,mm^2"))
        XCTAssertTrue(heightLines.contains("height_std_dev,2.500,mm"))
        XCTAssertTrue(heightLines.contains("height_cv,,%"))      // no CV for heights above a baseline (B-7)
        XCTAssertTrue(heightLines.contains("speed_mean,219.0,mm/s"))
        XCTAssertTrue(heightLines.contains("speed_tracked,100.0,%"))
        XCTAssertTrue(heightLines.contains("colour_dark_red,5.0,mm"))
        XCTAssertTrue(heightLines.contains("colour_dark_blue,0.0,mm"))

        let distance = TopoMapBuilder.statsCSV(makeStats(heightMode: false, speed: false))
        let distanceLines = distance.split(separator: "\n").map(String.init)
        XCTAssertEqual(distanceLines[1], "values,distance_from_camera,")
        XCTAssertTrue(distanceLines.contains("distance_mean,1000.00,mm"))
        XCTAssertTrue(distanceLines.contains("distance_cv,0.250,%"))
        XCTAssertTrue(distanceLines.contains("speed_mean,,mm/s"))      // missing speeds stay blank
        XCTAssertTrue(distanceLines.contains("speed_min,,mm/s"))
        XCTAssertTrue(distanceLines.contains("speed_tracked,0.0,%"))
        XCTAssertFalse(distanceLines.contains { $0.hasPrefix("height_") })
    }

    func testProfileCSV() {
        let points = [ProfilePoint(position: -295, value: 1000.456, cells: 12),
                      ProfilePoint(position: 5, value: 999.5, cells: 80)]
        XCTAssertEqual(TopoMapBuilder.profileCSV(points, header: "across_mm", valueName: "mean_height_mm"),
                       "across_mm,mean_height_mm,cells\n-295.0,1000.46,12\n5.0,999.50,80\n")
        XCTAssertEqual(TopoMapBuilder.profileCSV([], header: "along_mm", valueName: "mean_distance_mm"),
                       "along_mm,mean_distance_mm,cells\n")
    }

    func testBorderSkipsAThirtySecondOfTheSmallerSideButAtLeastTwoPixels() {
        XCTAssertEqual(TopoMapBuilder.border(width: 64, height: 48), 2)
        XCTAssertEqual(TopoMapBuilder.border(width: 8, height: 8), 2)
        XCTAssertEqual(TopoMapBuilder.border(width: 100, height: 100), 3)
        XCTAssertEqual(TopoMapBuilder.border(width: 640, height: 480), 15)
        XCTAssertEqual(TopoMapBuilder.border(width: 480, height: 640), 15)
    }
}
