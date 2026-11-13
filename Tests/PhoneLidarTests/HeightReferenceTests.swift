import XCTest
import simd

/// Height references (design §16, FR-HREF): belt normal from the tilt, plane heights, wall calibration, the stored
/// reference and plane heights in LiDAR maps.
final class HeightReferenceTests: XCTestCase {
    // MARK: Plane maths

    func testLevelPhoneLooksAlongTheNormal() {
        let n = HeightPlane.normal(tiltX: 0, tiltY: 0)
        XCTAssertEqual(n.x, 0, accuracy: 1e-12)
        XCTAssertEqual(n.y, 0, accuracy: 1e-12)
        XCTAssertEqual(n.z, 1, accuracy: 1e-12)
    }

    func testTiltSignsFollowTheCameraAxes() {
        // Top edge high: "down" leans toward the bottom of the portrait screen = +camera x.
        let top = HeightPlane.normal(tiltX: 0, tiltY: 10)
        XCTAssertEqual(top.x, sin(10 * .pi / 180), accuracy: 1e-9)
        XCTAssertEqual(top.y, 0, accuracy: 1e-12)
        // Right edge high: "down" leans toward the left of the screen = +camera y.
        let right = HeightPlane.normal(tiltX: 5, tiltY: 0)
        XCTAssertEqual(right.y, sin(5 * .pi / 180), accuracy: 1e-9)
        XCTAssertEqual(simd_length(HeightPlane.normal(tiltX: 3, tiltY: -4)), 1, accuracy: 1e-12)
    }

    func testPointsOnTheBeltPlaneHaveZeroHeight() {
        let n = HeightPlane.normal(tiltX: 1.5, tiltY: -2)
        let plane = HeightPlane(normal: n, distance: 1500)
        let inPlane = simd_normalize(simd_cross(n, SIMD3<Double>(1, 0, 0)))
        let p = n * 1500 + inPlane * 300
        XCTAssertEqual(plane.height(of: p), 0, accuracy: 1e-9)
        XCTAssertEqual(plane.height(of: p - n * 42), 42, accuracy: 1e-9)
        // The depth form gives the same height for the same point.
        let q = p - n * 42
        XCTAssertEqual(plane.height(z: q.z, xn: q.x / q.z, yn: q.y / q.z), 42, accuracy: 1e-9)
    }

    // MARK: Stored reference

