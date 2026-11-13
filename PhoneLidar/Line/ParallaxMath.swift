import Foundation
import simd

// Camera-parallax heights (design §15, FR-PAR): lens model, camera rays, triangulation with a known travel
// direction, patch matching and the LiDAR scale. Pure logic: no AVFoundation, in the test target.

/// Lens distortion of the video camera as AVFoundation reports it (`AVCameraCalibrationData`), stored in
/// Recording.json. Tables hold the relative radial magnification for radii 0 … r_max (linearly spaced), r_max =
/// distance from the distortion centre to the farthest image corner, all in reference-image pixels.
struct LensCalibration: Codable, Equatable, Sendable {
    var referenceWidth: Double
    var referenceHeight: Double
    /// Distortion centre, reference pixels.
    var centerX: Double
    var centerY: Double
    /// `lensDistortionLookupTable`: maps an undistorted (rectilinear) point to where it appears in the image.
    var forward: [Float]
    /// `inverseLensDistortionLookupTable`: maps an image point to its undistorted position.
    var inverse: [Float]

    /// Both tables usable (≥ 2 finite entries) and a positive reference size.
    var isValid: Bool {
        referenceWidth > 0 && referenceHeight > 0 && centerX.isFinite && centerY.isFinite
            && forward.count >= 2 && inverse.count >= 2
            && forward.allSatisfy(\.isFinite) && inverse.allSatisfy(\.isFinite)
    }

    /// Magnification at `radius` by linear interpolation (Apple's reference implementation); the last entry beyond
    /// r_max.
    static func magnification(_ table: [Float], radius: Double, maxRadius: Double) -> Double {
        guard table.count >= 2, maxRadius > 0 else { return 0 }
        guard radius < maxRadius else { return Double(table[table.count - 1]) }
        let position = max(0, radius) * Double(table.count - 1) / maxRadius
        let index = min(table.count - 2, Int(position))
        let fraction = position - Double(index)
        return (1 - fraction) * Double(table[index]) + fraction * Double(table[index + 1])
    }

    /// Applies `table` to an image point (pixels of an image `width` × `height`, scaled to the reference size).
    func apply(_ table: [Float], x: Double, y: Double, width: Int, height: Int) -> (x: Double, y: Double) {
        guard width > 0, height > 0 else { return (x, y) }
        let sx = referenceWidth / Double(width)
        let sy = referenceHeight / Double(height)
        let dx = x * sx - centerX
        let dy = y * sy - centerY
        let mx = max(centerX, referenceWidth - centerX)
        let my = max(centerY, referenceHeight - centerY)
        let rMax = (mx * mx + my * my).squareRoot()
        let m = Self.magnification(table, radius: (dx * dx + dy * dy).squareRoot(), maxRadius: rMax)
        return ((centerX + dx * (1 + m)) / sx, (centerY + dy * (1 + m)) / sy)
    }

    func undistort(x: Double, y: Double, width: Int, height: Int) -> (x: Double, y: Double) {
        apply(inverse, x: x, y: y, width: width, height: height)
    }

    func distort(x: Double, y: Double, width: Int, height: Int) -> (x: Double, y: Double) {
        apply(forward, x: x, y: y, width: width, height: height)
    }
}

/// Pinhole camera of the video picture (buffer orientation, pixels) with an optional lens model.
struct ParallaxCamera: Sendable {
    var width: Int
    var height: Int
    var fx: Double
    var fy: Double
    var cx: Double
    var cy: Double
    var lens: LensCalibration?

    /// Video intrinsics from a frame's depth intrinsics (the depth map is registered to the video, same aspect).
    init(frame: LineFrameInfo, videoWidth: Int, videoHeight: Int, depthWidth: Int, depthHeight: Int,
         lens: LensCalibration?) {
        let sx = Double(videoWidth) / Double(max(depthWidth, 1))
        let sy = Double(videoHeight) / Double(max(depthHeight, 1))
        self.init(width: videoWidth, height: videoHeight, fx: Double(frame.fx) * sx, fy: Double(frame.fy) * sy,
                  cx: Double(frame.cx) * sx, cy: Double(frame.cy) * sy, lens: lens)
    }

