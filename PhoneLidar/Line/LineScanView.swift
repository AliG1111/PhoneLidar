import SwiftUI
import AVFoundation
import UIKit

/// Fixed-mount recording of material passing under the phone (portrait, material moving right → left).
struct LineScanView: View {
    var onFinish: (UUID?) -> Void

    @Environment(ScanStore.self) private var store
    @State private var model = LineScanModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ZStack {
                CameraPreview(session: model.pipeline.session)
                if let image = model.depthImage {
                    Image(decorative: image, scale: 1, orientation: .right)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .opacity(model.overlayOpacity)
                        .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                speedPanel
                Spacer()
                DepthLegend(near: model.depthRange?.lowerBound, far: model.depthRange?.upperBound)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                controls
            }
            .padding()
        }
        .statusBarHidden()
        .onAppear {
            model.onSaved = { id in onFinish(id) }
            model.start()
        }
        .onDisappear { model.shutdown() }
    }

    // MARK: - Pieces

    private var topBar: some View {
        HStack {
            Button("Close") {
                model.shutdown()
                onFinish(nil)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .disabled(model.isBusy)

            Spacer()

            if model.thermal == .serious || model.thermal == .critical {
                Label("Hot", systemImage: "thermometer.high")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(model.statusText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(model.phase == .recording ? Color.red.opacity(0.8) : Color.black.opacity(0.55),
                            in: Capsule())
        }
    }

    private var speedPanel: some View {
        VStack(spacing: 4) {
            Text(SpeedText.main(model.speed))
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(SpeedText.perMinute(model.speed))
                .font(.subheadline)
                .monospacedDigit()
            HStack(spacing: 14) {
                Label(String(format: "%.0f mm", model.medianDepth), systemImage: "ruler")
                Label(String(format: "%.0f%% lock", model.quality * 100), systemImage: "scope")
                if let angle = model.angle {
                    Label(String(format: "%+.1f°", angle), systemImage: "angle")
                }
            }
            .font(.caption.monospacedDigit())
            SpeedSparkline(values: model.speedHistory)
                .frame(height: 34)
            HStack(spacing: 6) {
                Image(systemName: model.direction == .rightToLeft ? "arrow.left" : "arrow.right")
                Text("Material travel \(model.direction.label)")
            }
            .font(.caption2)
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if case .failed(let message) = model.phase {
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.yellow)
            }
            if model.phase == .ready {
                Toggle("Raw LiDAR depth (unfiltered)", isOn: Binding(
                    get: { !model.filteredDepth },
                    set: { model.setFiltered(!$0) }))
                Toggle("Short shutter (1/1000 s) for sharp texture", isOn: Binding(
                    get: { model.shortShutter },
                    set: { model.setShortShutter($0) }))
                Picker("Direction", selection: Binding(
                    get: { model.direction },
                    set: { model.setDirection($0) })) {
                    ForEach(TravelDirection.allCases) { direction in
                        Text(direction.label).tag(direction)
                    }
                }
                .pickerStyle(.segmented)
            }
            HStack(spacing: 10) {
                Image(systemName: "square.2.layers.3d")
                Slider(value: $model.overlayOpacity, in: 0...1)
                Text("Depth overlay").font(.caption)
            }
            if model.phase == .saving || model.phase == .building {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text(model.phase == .saving ? "Saving recording…" : "Building topographic map…")
                }
                .frame(height: 72)
            } else {
                recordButton
            }
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(10)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private var recordButton: some View {
        Button {
            model.toggleRecording(store: store)
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 72, height: 72)
                if model.phase == .recording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red)
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 58, height: 58)
                }
            }
        }
        .disabled(!(model.phase == .ready || model.phase == .recording))
        .accessibilityLabel(model.phase == .recording ? "Stop recording" : "Start recording")
    }
}

// MARK: - Model

@MainActor
@Observable
final class LineScanModel {
    enum Phase: Equatable {
        case starting
        case ready
        case recording
        case saving
        case building
        case failed(String)
    }

    var phase: Phase = .starting
    var speed: Double?
    var quality: Double = 0
    var medianDepth: Double = 0
    var angle: Double?
    var depthImage: CGImage?
    var depthRange: ClosedRange<Float>?
    var elapsed: Double = 0
    var recordedFrames = 0
    var filteredDepth = true
    var shortShutter = true
    var direction: TravelDirection = .rightToLeft
    var overlayOpacity: Double = 0.55
    var thermal: ProcessInfo.ThermalState = .nominal
    var speedHistory: [Double] = []

    let pipeline = LineCapturePipeline()
    @ObservationIgnored var onSaved: ((UUID) -> Void)?
    @ObservationIgnored private var folderName: String?
    @ObservationIgnored private var started = false

    var isBusy: Bool {
        phase == .recording || phase == .saving || phase == .building
    }

