import SwiftUI
import AVFoundation
import CoreMotion
import UIKit

/// State and actions of the laser line scan screen (design §14). Main actor; the pipeline does the frame work.
@MainActor
@Observable
final class LaserScanModel {
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

    private(set) var pipeline = LaserCapturePipeline()
    /// Changes when the pipeline is replaced (frame-rate change), so the preview re-attaches.
    private(set) var pipelineID = 0
    var phase: Phase = .starting
    private(set) var format: LaserFormatInfo?
    private(set) var live: LaserLiveUpdate?
    private(set) var calibration: LaserCalibration?
    private(set) var thermal: LinePressure = .normal
    private(set) var cameraBanner: String?
    var notice: String?
    private(set) var calibrating = false
    private(set) var calibrationStep: String?

    // Settings (kept between visits).
    private(set) var frameRate: Double = 240
    private(set) var shutterLimit: Double = 1.0 / 1000
    private(set) var exposureBias: Double = 0
    private(set) var maxHeight: Double = 100
    private(set) var direction: TravelDirection = .rightToLeft
    var mapMethod: MapMethod = .singleReading
    /// Camera height being typed (applied with Set).
    var cameraHeightText = ""
    /// Camera height in use (mm) and where it came from.
    private(set) var appliedCameraHeight: Double?
    private(set) var cameraHeightSource: LaserCalibration.HeightSource = .entered
    var shimText = "10.0"
    var angleText = "45"
    var laserSide: LaserSide = .left
    /// Calibration method chosen on screen (design §14.9).
    var calibrationMethod: LaserCalibration.Method = .emptyBelt
    var wallHeightText = ""
    /// Camera tilt along the travel / across (degrees, level zero applied; + = right / top edge high).
    private(set) var tiltAlong: Double?
    private(set) var tiltAcross: Double?
    private(set) var levelZeroed = false

    @ObservationIgnored var onSaved: ((UUID) -> Void)?

    @ObservationIgnored private var store: ScanStore?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var recordingFolder: (name: String, url: URL)?
    @ObservationIgnored private var recordingRecord: ScanRecord?
    @ObservationIgnored private var recordingInfo: LaserRecordingInfo?
    @ObservationIgnored private var stopReason: String?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var probe: LidarDistanceProbe?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var levelZeroX = 0.0
    @ObservationIgnored private var levelZeroY = 0.0

    // MARK: - Derived values

    var pictureAspect: Double {
        guard let format, format.width > 0 else { return 1080.0 / 1920.0 }
        return Double(format.height) / Double(format.width)
    }

    var isBusy: Bool {
        switch phase {
        case .arming, .recording, .saving, .building: return true
        default: return calibrating
        }
    }

    var lidarAvailable: Bool { LidarDistanceProbe.isSupported }

    /// The typed camera height when valid (100–5000 mm).
    var typedCameraHeight: Double? {
        guard let value = Double(cameraHeightText.replacingOccurrences(of: ",", with: ".")),
              value >= 100, value <= 5000 else { return nil }
        return value
    }

    /// The typed value differs from the one in use (Set not tapped yet).
    var cameraHeightPending: Bool {
        guard let typed = typedCameraHeight else { return true }
        return appliedCameraHeight.map { abs($0 - typed) > 0.5 } ?? true     // text is written with %.0f
    }

    /// Calibration usable for the active format (size, columns, intrinsics and binning, M2-4).
    var activeCalibration: LaserCalibration? {
        guard let calibration, let format, calibration.matches(width: format.width, height: format.height,
                                                              columns: format.columns, fx: format.fx, fy: format.fy,
                                                              cx: format.cx, cy: format.cy, binned: format.binned)
        else { return nil }
        return calibration
    }

    var canRecord: Bool {
        phase == .ready && !calibrating && activeCalibration?.isComplete == true && thermal != .critical
            && !cameraHeightPending
    }

    var statusText: String {
        switch phase {
        case .starting: return "Starting…"
        case .ready: return calibrating ? (calibrationStep ?? "Calibrating…") : "Ready"
        case .arming: return "Starting recording…"
        case .recording:
            return String(format: "REC %.1f s · %ld", live?.recordingElapsed ?? 0, live?.recordedFrames ?? 0)
        case .saving: return "Saving…"
        case .building: return "Building map…"
        case .failed: return "Camera unavailable"
        }
    }

