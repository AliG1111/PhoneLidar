import Foundation
import CoreVideo

/// How far the surface texture moved between two consecutive video frames.
struct TextureShift {
    /// Full-resolution pixels moved in the travel direction (negative = moving the other way).
    var along: Double
    /// Full-resolution pixels moved across the travel direction.
    var across: Double
    /// 0 = no usable texture, 1 = sharp, unique match.
    var quality: Double
    /// Tracked area in normalized buffer coordinates (0…1): x across, y along travel.
    var regionX: ClosedRange<Double> = 0...1
    var regionY: ClosedRange<Double> = 0...1
}

/// Movement of one zone of the picture between two frames (full-resolution pixels).
struct TileShift {
    var along: Double
    var across: Double
    var quality: Double
}

/// Image-correlation tracker on the camera's luma plane (coarse-to-fine block matching
/// with parabolic sub-pixel refinement). Works in the camera buffer's native landscape
/// orientation: buffer rows run along the material's travel when the phone is in portrait.
final class SpeedEstimator {
    struct Level {
        var width: Int
        var height: Int
        var pixels: [UInt8]
    }

    /// +1: material moves toward increasing buffer rows (right → left on a portrait screen).
    var travelSign = 1

    /// Zone grid for local speeds: columns run across the material (buffer x, top → bottom of the
    /// portrait screen), rows run along the travel (buffer y, right → left of the portrait screen).
    static let tileColumns = 6
    static let tileRows = 4

    /// Local movement of each zone from the last processed frame pair (row-major: row * tileColumns + column).
    private(set) var lastTiles: [TileShift?] = []

    private var previousHalf: Level?
    private var previousEighth: Level?

    func reset() {
        previousHalf = nil
        previousEighth = nil
    }

    /// `rows`: full-resolution buffer rows to track (laser mode keeps the laser band out, design §14.5); nil = all.
    /// A change of the crop size resets the estimator (the previous level no longer matches).
    func process(_ buffer: CVPixelBuffer, rows: Range<Int>? = nil) -> TextureShift? {
        guard let half = Self.halfLevel(from: buffer, rows: rows) else { return nil }
        let eighth = Self.downsample(Self.downsample(half))
        defer {
            previousHalf = half
            previousEighth = eighth
        }
        guard let prevHalf = previousHalf, let prevEighth = previousEighth,
              prevHalf.width == half.width, prevHalf.height == half.height else {
            lastTiles = []
            return nil
        }
        lastTiles = matchTiles(prevHalf: prevHalf, prevEighth: prevEighth, half: half, eighth: eighth)
        return match(prevHalf: prevHalf, prevEighth: prevEighth, half: half, eighth: eighth)
    }

    // MARK: - Matching