    var statusText: String {
        switch phase {
        case .starting: return "Starting…"
        case .ready: return "Ready"
        case .recording:
            let minutes = Int(elapsed) / 60
            let seconds = Int(elapsed) % 60
            return String(format: "● REC %ld:%02ld  ·  %ld frames", minutes, seconds, recordedFrames)
        case .saving: return "Saving…"
        case .building: return "Building map…"
        case .failed: return "Error"
        }
    }

    func start() {
        guard !started else { return }
        started = true
        pipeline.onUpdate = { [weak self] update in
            Task { @MainActor [weak self] in
                self?.apply(update)
            }
        }
        do {
            try pipeline.configure(filteredDepth: filteredDepth)
            pipeline.setDirection(direction)
            pipeline.start(shortShutter: shortShutter)
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func shutdown() {
        pipeline.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func setFiltered(_ filtered: Bool) {
        filteredDepth = filtered
        pipeline.setFiltering(filtered)
    }

    func setShortShutter(_ enabled: Bool) {
        shortShutter = enabled
        pipeline.setShortShutter(enabled)
    }

    func setDirection(_ newDirection: TravelDirection) {
        direction = newDirection
        pipeline.setDirection(newDirection)
        speedHistory.removeAll()
    }

    private func apply(_ update: LiveUpdate) {
        speed = update.speed
        quality = update.quality
        medianDepth = update.medianDepth
        angle = update.angle
        if let image = update.depthImage {
            depthImage = image
            depthRange = update.depthRange
        }
        elapsed = update.elapsed
        recordedFrames = update.recordedFrames
        if let v = update.speed {
            speedHistory.append(v)
            if speedHistory.count > 300 { speedHistory.removeFirst(speedHistory.count - 300) }
        }
        thermal = ProcessInfo.processInfo.thermalState
    }

    func toggleRecording(store: ScanStore) {
        switch phase {
        case .ready:
            do {
                let folder = try store.newFolder(kind: .line)
                folderName = folder.name
                pipeline.startRecording(folder: folder.url, filtered: filteredDepth,
                                        shortShutter: shortShutter, direction: direction)
                elapsed = 0
                recordedFrames = 0
                phase = .recording
                UIApplication.shared.isIdleTimerDisabled = true
            } catch {
                phase = .failed(error.localizedDescription)
            }
        case .recording:
            phase = .saving
            pipeline.stopRecording { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.finished(result, store: store)
                }
            }
        default:
            break
        }
    }

    private func finished(_ result: Result<LineCapturePipeline.Finished, Error>, store: ScanStore) {
        UIApplication.shared.isIdleTimerDisabled = false
        switch result {
        case .failure(let error):
            if let name = folderName {
                try? FileManager.default.removeItem(at: store.root.appendingPathComponent(name, isDirectory: true))
            }
            phase = .failed("Recording not saved: \(error.localizedDescription)")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if case .failed = self.phase { self.phase = .ready }
            }
        case .success(let output):
            phase = .building
            pipeline.stop()
            let folder = output.folder
            let info = output.info
            let name = folderName ?? folder.lastPathComponent
            Task { @MainActor in
                let built = await Task.detached(priority: .userInitiated) { () -> Result<TopoMapBuilder.Output, Error> in
                    do {
                        return .success(try TopoMapBuilder.build(folder: folder, info: info))
                    } catch {
                        return .failure(error)
                    }
                }.value
                var summary: [String]
                switch built {
                case .success(let map):
                    TopoMapRenderer.writeComposite(map: map.mapImage, stats: map.stats, direction: info.direction,
                                                   to: folder.appendingPathComponent("TopoMap.png"))
                    summary = map.summary
                case .failure(let error):
                    summary = ["Map not built: \(error.localizedDescription)"]
                }
                summary.insert(String(format: "%ld frames, %.1f s, material travel %@",
                                      info.frames.count, info.frames.last?.time ?? 0, info.direction.label), at: 0)
                let record = ScanRecord(id: UUID(),
                                        kind: .line,
                                        name: "Line " + Date().formatted(date: .abbreviated, time: .shortened),
                                        created: Date(),
                                        folderName: name,
                                        primaryModel: nil,
                                        summary: summary)
                do {
                    try store.save(record)
                    onSaved?(record.id)
                } catch {
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Views

/// Live camera picture in portrait.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // swiftlint:disable:next force_cast
            layer as! AVCaptureVideoPreviewLayer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let connection = previewLayer.connection,
               connection.isVideoRotationAngleSupported(90),
               connection.videoRotationAngle != 90 {
                connection.videoRotationAngle = 90
            }
        }
    }
}

/// Small line graph of recent speed readings.
struct SpeedSparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            guard values.count >= 2, let lo = values.min(), let hi = values.max() else { return }
            let span = max(hi - lo, 1)
            var path = Path()
            for (i, v) in values.enumerated() {
                let point = CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                                    y: size.height * CGFloat(1 - (v - lo) / span))
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(.green), lineWidth: 1.5)
        }
    }
}