    var banners: [String] {
        var lines: [String] = []
        if case .failed(let text) = phase { lines.append(text) }
        if let cameraBanner { lines.append(cameraBanner) }
        if thermal == .serious { lines.append("Phone is hot: shade it or improve airflow.") }
        if thermal == .critical { lines.append("Phone too hot: recording is stopped and cannot start until it cools down.") }
        if calibration != nil, format != nil, activeCalibration == nil {
            lines.append("The calibration was made with another camera format (picture size, crop or binning at this "
                         + "frame rate). Calibrate again.")
        }
        if calibrationMethod == .sideWalls, let across = tiltAcross, abs(across) > 0.5 {
            lines.append(String(format: "Camera tilted %.1f° across the belt: level it within 0.5° (the wall "
                                + "calibration assumes no tilt across).", across))
        }
        if live?.trackingAvailable == false {
            lines.append("No room for speed tracking: move the laser line toward an edge of the picture or lower "
                         + "Max height.")
        }
        if phase == .ready, typedCameraHeight != nil, cameraHeightPending {
            lines.append("Tap Set to use the camera height you typed.")
        } else if phase == .ready, typedCameraHeight == nil {
            lines.append("Enter a camera height of 100–5000 mm (lens to belt) and tap Set.")
        }
        if let format, format.activeFrameRate + 0.5 < format.requestedFrameRate {
            lines.append(String(format: "%.0f fps is not available; using %.0f fps.", format.requestedFrameRate,
                                format.activeFrameRate))
        }
        return lines
    }

    var heightText: String {
        guard activeCalibration?.isComplete == true else { return "Height: calibrate first" }
        let median = live?.medianHeight.map { String(format: "%.2f", $0) } ?? "—"
        let maximum = live?.maxHeight.map { String(format: "%.2f", $0) } ?? "—"
        return "Height median \(median) · max \(maximum) mm"
    }

    var cameraText: String {
        guard let live else { return "" }
        let size = format.map { "\($0.width)×\($0.height)" } ?? ""
        return String(format: "%@ %.0f fps · dropped %ld", size, live.fps, live.droppedFrames)
    }

    var calibrationLines: [String] {
        guard let c = calibration else {
            return ["1. Enter the camera height (lens to belt). 2. With the belt empty and the laser on, calibrate the "
                    + "baseline. 3. Put a shim of known thickness under part of the line and tap Measure shim "
                    + "(or enter the laser angle)."]
        }
        if c.isSideWalls {
            var lines = [String(format: "Side walls: %.0f mm wall tops, %ld wall columns; focus locked",
                                c.wallHeight ?? 0, c.wallColumns?.count ?? 0)]
            lines.append(String(format: "Laser %.1f° (%@), camera tilt %+.2f°, K = %.0f px", c.laserAngle ?? 0,
                                c.laserSide == .left ? "left" : "right", c.cameraTilt ?? 0, c.scale ?? 0))
            lines.append(c.wallTracking == false ? "Wall re-zero off" : "Wall re-zero on: every frame follows the walls")
            return lines
        }
        var lines = [String(format: "Baseline: %.0f %% of the line measured, %ld columns filled; focus locked",
                            c.coverage, c.filledColumns)]
        if let scale = c.scale, let source = c.scaleSource {
            switch source {
            case .shim:
                lines.append(String(format: "Height scale from a %.1f mm shim (shift %.1f px, K = %.0f px)",
                                    c.shimThickness ?? 0, c.shimShift ?? 0, scale))
            case .angle:
                lines.append(String(format: "Height scale from a %.1f° laser angle (K = %.0f px)", c.laserAngle ?? 0,
                                    scale))
            }
        } else {
            lines.append("Height scale missing: measure a shim or enter the laser angle.")
        }
        return lines
    }

    var displayBaseline: (columns: LaserColumns, rows: [Float])? {
        guard let c = activeCalibration else { return nil }
        let step = LaserCapturePipeline.displayStride
        let columns = LaserColumns(first: c.columns.first, stride: c.columns.stride * step,
                                   count: (c.columns.count + step - 1) / step)
        return (columns, stride(from: 0, to: c.baselineRows.count, by: step).map { c.baselineRows[$0] })
    }

    var profilePoints: [LaserProfilePoint] {
        guard let live, !live.heights.isEmpty, let format, format.fx > 0 else { return [] }
        let H = activeCalibration?.cameraHeight ?? appliedCameraHeight ?? 1000
        var points: [LaserProfilePoint] = []
        for (k, h) in live.heights.enumerated() where h.isFinite {
            let u = Double(live.displayColumns.u(k))
            points.append(LaserProfilePoint(across: (u - format.cx) * (H - Double(h)) / format.fx, height: Double(h)))
        }
        return points.sorted { $0.across < $1.across }
    }

    // MARK: - Lifecycle

