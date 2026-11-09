import SwiftUI
import AVFoundation
import UIKit

/// Plays a line recording: camera footage, LiDAR depth overlay and speed at every frame.
/// Touch the picture (playing or paused) to probe the distance at that point.
struct LinePlaybackView: View {
    let folder: URL

    @State private var model: PlaybackModel?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let model {
                PlaybackContent(model: model)
            } else if let loadError {
                ContentUnavailableView("Cannot open recording", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else {
                ProgressView("Loading recording…")
            }
        }
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard model == nil else { return }
            do {
                model = try PlaybackModel(folder: folder)
            } catch {
                loadError = error.localizedDescription
            }
        }
        .onDisappear { model?.pause() }
    }
}

private struct PlaybackContent: View {
    @Bindable var model: PlaybackModel

    var body: some View {
        VStack(spacing: 6) {
            speedStrip

            // Playback picture. Nothing is drawn over it except the crosshair, so every part of it can be
            // touched; touches in the black bars around the picture snap to its nearest edge.
            GeometryReader { geometry in
                let picture = PlaybackModel.fitRect(in: geometry.size, aspect: model.displayAspect)
                ZStack {
                    Color.black
                    if model.mode != .depth {
                        PlayerLayerView(player: model.player)
                    }
                    if model.mode != .camera, let image = model.depthImage {
                        Image(decorative: image, scale: 1, orientation: .right)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .opacity(model.mode == .depth ? 1 : model.blend)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                    }
                    if let tile = model.fastestTileNow,
                       let center = ZoneGrid.displayCenter(ofTile: tile, columns: model.zoneColumns,
                                                           rows: model.zoneRows) {
                        FastestMarker()
                            .position(x: picture.minX + center.x * picture.width,
                                      y: picture.minY + center.y * picture.height)
                    }
                    if let probe = model.probe {
                        ProbeMarker()
                            .position(x: picture.minX + probe.x * picture.width,
                                      y: picture.minY + probe.y * picture.height)
                    }
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in model.moveProbe(to: value.location, in: picture) }
                                .onEnded { _ in model.finishProbe() }
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(maxHeight: .infinity)

            // Fixed height so the picture never resizes while a point is being selected.
            probePanel
                .frame(height: 142)

            if model.heightMode {
                DepthLegend(lowHeight: model.displayRange?.lowerBound, highHeight: model.displayRange?.upperBound)
            } else {
                DepthLegend(near: model.displayRange?.lowerBound, far: model.displayRange?.upperBound)
            }

            SpeedTimeline(points: model.graphPoints, duration: model.duration,
                          maxSpeed: model.speedMax ?? 1, cursor: model.currentTime)
                .frame(height: 40)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    Text(model.speedMax.map { String(format: "speed 0 – %.0f mm/s", $0) } ?? "speed")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(3)
                        .allowsHitTesting(false)
                }

            transport
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: Speed

    private var speedStrip: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(SpeedText.main(model.smoothedSpeed))
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                    Text(model.smoothedSpeed.map { String(format: "%.2f m/min", $0 * 0.06) } ?? "no texture lock")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Label("Fastest on screen " + SpeedText.short(model.fastestNow), systemImage: "hare.fill")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 4)
            if let frame = model.frame {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(String(format: "frame %ld  ·  %.0f mm away", frame.index, frame.medianDepth))
                    Text(String(format: "travel %.0f mm  ·  lock %.0f%%", frame.travel, frame.quality * 100))
                    if let tx = frame.tiltX, let ty = frame.tiltY {
                        Text(String(format: "level ↔ %+.1f°  ↕ %+.1f°", tx, ty))
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Probe

    private var probePanel: some View {
        Group {
            if model.probe != nil {
                probeContent
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "hand.tap")
                        .font(.title2)
                    Text(model.heightMode
                         ? "Touch or drag anywhere on the playback picture to read the height above the baseline at that point: current, min and max."
                         : "Touch or drag anywhere on the playback picture to read the distance at that point: current, min and max.")
                        .multilineTextAlignment(.center)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var probeContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "scope")
                Text(model.probePositionText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                Button {
                    model.clearProbe()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Remove probe")
            }
            .font(.caption)

            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Speed here")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(SpeedText.short(model.probeSpeed))
                        .font(.callout.weight(.semibold).monospacedDigit())
                    Text("fastest " + SpeedText.short(model.fastestNow))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                probeValue(title: model.heightMode ? "Current height" : "Current",
                           value: model.probeCurrent,
                           detail: model.frame.map { String(format: "frame %ld", $0.index) } ?? "")
                Button {
                    if let stats = model.probeStats { model.seek(to: stats.minimumTime) }
                } label: {
                    probeValue(title: model.heightMode ? "Min (lowest)" : "Min (closest)",
                               value: model.probeStats?.minimum,
                               detail: model.probeStats.map { String(format: "at %.2f s ▸", $0.minimumTime) } ?? "")
                }
                .buttonStyle(.plain)
                .disabled(model.probeStats == nil)
                Button {
                    if let stats = model.probeStats { model.seek(to: stats.maximumTime) }
                } label: {
                    probeValue(title: model.heightMode ? "Max (highest)" : "Max (farthest)",
                               value: model.probeStats?.maximum,
                               detail: model.probeStats.map { String(format: "at %.2f s ▸", $0.maximumTime) } ?? "")
                }
                .buttonStyle(.plain)
                .disabled(model.probeStats == nil)
            }

            if let stats = model.probeStats {
                Text(String(format: "Mean %.1f mm  ·  std dev %.2f mm  ·  range %.1f mm  ·  %ld of %ld frames",
                            stats.mean, stats.stdDev, Double(stats.maximum - stats.minimum),
                            stats.validFrames, stats.totalFrames))
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                ProbeTimeline(stats: stats, duration: model.duration, cursor: model.currentTime,
                              heightMode: model.heightMode)
                    .frame(height: 26)
            } else if model.probeComputing {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("Reading this point in every frame…")
                }
                .font(.caption2)
            } else {
                Text("Lift your finger to read min / max over the whole recording.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func probeValue(title: String, value: Float?, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Circle()
                    .fill(model.color(for: value))
                    .frame(width: 8, height: 8)
                Text(value.map { String(format: "%.1f mm", $0) } ?? "—")
                    .font(.callout.weight(.semibold).monospacedDigit())
            }
            Text(detail)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: Transport

    private var transport: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    model.togglePlay()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 44, height: 32)
                }
                .buttonStyle(.borderedProminent)

                Slider(value: Binding(get: { model.currentTime }, set: { model.seek(to: $0) }),
                       in: 0...model.duration)

                Text(String(format: "%.1f s", model.currentTime))
                    .font(.caption.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Picker("View", selection: $model.mode) {
                    ForEach(PlaybackModel.Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if model.mode == .blend {
                    Slider(value: $model.blend, in: 0...1)
                        .frame(maxWidth: 90)
                }

                Menu {
                    ForEach([0.1, 0.25, 0.5, 1.0, 2.0], id: \.self) { rate in
                        Button(String(format: "%gx", rate)) { model.setRate(Float(rate)) }
                    }
                } label: {
                    Text(String(format: "%gx", Double(model.rate)))
                        .font(.callout.monospacedDigit())
                        .frame(minWidth: 40)
                }
            }
        }
    }
}

// MARK: - Probe data

private struct SharedFloats: @unchecked Sendable {
    let base: UnsafeMutablePointer<Float>
}

struct ProbePixel: Equatable {
    var u: Int   // depth-map column (across the material)
    var v: Int   // depth-map row (along the travel)
}

/// Distance at one point of the picture across the whole recording.
struct ProbeStats {
    var minimum: Float
    var minimumTime: Double
    var maximum: Float
    var maximumTime: Double
    var mean: Double
    var stdDev: Double
    var validFrames: Int
    var totalFrames: Int
    /// (time s, distance mm), thinned for drawing.
    var series: [CGPoint]

    static func make(values: [Float], frames: [LineFrameInfo]) -> ProbeStats? {
        var minimum = Float.infinity
        var maximum = -Float.infinity
        var minimumTime = 0.0
        var maximumTime = 0.0
        var sum = 0.0
        var count = 0
        var points: [CGPoint] = []
        for (i, z) in values.enumerated() where z.isFinite && i < frames.count {
            let t = frames[i].time
            if z < minimum { minimum = z; minimumTime = t }
            if z > maximum { maximum = z; maximumTime = t }
            sum += Double(z)
            count += 1
            points.append(CGPoint(x: t, y: Double(z)))
        }
        guard count > 0 else { return nil }
        let mean = sum / Double(count)
        var squares = 0.0
        for z in values where z.isFinite {
            let d = Double(z) - mean
            squares += d * d
        }
        if points.count > 600 {
            let all = points
            let step = Int((Double(all.count) / 600).rounded(.up))
            points = stride(from: 0, to: all.count, by: step).map { all[$0] }
        }
        return ProbeStats(minimum: minimum, minimumTime: minimumTime,
                          maximum: maximum, maximumTime: maximumTime,
                          mean: mean, stdDev: (squares / Double(count)).squareRoot(),
                          validFrames: count, totalFrames: values.count, series: points)
    }
}

// MARK: - Model

@MainActor
@Observable
final class PlaybackModel {
    enum Mode: String, CaseIterable, Identifiable {
        case camera = "Camera"
        case blend = "Blend"
        case depth = "Depth"

        var id: String { rawValue }
    }

    let player: AVPlayer
    let info: LineRecordingInfo
    let duration: Double
    let graphPoints: [CGPoint]
    let speedMax: Double?
    let colorRange: ClosedRange<Float>?
    /// Values are heights above the flat-surface baseline saved with the recording.
    let heightMode: Bool
    /// Colour range of the picture on screen (low/near … high/far).
    var displayRange: ClosedRange<Float>?

    var currentTime: Double = 0
    var isPlaying = false
    var rate: Float = 1
    var mode: Mode = .blend
    var blend: Double = 0.6
    var depthImage: CGImage?
    var frame: LineFrameInfo?
    var smoothedSpeed: Double?
    /// Fastest zone on screen at the current frame (mm/s, half-second average) and its index.
    var fastestNow: Double?
    var fastestTileNow: Int?
    /// Speed of the zone under the probe at the current frame (mm/s).
    var probeSpeed: Double?
    let zoneColumns: Int
    let zoneRows: Int

    /// Probe position in the portrait picture, 0…1 (x left → right, y top → bottom).
    var probe: CGPoint?
    var probePixel: ProbePixel?
    var probeCurrent: Float?
    var probeCurrentDistance: Float?
    var probeStats: ProbeStats?
    var probeComputing = false

    @ObservationIgnored private let reader: DepthFileReader?
    @ObservationIgnored private let baseline: Baseline?
    @ObservationIgnored private let smoothed: [Double?]
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var renderedIndex = -1
    @ObservationIgnored private var currentDepth: [Float]?
    @ObservationIgnored private var probeGeneration = 0
    /// Per frame: smoothed speed of every zone.
    @ObservationIgnored private let zoneSmoothed: [[Double?]]

    /// Width ÷ height of the portrait picture (the depth map is landscape, shown rotated).
    var displayAspect: CGFloat {
        CGFloat(max(info.depthHeight, 1)) / CGFloat(max(info.depthWidth, 1))
    }

    init(folder: URL) throws {
        let data = try Data(contentsOf: folder.appendingPathComponent("Recording.json"))
        let info = try JSONDecoder.iso.decode(LineRecordingInfo.self, from: data)
        self.info = info
        reader = try? DepthFileReader(url: folder.appendingPathComponent("Depth.bin"))
        let savedBaseline = Baseline.load(from: folder)
        baseline = savedBaseline?.matches(width: info.depthWidth, height: info.depthHeight) == true ? savedBaseline : nil
        heightMode = baseline != nil
        let item = AVPlayerItem(url: folder.appendingPathComponent("Video.mov"))
        player = AVPlayer(playerItem: item)
        duration = max(info.frames.last?.time ?? 0, 0.01)

        let smooth = LineMath.smoothed(info.frames.map(\.speed), radius: 7)
        smoothed = smooth
        var points: [CGPoint] = []
        for (i, frame) in info.frames.enumerated() {
            if let v = smooth[i] { points.append(CGPoint(x: frame.time, y: v)) }
        }
        graphPoints = points

        let columns = info.tileColumns ?? 0
        let rows = info.tileRows ?? 0
        zoneColumns = columns
        zoneRows = rows
        var perFrame = [[Double?]](repeating: [], count: info.frames.count)
        if columns > 0, rows > 0 {
            let zones = columns * rows
            let series: [[Double?]] = (0..<zones).map { zone in
                info.frames.map { frame -> Double? in
                    let speeds = frame.tileSpeeds ?? []
                    return zone < speeds.count ? speeds[zone] : nil
                }
            }
            let smoothedZones = series.map { LineMath.smoothed($0, radius: 7) }
            for f in 0..<info.frames.count {
                perFrame[f] = (0..<zones).map { smoothedZones[$0][f] }
            }
        }
        zoneSmoothed = perFrame
        if let top = points.map({ Double($0.y) }).max() {
            speedMax = max(top * 1.1, 1)
        } else {
            speedMax = nil
        }

        var range: ClosedRange<Float>?
        if let statsData = try? Data(contentsOf: folder.appendingPathComponent("TopoStats.json")),
           let stats = try? JSONDecoder.iso.decode(TopoStats.self, from: statsData),
           (stats.heightMode == true) == heightMode {
            if heightMode, stats.colorNear > stats.colorFar {
                range = Float(stats.colorFar)...Float(stats.colorNear)       // low … high
            } else if !heightMode, stats.colorFar > stats.colorNear {
                range = Float(stats.colorNear)...Float(stats.colorFar)       // near … far
            }
        }
        colorRange = range

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) {
            [weak self] time in
            MainActor.assumeIsolated {
                self?.tick(time.seconds)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
            }
        }
        render(at: 0)
    }

    // MARK: Transport

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            if currentTime >= duration - 0.05 { seek(to: 0) }
            player.playImmediately(atRate: rate)
            isPlaying = true
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        if isPlaying { player.rate = newRate }
    }

