import Foundation

/// Per-frame speed, zone, travel, smoothing and tilt maths of the line-scan capture (`LineCapturePipeline`).
/// Foundation only, so the unit-test target compiles it without AVFoundation or a device.
///
/// Units: distances mm, speeds mm/s (+ = travel direction), times s, angles degrees. Depth maps are row-major in
/// sensor landscape (design §6.1): u (column, x) runs across the material = top → bottom of the portrait screen,
/// v (row, y) runs along the travel = right → left. 0 in a depth map = no reading.
enum LineMotionMath {
    /// Texture-tracking quality needed for the main speed reading.
    static let minimumTrackQuality = 0.1
    /// Tracking quality needed for a zone's speed reading.
    static let minimumZoneQuality = 0.12

    /// Frame interval (s) that gives a speed: rejects a repeated timestamp (≤ 1 ms) and a gap of a second or more.
    static func isSpeedInterval(_ dt: Double) -> Bool {
        dt > 0.001 && dt < 1
    }

    /// Frame interval (s) over which travel is integrated: any positive interval under a second.
    static func isTravelInterval(_ dt: Double) -> Bool {
        dt > 0 && dt < 1
    }

    /// Depth focal length `fy` (depth pixels) scaled to full-resolution video pixels: the video and depth images
    /// cover the same field of view, so the scale is the ratio of their heights.
    static func videoFocalLength(depthFy: Double, videoHeight: Int, depthHeight: Int) -> Double {
        depthFy * Double(videoHeight) / Double(max(depthHeight, 1))
    }

    /// Surface speed (mm/s) from a texture shift: pixels moved × (distance / focal length) mm per pixel / time.
    /// Nil if the result is not finite.
    static func speed(shiftPixels: Double, distance: Double, focalPixels: Double, dt: Double) -> Double? {
        let v = shiftPixels * (distance / focalPixels) / dt
        return v.isFinite ? v : nil
    }

    /// The main speed reading (mm/s) of one frame, or nil when a gate fails: interval (`isSpeedInterval`),
    /// tracking quality (`minimumTrackQuality`), focal length and distance. The distance of the tracked area sets
    /// the mm-per-pixel scale; without one (no readings there) the centre distance is used.
    static func trackedSpeed(shiftPixels: Double, quality: Double, trackedDistance: Double, centerDistance: Double,
                             focalPixels: Double, dt: Double) -> Double? {
        guard isSpeedInterval(dt) else { return nil }
        let distance = trackedDistance > 0 ? trackedDistance : centerDistance
        guard quality >= minimumTrackQuality, focalPixels > 0, distance > 0 else { return nil }
        return speed(shiftPixels: shiftPixels, distance: distance, focalPixels: focalPixels, dt: dt)
    }

    /// Speed of each zone (mm/s), `columns × rows`, index row · columns + column (`ZoneGrid`). A zone has a speed
    /// when its tracking quality reaches `minimumZoneQuality`; its scale comes from the median distance of its own
    /// part of the depth map (else the centre distance). All nil if the interval fails, the focal length is not
    /// positive or `tiles` does not have one entry per zone.
    static func zoneSpeeds(tiles: [(along: Double, quality: Double)?], millimetres: [Float], width: Int, height: Int,
                           centerDistance: Double, focalPixels: Double, dt: Double,
                           columns: Int, rows: Int) -> [Double?] {
        var speeds = [Double?](repeating: nil, count: columns * rows)
        guard isSpeedInterval(dt), focalPixels > 0, tiles.count == speeds.count else { return speeds }
        for (i, tile) in tiles.enumerated() {
            guard let tile, tile.quality >= minimumZoneQuality else { continue }
            let c = i % columns
            let r = i / columns
            let zoneDistance = regionMedian(
                millimetres, width: width, height: height,
                regionX: Double(c) / Double(columns)...Double(c + 1) / Double(columns),
                regionY: Double(r) / Double(rows)...Double(r + 1) / Double(rows))
            let distance = zoneDistance > 0 ? zoneDistance : centerDistance
            guard distance > 0 else { continue }
            speeds[i] = speed(shiftPixels: tile.along, distance: distance, focalPixels: focalPixels, dt: dt)
        }
        return speeds
    }

    /// Zone with the largest speed magnitude (signed speed returned); the first one wins a tie.
    static func fastest(_ speeds: [Double?]) -> (speed: Double, index: Int)? {
        var best: (speed: Double, index: Int)?
        for (i, v) in speeds.enumerated() {
            guard let v else { continue }
            if let current = best, abs(v) <= abs(current.speed) { continue }
            best = (v, i)
        }
        return best
    }

    /// Angle (degrees) of the texture motion from the travel axis, + toward increasing buffer x (screen bottom);
    /// nil for shifts of 2 px or less along the travel, where the angle is mostly noise.
    static func motionAngle(along: Double, across: Double) -> Double? {
        guard abs(along) > 2 else { return nil }
        return atan2(across, abs(along)) * 180 / .pi
    }