    private func match(prevHalf: Level, prevEighth: Level, half: Level, eighth: Level) -> TextureShift? {
        let sign = travelSign >= 0 ? 1 : -1

        // Coarse search on the 1/8-scale image (one step = 8 full-resolution pixels).
        let w8 = eighth.width
        let h8 = eighth.height
        let tw = w8 / 2
        let tx = w8 / 4
        let th = max(12, h8 / 4)
        let back = 6
        let across = 4
        let ty = sign > 0 ? back + 1 : h8 - th - back - 1
        // Up to 60 coarse steps (480 full-resolution pixels) per frame.
        let forward = min(60, sign > 0 ? h8 - th - ty - 1 : ty - 1)
        guard forward > back, ty >= 1, tx - across >= 0, tx + tw + across <= w8 else { return nil }

        var coarseBest = Int.max
        var coarseD = 0
        var coarseE = 0
        prevEighth.pixels.withUnsafeBufferPointer { pa in
            eighth.pixels.withUnsafeBufferPointer { pb in
                for k in -back...forward {
                    let d = k * sign
                    for e in -across...across {
                        let c = Self.sad(pa, w8, pb, w8, tx: tx, ty: ty, tw: tw, th: th, dx: e, dy: d, step: 1)
                        if c < coarseBest {
                            coarseBest = c
                            coarseD = d
                            coarseE = e
                        }
                    }
                }
            }
        }
        // Best match at the far end of the search: the material moved more than the search covers.
        if coarseD * sign >= forward { return nil }

        // Refine on the 1/2-scale image around the coarse result (×4 scale step).
        let hw = half.width
        let hh = half.height
        let radius = 5
        let predD = coarseD * 4
        let predE = coarseE * 4
        let minD = predD - radius
        let maxD = predD + radius
        let minE = predE - radius
        let maxE = predE + radius
        let rtw = hw / 2
        let rtx = (hw - rtw) / 2
        guard rtx + minE >= 0, rtx + rtw + maxE <= hw else { return nil }
        var rth = max(24, hh / 4)
        // Centre the matched area (previous + current position) in the frame, where lens distortion is lowest.
        let centred = (hh - rth - predD) / 2
        let rty = max(1 - minD, max(1, centred))
        rth = min(rth, hh - 1 - rty)                  // template inside the previous frame
        if rty + rth + maxD > hh - 1 { rth = hh - 1 - rty - maxD }   // shifted template inside the current frame
        guard rth >= 16 else { return nil }

        let cols = maxE - minE + 1
        var costs = [Int](repeating: 0, count: (maxD - minD + 1) * cols)
        prevHalf.pixels.withUnsafeBufferPointer { pa in
            half.pixels.withUnsafeBufferPointer { pb in
                for d in minD...maxD {
                    for e in minE...maxE {
                        costs[(d - minD) * cols + (e - minE)] =
                            Self.sad(pa, hw, pb, hw, tx: rtx, ty: rty, tw: rtw, th: rth, dx: e, dy: d, step: 2)
                    }
                }
            }
        }

        var bestIndex = 0
        for i in costs.indices where costs[i] < costs[bestIndex] {
            bestIndex = i
        }
        let bd = bestIndex / cols + minD
        let be = bestIndex % cols + minE
        let best = Double(costs[bestIndex])
        let meanCost = Double(costs.reduce(0, +)) / Double(costs.count)
        let quality = meanCost > 0 ? max(0, min(1, (meanCost - best) / meanCost)) : 0

        func cost(_ d: Int, _ e: Int) -> Double? {
            guard d >= minD, d <= maxD, e >= minE, e <= maxE else { return nil }
            return Double(costs[(d - minD) * cols + (e - minE)])
        }
        func subpixel(_ minus: Double?, _ center: Double, _ plus: Double?) -> Double {
            guard let m = minus, let p = plus else { return 0 }
            let denominator = m - 2 * center + p
            guard denominator > 0 else { return 0 }
            return max(-0.5, min(0.5, 0.5 * (m - p) / denominator))
        }
        let fd = Double(bd) + subpixel(cost(bd - 1, be), best, cost(bd + 1, be))
        let fe = Double(be) + subpixel(cost(bd, be - 1), best, cost(bd, be + 1))
        // Half-scale pixels → full-resolution pixels.
        let top = Double(min(rty, rty + bd)) / Double(hh)
        let bottom = Double(max(rty, rty + bd) + rth) / Double(hh)
        let left = Double(rtx + min(0, be)) / Double(hw)
        let right = Double(rtx + rtw + max(0, be)) / Double(hw)
        return TextureShift(along: fd * 2 * Double(sign), across: fe * 2, quality: quality,
                            regionX: max(0, left)...min(1, max(left, right)),
                            regionY: max(0, top)...min(1, max(top, bottom)))
    }

