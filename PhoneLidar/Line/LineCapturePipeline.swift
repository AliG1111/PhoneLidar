import Foundation
import AVFoundation
import CoreGraphics
import CoreMotion

/// Snapshot sent to the screen after every processed frame.
struct LiveUpdate {
    var speed: Double?
    var rawSpeed: Double?
    var quality: Double
    var medianDepth: Double
    var travel: Double
    var angle: Double?
    var depthImage: CGImage?
    var depthRange: ClosedRange<Float>?
    var recordedFrames: Int
    var elapsed: Double
    /// Phone tilt from gravity, degrees. +X = right edge high, +Y = top edge high (screen up, portrait).
    var tiltX: Double?
    var tiltY: Double?
    /// Tilt of the phone relative to the surface below, from a plane fitted to the LiDAR depth (same signs).
    var surfaceTiltX: Double?
    var surfaceTiltY: Double?
    /// True when a flat-surface baseline is applied: the image and range are heights above it.
    var heightMode = false
    /// Median height above the baseline in the centre of the view, mm.
    var centerHeight: Double?
    /// Std dev across the view of the displayed values (heights or distances), mm: a flatness check.
    var spread: Double?
    /// 0…1 while a baseline calibration is being captured.
    var calibrationProgress: Double?
    /// Local speeds (mm/s, + = travel direction), half-second average, grid SpeedEstimator.tileColumns × tileRows.
    var tileSpeeds: [Double?] = []
    /// Fastest zone on screen (mm/s) and its index in tileSpeeds.
    var fastestSpeed: Double?
    var fastestTile: Int?
    /// Width ÷ height of the portrait picture.
    var pictureAspect: Double = 0.75
    /// Problem with the recording that does not stop it (e.g. the video encoder stopped).
    var recordingWarning: String?
    /// Direction found by the automatic detection (nil: not yet, or Direction is set by hand) and the generation of
    /// the direction setting it belongs to (`LineCapturePipeline.setDirection`), so a late update is ignored.
    var detectedDirection: TravelDirection?
    var directionGeneration = 0
}

/// Camera system load, from the capture device's system pressure state.
enum LinePressure: Sendable {
    case normal
    /// Serious: the live overlay is updated less often to reduce load.
    case serious
    /// Critical or shutdown: recording is stopped and saved.
    case critical
}

/// Things the capture pipeline reports to the screen (delivered on any queue).
enum LineCaptureEvent: Sendable {
    case recordingStarted
    /// The recording could not start; the text completes "Recording not started: …".
    case recordingStartFailed(String)
    /// The recording must be stopped and saved; the text completes "Recording stopped early: …".
    case stopRecording(String)
    case cameraInterrupted(String)
    case cameraResumed
    /// The camera stopped with an error; `restarting` is false once automatic restarts are used up.
    case cameraError(String, restarting: Bool)
    case pressure(LinePressure)
}

/// Frames collected for a baseline calibration (handed to a background queue when complete).
private struct CalibrationCapture: @unchecked Sendable {
    var target: Int
    /// Frames delivered since the calibration started, used or not.
    var seen = 0
    var frames: [[Float]] = []
    var tiltX: [Double] = []
    var tiltY: [Double] = []
    var width = 0
    var height = 0
    var filtered: Bool
    var completion: @Sendable (Result<Baseline, Error>) -> Void
}

