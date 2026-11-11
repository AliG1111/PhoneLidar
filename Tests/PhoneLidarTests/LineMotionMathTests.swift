import XCTest

/// Speed, zone, travel, smoothing and tilt maths of the line-scan capture (Z-7), with known inputs.
final class LineMotionMathTests: XCTestCase {
    // MARK: - Gates and scale

    func testSpeedIntervalGate() {
        XCTAssertFalse(LineMotionMath.isSpeedInterval(0))
        XCTAssertFalse(LineMotionMath.isSpeedInterval(-1.0 / 30))
        XCTAssertFalse(LineMotionMath.isSpeedInterval(0.001))       // repeated timestamp
        XCTAssertTrue(LineMotionMath.isSpeedInterval(0.0011))
        XCTAssertTrue(LineMotionMath.isSpeedInterval(1.0 / 30))
        XCTAssertTrue(LineMotionMath.isSpeedInterval(0.999))
        XCTAssertFalse(LineMotionMath.isSpeedInterval(1))           // a gap of a second or more
        XCTAssertFalse(LineMotionMath.isSpeedInterval(.nan))
    }

    func testTravelIntervalGate() {
        XCTAssertFalse(LineMotionMath.isTravelInterval(0))
        XCTAssertFalse(LineMotionMath.isTravelInterval(-0.01))
        XCTAssertTrue(LineMotionMath.isTravelInterval(0.0005))      // shorter than the speed gate still counts
        XCTAssertTrue(LineMotionMath.isTravelInterval(0.999))
        XCTAssertFalse(LineMotionMath.isTravelInterval(1))
        XCTAssertFalse(LineMotionMath.isTravelInterval(.nan))
    }

    func testVideoFocalLengthScalesByTheImageHeights() {
        // 200 depth px × 1440 / 192 = 1500 video px.
        XCTAssertEqual(LineMotionMath.videoFocalLength(depthFy: 200, videoHeight: 1440, depthHeight: 192), 1500,
                       accuracy: 1e-12)
        // No depth height: the divisor is 1, never 0.
        XCTAssertEqual(LineMotionMath.videoFocalLength(depthFy: 200, videoHeight: 1440, depthHeight: 0), 288_000)
    }

    func testSpeedIsPixelsTimesMillimetresPerPixelOverTime() throws {
        // 10 px × (1000 mm / 1500 px) / (1/30 s) = 200 mm/s.
        let v = try XCTUnwrap(LineMotionMath.speed(shiftPixels: 10, distance: 1000, focalPixels: 1500, dt: 1.0 / 30))
        XCTAssertEqual(v, 200, accuracy: 1e-9)
        XCTAssertNil(LineMotionMath.speed(shiftPixels: 10, distance: 1000, focalPixels: 0, dt: 0.1))
        XCTAssertNil(LineMotionMath.speed(shiftPixels: .nan, distance: 1000, focalPixels: 1500, dt: 0.1))
    }

    // MARK: - Main speed

    private func tracked(shift: Double = 10, quality: Double = 0.5, trackedDistance: Double = 1000,
                         center: Double = 750, focal: Double = 1500, dt: Double = 1.0 / 30) -> Double? {
        LineMotionMath.trackedSpeed(shiftPixels: shift, quality: quality, trackedDistance: trackedDistance,
                                    centerDistance: center, focalPixels: focal, dt: dt)
    }

    func testTrackedSpeedUsesTheTrackedAreaDistance() throws {
        XCTAssertEqual(try XCTUnwrap(tracked()), 200, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(tracked(shift: -10)), -200, accuracy: 1e-9)     // sign is kept
    }

    func testTrackedSpeedFallsBackToTheCentreDistance() throws {
        // 10 px × (750 / 1500) × 30 = 150 mm/s.
        XCTAssertEqual(try XCTUnwrap(tracked(trackedDistance: 0)), 150, accuracy: 1e-9)
        XCTAssertNil(tracked(trackedDistance: 0, center: 0))
    }

    func testTrackedSpeedQualityGate() {
        XCTAssertNotNil(tracked(quality: 0.1))
        XCTAssertNil(tracked(quality: 0.0999))
        XCTAssertNil(tracked(quality: 0))
    }

