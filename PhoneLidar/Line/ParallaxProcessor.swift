import Foundation
import simd

/// One measured point of a camera-parallax map: its camera-frame position at the first view (mm) and where the
/// first view saw it.
struct ParallaxReading: Sendable {
    /// Index in Recording.json of the first view.
    var frame: Int
    /// Recorded travel of that frame, mm.
    var travel: Double
    /// Camera-frame point at the first view, mm (x across, y along, z = distance along the optical axis).
    var point: SIMD3<Double>
    /// Depth pixel of the point in the first view's depth map.
    var depthU: Int
    var depthV: Int
}

/// Tunables of the parallax measurement (design §15.3–§15.5).
struct ParallaxSettings: Sendable {
    /// Matched patch, full-resolution pixels (even).
    var patch = 16
    /// Spacing of the patches across the picture and of the template rows along it, pixels (even).
    var acrossStep = 8
    var rowStep = 8
    /// Template rows per stored frame at most.
    var maxRows = 16
    /// Travel between the two views, as a share of the picture length along the travel.
    var baselineFraction = 1.0 / 3.0
    /// A stored frame without a partner after this many frames is dropped (belt stopped or reversed).
    var maxPendingFrames = 600
    /// Fewest matched patches for a frame pair's LiDAR scale.
    var minimumPatchesForScale = 12
    /// Half-width (frame pairs) of the scale median.
    var halfWindow = 15
}

/// Measures parallax heights frame by frame (design §15): stores template bands from the frames as the material
/// advances, matches each band in the frame where its material has moved about a third of the picture, triangulates
/// with the known travel direction and scales the result to the LiDAR. Feed frames in order with `add`, then call
/// `finish`. Not thread-safe; one instance per build.
final class ParallaxProcessor {
    struct FrameInput {
        var index: Int
        var travel: Double
        var medianDepth: Double
        var camera: ParallaxCamera
    }

    struct Counters: Sendable {
        var framesSeen = 0
        var templatesStored = 0
        var pairs = 0
        var pairsWithScale = 0
        var patchesTried = 0
        var patchesMatched = 0
        var pendingDropped = 0
        var readings = 0
    }

    private struct TemplatePatch {
        var x: Int
        var y: Int
        var zLidar: Double
        var ray: SIMD3<Double>
        var depthU: Int
        var depthV: Int
    }

    private struct Pending {
        var index: Int
        var travel: Double
        var medianDepth: Double
        var camera: ParallaxCamera
        var full: LumaPlane
        var half: LumaPlane
        var patches: [TemplatePatch]
    }

    private struct MatchedPatch {
        var ray: SIMD3<Double>
        var depthPerTravel: Double
        var depthU: Int
        var depthV: Int
    }

    private struct PairResult {
        var frame: Int
        var travel: Double
        var travelDelta: Double
        var patches: [MatchedPatch]
    }

    let settings: ParallaxSettings
    let width: Int
    let height: Int
    let sign: Int
    let normal: SIMD3<Double>
    let depthWidth: Int
    let depthHeight: Int
    private(set) var acrossPerAlong: Double
    private(set) var counters = Counters()
    private let matcher: PatchMatcher
    /// Depth frame (mm, depthWidth × depthHeight) of a recording frame.
    private let depthFrame: (Int) -> [Float]?
    private var pending: [Pending] = []
    private var lastStoredTravel: Double?
    private var smoother: ScaleSmoother
    private var results: [PairResult] = []
    /// Index (in `smoother.ratios`) of `results.first`.
    private var firstResult = 0
    private var yawUpdates = 0

    init(settings: ParallaxSettings = ParallaxSettings(), width: Int, height: Int, sign: Int,
         normal: SIMD3<Double>, acrossPerAlong: Double, depthWidth: Int, depthHeight: Int,
         depthFrame: @escaping (Int) -> [Float]?) {
        self.settings = settings
        self.width = width
        self.height = height
        self.sign = sign >= 0 ? 1 : -1
        self.normal = normal
        self.acrossPerAlong = acrossPerAlong
        self.depthWidth = depthWidth
        self.depthHeight = depthHeight
        self.depthFrame = depthFrame
        self.smoother = ScaleSmoother(halfWindow: settings.halfWindow)
        var m = PatchMatcher()
        m.patch = settings.patch
        self.matcher = m
    }

    /// Travel direction in camera coordinates with the current across drift.
    var travelDirection: SIMD3<Double> {
        ParallaxGeometry.travelDirection(normal: normal, acrossPerAlong: acrossPerAlong, sign: sign)
    }

    /// Baseline between the views, pixels along the travel.
    var baselinePixels: Double { settings.baselineFraction * Double(height) }

    /// Median LiDAR scale ratio so far (scale ÷ recorded travel).
    var medianRatio: Double? { smoother.overall }

