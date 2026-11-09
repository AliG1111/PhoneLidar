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

    private var previousHalf: Level?
    private var previousEighth: Level?

    func reset() {
        previousHalf = nil
        previousEighth = nil
    }

    func process(_ buffer: CVPixelBuffer) -> TextureShift? {
        guard let half = Self.halfLevel(from: buffer) else { return nil }
        let eighth = Self.downsample(Self.downsample(half))
        defer {
            previousHalf = half
            previousEighth = eighth
        }
        guard let prevHalf = previousHalf, let prevEighth = previousEighth,
              prevHalf.width == half.width, prevHalf.height == half.height else { return nil }
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
        let forward = sign > 0 ? h8 - th - ty - 1 : ty - 1
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
        let rty = max(1, 1 - minD)
        var rth = max(24, hh / 4)
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
        return TextureShift(along: fd * 2 * Double(sign), across: fe * 2, quality: quality)
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
    static func halfLevel(from buffer: CVPixelBuffer) -> Level? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let eightBit = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        guard eightBit || tenBit, CVPixelBufferIsPlanar(buffer) else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
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
