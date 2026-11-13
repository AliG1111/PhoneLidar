import SwiftUI
import AVFoundation
import Charts
import UIKit

/// Laser line scan: a fixed phone above the belt, a line laser across it, strand-level heights from the main camera
/// (design §14). Portrait, material travelling right → left by default.
struct LaserScanView: View {
    var onFinish: (UUID?) -> Void

    @Environment(ScanStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = LaserScanModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geometry in
                let picture = PlaybackModel.fitRect(in: geometry.size, aspect: CGFloat(model.pictureAspect))
                ZStack {
                    CameraPreview(session: model.pipeline.session)
                        .id(model.pipelineID)
                    LaserLineOverlay(live: model.live, baseline: model.displayBaseline, walls: model.displayWalls,
                                     picture: picture)
                        .allowsHitTesting(false)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .ignoresSafeArea()

            VStack(spacing: 8) {
                topBar
                ForEach(model.banners, id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                }
                readouts
                if !model.profilePoints.isEmpty {
                    LaserProfileChart(points: model.profilePoints)
                        .frame(height: 110)
                        .padding(6)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                }
                Spacer()
                controls
            }
            .padding()
        }
        .statusBarHidden()
        .onAppear {
            model.onSaved = { id in onFinish(id) }
            model.start(store: store)
        }
        .onDisappear { model.shutdown() }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
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
            if model.thermal != .normal {
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

    private var readouts: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(SpeedText.main(model.live?.speed))
                    .font(.title3.monospacedDigit().weight(.semibold))
                Spacer()
                Text(String(format: "%.0f %% of line found", model.live?.detectedPercent ?? 0))
                    .font(.caption.monospacedDigit())
            }
            HStack {
                Text(model.heightText)
                Spacer()
                Text(model.cameraText)
            }
            .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if let notice = model.notice {
                Text(notice)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.yellow)
            }
            if model.phase == .ready {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        calibrationPanel
                        Divider().overlay(Color.white.opacity(0.4))
                        settingsPanel
                    }
                    .foregroundStyle(.white)
                    .tint(.green)
                }
                .frame(maxHeight: 300)
            }
            if model.phase == .saving || model.phase == .building {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text(model.phase == .saving ? "Saving recording…" : "Building topographic map…")
                        .foregroundStyle(.white)
                }
            }
            recordButton
        }
        .padding(10)
        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
    }

    private var calibrationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calibration").font(.headline)
            HStack {
                Text("Camera height")
                TextField("mm", text: $model.cameraHeightText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Text("mm")
                Button("Set") { model.applyCameraHeight() }
                    .buttonStyle(.bordered)
                    .disabled(model.calibrating || !model.cameraHeightPending)
                Spacer()
                if model.lidarAvailable {
                    Button("LiDAR") { model.measureCameraHeight() }
                        .buttonStyle(.bordered)
                        .disabled(model.calibrating)
                }
            }
            Picker("Method", selection: $model.calibrationMethod) {
                Text("Empty belt").tag(LaserCalibration.Method.emptyBelt)
                Text("Side walls").tag(LaserCalibration.Method.sideWalls)
            }
            .pickerStyle(.segmented)
            .disabled(model.calibrating)
            if model.calibrationMethod == .sideWalls {
                wallControls
            } else {
                emptyBeltControls
            }
            ForEach(model.calibrationLines, id: \.self) { line in
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
            if model.calibration != nil {
                Button("Clear calibration", role: .destructive) { model.clearCalibration() }
                    .font(.caption)
                    .disabled(model.calibrating)
            }
        }
    }

    private var emptyBeltControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.calibrateBaseline()
            } label: {
                Label(model.calibration == nil ? "Calibrate baseline on the empty belt" : "Recalibrate baseline",
                      systemImage: "line.horizontal.3.decrease")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.calibrating || model.format == nil)
            HStack {
                Text("Shim")
                TextField("mm", text: $model.shimText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text("mm")
                Spacer()
                Button("Measure shim") { model.measureShim() }
                    .buttonStyle(.bordered)
                    .disabled(model.calibrating || model.calibration == nil)
            }
            HStack {
                Text("or angle")
                TextField("°", text: $model.angleText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                laserSidePicker
                Button("Use") { model.useAngle() }
                    .buttonStyle(.bordered)
                    .disabled(model.calibrating || model.calibration == nil)
            }
        }
    }

    /// Side walls (design §14.9): wall-top height, laser angle from a digital gauge, camera tilt from the phone.
    private var wallControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Wall top above belt")
                TextField("mm", text: $model.wallHeightText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Text("mm")
            }
            HStack {
                Text("Laser angle")
                TextField("°", text: $model.angleText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                Text("° from vertical")
                laserSidePicker
            }
            HStack {
                Text(model.tiltAlong.map { String(format: "Camera tilt along travel %+.2f°", $0) }
                     ?? "Camera tilt: no sensor reading")
                    .font(.caption.monospacedDigit())
                Spacer()
                Button(model.levelZeroed ? "Re-zero" : "Zero here") { model.zeroLevel() }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .disabled(model.calibrating)
            }
            Button {
                model.calibrateOnWalls()
            } label: {
                Label("Calibrate on the side walls", systemImage: "rectangle.split.3x1")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.calibrating || model.format == nil)
            if model.calibration?.isSideWalls == true {
                Toggle("Wall re-zero every frame", isOn: Binding(
                    get: { model.calibration?.wallTracking != false },
                    set: { model.setWallTracking($0) }))
                    .disabled(model.calibrating)
            }
        }
    }

    private var laserSidePicker: some View {
        Picker("Side", selection: $model.laserSide) {
            ForEach(LaserSide.allCases) { side in
                Text(side == .left ? "Left" : "Right").tag(side)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 110)
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings").font(.headline)
            Picker("Frame rate", selection: Binding(get: { model.frameRate }, set: { model.setFrameRate($0) })) {
                ForEach(LaserCapturePipeline.frameRates, id: \.self) { rate in
                    Text(String(format: "%.0f fps", rate)).tag(rate)
                }
            }
            .pickerStyle(.segmented)
            Picker("Shutter", selection: Binding(get: { model.shutterLimit }, set: { model.setShutter($0) })) {
                ForEach([1.0 / 1000, 1.0 / 2000, 1.0 / 4000], id: \.self) { limit in
                    Text(String(format: "1/%.0f s", 1 / limit)).tag(limit)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Exposure")
                Slider(value: Binding(get: { model.exposureBias }, set: { model.setExposureBias($0) }), in: -3...1)
                Text(String(format: "%+.1f EV", model.exposureBias)).font(.caption.monospacedDigit())
            }
            Stepper(String(format: "Max height above belt %.0f mm", model.maxHeight),
                    value: Binding(get: { model.maxHeight }, set: { model.setMaxHeight($0) }), in: 10...300, step: 10)
            Picker("Direction", selection: Binding(get: { model.direction }, set: { model.setDirection($0) })) {
                ForEach(TravelDirection.allCases) { direction in
                    Text(direction.label).tag(direction)
                }
            }
            .pickerStyle(.segmented)
            Picker("Map", selection: $model.mapMethod) {
                ForEach(MapMethod.allCases) { method in
                    Text(method == .averaged ? "Map: averaged" : "Map: single reading").tag(method)
                }
            }
            .pickerStyle(.segmented)
        }
        .disabled(model.calibrating)
    }

    private var recordButton: some View {
        Button {
            model.toggleRecording()
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 70, height: 70)
                if model.phase == .recording || model.phase == .arming {
                    RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30)
                } else {
                    Circle().fill(model.canRecord ? .red : .gray).frame(width: 56, height: 56)
                }
            }
        }
        .disabled(!(model.phase == .recording || model.phase == .arming || model.canRecord))
        .accessibilityLabel(model.phase == .recording ? "Stop recording" : "Start recording")
    }
}

