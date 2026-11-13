import SwiftUI
import SceneKit
import UIKit

/// Drives the real-time topographic replay: advances the replay clock at the chosen speed every screen refresh,
/// rebuilds the visible part of the 3D strip and keeps the profiles and statistics up to date.
@MainActor
@Observable
final class TopoReplayModel {
    enum Mode: String, CaseIterable, Identifiable {
        case threeD = "3D"
        case map = "Map"

        var id: String { rawValue }
    }

    struct TimeTick: Identifiable {
        var id: Int
        /// 0…1 across the window (0 = oldest end, 1 = newest).
        var position: Double
        var label: String
    }

    nonisolated static let speedPresets: [Double] = [0.1, 0.25, 0.5, 1, 2, 4, 8, 16]
    nonisolated static let defaultShear = 0.36
    /// Zoom limits (pinch and slider). Below 1 the strip still fits when it is turned with its length upright.
    nonisolated static let zoomRange: ClosedRange<Double> = 0.2...8
    nonisolated static let defaultLengthFactor = 2.0

    let folder: URL
    let title: String
    let created: Date?
    let source: TopoReplaySource
    let sceneContent: TopoReplayScene
    let defaultTarget: Double
    let defaultTolerance: Double
    /// Stepper increment for the target and tolerance, mm.
    let valueStep: Double

    // Transport (`time` is the displayed clock, refreshed up to 20 times a second while playing).
    var time: Double = 0
    var isPlaying = false
    var speed: Double = 1

    // Display settings.
    var mode: Mode = .threeD
    var smooth = true
    var showPlanes = true
    /// 3D camera orientation: any, no limits (FR-RPL-06).
    var orientation = ReplayOrientation.standard
    var shear = TopoReplayModel.defaultShear
    var zoom = 1.0
    /// Height of the value range (base → top) as a fraction of the strip width.
    var heightScale = 0.8
    /// Window length as a multiple of the strip width.
    var lengthFactor = TopoReplayModel.defaultLengthFactor
    var target: Double
    var tolerance: Double

    // Readouts.
    var frameIndex = 0
    var currentSpeed: Double?
    /// Heights across the newest line (top of the recording screen first), mm, NaN = no data.
    var newestProfile: [Float] = []
    /// Position of each profile value across the strip, 0 = top of the recording screen, 1 = bottom.
    var acrossFractions: [Double] = []
    /// Heights across the material averaged over the last second of replay.
    var averageProfile: [Float] = []
    /// Mean height of each visible column: x = 0…1 across the window, y = mm.
    var alongPoints: [CGPoint] = []
    var timeTicks: [TimeTick] = []
    var newestMean: Double?
    var windowMean: Double?
    var windowStdDev: Double?
    var windowMin: Double?
    var windowMax: Double?
    var inTolerancePercent: Double?

    @ObservationIgnored weak var scnView: SCNView?
    /// Width ÷ height of the 3D view.
    @ObservationIgnored var viewAspect: Double = 2
    @ObservationIgnored private var playhead: Double = 0
    @ObservationIgnored private var grid: TopoDisplayGrid?
    /// Display factor of the grid being built in the background.
    @ObservationIgnored private var buildingFactor: Int?
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval?
    @ObservationIgnored private var lastLayout: TopoReplayScene.Layout?
    @ObservationIgnored private var lastCamera: TopoReplayScene.CameraSettings?
    @ObservationIgnored private var lastStrip: StripKey?
    @ObservationIgnored private var lastReadout: CFTimeInterval = 0
    @ObservationIgnored private var readoutDue = true

    private struct StripKey: Equatable {
        var jLo: Int
        var jHi: Int
        var smooth: Bool
        var factor: Int
    }