    func seek(to time: Double) {
        let t = min(max(time, 0), duration)
        currentTime = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        render(at: t)
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = min(max(seconds, 0), duration)
        render(at: currentTime)
    }

    private func render(at time: Double) {
        guard !info.frames.isEmpty else { return }
        let index = LineMath.frameIndex(for: time, in: info.frames)
        guard index != renderedIndex else { return }
        renderedIndex = index
        frame = info.frames[index]
        smoothedSpeed = smoothed[index]
        let zones = index < zoneSmoothed.count ? zoneSmoothed[index] : []
        let fastest = LineCapturePipeline.fastest(zones)
        fastestNow = fastest?.speed
        fastestTileNow = fastest?.index
        guard let reader, let depth = reader.frame(index) else {
            currentDepth = nil
            updateProbeCurrent()
            return
        }
        currentDepth = depth
        if let baseline {
            let heights = baseline.heights(depth)
            heights.withUnsafeBufferPointer { buffer in
                let range = colorRange ?? DepthColors.finiteRange(buffer, step: 3)
                displayRange = range
                if let range {
                    depthImage = DepthColors.heightImage(buffer, width: reader.width, height: reader.height,
                                                         low: range.lowerBound, high: range.upperBound)
                }
            }
        } else {
            depth.withUnsafeBufferPointer { buffer in
                let range = colorRange ?? DepthColors.percentileRange(buffer, step: 3)
                displayRange = range
                if let range {
                    depthImage = DepthColors.image(millimetres: buffer, width: reader.width, height: reader.height,
                                                   near: range.lowerBound, far: range.upperBound)
                }
            }
        }
        updateProbeCurrent()
    }