    init(width: Int, height: Int, fx: Double, fy: Double, cx: Double, cy: Double, lens: LensCalibration?) {
        self.width = width
        self.height = height
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.lens = lens.flatMap { $0.isValid ? $0 : nil }
    }

    var isValid: Bool { width > 0 && height > 0 && fx > 0 && fy > 0 && cx.isFinite && cy.isFinite }

    /// Ray (x_n, y_n, 1) through an image point, lens distortion removed.
    func ray(x: Double, y: Double) -> SIMD3<Double> {
        let p = lens?.undistort(x: x, y: y, width: width, height: height) ?? (x, y)
        return SIMD3<Double>((p.x - cx) / fx, (p.y - cy) / fy, 1)
    }

    /// Image point of a camera-frame point (lens distortion applied), nil behind the camera.
    func project(_ point: SIMD3<Double>) -> (x: Double, y: Double)? {
        guard point.z > 1e-6 else { return nil }
        let x = cx + fx * point.x / point.z
        let y = cy + fy * point.y / point.z
        return lens?.distort(x: x, y: y, width: width, height: height) ?? (x, y)
    }
}

enum ParallaxGeometry {
    /// Depth of the first view per millimetre of travel. The material point P moves by s·`travel` (unit vector,
    /// camera frame) between the views: Z₁·r₁ + s·u = Z₂·r₂ for rays r = (x_n, y_n, 1). Least squares in Z₁, Z₂
    /// gives Z₁ = s·g with g = ((r₁·u)(r₂·r₂) − (r₁·r₂)(r₂·u)) / ((r₁·r₂)² − (r₁·r₁)(r₂·r₂)). Nil for (nearly)
    /// parallel rays or a point behind the camera.
    static func depthPerTravel(_ r1: SIMD3<Double>, _ r2: SIMD3<Double>, travel u: SIMD3<Double>) -> Double? {
        let a = simd_dot(r1, r1)
        let b = simd_dot(r1, r2)
        let c = simd_dot(r2, r2)
        let denominator = b * b - a * c
        guard abs(denominator) > 1e-12 * a * c else { return nil }
        let g = (simd_dot(r1, u) * c - b * simd_dot(r2, u)) / denominator
        return g.isFinite && g > 0 ? g : nil
    }

    /// Unit travel direction of the material in camera coordinates: parallel to the belt (perpendicular to
    /// `normal`) and seen in the picture as (`acrossPerAlong`, `sign`) (buffer x, buffer y).
    static func travelDirection(normal n: SIMD3<Double>, acrossPerAlong: Double, sign: Int) -> SIMD3<Double> {
        let ax = acrossPerAlong.isFinite ? acrossPerAlong : 0
        let ay = Double(sign >= 0 ? 1 : -1)
        let w = abs(n.z) > 1e-6 ? -(ax * n.x + ay * n.y) / n.z : 0
        let u = SIMD3<Double>(ax, ay, w)
        return u / simd_length(u)
    }

    /// Belt normal for the travel direction: the phone tilt relative to the level zero when the recording holds a
    /// height reference with one, else the median LiDAR surface tilt (the mat is parallel to the belt), else the
    /// gravity tilt, else straight down.
    static func beltNormal(frames: [LineFrameInfo], reference: HeightReference?) -> SIMD3<Double> {
        func median(_ values: [Double?]) -> Double? { HeightMath.median(values.compactMap { $0 }.filter(\.isFinite)) }
        if let reference, reference.levelZeroX != nil || reference.levelZeroY != nil,
           let x = median(frames.map(\.tiltX)), let y = median(frames.map(\.tiltY)) {
            return HeightPlane.normal(tiltX: x - (reference.levelZeroX ?? 0), tiltY: y - (reference.levelZeroY ?? 0))
        }
        if let x = median(frames.map(\.surfaceTiltX)), let y = median(frames.map(\.surfaceTiltY)) {
            return HeightPlane.normal(tiltX: x, tiltY: y)
        }
        if let x = median(frames.map(\.tiltX)), let y = median(frames.map(\.tiltY)) {
            return HeightPlane.normal(tiltX: x, tiltY: y)
        }
        return SIMD3<Double>(0, 0, 1)
    }