    /// Processes one video frame (luma plane in buffer orientation, `width` × `height`). Returns the readings of
    /// frame pairs whose scale window is complete.
    func add(_ input: FrameInput, luma: UnsafeBufferPointer<UInt8>, bytesPerRow: Int) -> [ParallaxReading] {
        counters.framesSeen += 1
        guard input.camera.isValid, input.medianDepth > 0, input.travel.isFinite else { return [] }
        // Drop frames that waited too long for a partner (belt stopped or reversed).
        let before = pending.count
        pending.removeAll { input.index - $0.index > settings.maxPendingFrames }
        counters.pendingDropped += before - pending.count

        // Pairs completed by this frame.
        let ready = pending.prefix { entry in
            let moved = (input.travel - entry.travel) * entry.camera.fy / entry.medianDepth
            return moved >= baselinePixels
        }
        if !ready.isEmpty {
            let full = LumaPlane(copying: luma, width: width, height: height, bytesPerRow: bytesPerRow,
                                 rows: 0..<height)
            let half = full.halved()
            for entry in ready {
                matchPair(entry, frame: input, full: full, half: half)
            }
            pending.removeFirst(ready.count)
        }

        storeTemplateIfNeeded(input, luma: luma, bytesPerRow: bytesPerRow)
        return settledReadings(final: false)
    }

    /// Readings of every pair still waiting for its scale window (call once after the last frame).
    func finish() -> [ParallaxReading] {
        pending.removeAll()
        return settledReadings(final: true)
    }

    // MARK: Templates

    private func storeTemplateIfNeeded(_ input: FrameInput, luma: UnsafeBufferPointer<UInt8>, bytesPerRow: Int) {
        let camera = input.camera
        let advance: Double
        if let last = lastStoredTravel {
            let moved = input.travel - last
            // Belt running backwards (jog, jam clearing): store nothing, start again from here when it runs forward.
            guard moved >= 0 else {
                lastStoredTravel = input.travel
                return
            }
            advance = moved * camera.fy / input.medianDepth
            guard advance >= Double(settings.rowStep) else { return }      // no new material yet
        } else {
            advance = Double(settings.rowStep)
        }
        let rows = min(settings.maxRows, max(1, Int((advance / Double(settings.rowStep)).rounded(.up))))
        // Template band: half a baseline upstream of the principal row; rows step downstream over the new material.
        let half = settings.patch / 2
        let first = Self.even(camera.cy - Double(sign) * baselinePixels / 2)
        let rowYs = (0..<rows).map { first + sign * $0 * settings.rowStep }
        guard let lo = rowYs.min(), let hi = rowYs.max(), lo - half >= 0, hi + half <= height else {
            lastStoredTravel = input.travel
            return
        }
        guard let depth = depthFrame(input.index), depth.count >= depthWidth * depthHeight else {
            lastStoredTravel = input.travel
            return
        }
        let stripLo = max(0, Self.even(Double(lo - half - 2)) - 2)
        let stripHi = min(height, hi + half + 4)
        let full = LumaPlane(copying: luma, width: width, height: height, bytesPerRow: bytesPerRow,
                             rows: stripLo..<stripHi)
        let halfPlane = full.halved()
        let margin = half + 2 * 4 + 2
        var patches: [TemplatePatch] = []
        patches.reserveCapacity(rows * (width / settings.acrossStep))
        let su = Double(depthWidth) / Double(width)
        let sv = Double(depthHeight) / Double(height)
        for y in rowYs {
            var x = Self.even(Double(margin))
            while x <= width - margin {
                let u = Int(Double(x) * su)
                let v = Int(Double(y) * sv)
                if let z = DepthFileReader.sample(depth, width: depthWidth, height: depthHeight, u: u, v: v, radius: 1),
                   z > 0, z.isFinite {
                    patches.append(TemplatePatch(x: x, y: y, zLidar: Double(z), ray: camera.ray(x: Double(x), y: Double(y)),
                                                 depthU: u, depthV: v))
                }
                x += settings.acrossStep
            }
        }
        lastStoredTravel = input.travel
        guard !patches.isEmpty else { return }
        pending.append(Pending(index: input.index, travel: input.travel, medianDepth: input.medianDepth,
                               camera: camera, full: full, half: halfPlane, patches: patches))
        counters.templatesStored += 1
    }

    // MARK: Matching

    /// Scale ratio used to predict where a patch lands: the median of the last ratios (1 before any).
    private var predictionRatio: Double {
        let recent = smoother.ratios.suffix(settings.halfWindow).compactMap { $0 }
        return HeightMath.median(recent) ?? 1
    }

