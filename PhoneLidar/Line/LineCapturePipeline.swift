import Foundation
import AVFoundation
import CoreGraphics

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

    // Data-queue state
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
        sessionQueue.async { [self] in
            if !session.isRunning { session.startRunning() }
            // Let auto exposure settle before switching to a short shutter.
            sessionQueue.asyncAfter(deadline: .now() + 1.0) { [self] in
                applyShutter(short: shortShutter)
            }
        }
    }

    func stop() {
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
            applyShutter(short: enabled)
        }
    }

    func setDirection(_ direction: TravelDirection) {
        dataQueue.async { [self] in
            self.direction = direction
            estimator.travelSign = direction.bufferSign
            estimator.reset()
        }
    }

    private func applyShutter(short: Bool) {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if short, device.isExposureModeSupported(.custom) {
                let format = device.activeFormat
                var target = CMTime(value: 1, timescale: 1000)
                if CMTimeCompare(target, format.minExposureDuration) < 0 { target = format.minExposureDuration }
                if CMTimeCompare(target, format.maxExposureDuration) > 0 { target = format.maxExposureDuration }
                let current = device.exposureDuration.seconds > 0 ? device.exposureDuration.seconds : 1.0 / 60
                let gain = Float(current / max(target.seconds, 0.00001))
                let iso = min(format.maxISO, max(format.minISO, device.iso * gain))
                device.setExposureModeCustom(duration: target, iso: iso, completionHandler: nil)
            } else if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        } catch {
            // Keep whatever exposure mode is active.
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

        // Speed from texture motion: pixels moved × (distance / focal length) / time.
        var shift: TextureShift?
        var rawSpeed: Double?
        let measured = estimator.process(pixelBuffer)
        var dt = 0.0
        if let last = lastTime { dt = (time - last).seconds }
        lastTime = time
        if let m = measured, dt > 0.001, dt < 1, median > 0 {
            shift = m
            let fyVideo = Double(k.fy) * Double(videoHeight) / Double(dh)
            if m.quality >= 0.1, fyVideo > 0 {
                rawSpeed = m.along * (median / fyVideo) / dt
            }
        }
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

        // Live colour image (every second frame).
        var image: CGImage?
        var range: ClosedRange<Float>?
        if frameCounter % 2 == 0 {
            millimetres.withUnsafeBufferPointer { buffer in
                if let r = DepthColors.percentileRange(buffer, step: 3) {
                    range = r
                    image = DepthColors.image(millimetres: buffer, width: dw, height: dh,
                                              near: r.lowerBound, far: r.upperBound)
                }
            }
        }

        // Recording.
        if let pending = pendingRecording, recorder == nil {
            pendingRecording = nil
            recorder = try? LineRecorder(folder: pending.folder, videoWidth: videoWidth, videoHeight: videoHeight,
                                         depthWidth: dw, depthHeight: dh, filteredDepth: pending.filtered,
                                         shortShutter: pending.shortShutter, direction: pending.direction,
                                         travelOffset: travel)
        }
        if let active = recorder {
            let info = LineFrameInfo(index: 0, time: 0, speed: rawSpeed, travel: travel,
                                     shiftPixels: shift?.along, crossShiftPixels: shift?.across,
                                     quality: shift?.quality ?? 0, medianDepth: median,
                                     fx: k.fx, fy: k.fy, cx: k.cx, cy: k.cy)
            active.append(sampleBuffer: sampleBuffer, depthMillimetres: millimetres, info: info)
        }

        onUpdate?(LiveUpdate(speed: smoothed, rawSpeed: rawSpeed, quality: shift?.quality ?? 0,
                             medianDepth: median, travel: travel, angle: angle,
                             depthImage: image, depthRange: range,
                             recordedFrames: recorder?.frames.count ?? 0,
                             elapsed: recorder?.elapsed ?? 0))
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

    /// Median distance (mm) of the central half of the depth map.
    static func centerMedian(_ millimetres: [Float], width: Int, height: Int) -> Double {
        var samples: [Float] = []
        samples.reserveCapacity(width * height / 16)
        var y = height / 4
        while y < height * 3 / 4 {
            var x = width / 4
            while x < width * 3 / 4 {
                let z = millimetres[y * width + x]
                if z > 0 { samples.append(z) }
                x += 2
            }
            y += 2
        }
        guard !samples.isEmpty else { return 0 }
        samples.sort()
        return Double(samples[samples.count / 2])
    }
}