    /// Across movement per along movement of the main texture match (buffer x per buffer y of travel), median of the
    /// frames with a confident shift of more than 2 px; 0 without any.
    static func acrossPerAlong(frames: [LineFrameInfo]) -> Double {
        var ratios: [Double] = []
        for f in frames {
            guard let along = f.shiftPixels, let across = f.crossShiftPixels, along > 2, f.quality >= 0.15 else {
                continue
            }
            let r = across / along
            if r.isFinite, abs(r) < 0.5 { ratios.append(r) }
        }
        return HeightMath.median(ratios) ?? 0
    }

    /// Map cell for a parallax map: the patch spacing at the typical distance, rounded up to 0.1 mm.
    static func cellSize(spacingPixels: Int, distance: Double, focal: Double) -> Double {
        guard focal > 0, distance > 0 else { return 2 }
        let raw = Double(spacingPixels) * distance / focal
        return max(0.5, ((raw - 1e-9) * 10).rounded(.up) / 10)
    }
}

/// An 8-bit luma image (or a band of rows of one) owned as an array. `originY` = buffer row of pixel row 0.
struct LumaPlane: Sendable {
    var pixels: [UInt8]
    var width: Int
    var height: Int
    var originY: Int

    init(pixels: [UInt8], width: Int, height: Int, originY: Int = 0) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.originY = originY
    }

    /// Rows [y0, y0 + rows) of a strided luma buffer (rows outside the buffer are clamped away).
    init(copying source: UnsafeBufferPointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, rows: Range<Int>) {
        let lo = max(0, rows.lowerBound)
        let hi = min(height, rows.upperBound)
        let count = max(0, hi - lo)
        var out = [UInt8](repeating: 0, count: count * width)
        if count > 0, let base = source.baseAddress, bytesPerRow >= width, source.count >= (hi - 1) * bytesPerRow + width {
            out.withUnsafeMutableBufferPointer { dst in
                guard let target = dst.baseAddress else { return }
                for r in 0..<count {
                    (target + r * width).update(from: base + (lo + r) * bytesPerRow, count: width)
                }
            }
        }
        self.init(pixels: out, width: width, height: count, originY: lo)
    }

    /// 2 × 2 box average: pixel (i, j) = mean of (2i…2i+1, 2j…2j+1); `originY` must be even.
    func halved() -> LumaPlane {
        let w = width / 2
        let h = height / 2
        var out = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeBufferPointer { src in
            for j in 0..<h {
                let r0 = 2 * j * width
                let r1 = r0 + width
                for i in 0..<w {
                    let sum = Int(src[r0 + 2 * i]) + Int(src[r0 + 2 * i + 1]) + Int(src[r1 + 2 * i]) + Int(src[r1 + 2 * i + 1])
                    out[j * w + i] = UInt8((sum + 2) / 4)
                }
            }
        }
        return LumaPlane(pixels: out, width: w, height: h, originY: originY / 2)
    }
}

/// A square template cut from a plane, with its sums for zero-normalised cross-correlation.
struct MatchTemplate {
    let size: Int
    let values: [Int32]
    let sum: Int64
    let sumSquares: Int64