/// Detected laser line (green) and calibrated baseline (yellow) drawn over the portrait picture.
/// Buffer (u, v) → portrait (x = 1 − v/H, y = u/W), the same mapping as the camera preview.
struct LaserLineOverlay: View {
    let live: LaserLiveUpdate?
    let baseline: (columns: LaserColumns, rows: [Float])?
    /// Wall-top points of a side-wall calibration (orange).
    let walls: [(u: Int, v: Float)]
    let picture: CGRect

    var body: some View {
        Canvas { context, _ in
            guard let live, live.videoWidth > 0, live.videoHeight > 0 else { return }
            let w = Double(live.videoWidth)
            let h = Double(live.videoHeight)
            func point(u: Int, v: Float) -> CGPoint {
                CGPoint(x: picture.minX + (1 - Double(v) / h) * picture.width,
                        y: picture.minY + Double(u) / w * picture.height)
            }
            if let baseline {
                var path = Path()
                for (k, v) in baseline.rows.enumerated() where v.isFinite {
                    path.addEllipse(in: CGRect(origin: point(u: baseline.columns.u(k), v: v), size: CGSize(width: 2, height: 2)))
                }
                context.fill(path, with: .color(.yellow.opacity(0.8)))
            }
            if !walls.isEmpty {
                var wallPath = Path()
                for p in walls where p.v.isFinite {
                    wallPath.addEllipse(in: CGRect(origin: point(u: p.u, v: p.v), size: CGSize(width: 4, height: 4)))
                }
                context.fill(wallPath, with: .color(.orange))
            }
            var path = Path()
            for (k, v) in live.lineRows.enumerated() where v.isFinite {
                path.addEllipse(in: CGRect(origin: point(u: live.displayColumns.u(k), v: v),
                                           size: CGSize(width: 3, height: 3)))
            }
            context.fill(path, with: .color(.green))
        }
    }
}

/// Live across-width height profile on the laser line.
struct LaserProfileChart: View {
    let points: [LaserProfilePoint]

    var body: some View {
        Chart(points) { p in
            LineMark(x: .value("Across (mm)", p.across), y: .value("Height (mm)", p.height))
                .interpolationMethod(.linear)
        }
        .chartXAxisLabel { Text("Across (mm)").foregroundStyle(.white) }
        .chartYAxisLabel { Text("Height (mm)").foregroundStyle(.white) }
        .foregroundStyle(.green)
    }
}

struct LaserProfilePoint: Identifiable {
    var across: Double
    var height: Double
    var id: Double { across }
}