    /// `grid` is the display grid for the default window (built off the main thread by the caller).
    init(folder: URL, title: String, created: Date?, source: TopoReplaySource, grid: TopoDisplayGrid?) {
        self.folder = folder
        self.title = title
        self.created = created
        self.source = source
        self.grid = grid
        sceneContent = TopoReplayScene()
        let tol = max(ReplayNumbers.nice(source.robustStdDev), 0.05)
        let step = ReplayNumbers.nice(tol / 5)
        valueStep = step
        defaultTolerance = tol
        defaultTarget = (source.median / step).rounded() * step
        target = defaultTarget
        tolerance = tol
    }

    var heightMode: Bool { source.heightMode }
    var duration: Double { source.duration }
    var frameCount: Int { source.frameTimes.count }
    var stripLengthMM: Double { source.widthMM * lengthFactor }
    /// Colour scale ends: target ± 2 tolerances (blue … red).
    var colorLow: Double { target - 2 * tolerance }
    var colorHigh: Double { target + 2 * tolerance }
    var valueName: String { heightMode ? "Height above baseline" : "Relative height (+ = closer to camera)" }

    // MARK: Clock

    func start() {
        guard displayLink == nil else { return }
        lastTimestamp = nil
        displayLink = DisplayLinkProxy.makeLink { [weak self] link in
            guard let self else { return false }
            self.tick(link)
            return true
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        isPlaying = false
        lastTimestamp = nil
    }

    private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if isPlaying, let last = lastTimestamp {
            let dt = min(max(now - last, 0), 0.1)
            var t = playhead + dt * speed
            if t >= duration {
                t = duration
                isPlaying = false
                readoutDue = true
            }
            playhead = t
        }
        lastTimestamp = now
        render(now: now)
    }

    // MARK: Transport

    func togglePlay() {
        if isPlaying {
            isPlaying = false
        } else {
            if playhead >= duration - 1e-3 { playhead = 0 }
            lastTimestamp = nil
            isPlaying = true
        }
        readoutDue = true
    }

    func restart() {
        playhead = 0
        time = 0
        readoutDue = true
    }

    func seek(to t: Double) {
        playhead = min(max(t, 0), duration)
        time = playhead
        readoutDue = true
    }

    /// One recorded frame forward or back (pauses). Past the last frame it moves in 1/30 s steps.
    func step(_ direction: Int) {
        isPlaying = false
        let times = source.frameTimes
        if playhead > source.recordingDuration + 1e-6 || (direction > 0 && playhead >= source.recordingDuration) {
            seek(to: playhead + Double(direction) / 30)
            return
        }
        let index = source.frameIndex(at: playhead)
        var next = index + direction
        if direction < 0, playhead - times[index] > 1e-6 { next = index }
        if next >= times.count {
            seek(to: playhead + 1.0 / 30)
        } else {
            seek(to: times[max(0, next)])
        }
    }

    func setSpeed(_ value: Double) {
        speed = min(max(value, 0.05), 20)
    }

    func resetTargetAndTolerance() {
        target = defaultTarget
        tolerance = defaultTolerance
    }

    func resetView() {
        orientation = .standard
        shear = Self.defaultShear
        zoom = 1
    }

    // MARK: Rendering

    /// Block size (cells) that keeps the window within about 260 blocks along and 90 across.
    nonisolated static func displayFactor(source: TopoReplaySource, lengthMM: Double) -> Int {
        let columnsInWindow = lengthMM / max(source.cell, 0.1)
        let factor = max(columnsInWindow / 260, Double(source.rows) / 90)
        guard factor.isFinite else { return 1 }
        return max(1, Int(min(factor, 10_000).rounded(.up)))
    }

    /// Builds the display grid for a new block size in the background and swaps it in when ready. Changes made
    /// while a build runs (e.g. dragging the window-length slider) are coalesced: when it finishes, only the
    /// block size wanted at that moment is built next. The current grid stays on screen meanwhile.
    private func requestGrid(factor: Int) {
        guard buildingFactor == nil else { return }
        buildingFactor = factor
        let source = self.source
        Task { @MainActor [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                TopoDisplayGrid.make(source: source, factor: factor)
            }.value
            guard let self else { return }
            self.buildingFactor = nil
            self.grid = built
            self.lastStrip = nil
            self.readoutDue = true
            let wanted = Self.displayFactor(source: self.source, lengthMM: self.stripLengthMM)
            if wanted != built.factor { self.requestGrid(factor: wanted) }
        }
    }