    func testBeltDistanceFollowsTheMethod() {
        var r = HeightReference()
        XCTAssertNil(r.beltDistance)
        r.method = .cameraHeight
        XCTAssertNil(r.beltDistance)
        r.cameraHeight = 1234
        XCTAssertEqual(r.beltDistance, 1234)
        XCTAssertTrue(r.isPlaneReady)
        r.method = .sideWalls
        XCTAssertNil(r.beltDistance)
        r.walls = makeWalls(top: 1190, bottom: 1194, wallHeight: 300)
        XCTAssertEqual(r.beltDistance ?? 0, 1492, accuracy: 1e-9)
        XCTAssertEqual(r.walls?.disagreement ?? 0, 4, accuracy: 1e-9)
        let kept = r.keptAcross
        XCTAssertEqual(kept?.lowerBound ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(kept?.upperBound ?? 0, 0.9, accuracy: 1e-9)
    }

    func testPlaneUsesTheMedianTiltRelativeToTheStoredZero() {
        var r = HeightReference(method: .cameraHeight, cameraHeight: 1000)
        r.levelZeroX = 1
        r.levelZeroY = -1
        var frames: [LineFrameInfo] = []
        for (i, t) in [(3.0, 1.0), (3.2, 1.1), (9.0, 9.0)].enumerated() {
            var f = makeFrame(index: i)
            f.tiltX = t.0
            f.tiltY = t.1
            frames.append(f)
        }
        let plane = r.plane(frames: frames)
        XCTAssertEqual(plane?.distance, 1000)
        let expected = HeightPlane.normal(tiltX: 2.2, tiltY: 2.1)
        XCTAssertEqual(plane?.normal.x ?? 0, expected.x, accuracy: 1e-9)
        XCTAssertEqual(plane?.normal.y ?? 0, expected.y, accuracy: 1e-9)
    }

    func testReferenceRoundTripsAndReadsUnknownMethodsAsEmptyBelt() throws {
        let folder = try makeTempFolder()
        var r = HeightReference(method: .sideWalls, cameraHeight: 900, wallHeight: 300)
        r.walls = makeWalls(top: 1190, bottom: 1191, wallHeight: 300)
        try r.save(to: folder)
        XCTAssertEqual(HeightReference.load(from: folder), r)
        let data = Data(#"{"method":"laserLine","cameraHeight":5}"#.utf8)
        let back = try JSONDecoder.iso.decode(HeightReference.self, from: data)
        XCTAssertEqual(back.method, .emptyBelt)
        XCTAssertEqual(back.cameraHeight, 5)
    }

    func testWallBandsAreClampedAndCoverColumns() {
        let band = WallBand(start: 0.95, end: 0.2).clamped
        XCTAssertEqual(band.start, 0.2, accuracy: 1e-12)
        XCTAssertEqual(band.end, 0.95, accuracy: 1e-12)
        let thin = WallBand(start: 1, end: 1).clamped
        XCTAssertEqual(thin.end - thin.start, WallBand.minimumWidth, accuracy: 1e-12)
        XCTAssertEqual(WallBand(start: 0.1, end: 0.2).columns(width: 320), 32..<64)
        XCTAssertEqual(WallBand(start: Double.nan, end: 0.001).columns(width: 100).count, 1)
    }

    // MARK: Wall measurement

    func testClosestClusterFindsTheWallTopAmongFartherReadings() throws {
        var rng = SystemRandomNumberGenerator()
        var values: [Float] = []
        for _ in 0..<600 { values.append(Float(1200 + Double.random(in: -4...4, using: &rng))) }
        for _ in 0..<300 { values.append(Float(Double.random(in: 1210...1490, using: &rng))) }      // mixed edges
        for _ in 0..<3000 { values.append(Float(1500 + Double.random(in: -15...15, using: &rng))) }   // belt
        values.append(0)
        values.append(.nan)
        let cluster = try XCTUnwrap(HeightMath.closestCluster(values))
        XCTAssertEqual(cluster.distance, 1200, accuracy: 1.0)
        XCTAssertGreaterThan(cluster.readings, 550)
        XCTAssertLessThan(cluster.spread, 6)
        XCTAssertNil(HeightMath.closestCluster([Float](repeating: 1000, count: 10)))
    }

    /// Depth maps of a camera tilted against a flat belt at `belt` mm along the normal, with wall tops `wall` mm
    /// above it in the given bands.
    private func renderWalls(width: Int, height: Int, n: SIMD3<Double>, belt: Double, wall: Double,
                             bands: [WallBand], fx: Double) -> [Float] {
        var depth = [Float](repeating: 0, count: width * height)
        let cx = Double(width) / 2, cy = Double(height) / 2
        for v in 0..<height {
            for u in 0..<width {
                let r = SIMD3<Double>((Double(u) - cx) / fx, (Double(v) - cy) / fx, 1)
                let inWall = bands.contains { $0.columns(width: width).contains(u) }
                let d = inWall ? belt - wall : belt
                depth[v * width + u] = Float(d / simd_dot(n, r))      // planar z (r.z = 1)
            }
        }
        return depth
    }

    func testWallCaptureRecoversTheBeltOfATiltedCamera() throws {
        let width = 64, height = 48, fx = 50.0
        let top = WallBand(start: 0.04, end: 0.14)
        let bottom = WallBand(start: 0.86, end: 0.96)
        // Phone tilted 2° / −1.5° from gravity, with a level zero of 0.5° / 0.5°.
        let n = HeightPlane.normal(tiltX: 1.5, tiltY: -2.0)
        let depth = renderWalls(width: width, height: height, n: n, belt: 2500, wall: 300, bands: [top, bottom],
                                fx: fx)
        // Bands passed in either order: the one nearer the top of the screen is the top wall.
        var capture = WallCapture(target: 10, topBand: bottom, bottomBand: top, wallHeight: 300,
                                  zeroX: 0.5, zeroY: 0.5, filtered: false)
        for _ in 0..<10 {
            capture.add(depth: depth, width: width, height: height, fx: fx, fy: fx, cx: 32, cy: 24,
                        tiltX: 2.0, tiltY: -1.5)
        }
        XCTAssertTrue(capture.isComplete)
        let walls = try capture.build()
        XCTAssertEqual(walls.topBand, top)
        XCTAssertEqual(walls.topDistance, 2200, accuracy: 0.5)
        XCTAssertEqual(walls.bottomDistance, 2200, accuracy: 0.5)
        XCTAssertEqual(walls.beltDistance, 2500, accuracy: 0.5)
        XCTAssertEqual(walls.tiltX, 1.5, accuracy: 1e-9)
        XCTAssertEqual(walls.tiltY, -2.0, accuracy: 1e-9)
    }

    func testWallCaptureRefusesBandsWithoutReadings() {
        var capture = WallCapture(target: 2, topBand: WallBand(start: 0, end: 0.1),
                                  bottomBand: WallBand(start: 0.9, end: 1), wallHeight: 300, zeroX: 0, zeroY: 0,
                                  filtered: true)
        let empty = [Float](repeating: 0, count: 64 * 48)
        capture.add(depth: empty, width: 64, height: 48, fx: 50, fy: 50, cx: 32, cy: 24, tiltX: 0, tiltY: 0)
        capture.add(depth: empty, width: 64, height: 48, fx: 50, fy: 50, cx: 32, cy: 24, tiltX: nil, tiltY: 0)
        XCTAssertEqual(capture.frames, 1)
        XCTAssertEqual(capture.seen, 2)
        XCTAssertThrowsError(try capture.build()) { error in
            XCTAssertEqual(error as? WallCalibrationError, .tooFewReadings("top"))
        }
    }

    // MARK: Plane heights in LiDAR maps

    /// Depth.bin of a level camera over material `h(x)` mm above a belt `belt` mm away (planar distances).
    private func writeFlatRecording(folder: URL, belt: Double, h: (Double) -> Double) throws -> LineRecordingInfo {
        let width = 64, height = 48, fx = 100.0
        let writer = try DepthFileWriter(url: folder.appendingPathComponent("Depth.bin"), width: width, height: height)
        var frames: [LineFrameInfo] = []
        for i in 0..<40 {
            frames.append(makeFrame(index: i, time: Double(i) / 30, speed: 200, travel: Double(i) * 7,
                                    medianDepth: belt, fx: Float(fx), fy: Float(fx), cx: 32, cy: 24))
            var depth = [Float](repeating: 0, count: width * height)
            for v in 0..<height {
                for u in 0..<width {
                    let x = (Double(u) - 32) / fx * belt
                    depth[v * width + u] = Float(belt - h(x))
                }
            }
            try writer.append(millimetres: depth)
        }
        writer.close()
        return LineRecordingInfo(depthWidth: width, depthHeight: height, videoWidth: 1920, videoHeight: 1440,
                                 filteredDepth: true, shortShutter: true, direction: .rightToLeft, frames: frames)
    }

    func testCameraHeightReferenceGivesHeightsAboveTheBelt() throws {
        let folder = try makeTempFolder()
        let info = try writeFlatRecording(folder: folder, belt: 1000, h: { $0 >= 0 ? 150 : 100 })
        try HeightReference(method: .cameraHeight, cameraHeight: 1000, levelZeroX: 0, levelZeroY: 0).save(to: folder)
        let output = try TopoMapBuilder.build(folder: folder, info: info)
        XCTAssertEqual(output.stats.heightMode, true)
        XCTAssertEqual(output.stats.heightReference, .cameraHeight)
        XCTAssertTrue(output.stats.heightAboveBelt)
        XCTAssertEqual(output.stats.minimum, 100, accuracy: 0.6)
        XCTAssertEqual(output.stats.maximum, 150, accuracy: 0.6)
        XCTAssertTrue(output.summary[1].hasPrefix("Height above the belt mean"), output.summary[1])
        XCTAssertTrue(output.summary.contains { $0.hasPrefix("Height reference: camera height 1000 mm") })
        let csv = try String(contentsOf: folder.appendingPathComponent("TopoStats.csv"), encoding: .utf8)
        XCTAssertTrue(csv.contains("values,height_above_belt_camera_height,"), csv)
    }

    func testSideWallReferenceKeepsOnlyTheColumnsBetweenTheWalls() throws {
        let folder = try makeTempFolder()
        let info = try writeFlatRecording(folder: folder, belt: 1000, h: { _ in 50 })
        var r = HeightReference(method: .sideWalls, wallHeight: 300, levelZeroX: 0, levelZeroY: 0)
        r.walls = makeWalls(top: 700, bottom: 700, wallHeight: 300, topBand: WallBand(start: 0, end: 0.25),
                            bottomBand: WallBand(start: 0.75, end: 1))
        try r.save(to: folder)
        let model = MapHeightModel.load(folder: folder, width: 64, height: 48, frames: info.frames)
        XCTAssertEqual(model.method, .sideWalls)
        XCTAssertEqual(model.columns(width: 64, border: 2), 16..<48)
        let output = try TopoMapBuilder.build(folder: folder, info: info)
        XCTAssertEqual(output.stats.heightReference, .sideWalls)
        XCTAssertEqual(output.stats.mean, 50, accuracy: 0.5)
        // 32 of 64 columns at 10 mm each: about 320 mm wide instead of 640 mm.
        XCTAssertLessThan(output.stats.widthMM, 360)
        XCTAssertGreaterThan(output.stats.widthMM, 280)
    }

    func testAnEmptyBeltReferenceFileLeavesTheBaselineInCharge() throws {
        let folder = try makeTempFolder()
        let info = try writeFlatRecording(folder: folder, belt: 1000, h: { _ in 20 })
        try HeightReference(method: .emptyBelt, cameraHeight: 5000).save(to: folder)
        let model = MapHeightModel.load(folder: folder, width: 64, height: 48, frames: info.frames)
        XCTAssertFalse(model.isHeight)
        XCTAssertEqual(try TopoMapBuilder.build(folder: folder, info: info).stats.mean, 980, accuracy: 0.01)
    }

    // MARK: Helpers

    private func makeWalls(top: Double, bottom: Double, wallHeight: Double,
                           topBand: WallBand = WallBand(start: 0, end: 0.1),
                           bottomBand: WallBand = WallBand(start: 0.9, end: 1)) -> WallCalibration {
        WallCalibration(date: Date(timeIntervalSince1970: 0), wallHeight: wallHeight, topDistance: top,
                        bottomDistance: bottom, topReadings: 500, bottomReadings: 500, topSpread: 2,
                        bottomSpread: 2, tiltX: 0, tiltY: 0, depthWidth: 64, depthHeight: 48, filteredDepth: true,
                        topBand: topBand, bottomBand: bottomBand)
    }
}
