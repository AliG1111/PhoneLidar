import SwiftUI
import AVFoundation
import UIKit

/// Fixed-mount recording of material passing under the phone (portrait, material moving right → left).
struct LineScanView: View {
    var onFinish: (UUID?) -> Void

    @Environment(ScanStore.self) private var store
    @Environment(RemoteLink.self) private var link
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = LineScanModel()
    @State private var showRemote = false
    @State private var showReference = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geometry in
                let picture = PlaybackModel.fitRect(in: geometry.size, aspect: CGFloat(model.pictureAspect))
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
                    // Tap anywhere on the picture to read the speed there.
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { value in
                            model.selectPoint(at: value.location, in: picture)
                        })
                    if let tile = model.fastestTile, let point = model.displayPoint(ofTile: tile) {
                        FastestMarker()
                            .position(x: picture.minX + point.x * picture.width,
                                      y: picture.minY + point.y * picture.height)
                    }
                    if let point = model.selectedPoint {
                        ProbeMarker()
                            .position(x: picture.minX + point.x * picture.width,
                                      y: picture.minY + point.y * picture.height)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                RemoteStatusChip()
                if let banner = model.bannerText {
                    noticeBadge([banner], color: .orange)
                }
                if model.phase == .recording, !model.recordingWarnings.isEmpty {
                    noticeBadge(model.recordingWarnings, color: .yellow)
                }
                speedPanel
                levelPanel
                Spacer()
                Group {
                    if model.heightMode {
                        DepthLegend(lowHeight: model.depthRange?.lowerBound, highHeight: model.depthRange?.upperBound)
                    } else {
                        DepthLegend(near: model.depthRange?.lowerBound, far: model.depthRange?.upperBound)
                    }
                }
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
            // Remote control allowed: stay on this screen after a save (FR-RMT-09).
            let remoteLink = link
            model.keepOpenAfterSave = { [weak remoteLink] in remoteLink?.mode == .scanner }
            model.onRecordingStart = { [weak remoteLink] in remoteLink?.recordingStarts() }
            model.start(store: store)
            link.attachScanner(model)
        }
        .onDisappear {
            link.detachScanner(model)
            model.shutdown()
        }
        .sheet(isPresented: $showRemote) {
            RemoteScannerSheet()
                .environment(link)
        }
        .onChange(of: scenePhase) { _, newPhase in
            model.scenePhaseChanged(newPhase)
        }
    }

    /// Compact warning lines (camera / heat banner, and warnings that stay visible while recording).
    private func noticeBadge(_ lines: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(lines, id: \.self) { line in
                Label(line, systemImage: "exclamationmark.triangle.fill")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
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

            Button {
                showRemote = true
            } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title3)
                    .foregroundStyle(remoteIconColor)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Remote control")

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

    private var remoteIconColor: Color {
        guard link.mode == .scanner else { return .white }
        switch link.linkState {
        case .connected: return .green
        case .lost, .problem: return .orange
        case .off, .waiting, .connecting: return .cyan
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
                if model.heightMode, let h = model.centerHeight {
                    Label(String(format: "%+.1f mm high", h), systemImage: "arrow.up.to.line")
                }
                if let spread = model.spread {
                    Label(String(format: "σ %.1f mm", spread), systemImage: "square.grid.3x3")
                }
                Label(String(format: "%.0f%% lock", model.quality * 100), systemImage: "scope")
                if let angle = model.angle {
                    Label(String(format: "%+.1f°", angle), systemImage: "angle")
                }
            }
            .font(.caption.monospacedDigit())
            HStack(spacing: 14) {
                Label("Fastest " + SpeedText.short(model.fastestSpeed), systemImage: "hare.fill")
                    .foregroundStyle(.orange)
                if model.selectedPoint != nil {
                    Label("At point " + SpeedText.short(model.speedAtPoint), systemImage: "scope")
                    Button {
                        model.clearPoint()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel("Clear point")
                } else {
                    Text("Tap the picture for speed at a point")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .font(.callout.weight(.semibold).monospacedDigit())
            SpeedSparkline(values: model.speedHistory)
                .frame(height: 34)
            HStack(spacing: 6) {
                Image(systemName: model.direction.map { $0 == .rightToLeft ? "arrow.left" : "arrow.right" }
                      ?? "arrow.left.arrow.right")
                Text(model.directionSetting.travelText(detected: model.detectedDirection))
            }
            .font(.caption2)
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private var levelPanel: some View {
        HStack(spacing: 12) {
            BubbleLevel(x: model.levelX, y: model.levelY,
                        surfaceX: model.surfaceTiltX, surfaceY: model.surfaceTiltY)
                .frame(width: 88, height: 88)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(BubbleLevel.color(for: model.levelX, model.levelY)).frame(width: 9, height: 9)
                    Text(model.levelZeroed ? "Phone vs zero" : "Phone vs gravity")
                        .font(.caption.weight(.semibold))
                }
                Text(Self.levelText(model.levelX, model.levelY))
                    .font(.caption.monospacedDigit())
                HStack(spacing: 6) {
                    Circle().stroke(Color.orange, lineWidth: 2).frame(width: 9, height: 9)
                    Text("Phone vs surface (LiDAR)")
                        .font(.caption.weight(.semibold))
                }
                Text(Self.levelText(model.surfaceTiltX, model.surfaceTiltY))
                    .font(.caption.monospacedDigit())
                HStack(spacing: 8) {
                    Button(model.levelZeroed ? "Re-zero" : "Zero here") { model.zeroLevel() }
                    if model.levelZeroed {
                        Button("Reset") { model.resetLevel() }
                    }
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .tint(.white)
                .disabled(model.tiltX == nil)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(8)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    /// "↔ +0.3°  ↕ −0.8°  (0.9°)": ↔ = left/right edge, ↕ = top/bottom edge; + = right / top edge high.
    static func levelText(_ x: Double?, _ y: Double?) -> String {
        guard let x, let y else { return "↔ —   ↕ —" }
        return String(format: "↔ %+.1f°   ↕ %+.1f°   (%.1f°)", x, y, (x * x + y * y).squareRoot())
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if case .failed(let message) = model.phase {
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.yellow)
                if model.cameraDenied, let settings = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") { UIApplication.shared.open(settings) }
                        .buttonStyle(.borderedProminent)
                }
            }
            if model.phase == .ready, let notice = model.notice {
                Text(notice)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.yellow)
            }
            if model.phase == .ready {
                referenceRow
                // Locked while a calibration is being captured so it uses one depth setting.
                Group {
                    Toggle("Raw LiDAR depth (unfiltered)", isOn: Binding(
                        get: { !model.filteredDepth },
                        set: { model.setFiltered(!$0) }))
                    Toggle("Short shutter (1/1000 s) for sharp texture", isOn: Binding(
                        get: { model.shortShutter },
                        set: { model.setShortShutter($0) }))
                    Picker("Direction", selection: Binding(
                        get: { model.directionSetting },
                        set: { model.setDirection($0) })) {
                        ForEach(DirectionSetting.allCases) { setting in
                            Text(setting.label).tag(setting)
                        }
                    }
                    .pickerStyle(.segmented)
                    // Single frame: one reading per map cell, no averaging between frames (FR-SFM-01).
                    // Camera parallax: strand heights from the video, scaled by the LiDAR (FR-PAR-01).
                    Picker("Map", selection: Binding(
                        get: { model.mapMethod },
                        set: { model.setMapMethod($0) })) {
                        ForEach(MapMethod.allCases) { method in
                            Text(method.shortLabel).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .disabled(model.calibrating)
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

    /// Height reference: the method in use, its state, and the sheet to change it.
    private var referenceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Height: \(model.heightReference.method.label)")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Height reference…") { showReference = true }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .disabled(model.calibrating)
            }
            if model.heightReference.method == .emptyBelt {
                baselineRow
            } else {
                if let progress = model.calibrationProgress {
                    HStack(spacing: 8) {
                        ProgressView(value: progress).tint(.green)
                        Text(String(format: "Hold still — reading the wall tops %.0f%%", progress * 100))
                            .font(.caption)
                    }
                } else if model.calibrating {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("Measuring the wall tops…").font(.caption)
                    }
                }
                Text(model.referenceStatusText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(model.heightReferenceReady ? .green : .yellow)
                ForEach(model.referenceWarnings(short: false), id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                if let message = model.calibrationMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showReference) {
            HeightReferenceSheet(model: model)
        }
    }

    private var baselineRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = model.calibrationProgress {
                HStack(spacing: 8) {
                    ProgressView(value: progress).tint(.green)
                    Text(String(format: "Hold still — reading the flat surface %.0f%%", progress * 100))
                        .font(.caption)
                }
            } else if model.calibrating {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Building baseline…").font(.caption)
                }
            } else if let baseline = model.baseline {
                Label("Baseline set: showing height above the flat surface", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                Text(String(format: "%.0f mm away · flat surface %.1f mm σ (%.1f mm range) → %.2f mm σ corrected · coverage %.0f %%",
                            baseline.info.meanDistance, baseline.info.rawStdDev, baseline.info.rawRange,
                            baseline.info.correctedStdDev, baseline.info.coveragePercent))
                    .font(.caption2.monospacedDigit())
                if baseline.info.coveragePercent < Baseline.goodCoveragePercent {
                    Label(String(format: "Only %.0f %% of the view had steady LiDAR readings; the rest is estimated from a fitted plane. Clear the view and recalibrate for best accuracy.",
                                 baseline.info.coveragePercent),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                if let moved = model.baselineMovedDegrees, moved > 0.3 {
                    Label(String(format: "Phone tilt changed %.1f° since calibration — recalibrate", moved),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                if baseline.info.filteredDepth != model.filteredDepth {
                    Label("Calibrated with \(baseline.info.filteredDepth ? "filtered" : "raw") depth — recalibrate for this setting",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                HStack(spacing: 8) {
                    Button("Recalibrate") { model.calibrateBaseline() }
                    Button("Clear") { model.clearBaseline() }
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .tint(.white)
            } else {
                Text("No baseline: colours and numbers are distance from the camera.")
                    .font(.caption)
                Button {
                    model.calibrateBaseline()
                } label: {
                    Label("Calibrate baseline on the empty flat surface", systemImage: "scope")
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .tint(.green)
            }
            if let message = model.calibrationMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recordButton: some View {
        Button {
            model.toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 72, height: 72)
                if model.phase == .recording || model.phase == .arming {
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
        .disabled(!(model.phase == .ready || model.phase == .recording || model.phase == .arming) || model.calibrating)
        .accessibilityLabel(model.phase == .recording || model.phase == .arming ? "Stop recording" : "Start recording")
    }
}

// MARK: - Model

@MainActor
@Observable
final class LineScanModel {
    enum Phase: Equatable {
        case starting
        case ready
        /// Record tapped; waiting for the first frame to create the files.
        case arming
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
    /// Direction setting (default Auto) and the direction the automatic detection found (FR-DIR-01).
    var directionSetting: DirectionSetting = .auto
    var detectedDirection: TravelDirection?
    /// Counts setting changes, so a live update made under an earlier setting cannot set `detectedDirection`.
    private var directionGeneration = 0
    /// Direction in use: set by hand, or detected (nil while Auto has not seen the material move).
    var direction: TravelDirection? { directionSetting.manual ?? detectedDirection }
    /// Map built after Stop (stored in Recording.json); single frame turns raw depth on (FR-SFM-01).
    var mapMethod: MapMethod = .averaged
    var overlayOpacity: Double = 0.55
    var thermal: ProcessInfo.ThermalState = .nominal
    var speedHistory: [Double] = []
    var tileSpeeds: [Double?] = []
    var fastestSpeed: Double?
    var fastestTile: Int?
    var pictureAspect: Double = 0.75
    /// Selected point in the portrait picture (0…1, x left → right, y top → bottom).
    var selectedPoint: CGPoint?
    /// Result of the last start/stop that the user should read (stays until the next recording starts).
    var notice: String?
    /// Camera interrupted or failed (cleared when frames arrive again).
    var cameraBanner: String?
    var pressure: LinePressure = .normal
    /// Problem with the running recording that does not stop it (e.g. video encoder stopped).
    var recordingWarning: String?
    /// Camera permission is off: the screen offers a Settings button.
    var cameraDenied = false

    /// Speed of the zone under the selected point, mm/s.
    var speedAtPoint: Double? {
        guard let point = selectedPoint else { return nil }
        let index = ZoneGrid.tile(atDisplay: point)
        return index < tileSpeeds.count ? tileSpeeds[index] : nil
    }

    func selectPoint(at location: CGPoint, in picture: CGRect) {
        guard picture.width > 0, picture.height > 0 else { return }
        selectedPoint = CGPoint(x: min(max((location.x - picture.minX) / picture.width, 0), 1),
                                y: min(max((location.y - picture.minY) / picture.height, 0), 1))
    }

    func clearPoint() {
        selectedPoint = nil
    }

    func displayPoint(ofTile index: Int) -> CGPoint? {
        ZoneGrid.displayCenter(ofTile: index)
    }
    var tiltX: Double?
    var tiltY: Double?
    var surfaceTiltX: Double?
    var surfaceTiltY: Double?
    var levelZeroed = UserDefaults.standard.bool(forKey: "lineLevelZeroed")
    var levelZeroX = UserDefaults.standard.double(forKey: "lineLevelZeroX")
    var levelZeroY = UserDefaults.standard.double(forKey: "lineLevelZeroY")
    var baseline: Baseline? = Baseline.load(from: Baseline.standardFolder)
    /// Height reference (empty belt, camera height or side walls; design §16), kept in Calibration.
    var heightReference: HeightReference = HeightReference.load(from: HeightReference.standardFolder) ?? HeightReference()
    /// Which capture `calibrating` belongs to.
    var calibrationKind: CalibrationKind?
    var heightMode = false
    var centerHeight: Double?
    var spread: Double?
    var calibrating = false
    var calibrationProgress: Double?
    var calibrationMessage: String?

    enum CalibrationKind {
        case baseline
        case walls
    }

    /// How far the gravity tilt has moved since the baseline was captured (degrees).
    var baselineMovedDegrees: Double? {
        guard let info = baseline?.info, let bx = info.tiltX, let by = info.tiltY,
              let x = tiltX, let y = tiltY else { return nil }
        return ((x - bx) * (x - bx) + (y - by) * (y - by)).squareRoot()
    }

    /// Level shown on the bubble: gravity tilt minus the saved zero (if any).
    var levelX: Double? { tiltX.map { $0 - (levelZeroed ? levelZeroX : 0) } }
    var levelY: Double? { tiltY.map { $0 - (levelZeroed ? levelZeroY : 0) } }

    /// Short warnings kept on screen while recording (the full ones are in the settings panel before recording).
    var recordingWarnings: [String] {
        var warnings: [String] = referenceWarnings(short: true)
        if heightReference.method == .emptyBelt, heightMode, let baseline {
            if let moved = baselineMovedDegrees, moved > 0.3 {
                warnings.append(String(format: "Tilt changed %.1f° since baseline — recalibrate after this run", moved))
            }
            if baseline.info.filteredDepth != filteredDepth {
                warnings.append("Baseline was calibrated with \(baseline.info.filteredDepth ? "filtered" : "raw") depth")
            }
            if baseline.info.coveragePercent < Baseline.goodCoveragePercent {
                warnings.append(String(format: "Baseline coverage only %.0f %%", baseline.info.coveragePercent))
            }
        }
        if let recordingWarning { warnings.append(recordingWarning) }
        return warnings
    }

    /// Camera / heat message for the top of the screen.
    var bannerText: String? {
        if let cameraBanner { return cameraBanner }
        switch pressure {
        case .normal: return nil
        case .serious: return "Phone is hot: live overlay slowed to reduce load. Shade the phone or improve airflow."
        case .critical: return "Phone too hot: recording is stopped and cannot start until the phone cools down."
        }
    }

    let pipeline = LineCapturePipeline()
    @ObservationIgnored var onSaved: ((UUID) -> Void)?
    /// True while remote control is allowed: after a save the screen stays open and ready instead of opening the
    /// scan, so the remote phone can start the next recording (FR-RMT-09).
    @ObservationIgnored var keepOpenAfterSave: () -> Bool = { false }
    /// Called when a recording starts (button or remote), so the remote link stops sending files at once.
    @ObservationIgnored var onRecordingStart: () -> Void = {}
    @ObservationIgnored private var store: ScanStore?
    @ObservationIgnored private var recordingFolder: (name: String, url: URL)?
    @ObservationIgnored private var stopReason: String?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var started = false
    @ObservationIgnored private var closed = false

    var isBusy: Bool {
        phase == .arming || phase == .recording || phase == .saving || phase == .building
    }

    var statusText: String {
        switch phase {
        case .starting: return "Starting…"
        case .ready: return "Ready"
        case .arming: return "Starting recording…"
        case .recording:
            let minutes = Int(elapsed) / 60
            let seconds = Int(elapsed) % 60
            return String(format: "● REC %ld:%02ld  ·  %ld frames", minutes, seconds, recordedFrames)
        case .saving: return "Saving…"
        case .building: return "Building map…"
        case .failed: return "Error"
        }
    }

    func start(store: ScanStore) {
        guard !started else { return }
        started = true
        self.store = store
        // Keep the screen awake for the whole Line scan screen (mounting, levelling, calibration, recording);
        // an auto-lock would cancel the calibration. Reset in shutdown().
        UIApplication.shared.isIdleTimerDisabled = true
        pipeline.onUpdate = { [weak self] update in
            Task { @MainActor [weak self] in
                self?.apply(update)
            }
        }
        pipeline.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            openCamera()
        case .notDetermined:
            Task { @MainActor in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if granted { self.openCamera() } else { self.denyCamera() }
            }
        default:
            denyCamera()
        }
    }

    private func openCamera() {
        guard !closed else { return }
        do {
            try pipeline.configure(filteredDepth: filteredDepth)
            pipeline.setDirection(directionSetting, generation: directionGeneration)
            applyHeightReference()
            pipeline.start(shortShutter: shortShutter)
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func denyCamera() {
        cameraDenied = true
        phase = .failed("Camera access is off for Phone LiDAR. Turn it on in Settings › Privacy & Security › Camera, then reopen Line scan.")
    }

    func shutdown() {
        closed = true
        if phase == .recording || phase == .arming {
            stop(reason: "the Line scan screen was closed")
        }
        if calibrating {
            pipeline.cancelCalibration(reason: "the screen was closed")
        }
        pipeline.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Recording cannot continue in the background (the camera stops), so it is stopped and saved.
    func scenePhaseChanged(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            if calibrating {
                pipeline.cancelCalibration(reason: "the app went to the background")
            }
            if phase == .recording || phase == .arming {
                stop(reason: "the app went to the background (screen locked or another app opened)")
            }
        case .active:
            // The camera normally resumes by itself; make sure it runs if it was stopped meanwhile.
            if started, !closed, phase == .ready {
                pipeline.start(shortShutter: shortShutter)
            }
        default:
            break
        }
    }

    private func handle(_ event: LineCaptureEvent) {
        switch event {
        case .recordingStarted:
            if phase == .arming { phase = .recording }
        case .recordingStartFailed(let reason):
            guard phase == .arming else { return }
            if let folder = recordingFolder {
                try? FileManager.default.removeItem(at: folder.url)      // no frames were written
            }
            releaseRecordingFolder()
            phase = .ready
            notice = "Recording not started: \(reason)."
        case .stopRecording(let reason):
            if phase == .recording || phase == .arming { stop(reason: reason) }
        case .cameraInterrupted(let text):
            cameraBanner = "Camera paused: \(text)."
        case .cameraResumed:
            cameraBanner = nil
        case .cameraError(let text, let restarting):
            cameraBanner = restarting
                ? "Camera error: \(text). Restarting the camera; if the picture stays frozen, close and reopen Line scan."
                : "Camera error: \(text). The camera could not be restarted: close and reopen Line scan."
        case .pressure(let level):
            pressure = level
        }
    }

    /// Use the current orientation as level (e.g. phone laid flat on the floor or conveyor first).
    /// Point the mounted phone at the empty flat surface, keep it still, then call this (~3 s at 30 fps).
    func calibrateBaseline() {
        guard phase == .ready, !calibrating else { return }
        calibrating = true
        calibrationKind = .baseline
        calibrationMessage = nil
        calibrationProgress = 0
        pipeline.captureBaseline(frames: 90, filtered: filteredDepth) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.finishCalibration(result)
            }
        }
    }

    private func finishCalibration(_ outcome: Result<Baseline, Error>) {
        calibrating = false
        calibrationKind = nil
        calibrationProgress = nil
        let result: Baseline
        switch outcome {
        case .success(let built):
            result = built
        case .failure(let error):
            calibrationMessage = error.localizedDescription
            return
        }
        do {
            try result.save(to: Baseline.standardFolder)
        } catch {
            calibrationMessage = "Baseline in use but not saved: \(error.localizedDescription)"
        }
        baseline = result
        applyHeightReference()
    }

    func clearBaseline() {
        Baseline.delete(from: Baseline.standardFolder)
        baseline = nil
        calibrationMessage = nil
        applyHeightReference()
    }

    func zeroLevel() {
        guard let x = tiltX, let y = tiltY else { return }
        levelZeroX = x
        levelZeroY = y
        levelZeroed = true
        saveLevelZero()
        applyHeightReference()
    }

    func resetLevel() {
        levelZeroed = false
        levelZeroX = 0
        levelZeroY = 0
        saveLevelZero()
        applyHeightReference()
    }

    private func saveLevelZero() {
        UserDefaults.standard.set(levelZeroed, forKey: "lineLevelZeroed")
        UserDefaults.standard.set(levelZeroX, forKey: "lineLevelZeroX")
        UserDefaults.standard.set(levelZeroY, forKey: "lineLevelZeroY")
    }

    func setFiltered(_ filtered: Bool) {
        guard !calibrating else { return }
        filteredDepth = filtered
        pipeline.setFiltering(filtered)
    }

    /// Single frame needs Apple's temporal filter off, so it switches raw depth on; camera parallax needs sharp
    /// texture, so it switches the short shutter on.
    func setMapMethod(_ method: MapMethod) {
        guard !calibrating else { return }
        mapMethod = method
        if method == .singleReading && filteredDepth {
            setFiltered(false)
        }
        if method == .cameraParallax && !shortShutter {
            setShortShutter(true)
        }
    }

    func setShortShutter(_ enabled: Bool) {
        guard !calibrating else { return }
        shortShutter = enabled
        pipeline.setShortShutter(enabled)
    }

    func setDirection(_ newSetting: DirectionSetting) {
        guard !calibrating else { return }
        directionSetting = newSetting
        detectedDirection = nil
        directionGeneration += 1
        pipeline.setDirection(newSetting, generation: directionGeneration)
        speedHistory.removeAll()
    }

    private func apply(_ update: LiveUpdate) {
        if directionSetting == .auto, update.directionGeneration == directionGeneration,
           update.detectedDirection != detectedDirection {
            // A reversal: the sparkline's readings were signed for the other direction.
            if detectedDirection != nil { speedHistory.removeAll() }
            detectedDirection = update.detectedDirection
        }
        speed = update.speed
        quality = update.quality
        medianDepth = update.medianDepth
        angle = update.angle
        if let image = update.depthImage {
            depthImage = image
            depthRange = update.depthRange
        }
        if phase == .recording {
            elapsed = update.elapsed
            recordedFrames = update.recordedFrames
            recordingWarning = update.recordingWarning
        }
        if let v = update.speed {
            speedHistory.append(v)
            if speedHistory.count > 300 { speedHistory.removeFirst(speedHistory.count - 300) }
        }
        tiltX = update.tiltX
        tiltY = update.tiltY
        if update.surfaceTiltX != nil {
            surfaceTiltX = update.surfaceTiltX
            surfaceTiltY = update.surfaceTiltY
        }
        heightMode = update.heightMode
        centerHeight = update.centerHeight
        spread = update.spread
        tileSpeeds = update.tileSpeeds
        fastestSpeed = update.fastestSpeed
        fastestTile = update.fastestTile
        pictureAspect = update.pictureAspect
        if calibrating, let progress = update.calibrationProgress {
            calibrationProgress = progress
        } else if calibrating, calibrationProgress != nil, update.calibrationProgress == nil {
            calibrationProgress = nil      // capture finished; the result is being built
        }
        thermal = ProcessInfo.processInfo.thermalState
    }

    // MARK: Recording

    func toggleRecording() {
        switch phase {
        case .ready:
            startRecording()
        case .recording, .arming:
            stop(reason: nil)
        default:
            break
        }
    }

    private func startRecording() {
        guard let store, !calibrating else { return }
        notice = nil
        guard pressure != .critical else {
            notice = "Recording not started: the phone is too hot. Let it cool down (shade, airflow) and try again."
            return
        }
        if let free = LineStorage.freeBytes(at: store.root), free < LineStorage.minimumToStart {
            notice = "Not enough free storage to record: \(LineStorage.text(free)) free, at least "
                + "\(LineStorage.text(LineStorage.minimumToStart)) needed. Delete old scans or free up space on the iPhone."
            return
        }
        guard let direction else {
            notice = "Recording not started: \(DirectionSetting.notDetectedReason)."
            return
        }
        do {
            let folder = try store.newFolder(kind: .line)
            let notes = copyHeightReference(into: folder.url)
            recordingFolder = folder
            store.beginLineRecording(folder.name)      // until saved: no recovery, not listed as incomplete
            stopReason = nil
            recordingWarning = nil
            elapsed = 0
            recordedFrames = 0
            phase = .arming
            onRecordingStart()
            pipeline.startRecording(folder: folder.url, filtered: filteredDepth,
                                    shortShutter: shortShutter, direction: direction, mapMethod: mapMethod,
                                    notes: notes)
        } catch {
            notice = "Recording not started: the scan folder could not be created (\(error.localizedDescription))."
        }
    }

    /// Stops the recording and saves it. `reason` (nil = Stop tapped) completes "Recording stopped early: …".
    /// Runs inside a background task so locking the phone during the save does not lose the recording.
    private func stop(reason: String?) {
        guard phase == .recording || phase == .arming else { return }
        stopReason = reason
        phase = .saving
        beginBackgroundTask()
        // Strong capture: the save must finish even if the screen has gone.
        pipeline.stopRecording { result in
            Task { @MainActor in
                self.recordingStopped(result)
            }
        }
    }

    private func recordingStopped(_ result: LineRecordingResult?) {
        recordingWarning = nil
        guard let store, let folder = recordingFolder else {
            phase = .ready
            endBackgroundTask()
            return
        }
        guard let result, result.frameCount > 0 else {
            try? FileManager.default.removeItem(at: folder.url)      // nothing was recorded
            releaseRecordingFolder()
            phase = .ready
            notice = "Recording not saved: no frames were recorded" + (stopReason.map { " (\($0))." } ?? ".")
            endBackgroundTask()
            return
        }

        // Add the scan to the library straight away, so it is kept even if the map step is cut short.
        var summary = [LineRecordingInfo.summaryLine(frames: result.frameCount, duration: result.duration,
                                                     direction: result.direction)]
        if let stopReason { summary.append("Recording stopped early: \(stopReason).") }
        summary += result.notes
        let record = ScanRecord(id: UUID(),
                                kind: .line,
                                name: "Line " + Date().formatted(date: .abbreviated, time: .shortened),
                                created: Date(),
                                folderName: folder.name,
                                primaryModel: nil,
                                summary: summary + ["Map not built yet: open Topographic map and tap Rebuild map."])
        // G-2: if the save below fails, library recovery adds the scan later with this record's name and summary
        // (stop reason, recorder notes) instead of a generic one. Best effort: without the file recovery still
        // adds the scan, with the generic summary.
        try? LinePendingSave(name: record.name, created: record.created, summary: record.summary)
            .write(to: folder.url)
        do {
            try store.save(record)
            LinePendingSave.remove(from: folder.url)
        } catch {
            // The folder keeps its marker (and the pending save), so library recovery adds it to the list later.
            releaseRecordingFolder()
            phase = .ready
            notice = "The recording files are kept in Files › On My iPhone › Phone LiDAR › Scans › \(folder.name), "
                + "but the scan could not be added to the list (\(error.localizedDescription)). "
                + "The app tries again the next time the library opens."
            endBackgroundTask()
            return
        }
        phase = .building
        pipeline.stop()
        let url = folder.url
        Task { @MainActor in
            let built = await Task.detached(priority: .userInitiated) { await LineScanModel.buildMap(folder: url) }.value
            var updated = record
            // Z-3: frames and duration as Recording.json holds them (a failed write can drop buffered frames).
            var recordingLines = summary
            if let line = built.recordingLine { recordingLines[0] = line }
            updated.summary = recordingLines + built.summary
            do {
                try store.save(updated)
            } catch {
                // The scan stays in the library with its first summary; say so on the Home screen (Y-2: from the
                // map step's real outcome).
                let mapStep = built.mapBuilt ? "the map was built, but" : "the map was not built and"
                let text = "\(record.name): \(mapStep) the scan summary was not updated "
                    + "(\(error.localizedDescription)). Open the scan and tap Rebuild map."
                store.recoveryNotice = store.recoveryNotice.map { $0 + "\n\n" + text } ?? text
            }
            releaseRecordingFolder()
            endBackgroundTask()
            if keepOpenAfterSave(), !closed {
                // Remote control (FR-RMT-09): restart the camera and wait for the next recording.
                notice = "Saved \"\(record.name)\". Ready for the next recording."
                phase = .ready
                pipeline.start(shortShutter: shortShutter)
            } else {
                onSaved?(record.id)
            }
        }
    }

    /// Reads Recording.json back (repairing it if it was cut short) and builds the topographic map, TopoMap.png
    /// included: it is rendered here, off the main thread, and staged with the other map files (Z-5), as Rebuild map
    /// does. `recordingLine` is the summary's frames-and-duration line from the file read back (nil if unreadable);
    /// `mapBuilt` is true when the map files were written.
    nonisolated private static func buildMap(folder: URL) async
        -> (recordingLine: String?, summary: [String], mapBuilt: Bool) {
        let info: LineRecordingInfo
        let repaired: Bool
        do {
            let loaded = try LineRecordingRepair.loadInfo(folder: folder)
            info = loaded.info
            repaired = loaded.repaired
        } catch {
            return (nil,
                    ["Recording.json could not be read back (\(error.localizedDescription)): playback and map are "
                     + "not available. Free up storage; the app repairs it the next time the library opens."],
                    false)
        }
        LineRecordingRepair.clearMarker(in: folder)
        do {
            // The recording's map method (a camera-parallax recording builds from Video.mov; design §15).
            let map = try await MapRebuild.build(folder: folder, recording: .lidar(info, repaired: repaired),
                                                 method: nil)
            return (info.summaryLine, map.summary, true)
        } catch {
            let note = repaired ? [TopoMapBuilder.recordingRepairedNote] : []
            return (info.summaryLine, note + ["Map not built: \(error.localizedDescription)"], false)
        }
    }

    /// The recording folder is finished with (saved, or removed because it holds no frames).
    private func releaseRecordingFolder() {
        if let name = recordingFolder?.name {
            store?.endLineRecording(name)
        }
        recordingFolder = nil
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save line recording") { [weak self] in
            MainActor.assumeIsolated {
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

// MARK: - Remote link

extension LineScanModel: RemoteScannerTarget {
    func remoteLineStatus() -> RemoteStatus {
        var status = RemoteStatus()
        status.lineScanOpen = true
        switch phase {
        case .starting: status.phase = .starting
        case .ready: status.phase = .ready
        case .arming: status.phase = .arming
        case .recording: status.phase = .recording
        case .saving: status.phase = .saving
        case .building: status.phase = .building
        case .failed(let message):
            status.phase = .failed
            status.failure = message
        }
        status.elapsed = elapsed
        status.frames = recordedFrames
        status.speed = speed
        status.lock = quality
        status.distance = medianDepth > 0 ? medianDepth : nil
        status.heightMode = heightMode
        status.centerHeight = centerHeight
        status.baselineSaved = heightReferenceReady
        status.calibrating = calibrating
        status.levelX = levelX
        status.levelY = levelY
        status.banner = bannerText
        status.warnings = phase == .recording ? recordingWarnings : []
        status.notice = notice
        switch pressure {
        case .normal: status.heat = .normal
        case .serious: status.heat = .serious
        case .critical: status.heat = .critical
        }
        return status
    }

    /// Same path as the record button; refusals reuse the screen's own reasons. Refused once Close was tapped
    /// (the screen may still be on its way out).
    func remoteStart() -> String? {
        if let refusal = RemoteCommandRules.startRefusal(remoteLineStatus(), closing: closed) { return refusal }
        startRecording()
        return phase == .arming ? nil : (notice ?? "The recording did not start.")
    }

    func remoteStop() -> String? {
        if let refusal = RemoteCommandRules.stopRefusal(remoteLineStatus(), closing: closed) { return refusal }
        stop(reason: nil)
        return nil
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

/// Bubble level for a phone lying screen-up. The bubble moves toward the high side, like a spirit level.
/// Filled bubble = phone vs gravity (or vs the saved zero); orange ring = phone vs the surface below (LiDAR).
struct BubbleLevel: View {
    let x: Double?
    let y: Double?
    let surfaceX: Double?
    let surfaceY: Double?
    /// Degrees of tilt that reach the rim.
    var range: Double = 3

    static func color(for x: Double?, _ y: Double?) -> Color {
        guard let x, let y else { return .gray }
        let tilt = (x * x + y * y).squareRoot()
        if tilt <= 0.5 { return .green }
        if tilt <= 2 { return .yellow }
        return .red
    }

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack {
                Circle().fill(Color.black.opacity(0.35))
                Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.5)
                // Rings at the colour limits: 0.5° (green) and 2° (yellow).
                Circle().stroke(Color.green.opacity(0.9), lineWidth: 1)
                    .frame(width: ringDiameter(degrees: 0.5, size: size), height: ringDiameter(degrees: 0.5, size: size))
                Circle().stroke(Color.yellow.opacity(0.6), lineWidth: 1)
                    .frame(width: ringDiameter(degrees: 2, size: size), height: ringDiameter(degrees: 2, size: size))
                Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1, height: size)
                Rectangle().fill(Color.white.opacity(0.35)).frame(width: size, height: 1)
                if let sx = surfaceX, let sy = surfaceY {
                    Circle().stroke(Color.orange, lineWidth: 2)
                        .frame(width: 14, height: 14)
                        .position(point(sx, sy, size: size, center: center, inset: 7))
                }
                if let x, let y {
                    Circle()
                        .fill(Self.color(for: x, y))
                        .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                        .frame(width: 16, height: 16)
                        .position(point(x, y, size: size, center: center, inset: Self.bubbleInset))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Bubble level")
    }

    /// Inset of the filled bubble's centre from the rim (half its 16 pt diameter). The ring radii use the same
    /// travel as the bubble (`size / 2 - bubbleInset` per `range` degrees), so a ring marks exactly the tilt at
    /// which the bubble centre sits on it (D-3).
    private static let bubbleInset: CGFloat = 8

    /// Diameter of the ring that the bubble centre reaches at `degrees` of tilt.
    private func ringDiameter(degrees: Double, size: CGFloat) -> CGFloat {
        2 * (size / 2 - Self.bubbleInset) * CGFloat(degrees / range)
    }

    /// +x (right edge high) moves right; +y (top edge high) moves up. Clamped to the rim.
    private func point(_ x: Double, _ y: Double, size: CGFloat, center: CGPoint, inset: CGFloat) -> CGPoint {
        var nx = x / range
        var ny = y / range
        let length = (nx * nx + ny * ny).squareRoot()
        if length > 1 {
            nx /= length
            ny /= length
        }
        let radius = Double(size / 2 - inset)
        return CGPoint(x: Double(center.x) + nx * radius, y: Double(center.y) - ny * radius)
    }
}

/// Marks the fastest-moving zone on the picture.
struct FastestMarker: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.orange, lineWidth: 2.5)
                .frame(width: 30, height: 30)
            Image(systemName: "hare.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.orange)
        }
        .shadow(color: .black, radius: 1)
        .allowsHitTesting(false)
    }
}