    func testTrackedSpeedIntervalAndFocalGates() {
        XCTAssertNil(tracked(dt: 0.001))
        XCTAssertNil(tracked(dt: 0))
        XCTAssertNil(tracked(dt: 1))
        XCTAssertNotNil(tracked(dt: 0.002))
        XCTAssertNil(tracked(focal: 0))
        XCTAssertNil(tracked(focal: -1))
    }

    // MARK: - Zones

    private let mapWidth = 48
    private let mapHeight = 32

    /// 48 × 32 depth map; zone n (6 × 4 grid of 8 × 8 px) reads 1000 + 10·n mm, or 0 in `empty` zones.
    private func zoneMap(empty: Set<Int> = []) -> [Float] {
        var map = [Float](repeating: 0, count: mapWidth * mapHeight)
        for y in 0..<mapHeight {
            for x in 0..<mapWidth {
                let zone = (y / 8) * 6 + x / 8
                map[y * mapWidth + x] = empty.contains(zone) ? 0 : Float(1000 + 10 * zone)
            }
        }
        return map
    }

    private func zoneSpeeds(_ tiles: [(along: Double, quality: Double)?], map: [Float], dt: Double = 0.05,
                            focal: Double = 1500) -> [Double?] {
        LineMotionMath.zoneSpeeds(tiles: tiles, millimetres: map, width: mapWidth, height: mapHeight,
                                  centerDistance: 900, focalPixels: focal, dt: dt, columns: 6, rows: 4)
    }

    func testZoneSpeedsUseEachZonesOwnDistance() throws {
        let tiles = [(along: Double, quality: Double)?](repeating: (along: 3, quality: 0.5), count: 24)
        let speeds = zoneSpeeds(tiles, map: zoneMap())
        XCTAssertEqual(speeds.count, 24)
        for n in 0..<24 {
            // 3 px × (d / 1500) / 0.05 s = 0.04 · d.
            let expected = 0.04 * Double(1000 + 10 * n)
            XCTAssertEqual(try XCTUnwrap(speeds[n]), expected, accuracy: 1e-9, "zone \(n)")
        }
    }

    func testZoneSpeedQualityGateAndMissingTiles() {
        var tiles = [(along: Double, quality: Double)?](repeating: (along: 3, quality: 0.5), count: 24)
        tiles[1] = (along: 3, quality: 0.1199)
        tiles[2] = nil
        tiles[3] = (along: 3, quality: 0.12)
        let speeds = zoneSpeeds(tiles, map: zoneMap())
        XCTAssertNil(speeds[1])
        XCTAssertNil(speeds[2])
        XCTAssertNotNil(speeds[3])
    }

    func testAZoneWithoutReadingsUsesTheCentreDistance() throws {
        let tiles = [(along: Double, quality: Double)?](repeating: (along: 3, quality: 0.5), count: 24)
        let speeds = zoneSpeeds(tiles, map: zoneMap(empty: [7]))
        XCTAssertEqual(try XCTUnwrap(speeds[7]), 0.04 * 900, accuracy: 1e-9)
    }

    func testZoneSpeedsAreAllMissingWhenAGateFails() {
        let tiles = [(along: Double, quality: Double)?](repeating: (along: 3, quality: 0.5), count: 24)
        for speeds in [zoneSpeeds(tiles, map: zoneMap(), dt: 0.001),
                       zoneSpeeds(tiles, map: zoneMap(), dt: 1),
                       zoneSpeeds(tiles, map: zoneMap(), focal: 0),
                       zoneSpeeds(Array(tiles.prefix(23)), map: zoneMap()),
                       zoneSpeeds([], map: zoneMap())] {
            XCTAssertEqual(speeds.count, 24)
            XCTAssertTrue(speeds.allSatisfy { $0 == nil })
        }
    }

    func testFastestPicksTheLargestMagnitudeAndKeepsItsSign() throws {
        let best = try XCTUnwrap(LineMotionMath.fastest([nil, 3, -5, 5, 4]))
        XCTAssertEqual(best.speed, -5)
        XCTAssertEqual(best.index, 2)       // the first of equal magnitudes wins
        XCTAssertNil(LineMotionMath.fastest([]))
        XCTAssertNil(LineMotionMath.fastest([nil, nil]))
    }

    // MARK: - Smoothing and travel