    private func render(now: CFTimeInterval, forceReadout: Bool = false) {
        if isPlaying { readoutDue = true }
        let lengthMM = stripLengthMM
        let factor = Self.displayFactor(source: source, lengthMM: lengthMM)
        if grid?.factor != factor { requestGrid(factor: factor) }
        guard let grid else { return }

        let widthM = Float(grid.widthMM / 1000)
        let tol = max(tolerance, 1e-3)
        let layout = TopoReplayScene.Layout(
            length: Float(lengthMM / 1000), width: widthM, height: widthM * Float(heightScale),
            base: Float(target - 4 * tol), top: Float(target + 3 * tol),
            colorLow: Float(target - 2 * tol), colorHigh: Float(target + 2 * tol),
            lowerTolerance: Float(target - tol), upperTolerance: Float(target + tol),
            flat: mode == .map, planes: showPlanes, acrossStart: Float(source.acrossStart))
        if layout != lastLayout {
            sceneContent.apply(layout)
            lastLayout = layout
            lastStrip = nil
            lastCamera = nil
            readoutDue = true
        }
        let camera = TopoReplayScene.CameraSettings(orientation: orientation, shear: shear, zoom: zoom,
                                                    aspect: viewAspect)
        if camera != lastCamera {
            sceneContent.applyCamera(camera)
            lastCamera = camera
        }

        // Window: newest complete line at the right edge, `lengthMM` of older material to its left. Only blocks
        // whose whole length is complete are shown (the newest one may sit up to one block left of the edge).
        let newest = source.revealPosition(at: playhead)
        let windowStart = newest - lengthMM
        let jHi = grid.newestCompleteColumn(newest: newest)
        let startColumn = ((windowStart - grid.pStart) / grid.cellMM - 0.5).rounded(.up)
        let jLo = startColumn.isFinite ? Int(min(max(startColumn, 0), Double(grid.columns))) : 0
        if jHi - jLo >= 1 {
            let offset = Float((grid.p(ofColumn: jLo) - windowStart) / 1000)
            let key = StripKey(jLo: jLo, jHi: jHi, smooth: smooth, factor: grid.factor)
            if key != lastStrip {
                sceneContent.setStrip(values: grid.window(jLo: jLo, jHi: jHi, smooth: smooth), rows: grid.rows,
                                      columns: jHi - jLo + 1, rowCenters: grid.rowCenterMM,
                                      blockLength: Float(grid.cellMM / 1000), offset: offset)
                lastStrip = key
                readoutDue = true
            } else {
                sceneContent.moveStrip(offset: offset)
            }
        } else if lastStrip != nil || readoutDue {
            sceneContent.setStrip(values: [], rows: 0, columns: 0, rowCenters: [], blockLength: 0, offset: 0)
            lastStrip = nil
            readoutDue = true
        }

        let interval = isPlaying && !forceReadout ? 0.05 : 0
        if (readoutDue || forceReadout) && now - lastReadout >= interval {
            updateReadouts(grid: grid, jLo: jLo, jHi: jHi, windowStart: windowStart, lengthMM: lengthMM)
            lastReadout = now
            readoutDue = false
        }
    }

