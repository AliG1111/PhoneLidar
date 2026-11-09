import SwiftUI
import AVFoundation
import UIKit

/// Plays a line recording: camera footage, LiDAR depth overlay and speed at every frame.
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
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
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
                }
                speedBadge
                    .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(maxHeight: .infinity)

            DepthLegend(near: model.colorRange?.lowerBound, far: model.colorRange?.upperBound)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Speed over the recording")
                    Spacer()
                    if let max = model.speedMax {
                        Text(String(format: "0 – %.0f mm/s", max))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                SpeedTimeline(points: model.graphPoints, duration: model.duration,
                              maxSpeed: model.speedMax ?? 1, cursor: model.currentTime)
                    .frame(height: 64)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
            }

            transport
        }
        .padding()
    }

    private var speedBadge: some View {
        VStack(spacing: 2) {
            Text(SpeedText.main(model.smoothedSpeed))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(SpeedText.perMinute(model.smoothedSpeed))
                .font(.caption)
                .monospacedDigit()
            if let frame = model.frame {
                Text(String(format: "frame %ld  ·  %.0f mm away  ·  travel %.0f mm  ·  lock %.0f%%",
                            frame.index, frame.medianDepth, frame.travel, frame.quality * 100))
                    .font(.caption2)
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.white)
        .padding(8)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private var transport: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    model.togglePlay()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 44, height: 36)
                }
                .buttonStyle(.borderedProminent)

                Slider(value: Binding(get: { model.currentTime }, set: { model.seek(to: $0) }),
                       in: 0...model.duration)

                Text(String(format: "%.1f s", model.currentTime))
                    .font(.caption.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
            }
            HStack(spacing: 12) {
                Picker("View", selection: $model.mode) {
                    ForEach(PlaybackModel.Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Menu {
                    ForEach([0.1, 0.25, 0.5, 1.0, 2.0], id: \.self) { rate in
                        Button(String(format: "%gx", rate)) { model.setRate(Float(rate)) }
                    }
                } label: {
                    Text(String(format: "%gx", Double(model.rate)))
                        .font(.callout.monospacedDigit())
                        .frame(minWidth: 44)
                }
            }
            if model.mode == .blend {
                HStack {
                    Image(systemName: "square.2.layers.3d")
                    Slider(value: $model.blend, in: 0...1)
                }
            }
        }
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

    var currentTime: Double = 0
    var isPlaying = false
    var rate: Float = 1
    var mode: Mode = .blend
    var blend: Double = 0.6
    var depthImage: CGImage?
    var frame: LineFrameInfo?
    var smoothedSpeed: Double?

    @ObservationIgnored private let reader: DepthFileReader?
    @ObservationIgnored private let smoothed: [Double?]
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var renderedIndex = -1

    init(folder: URL) throws {
        let data = try Data(contentsOf: folder.appendingPathComponent("Recording.json"))
        let info = try JSONDecoder.iso.decode(LineRecordingInfo.self, from: data)
        self.info = info
        reader = try? DepthFileReader(url: folder.appendingPathComponent("Depth.bin"))
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
        if let top = points.map({ Double($0.y) }).max() {
            speedMax = max(top * 1.1, 1)
        } else {
            speedMax = nil
        }

        var range: ClosedRange<Float>?
        if let statsData = try? Data(contentsOf: folder.appendingPathComponent("TopoStats.json")),
           let stats = try? JSONDecoder.iso.decode(TopoStats.self, from: statsData),
           stats.colorFar > stats.colorNear {
            range = Float(stats.colorNear)...Float(stats.colorFar)
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
        guard let reader, let depth = reader.frame(index) else { return }
        depth.withUnsafeBufferPointer { buffer in
            let range = colorRange ?? DepthColors.percentileRange(buffer, step: 3)
            if let range {
                depthImage = DepthColors.image(millimetres: buffer, width: reader.width, height: reader.height,
                                               near: range.lowerBound, far: range.upperBound)
            }
        }
    }
}

// MARK: - Views

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .black
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
