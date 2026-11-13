import XCTest
import simd

/// Camera-parallax heights (design §15, FR-PAR): geometry, lens model, matching, scale smoothing and the processor
/// on synthetic video of moving textured material.
final class ParallaxGeometryTests: XCTestCase {
    func testDepthPerTravelOfAFrontoParallelMove() throws {
        let z = 1000.0, s = 120.0
        let r1 = SIMD3<Double>(0.05, -0.1, 1)
        let p2 = r1 * z + SIMD3<Double>(0, s, 0)
        let g = try XCTUnwrap(ParallaxGeometry.depthPerTravel(r1, p2 / p2.z, travel: SIMD3<Double>(0, 1, 0)))
        XCTAssertEqual(g * s, z, accuracy: 1e-6)
    }

    func testDepthPerTravelWithATiltedTravelDirection() throws {
        let n = HeightPlane.normal(tiltX: 2, tiltY: -3)
        let u = ParallaxGeometry.travelDirection(normal: n, acrossPerAlong: 0.03, sign: -1)
        XCTAssertEqual(simd_dot(u, n), 0, accuracy: 1e-12)
        XCTAssertEqual(simd_length(u), 1, accuracy: 1e-12)
        XCTAssertLessThan(u.y, 0)
        let p1 = SIMD3<Double>(-150, 90, 1234)
        let s = 333.0
        let p2 = p1 + u * s
        let g = try XCTUnwrap(ParallaxGeometry.depthPerTravel(p1 / p1.z, p2 / p2.z, travel: u))
        XCTAssertEqual(g * s, p1.z, accuracy: 1e-6)
    }

    func testParallelRaysHaveNoDepth() {
        let r = SIMD3<Double>(0.1, 0.2, 1)
        XCTAssertNil(ParallaxGeometry.depthPerTravel(r, r, travel: SIMD3<Double>(0, 1, 0)))
        // Moving away from the camera's side of the picture gives a negative depth: rejected.
        XCTAssertNil(ParallaxGeometry.depthPerTravel(SIMD3<Double>(0, 0.1, 1), SIMD3<Double>(0, 0, 1),
                                                     travel: SIMD3<Double>(0, 1, 0)))
    }

    func testBeltNormalPrefersTheZeroedTiltThenTheSurfaceTilt() {
        var frames = (0..<3).map { makeFrame(index: $0) }
        XCTAssertEqual(ParallaxGeometry.beltNormal(frames: frames, reference: nil), SIMD3<Double>(0, 0, 1))
        for i in frames.indices {
            frames[i].tiltX = 4
            frames[i].tiltY = 0
            frames[i].surfaceTiltX = 1
            frames[i].surfaceTiltY = 0
        }
        XCTAssertEqual(ParallaxGeometry.beltNormal(frames: frames, reference: nil).y, sin(1 * .pi / 180),
                       accuracy: 1e-9)
        let zeroed = HeightReference(method: .cameraHeight, cameraHeight: 1000, levelZeroX: 1.5, levelZeroY: 0)
        XCTAssertEqual(ParallaxGeometry.beltNormal(frames: frames, reference: zeroed).y, sin(2.5 * .pi / 180),
                       accuracy: 1e-9)
    }

    func testAcrossPerAlongIsTheMedianOfConfidentShifts() {
        var frames: [LineFrameInfo] = []
        for (along, across, quality) in [(20.0, 1.0, 1.0), (22.0, 1.1, 1.0), (1.0, 5.0, 1.0), (20.0, 9.0, 0.05)] {
            var f = makeFrame()
            f.shiftPixels = along
            f.crossShiftPixels = across
            f.quality = quality
            frames.append(f)
        }
        XCTAssertEqual(ParallaxGeometry.acrossPerAlong(frames: frames), 0.05, accuracy: 1e-9)
        XCTAssertEqual(ParallaxGeometry.acrossPerAlong(frames: []), 0)
    }

    func testCellSizeIsThePatchSpacingRoundedUpToATenth() {
        XCTAssertEqual(ParallaxGeometry.cellSize(spacingPixels: 8, distance: 1000, focal: 1512), 5.3, accuracy: 1e-9)
        XCTAssertEqual(ParallaxGeometry.cellSize(spacingPixels: 8, distance: 1000, focal: 800), 10, accuracy: 1e-9)
        XCTAssertEqual(ParallaxGeometry.cellSize(spacingPixels: 8, distance: 0, focal: 800), 2)
    }

