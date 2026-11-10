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
    struct Finished {
        var folder: URL
        var info: LineRecordingInfo
    }

    static var isSupported: Bool {
        AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) != nil
    }

    let session = AVCaptureSession()
    var onUpdate: (@Sendable (LiveUpdate) -> Void)?

    private let sessionQueue = DispatchQueue(label: "phonelidar.line.session")
    private let dataQueue = DispatchQueue(label: "phonelidar.line.data", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var device: AVCaptureDevice?
    private var configured = false
    /// Session-queue state: short shutter wanted (read when the session starts and when toggled).
    private var shortShutterSetting = true

    // Data-queue state
    private var baseline: Baseline?
    private var calibration: CalibrationCapture?
    private var tileHistory: [[Double?]] = []
    private var lastSpread: Double?
    private var lastCenterHeight: Double?
    private let motion = CMMotionManager()
    private var surfaceTilt: (x: Double, y: Double)?
    private let estimator = SpeedEstimator()
    private var lastTime: CMTime?
    private var travel: Double = 0
    private var recentSpeeds: [Double] = []
    private var lastValidSpeed: Double?
    private var frameCounter = 0
    private var direction: TravelDirection = .rightToLeft
    private var recorder: LineRecorder?
    private var pendingRecording: (folder: URL, filtered: Bool, shortShutter: Bool, direction: TravelDirection)?

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
        configured = true
    }

    func start(shortShutter: Bool) {
        if motion.isDeviceMotionAvailable && !motion.isDeviceMotionActive {
            motion.deviceMotionUpdateInterval = 1.0 / 30
            motion.startDeviceMotionUpdates()
        }
        sessionQueue.async { [self] in
            shortShutterSetting = shortShutter
            if !session.isRunning { session.startRunning() }
            applyShutter()
        }
    }

    func stop() {
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
        sessionQueue.async { [self] in
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

    func setDirection(_ direction: TravelDirection) {
        dataQueue.async { [self] in
            self.direction = direction
            estimator.travelSign = direction.bufferSign
            estimator.reset()
            tileHistory.removeAll()
        }
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
            guard let capture = calibration else { return }
            calibration = nil
            capture.completion(.failure(BaselineError.cancelled(reason)))
        }
    }

    // MARK: - Recording

    func startRecording(folder: URL, filtered: Bool, shortShutter: Bool, direction: TravelDirection) {
        dataQueue.async { [self] in
            pendingRecording = (folder, filtered, shortShutter, direction)
        }
    }

    func stopRecording(completion: @escaping @Sendable (Result<Finished, Error>) -> Void) {
        dataQueue.async { [self] in
            pendingRecording = nil
            guard let active = recorder else {
                completion(.failure(LineError.notEnoughData))
                return
            }
            recorder = nil
            let folder = active.folder
            active.finish { result in
                completion(result.map { Finished(folder: folder, info: $0) })
            }
        }
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
        let median = Self.centerMedian(millimetres, width: dw, height: dh)
        // Focal length in full-resolution video pixels (depth intrinsics scaled up to the video buffer).
        let fyVideo = Double(k.fy) * Double(videoHeight) / Double(max(dh, 1))

        // Speed from texture motion: pixels moved × (distance / focal length) / time.
        var shift: TextureShift?
        var rawSpeed: Double?
        let measured = estimator.process(pixelBuffer)
        var dt = 0.0
        if let last = lastTime { dt = (time - last).seconds }
        lastTime = time
        if let m = measured, dt > 0.001, dt < 1 {
            shift = m
            // Distance of the tracked area itself sets the mm-per-pixel scale.
            let trackedDistance = Self.regionMedian(millimetres, width: dw, height: dh,
                                                    regionX: m.regionX, regionY: m.regionY)
            let distance = trackedDistance > 0 ? trackedDistance : median
            if m.quality >= 0.1, fyVideo > 0, distance > 0 {
                rawSpeed = m.along * (distance / fyVideo) / dt
            }
        }
        // Local speeds per zone: zone movement × (zone distance / focal length) / time.
        let tileColumns = SpeedEstimator.tileColumns
        let tileRows = SpeedEstimator.tileRows
        let tiles = estimator.lastTiles
        var rawTiles = [Double?](repeating: nil, count: tileColumns * tileRows)
        if dt > 0.001, dt < 1, fyVideo > 0, tiles.count == rawTiles.count {
            for (i, tile) in tiles.enumerated() {
                guard let tile, tile.quality >= 0.12 else { continue }
                let c = i % tileColumns
                let r = i / tileColumns
                let zoneDistance = Self.regionMedian(
                    millimetres, width: dw, height: dh,
                    regionX: Double(c) / Double(tileColumns)...Double(c + 1) / Double(tileColumns),
                    regionY: Double(r) / Double(tileRows)...Double(r + 1) / Double(tileRows))
                let distance = zoneDistance > 0 ? zoneDistance : median
                guard distance > 0 else { continue }
                rawTiles[i] = tile.along * (distance / fyVideo) / dt
            }
        }
        tileHistory.append(rawTiles)
        if tileHistory.count > 15 { tileHistory.removeFirst(tileHistory.count - 15) }
        var smoothTiles = [Double?](repeating: nil, count: rawTiles.count)
        for i in 0..<rawTiles.count {
            var sum = 0.0
            var n = 0
            for frameTiles in tileHistory where i < frameTiles.count {
                if let v = frameTiles[i] {
                    sum += v
                    n += 1
                }
            }
            if n >= 4 { smoothTiles[i] = sum / Double(n) }
        }
        let fastest = Self.fastest(smoothTiles)
        let rawFastest = Self.fastest(rawTiles)

        if let v = rawSpeed { lastValidSpeed = v }
        if dt > 0, dt < 1 { travel += (rawSpeed ?? lastValidSpeed ?? 0) * dt }
        // Half-second rolling average of the valid readings (missing readings age out).
        recentSpeeds.append(rawSpeed ?? .nan)
        if recentSpeeds.count > 15 { recentSpeeds.removeFirst(recentSpeeds.count - 15) }
        let valid = recentSpeeds.filter { !$0.isNaN }
        let smoothed: Double? = valid.count >= 3 ? valid.reduce(0, +) / Double(valid.count) : rawSpeed
        var angle: Double?
        if let s = shift, abs(s.along) > 2 {
            angle = atan2(s.across, abs(s.along)) * 180 / .pi
        }

        // Live colour image (every second frame): heights above the baseline when one is set, else distance.
        var image: CGImage?
        var range: ClosedRange<Float>?
        let activeBaseline = baseline?.matches(width: dw, height: dh) == true ? baseline : nil
        if frameCounter % 2 == 0 {
            if let activeBaseline {
                let heights = activeBaseline.heights(millimetres)
                heights.withUnsafeBufferPointer { buffer in
                    if let r = DepthColors.finiteRange(buffer, step: 3) {
                        range = r
                        image = DepthColors.heightImage(buffer, width: dw, height: dh,
                                                        low: r.lowerBound, high: r.upperBound)
                    }
                    lastSpread = Self.spread(buffer, width: dw, height: dh)
                }
                lastCenterHeight = Self.centerMedian(heights, width: dw, height: dh, allowNegative: true)
            } else {
                millimetres.withUnsafeBufferPointer { buffer in
                    if let r = DepthColors.percentileRange(buffer, step: 3) {
                        range = r
                        image = DepthColors.image(millimetres: buffer, width: dw, height: dh,
                                                  near: r.lowerBound, far: r.upperBound)
                    }
                    lastSpread = Self.spread(buffer, width: dw, height: dh)
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
                    capture.tiltX.append(asin(max(-1, min(1, -g.x))) * 180 / .pi)
                    capture.tiltY.append(asin(max(-1, min(1, -g.y))) * 180 / .pi)
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
        if let pending = pendingRecording, recorder == nil {
            pendingRecording = nil
            recorder = try? LineRecorder(folder: pending.folder, videoWidth: videoWidth, videoHeight: videoHeight,
                                         depthWidth: dw, depthHeight: dh, filteredDepth: pending.filtered,
                                         shortShutter: pending.shortShutter, direction: pending.direction,
                                         travelOffset: travel)
            // Keep the baseline with the recording so its map and playback use the same reference.
            if recorder != nil, let activeBaseline {
                try? activeBaseline.save(to: pending.folder)
            }
        }
        // Level: gravity tilt every frame, LiDAR surface tilt every second frame.
        var tiltX: Double?
        var tiltY: Double?
        if let g = motion.deviceMotion?.gravity {
            tiltX = asin(max(-1, min(1, -g.x))) * 180 / .pi
            tiltY = asin(max(-1, min(1, -g.y))) * 180 / .pi
        }
        if frameCounter % 2 == 1 {
            surfaceTilt = Self.surfaceTilt(millimetres, width: dw, height: dh,
                                           fx: Double(k.fx), fy: Double(k.fy), cx: Double(k.cx), cy: Double(k.cy))
        }

        if let active = recorder {
            let info = LineFrameInfo(index: 0, time: 0, speed: rawSpeed, travel: travel,
                                     shiftPixels: shift?.along, crossShiftPixels: shift?.across,
                                     quality: shift?.quality ?? 0, medianDepth: median,
                                     fx: k.fx, fy: k.fy, cx: k.cx, cy: k.cy,
                                     tiltX: tiltX, tiltY: tiltY,
                                     surfaceTiltX: surfaceTilt?.x, surfaceTiltY: surfaceTilt?.y,
                                     tileSpeeds: rawTiles,
                                     fastestSpeed: rawFastest?.speed, fastestTile: rawFastest?.index)
            active.append(sampleBuffer: sampleBuffer, depthMillimetres: millimetres, info: info)
        }

        onUpdate?(LiveUpdate(speed: smoothed, rawSpeed: rawSpeed, quality: shift?.quality ?? 0,
                             medianDepth: median, travel: travel, angle: angle,
                             depthImage: image, depthRange: range,
                             recordedFrames: recorder?.frames.count ?? 0,
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
                             pictureAspect: Double(dh) / Double(max(dw, 1))))
    }

    /// Zone with the largest speed magnitude (signed speed returned).
    static func fastest(_ speeds: [Double?]) -> (speed: Double, index: Int)? {
        var best: (speed: Double, index: Int)?
        for (i, v) in speeds.enumerated() {
            guard let v else { continue }
            if best == nil || abs(v) > abs(best!.speed) { best = (v, i) }
        }
        return best
    }

    /// Std dev of the finite, positive-distance or any-height values in the central 80 % of the view.
    static func spread(_ values: UnsafeBufferPointer<Float>, width: Int, height: Int) -> Double? {
        var s = 0.0, ss = 0.0, n = 0.0
        var y = height / 10
        while y < height - height / 10 {
            var x = width / 10
            while x < width - width / 10 {
                let v = values[y * width + x]
                if v.isFinite && v != 0 {
                    let d = Double(v)
                    s += d
                    ss += d * d
                    n += 1
                }
                x += 3
            }
            y += 3
        }
        guard n > 20 else { return nil }
        let m = s / n
        return max(0, ss / n - m * m).squareRoot()
    }

    /// Fits a plane Z = a·X + b·Y + c to the depth points (mm, camera coordinates) and converts its slope
    /// to phone tilt relative to that surface. Depth columns run down the portrait screen, rows run right → left.
    static func surfaceTilt(_ millimetres: [Float], width: Int, height: Int,
                            fx: Double, fy: Double, cx: Double, cy: Double) -> (x: Double, y: Double)? {
        guard fx > 0, fy > 0, width > 16, height > 16 else { return nil }
        var n = 0.0, sx = 0.0, sy = 0.0, sz = 0.0
        var sxx = 0.0, syy = 0.0, sxy = 0.0, sxz = 0.0, syz = 0.0
        let border = max(2, min(width, height) / 16)
        var v = border
        while v < height - border {
            var u = border
            while u < width - border {
                let z = Double(millimetres[v * width + u])
                if z > 0 {
                    let x = (Double(u) - cx) * z / fx      // toward the bottom of the screen
                    let y = (Double(v) - cy) * z / fy      // toward the left of the screen
                    n += 1; sx += x; sy += y; sz += z
                    sxx += x * x; syy += y * y; sxy += x * y; sxz += x * z; syz += y * z
                }
                u += 4
            }
            v += 4
        }
        guard n >= 50 else { return nil }
        // Solve the 3×3 normal equations for (a, b, c) with Cramer's rule.
        let m = [[sxx, sxy, sx], [sxy, syy, sy], [sx, sy, n]]
        let r = [sxz, syz, sz]
        func det(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1])
                - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let d = det(m)
        guard abs(d) > 1e-9 else { return nil }
        var ma = m
        var mb = m
        for i in 0..<3 {
            ma[i][0] = r[i]
            mb[i][1] = r[i]
        }
        let a = det(ma) / d      // dZ per mm toward the screen bottom
        let b = det(mb) / d      // dZ per mm toward the screen left
        // Farther at the bottom = bottom edge high = top edge low; farther at the left = left edge high.
        let tiltY = -atan(a) * 180 / .pi
        let tiltX = -atan(b) * 180 / .pi
        guard tiltX.isFinite, tiltY.isFinite else { return nil }
        return (tiltX, tiltY)
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

    /// Median distance (mm) inside a normalized region of the depth map.
    static func regionMedian(_ millimetres: [Float], width: Int, height: Int,
                             regionX: ClosedRange<Double>, regionY: ClosedRange<Double>) -> Double {
        let x0 = max(0, min(width - 1, Int(regionX.lowerBound * Double(width))))
        let x1 = max(x0 + 1, min(width, Int(regionX.upperBound * Double(width))))
        let y0 = max(0, min(height - 1, Int(regionY.lowerBound * Double(height))))
        let y1 = max(y0 + 1, min(height, Int(regionY.upperBound * Double(height))))
        var samples: [Float] = []
        samples.reserveCapacity((x1 - x0) * (y1 - y0) / 4 + 1)
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                let z = millimetres[y * width + x]
                if z > 0 { samples.append(z) }
                x += 2
            }
            y += 2
        }
        guard samples.count >= 8 else { return 0 }
        samples.sort()
        return Double(samples[samples.count / 2])
    }

    /// Median of the central half of the map: distances (> 0), or heights (any finite value) with allowNegative.
    static func centerMedian(_ millimetres: [Float], width: Int, height: Int, allowNegative: Bool = false) -> Double {
        var samples: [Float] = []
        samples.reserveCapacity(width * height / 16)
        var y = height / 4
        while y < height * 3 / 4 {
            var x = width / 4
            while x < width * 3 / 4 {
                let z = millimetres[y * width + x]
                if allowNegative ? z.isFinite : z > 0 { samples.append(z) }
                x += 2
            }
            y += 2
        }
        guard !samples.isEmpty else { return 0 }
        samples.sort()
        return Double(samples[samples.count / 2])
    }
}