    /// Phone tilt (degrees) from one gravity component (in g): asin(−g), clamped to ±90°. With the x component:
    /// + = right edge high; with the y component: + = top edge high (portrait screen).
    static func gravityTilt(_ component: Double) -> Double {
        asin(max(-1, min(1, -component))) * 180 / .pi
    }

    /// Fits a plane Z = a·X + b·Y + c to the depth points (mm, camera coordinates) and converts its slope
    /// to phone tilt relative to that surface (same signs as `gravityTilt`). Depth columns run down the portrait
    /// screen, rows run right → left. Nil with fewer than 50 points, a singular fit or invalid intrinsics.
    static func surfaceTilt(_ millimetres: [Float], width: Int, height: Int,
                            fx: Double, fy: Double, cx: Double, cy: Double) -> (x: Double, y: Double)? {
        guard fx > 0, fy > 0, width > 16, height > 16, millimetres.count >= width * height else { return nil }
        var n = 0.0, sx = 0.0, sy = 0.0, sz = 0.0
        var sxx = 0.0, syy = 0.0, sxy = 0.0, sxz = 0.0, syz = 0.0
        let border = max(2, min(width, height) / 16)
        var v = border
        while v < height - border {
            var u = border
            while u < width - border {
                let z = Double(millimetres[v * width + u])
                if z > 0 {
                    let x = (Double(u) - cx) * z / fx      // toward the bottom of the screen
                    let y = (Double(v) - cy) * z / fy      // toward the left of the screen
                    n += 1; sx += x; sy += y; sz += z
                    sxx += x * x; syy += y * y; sxy += x * y; sxz += x * z; syz += y * z
                }
                u += 4
            }
            v += 4
        }
        guard n >= 50 else { return nil }
        // Solve the 3×3 normal equations for (a, b, c) with Cramer's rule.
        let m = [[sxx, sxy, sx], [sxy, syy, sy], [sx, sy, n]]
        let r = [sxz, syz, sz]
        func det(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1])
                - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let d = det(m)
        guard abs(d) > 1e-9 else { return nil }
        var ma = m
        var mb = m
        for i in 0..<3 {
            ma[i][0] = r[i]
            mb[i][1] = r[i]
        }
        let a = det(ma) / d      // dZ per mm toward the screen bottom
        let b = det(mb) / d      // dZ per mm toward the screen left
        // Farther at the bottom = bottom edge high = top edge low; farther at the left = left edge high.
        let tiltY = -atan(a) * 180 / .pi
        let tiltX = -atan(b) * 180 / .pi
        guard tiltX.isFinite, tiltY.isFinite else { return nil }
        return (tiltX, tiltY)
    }

    /// Median distance (mm) inside a normalized region (0…1 of width and height) of the depth map, from every
    /// second pixel in each direction; 0 when fewer than 8 of them have a reading.
    static func regionMedian(_ millimetres: [Float], width: Int, height: Int,
                             regionX: ClosedRange<Double>, regionY: ClosedRange<Double>) -> Double {
        guard width > 0, height > 0, millimetres.count >= width * height else { return 0 }
        let x0 = max(0, min(width - 1, Int(regionX.lowerBound * Double(width))))
        let x1 = max(x0 + 1, min(width, Int(regionX.upperBound * Double(width))))
        let y0 = max(0, min(height - 1, Int(regionY.lowerBound * Double(height))))
        let y1 = max(y0 + 1, min(height, Int(regionY.upperBound * Double(height))))
        var samples: [Float] = []
        samples.reserveCapacity((x1 - x0) * (y1 - y0) / 4 + 1)
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                let z = millimetres[y * width + x]
                if z > 0 { samples.append(z) }
                x += 2
            }
            y += 2
        }
        guard samples.count >= 8 else { return 0 }
        samples.sort()
        return Double(samples[samples.count / 2])
    }

    /// Median of the central half of the map (every second pixel): distances (> 0), or heights (any finite value)
    /// with `allowNegative`. 0 when there is no value.
    static func centerMedian(_ millimetres: [Float], width: Int, height: Int, allowNegative: Bool = false) -> Double {
        guard millimetres.count >= width * height else { return 0 }
        var samples: [Float] = []
        samples.reserveCapacity(max(0, width * height / 16))
        var y = height / 4
        while y < height * 3 / 4 {
            var x = width / 4
            while x < width * 3 / 4 {
                let z = millimetres[y * width + x]
                if allowNegative ? z.isFinite : z > 0 { samples.append(z) }
                x += 2
            }
            y += 2
        }
        guard !samples.isEmpty else { return 0 }
        samples.sort()
        return Double(samples[samples.count / 2])
    }

    /// Std dev (mm) of the finite, non-zero values in the central 80 % of the view (every third pixel):
    /// a flatness check. Nil with 20 values or fewer.
    static func spread(_ values: UnsafeBufferPointer<Float>, width: Int, height: Int) -> Double? {
        guard values.count >= width * height else { return nil }
        var s = 0.0, ss = 0.0, n = 0.0
        var y = height / 10
        while y < height - height / 10 {
            var x = width / 10
            while x < width - width / 10 {
                let v = values[y * width + x]
                if v.isFinite && v != 0 {
                    let d = Double(v)
                    s += d
                    ss += d * d
                    n += 1
                }
                x += 3
            }
            y += 3
        }
        guard n > 20 else { return nil }
        let m = s / n
        return max(0, ss / n - m * m).squareRoot()
    }
}