    func testLensTablesAreAppliedAboutTheCentreInReferencePixels() {
        // Magnification 0 at the centre, 0.02 at the corner; reference twice the image size.
        let lens = LensCalibration(referenceWidth: 400, referenceHeight: 300, centerX: 200, centerY: 150,
                                   forward: [0, 0.01, 0.02], inverse: [0, -0.01, -0.02])
        XCTAssertTrue(lens.isValid)
        let centre = lens.distort(x: 100, y: 75, width: 200, height: 150)
        XCTAssertEqual(centre.x, 100, accuracy: 1e-9)
        XCTAssertEqual(centre.y, 75, accuracy: 1e-9)
        // Corner (r = r_max): +2 %; half way: +1 %.
        let corner = lens.distort(x: 200, y: 150, width: 200, height: 150)
        XCTAssertEqual(corner.x, 100 + 100 * 1.02, accuracy: 1e-9)
        XCTAssertEqual(corner.y, 75 + 75 * 1.02, accuracy: 1e-9)
        let half = lens.distort(x: 150, y: 112.5, width: 200, height: 150)
        XCTAssertEqual(half.x, 100 + 50 * 1.01, accuracy: 1e-9)
        let back = lens.undistort(x: half.x, y: half.y, width: 200, height: 150)
        XCTAssertEqual(back.x, 150, accuracy: 0.05)
        XCTAssertFalse(LensCalibration(referenceWidth: 0, referenceHeight: 1, centerX: 0, centerY: 0,
                                       forward: [0, 0], inverse: [0, 0]).isValid)
        XCTAssertFalse(LensCalibration(referenceWidth: 4, referenceHeight: 3, centerX: 2, centerY: 1,
                                       forward: [0], inverse: [0, .nan]).isValid)
    }

    func testCameraRaysAndProjectionAreInverse() throws {
        let lens = LensCalibration(referenceWidth: 640, referenceHeight: 480, centerX: 322, centerY: 238,
                                   forward: [0, 0.004, 0.012, 0.024], inverse: [0, -0.004, -0.0119, -0.0234])
        let camera = ParallaxCamera(width: 320, height: 240, fx: 300, fy: 300, cx: 160, cy: 120, lens: lens)
        let p = SIMD3<Double>(-210, 140, 900)
        let image = try XCTUnwrap(camera.project(p))
        let r = camera.ray(x: image.x, y: image.y)
        XCTAssertEqual(r.x, p.x / p.z, accuracy: 2e-4)
        XCTAssertEqual(r.y, p.y / p.z, accuracy: 2e-4)
        XCTAssertNil(camera.project(SIMD3<Double>(0, 0, -1)))
    }

    func testParabolicPeak() {
        XCTAssertEqual(parabolicPeak(0.5, 1, 0.5) ?? 9, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(parabolicPeak(0.6, 1, 0.9) ?? -1, 0)
        XCTAssertNil(parabolicPeak(1, 0.5, 1))
    }

    func testScaleSmootherTakesTheWindowMedian() {
        var s = ScaleSmoother(halfWindow: 1)
        s.append(1.0)
        s.append(nil)
        s.append(3.0)
        s.append(.nan)
        s.append(2.0)
        XCTAssertEqual(s.smoothed(at: 0), 1.0)
        XCTAssertEqual(s.smoothed(at: 1), 2.0)          // median of 1 and 3
        XCTAssertEqual(s.smoothed(at: 3), 2.5)          // 3 and 2; the NaN was dropped
        XCTAssertEqual(s.smoothed(at: 4), 2.0)
        XCTAssertEqual(s.overall, 2.0)
        XCTAssertTrue(s.isSettled(3))
        XCTAssertFalse(s.isSettled(4))
    }
}

/// Synthetic texture and frames for the matcher and the processor.
enum SyntheticTexture {
    /// Smooth random texture (two octaves of value noise), 0…255, at material position (x, y) mm.
    static func value(_ x: Double, _ y: Double) -> Double {
        0.6 * noise(x / 12.0, y / 12.0, seed: 17) + 0.4 * noise(x / 30.0, y / 30.0, seed: 91)
    }

    private static func lattice(_ i: Int, _ j: Int, seed: UInt64) -> Double {
        let ki: UInt64 = 0x9E37_79B9_7F4A_7C15
        let kj: UInt64 = 0xC2B2_AE3D_27D4_EB4F
        let ks: UInt64 = 0x1656_67B1_9E37_79F9
        let km: UInt64 = 0xBF58_476D_1CE4_E5B9
        var h: UInt64 = UInt64(bitPattern: Int64(i)) &* ki
        h ^= UInt64(bitPattern: Int64(j)) &* kj
        h ^= seed &* ks
        h ^= h >> 29
        h = h &* km
        h ^= h >> 32
        let bucket = Double(h % 10_000)
        return bucket / 10_000 * 255
    }