    private func matchPair(_ entry: Pending, frame: FrameInput, full: LumaPlane, half: LumaPlane) {
        counters.pairs += 1
        let delta = frame.travel - entry.travel
        guard delta > 0 else {
            appendResult(PairResult(frame: entry.index, travel: entry.travel, travelDelta: delta, patches: []),
                         ratio: nil)
            return
        }
        let settled = smoother.ratios.compactMap { $0 }.count >= 3
        let ratio = predictionRatio
        let u = travelDirection
        let camera2 = frame.camera
        let count = entry.patches.count
        counters.patchesTried += count
        var found = [MatchedPatch?](repeating: nil, count: count)
        var residuals = [Double](repeating: .nan, count: count)
        let acrossRadius = yawUpdates >= 3 ? 2 : 3
        let matcher = self.matcher
        found.withUnsafeMutableBufferPointer { foundBuf in
            residuals.withUnsafeMutableBufferPointer { resBuf in
                guard let foundBase = foundBuf.baseAddress, let resBase = resBuf.baseAddress else { return }
                let outFound = ParallaxSlots(base: foundBase)
                let outResidual = ParallaxSlots(base: resBase)
                full.pixels.withUnsafeBufferPointer { fullBuf in
                    half.pixels.withUnsafeBufferPointer { halfBuf in
                        DispatchQueue.concurrentPerform(iterations: count) { i in
                            let p = entry.patches[i]
                            let start = p.ray * p.zLidar
                            let moved = start + u * (ratio * delta)
                            guard let predicted = camera2.project(moved) else { return }
                            let along = abs(predicted.y - Double(p.y))
                            let spread = settled ? 0.04 * along + 6 : 0.08 * along + 8
                            let alongRadius = max(4, Int((spread / 2).rounded(.up)))
                            guard let m = matcher.match(
                                templateFull: entry.full, templateHalf: entry.half, tx: p.x, ty: p.y,
                                searchFull: fullBuf, fullWidth: full.width, fullHeight: full.height,
                                fullOriginY: full.originY,
                                searchHalf: halfBuf, halfWidth: half.width, halfHeight: half.height,
                                halfOriginY: half.originY,
                                px: predicted.x, py: predicted.y, alongRadius: alongRadius,
                                acrossRadius: acrossRadius) else { return }
                            let ray2 = camera2.ray(x: m.x, y: m.y)
                            guard let g = ParallaxGeometry.depthPerTravel(p.ray, ray2, travel: u) else { return }
                            outFound.base[i] = MatchedPatch(ray: p.ray, depthPerTravel: g, depthU: p.depthU,
                                                            depthV: p.depthV)
                            let dy = abs(m.y - Double(p.y))
                            if dy > 1 { outResidual.base[i] = (m.x - predicted.x) / dy }
                        }
                    }
                }
            }
        }
        var matched: [MatchedPatch] = []
        var scales: [Double] = []
        for (i, m) in found.enumerated() {
            guard let m else { continue }
            matched.append(m)
            scales.append(entry.patches[i].zLidar / m.depthPerTravel)
        }
        counters.patchesMatched += matched.count
        var pairRatio: Double?
        if scales.count >= settings.minimumPatchesForScale, let s = HeightMath.median(scales) {
            pairRatio = s / delta
            counters.pairsWithScale += 1
        }
        // Across drift: move the travel direction toward where the patches were found (half the median residual).
        let r = residuals.filter(\.isFinite)
        if r.count >= settings.minimumPatchesForScale, let shift = HeightMath.median(r) {
            acrossPerAlong = max(-0.5, min(0.5, acrossPerAlong + 0.5 * shift))
            yawUpdates += 1
        }
        appendResult(PairResult(frame: entry.index, travel: entry.travel, travelDelta: delta, patches: matched),
                     ratio: pairRatio)
    }

    private func appendResult(_ result: PairResult, ratio: Double?) {
        results.append(result)
        smoother.append(ratio)
    }

    /// Readings of the pairs whose scale window is complete (all of them when `final`).
    private func settledReadings(final: Bool) -> [ParallaxReading] {
        var out: [ParallaxReading] = []
        while let result = results.first, final || smoother.isSettled(firstResult) {
            let index = firstResult
            results.removeFirst()
            firstResult += 1
            guard result.travelDelta > 0, !result.patches.isEmpty,
                  let ratio = smoother.smoothed(at: index) ?? smoother.overall else { continue }
            let scale = ratio * result.travelDelta
            for p in result.patches {
                let z = scale * p.depthPerTravel
                guard z.isFinite, z > 0 else { continue }
                out.append(ParallaxReading(frame: result.frame, travel: result.travel, point: p.ray * z,
                                           depthU: p.depthU, depthV: p.depthV))
            }
        }
        counters.readings += out.count
        return out
    }

    /// Nearest even integer (half-resolution planes need even centres).
    static func even(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return 2 * Int((value / 2).rounded())
    }
}