    func start(store: ScanStore) {
        guard !started else { return }
        started = true
        self.store = store
        loadPreferences()
        calibration = LaserCalibration.loadStandard()
        loadLevelZero()
        startMotion()
        if let c = calibration {
            calibrationMethod = c.method ?? .emptyBelt
            if let hw = c.wallHeight { wallHeightText = String(format: "%.0f", hw) }
            cameraHeightText = String(format: "%.0f", c.cameraHeight)
            appliedCameraHeight = c.cameraHeight
            cameraHeightSource = c.cameraHeightSource
            laserSide = c.laserSide
            if let t = c.shimThickness { shimText = String(format: "%.1f", t) }
            if let a = c.laserAngle { angleText = String(format: "%.1f", a) }
        }
        UIApplication.shared.isIdleTimerDisabled = true
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
        pipeline.onUpdate = { [weak self] update in
            Task { @MainActor [weak self] in self?.live = update }
        }
        pipeline.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event) }
        }
        do {
            try pipeline.configure(frameRate: frameRate)
            pushSettings()
            pipeline.setExposure(shutterLimit: shutterLimit, bias: Float(exposureBias))
            pipeline.setLens(position: calibration?.lensPosition)
            pipeline.start()
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func denyCamera() {
        phase = .failed("Camera access is off for Phone LiDAR. Turn it on in Settings › Privacy & Security › Camera, "
                        + "then reopen Laser line scan.")
    }

    func shutdown() {
        guard !closed else { return }
        closed = true
        if phase == .recording || phase == .arming { stop(reason: "the Laser line scan screen was closed") }
        pipeline.cancelCollection()
        if phase != .saving && phase != .building { pipeline.stop() }
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Level (camera tilt; its own zero, made on a level surface, unlike Line scan's conveyor zero)

    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let g = data?.gravity else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let x = LineMotionMath.gravityTilt(g.x)
                let y = LineMotionMath.gravityTilt(g.y)
                self.rawTilt = (x, y)
                self.tiltAlong = x - (self.levelZeroed ? self.levelZeroX : 0)
                self.tiltAcross = y - (self.levelZeroed ? self.levelZeroY : 0)
            }
        }
    }

    @ObservationIgnored private var rawTilt: (x: Double, y: Double)?

    private func loadLevelZero() {
        levelZeroed = defaults.bool(forKey: "laserLevelZeroed")
        levelZeroX = defaults.double(forKey: "laserLevelZeroX")
        levelZeroY = defaults.double(forKey: "laserLevelZeroY")
    }

    /// Lay the phone flat (screen up) on a level surface first (checked with a spirit level).
    func zeroLevel() {
        guard let raw = rawTilt else { return }
        levelZeroX = raw.x
        levelZeroY = raw.y
        levelZeroed = true
        defaults.set(true, forKey: "laserLevelZeroed")
        defaults.set(raw.x, forKey: "laserLevelZeroX")
        defaults.set(raw.y, forKey: "laserLevelZeroY")
    }

    func scenePhaseChanged(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            if calibrating { pipeline.cancelCollection() }
            if phase == .recording || phase == .arming {
                stop(reason: "the app went to the background (screen locked or another app opened)")
            }
        case .active:
            if started, !closed, phase == .ready { pipeline.start() }
        default:
            break
        }
    }

    private func handle(_ event: LaserCaptureEvent) {
        switch event {
        case .format(let info):
            format = info
        case .recordingStarted:
            if phase == .arming { phase = .recording }
        case .recordingStartFailed(let reason):
            guard phase == .arming else { return }
            discardRecording()
            phase = .ready
            notice = "Recording not started: \(reason)."
        case .stopRecording(let reason):
            stop(reason: reason)
        case .cameraInterrupted(let text):
            cameraBanner = "Camera paused: \(text)."
        case .cameraResumed:
            cameraBanner = nil
        case .cameraError(let text):
            cameraBanner = "Camera error: \(text)."
        case .pressure(let level):
            thermal = level
        }
    }

    // MARK: - Settings

    private func loadPreferences() {
        if let rate = defaults.object(forKey: "laserFrameRate") as? Double,
           LaserCapturePipeline.frameRates.contains(rate) { frameRate = rate }
        if let limit = defaults.object(forKey: "laserShutterLimit") as? Double, limit > 0 { shutterLimit = limit }
        exposureBias = defaults.double(forKey: "laserExposureBias")
        if let height = defaults.object(forKey: "laserMaxHeight") as? Double, height >= 10 { maxHeight = height }
        if let raw = defaults.string(forKey: "laserMapMethod"), let method = MapMethod(rawValue: raw) { mapMethod = method }
        if let raw = defaults.string(forKey: "laserDirection"), let value = TravelDirection(rawValue: raw) {
            direction = value
        }
    }

    private func savePreferences() {
        defaults.set(frameRate, forKey: "laserFrameRate")
        defaults.set(shutterLimit, forKey: "laserShutterLimit")
        defaults.set(exposureBias, forKey: "laserExposureBias")
        defaults.set(maxHeight, forKey: "laserMaxHeight")
        defaults.set(mapMethod.rawValue, forKey: "laserMapMethod")
        defaults.set(direction.rawValue, forKey: "laserDirection")
    }

    private func pushSettings() {
        pipeline.setSettings(LaserProcessingSettings(calibration: calibration, cameraHeight: appliedCameraHeight ?? 0,
                                                     maxHeight: searchHeight, direction: direction))
    }

    /// Search band height: the wall tops must stay inside it with a side-wall calibration.
    private var searchHeight: Double {
        guard let c = calibration, c.isSideWalls, let hw = c.wallHeight else { return maxHeight }
        return max(maxHeight, hw + 20)
    }

    /// A new frame rate needs a new capture session: the pipeline is replaced.
    func setFrameRate(_ rate: Double) {
        guard phase == .ready, !calibrating, rate != frameRate else { return }
        frameRate = rate
        savePreferences()
        // The old session must have stopped before the new one takes the camera.
        let old = pipeline
        pipeline = LaserCapturePipeline()
        pipelineID += 1
        format = nil
        live = nil
        phase = .starting
        old.stopAndWait {
            Task { @MainActor in self.openCamera() }
        }
    }

    func setShutter(_ limit: Double) {
        shutterLimit = limit
        savePreferences()
        pipeline.setExposure(shutterLimit: limit, bias: Float(exposureBias))
    }

    func setExposureBias(_ bias: Double) {
        exposureBias = bias
        savePreferences()
        pipeline.setExposure(shutterLimit: shutterLimit, bias: Float(bias))
    }

    func setMaxHeight(_ height: Double) {
        maxHeight = height
        savePreferences()
        pushSettings()
    }

    func setDirection(_ value: TravelDirection) {
        direction = value
        savePreferences()
        pushSettings()
    }

    /// Applies the typed camera height (Set button).
    func applyCameraHeight() {
        guard let H = typedCameraHeight else {
            notice = "Enter the camera height (lens to belt) in mm, 100–5000."
            return
        }
        setCameraHeight(H, source: .entered)
    }

    private func setCameraHeight(_ H: Double, source: LaserCalibration.HeightSource) {
        guard var c = calibration else {
            appliedCameraHeight = H
            cameraHeightSource = source
            cameraHeightText = String(format: "%.0f", H)
            pushSettings()
            return
        }
        if c.isSideWalls {
            // The wall fit depends on H: refit from the stored wall rows (same walls, K and wall height). The new
            // height is applied only when the refit works (M2T-4).
            guard var refit = LaserWalls.refit(c, cameraHeight: H) else {
                notice = "The wall calibration could not be refitted for this camera height (it must be well above the "
                    + "wall tops): the previous height stays in use. Check it, or calibrate on the side walls again."
                appliedCameraHeight = c.cameraHeight
                cameraHeightSource = c.cameraHeightSource
                cameraHeightText = String(format: "%.0f", c.cameraHeight)
                return
            }
            refit.cameraHeightSource = source
            appliedCameraHeight = H
            cameraHeightSource = source
            cameraHeightText = String(format: "%.0f", H)
            saveCalibration(refit)
            return
        }
        appliedCameraHeight = H
        cameraHeightSource = source
        cameraHeightText = String(format: "%.0f", H)
        c.cameraHeight = H
        c.cameraHeightSource = source
        // A shim scale depends on H (A = d·(H − t)/t): recompute K from the stored shim shift and its baseline row.
        if c.scaleSource == .shim, let d = c.shimShift, let t = c.shimThickness,
           let a = LaserGeometry.scaleFromShim(shift: d, thickness: t, cameraHeight: H) {
            c.scale = LaserGeometry.laserTerm(columnScale: a, baselineRow: c.shimBaselineRow ?? c.cy, cy: c.cy)
        }
        saveCalibration(c)
    }

    // MARK: - Calibration

    func measureCameraHeight() {
        guard phase == .ready, !calibrating else { return }
        calibrating = true
        calibrationStep = "Measuring height with the LiDAR…"
        let probe = LidarDistanceProbe()
        self.probe = probe
        pipeline.stopAndWait {
            probe.measure { result in
                Task { @MainActor in self.cameraHeightMeasured(result) }
            }
        }
    }

    private func cameraHeightMeasured(_ result: Result<Double, Error>) {
        probe = nil
        calibrating = false
        calibrationStep = nil
        switch result {
        case .success(let mm):
            setCameraHeight(mm, source: .lidar)
            notice = String(format: "LiDAR camera height: %.0f mm (check against a tape measure).", mm)
        case .failure(let error):
            notice = error.localizedDescription
        }
        if !closed { pipeline.start() }
    }

    func calibrateBaseline() {
        guard phase == .ready, !calibrating, let format else { return }
        guard let H = appliedCameraHeight, !cameraHeightPending else {
            notice = "Enter the camera height (lens to belt, 100–5000 mm) and tap Set first."
            return
        }
        calibrating = true
        calibrationStep = "Locking focus…"
        notice = nil
        // Full-frame search while the baseline is captured.
        pipeline.setSettings(LaserProcessingSettings(calibration: nil, cameraHeight: H, maxHeight: maxHeight,
                                                     direction: direction))
        let pipeline = self.pipeline
        pipeline.lockFocusAndWhiteBalance { lens in
            Task { @MainActor in
                self.calibrationStep = "Calibrating baseline (keep the belt empty)…"
                // 60 frames spread over about 1 s at any frame rate.
                let every = max(1, Int((format.activeFrameRate / 60).rounded()))
                pipeline.collectRows(frames: 60, every: every) { frames in
                    Task { @MainActor in self.baselineCollected(frames, format: format, cameraHeight: H, lens: lens) }
                }
            }
        }
    }

    private func baselineCollected(_ frames: [[Float]], format: LaserFormatInfo, cameraHeight H: Double, lens: Float?) {
        calibrating = false
        calibrationStep = nil
        guard !frames.isEmpty else {
            notice = "Calibration cancelled. Tap Calibrate again when the phone is steady."
            pushSettings()
            return
        }
        guard let result = LaserGeometry.baseline(frames: frames) else {
            notice = "Calibration refused: the laser line was found on less than half of the width. Check the laser "
                + "is on and across the whole view, lower the exposure or add a filter, then try again."
            pushSettings()
            return
        }
        let columns = format.columns
        // Intrinsics at the end of the capture (after the focus lock).
        let current = self.format ?? format
        var c = LaserCalibration(date: Date(), cameraHeight: H, cameraHeightSource: cameraHeightSource,
                                 scale: nil, scaleSource: nil, shimThickness: nil, shimShift: nil, laserAngle: nil,
                                 laserSide: laserSide, videoWidth: current.width, videoHeight: current.height,
                                 columns: columns, baselineRows: result.rows, coverage: result.coverage,
                                 filledColumns: result.filled, lensPosition: lens, fx: current.fx, fy: current.fy,
                                 cx: current.cx, cy: current.cy, shimBaselineRow: nil, binned: current.binned)
        // Keep an earlier scale of the same format (re-measure the shim if the laser or camera moved).
        if let old = calibration, old.matches(width: current.width, height: current.height, columns: columns,
                                              fx: current.fx, fy: current.fy, cx: current.cx, cy: current.cy,
                                              binned: current.binned) {
            c.scale = old.scale
            c.scaleSource = old.scaleSource
            c.shimThickness = old.shimThickness
            c.shimShift = old.shimShift
            c.shimBaselineRow = old.shimBaselineRow
            c.laserAngle = old.laserAngle
            c.cameraTilt = old.cameraTilt       // K contains the tilt; the effective height needs it too (M2T-2)
        }
        saveCalibration(c)
        notice = String(format: "Baseline calibrated: %.0f %% of the line measured. ", result.coverage)
            + (c.scale == nil ? "Now measure a shim." : "Re-measure the shim if the laser or camera moved.")
    }

    func measureShim() {
        guard phase == .ready, !calibrating, let c = activeCalibration else { return }
        guard !c.isSideWalls else {
            notice = "This is a side-wall calibration: calibrate the baseline on the empty belt first to use a shim."
            return
        }
        guard let t = Double(shimText.replacingOccurrences(of: ",", with: ".")), t > 0.1, t < c.cameraHeight / 2 else {
            notice = "Enter the shim thickness in mm (measured with a calliper)."
            return
        }
        calibrating = true
        calibrationStep = "Measuring the shim…"
        notice = nil
        // The band must reach the shim even before a scale exists.
        pipeline.setSettings(LaserProcessingSettings(calibration: c, cameraHeight: c.cameraHeight,
                                                     maxHeight: max(maxHeight, t * 3), direction: direction))
        pipeline.collectRows(frames: 30, every: 1) { frames in
            Task { @MainActor in self.shimCollected(frames, thickness: t) }
        }
    }

    private func shimCollected(_ frames: [[Float]], thickness t: Double) {
        calibrating = false
        calibrationStep = nil
        guard var c = activeCalibration, !frames.isEmpty else {
            notice = "Shim measurement cancelled."
            pushSettings()
            return
        }
        guard let shim = LaserGeometry.shimMeasurement(frames: frames, baseline: c.baselineRows),
              let columnScale = LaserGeometry.scaleFromShim(shift: shim.shift, thickness: t,
                                                            cameraHeight: c.cameraHeight) else {
            notice = "Shim not found: place it under the laser line (at least a tenth of the width), keep it still "
                + "and try again."
            pushSettings()
            return
        }
        // Store the laser term K; each column's scale adds its own perspective term (design §14.4).
        let k = LaserGeometry.laserTerm(columnScale: columnScale, baselineRow: shim.baselineRow, cy: c.cy)
        c.scale = k
        c.scaleSource = .shim
        c.shimThickness = t
        c.shimShift = shim.shift
        c.shimBaselineRow = shim.baselineRow
        c.laserAngle = nil
        c.laserSide = k > 0 ? .left : .right
        laserSide = c.laserSide
        saveCalibration(c)
        notice = String(format: "Height scale set: the %.1f mm shim moved the line %.1f px. Remove the shim.", t,
                        shim.shift)
    }

    func useAngle() {
        guard phase == .ready, !calibrating, var c = activeCalibration, let format else { return }
        guard !c.isSideWalls else {
            notice = "This is a side-wall calibration: change the laser angle and calibrate on the side walls again."
            return
        }
        let tilt = tiltAlong ?? 0
        guard let degrees = Double(angleText.replacingOccurrences(of: ",", with: ".")),
              let scale = LaserWalls.laserTerm(laserAngle: degrees, side: laserSide, cameraTilt: tilt,
                                               fy: format.fy) else {
            notice = "Enter the laser angle from vertical in degrees (1–80)."
            return
        }
        c.scale = scale
        c.scaleSource = .angle
        c.laserAngle = degrees
        c.cameraTilt = tilt
        c.laserSide = laserSide
        c.shimThickness = nil
        c.shimShift = nil
        c.shimBaselineRow = nil
        saveCalibration(c)
        notice = "Height scale set from the laser angle. A shim measurement is more accurate."
    }

    /// Side-wall calibration (design §14.9): no need to clear the belt. Needs the camera height (Set), the wall-top
    /// height, the laser angle from a digital gauge and its side; the camera tilt comes from the gravity sensor.
    func calibrateOnWalls() {
        guard phase == .ready, !calibrating, let format else { return }
        guard let H = appliedCameraHeight, !cameraHeightPending else {
            notice = "Enter the camera height (lens to belt, 100–5000 mm) and tap Set first."
            return
        }
        guard let hw = Double(wallHeightText.replacingOccurrences(of: ",", with: ".")), hw >= 10, hw < 0.7 * H else {
            notice = "Enter the wall-top height above the belt in mm (at least 10 mm, below 70 % of the camera height)."
            return
        }
        guard let theta = Double(angleText.replacingOccurrences(of: ",", with: ".")), theta >= 1, theta <= 80 else {
            notice = "Enter the laser angle from vertical in degrees (1–80), measured with a digital angle gauge."
            return
        }
        guard let tilt = tiltAlong else {
            notice = "The camera tilt is not available (motion sensor)."
            return
        }
        guard let k = LaserWalls.laserTerm(laserAngle: theta, side: laserSide, cameraTilt: tilt, fy: format.fy) else {
            notice = "The laser angle to the camera axis is under 1° or the camera tilt is over 10°: check both."
            return
        }
        calibrating = true
        calibrationStep = "Locking focus…"
        notice = nil
        // Full-frame search, band large enough for the walls.
        pipeline.setSettings(LaserProcessingSettings(calibration: nil, cameraHeight: H, maxHeight: max(maxHeight, hw + 20),
                                                     direction: direction))
        let pipeline = self.pipeline
        let side = laserSide
        pipeline.lockFocusAndWhiteBalance { lens in
            Task { @MainActor in
                self.calibrationStep = "Finding the side walls…"
                let every = max(1, Int((format.activeFrameRate / 60).rounded()))
                pipeline.collectRows(frames: 60, every: every) { frames in
                    Task { @MainActor in
                        self.wallsCollected(frames, cameraHeight: H, wallHeight: hw, angle: theta, side: side,
                                            tilt: tilt, laserTerm: k, lens: lens)
                    }
                }
            }
        }
    }

    private func wallsCollected(_ frames: [[Float]], cameraHeight H: Double, wallHeight hw: Double, angle: Double,
                                side: LaserSide, tilt: Double, laserTerm k: Double, lens: Float?) {
        calibrating = false
        calibrationStep = nil
        guard !frames.isEmpty, let current = format else {
            notice = "Calibration cancelled. Tap Calibrate again when the phone is steady."
            pushSettings()
            return
        }
        let columns = current.columns
        // A raised point moves with the sign of A = K + (v₀ − c_y), not of K alone (line far from the centre row).
        let lineRow = LaserGeometry.median(frames.flatMap { $0 }) ?? Float(current.cy)
        let a = k + (Double(lineRow) - current.cy)
        guard a.sign == k.sign, abs(a) >= 1 else {
            notice = "The laser line is too far from the picture centre for this laser angle (raised points would move "
                + "the other way). Move the line toward the middle of the picture or use a larger laser angle."
            pushSettings()
            return
        }
        guard let detection = LaserWalls.detect(frames: frames, raisedSign: a > 0 ? 1 : -1) else {
            notice = "Side walls not found: the laser line must cross both wall tops, and both must be in the picture. "
                + "Check the laser side, the exposure and that the wall tops are matte, then try again."
            pushSettings()
            return
        }
        guard let fit = LaserWalls.fit(detection, columns: columns, cameraHeight: H, wallHeight: hw, laserTerm: k,
                                       fx: current.fx, cx: current.cx, cy: current.cy,
                                       tilt: (laserAngle: angle, side: side, cameraTilt: tilt, fy: current.fy)) else {
            notice = "The wall calibration could not be computed (check the camera and wall heights)."
            pushSettings()
            return
        }
        let wallCount = fit.wallColumns.count
        let c = LaserCalibration(date: Date(), cameraHeight: H, cameraHeightSource: cameraHeightSource, scale: k,
                                 scaleSource: .angle, shimThickness: nil, shimShift: nil, laserAngle: angle,
                                 laserSide: side, videoWidth: current.width, videoHeight: current.height,
                                 columns: columns, baselineRows: fit.rows,
                                 coverage: 100 * Double(wallCount) / Double(max(1, columns.count)),
                                 filledColumns: columns.count - wallCount, lensPosition: lens, fx: current.fx,
                                 fy: current.fy, cx: current.cx, cy: current.cy, shimBaselineRow: nil,
                                 binned: current.binned, method: .sideWalls, wallHeight: hw,
                                 wallColumns: fit.wallColumns, wallRows: fit.wallRows, wallInnerX: fit.innerX,
                                 wallTracking: true, cameraTilt: tilt)
        saveCalibration(c)
        notice = String(format: "Calibrated on the side walls: %ld + %ld wall columns, fit residual %.2f px.",
                        detection.left.count, detection.right.count, fit.residual)
    }

    func setWallTracking(_ on: Bool) {
        guard var c = calibration, c.isSideWalls, !calibrating else { return }
        c.wallTracking = on
        saveCalibration(c)
    }

    /// Wall-top points of the calibration (orange on the picture).
    var displayWalls: [(u: Int, v: Float)] {
        guard let c = activeCalibration, let columns = c.wallColumns, let rows = c.wallRows,
              columns.count == rows.count else { return [] }
        return zip(columns, rows).map { (c.columns.u($0.0), $0.1) }
    }

    func clearCalibration() {
        guard !calibrating else { return }
        do {
            try LaserCalibration.removeStandard()
        } catch {
            notice = "The calibration file could not be removed: \(error.localizedDescription)"
        }
        calibration = nil
        pushSettings()
        pipeline.setLens(position: nil)
    }

    private func saveCalibration(_ c: LaserCalibration) {
        calibration = c
        do {
            try c.saveStandard()
        } catch {
            notice = "The calibration is used now but could not be saved: \(error.localizedDescription)"
        }
        pushSettings()
    }

    // MARK: - Recording

    func toggleRecording() {
        if phase == .recording || phase == .arming {
            stop(reason: nil)
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard canRecord, let store, let c = activeCalibration, let format else { return }
        notice = nil
        if let free = LineStorage.freeBytes(at: store.root), free < LineStorage.minimumToStart {
            notice = "Not enough free storage to record: \(LineStorage.text(free)) free, at least "
                + "\(LineStorage.text(LineStorage.minimumToStart)) needed."
            return
        }
        let folder: (name: String, url: URL)
        do {
            folder = try store.newFolder(kind: .laser)
        } catch {
            notice = "Recording not started: the scan folder could not be created (\(error.localizedDescription))."
            return
        }
        do {
            let columns = format.columns
            let info = LaserRecordingInfo(videoWidth: format.width, videoHeight: format.height,
                                          frameRate: format.requestedFrameRate, activeFrameRate: format.activeFrameRate,
                                          direction: direction, columnFirst: columns.first,
                                          columnStride: columns.stride, columnCount: columns.count,
                                          fx: format.fx, fy: format.fy, cx: format.cx, cy: format.cy,
                                          shutterLimit: shutterLimit, exposureBias: exposureBias,
                                          maxHeight: maxHeight, mapMethod: mapMethod, calibration: c)
            try info.save(to: folder.url)
            // In the library from the start: a recording cut short by a crash keeps its files and can be rebuilt.
            let record = ScanRecord(id: UUID(), kind: .laser,
                                    name: "Laser " + Date().formatted(date: .abbreviated, time: .shortened),
                                    created: Date(), folderName: folder.name, primaryModel: nil,
                                    summary: ["Recording did not finish (the app closed while recording). Open "
                                              + "Topographic map and tap Rebuild map."])
            try store.save(record)
            recordingFolder = folder
            recordingRecord = record
            recordingInfo = info
            stopReason = nil
            savePreferences()
            phase = .arming
            pipeline.startRecording(folder: folder.url)
        } catch {
            notice = "Recording not started: the recording files could not be created (\(error.localizedDescription))."
            // Nothing was recorded yet: remove the new folder (and its scan.json if that was written).
            if let record = recordingRecord { store.delete(record) }
            try? FileManager.default.removeItem(at: folder.url)
            recordingFolder = nil
            recordingRecord = nil
            recordingInfo = nil
        }
    }

    /// Removes a recording that never got a frame (its scan.json may already exist).
    private func discardRecording() {
        if let store, let record = recordingRecord {
            store.delete(record)
        } else if let folder = recordingFolder {
            try? FileManager.default.removeItem(at: folder.url)
        }
        recordingFolder = nil
        recordingRecord = nil
        recordingInfo = nil
    }

    private func stop(reason: String?) {
        guard phase == .recording || phase == .arming else { return }
        if let reason, stopReason == nil { stopReason = reason }
        phase = .saving
        beginBackgroundTask()
        pipeline.stopRecording { result in
            Task { @MainActor in self.recordingStopped(result) }
        }
    }

    private func recordingStopped(_ result: LaserRecordingResult?) {
        guard let store, var record = recordingRecord, var info = recordingInfo, let folder = recordingFolder else {
            phase = .ready
            endBackgroundTask()
            return
        }
        guard let result, result.frameCount > 0 else {
            discardRecording()
            phase = .ready
            notice = "Recording not saved: no frames were recorded" + (stopReason.map { " (\($0))." } ?? ".")
            endBackgroundTask()
            return
        }
        info.frameCount = result.frameCount
        info.duration = result.duration
        info.droppedFrames = result.droppedFrames
        info.stopReason = stopReason
        var summary = [info.summaryLine]
        if let stopReason { summary.append("Recording stopped early: \(stopReason).") }
        if result.droppedFrames > 0 {
            summary.append(String(format: "%ld camera frames dropped (%.1f %%)", result.droppedFrames,
                                  100 * Double(result.droppedFrames) / Double(result.frameCount + result.droppedFrames)))
        }
        summary += result.notes
        do {
            try info.save(to: folder.url)
        } catch {
            summary.append("LaserRecording.json was not updated (\(error.localizedDescription)); the frame count is "
                           + "missing but the data is complete.")
        }
        record.summary = summary + ["Map not built yet: open Topographic map and tap Rebuild map."]
        do {
            try store.save(record)
        } catch {
            notice = "The recording is kept in Files › On My iPhone › Phone LiDAR › Scans › \(folder.name), but its "
                + "summary could not be saved (\(error.localizedDescription))."
        }
        phase = .building
        pipeline.stop()
        let url = folder.url
        let finalInfo = info
        let baseSummary = summary
        let savedRecord = record
        let recording = MapRecording.laser(finalInfo)
        Task { @MainActor in
            var record = savedRecord
            let built = await Task.detached(priority: .userInitiated) { () -> Result<[String], Error> in
                do {
                    return .success(try MapRebuild.build(folder: url, recording: recording, method: nil).summary)
                } catch {
                    return .failure(error)
                }
            }.value
            switch built {
            case .success(let map):
                record.summary = LaserMapBuilder.recordSummary(existing: baseSummary, info: finalInfo, map: map)
            case .failure(let error):
                record.summary = baseSummary + ["Map not built: \(error.localizedDescription)"]
            }
            do {
                try store.save(record)
            } catch {
                let text = "\(record.name): the scan summary was not updated (\(error.localizedDescription)). "
                    + "Open the scan and tap Rebuild map."
                store.recoveryNotice = store.recoveryNotice.map { $0 + "\n\n" + text } ?? text
            }
            recordingFolder = nil
            recordingRecord = nil
            recordingInfo = nil
            endBackgroundTask()
            onSaved?(record.id)
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save laser recording") { [weak self] in
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