    private func updateReadouts(grid: TopoDisplayGrid, jLo: Int, jHi: Int, windowStart: Double, lengthMM: Double) {
        time = playhead
        frameIndex = source.frameIndex(at: playhead)
        if playhead <= source.recordingDuration {
            currentSpeed = frameIndex < source.speeds.count ? source.speeds[frameIndex] : nil
        } else {
            currentSpeed = source.runOutSpeed > 0 ? source.runOutSpeed : nil
        }

        guard jHi >= 0, jHi >= jLo, jHi < grid.columns else {
            newestProfile = []
            averageProfile = []
            alongPoints = []
            timeTicks = []
            newestMean = nil
            windowMean = nil
            windowStdDev = nil
            windowMin = nil
            windowMax = nil
            inTolerancePercent = nil
            return
        }
        // Measured blocks only: filled gaps are for the surface, not for statistics or profiles.
        let values = grid.observed
        let rows = grid.rows
        let columns = grid.columns
        if grid.widthMM > 0 {
            let fractions = grid.rowCenterMM.map { $0 / grid.widthMM }
            if fractions != acrossFractions { acrossFractions = fractions }
        }

        var newest = [Float](repeating: .nan, count: rows)
        var newestSum = 0.0
        var newestN = 0
        for r in 0..<rows {
            let v = values[r * columns + jHi]
            newest[r] = v
            if v.isFinite {
                newestSum += Double(v)
                newestN += 1
            }
        }
        newestProfile = newest
        newestMean = newestN > 0 ? newestSum / Double(newestN) : nil

        let older = source.revealPosition(at: max(0, playhead - 1))
        let jAverage = min(max(Int(ceil((older - grid.pStart) / grid.cellMM - 0.5)), jLo), jHi)
        var average = [Float](repeating: .nan, count: rows)
        for r in 0..<rows {
            var sum: Float = 0
            var n = 0
            for j in jAverage...jHi {
                let v = values[r * columns + j]
                if v.isFinite {
                    sum += v
                    n += 1
                }
            }
            if n > 0 { average[r] = sum / Float(n) }
        }
        averageProfile = average

        var sum = 0.0
        var squares = 0.0
        var count = 0
        var inside = 0
        var lo = Double.infinity
        var hi = -Double.infinity
        let low = target - tolerance
        let high = target + tolerance
        for r in 0..<rows {
            let base = r * columns
            for j in jLo...jHi {
                let v = values[base + j]
                guard v.isFinite else { continue }
                let d = Double(v)
                sum += d
                squares += d * d
                count += 1
                if d >= low && d <= high { inside += 1 }
                lo = min(lo, d)
                hi = max(hi, d)
            }
        }
        if count > 0 {
            let mean = sum / Double(count)
            windowMean = mean
            windowStdDev = max(squares / Double(count) - mean * mean, 0).squareRoot()
            windowMin = lo
            windowMax = hi
            inTolerancePercent = 100 * Double(inside) / Double(count)
        } else {
            windowMean = nil
            windowStdDev = nil
            windowMin = nil
            windowMax = nil
            inTolerancePercent = nil
        }

        var points: [CGPoint] = []
        points.reserveCapacity(jHi - jLo + 1)
        for j in jLo...jHi {
            let m = grid.columnMean[j]
            if m.isFinite {
                points.append(CGPoint(x: (grid.p(ofColumn: j) - windowStart) / lengthMM, y: Double(m)))
            }
        }
        alongPoints = points

        var ticks: [TimeTick] = []
        for (n, f) in [0.0, 0.25, 0.5, 0.75, 1.0].enumerated() {
            let p = windowStart + f * lengthMM
            let j = Int(((p - grid.pStart) / grid.cellMM - 0.5).rounded())
            guard j >= jLo, j <= jHi else { continue }
            ticks.append(TimeTick(id: n, position: f, label: String(format: "%.1f s", grid.revealTime[j])))
        }
        timeTicks = ticks
    }

    // MARK: Image