    /// Patch covering columns cx − size/2 ..< cx + size/2 and buffer rows cy − size/2 ..< cy + size/2; nil outside
    /// the plane or with a standard deviation below `minimumSD` grey levels (no texture).
    init?(plane: LumaPlane, cx: Int, cy: Int, size: Int, minimumSD: Double) {
        let x0 = cx - size / 2
        let y0 = cy - size / 2 - plane.originY
        guard size >= 4, x0 >= 0, y0 >= 0, x0 + size <= plane.width, y0 + size <= plane.height else { return nil }
        var values = [Int32](repeating: 0, count: size * size)
        var s: Int64 = 0
        var ss: Int64 = 0
        plane.pixels.withUnsafeBufferPointer { p in
            for r in 0..<size {
                let row = (y0 + r) * plane.width + x0
                for c in 0..<size {
                    let v = Int32(p[row + c])
                    values[r * size + c] = v
                    s += Int64(v)
                    ss += Int64(v) * Int64(v)
                }
            }
        }
        let n = Double(size * size)
        let variance = (Double(ss) - Double(s) * Double(s) / n) / n
        guard variance >= minimumSD * minimumSD else { return nil }
        self.size = size
        self.values = values
        self.sum = s
        self.sumSquares = ss
    }

    /// ZNCC of this template against the patch of `plane` centred at (cx, cy) (buffer coordinates); nil outside the
    /// plane or for a flat patch.
    func score(_ plane: UnsafeBufferPointer<UInt8>, width: Int, height: Int, originY: Int, cx: Int, cy: Int) -> Double? {
        let x0 = cx - size / 2
        let y0 = cy - size / 2 - originY
        guard x0 >= 0, y0 >= 0, x0 + size <= width, y0 + size <= height else { return nil }
        var sb: Int64 = 0
        var sbb: Int64 = 0
        var sab: Int64 = 0
        values.withUnsafeBufferPointer { t in
            for r in 0..<size {
                let row = (y0 + r) * width + x0
                let tr = r * size
                for c in 0..<size {
                    let b = Int64(plane[row + c])
                    sb += b
                    sbb += b * b
                    sab += Int64(t[tr + c]) * b
                }
            }
        }
        let n = Double(size * size)
        let numerator = n * Double(sab) - Double(sum) * Double(sb)
        let va = n * Double(sumSquares) - Double(sum) * Double(sum)
        let vb = n * Double(sbb) - Double(sb) * Double(sb)
        guard va > 0, vb > 0 else { return nil }
        return numerator / (va * vb).squareRoot()
    }
}

/// Sub-pixel peak of a maximum from three scores (left, centre, right): offset in −0.5…0.5, nil when the centre is
/// not a strict maximum.
func parabolicPeak(_ minus: Double, _ center: Double, _ plus: Double) -> Double? {
    let denominator = minus - 2 * center + plus
    guard denominator < 0, center >= minus, center >= plus else { return nil }
    return max(-0.5, min(0.5, 0.5 * (minus - plus) / denominator))
}

/// Coarse-to-fine search of one patch (design §15.4): ZNCC of a half-resolution template over the predicted
/// window, then hill-climbing at full resolution and a parabola in each axis.
struct PatchMatcher {
    var patch = 16
    var minimumSD = 3.0
    var minimumCoarse = 0.5
    var minimumFine = 0.75

    struct Match {
        var x: Double
        var y: Double
        var score: Double
    }

