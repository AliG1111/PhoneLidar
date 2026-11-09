import Foundation
import AVFoundation

// MARK: - Errors

enum LineError: LocalizedError {
    case noLiDAR
    case configuration(String)
    case badFile
    case notEnoughData

    var errorDescription: String? {
        switch self {
        case .noLiDAR: return "This iPhone has no LiDAR depth camera."
        case .configuration(let message): return message
        case .badFile: return "The recording file is damaged or incomplete."
        case .notEnoughData: return "Not enough frames were recorded to build a map."
        }
    }
}

/// Which way the material moves across the portrait screen.
enum TravelDirection: String, Codable, CaseIterable, Identifiable {
    case rightToLeft
    case leftToRight

    var id: String { rawValue }

    /// +1 when material moves toward increasing rows of the camera buffer (right → left on a portrait screen).
    var bufferSign: Int { self == .rightToLeft ? 1 : -1 }

    var label: String { self == .rightToLeft ? "Right → Left" : "Left → Right" }
}

// MARK: - Recording metadata

/// One recorded frame. Depth intrinsics are in depth-map pixels; distances in millimetres.
struct LineFrameInfo: Codable {
    var index: Int
    var time: Double
    var speed: Double?
    var travel: Double
    var shiftPixels: Double?
    var crossShiftPixels: Double?
    var quality: Double
    var medianDepth: Double
    var fx: Float
    var fy: Float
    var cx: Float
    var cy: Float
    /// Phone tilt from gravity, degrees (+X right edge high, +Y top edge high).
    var tiltX: Double? = nil
    var tiltY: Double? = nil
    /// Phone tilt relative to the surface below, from the LiDAR plane fit.
    var surfaceTiltX: Double? = nil
    var surfaceTiltY: Double? = nil
}

/// Saved as Recording.json next to Video.mov and Depth.bin.
struct LineRecordingInfo: Codable {
    var depthWidth: Int
    var depthHeight: Int
    var videoWidth: Int
    var videoHeight: Int
    var filteredDepth: Bool
    var shortShutter: Bool
    var direction: TravelDirection
    var frames: [LineFrameInfo]
}

// MARK: - Speed text

enum SpeedText {
    static func main(_ mmPerSecond: Double?) -> String {
        guard let v = mmPerSecond else { return "— mm/s" }
        return String(format: "%.0f mm/s", v)
    }

    static func perMinute(_ mmPerSecond: Double?) -> String {
        guard let v = mmPerSecond else { return "no texture lock" }
        return String(format: "%.2f m/min  ·  %.1f ft/min", v * 0.06, v * 0.06 * 3.28084)
    }
}

enum LineMath {
    /// Centered moving average that skips missing values.
    static func smoothed(_ values: [Double?], radius: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: values.count)
        guard !values.isEmpty else { return out }
        for i in values.indices {
            let lo = max(0, i - radius)
            let hi = min(values.count - 1, i + radius)
            var sum = 0.0
            var n = 0
            for j in lo...hi {
                if let v = values[j] {
                    sum += v
                    n += 1
                }
            }
            out[i] = n > 0 ? sum / Double(n) : nil
        }
        return out
    }

    static func frameIndex(for time: Double, in frames: [LineFrameInfo]) -> Int {
        guard !frames.isEmpty else { return 0 }
        var lo = 0
        var hi = frames.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if frames[mid].time <= time { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

// MARK: - Binary helpers

extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { bytes in
            self.append(contentsOf: bytes)
        }
    }

    func readUInt32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i])
            | (UInt32(self[i + 1]) << 8)
            | (UInt32(self[i + 2]) << 16)
            | (UInt32(self[i + 3]) << 24)
    }
}

/// Buffered line-by-line text file writer (for large CSV files).
final class TextFileWriter {
    private let handle: FileHandle
    private var buffer = ""
    private var pending = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func line(_ text: String) throws {
        buffer += text
        buffer += "\n"
        pending += text.utf8.count + 1
        if pending > 1_000_000 { try flush() }
    }

    func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: Data(buffer.utf8))
        buffer = ""
        pending = 0
    }

    func close() throws {
        try flush()
        try handle.close()
    }
}

// MARK: - Depth file

/// Depth.bin: "PLDP", version, width, height (UInt32 little endian), then per frame
/// a UInt32 byte count followed by LZFSE-compressed UInt16 distances in 0.1 mm (0 = no data).
final class DepthFileWriter {
    let width: Int
    let height: Int
    private let handle: FileHandle
    private var scratch: [UInt16]

