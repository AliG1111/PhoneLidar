import Foundation
import AVFoundation
import CoreGraphics
import simd

/// Live values for the laser screen, sent at most 15 times a second (design §14.2).
struct LaserLiveUpdate: Sendable {
    var fps: Double
    var droppedFrames: Int
    var detectedPercent: Double
    /// Detected rows of every `displayStride`-th profile column (buffer px, NaN = none).
    var lineRows: [Float]
    /// Heights (mm) of the same columns, NaN = none; empty without a complete calibration.
    var heights: [Float]
    var displayColumns: LaserColumns
    var medianHeight: Double?
    var maxHeight: Double?
    var speed: Double?
    var quality: Double
    var travel: Double
    var recordedFrames: Int
    var recordingElapsed: Double
    var videoWidth: Int
    var videoHeight: Int
    var calibrationProgress: Double?
    /// False when the part of the picture outside the laser band is too small for speed tracking.
    var trackingAvailable = true
}

/// Active camera format and intrinsics, reported once frames arrive.
struct LaserFormatInfo: Sendable, Equatable {
    var width: Int
    var height: Int
    var requestedFrameRate: Double
    var activeFrameRate: Double
    var fx: Double
    var fy: Double
    var cx: Double
    var cy: Double
    var binned: Bool

    var columns: LaserColumns { LaserColumns.make(width: width) }
}

enum LaserCaptureEvent: Sendable {
    case format(LaserFormatInfo)
    case recordingStarted
    case recordingStartFailed(String)
    case stopRecording(String)
    case cameraInterrupted(String)
    case cameraResumed
    case cameraError(String)
    case pressure(LinePressure)
}

/// What a finished laser recording produced.
struct LaserRecordingResult: Sendable {
    var folder: URL
    var frameCount: Int
    var duration: Double
    var droppedFrames: Int
    var notes: [String]
}

/// Settings the data queue needs for every frame.
struct LaserProcessingSettings: Sendable {
    var calibration: LaserCalibration?
    /// Lens to belt, mm (0 = unknown: no speed).
    var cameraHeight: Double
    var maxHeight: Double
    var direction: TravelDirection
}