/// LiDAR depth camera + synchronized video. Measures surface speed from the video texture,
/// shows live depth, and records Video.mov + Depth.bin while recording is on.
final class LineCapturePipeline: NSObject, AVCaptureDataOutputSynchronizerDelegate, @unchecked Sendable {
    static var isSupported: Bool {
        AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) != nil
    }

    let session = AVCaptureSession()
    /// Set once before `configure`; called on the data queue.
    var onUpdate: (@Sendable (LiveUpdate) -> Void)?
    /// Set once before `configure`; called on various queues.
    var onEvent: (@Sendable (LineCaptureEvent) -> Void)?

    private let sessionQueue = DispatchQueue(label: "phonelidar.line.session")
    private let dataQueue = DispatchQueue(label: "phonelidar.line.data", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var device: AVCaptureDevice?
    private var configured = false
    private var observers: [NSObjectProtocol] = []
    private var pressureObservation: NSKeyValueObservation?
    /// Session-queue state: short shutter wanted (read when the session starts and when toggled).
    private var shortShutterSetting = true
    /// Session-queue state: the screen wants the camera running (restart after a runtime error).
    private var wantsRunning = false
    /// Session-queue state: automatic restarts after runtime errors since frames last arrived (max 3).
    private var errorRestarts = 0
    static let maxErrorRestarts = 3

    // Data-queue state
    private var baseline: Baseline?
    private var calibration: CalibrationCapture?
    private var zoneSmoother = ZoneSpeedSmoother()
    private var lastSpread: Double?
    private var lastCenterHeight: Double?
    private let motion = CMMotionManager()
    private var surfaceTilt: (x: Double, y: Double)?
    private let estimator = SpeedEstimator()
    private var lastTime: CMTime?
    private var speedTracker = LineSpeedTracker()
    private var frameCounter = 0
    /// Direction setting (Auto or by hand), its generation, and the automatic detection (design §6.16).
    private var directionSetting: DirectionSetting = .rightToLeft
    private var directionGeneration = 0
    private var detector = TravelDirectionDetector()
    private var recorder: LineRecorder?
    private var pendingRecording: PendingRecording?
    private var pendingToken = 0
    /// Set when the recording has been asked to stop; no more frames go into it.
    private var autoStopReason: String?
    /// Live overlay and LiDAR tilt are computed every `overlayStride` frames (raised under system pressure).
    private var overlayStride = 2
    /// The camera was interrupted or failed; the next frame reports that it is running again.
    private var awaitingResume = false

    private struct PendingRecording {
        var token: Int
        var folder: URL
        var filtered: Bool
        var shortShutter: Bool
        var direction: TravelDirection
        var mapMethod: MapMethod
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        pressureObservation?.invalidate()
    }

    // MARK: - Session setup

    func configure(filteredDepth: Bool) throws {
        guard !configured else { return }
        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) else {
            throw LineError.noLiDAR
        }
        self.device = device

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw LineError.configuration("Cannot open the LiDAR camera.") }
        session.addInput(input)

        func dims(_ format: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        }
        func subtype(_ format: AVCaptureDevice.Format) -> FourCharCode {
            CMFormatDescriptionGetMediaSubType(format.formatDescription)
        }
        let eightBit: Set<FourCharCode> = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                           kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        func score(_ format: AVCaptureDevice.Format) -> Int {
            let d = dims(format)
            var s = 0
            if Int(d.width) * 3 == Int(d.height) * 4 { s += 1000 }          // 4:3 matches the depth field of view
            if d.width == 1920 { s += 500 } else if d.width >= 1280 && d.width <= 2016 { s += 200 }
            if eightBit.contains(subtype(format)) { s += 100 }
            if format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 30 }) { s += 50 }
            return s
        }
        let candidates = device.formats.filter { !$0.supportedDepthDataFormats.isEmpty && !$0.isVideoBinned }
        guard let format = candidates.max(by: { score($0) < score($1) }) else {
            throw LineError.configuration("No LiDAR depth format is available.")
        }
        let depthFormats = format.supportedDepthDataFormats
        let depthFormat = depthFormats
            .filter { subtype($0) == kCVPixelFormatType_DepthFloat32 }
            .max(by: { dims($0).width < dims($1).width })
            ?? depthFormats.max(by: { dims($0).width < dims($1).width })

        try device.lockForConfiguration()
        device.activeFormat = format
        device.activeDepthDataFormat = depthFormat
        if format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
            let thirty = CMTime(value: 1, timescale: 30)
            device.activeVideoMinFrameDuration = thirty
            device.activeVideoMaxFrameDuration = thirty
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        device.unlockForConfiguration()

        guard session.canAddOutput(videoOutput) else { throw LineError.configuration("Cannot read video frames.") }
        session.addOutput(videoOutput)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0     // keep the sensor's native orientation (matches the depth map)
        }

        guard session.canAddOutput(depthOutput) else { throw LineError.configuration("Cannot read LiDAR depth.") }
        session.addOutput(depthOutput)
        depthOutput.isFilteringEnabled = filteredDepth
        depthOutput.alwaysDiscardsLateDepthData = true
        depthOutput.connection(with: .depthData)?.isEnabled = true

        let sync = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
        sync.setDelegate(self, queue: dataQueue)
        synchronizer = sync
        observe(device: device)
        configured = true
    }

    // MARK: - Interruptions, errors, system pressure

    private func observe(device: AVCaptureDevice) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                            object: session, queue: nil) { [weak self] note in
            let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            let reason = raw.flatMap { AVCaptureSession.InterruptionReason(rawValue: $0) }
            self?.sessionInterrupted(LineCapturePipeline.describe(reason))
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                            object: session, queue: nil) { [weak self] _ in
            self?.onEvent?(.cameraResumed)
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                            object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self?.sessionFailed(error)
        })
        pressureObservation = device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
            self?.pressureChanged(device.systemPressureState.level)
        }
    }

    static func describe(_ reason: AVCaptureSession.InterruptionReason?) -> String {
        guard let reason else { return "the camera was interrupted" }
        switch reason {
        case .videoDeviceNotAvailableInBackground: return "the app is in the background"
        case .videoDeviceInUseByAnotherClient: return "another app is using the camera"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return "the camera is not available with several apps on screen"
        case .videoDeviceNotAvailableDueToSystemPressure: return "the phone is too hot"
        case .audioDeviceInUseByAnotherClient: return "another app is using the microphone"
        default: return "the camera was interrupted"
        }
    }

    private func sessionInterrupted(_ text: String) {
        dataQueue.async { [self] in
            awaitingResume = true
            cancelCalibrationOnDataQueue(reason: "the camera was interrupted (\(text))")
            requestAutoStop("the camera was interrupted (\(text))")
            onEvent?(.cameraInterrupted(text))
        }
    }

    private func sessionFailed(_ error: AVError?) {
        let message = error?.localizedDescription ?? "unknown camera error"
        let reset = error?.code == .mediaServicesWereReset
        // Stop the recording first, so no frame from a restarted session goes into it.
        dataQueue.async { [self] in
            awaitingResume = true
            cancelCalibrationOnDataQueue(reason: "the camera stopped with an error")
            requestAutoStop("the camera stopped with an error (\(message))")
        }
        // Restart the camera: always after a media services reset, else up to `maxErrorRestarts` times in a row
        // (the count is reset by the first frame after a restart). The event goes out before the restart, so the
        // "running again" report of the first new frame always follows it.
        sessionQueue.async { [self] in
            let needed = wantsRunning && !session.isRunning
            let restart = needed && (reset || errorRestarts < Self.maxErrorRestarts)
            onEvent?(.cameraError(message, restarting: restart || !needed))
            guard restart else { return }
            if !reset { errorRestarts += 1 }
            session.startRunning()
            applyShutter()
        }
    }

    private func pressureChanged(_ level: AVCaptureDevice.SystemPressureState.Level) {
        let pressure: LinePressure
        if level == .critical || level == .shutdown {
            pressure = .critical
        } else if level == .serious {
            pressure = .serious
        } else {
            pressure = .normal
        }
        dataQueue.async { [self] in
            overlayStride = pressure == .normal ? 2 : 6
            if pressure == .critical {
                requestAutoStop("the phone is too hot (camera system pressure critical)")
            }
            onEvent?(.pressure(pressure))
        }
    }

    func start(shortShutter: Bool) {
        // The motion manager is only used on the data queue (started, read per frame and stopped there).
        dataQueue.async { [self] in
            if motion.isDeviceMotionAvailable && !motion.isDeviceMotionActive {
                motion.deviceMotionUpdateInterval = 1.0 / 30
                motion.startDeviceMotionUpdates()
            }
        }
        sessionQueue.async { [self] in
            shortShutterSetting = shortShutter
            wantsRunning = true
            if !session.isRunning { session.startRunning() }
            applyShutter()
        }
    }

    func stop() {
        dataQueue.async { [self] in
            if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
        }
        sessionQueue.async { [self] in
            wantsRunning = false
            if session.isRunning { session.stopRunning() }
        }
    }

    func setFiltering(_ filtered: Bool) {
        sessionQueue.async { [self] in
            depthOutput.isFilteringEnabled = filtered
        }
    }

    func setShortShutter(_ enabled: Bool) {
        sessionQueue.async { [self] in
            shortShutterSetting = enabled
            applyShutter()
        }
    }

    /// Direction by hand, or Auto: the direction is then detected from the texture movement while no recording
    /// runs (design §6.16). `generation` comes back in `LiveUpdate.directionGeneration`.
    func setDirection(_ setting: DirectionSetting, generation: Int) {
        dataQueue.async { [self] in
            directionSetting = setting
            directionGeneration = generation
            detector.reset()
            if let manual = setting.manual { estimator.travelSign = manual.bufferSign }
            estimator.reset()
            zoneSmoother.reset()
            // Readings taken with the old sign must not carry into the new direction.
            speedTracker.clearHeldSpeed()
            lastTime = nil
        }
    }

    /// Data queue: tracking sign for a new direction (detected, or fixed for a recording). Readings taken with the
    /// old sign must not carry over; the stored picture levels stay valid, so the estimator is not reset.
    private func applyTravelSign(_ direction: TravelDirection) {
        guard estimator.travelSign != direction.bufferSign else { return }
        estimator.travelSign = direction.bufferSign
        zoneSmoother.reset()
        speedTracker.clearHeldSpeed()
    }

    /// Continuous auto exposure throughout; with the short shutter on, auto exposure may not use
    /// exposures longer than 1/1000 s and raises ISO instead, so it keeps adapting to the light.
    /// Session queue only.
    private func applyShutter() {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            guard device.exposureMode == .continuousAutoExposure || device.exposureMode == .autoExpose else { return }
            if shortShutterSetting {
                let format = device.activeFormat
                var limit = CMTime(value: 1, timescale: 1000)
                if CMTimeCompare(limit, format.minExposureDuration) < 0 { limit = format.minExposureDuration }
                if CMTimeCompare(limit, format.maxExposureDuration) > 0 { limit = format.maxExposureDuration }
                device.activeMaxExposureDuration = limit
            } else {
                device.activeMaxExposureDuration = .invalid      // back to the format's default limit
            }
        } catch {
            // Keep whatever exposure mode is active.
        }
    }

    // MARK: - Baseline

    func setBaseline(_ newBaseline: Baseline?) {
        dataQueue.async { [self] in
            baseline = newBaseline
        }
    }

    /// Captures `frames` frames of the empty flat surface and builds a per-pixel baseline from them.
    /// Only frames whose depth filtering matches `filtered` are used.
    func captureBaseline(frames: Int, filtered: Bool,
                         completion: @escaping @Sendable (Result<Baseline, Error>) -> Void) {
        dataQueue.async { [self] in
            calibration?.completion(.failure(BaselineError.cancelled("a new calibration was started")))
            calibration = CalibrationCapture(target: frames, filtered: filtered, completion: completion)
        }
    }

    /// Abandons a calibration in progress (camera interrupted, app in the background).
    func cancelCalibration(reason: String) {
        dataQueue.async { [self] in
            cancelCalibrationOnDataQueue(reason: reason)
        }
    }

    private func cancelCalibrationOnDataQueue(reason: String) {
        guard let capture = calibration else { return }
        calibration = nil
        capture.completion(.failure(BaselineError.cancelled(reason)))
    }

    // MARK: - Recording

    /// Starts recording into `folder` with the next frame. Reports `.recordingStarted` or
    /// `.recordingStartFailed` (also when no frame arrives within 3 s).
    func startRecording(folder: URL, filtered: Bool, shortShutter: Bool, direction: TravelDirection,
                        mapMethod: MapMethod = .averaged) {
        dataQueue.async { [self] in
            guard recorder == nil else {
                onEvent?(.recordingStartFailed("a recording is already running"))
                return
            }
            pendingToken += 1
            let token = pendingToken
            pendingRecording = PendingRecording(token: token, folder: folder, filtered: filtered,
                                                shortShutter: shortShutter, direction: direction,
                                                mapMethod: mapMethod)
            dataQueue.asyncAfter(deadline: .now() + 3) { [self] in
                guard pendingRecording?.token == token else { return }
                pendingRecording = nil
                onEvent?(.recordingStartFailed("no camera frames arrived. Check that no other app is using the camera"))
            }
        }
    }

    /// Stops the recording (or a start still waiting for a frame) and finishes its files off the capture queue.
    /// `completion` gets nil when no recording had started.
    func stopRecording(completion: @escaping @Sendable (LineRecordingResult?) -> Void) {
        dataQueue.async { [self] in
            pendingRecording = nil
            autoStopReason = nil
            guard let active = recorder else {
                completion(nil)
                return
            }
            recorder = nil
            active.finish(completion: completion)
        }
    }

    /// Data queue. Takes no more frames into the recording and asks the screen to stop and save it.
    private func requestAutoStop(_ reason: String) {
        if pendingRecording != nil {
            pendingRecording = nil
            onEvent?(.recordingStartFailed(reason))
        }
        guard recorder != nil, autoStopReason == nil else { return }
        autoStopReason = reason
        onEvent?(.stopRecording(reason))
    }

    // MARK: - Frames

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        guard let videoData = synchronizedDataCollection.synchronizedData(for: videoOutput)
                as? AVCaptureSynchronizedSampleBufferData,
              !videoData.sampleBufferWasDropped,
              let depthSync = synchronizedDataCollection.synchronizedData(for: depthOutput)
                as? AVCaptureSynchronizedDepthData,
              !depthSync.depthDataWasDropped,
              let pixelBuffer = CMSampleBufferGetImageBuffer(videoData.sampleBuffer) else { return }
        handle(sampleBuffer: videoData.sampleBuffer, pixelBuffer: pixelBuffer, depthData: depthSync.depthData)
    }

    private func handle(sampleBuffer: CMSampleBuffer, pixelBuffer: CVPixelBuffer, depthData: AVDepthData) {
        frameCounter += 1
        if awaitingResume {
            awaitingResume = false
            onEvent?(.cameraResumed)
            sessionQueue.async { [self] in errorRestarts = 0 }      // frames again: the restart worked
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Depth map → millimetres.
        let depth = depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let map = depth.depthDataMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        let dw = CVPixelBufferGetWidth(map)
        let dh = CVPixelBufferGetHeight(map)
        let rowFloats = CVPixelBufferGetBytesPerRow(map) / MemoryLayout<Float32>.size
        var millimetres = [Float](repeating: 0, count: dw * dh)
        if let base = CVPixelBufferGetBaseAddress(map) {
            let source = base.assumingMemoryBound(to: Float32.self)
            millimetres.withUnsafeMutableBufferPointer { out in
                for y in 0..<dh {
                    let row = source + y * rowFloats
                    for x in 0..<dw {
                        let metres = row[x]
                        out[y * dw + x] = (metres.isFinite && metres > 0) ? metres * 1000 : 0
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(map, .readOnly)

        let videoHeight = CVPixelBufferGetHeight(pixelBuffer)
        let videoWidth = CVPixelBufferGetWidth(pixelBuffer)
        let k = intrinsics(for: depth, depthWidth: dw, depthHeight: dh)
        let median = LineMotionMath.centerMedian(millimetres, width: dw, height: dh)
        let fyVideo = LineMotionMath.videoFocalLength(depthFy: Double(k.fy), videoHeight: videoHeight, depthHeight: dh)

        // Speed from texture motion (LineMotionMath: pixels moved × (distance / focal length) / time, with gates).
        var shift: TextureShift?
        var rawSpeed: Double?
        // Auto direction: while no recording runs, the main match searches both ways and its shifts vote for the
        // direction (design §6.16). A recording keeps the direction it started with and the one-way search.
        let detecting = directionSetting == .auto && recorder == nil
        estimator.searchesBothWays = detecting
        let measured = estimator.process(pixelBuffer)
        var dt = 0.0
        if let last = lastTime { dt = (time - last).seconds }
        lastTime = time
        // Zone shifts of this frame were matched with the current sign; a sign change below drops them.
        var tileShifts = estimator.lastTiles
        var directionKnown = true
        if detecting {
            if let m = measured, LineMotionMath.isSpeedInterval(dt) {
                detector.add(rowShift: m.along * Double(estimator.travelSign), quality: m.quality)
            }
            if let found = detector.detected {
                if found.bufferSign != estimator.travelSign {
                    applyTravelSign(found)
                    tileShifts = []
                    directionKnown = false      // this frame's shifts are signed for the old direction
                }
            } else {
                // No direction yet: no speed, zone speeds or travel until the material has been seen moving.
                tileShifts = []
                directionKnown = false
            }
        }
        if directionKnown, let m = measured, LineMotionMath.isSpeedInterval(dt) {
            shift = m
            // Distance of the tracked area itself sets the mm-per-pixel scale.
            let trackedDistance = LineMotionMath.regionMedian(millimetres, width: dw, height: dh,
                                                              regionX: m.regionX, regionY: m.regionY)
            rawSpeed = LineMotionMath.trackedSpeed(shiftPixels: m.along, quality: m.quality,
                                                   trackedDistance: trackedDistance, centerDistance: median,
                                                   focalPixels: fyVideo, dt: dt)
        }
        // Local speeds per zone: zone movement × (zone distance / focal length) / time.
        var rawTiles = LineMotionMath.zoneSpeeds(
            tiles: tileShifts.map { tile in tile.map { (along: $0.along, quality: $0.quality) } },
            millimetres: millimetres, width: dw, height: dh, centerDistance: median, focalPixels: fyVideo, dt: dt,
            columns: SpeedEstimator.tileColumns, rows: SpeedEstimator.tileRows)
        let smoothTiles = zoneSmoother.add(rawTiles)
        let fastest = LineMotionMath.fastest(smoothTiles)
        var rawFastest = LineMotionMath.fastest(rawTiles)

        // Travel (held speed through frames without lock) and the half-second rolling average.
        let smoothed = speedTracker.add(rawSpeed: rawSpeed, dt: dt)
        let travel = speedTracker.travel
        let angle = shift.flatMap { LineMotionMath.motionAngle(along: $0.along, across: $0.across) }

        // Live colour image (every second frame, less often under system pressure):
        // heights above the baseline when one is set, else distance.
        var image: CGImage?
        var range: ClosedRange<Float>?
        let activeBaseline = baseline?.matches(width: dw, height: dh) == true ? baseline : nil
        if frameCounter % overlayStride == 0 {
            if let activeBaseline {
                let heights = activeBaseline.heights(millimetres)
                heights.withUnsafeBufferPointer { buffer in
                    if let r = DepthColors.finiteRange(buffer, step: 3) {
                        range = r
                        image = DepthColors.heightImage(buffer, width: dw, height: dh,
                                                        low: r.lowerBound, high: r.upperBound)
                    }
                    lastSpread = LineMotionMath.spread(buffer, width: dw, height: dh)
                }
                lastCenterHeight = LineMotionMath.centerMedian(heights, width: dw, height: dh, allowNegative: true)
            } else {
                millimetres.withUnsafeBufferPointer { buffer in
                    if let r = DepthColors.percentileRange(buffer, step: 3) {
                        range = r
                        image = DepthColors.image(millimetres: buffer, width: dw, height: dh,
                                                  near: r.lowerBound, far: r.upperBound)
                    }
                    lastSpread = LineMotionMath.spread(buffer, width: dw, height: dh)
                }
                lastCenterHeight = nil
            }
        }

        // Baseline calibration capture.
        var calibrationProgress: Double?
        if var capture = calibration {
            capture.seen += 1
            if capture.frames.isEmpty {
                capture.width = dw
                capture.height = dh
            }
            // Frames with the other depth filter setting (toggle still taking effect) are skipped.
            if capture.width == dw && capture.height == dh && depthData.isDepthDataFiltered == capture.filtered {
                capture.frames.append(millimetres)
                if let g = motion.deviceMotion?.gravity {
                    capture.tiltX.append(LineMotionMath.gravityTilt(g.x))
                    capture.tiltY.append(LineMotionMath.gravityTilt(g.y))
                }
            }
            calibrationProgress = Double(capture.frames.count) / Double(max(capture.target, 1))
            // Give up waiting after 3× the frames needed (Baseline.build refuses too few frames).
            if capture.frames.count >= capture.target || capture.seen >= capture.target * 3 {
                calibration = nil
                let done = capture
                DispatchQueue.global(qos: .userInitiated).async {
                    let meanX = done.tiltX.isEmpty ? nil : done.tiltX.reduce(0, +) / Double(done.tiltX.count)
                    let meanY = done.tiltY.isEmpty ? nil : done.tiltY.reduce(0, +) / Double(done.tiltY.count)
                    let result = Result<Baseline, Error> {
                        try Baseline.build(frames: done.frames, width: done.width, height: done.height,
                                           verify: done.target / 3, tiltX: meanX, tiltY: meanY,
                                           filtered: done.filtered)
                    }
                    done.completion(result)
                }
            } else {
                calibration = capture
            }
        }

        // Recording.
        // Auto: the detection changed after the screen read it (e.g. the line reversed just before Record). Refuse
        // rather than lock the recording to a direction against the movement.
        if let pending = pendingRecording, recorder == nil, directionSetting == .auto,
           let current = detector.detected, current != pending.direction {
            pendingRecording = nil
            onEvent?(.recordingStartFailed("the travel direction just changed to \(current.label). Tap Record again"))
        }
        if let pending = pendingRecording, recorder == nil {
            pendingRecording = nil
            // The recording keeps its direction: the screen passes the direction in use (set by hand or detected).
            // If that differs from the sign this frame was tracked with, its shifts are not recorded.
            if pending.direction.bufferSign != estimator.travelSign {
                applyTravelSign(pending.direction)
                shift = nil
                rawSpeed = nil
                rawTiles = [Double?](repeating: nil, count: rawTiles.count)
                rawFastest = nil
            }
            do {
                let created = try LineRecorder(folder: pending.folder, videoWidth: videoWidth, videoHeight: videoHeight,
                                               depthWidth: dw, depthHeight: dh, filteredDepth: pending.filtered,
                                               shortShutter: pending.shortShutter, direction: pending.direction,
                                               travelOffset: travel, mapMethod: pending.mapMethod)
                // Keep the baseline with the recording so its map and playback use the same reference.
                if let activeBaseline {
                    do {
                        try activeBaseline.save(to: pending.folder)
                    } catch {
                        created.addNote("Baseline not copied into the recording (\(error.localizedDescription)): "
                                        + "map and playback show distances from the camera.")
                    }
                }
                if directionSetting == .auto {
                    created.addNote(DirectionSetting.detectedNote(pending.direction))
                }
                recorder = created
                autoStopReason = nil
                // This frame is the recording's first (travel 0 via travelOffset). Y-1: a held speed read at most
                // 2 s ago carries into it; older readings are cleared so they cannot drive the recording's travel.
                speedTracker.beginRecording()
                onEvent?(.recordingStarted)
            } catch {
                onEvent?(.recordingStartFailed("the recording files could not be created (\(error.localizedDescription))"))
            }
        }
        // Level: gravity tilt every frame, LiDAR surface tilt every second frame.
        var tiltX: Double?
        var tiltY: Double?
        if let g = motion.deviceMotion?.gravity {
            tiltX = LineMotionMath.gravityTilt(g.x)
            tiltY = LineMotionMath.gravityTilt(g.y)
        }
        if frameCounter % overlayStride == 1 {
            surfaceTilt = LineMotionMath.surfaceTilt(millimetres, width: dw, height: dh, fx: Double(k.fx),
                                                     fy: Double(k.fy), cx: Double(k.cx), cy: Double(k.cy))
        }

        if let active = recorder, autoStopReason == nil {
            let info = LineFrameInfo(index: 0, time: 0, speed: rawSpeed, travel: travel,
                                     shiftPixels: shift?.along, crossShiftPixels: shift?.across,
                                     quality: shift?.quality ?? 0, medianDepth: median,
                                     fx: k.fx, fy: k.fy, cx: k.cx, cy: k.cy,
                                     tiltX: tiltX, tiltY: tiltY,
                                     surfaceTiltX: surfaceTilt?.x, surfaceTiltY: surfaceTilt?.y,
                                     tileSpeeds: rawTiles,
                                     fastestSpeed: rawFastest?.speed, fastestTile: rawFastest?.index)
            active.append(sampleBuffer: sampleBuffer, depthMillimetres: millimetres, info: info)
            if let reason = active.stopReason { requestAutoStop(reason) }
        }

        // While the direction is being detected the lock % still shows the texture match.
        let lock = shift?.quality ?? (detecting ? measured?.quality ?? 0 : 0)
        onUpdate?(LiveUpdate(speed: smoothed, rawSpeed: rawSpeed, quality: lock,
                             medianDepth: median, travel: travel, angle: angle,
                             depthImage: image, depthRange: range,
                             recordedFrames: recorder?.frameCount ?? 0,
                             elapsed: recorder?.elapsed ?? 0,
                             tiltX: tiltX, tiltY: tiltY,
                             surfaceTiltX: surfaceTilt?.x, surfaceTiltY: surfaceTilt?.y,
                             heightMode: activeBaseline != nil,
                             centerHeight: lastCenterHeight,
                             spread: lastSpread,
                             calibrationProgress: calibrationProgress,
                             tileSpeeds: smoothTiles,
                             fastestSpeed: fastest?.speed,
                             fastestTile: fastest?.index,
                             pictureAspect: Double(dh) / Double(max(dw, 1)),
                             recordingWarning: recorder?.videoProblem.map { "Video not recording: \($0)" },
                             detectedDirection: directionSetting == .auto ? detector.detected : nil,
                             directionGeneration: directionGeneration))
    }

    /// Zone with the largest speed magnitude (signed speed returned). See `LineMotionMath.fastest`.
    static func fastest(_ speeds: [Double?]) -> (speed: Double, index: Int)? {
        LineMotionMath.fastest(speeds)
    }

    /// Depth-map intrinsics in depth pixels.
    private func intrinsics(for depth: AVDepthData, depthWidth: Int, depthHeight: Int)
        -> (fx: Float, fy: Float, cx: Float, cy: Float) {
        if let calibration = depth.cameraCalibrationData {
            let m = calibration.intrinsicMatrix
            let reference = calibration.intrinsicMatrixReferenceDimensions
            if reference.width > 0, reference.height > 0 {
                let sx = Float(depthWidth) / Float(reference.width)
                let sy = Float(depthHeight) / Float(reference.height)
                return (m.columns.0.x * sx, m.columns.1.y * sy, m.columns.2.x * sx, m.columns.2.y * sy)
            }
        }
        let fieldOfView = (device?.activeFormat.videoFieldOfView ?? 64) * .pi / 180
        let fx = Float(depthWidth) / 2 / tan(fieldOfView / 2)
        return (fx, fx, Float(depthWidth) / 2, Float(depthHeight) / 2)
    }
}