    /// Local block matching for every zone of the grid. Zones near the downstream edge match backwards
    /// (template in the current frame, searched in the previous one) so every zone has room to measure.
    private func matchTiles(prevHalf: Level, prevEighth: Level, half: Level, eighth: Level) -> [TileShift?] {
        let sign = travelSign >= 0 ? 1 : -1
        let cols = Self.tileColumns
        let rows = Self.tileRows
        let w8 = eighth.width
        let h8 = eighth.height
        let hw = half.width
        let hh = half.height
        let ts = 16                 // template size at 1/8 scale (64 px at 1/2, 128 px full resolution)
        let back = 3
        let maxForward = 40         // 320 full-resolution pixels per frame
        let cross = 2
        var result = [TileShift?](repeating: nil, count: cols * rows)

        for row in 0..<rows {
            for col in 0..<cols {
                let tx = (2 * col + 1) * w8 / (2 * cols) - ts / 2
                let ty = (2 * row + 1) * h8 / (2 * rows) - ts / 2
                guard tx - cross >= 0, tx + ts + cross <= w8, ty >= 1, ty + ts + 1 <= h8 else { continue }
                let roomPlus = h8 - ts - ty - 1
                let roomMinus = ty - 1
                let forwardRoom = sign > 0 ? roomPlus : roomMinus
                let backwardRoom = sign > 0 ? roomMinus : roomPlus
                let useForward = forwardRoom >= backwardRoom
                let room = min(maxForward, useForward ? forwardRoom : backwardRoom)
                let backRoom = min(back, useForward ? backwardRoom : forwardRoom)
                guard room > 4, backRoom >= 0 else { continue }
                let dySign = useForward ? sign : -sign
                let dxSign = useForward ? 1 : -1
                let template8 = useForward ? prevEighth : eighth
                let search8 = useForward ? eighth : prevEighth

                var best = Int.max
                var bd = 0
                var be = 0
                template8.pixels.withUnsafeBufferPointer { pa in
                    search8.pixels.withUnsafeBufferPointer { pb in
                        for d in -backRoom...room {
                            for e in -cross...cross {
                                let c = Self.sad(pa, w8, pb, w8, tx: tx, ty: ty, tw: ts, th: ts,
                                                 dx: dxSign * e, dy: dySign * d, step: 1)
                                if c < best {
                                    best = c
                                    bd = d
                                    be = e
                                }
                            }
                        }
                    }
                }
                if bd >= room { continue }      // moving faster than this zone can measure

                // Refine at 1/2 scale around the coarse result.
                let template2 = useForward ? prevHalf : half
                let search2 = useForward ? half : prevHalf
                let tx2 = tx * 4
                let ty2 = ty * 4
                let size2 = ts * 4
                let kRange = 4
                let jRange = 3
                let kCount = 2 * kRange + 1
                let jCount = 2 * jRange + 1
                var costs = [Int](repeating: Int.max, count: kCount * jCount)
                template2.pixels.withUnsafeBufferPointer { pa in
                    search2.pixels.withUnsafeBufferPointer { pb in
                        for k in -kRange...kRange {
                            let dy = dySign * (4 * bd + k)
                            if ty2 + dy < 0 || ty2 + dy + size2 > hh { continue }
                            for j in -jRange...jRange {
                                let dx = dxSign * (4 * be + j)
                                if tx2 + dx < 0 || tx2 + dx + size2 > hw { continue }
                                costs[(k + kRange) * jCount + (j + jRange)] =
                                    Self.sad(pa, hw, pb, hw, tx: tx2, ty: ty2, tw: size2, th: size2,
                                             dx: dx, dy: dy, step: 2)
                            }
                        }
                    }
                }
                var bestIndex = -1
                var total = 0.0
                var valid = 0
                for i in costs.indices where costs[i] != Int.max {
                    total += Double(costs[i])
                    valid += 1
                    if bestIndex < 0 || costs[i] < costs[bestIndex] { bestIndex = i }
                }
                guard bestIndex >= 0, valid >= 9 else { continue }
                let bestCost = Double(costs[bestIndex])
                let meanCost = total / Double(valid)
                let quality = meanCost > 0 ? max(0, min(1, (meanCost - bestCost) / meanCost)) : 0
                let bk = bestIndex / jCount - kRange
                let bj = bestIndex % jCount - jRange
                func cost(_ k: Int, _ j: Int) -> Double? {
                    guard abs(k) <= kRange, abs(j) <= jRange else { return nil }
                    let c = costs[(k + kRange) * jCount + (j + jRange)]
                    return c == Int.max ? nil : Double(c)
                }
                func subpixel(_ minus: Double?, _ center: Double, _ plus: Double?) -> Double {
                    guard let m = minus, let p = plus else { return 0 }
                    let denominator = m - 2 * center + p
                    guard denominator > 0 else { return 0 }
                    return max(-0.5, min(0.5, 0.5 * (m - p) / denominator))
                }
                let along = Double(4 * bd + bk) + subpixel(cost(bk - 1, bj), bestCost, cost(bk + 1, bj))
                let acrossShift = Double(4 * be + bj) + subpixel(cost(bk, bj - 1), bestCost, cost(bk, bj + 1))
                result[row * cols + col] = TileShift(along: along * 2, across: acrossShift * 2, quality: quality)
            }
        }
        return result
    }

