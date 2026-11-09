import SwiftUI
import CoreGraphics

/// Distance colour scale: dark blue = farthest from the camera, dark red = closest.
enum DepthColors {
    /// Jet palette. t = 0 → dark blue, t = 1 → dark red.
    static func rgb(_ t: Float) -> (UInt8, UInt8, UInt8) {
        let c = min(max(t, 0), 1)
        func channel(_ v: Float) -> UInt8 { UInt8(min(max(v, 0), 1) * 255) }
        return (channel(1.5 - abs(4 * c - 3)),
                channel(1.5 - abs(4 * c - 2)),
                channel(1.5 - abs(4 * c - 1)))
    }

    static let lut: [(UInt8, UInt8, UInt8)] = (0..<256).map { rgb(Float($0) / 255) }

    /// Gradient stops for legends, far (left) → near (right).
    static let stops: [Color] = (0...8).map { i in
        let c = rgb(Float(i) / 8)
        return Color(red: Double(c.0) / 255, green: Double(c.1) / 255, blue: Double(c.2) / 255)
    }

    /// Colour index for a distance: far → 0 (dark blue), near → 255 (dark red).
    @inline(__always)
    static func index(distance z: Float, near: Float, far: Float) -> Int {
        let span = max(far - near, 0.001)
        let t = (far - z) / span
        return Int(min(max(t, 0), 1) * 255)
    }

    /// Colour index for a height (or any value where bigger = closer): low → 0 (dark blue), high → 255 (dark red).
    @inline(__always)
    static func index(value v: Float, low: Float, high: Float) -> Int {
        let span = max(high - low, 0.001)
        let t = (v - low) / span
        return Int(min(max(t, 0), 1) * 255)
    }

    /// RGBA image of heights (mm above the baseline). NaN = transparent. Low = dark blue, high = dark red.
    static func heightImage(_ values: UnsafeBufferPointer<Float>, width: Int, height: Int,
                            low: Float, high: Float) -> CGImage? {
        guard width > 0, height > 0, values.count >= width * height else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBufferPointer { out in
            for i in 0..<(width * height) {
                let v = values[i]
                guard v.isFinite else { continue }
                let c = lut[index(value: v, low: low, high: high)]
                out[i * 4] = c.0
                out[i * 4 + 1] = c.1
                out[i * 4 + 2] = c.2
                out[i * 4 + 3] = 255
            }
        }
        return makeImage(rgba: pixels, width: width, height: height)
    }

    /// Percentile range of the finite values (heights can be zero or negative).
    static func finiteRange(_ values: UnsafeBufferPointer<Float>, low: Double = 0.02, high: Double = 0.98,
                            step: Int = 1) -> ClosedRange<Float>? {
        var samples: [Float] = []
        samples.reserveCapacity(values.count / max(step, 1) + 1)
        var i = 0
        while i < values.count {
            let v = values[i]
            if v.isFinite { samples.append(v) }
            i += max(step, 1)
        }
        guard samples.count >= 16 else { return nil }
        samples.sort()
        let lo = samples[Int(Double(samples.count - 1) * low)]
        let hi = samples[Int(Double(samples.count - 1) * high)]
        return hi > lo + 0.5 ? lo...hi : lo...(lo + 0.5)
    }

    /// RGBA image of a distance grid in millimetres. Cells ≤ 0 are transparent.
    static func image(millimetres values: UnsafeBufferPointer<Float>, width: Int, height: Int,
                      near: Float, far: Float) -> CGImage? {
        guard width > 0, height > 0, values.count >= width * height else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBufferPointer { out in
            for i in 0..<(width * height) {
                let z = values[i]
                guard z > 0, z.isFinite else { continue }
                let c = lut[index(distance: z, near: near, far: far)]
                out[i * 4] = c.0
                out[i * 4 + 1] = c.1
                out[i * 4 + 2] = c.2
                out[i * 4 + 3] = 255
            }
        }
        return makeImage(rgba: pixels, width: width, height: height)
    }

    static func makeImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Robust colour range (low/high percentiles of valid distances).
    static func percentileRange(_ values: UnsafeBufferPointer<Float>, low: Double = 0.02, high: Double = 0.98,
                                step: Int = 1) -> ClosedRange<Float>? {
        var samples: [Float] = []
        samples.reserveCapacity(values.count / max(step, 1) + 1)
        var i = 0
        while i < values.count {
            let z = values[i]
            if z > 0 && z.isFinite { samples.append(z) }
            i += max(step, 1)
        }
        guard samples.count >= 16 else { return nil }
        samples.sort()
        let lo = samples[Int(Double(samples.count - 1) * low)]
        let hi = samples[Int(Double(samples.count - 1) * high)]
        return hi > lo ? lo...hi : lo...(lo + 1)
    }
}

/// Horizontal colour legend: dark blue on the left, dark red on the right.
/// Distance mode: far → near. Height mode: low → high above the baseline.
struct DepthLegend: View {
    let blueValue: Float?
    let redValue: Float?
    let blueLabel: String
    let redLabel: String
    let decimals: Int

    init(near: Float?, far: Float?) {
        blueValue = far
        redValue = near
        blueLabel = "Far"
        redLabel = "Near"
        decimals = 0
    }

    init(lowHeight: Float?, highHeight: Float?) {
        blueValue = lowHeight
        redValue = highHeight
        blueLabel = "Low"
        redLabel = "High"
        decimals = 1
    }

    var body: some View {
        VStack(spacing: 2) {
            LinearGradient(colors: DepthColors.stops, startPoint: .leading, endPoint: .trailing)
                .frame(height: 10)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            HStack {
                Text(text(blueLabel, blueValue))
                Spacer()
                if let blue = blueValue, let red = redValue {
                    Text(String(format: "span %.\(decimals)f mm", abs(red - blue)))
                    Spacer()
                }
                Text(text(redLabel, redValue))
            }
            .font(.caption2.monospacedDigit())
        }
    }

    private func text(_ label: String, _ value: Float?) -> String {
        guard let value else { return label }
        return label + " " + String(format: "%.\(decimals)f mm", value)
    }
}