    // MARK: Probe

    /// Fitted picture rectangle inside a container (same fit as the video and depth image).
    static func fitRect(in size: CGSize, aspect: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0, aspect > 0 else { return .zero }
        var width = size.width
        var height = width / aspect
        if height > size.height {
            height = size.height
            width = height * aspect
        }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    func moveProbe(to location: CGPoint, in picture: CGRect) {
        guard picture.width > 0, picture.height > 0, info.depthWidth > 0, info.depthHeight > 0 else { return }
        let x = min(max((location.x - picture.minX) / picture.width, 0), 1)
        let y = min(max((location.y - picture.minY) / picture.height, 0), 1)
        probe = CGPoint(x: x, y: y)
        // Portrait picture → landscape depth map: picture top = column 0, picture right = row 0.
        let u = min(info.depthWidth - 1, Int(Double(y) * Double(info.depthWidth)))
        let v = min(info.depthHeight - 1, Int(Double(1 - x) * Double(info.depthHeight)))
        let pixel = ProbePixel(u: u, v: v)
        if pixel != probePixel {
            probePixel = pixel
            probeStats = nil
            probeGeneration += 1
            probeComputing = false
        }
        updateProbeCurrent()
    }

    func finishProbe() {
        guard let pixel = probePixel, probeStats == nil, !probeComputing, let reader else { return }
        probeGeneration += 1
        let generation = probeGeneration
        probeComputing = true
        let frames = info.frames
        let count = min(frames.count, reader.frameCount)
        let baseDistance = baseline?.sample(u: pixel.u, v: pixel.v, radius: 1)
        if heightMode && baseDistance == nil {
            probeComputing = false
            return
        }
        Task { @MainActor [weak self] in
            let values = await Task.detached(priority: .userInitiated) { () -> [Float] in
                var out = [Float](repeating: .nan, count: count)
                guard count > 0 else { return out }
                out.withUnsafeMutableBufferPointer { buffer in
                    // Each iteration writes its own element, so sharing the pointer across threads is safe.
                    let target = SharedFloats(base: buffer.baseAddress!)
                    DispatchQueue.concurrentPerform(iterations: count) { i in
                        if let z = reader.sample(i, u: pixel.u, v: pixel.v, radius: 1) {
                            target.base[i] = baseDistance.map { $0 - z } ?? z
                        } else {
                            target.base[i] = .nan
                        }
                    }
                }
                return out
            }.value
            guard let self, generation == self.probeGeneration else { return }
            self.probeStats = ProbeStats.make(values: values, frames: frames)
            self.probeComputing = false
        }
    }

    func clearProbe() {
        probe = nil
        probePixel = nil
        probeCurrent = nil
        probeCurrentDistance = nil
        probeSpeed = nil
        probeStats = nil
        probeComputing = false
        probeGeneration += 1
    }

    private func updateProbeSpeed() {
        guard let pixel = probePixel, zoneColumns > 0, zoneRows > 0, renderedIndex >= 0,
              renderedIndex < zoneSmoothed.count else {
            probeSpeed = nil
            return
        }
        let zones = zoneSmoothed[renderedIndex]
        let tile = ZoneGrid.tile(u: pixel.u, v: pixel.v, width: info.depthWidth, height: info.depthHeight,
                                 columns: zoneColumns, rows: zoneRows)
        probeSpeed = tile < zones.count ? zones[tile] : nil
    }

    private func updateProbeCurrent() {
        updateProbeSpeed()
        guard let pixel = probePixel, let depth = currentDepth else {
            probeCurrent = nil
            probeCurrentDistance = nil
            return
        }
        let distance = DepthFileReader.sample(depth, width: info.depthWidth, height: info.depthHeight,
                                              u: pixel.u, v: pixel.v, radius: 1)
        probeCurrentDistance = distance
        if let baseline {
            if let distance, let base = baseline.sample(u: pixel.u, v: pixel.v, radius: 1) {
                probeCurrent = base - distance
            } else {
                probeCurrent = nil
            }
        } else {
            probeCurrent = distance
        }
    }

    /// Where the probe is, relative to the picture centre, in mm on the surface.
    var probePositionText: String {
        guard let pixel = probePixel else { return "" }
        guard let f = frame else { return "Point (\(pixel.u), \(pixel.v))" }
        let z = probeCurrentDistance ?? Float(f.medianDepth)
        guard z > 0, f.fx > 0, f.fy > 0 else {
            return "Point (\(pixel.u), \(pixel.v))"
        }
        // Screen right = decreasing depth rows; screen down = increasing depth columns.
        let right = -Double((Float(pixel.v) - f.cy) * z / f.fy)
        let down = Double((Float(pixel.u) - f.cx) * z / f.fx)
        return String(format: "%.0f mm %@, %.0f mm %@ of centre",
                      abs(right), right >= 0 ? "right" : "left",
                      abs(down), down >= 0 ? "below" : "above")
    }

    /// Legend colour for a distance (dark blue far … dark red near).
    func color(for value: Float?) -> Color {
        guard let value, let range = displayRange else { return .gray }
        let index = heightMode
            ? DepthColors.index(value: value, low: range.lowerBound, high: range.upperBound)
            : DepthColors.index(distance: value, near: range.lowerBound, far: range.upperBound)
        let c = DepthColors.lut[index]
        return Color(red: Double(c.0) / 255, green: Double(c.1) / 255, blue: Double(c.2) / 255)
    }
}

// MARK: - Views

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer {
            // swiftlint:disable:next force_cast
            layer as! AVPlayerLayer
        }
    }
}