    /// Sum of absolute differences between a template in `a` and the same-size block in `b` shifted by (dx, dy).
    private static func sad(_ a: UnsafeBufferPointer<UInt8>, _ aw: Int,
                            _ b: UnsafeBufferPointer<UInt8>, _ bw: Int,
                            tx: Int, ty: Int, tw: Int, th: Int, dx: Int, dy: Int, step: Int) -> Int {
        var total = 0
        var y = 0
        while y < th {
            let ra = (ty + y) * aw + tx
            let rb = (ty + y + dy) * bw + tx + dx
            var x = 0
            while x < tw {
                let d = Int(a[ra + x]) - Int(b[rb + x])
                total += d < 0 ? -d : d
                x += step
            }
            y += step
        }
        return total
    }

    // MARK: - Image pyramid

    /// Half-resolution 8-bit luma from an 8-bit or 10-bit 4:2:0 bi-planar camera buffer.
    static func halfLevel(from buffer: CVPixelBuffer, rows: Range<Int>? = nil) -> Level? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let eightBit = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        guard eightBit || tenBit, CVPixelBufferIsPlanar(buffer) else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let planeBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let fullHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let rowRange = (rows ?? 0..<fullHeight).clamped(to: 0..<fullHeight)
        let base = planeBase + rowRange.lowerBound * stride
        let height = rowRange.count
        let w = width / 2
        let h = height / 2
        guard w >= 64, h >= 64 else { return nil }

        var pixels = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBufferPointer { out in
            if eightBit {
                for y in 0..<h {
                    let r0 = (base + 2 * y * stride).assumingMemoryBound(to: UInt8.self)
                    let r1 = (base + (2 * y + 1) * stride).assumingMemoryBound(to: UInt8.self)
                    let o = y * w
                    for x in 0..<w {
                        let s = Int(r0[2 * x]) + Int(r0[2 * x + 1]) + Int(r1[2 * x]) + Int(r1[2 * x + 1])
                        out[o + x] = UInt8(truncatingIfNeeded: s >> 2)
                    }
                }
            } else {
                // 10-bit samples sit in the top bits of each 16-bit value.
                for y in 0..<h {
                    let r0 = (base + 2 * y * stride).assumingMemoryBound(to: UInt16.self)
                    let r1 = (base + (2 * y + 1) * stride).assumingMemoryBound(to: UInt16.self)
                    let o = y * w
                    for x in 0..<w {
                        let s = Int(r0[2 * x] >> 8) + Int(r0[2 * x + 1] >> 8)
                            + Int(r1[2 * x] >> 8) + Int(r1[2 * x + 1] >> 8)
                        out[o + x] = UInt8(truncatingIfNeeded: s >> 2)
                    }
                }
            }
        }
        return Level(width: w, height: h, pixels: pixels)
    }

    static func downsample(_ level: Level) -> Level {
        let w = level.width / 2
        let h = level.height / 2
        let sourceWidth = level.width
        var pixels = [UInt8](repeating: 0, count: w * h)
        level.pixels.withUnsafeBufferPointer { src in
            pixels.withUnsafeMutableBufferPointer { out in
                for y in 0..<h {
                    let r0 = 2 * y * sourceWidth
                    let r1 = r0 + sourceWidth
                    for x in 0..<w {
                        let s = Int(src[r0 + 2 * x]) + Int(src[r0 + 2 * x + 1])
                            + Int(src[r1 + 2 * x]) + Int(src[r1 + 2 * x + 1])
                        out[y * w + x] = UInt8(truncatingIfNeeded: s >> 2)
                    }
                }
            }
        }
        return Level(width: w, height: h, pixels: pixels)
    }
}