    /// Saves the current view with a title and colour bar as a PNG in the scan folder.
    func saveImage() throws -> URL {
        guard let view = scnView else { throw ReplayImageError.noView }
        // Bring the header readouts up to the playhead so the text, the picture and the file name agree.
        render(now: CACurrentMediaTime(), forceReadout: true)
        let shot = view.snapshot()
        let width = max(shot.size.width, 900)
        let header: CGFloat = 64
        let footer: CGFloat = 76
        let format = UIGraphicsImageRendererFormat()
        format.scale = shot.scale
        format.opaque = true
        let size = CGSize(width: width, height: header + shot.size.height + footer)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let titleText = "\(title) — topographic replay (\(valueName.lowercased()))"
        let line2 = timeText + "   " + statsText
        let target = self.target
        let tolerance = self.tolerance
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let bold: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 17),
                                                        .foregroundColor: UIColor.black]
            let body: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: UIColor.darkGray
            ]
            (titleText as NSString).draw(at: CGPoint(x: 14, y: 10), withAttributes: bold)
            (line2 as NSString).draw(at: CGPoint(x: 14, y: 36), withAttributes: body)
            shot.draw(at: CGPoint(x: (width - shot.size.width) / 2, y: header))
            let barY = header + shot.size.height + 12
            let barWidth = width - 28
            let steps = 200
            for i in 0..<steps {
                let c = ReplayPalette.rgb(Float(i) / Float(steps - 1))
                UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1).setFill()
                context.fill(CGRect(x: 14 + barWidth * CGFloat(i) / CGFloat(steps), y: barY,
                                    width: barWidth / CGFloat(steps) + 1, height: 16))
            }
            let digits = ReplayNumbers.decimals(for: self.valueStep)
            for k in 0...4 {
                let value = target + Double(k - 2) * tolerance
                let text = ReplayNumbers.text(value, decimals: digits) as NSString
                let textSize = text.size(withAttributes: body)
                let x = 14 + barWidth * CGFloat(k) / 4 - textSize.width * CGFloat(k) / 4
                text.draw(at: CGPoint(x: x, y: barY + 20), withAttributes: body)
            }
            (colorBarCaption as NSString).draw(at: CGPoint(x: 14, y: barY + 38), withAttributes: body)
        }
        let url = folder.appendingPathComponent(String(format: "TopoReplay_%07.2fs.png", playhead))
        guard let data = image.pngData() else { throw ReplayImageError.encodeFailed }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ReplayImageError.writeFailed(error.localizedDescription)
        }
        return url
    }

    // MARK: Text

    var timeText: String {
        var parts = [String(format: "t %.2f s of %.2f s", time, duration)]
        parts.append("frame \(min(frameIndex + 1, frameCount)) of \(frameCount)")
        if time > source.recordingDuration + 1e-6 {
            parts.append("run-out after the last frame")
        }
        parts.append(currentSpeed.map { String(format: "speed %.0f mm/s (%.2f m/min)", $0, $0 * 0.06) }
                     ?? "speed —")
        return parts.joined(separator: "  ·  ")
    }

    var statsText: String {
        let digits = max(1, ReplayNumbers.decimals(for: valueStep))
        func f(_ v: Double?) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "—" }
        var parts = ["Newest line avg " + f(newestMean) + " mm"]
        if let m = newestMean {
            parts[0] += String(format: " (%+.\(digits)f vs target)", m - target)
        }
        parts.append("on screen avg " + f(windowMean) + " mm, std dev " + f(windowStdDev) + " mm")
        parts.append("min " + f(windowMin) + " / max " + f(windowMax) + " mm")
        parts.append(inTolerancePercent.map { String(format: "%.0f%% within ±tolerance", $0) } ?? "")
        return parts.filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    var colorBarCaption: String {
        let digits = ReplayNumbers.decimals(for: valueStep)
        return valueName + " (mm): green = target " + ReplayNumbers.text(target, decimals: digits)
            + " ±" + ReplayNumbers.text(tolerance, decimals: digits) + " mm, blue = lower, red = higher"
    }
}

/// Why "Save image" could not produce a file; shown to the user in an alert.
enum ReplayImageError: LocalizedError {
    case noView
    case encodeFailed
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noView: return "The replay view is not ready yet. Try again in a moment."
        case .encodeFailed: return "The image could not be created."
        case .writeFailed(let reason): return "The image could not be saved: \(reason)"
        }
    }
}