    private static func noise(_ x: Double, _ y: Double, seed: UInt64) -> Double {
        let i = Int(floor(x))
        let j = Int(floor(y))
        let fx = x - floor(x)
        let fy = y - floor(y)
        let sx: Double = fx * fx * (3 - 2 * fx)
        let sy: Double = fy * fy * (3 - 2 * fy)
        let a = lattice(i, j, seed: seed)
        let b = lattice(i + 1, j, seed: seed)
        let c = lattice(i, j + 1, seed: seed)
        let d = lattice(i + 1, j + 1, seed: seed)
        let top: Double = a + (b - a) * sx
        let bottom: Double = c + (d - c) * sx
        return top * (1 - sy) + bottom * sy
    }

    /// Picture of material moved `travel` mm along +sign·y past a level camera (no lens distortion): a belt plane at
    /// `belt` mm and a ridge running along the travel with its top at `ridgeTop` mm for x in `ridge` (mm).
    static func frame(camera: ParallaxCamera, travel: Double, sign: Int, belt: Double, ridgeTop: Double,
                      ridge: ClosedRange<Double>) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: camera.width * camera.height)
        for y in 0..<camera.height {
            let yn = (Double(y) - camera.cy) / camera.fy
            for x in 0..<camera.width {
                let xn = (Double(x) - camera.cx) / camera.fx
                var z = belt
                if ridge.contains(xn * ridgeTop) { z = ridgeTop }
                let along = yn * z - Double(sign) * travel
                let v = value(xn * z, along)
                out[y * camera.width + x] = UInt8(max(0, min(255, v.rounded())))
            }
        }
        return out
    }
}

final class PatchMatcherTests: XCTestCase {
    func testFindsASubPixelShift() throws {
        let camera = ParallaxCamera(width: 160, height: 120, fx: 300, fy: 300, cx: 80, cy: 60, lens: nil)
        // Same material moved 23.4 mm (7.02 px at 1000 mm).
        let a = SyntheticTexture.frame(camera: camera, travel: 0, sign: 1, belt: 1000, ridgeTop: 1000, ridge: 0...0)
        let b = SyntheticTexture.frame(camera: camera, travel: 23.4, sign: 1, belt: 1000, ridgeTop: 1000, ridge: 0...0)
        let full = LumaPlane(pixels: a, width: 160, height: 120)
        let half = full.halved()
        let searchFull = LumaPlane(pixels: b, width: 160, height: 120)
        let searchHalf = searchFull.halved()
        var matcher = PatchMatcher()
        matcher.patch = 16
        let m = try searchFull.pixels.withUnsafeBufferPointer { fb in
            try searchHalf.pixels.withUnsafeBufferPointer { hb in
                try XCTUnwrap(matcher.match(templateFull: full, templateHalf: half, tx: 80, ty: 50,
                                            searchFull: fb, fullWidth: 160, fullHeight: 120, fullOriginY: 0,
                                            searchHalf: hb, halfWidth: 80, halfHeight: 60, halfOriginY: 0,
                                            px: 80, py: 55, alongRadius: 6, acrossRadius: 2))
            }
        }
        XCTAssertEqual(m.x, 80, accuracy: 0.15)
        XCTAssertEqual(m.y, 50 + 7.02, accuracy: 0.15)
        XCTAssertGreaterThan(m.score, 0.95)
    }

    func testFlatPatchesAreNotMatched() {
        let flat = LumaPlane(pixels: [UInt8](repeating: 128, count: 64 * 64), width: 64, height: 64)
        XCTAssertNil(MatchTemplate(plane: flat, cx: 32, cy: 32, size: 16, minimumSD: 3))
        // Outside the plane.
        XCTAssertNil(MatchTemplate(plane: flat, cx: 4, cy: 32, size: 16, minimumSD: 0))
    }

    func testStripCopyAndHalvingKeepBufferRows() {
        let pixels = (0..<(8 * 10)).map { UInt8($0 % 256) }
        let strip = pixels.withUnsafeBufferPointer {
            LumaPlane(copying: $0, width: 8, height: 10, bytesPerRow: 8, rows: 4..<8)
        }
        XCTAssertEqual(strip.originY, 4)
        XCTAssertEqual(strip.height, 4)
        XCTAssertEqual(strip.pixels.first, 32)
        let half = strip.halved()
        XCTAssertEqual(half.originY, 2)
        XCTAssertEqual(half.width, 4)
        XCTAssertEqual(half.height, 2)
        let sum: Int = 32 + 33 + 40 + 41
        XCTAssertEqual(Int(half.pixels[0]), (sum + 2) / 4)
    }
}