    /// Finds the template patch (full and half resolution, centred at even (tx, ty) of `templateFull`) in the search
    /// plane around the predicted full-resolution centre (px, py), searching ±`alongRadius` / ±`acrossRadius`
    /// half-resolution pixels. Nil when the patch has no texture, the best match is weak or lies on the window edge.
    func match(templateFull: LumaPlane, templateHalf: LumaPlane, tx: Int, ty: Int,
               searchFull: UnsafeBufferPointer<UInt8>, fullWidth: Int, fullHeight: Int, fullOriginY: Int,
               searchHalf: UnsafeBufferPointer<UInt8>, halfWidth: Int, halfHeight: Int, halfOriginY: Int,
               px: Double, py: Double, alongRadius: Int, acrossRadius: Int) -> Match? {
        guard let fine = MatchTemplate(plane: templateFull, cx: tx, cy: ty, size: patch, minimumSD: minimumSD),
              let coarse = MatchTemplate(plane: templateHalf, cx: tx / 2, cy: ty / 2, size: patch / 2,
                                         minimumSD: minimumSD * 0.5) else { return nil }
        let hx = Int((px / 2).rounded())
        let hy = Int((py / 2).rounded())
        var best = -2.0
        var bx = 0
        var by = 0
        for dy in -alongRadius...alongRadius {
            for dx in -acrossRadius...acrossRadius {
                guard let s = coarse.score(searchHalf, width: halfWidth, height: halfHeight, originY: halfOriginY,
                                           cx: hx + dx, cy: hy + dy) else { continue }
                if s > best {
                    best = s
                    bx = dx
                    by = dy
                }
            }
        }
        guard best >= minimumCoarse, abs(by) < alongRadius, abs(bx) < acrossRadius || acrossRadius == 0 else {
            return nil
        }
        // Full resolution: climb to the best of each 3 × 3 neighbourhood (at most 6 moves).
        let startX = 2 * (hx + bx)
        let startY = 2 * (hy + by)
        var cx = startX
        var cy = startY
        // Scores by offset from the start (the climb moves at most 7 pixels each way).
        var cache: [Int: Double] = [:]
        func score(_ x: Int, _ y: Int) -> Double? {
            let key = (y - startY + 64) * 256 + (x - startX + 64)
            if let v = cache[key] { return v }
            let v = fine.score(searchFull, width: fullWidth, height: fullHeight, originY: fullOriginY, cx: x, cy: y)
            if let v { cache[key] = v }
            return v
        }
        var centre = score(cx, cy) ?? -2
        for _ in 0..<6 {
            var moved = false
            var nx = cx
            var ny = cy
            var top = centre
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    if let s = score(cx + dx, cy + dy), s > top {
                        top = s
                        nx = cx + dx
                        ny = cy + dy
                        moved = true
                    }
                }
            }
            guard moved else { break }
            cx = nx
            cy = ny
            centre = top
        }
        guard centre >= minimumFine,
              let left = score(cx - 1, cy), let right = score(cx + 1, cy),
              let up = score(cx, cy - 1), let down = score(cx, cy + 1),
              let ox = parabolicPeak(left, centre, right),
              let oy = parabolicPeak(up, centre, down) else { return nil }
        return Match(x: Double(cx) + ox, y: Double(cy) + oy, score: centre)
    }
}

/// Median of a window of per-pair scale ratios (LiDAR scale ÷ recorded travel), so the scale follows the belt
/// without the noise of one pair (design §15.5).
struct ScaleSmoother {
    let halfWindow: Int
    private(set) var ratios: [Double?] = []

    init(halfWindow: Int = 15) {
        self.halfWindow = max(0, halfWindow)
    }

    mutating func append(_ ratio: Double?) {
        ratios.append(ratio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
    }

    /// Median of the valid ratios within ±`halfWindow` of pair `index`; nil when none.
    func smoothed(at index: Int) -> Double? {
        guard index >= 0, index < ratios.count else { return nil }
        let lo = max(0, index - halfWindow)
        let hi = min(ratios.count - 1, index + halfWindow)
        return HeightMath.median(ratios[lo...hi].compactMap { $0 })
    }

    /// Median of every valid ratio so far.
    var overall: Double? { HeightMath.median(ratios.compactMap { $0 }) }

    /// True when pair `index` has its whole window (or the stream has ended).
    func isSettled(_ index: Int) -> Bool { ratios.count > index + halfWindow }
}

/// A raw pointer shared by `concurrentPerform` iterations that each write their own element.
struct ParallaxSlots<T>: @unchecked Sendable {
    let base: UnsafeMutablePointer<T>
}