/// Wide-camera capture for the laser line scan (design §14.2–§14.5). Session work on `phonelidar.laser.session`,
/// frames and recording on `phonelidar.laser.data`.
final class LaserCapturePipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    // @unchecked: session state is confined to `sessionQueue`, frame state to `dataQueue`; `onUpdate`/`onEvent`
    // are set once before `configure`.

    static var isSupported: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    static let frameRates: [Double] = [240, 120, 60]
    /// Profile columns shown on screen: every 4th.
    static let displayStride = 4

    let session = AVCaptureSession()
    var onUpdate: (@Sendable (LaserLiveUpdate) -> Void)?
    var onEvent: (@Sendable (LaserCaptureEvent) -> Void)?

    private let sessionQueue = DispatchQueue(label: "phonelidar.laser.session")
    private let dataQueue = DispatchQueue(label: "phonelidar.laser.data", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var observers: [NSObjectProtocol] = []
    private var pressureObservation: NSKeyValueObservation?
    // Session-queue state
    private var wantsRunning = false
    /// Automatic restarts after runtime errors since frames last arrived (max `maxErrorRestarts`).
    private var errorRestarts = 0
    static let maxErrorRestarts = 3
    private var shutterLimit = 1.0 / 1000
    private var exposureBias: Float = 0

    // Data-queue state
    private var settings = LaserProcessingSettings(calibration: nil, cameraHeight: 0, maxHeight: 100,
                                                   direction: .rightToLeft)
    private var requestedFrameRate = 240.0
    private var format: LaserFormatInfo?
    private var intrinsicsFromFrames = false
    private let estimator = SpeedEstimator()
    private var travel = LaserTravel()
    private var frameIndex = 0
    private var trackStride = 8
    private var lastTrackTime: Double?
    private var lastSpeed: Double?
    private var lastQuality = 0.0
    private var dropped = 0
    private var fpsWindow: [Double] = []
    private var lastUpdateTime = -Double.infinity
    private var lastFrameTime: Double?
    private var collection: RowCollection?
    private var recorder: LaserRecorder?
    private var pending: PendingRecording?
    private var pendingToken = 0
    private var autoStopReason: String?
    /// The camera was interrupted or failed; the next frame reports that it runs again.
    private var awaitingResume = false
    private var trackingAvailable = true

    private struct PendingRecording {
        var token: Int
        var folder: URL
    }

    /// Rows collected for a calibration (baseline: full frame; shim: band).
    private struct RowCollection {
        var target: Int
        var frames: [[Float]] = []
        var everyFrames: Int
        var completion: @Sendable ([[Float]]) -> Void
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        pressureObservation?.invalidate()
    }

    // MARK: - Session

    /// Configures the wide camera for `frameRate` (or the highest available). Main thread, once per screen.
    func configure(frameRate: Double) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw LineError.configuration("The back camera is not available.")
        }
        self.device = device
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw LineError.configuration("Cannot use the camera.") }
        session.addInput(input)

        guard let chosen = Self.chooseFormat(device.formats, frameRate: frameRate) else {
            throw LineError.configuration("No suitable camera format (1280 × 720 or larger, 8-bit) was found.")
        }
        let maxRate = chosen.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        let rate = min(frameRate, maxRate)
        try device.lockForConfiguration()
        device.activeFormat = chosen
        let duration = CMTime(value: 1, timescale: CMTimeScale(max(1, rate.rounded())))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        device.unlockForConfiguration()

        guard session.canAddOutput(videoOutput) else { throw LineError.configuration("Cannot read video frames.") }
        session.addOutput(videoOutput)
        let subtype = CMFormatDescriptionGetMediaSubType(chosen.formatDescription)
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: subtype]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
            if connection.isCameraIntrinsicMatrixDeliverySupported {
                connection.isCameraIntrinsicMatrixDeliveryEnabled = true
            }
        }
        let dims = CMVideoFormatDescriptionGetDimensions(chosen.formatDescription)
        let width = Int(dims.width)
        let height = Int(dims.height)
        // Pinhole fallback until intrinsics arrive with the frames.
        let fov = Double(chosen.videoFieldOfView > 0 ? chosen.videoFieldOfView : 70) * .pi / 180
        let f = Double(width) / 2 / tan(fov / 2)
        let info = LaserFormatInfo(width: width, height: height, requestedFrameRate: frameRate, activeFrameRate: rate,
                                   fx: f, fy: f, cx: Double(width) / 2, cy: Double(height) / 2,
                                   binned: chosen.isVideoBinned)
        dataQueue.async { [self] in
            format = info
            requestedFrameRate = frameRate
            trackStride = max(1, Int((rate / 60).rounded()))      // texture tracking at about 60 Hz
        }
        observe(device: device)
    }

    /// Format score (design §14.2): requested fps reachable, 1920 × 1080 or 1280 × 720, 8-bit 420 full/video range.
    static func chooseFormat(_ formats: [AVCaptureDevice.Format], frameRate: Double) -> AVCaptureDevice.Format? {
        let full = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let video = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        func score(_ format: AVCaptureDevice.Format) -> Double? {
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            guard subtype == full || subtype == video else { return nil }
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width >= 1280, dims.width <= 1920 else { return nil }
            let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            var s = 0.0
            if maxRate >= frameRate - 0.5 { s += 1000 } else { s += maxRate }          // else: the fastest wins
            if dims.width == 1920 && dims.height == 1080 { s += 500 } else if dims.width == 1280 { s += 200 }
            s += subtype == full ? 100 : 90
            return s
        }
        return formats.compactMap { f in score(f).map { (f, $0) } }.max { $0.1 < $1.1 }?.0
    }

    func start() {
        sessionQueue.async { [self] in
            wantsRunning = true
            if !session.isRunning { session.startRunning() }
            applyExposure()
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            wantsRunning = false
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Stops the session and calls `done` on the session queue once it has stopped (before the LiDAR probe).
    func stopAndWait(_ done: @escaping @Sendable () -> Void) {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
            done()
        }
    }

    func setExposure(shutterLimit: Double, bias: Float) {
        sessionQueue.async { [self] in
            self.shutterLimit = shutterLimit
            exposureBias = bias
            applyExposure()
        }
    }

    /// Continuous auto-exposure limited to the shutter limit, with the exposure bias. Session queue.
    private func applyExposure() {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            let format = device.activeFormat
            var limit = CMTime(seconds: shutterLimit, preferredTimescale: 1_000_000)
            if CMTimeCompare(limit, format.minExposureDuration) < 0 { limit = format.minExposureDuration }
            if CMTimeCompare(limit, format.maxExposureDuration) > 0 { limit = format.maxExposureDuration }
            if device.exposureMode == .continuousAutoExposure { device.activeMaxExposureDuration = limit }
            let bias = max(device.minExposureTargetBias, min(device.maxExposureTargetBias, exposureBias))
            device.setExposureTargetBias(bias, completionHandler: nil)
        } catch {
            // Keep the current exposure.
        }
    }

    /// Locks focus and white balance where they are; `completion` gets the lens position (main use: the baseline).
    func lockFocusAndWhiteBalance(completion: @escaping @Sendable (Float?) -> Void) {
        sessionQueue.async { [self] in
            guard let device else { return completion(nil) }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                completion(device.lensPosition)
            } catch {
                completion(nil)
            }
        }
    }

    /// Restores a saved lens position (calibration from an earlier session) or unlocks focus (nil).
    func setLens(position: Float?) {
        sessionQueue.async { [self] in
            guard let device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if let position, device.isLockingFocusWithCustomLensPositionSupported {
                    device.setFocusModeLocked(lensPosition: max(0, min(1, position)), completionHandler: nil)
                    if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                } else {
                    if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                }
            } catch {
                // Keep the current focus.
            }
        }
    }

    // MARK: - Interruptions, errors, system pressure

    private func observe(device: AVCaptureDevice) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                            object: session, queue: nil) { [weak self] note in
            let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            let reason = raw.flatMap { AVCaptureSession.InterruptionReason(rawValue: $0) }
            self?.interrupted("the camera was interrupted (\(LineCapturePipeline.describe(reason)))")
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                            object: session, queue: nil) { [weak self] _ in
            self?.onEvent?(.cameraResumed)
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                            object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self?.failed(error)
        })
        pressureObservation = device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
            let level = device.systemPressureState.level
            let pressure: LinePressure = level == .critical || level == .shutdown ? .critical
                : level == .serious ? .serious : .normal
            self?.dataQueue.async {
                guard let self else { return }
                if pressure == .critical { self.requestAutoStop("the phone is too hot (camera system pressure critical)") }
                self.onEvent?(.pressure(pressure))
            }
        }
    }

    private func interrupted(_ text: String) {
        dataQueue.async { [self] in
            awaitingResume = true
            cancelCollectionOnDataQueue()
            requestAutoStop(text)
            onEvent?(.cameraInterrupted(text))
        }
    }

    /// Stops the recording, then restarts the camera: always after a media-services reset, else at most
    /// `maxErrorRestarts` times in a row (the count is reset by the first frame after a restart).
    private func failed(_ error: AVError?) {
        let message = error?.localizedDescription ?? "unknown camera error"
        let reset = error?.code == .mediaServicesWereReset
        dataQueue.async { [self] in
            awaitingResume = true
            cancelCollectionOnDataQueue()
            requestAutoStop("the camera stopped with an error (\(message))")
        }
        sessionQueue.async { [self] in
            let needed = wantsRunning && !session.isRunning
            let restart = needed && (reset || errorRestarts < Self.maxErrorRestarts)
            onEvent?(.cameraError(restart ? message + "; restarting" : message))
            guard restart else { return }
            if !reset { errorRestarts += 1 }
            session.startRunning()
            applyExposure()
        }
    }

    // MARK: - Settings and calibration capture

    func setSettings(_ newSettings: LaserProcessingSettings) {
        dataQueue.async { [self] in
            if newSettings.direction != settings.direction {
                estimator.travelSign = newSettings.direction.bufferSign
                estimator.reset()
                travel.clearHeldSpeed()
                lastTrackTime = nil
            }
            settings = newSettings
        }
    }

    /// Collects the detected rows of the next `frames` processed frames (every `every`-th camera frame). Full-frame
    /// search when no calibration is set. `completion` runs on the data queue (empty on cancellation).
    func collectRows(frames: Int, every: Int, completion: @escaping @Sendable ([[Float]]) -> Void) {
        dataQueue.async { [self] in
            collection?.completion([])
            collection = RowCollection(target: max(1, frames), everyFrames: max(1, every), completion: completion)
        }
    }

    func cancelCollection() {
        dataQueue.async { [self] in cancelCollectionOnDataQueue() }
    }

    private func cancelCollectionOnDataQueue() {
        guard let active = collection else { return }
        collection = nil
        active.completion([])
    }

    // MARK: - Recording

    /// Starts recording into `folder` with the next frame (`LaserRecording.json` and `scan.json` already exist).
    func startRecording(folder: URL) {
        dataQueue.async { [self] in
            guard recorder == nil else {
                onEvent?(.recordingStartFailed("a recording is already running"))
                return
            }
            pendingToken += 1
            let token = pendingToken
            pending = PendingRecording(token: token, folder: folder)
            dataQueue.asyncAfter(deadline: .now() + 3) { [self] in
                guard pending?.token == token else { return }
                pending = nil
                onEvent?(.recordingStartFailed("no camera frames arrived. Check that no other app is using the camera"))
            }
        }
    }

    /// Stops the recording and closes its files on the data queue. `completion` gets nil when none had started.
    func stopRecording(completion: @escaping @Sendable (LaserRecordingResult?) -> Void) {
        dataQueue.async { [self] in
            pending = nil
            autoStopReason = nil
            guard let active = recorder else { return completion(nil) }
            recorder = nil
            completion(active.finish(droppedFrames: dropped - active.droppedAtStart))
        }
    }

    /// Data queue: no more frames go into the recording; the screen is asked to stop and save it.
    private func requestAutoStop(_ reason: String) {
        if pending != nil {
            pending = nil
            onEvent?(.recordingStartFailed(reason))
        }
        guard recorder != nil, autoStopReason == nil else { return }
        autoStopReason = reason
        onEvent?(.stopRecording(reason))
    }

    // MARK: - Frames

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        dropped += 1
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer), var info = format else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard time.isFinite else { return }
        if awaitingResume {
            awaitingResume = false
            onEvent?(.cameraResumed)
            sessionQueue.async { [self] in errorRestarts = 0 }
        }
        frameIndex += 1
        if let previous = lastFrameTime, time - previous > 0.5 { fpsWindow.removeAll() }   // after a pause
        lastFrameTime = time
        fpsWindow.append(time)
        while let first = fpsWindow.first, time - first > 1 { fpsWindow.removeFirst() }

        // Intrinsics with the frames (preferred over the field-of-view estimate); reported again when they change
        // by more than 0.1 % (focus lock) or 0.5 px.
        if let m = Self.intrinsics(sampleBuffer) {
            let fx = Double(m.columns.0.x), fy = Double(m.columns.1.y)
            let cx = Double(m.columns.2.x), cy = Double(m.columns.2.y)
            if !intrinsicsFromFrames || abs(fx - info.fx) > 0.001 * info.fx || abs(fy - info.fy) > 0.001 * info.fy
                || abs(cx - info.cx) > 0.5 || abs(cy - info.cy) > 0.5 {
                info.fx = fx
                info.fy = fy
                info.cx = cx
                info.cy = cy
                intrinsicsFromFrames = true
            }
        }
        if format != info || frameIndex == 1 {
            format = info
            onEvent?(.format(info))
        }

        let columns = info.columns
        let baselineReady = settings.calibration.map {
            $0.matches(width: info.width, height: info.height, columns: columns, fx: info.fx, fy: info.fy,
                       cx: info.cx, cy: info.cy, binned: info.binned)
        } == true
        let calibration = baselineReady && settings.calibration?.isComplete == true ? settings.calibration : nil
        let collecting = collection != nil
        // Without a baseline the whole frame is searched, on every 4th frame (preview) or the collection's stride.
        let fullFrame = !baselineReady
        if fullFrame && !collecting && recorder == nil && frameIndex % 4 != 0 { return }
        if let active = collection, frameIndex % active.everyFrames != 0, recorder == nil { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        var detection: LaserLineDetector.Result?
        var band = (lo: 0, hi: info.height)
        if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            if var calibrated = settings.calibration, baselineReady {
                // Before a scale exists (shim measurement), size the band as for a 45° laser.
                if calibrated.scale == nil {
                    calibrated.scale = LaserGeometry.scaleFromAngle(degrees: 45, side: calibrated.laserSide,
                                                                    focal: info.fy)
                }
                let scale = calibrated.bandScale ?? info.fy
                let H = calibrated.cameraHeight > 0 ? calibrated.cameraHeight : max(settings.cameraHeight, 300)
                band = LaserGeometry.band(baseline: calibrated.baselineRows, maxHeight: settings.maxHeight,
                                          cameraHeight: H, scale: scale, height: height)
            }
            detection = LaserLineDetector.detect(luma: base.assumingMemoryBound(to: UInt8.self), width: width,
                                                 height: height, rowBytes: rowBytes, columns: columns,
                                                 rowLo: band.lo, rowHi: band.hi)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        guard let detection else { return }

        // Calibration collection.
        if var active = collection {
            active.frames.append(detection.rows)
            if active.frames.count >= active.target {
                collection = nil
                active.completion(active.frames)
            } else {
                collection = active
            }
        }

        // Heights.
        var heights: [Float] = []
        var medianHeight: Double?
        var maxHeight: Double?
        if let calibration {
            heights = [Float](repeating: .nan, count: columns.count)
            var finite: [Float] = []
            finite.reserveCapacity(columns.count)
            for k in 0..<columns.count {
                let row = detection.rows[k]
                guard row.isFinite, let scale = calibration.shiftScale(column: k),
                      let h = LaserGeometry.height(shift: Double(row - calibration.baselineRows[k]),
                                                   cameraHeight: calibration.cameraHeight, scale: scale) else { continue }
                heights[k] = Float(h)
                finite.append(Float(h))
            }
            if !finite.isEmpty {
                finite.sort()
                medianHeight = Double(finite[finite.count / 2])
                maxHeight = Double(finite[finite.count - 1])
            }
        }

        // Speed and travel: texture tracking away from the laser band, every `trackStride` frames.
        var flags: UInt32 = 0
        var rawSpeed: Double?
        let H = calibration?.cameraHeight ?? settings.cameraHeight
        if frameIndex % trackStride == 0 && H > 0 {
            flags |= ProfilesFile.trackedFlag
            var trackBand = band
            if fullFrame {
                let finite = detection.rows.filter { $0.isFinite }
                if let lo = finite.min(), let hi = finite.max() {
                    trackBand = (max(0, Int(lo) - 24), min(info.height, Int(hi) + 25))
                } else {
                    trackBand = (0, 0)
                }
            }
            let rows = LaserGeometry.trackingRows(band: trackBand, height: info.height)
            trackingAvailable = rows != nil
            if let rows, let shift = estimator.process(pixelBuffer, rows: rows, zones: false) {
                let dt = lastTrackTime.map { time - $0 } ?? 0
                let distance = H - max(0, medianHeight ?? 0)
                rawSpeed = LineMotionMath.trackedSpeed(shiftPixels: shift.along, quality: shift.quality,
                                                       trackedDistance: distance, centerDistance: H,
                                                       focalPixels: info.fy, dt: dt)
                lastQuality = shift.quality
            } else {
                if rows == nil { estimator.reset() }
                lastQuality = 0
            }
            if rawSpeed != nil { flags |= ProfilesFile.speedFlag }
            lastSpeed = travel.addTracked(speed: rawSpeed, time: time)
            lastTrackTime = time
        }
        let travelNow = travel.travel(at: time)

        // Recording.
        if pending != nil, recorder == nil, calibration == nil {
            pending = nil
            onEvent?(.recordingStartFailed("the calibration does not match the camera format. Calibrate again"))
        }
        if let request = pending, recorder == nil {
            pending = nil
            do {
                recorder = try LaserRecorder(folder: request.folder, columns: columns, startTime: time,
                                             travelOffset: travelNow, droppedAtStart: dropped)
                travel.beginRecording()
                onEvent?(.recordingStarted)
            } catch {
                onEvent?(.recordingStartFailed("the recording files could not be created (\(error.localizedDescription))"))
            }
        }
        if let active = recorder, autoStopReason == nil {
            active.append(time: time, travel: travelNow, speed: rawSpeed, flags: flags, rows: detection.rows,
                          detectedPercent: 100 * detection.detectedFraction, medianHeight: medianHeight,
                          maxHeight: maxHeight)
            if let reason = active.stopReason { requestAutoStop(reason) }
        }

        // Live update, ≤ 15 Hz.
        if time - lastUpdateTime >= 1.0 / 15 {
            lastUpdateTime = time
            let display = LaserColumns(first: columns.first, stride: columns.stride * Self.displayStride,
                                       count: (columns.count + Self.displayStride - 1) / Self.displayStride)
            let pick: ([Float]) -> [Float] = { values in
                stride(from: 0, to: values.count, by: Self.displayStride).map { values[$0] }
            }
            let span = (fpsWindow.last ?? time) - (fpsWindow.first ?? time)
            let update = LaserLiveUpdate(
                fps: span > 0 ? Double(fpsWindow.count - 1) / span : 0,
                droppedFrames: dropped, detectedPercent: 100 * detection.detectedFraction,
                lineRows: pick(detection.rows), heights: heights.isEmpty ? [] : pick(heights),
                displayColumns: display, medianHeight: medianHeight, maxHeight: maxHeight,
                speed: lastSpeed, quality: lastQuality, travel: travelNow,
                recordedFrames: recorder?.frameCount ?? 0, recordingElapsed: recorder?.elapsed ?? 0,
                videoWidth: info.width, videoHeight: info.height,
                calibrationProgress: collection.map { Double($0.frames.count) / Double($0.target) },
                trackingAvailable: trackingAvailable)
            onUpdate?(update)
        }
    }

    /// Camera intrinsics delivered with the frame (pixels of the buffer).
    private static func intrinsics(_ sampleBuffer: CMSampleBuffer) -> matrix_float3x3? {
        guard let attachment = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                               attachmentModeOut: nil) as? Data,
              attachment.count >= MemoryLayout<matrix_float3x3>.size else { return nil }
        let m = attachment.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) }
        guard m.columns.0.x > 0, m.columns.1.y > 0, m.columns.0.x.isFinite, m.columns.1.y.isFinite else { return nil }
        return m
    }
}