/// Main speed state of the capture: travel integration with the held speed, and the half-second rolling average
/// shown on screen. Owned by the capture data queue (a value type, no sharing).
///
/// Time: the tracker keeps its own clock (s), the sum of the positive frame intervals `dt` it is given, i.e. the
/// frame timestamps the capture computes `dt` from (gaps of a second or more count too). Readings are stamped with it
/// so `beginRecording` can tell how old they are.
struct LineSpeedTracker {
    /// Rolling-average window, frames (~0.5 s at 30 fps).
    static let windowFrames = 15
    /// Valid readings in the window needed for an average; below this the raw reading is shown.
    static let minimumReadings = 3
    /// Oldest reading (s, by the tracker clock) that a recording may start with: the held speed and window readings
    /// at most this old at Record are kept, older ones are cleared (Y-1).
    static let recordingCarryOverAge = 2.0

    /// Material travel since the capture started, mm (+ = travel direction).
    private(set) var travel: Double = 0
    /// Last valid speed reading (mm/s): travel keeps integrating it through frames without texture lock.
    private(set) var lastValidSpeed: Double?
    /// Tracker clock (s) of `lastValidSpeed`'s frame.
    private var lastValidTime: Double?
    /// Tracker clock (s): sum of the positive, finite frame intervals added so far.
    private var clock: Double = 0
    /// The last `windowFrames` readings with their tracker clock (s); speed NaN = no reading (missing readings age
    /// out of the window).
    private var recent: [(speed: Double, time: Double)] = []

    /// Adds one frame's reading (nil = no texture lock) over the interval `dt` (s) since the previous frame and
    /// returns the smoothed speed: the mean of the window's valid readings when there are at least
    /// `minimumReadings`, else `rawSpeed`. Travel grows by (rawSpeed, else the held speed, else 0) × dt for
    /// intervals accepted by `LineMotionMath.isTravelInterval`.
    mutating func add(rawSpeed: Double?, dt: Double) -> Double? {
        if dt.isFinite && dt > 0 { clock += dt }
        if let v = rawSpeed {
            lastValidSpeed = v
            lastValidTime = clock
        }
        if LineMotionMath.isTravelInterval(dt) { travel += (rawSpeed ?? lastValidSpeed ?? 0) * dt }
        recent.append((rawSpeed ?? .nan, clock))
        if recent.count > Self.windowFrames { recent.removeFirst(recent.count - Self.windowFrames) }
        let valid = recent.map(\.speed).filter { !$0.isNaN }
        return valid.count >= Self.minimumReadings ? valid.reduce(0, +) / Double(valid.count) : rawSpeed
    }

    /// Forgets the held speed and the rolling window (travel is kept): readings from before must not carry over.
    mutating func clearHeldSpeed() {
        lastValidSpeed = nil
        lastValidTime = nil
        recent.removeAll()
    }

    /// A recording starts with the frame just passed to `add` (travel is unchanged, so the recording's travel
    /// starts at 0 there). Y-1: the held speed is kept when its reading is at most `recordingCarryOverAge` old
    /// by the tracker clock, so frames without lock right after Record still advance; an older one is cleared
    /// (Z-1), and so are window entries older than that limit. Mid-recording behaviour is unchanged.
    mutating func beginRecording() {
        let oldest = clock - Self.recordingCarryOverAge
        if let t = lastValidTime, t < oldest {
            lastValidSpeed = nil
            lastValidTime = nil
        }
        recent.removeAll { $0.time < oldest }
    }
}

/// Rolling average of the zone speeds over the last `windowFrames` frames, for the live overlay.
struct ZoneSpeedSmoother {
    /// Window, frames (~0.5 s at 30 fps).
    static let windowFrames = 15
    /// Readings of a zone in the window needed for its average; fewer = no value.
    static let minimumReadings = 4

    private var history: [[Double?]] = []

    /// Adds one frame of zone speeds and returns the averages, one per zone of `speeds`.
    mutating func add(_ speeds: [Double?]) -> [Double?] {
        history.append(speeds)
        if history.count > Self.windowFrames { history.removeFirst(history.count - Self.windowFrames) }
        var smooth = [Double?](repeating: nil, count: speeds.count)
        for i in 0..<speeds.count {
            var sum = 0.0
            var n = 0
            for frame in history where i < frame.count {
                if let v = frame[i] {
                    sum += v
                    n += 1
                }
            }
            if n >= Self.minimumReadings { smooth[i] = sum / Double(n) }
        }
        return smooth
    }

    mutating func reset() {
        history.removeAll()
    }
}
