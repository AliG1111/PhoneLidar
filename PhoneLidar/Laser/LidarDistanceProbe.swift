import Foundation
import AVFoundation

/// One-shot camera height for the laser line scan: the median LiDAR distance (mm) of the central 20 % of the view
/// over 30 depth frames (design §14.1). Runs its own capture session; the laser session must be stopped first.
final class LidarDistanceProbe: NSObject, AVCaptureDepthDataOutputDelegate, @unchecked Sendable {
    // @unchecked: all state is confined to `queue`.

    static var isSupported: Bool { LineCapturePipeline.isSupported }

    private let session = AVCaptureSession()
    private let output = AVCaptureDepthDataOutput()
    private let queue = DispatchQueue(label: "phonelidar.laser.lidarprobe")
    private var samples: [Double] = []
    private var completion: (@Sendable (Result<Double, Error>) -> Void)?
    private var frames = 0
    static let frameCount = 30

    /// Measures and calls `completion` once (on a background queue). Fails after 5 s without enough readings.
    func measure(completion: @escaping @Sendable (Result<Double, Error>) -> Void) {
        queue.async { [self] in
            self.completion = completion
            do {
                try configure()
            } catch {
                finish(.failure(error))
                return
            }
            session.startRunning()
            queue.asyncAfter(deadline: .now() + 5) { [self] in
                finish(.failure(LineError.configuration("The LiDAR gave too few readings. Check that the belt is "
                                                        + "in view, 0.3–4 m away.")))
            }
        }
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) else {
            throw LineError.configuration("This iPhone has no LiDAR. Enter the camera height instead.")
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw LineError.configuration("Cannot use the LiDAR camera.") }
        session.addInput(input)
        guard let format = device.formats.first(where: { !$0.supportedDepthDataFormats.isEmpty }),
              let depthFormat = format.supportedDepthDataFormats.first(where: {
                  CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
              }) ?? format.supportedDepthDataFormats.first else {
            throw LineError.configuration("No LiDAR depth format is available.")
        }
        try device.lockForConfiguration()
        device.activeFormat = format
        device.activeDepthDataFormat = depthFormat
        device.unlockForConfiguration()
        guard session.canAddOutput(output) else { throw LineError.configuration("Cannot read LiDAR depth.") }
        session.addOutput(output)
        output.isFilteringEnabled = true
        output.setDelegate(self, callbackQueue: queue)
    }

    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData,
                         timestamp: CMTime, connection: AVCaptureConnection) {
        guard completion != nil else { return }
        let depth = depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let map = depth.depthDataMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        // The central fifth of each side of the depth map.
        for y in (height * 2 / 5)..<(height * 3 / 5) {
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in (width * 2 / 5)..<(width * 3 / 5) {
                let metres = Double(row[x])
                if metres.isFinite && metres > 0.2 && metres < 6 { samples.append(metres * 1000) }
            }
        }
        frames += 1
        if frames >= Self.frameCount {
            guard samples.count >= 100 else {
                finish(.failure(LineError.configuration("The LiDAR gave too few readings. Check that the belt is "
                                                        + "in view, 0.3–4 m away.")))
                return
            }
            samples.sort()
            finish(.success(samples[samples.count / 2]))
        }
    }

    private func finish(_ result: Result<Double, Error>) {
        guard let done = completion else { return }
        completion = nil
        if session.isRunning { session.stopRunning() }
        done(result)
    }
}