final class ParallaxProcessorTests: XCTestCase {
    /// Runs the processor over synthetic frames and returns the readings' distances inside and outside the ridge.
    private func run(sign: Int, travelStep: Double) throws -> (flat: [Double], ridge: [Double],
                                                              counters: ParallaxProcessor.Counters) {
        let camera = ParallaxCamera(width: 240, height: 180, fx: 240, fy: 240, cx: 120, cy: 90, lens: nil)
        let ridge = -200.0 ... -30.0          // mm across, ridge top 50 mm above the belt
        let depthWidth = 24, depthHeight = 18
        let lidar = [Float](repeating: 1000, count: depthWidth * depthHeight)      // smooth LiDAR: the belt only
        var settings = ParallaxSettings()
        settings.halfWindow = 3
        let processor = ParallaxProcessor(settings: settings, width: 240, height: 180, sign: sign,
                                          normal: SIMD3<Double>(0, 0, 1), acrossPerAlong: 0,
                                          depthWidth: depthWidth, depthHeight: depthHeight,
                                          depthFrame: { _ in lidar })
        var readings: [ParallaxReading] = []
        for i in 0..<48 {
            let travel = Double(i) * travelStep
            let image = SyntheticTexture.frame(camera: camera, travel: travel, sign: sign, belt: 1000,
                                               ridgeTop: 950, ridge: ridge)
            let input = ParallaxProcessor.FrameInput(index: i, travel: travel, medianDepth: 1000, camera: camera)
            readings += image.withUnsafeBufferPointer { processor.add(input, luma: $0, bytesPerRow: 240) }
        }
        readings += processor.finish()
        var flat: [Double] = []
        var onRidge: [Double] = []
        for r in readings {
            let x = r.point.x
            // Patches (16 px ≈ 65 mm) clear of the ridge edges.
            if x > ridge.lowerBound + 30 && x < ridge.upperBound - 30 {
                onRidge.append(r.point.z)
            } else if x > ridge.upperBound + 40 || x < ridge.lowerBound - 40 {
                flat.append(r.point.z)
            }
        }
        return (flat, onRidge, processor.counters)
    }

    func testRecoversTheRidgeHeightFromParallaxAlone() throws {
        let result = try run(sign: 1, travelStep: 12)
        XCTAssertGreaterThan(result.counters.pairsWithScale, 3)
        XCTAssertGreaterThan(result.flat.count, 50)
        XCTAssertGreaterThan(result.ridge.count, 10)
        let flat = try XCTUnwrap(HeightMath.median(result.flat))
        let ridge = try XCTUnwrap(HeightMath.median(result.ridge))
        XCTAssertEqual(flat, 1000, accuracy: 1.5)
        // The LiDAR saw only the belt; the 50 mm ridge comes from the parallax.
        XCTAssertEqual(ridge, 950, accuracy: 3.0)
    }

    func testWorksForTheOtherTravelDirection() throws {
        let result = try run(sign: -1, travelStep: 9)
        let flat = try XCTUnwrap(HeightMath.median(result.flat))
        let ridge = try XCTUnwrap(HeightMath.median(result.ridge))
        XCTAssertEqual(flat, 1000, accuracy: 1.5)
        XCTAssertEqual(ridge, 950, accuracy: 3.0)
    }

    func testAStoppedBeltStoresNoTemplatesAfterTheFirst() {
        let camera = ParallaxCamera(width: 240, height: 180, fx: 240, fy: 240, cx: 120, cy: 90, lens: nil)
        let lidar = [Float](repeating: 1000, count: 24 * 18)
        let processor = ParallaxProcessor(width: 240, height: 180, sign: 1, normal: SIMD3<Double>(0, 0, 1),
                                          acrossPerAlong: 0, depthWidth: 24, depthHeight: 18,
                                          depthFrame: { _ in lidar })
        let image = SyntheticTexture.frame(camera: camera, travel: 0, sign: 1, belt: 1000, ridgeTop: 1000, ridge: 0...0)
        for i in 0..<20 {
            let input = ParallaxProcessor.FrameInput(index: i, travel: 0, medianDepth: 1000, camera: camera)
            XCTAssertTrue(image.withUnsafeBufferPointer { processor.add(input, luma: $0, bytesPerRow: 240) }.isEmpty)
        }
        XCTAssertEqual(processor.counters.templatesStored, 1)
        XCTAssertEqual(processor.counters.pairs, 0)
        XCTAssertTrue(processor.finish().isEmpty)
    }
}