    func testZoneSmootherNeedsFourReadingsInTheWindow() throws {
        var smoother = ZoneSpeedSmoother()
        for _ in 0..<3 {
            XCTAssertNil(smoother.add([10, nil])[0])
        }
        let fourth = smoother.add([30, nil])
        XCTAssertEqual(try XCTUnwrap(fourth[0]), 15, accuracy: 1e-12)       // (10 + 10 + 10 + 30) / 4
        XCTAssertNil(fourth[1])
    }

    func testZoneSmootherAveragesTheLastFifteenFrames() throws {
        var smoother = ZoneSpeedSmoother()
        var last: [Double?] = []
        for v in 1...20 {
            last = smoother.add([Double(v)])
        }
        XCTAssertEqual(try XCTUnwrap(last[0]), 13, accuracy: 1e-12)          // mean of 6…20
        smoother.reset()
        XCTAssertNil(smoother.add([5])[0])
    }

    func testZoneSmootherOutputMatchesTheNewFrameSize() {
        var smoother = ZoneSpeedSmoother()
        for _ in 0..<5 { _ = smoother.add([1, 2, 3]) }
        let out = smoother.add([1, 2])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[1], 2)
    }

    func testTravelIntegratesTheReadingAndHoldsTheLastValidSpeed() {
        var tracker = LineSpeedTracker()
        _ = tracker.add(rawSpeed: 100, dt: 0.1)
        XCTAssertEqual(tracker.travel, 10, accuracy: 1e-12)
        _ = tracker.add(rawSpeed: nil, dt: 0.1)           // no lock: the held 100 mm/s keeps the travel going
        XCTAssertEqual(tracker.travel, 20, accuracy: 1e-12)
        XCTAssertEqual(tracker.lastValidSpeed, 100)
        _ = tracker.add(rawSpeed: -50, dt: 0.2)
        XCTAssertEqual(tracker.travel, 10, accuracy: 1e-12)
    }

    func testTravelSkipsIntervalsOutsideTheGate() {
        var tracker = LineSpeedTracker()
        _ = tracker.add(rawSpeed: 100, dt: 0)
        _ = tracker.add(rawSpeed: 100, dt: 1)
        _ = tracker.add(rawSpeed: 100, dt: -0.1)
        XCTAssertEqual(tracker.travel, 0)
        XCTAssertEqual(tracker.lastValidSpeed, 100)       // the reading is still held
    }

    func testTravelWithoutAnyReadingStaysZero() {
        var tracker = LineSpeedTracker()
        for _ in 0..<30 { XCTAssertNil(tracker.add(rawSpeed: nil, dt: 1.0 / 30)) }
        XCTAssertEqual(tracker.travel, 0)
        XCTAssertNil(tracker.lastValidSpeed)
    }

    func testClearHeldSpeedKeepsTheTravel() {
        var tracker = LineSpeedTracker()
        _ = tracker.add(rawSpeed: 100, dt: 0.1)
        tracker.clearHeldSpeed()
        XCTAssertNil(tracker.lastValidSpeed)
        _ = tracker.add(rawSpeed: nil, dt: 0.1)
        XCTAssertEqual(tracker.travel, 10, accuracy: 1e-12)
    }

    func testARecordingKeepsAFreshHeldSpeed() throws {
        // Y-1: lock on the material, lost 0.5 s before Record: the held speed and the recent average carry over.
        var tracker = LineSpeedTracker()
        for _ in 0..<5 { _ = tracker.add(rawSpeed: 300, dt: 0.1) }
        for _ in 0..<4 { _ = tracker.add(rawSpeed: nil, dt: 0.125) }      // the last one is the first recorded frame
        let start = tracker.travel
        tracker.beginRecording()
        XCTAssertEqual(tracker.travel, start)                             // recorded travel starts at 0 here
        XCTAssertEqual(tracker.lastValidSpeed, 300)
        XCTAssertEqual(try XCTUnwrap(tracker.add(rawSpeed: nil, dt: 0.125)), 300, accuracy: 1e-12)   // window kept
        XCTAssertEqual(tracker.travel - start, 37.5, accuracy: 1e-12)     // held 300 mm/s × 0.125 s
    }

    func testARecordingClearsAStaleHeldSpeed() throws {
        // Y-1 (Z-1 kept for old readings): lock lost 3 s before Record and never regained: travel stays put.
        var tracker = LineSpeedTracker()
        for _ in 0..<5 { _ = tracker.add(rawSpeed: 300, dt: 0.25) }       // last reading at 1.25 s
        var shown: Double?
        for _ in 0..<12 { shown = tracker.add(rawSpeed: nil, dt: 0.25) }  // Record at 4.25 s
        XCTAssertEqual(try XCTUnwrap(shown), 300, accuracy: 1e-12)        // three old readings still in the window
        tracker.beginRecording()
        XCTAssertNil(tracker.lastValidSpeed)
        let start = tracker.travel
        for _ in 0..<30 { XCTAssertNil(tracker.add(rawSpeed: nil, dt: 0.1)) }      // the old average is gone too
        XCTAssertEqual(tracker.travel, start)
    }

    func testARecordingKeepsReadingsExactlyTwoSecondsOld() throws {
        // Y-1 boundary: the reading at 0.25 s is exactly 2.0 s old at 2.25 s (binary-exact intervals).
        var tracker = LineSpeedTracker()
        _ = tracker.add(rawSpeed: 300, dt: 0.25)
        for _ in 0..<4 { _ = tracker.add(rawSpeed: nil, dt: 0.5) }
        XCTAssertEqual(LineSpeedTracker.recordingCarryOverAge, 2.0)

        var atLimit = tracker
        atLimit.beginRecording()
        XCTAssertEqual(atLimit.lastValidSpeed, 300)
        let start = atLimit.travel
        _ = atLimit.add(rawSpeed: nil, dt: 0.5)
        XCTAssertEqual(atLimit.travel - start, 150, accuracy: 1e-12)      // held 300 mm/s × 0.5 s
        // The 300 reading is still in the window: with two new readings the average needs three.
        XCTAssertEqual(atLimit.add(rawSpeed: 600, dt: 0.0625), 600)
        XCTAssertEqual(try XCTUnwrap(atLimit.add(rawSpeed: 600, dt: 0.0625)), 500, accuracy: 1e-12)

        var pastLimit = tracker
        _ = pastLimit.add(rawSpeed: nil, dt: 0.0625)                     // now 2.0625 s old
        pastLimit.beginRecording()
        XCTAssertNil(pastLimit.lastValidSpeed)
        let pastStart = pastLimit.travel
        _ = pastLimit.add(rawSpeed: nil, dt: 0.5)
        XCTAssertEqual(pastLimit.travel, pastStart)
        XCTAssertEqual(pastLimit.add(rawSpeed: 600, dt: 0.0625), 600)
        XCTAssertEqual(pastLimit.add(rawSpeed: 600, dt: 0.0625), 600)      // two readings only: raw shown
    }

    func testARecordingThatStartsWithLockIsUnchanged() {
        // Y-1: with a fresh reading throughout (no-lock frames are all within 2 s of one), Record changes neither the
        // travel nor the shown average.
        let readings: [Double?] = [100, 120, nil, 140, 160, 150, nil, nil, 170, 180, 190, nil, 200]
        var plain = LineSpeedTracker()
        var recorded = LineSpeedTracker()
        for (n, v) in readings.enumerated() {
            let a = plain.add(rawSpeed: v, dt: 1.0 / 30)
            let b = recorded.add(rawSpeed: v, dt: 1.0 / 30)
            if n == 4 { recorded.beginRecording() }
            XCTAssertEqual(a, b, "frame \(n)")
            XCTAssertEqual(plain.travel, recorded.travel, "frame \(n)")
            XCTAssertEqual(plain.lastValidSpeed, recorded.lastValidSpeed, "frame \(n)")
        }
    }

    func testARecordingStartingWithLockAfterAStalePeriodHoldsTheNewReading() {
        var tracker = LineSpeedTracker()
        _ = tracker.add(rawSpeed: 300, dt: 0.1)
        for _ in 0..<30 { _ = tracker.add(rawSpeed: nil, dt: 0.1) }       // 3 s without lock
        _ = tracker.add(rawSpeed: 50, dt: 0.1)                           // the first recorded frame measured 50 mm/s
        tracker.beginRecording()
        let start = tracker.travel
        XCTAssertNil(tracker.add(rawSpeed: nil, dt: 0.1))                 // one reading in the window: no average yet
        XCTAssertEqual(tracker.travel - start, 5, accuracy: 1e-12)        // held 50 mm/s × 0.1 s
        XCTAssertEqual(tracker.lastValidSpeed, 50)
    }

    func testALongGapCountsTowardTheAgeOfTheHeldSpeed() {
        // X-3: a gap of a second or more still advances the tracker clock (the clock sums every positive finite dt).
        // Lock at clock 0.1 s; one no-lock frame over 60 s puts the clock at 60.1 s, so at Record the reading is
        // 60.0 s old (> 2.0 s): the held speed is cleared. The 60 s frame itself gives no travel (dt >= 1 s).
        var tracker = LineSpeedTracker()
        _ = tracker.add(rawSpeed: 300, dt: 0.1)
        XCTAssertEqual(tracker.travel, 30, accuracy: 1e-12)                // 300 mm/s × 0.1 s
        XCTAssertNil(tracker.add(rawSpeed: nil, dt: 60))
        XCTAssertEqual(tracker.travel, 30, accuracy: 1e-12)                // unchanged by the long gap
        XCTAssertEqual(tracker.lastValidSpeed, 300)
        tracker.beginRecording()
        XCTAssertNil(tracker.lastValidSpeed)
        let start = tracker.travel
        for _ in 0..<30 { XCTAssertNil(tracker.add(rawSpeed: nil, dt: 0.1)) }
        XCTAssertEqual(tracker.travel - start, 0)                          // recorded travel stays at zero
    }

    func testInvalidIntervalsDoNotAdvanceTheTrackerClock() {
        // X-3: dt = NaN, 0 and negative do not move the clock, so they never age the held speed, and they never
        // turn the clock into NaN.
        var tracker = LineSpeedTracker()
        _ = tracker.add(rawSpeed: 300, dt: 0.5)                           // reading at clock 0.5 s
        _ = tracker.add(rawSpeed: nil, dt: 0.25)
        _ = tracker.add(rawSpeed: nil, dt: 0.25)                          // clock 1.0 s: the reading is 0.5 s old
        let travelBefore = tracker.travel
        XCTAssertEqual(travelBefore, 150 + 75 + 75, accuracy: 1e-12)      // 300 mm/s × (0.5 + 0.25 + 0.25) s
        // Three rounds so that a clock that counted |dt| (3 × 1 s extra) or went NaN would show: 1.0 s stays 1.0 s.
        for _ in 0..<3 {
            _ = tracker.add(rawSpeed: nil, dt: .nan)
            _ = tracker.add(rawSpeed: nil, dt: 0)
            _ = tracker.add(rawSpeed: nil, dt: -1)
        }
        XCTAssertEqual(tracker.travel, travelBefore)                      // none is a travel interval
        tracker.beginRecording()
        // Age at Record is 0.5 s (≤ 2.0 s): the held speed is kept.
        XCTAssertEqual(tracker.lastValidSpeed, 300)
        let start = tracker.travel
        _ = tracker.add(rawSpeed: nil, dt: 0.25)
        XCTAssertEqual(tracker.travel - start, 75, accuracy: 1e-12)       // held 300 mm/s × 0.25 s

        // 3 s of valid no-lock frames: clock 1.25 + 3.0 = 4.25 s, the reading (0.5 s) is 3.75 s old > 2.0 s.
        // A NaN clock would compare false and keep the speed, so clearing it proves the clock stayed finite.
        for _ in 0..<12 { _ = tracker.add(rawSpeed: nil, dt: 0.25) }
        tracker.beginRecording()
        XCTAssertNil(tracker.lastValidSpeed)
        let again = tracker.travel
        _ = tracker.add(rawSpeed: nil, dt: 0.25)
        XCTAssertEqual(tracker.travel, again)                             // no held speed left to integrate
    }

    func testSmoothedSpeedNeedsThreeValidReadings() throws {
        var tracker = LineSpeedTracker()
        XCTAssertEqual(tracker.add(rawSpeed: 100, dt: 0.1), 100)          // raw until three readings
        XCTAssertNil(tracker.add(rawSpeed: nil, dt: 0.1))
        XCTAssertEqual(tracker.add(rawSpeed: 200, dt: 0.1), 200)
        XCTAssertEqual(try XCTUnwrap(tracker.add(rawSpeed: 300, dt: 0.1)), 200, accuracy: 1e-12)
        // With three readings in the window a frame without lock still shows the average.
        XCTAssertEqual(try XCTUnwrap(tracker.add(rawSpeed: nil, dt: 0.1)), 200, accuracy: 1e-12)
    }

    func testSmoothedReadingsAgeOutAfterFifteenFrames() {
        var tracker = LineSpeedTracker()
        for _ in 0..<3 { _ = tracker.add(rawSpeed: 100, dt: 0.1) }
        for _ in 0..<12 { XCTAssertEqual(tracker.add(rawSpeed: nil, dt: 0.1), 100) }
        XCTAssertNil(tracker.add(rawSpeed: nil, dt: 0.1))                 // only two of the readings are left
        tracker.clearHeldSpeed()
        XCTAssertEqual(tracker.add(rawSpeed: 400, dt: 0.1), 400)
    }

    // MARK: - Angles

    func testMotionAngle() throws {
        XCTAssertEqual(try XCTUnwrap(LineMotionMath.motionAngle(along: 10, across: 10)), 45, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(LineMotionMath.motionAngle(along: -10, across: 10)), 45, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(LineMotionMath.motionAngle(along: 10, across: -10)), -45, accuracy: 1e-12)
        XCTAssertNil(LineMotionMath.motionAngle(along: 2, across: 1))
        XCTAssertNil(LineMotionMath.motionAngle(along: -2, across: 1))
    }

    func testGravityTilt() {
        XCTAssertEqual(LineMotionMath.gravityTilt(-0.5), 30, accuracy: 1e-9)
        XCTAssertEqual(LineMotionMath.gravityTilt(0.5), -30, accuracy: 1e-9)
        XCTAssertEqual(LineMotionMath.gravityTilt(0), 0)
        XCTAssertEqual(LineMotionMath.gravityTilt(-2), 90, accuracy: 1e-9)     // clamped
        XCTAssertEqual(LineMotionMath.gravityTilt(2), -90, accuracy: 1e-9)
    }

    // MARK: - Surface tilt (plane fit)

    private let tiltWidth = 64
    private let tiltHeight = 48
    private let f = 60.0
    private let cx = 32.0
    private let cy = 24.0

    /// Depth map (planar Z, mm) of the plane Z = z0 + a·X + b·Y in camera coordinates, where X = (u − cx)·Z / f
    /// points to the bottom of the portrait screen and Y = (v − cy)·Z / f to its left:
    /// Z = z0 / (1 − a·(u − cx)/f − b·(v − cy)/f).
    private func planeMap(z0: Double = 1000, a: Double, b: Double) -> [Float] {
        var map = [Float](repeating: 0, count: tiltWidth * tiltHeight)
        for v in 0..<tiltHeight {
            for u in 0..<tiltWidth {
                let z = z0 / (1 - a * (Double(u) - cx) / f - b * (Double(v) - cy) / f)
                map[v * tiltWidth + u] = Float(z)
            }
        }
        return map
    }

    private func surfaceTilt(_ map: [Float]) -> (x: Double, y: Double)? {
        LineMotionMath.surfaceTilt(map, width: tiltWidth, height: tiltHeight, fx: f, fy: f, cx: cx, cy: cy)
    }

    func testLevelSurfaceHasNoTilt() throws {
        let tilt = try XCTUnwrap(surfaceTilt(planeMap(a: 0, b: 0)))
        XCTAssertEqual(tilt.x, 0, accuracy: 1e-6)
        XCTAssertEqual(tilt.y, 0, accuracy: 1e-6)
    }

    func testSurfaceFartherAtTheScreenBottomIsTopEdgeLow() throws {
        // Farther toward the bottom of the screen = the phone's bottom edge is high above the surface:
        // top edge low, so tilt Y is negative (+Y = top edge high, as with gravity).
        let tilt = try XCTUnwrap(surfaceTilt(planeMap(a: tan(10 * Double.pi / 180), b: 0)))
        XCTAssertEqual(tilt.y, -10, accuracy: 1e-3)
        XCTAssertEqual(tilt.x, 0, accuracy: 1e-3)
    }

    func testSurfaceFartherAtTheScreenLeftIsRightEdgeLow() throws {
        // Farther toward the left of the screen = left edge high, right edge low: tilt X is negative
        // (+X = right edge high).
        let tilt = try XCTUnwrap(surfaceTilt(planeMap(a: 0, b: tan(5 * Double.pi / 180))))
        XCTAssertEqual(tilt.x, -5, accuracy: 1e-3)
        XCTAssertEqual(tilt.y, 0, accuracy: 1e-3)
    }

    func testSurfaceTiltedBothWays() throws {
        let tilt = try XCTUnwrap(surfaceTilt(planeMap(a: -tan(7 * Double.pi / 180), b: tan(3 * Double.pi / 180))))
        XCTAssertEqual(tilt.y, 7, accuracy: 1e-3)
        XCTAssertEqual(tilt.x, -3, accuracy: 1e-3)
    }

    func testSurfaceTiltIgnoresMissingReadings() throws {
        var map = planeMap(a: tan(10 * Double.pi / 180), b: 0)
        for i in stride(from: 0, to: map.count, by: 3) { map[i] = 0 }
        let tilt = try XCTUnwrap(surfaceTilt(map))
        XCTAssertEqual(tilt.y, -10, accuracy: 1e-3)
    }

    func testSurfaceTiltRefusesTooLittleData() {
        XCTAssertNil(surfaceTilt([Float](repeating: 0, count: tiltWidth * tiltHeight)))
        let level = planeMap(a: 0, b: 0)
        XCTAssertNil(LineMotionMath.surfaceTilt(level, width: tiltWidth, height: tiltHeight, fx: 0, fy: f, cx: cx, cy: cy))
        XCTAssertNil(LineMotionMath.surfaceTilt(level, width: tiltWidth, height: tiltHeight, fx: f, fy: 0, cx: cx, cy: cy))
        XCTAssertNil(LineMotionMath.surfaceTilt(Array(level.prefix(16 * 16)), width: 16, height: 16,
                                                fx: f, fy: f, cx: 8, cy: 8))
        XCTAssertNil(LineMotionMath.surfaceTilt(Array(level.prefix(100)), width: tiltWidth, height: tiltHeight,
                                                fx: f, fy: f, cx: cx, cy: cy))      // short map
    }

    // MARK: - Medians and spread

    func testRegionMedian() {
        let map = zoneMap()
        // Zone 7 (column 1, row 1) reads 1070 mm everywhere.
        XCTAssertEqual(LineMotionMath.regionMedian(map, width: mapWidth, height: mapHeight,
                                                   regionX: 1.0 / 6...2.0 / 6, regionY: 0.25...0.5), 1070)
        // Fewer than 8 readings: 0.
        XCTAssertEqual(LineMotionMath.regionMedian(map, width: mapWidth, height: mapHeight,
                                                   regionX: 0...0.05, regionY: 0...0.05), 0)
        XCTAssertEqual(LineMotionMath.regionMedian(zoneMap(empty: [7]), width: mapWidth, height: mapHeight,
                                                   regionX: 1.0 / 6...2.0 / 6, regionY: 0.25...0.5), 0)
        XCTAssertEqual(LineMotionMath.regionMedian([], width: mapWidth, height: mapHeight,
                                                   regionX: 0...1, regionY: 0...1), 0)
    }

    func testCenterMedian() {
        var map = [Float](repeating: 0, count: 16 * 16)
        XCTAssertEqual(LineMotionMath.centerMedian(map, width: 16, height: 16), 0)
        for i in map.indices { map[i] = -5 }
        XCTAssertEqual(LineMotionMath.centerMedian(map, width: 16, height: 16), 0)          // distances must be > 0
        XCTAssertEqual(LineMotionMath.centerMedian(map, width: 16, height: 16, allowNegative: true), -5)
        for i in map.indices { map[i] = 1234 }
        XCTAssertEqual(LineMotionMath.centerMedian(map, width: 16, height: 16), 1234)
    }

    func testSpread() throws {
        let flat = [Float](repeating: 800, count: 40 * 40)
        let flatSpread = flat.withUnsafeBufferPointer { LineMotionMath.spread($0, width: 40, height: 40) }
        XCTAssertEqual(try XCTUnwrap(flatSpread), 0, accuracy: 1e-6)
        // Alternate rows of 790 and 810: std dev 10 mm (every third row is sampled, both values appear).
        var rows = [Float](repeating: 0, count: 60 * 60)
        for y in 0..<60 { for x in 0..<60 { rows[y * 60 + x] = y % 2 == 0 ? 790 : 810 } }
        let rowSpread = rows.withUnsafeBufferPointer { LineMotionMath.spread($0, width: 60, height: 60) }
        XCTAssertEqual(try XCTUnwrap(rowSpread), 10, accuracy: 0.2)
        let small = [Float](repeating: 800, count: 8 * 8)
        XCTAssertNil(small.withUnsafeBufferPointer { LineMotionMath.spread($0, width: 8, height: 8) })
    }
}