/// Writes one laser recording's streamed files (`Profiles.bin`, `LaserFrames.csv`). Confined to the data queue.
final class LaserRecorder {
    let folder: URL
    let droppedAtStart: Int
    private let profiles: ProfilesFileWriter
    private let frames: TextFileWriter
    private let startTime: Double
    private let travelOffset: Double
    private var notes: [String] = []
    private(set) var frameCount = 0
    private(set) var elapsed = 0.0
    /// Set when the recording must stop (write failure, storage almost full); no more frames are written.
    private(set) var stopReason: String?

    /// Free storage is checked every this many frames.
    static let storageCheckFrames = 240

    init(folder: URL, columns: LaserColumns, startTime: Double, travelOffset: Double, droppedAtStart: Int) throws {
        self.folder = folder
        self.startTime = startTime
        self.travelOffset = travelOffset
        self.droppedAtStart = droppedAtStart
        profiles = try ProfilesFileWriter(url: folder.appendingPathComponent(ProfilesFile.fileName), columns: columns)
        frames = try TextFileWriter(url: folder.appendingPathComponent(LaserFramesCSV.fileName), flushBytes: 128_000)
        try frames.line(LaserFramesCSV.header.joined(separator: ","))
    }

    func append(time: Double, travel: Double, speed: Double?, flags: UInt32, rows: [Float], detectedPercent: Double,
                medianHeight: Double?, maxHeight: Double?) {
        guard stopReason == nil else { return }
        let t = time - startTime
        let d = travel - travelOffset
        do {
            try profiles.append(time: t, travel: d, speed: speed, flags: flags, rows: rows)
            try frames.line(LaserFramesCSV.row(frame: frameCount, time: t, speed: speed, travel: d,
                                               detectedPercent: detectedPercent, medianHeight: medianHeight,
                                               maxHeight: maxHeight))
            frameCount += 1
            elapsed = t
        } catch {
            stopReason = "the recording could not be written to storage (\(error.localizedDescription))"
            return
        }
        if frameCount % Self.storageCheckFrames == 0, let free = LineStorage.freeBytes(at: folder),
           free < LineStorage.stopBelow {
            stopReason = "iPhone storage is almost full (\(LineStorage.text(free)) left)"
        }
    }

    /// Closes the files. Problems that did not lose frames become notes.
    func finish(droppedFrames: Int) -> LaserRecordingResult {
        do {
            try profiles.close()
        } catch {
            notes.append("Profiles.bin may be missing its last frames (\(error.localizedDescription)).")
        }
        do {
            try frames.close()
        } catch {
            notes.append("LaserFrames.csv may end early (\(error.localizedDescription)); Profiles.bin holds the data.")
        }
        return LaserRecordingResult(folder: folder, frameCount: frameCount, duration: elapsed,
                                    droppedFrames: max(0, droppedFrames), notes: notes)
    }
}