    init(url: URL, width: Int, height: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        self.width = width
        self.height = height
        scratch = [UInt16](repeating: 0, count: width * height)
        var header = Data("PLDP".utf8)
        header.appendUInt32(1)
        header.appendUInt32(UInt32(width))
        header.appendUInt32(UInt32(height))
        try handle.write(contentsOf: header)
    }

    /// `millimetres` is row-major, width × height, 0 = no data.
    func append(millimetres: [Float]) throws {
        let count = min(millimetres.count, scratch.count)
        for i in 0..<count {
            let mm = millimetres[i]
            if mm > 0 && mm < 6500 {
                scratch[i] = UInt16(mm * 10 + 0.5)
            } else {
                scratch[i] = 0
            }
        }
        let raw = scratch.withUnsafeBytes { Data($0) }
        let compressed = try (raw as NSData).compressed(using: .lzfse) as Data
        var record = Data()
        record.appendUInt32(UInt32(compressed.count))
        record.append(compressed)
        try handle.write(contentsOf: record)
    }

    func close() {
        try? handle.close()
    }
}

/// Reads Depth.bin. Immutable after init, so frames can be read from several threads at once.
final class DepthFileReader: @unchecked Sendable {
    let width: Int
    let height: Int
    private let data: Data
    private let offsets: [Int]
    private let lengths: [Int]

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= 16, String(decoding: data.prefix(4), as: UTF8.self) == "PLDP" else {
            throw LineError.badFile
        }
        width = Int(data.readUInt32(at: 8))
        height = Int(data.readUInt32(at: 12))
        guard width > 0, height > 0 else { throw LineError.badFile }
        var foundOffsets: [Int] = []
        var foundLengths: [Int] = []
        var cursor = 16
        while cursor + 4 <= data.count {
            let length = Int(data.readUInt32(at: cursor))
            let start = cursor + 4
            guard length > 0, start + length <= data.count else { break }
            foundOffsets.append(start)
            foundLengths.append(length)
            cursor = start + length
        }
        offsets = foundOffsets
        lengths = foundLengths
    }

    var frameCount: Int { offsets.count }

    private func decompressed(_ index: Int) -> Data? {
        guard index >= 0, index < offsets.count else { return nil }
        let start = data.startIndex + offsets[index]
        let slice = data.subdata(in: start..<(start + lengths[index]))
        guard let raw = try? (slice as NSData).decompressed(using: .lzfse) as Data,
              raw.count >= width * height * 2 else { return nil }
        return raw
    }

    /// Distances in millimetres, row-major width × height (0 = no data).
    func frame(_ index: Int) -> [Float]? {
        guard let raw = decompressed(index) else { return nil }
        var out = [Float](repeating: 0, count: width * height)
        raw.withUnsafeBytes { bytes in
            let values = bytes.bindMemory(to: UInt16.self)
            for i in 0..<out.count {
                out[i] = Float(UInt16(littleEndian: values[i])) * 0.1
            }
        }
        return out
    }

    /// Median distance (mm) of the valid pixels in a (2·radius+1)² window around (u, v) of one frame.
    func sample(_ index: Int, u: Int, v: Int, radius: Int) -> Float? {
        guard let raw = decompressed(index), u >= 0, u < width, v >= 0, v < height else { return nil }
        var values: [Float] = []
        values.reserveCapacity((2 * radius + 1) * (2 * radius + 1))
        raw.withUnsafeBytes { bytes in
            let p = bytes.bindMemory(to: UInt16.self)
            for y in max(0, v - radius)...min(height - 1, v + radius) {
                for x in max(0, u - radius)...min(width - 1, u + radius) {
                    let tenths = UInt16(littleEndian: p[y * width + x])
                    if tenths > 0 { values.append(Float(tenths) * 0.1) }
                }
            }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        return values[values.count / 2]
    }

    /// Same window median, on an already decoded frame.
    static func sample(_ millimetres: [Float], width: Int, height: Int, u: Int, v: Int, radius: Int) -> Float? {
        guard u >= 0, u < width, v >= 0, v < height, millimetres.count >= width * height else { return nil }
        var values: [Float] = []
        for y in max(0, v - radius)...min(height - 1, v + radius) {
            for x in max(0, u - radius)...min(width - 1, u + radius) {
                let z = millimetres[y * width + x]
                if z > 0 { values.append(z) }
            }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        return values[values.count / 2]
    }
}

// MARK: - Recorder

/// Writes Video.mov (HEVC, portrait), Depth.bin, Recording.json and Frames.csv.
final class LineRecorder {
    let folder: URL
    let videoWidth: Int
    let videoHeight: Int
    let depthWidth: Int
    let depthHeight: Int
    let filteredDepth: Bool
    let shortShutter: Bool
    let direction: TravelDirection

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let depthWriter: DepthFileWriter
    private let travelOffset: Double
    private var startTime: CMTime?
    private(set) var frames: [LineFrameInfo] = []

    var elapsed: Double { frames.last?.time ?? 0 }

    init(folder: URL, videoWidth: Int, videoHeight: Int, depthWidth: Int, depthHeight: Int,
         filteredDepth: Bool, shortShutter: Bool, direction: TravelDirection, travelOffset: Double) throws {
        self.folder = folder
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.depthWidth = depthWidth
        self.depthHeight = depthHeight
        self.filteredDepth = filteredDepth
        self.shortShutter = shortShutter
        self.direction = direction
        self.travelOffset = travelOffset

        writer = try AVAssetWriter(outputURL: folder.appendingPathComponent("Video.mov"), fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 16_000_000]
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = true
        // Camera buffers are landscape; rotate so the movie plays in portrait like the live view.
        videoInput.transform = CGAffineTransform(rotationAngle: .pi / 2)
        guard writer.canAdd(videoInput) else { throw LineError.configuration("Cannot record video.") }
        writer.add(videoInput)
        depthWriter = try DepthFileWriter(url: folder.appendingPathComponent("Depth.bin"),
                                          width: depthWidth, height: depthHeight)
    }

    func append(sampleBuffer: CMSampleBuffer, depthMillimetres: [Float], info: LineFrameInfo) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startTime == nil {
            startTime = pts
            _ = writer.startWriting()
            writer.startSession(atSourceTime: pts)
        }
        guard let start = startTime else { return }
        // Depth and frame data are kept even if the video encoder fails.
        if writer.status == .writing, videoInput.isReadyForMoreMediaData {
            _ = videoInput.append(sampleBuffer)
        }
        do {
            try depthWriter.append(millimetres: depthMillimetres)
        } catch {
            return
        }
        var frame = info
        frame.index = frames.count
        frame.time = (pts - start).seconds
        frame.travel = info.travel - travelOffset
        frames.append(frame)
    }

    func finish(completion: @escaping @Sendable (Result<LineRecordingInfo, Error>) -> Void) {
        depthWriter.close()
        let info = LineRecordingInfo(depthWidth: depthWidth, depthHeight: depthHeight,
                                     videoWidth: videoWidth, videoHeight: videoHeight,
                                     filteredDepth: filteredDepth, shortShutter: shortShutter,
                                     direction: direction, frames: frames)
        do {
            let json = try JSONEncoder.pretty.encode(info)
            try json.write(to: folder.appendingPathComponent("Recording.json"), options: .atomic)
            try framesCSV().write(to: folder.appendingPathComponent("Frames.csv"), atomically: true, encoding: .utf8)
        } catch {
            completion(.failure(error))
            return
        }
        guard writer.status == .writing else {
            writer.cancelWriting()
            completion(frames.count >= 2 ? .success(info) : .failure(LineError.notEnoughData))
            return
        }
        videoInput.markAsFinished()
        let count = frames.count
        writer.finishWriting {
            completion(count >= 2 ? .success(info) : .failure(LineError.notEnoughData))
        }
    }

    private func framesCSV() -> String {
        var rows: [[String]] = [["frame", "time_s", "speed_mm_s", "speed_m_min", "travel_mm",
                                 "shift_px", "cross_shift_px", "track_quality", "median_distance_mm",
                                 "tilt_x_deg", "tilt_y_deg", "surface_tilt_x_deg", "surface_tilt_y_deg"]]
        for f in frames {
            rows.append([
                "\(f.index)",
                String(format: "%.4f", f.time),
                f.speed.map { String(format: "%.1f", $0) } ?? "",
                f.speed.map { String(format: "%.3f", $0 * 0.06) } ?? "",
                String(format: "%.1f", f.travel),
                f.shiftPixels.map { String(format: "%.2f", $0) } ?? "",
                f.crossShiftPixels.map { String(format: "%.2f", $0) } ?? "",
                String(format: "%.3f", f.quality),
                String(format: "%.1f", f.medianDepth),
                f.tiltX.map { String(format: "%.2f", $0) } ?? "",
                f.tiltY.map { String(format: "%.2f", $0) } ?? "",
                f.surfaceTiltX.map { String(format: "%.2f", $0) } ?? "",
                f.surfaceTiltY.map { String(format: "%.2f", $0) } ?? ""
            ])
        }
        return CSV.make(rows)
    }
}