/// Crosshair drawn at the probe point.
struct ProbeMarker: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Color.white).frame(width: 1.5, height: 36)
            Rectangle().fill(Color.white).frame(width: 36, height: 1.5)
            Circle().stroke(Color.black, lineWidth: 3).frame(width: 20, height: 20)
            Circle().stroke(Color.white, lineWidth: 1.5).frame(width: 20, height: 20)
        }
        .shadow(color: .black, radius: 1)
        .allowsHitTesting(false)
    }
}

/// Distance at the probe point over the whole recording (up = closer), with min/max and the playback cursor.
struct ProbeTimeline: View {
    let stats: ProbeStats
    let duration: Double
    let cursor: Double
    /// Heights: highest at the top. Distances: closest (smallest) at the top.
    var heightMode = false

    var body: some View {
        Canvas { context, size in
            guard duration > 0 else { return }
            let lo = Double(stats.minimum)
            let span = max(Double(stats.maximum) - lo, 0.5)
            let invert = heightMode
            func point(_ t: Double, _ z: Double) -> CGPoint {
                let f = min(max((z - lo) / span, 0), 1)
                return CGPoint(x: Double(size.width) * min(max(t / duration, 0), 1),
                               y: Double(size.height) * (invert ? 1 - f : f))
            }
            if stats.series.count >= 2 {
                var path = Path()
                for (i, p) in stats.series.enumerated() {
                    let q = point(Double(p.x), Double(p.y))
                    if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
                }
                context.stroke(path, with: .color(.cyan), lineWidth: 1.2)
            }
            let minPoint = point(stats.minimumTime, Double(stats.minimum))
            let maxPoint = point(stats.maximumTime, Double(stats.maximum))
            // Red = closest/highest, blue = farthest/lowest (same as the colour scale).
            context.fill(Path(ellipseIn: CGRect(x: minPoint.x - 3, y: minPoint.y - 3, width: 6, height: 6)),
                         with: .color(heightMode ? .blue : .red))
            context.fill(Path(ellipseIn: CGRect(x: maxPoint.x - 3, y: maxPoint.y - 3, width: 6, height: 6)),
                         with: .color(heightMode ? .red : .blue))
            let x = Double(size.width) * min(max(cursor / duration, 0), 1)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: Double(size.height)))
            context.stroke(line, with: .color(.primary), lineWidth: 1)
        }
    }
}

/// Speed (y) against time (x) for the whole recording, with the playback position.
struct SpeedTimeline: View {
    let points: [CGPoint]
    let duration: Double
    let maxSpeed: Double
    let cursor: Double

    var body: some View {
        Canvas { context, size in
            guard duration > 0 else { return }
            if points.count >= 2 {
                var path = Path()
                for (i, p) in points.enumerated() {
                    let fx = Double(p.x) / duration
                    let fy = 1 - min(max(Double(p.y) / maxSpeed, 0), 1)
                    let point = CGPoint(x: Double(size.width) * fx, y: Double(size.height) * fy)
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(.green), lineWidth: 1.5)
            }
            let x = Double(size.width) * min(max(cursor / duration, 0), 1)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(.primary), lineWidth: 1)
        }
    }
}
