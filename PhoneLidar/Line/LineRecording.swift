import Foundation
import AVFoundation
import CoreGraphics

// MARK: - Errors

enum LineError: LocalizedError {
    case noLiDAR
    case configuration(String)
    case badFile
    case notEnoughData
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noLiDAR: return "This iPhone has no LiDAR depth camera."
        case .configuration(let message): return message
        case .badFile: return "The recording file is damaged or incomplete."
        case .notEnoughData: return "Not enough frames were recorded to build a map."
        case .writeFailed: return "An earlier write to this file failed."
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
    /// Speed of each zone this frame (mm/s, + = travel direction), grid tileColumns × tileRows.
    var tileSpeeds: [Double?]? = nil
    /// Fastest zone this frame (mm/s, signed) and its index.
    var fastestSpeed: Double? = nil
    var fastestTile: Int? = nil
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
    /// Zone grid of the per-frame local speeds: columns across the material, rows along the travel.
    var tileColumns: Int? = nil
    var tileRows: Int? = nil
}

extension LineFrameInfo {
    /// The same frame with every non-finite number removed: Recording.json and the CSV files never get NaN or inf.
    func sanitized() -> LineFrameInfo {
        func finiteOrNil(_ v: Double?) -> Double? { v.flatMap { $0.isFinite ? $0 : nil } }
        func number(_ v: Double) -> Double { v.isFinite ? v : 0 }
        func single(_ v: Float) -> Float { v.isFinite ? v : 0 }
        var f = self
        f.time = number(time)
        f.speed = finiteOrNil(speed)
        f.travel = number(travel)
        f.shiftPixels = finiteOrNil(shiftPixels)
        f.crossShiftPixels = finiteOrNil(crossShiftPixels)
        f.quality = number(quality)
        f.medianDepth = number(medianDepth)
        f.fx = single(fx)
        f.fy = single(fy)
        f.cx = single(cx)
        f.cy = single(cy)
        f.tiltX = finiteOrNil(tiltX)
        f.tiltY = finiteOrNil(tiltY)
        f.surfaceTiltX = finiteOrNil(surfaceTiltX)
        f.surfaceTiltY = finiteOrNil(surfaceTiltY)
        f.tileSpeeds = tileSpeeds.map { speeds in speeds.map { finiteOrNil($0) } }
        f.fastestSpeed = finiteOrNil(fastestSpeed)
        if f.fastestSpeed == nil { f.fastestTile = nil }
        return f
    }
}

/// Recording.json without the frame list: the same keys as LineRecordingInfo, written first.
struct LineRecordingHeader: Encodable {
    var depthWidth: Int
    var depthHeight: Int
    var videoWidth: Int
    var videoHeight: Int
    var filteredDepth: Bool
    var shortShutter: Bool
    var direction: TravelDirection
    var tileColumns: Int
    var tileRows: Int
}

/// What a finished recording produced, for the scan summary.
struct LineRecordingResult: Sendable {
    var folder: URL
    var frameCount: Int
    var duration: Double
    var direction: TravelDirection
    /// Problems that did not stop the recording (video incomplete, a CSV file cut short, …), one line each.
    var notes: [String]
}

/// Free storage checks for recordings (~3–4 MB/s: HEVC video ≈ 2 MB/s plus compressed depth).
enum LineStorage {
    /// Recording does not start with less free space than this.
    static let minimumToStart: Int64 = 1_000_000_000
    /// A recording is stopped and saved when free space drops below this, leaving room to finish the files.
    static let stopBelow: Int64 = 300_000_000

    /// Free space for important data on the volume holding `url`, bytes (nil if unknown).
    static func freeBytes(at url: URL) -> Int64? {
        let fresh = URL(fileURLWithPath: url.path)     // new URL: resource values are cached per URL object
        guard let values = try? fresh.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else {
            return nil
        }
        return values.volumeAvailableCapacityForImportantUsage
    }

    /// "850 MB" or "1.0 GB".
    static func text(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000
            ? String(format: "%.1f GB", Double(bytes) / 1e9)
            : String(format: "%.0f MB", Double(max(bytes, 0)) / 1e6)
    }
}

// MARK: - Speed text

enum SpeedText {
    static func main(_ mmPerSecond: Double?) -> String {
        guard let v = mmPerSecond else { return "— mm/s" }
        return String(format: "%.0f mm/s", v)
    }

    /// "612 mm/s" or "— mm/s".
    static func short(_ mmPerSecond: Double?) -> String {
        guard let v = mmPerSecond else { return "— mm/s" }
        return String(format: "%.0f mm/s", v)
    }

    static func perMinute(_ mmPerSecond: Double?) -> String {
        guard let v = mmPerSecond else { return "no texture lock" }
        return String(format: "%.2f m/min  ·  %.1f ft/min", v * 0.06, v * 0.06 * 3.28084)
    }
}

/// Mapping between the speed-zone grid (buffer orientation) and the portrait picture.
/// Zone columns run across the material = top → bottom of the screen; zone rows run along the travel
/// = right → left of the screen (buffer row 0 is at the right edge of the portrait picture).
enum ZoneGrid {
    static var columns: Int { SpeedEstimator.tileColumns }
    static var rows: Int { SpeedEstimator.tileRows }

    /// Zone index under a point of the portrait picture (0…1 coordinates).
    static func tile(atDisplay point: CGPoint, columns: Int = columns, rows: Int = rows) -> Int {
        let across = Double(point.y)            // buffer x
        let along = 1 - Double(point.x)         // buffer y
        let c = min(columns - 1, max(0, Int(across * Double(columns))))
        let r = min(rows - 1, max(0, Int(along * Double(rows))))
        return r * columns + c
    }

    /// Zone index for a depth-map pixel.
    static func tile(u: Int, v: Int, width: Int, height: Int, columns: Int = columns, rows: Int = rows) -> Int {
        let c = min(columns - 1, max(0, u * columns / max(width, 1)))
        let r = min(rows - 1, max(0, v * rows / max(height, 1)))
        return r * columns + c
    }

    /// Centre of a zone in portrait-picture coordinates (0…1).
    static func displayCenter(ofTile index: Int, columns: Int = columns, rows: Int = rows) -> CGPoint? {
        guard index >= 0, index < columns * rows else { return nil }
        let c = index % columns
        let r = index / columns
        let across = (Double(c) + 0.5) / Double(columns)
        let along = (Double(r) + 0.5) / Double(rows)
        return CGPoint(x: 1 - along, y: across)
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
/// After the first failed write nothing more is written, so a file is never left with a repeated fragment.
final class TextFileWriter {
    private let handle: FileHandle
    private let flushBytes: Int
    private var buffer = ""
    private var pending = 0
    private var closed = false
    private(set) var failed = false

    init(url: URL, flushBytes: Int = 1_000_000) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        self.flushBytes = flushBytes
    }

    func line(_ text: String) throws {
        guard !failed, !closed else { throw LineError.writeFailed }
        buffer += text
        buffer += "\n"
        pending += text.utf8.count + 1
        if pending > flushBytes { try flush() }
    }

    func flush() throws {
        guard !failed else { throw LineError.writeFailed }
        guard !buffer.isEmpty, !closed else { return }
        let data = Data(buffer.utf8)
        buffer = ""
        pending = 0
        do {
            try handle.write(contentsOf: data)
        } catch {
            failed = true
            throw error
        }
    }

    func close() throws {
        guard !closed else { return }
        do {
            try flush()
        } catch {
            closed = true
            try? handle.close()
            throw error
        }
        closed = true
        try handle.close()
    }
}

/// Writes Recording.json while recording: the header and `"frames":[` on the first line, then one frame per
/// line, and `]}` when closed. Per-frame data is never held in memory, and a file cut off by a crash can be
/// repaired by dropping its incomplete last line (LineRecordingRepair). Readable by the normal decoder.
final class RecordingJSONWriter {
    private let file: TextFileWriter
    private let encoder = JSONEncoder()
    private var count = 0

    init(url: URL, header: LineRecordingHeader) throws {
        file = try TextFileWriter(url: url, flushBytes: 64_000)
        var text = String(decoding: try encoder.encode(header), as: UTF8.self)
        guard text.hasSuffix("}") else { throw LineError.badFile }
        text.removeLast()
        try file.line(text + ",\"frames\":[")
        try file.flush()      // header on disk at once, so even a very short cut-off recording can be repaired
    }

    /// `frame` must already be sanitized (the encoder refuses NaN and inf).
    func append(_ frame: LineFrameInfo) throws {
        let json = String(decoding: try encoder.encode(frame), as: UTF8.self)
        try file.line(count == 0 ? json : "," + json)
        count += 1
    }

    func close() throws {
        do {
            try file.line("]}")
        } catch {
            try? file.close()
            throw error
        }
        try file.close()
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

    /// `millimetres` is row-major, width × height, 0 = no data. Callers stop appending after an error
    /// (a cut-off last record is ignored by DepthFileReader).
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

/// Writes Video.mov (HEVC, portrait), Depth.bin, Recording.json, Frames.csv and ZoneSpeeds.csv while recording.
/// Every frame goes straight to disk, so memory use does not grow with the length of the recording.
/// Used only on the capture data queue until `finish`, which hands it to a background queue (no shared state).
final class LineRecorder: @unchecked Sendable {
    /// Hidden file present in the folder until the recording has been saved and Recording.json reads back.
    static let inProgressMarker = ".recording-in-progress"
    /// Movie fragment length: after a crash the video still plays up to the last complete fragment.
    static let videoFragmentSeconds = 5.0
    /// Free space is checked every this many frames (~5 s).
    static let storageCheckFrames = 150

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
    private let jsonWriter: RecordingJSONWriter
    private let framesWriter: TextFileWriter
    private let zonesWriter: TextFileWriter
    private let travelOffset: Double
    private var startTime: CMTime?
    private var videoDropped = 0
    private var notes: [String] = []

    /// Frames written to Depth.bin and Recording.json.
    private(set) var frameCount = 0
    /// Time of the last written frame since the first, seconds.
    private(set) var elapsed: Double = 0
    /// First video problem (the recording continues with depth and speed only).
    private(set) var videoProblem: String?
    /// Set when the recording must stop (a failed write or storage almost full); no more frames are taken.
    private(set) var stopReason: String?

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

        FileManager.default.createFile(atPath: folder.appendingPathComponent(LineRecorder.inProgressMarker).path,
                                       contents: nil)
        writer = try AVAssetWriter(outputURL: folder.appendingPathComponent("Video.mov"), fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: LineRecorder.videoFragmentSeconds, preferredTimescale: 600)
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
        let columns = SpeedEstimator.tileColumns
        let rows = SpeedEstimator.tileRows
        jsonWriter = try RecordingJSONWriter(
            url: folder.appendingPathComponent("Recording.json"),
            header: LineRecordingHeader(depthWidth: depthWidth, depthHeight: depthHeight,
                                        videoWidth: videoWidth, videoHeight: videoHeight,
                                        filteredDepth: filteredDepth, shortShutter: shortShutter,
                                        direction: direction, tileColumns: columns, tileRows: rows))
        framesWriter = try TextFileWriter(url: folder.appendingPathComponent("Frames.csv"), flushBytes: 64_000)
        zonesWriter = try TextFileWriter(url: folder.appendingPathComponent("ZoneSpeeds.csv"), flushBytes: 64_000)
        try framesWriter.line(LineRecorder.framesHeader.joined(separator: ","))
        try zonesWriter.line(LineRecorder.zonesHeader(columns: columns, rows: rows).joined(separator: ","))
    }

    /// Adds a line to the scan summary.
    func addNote(_ note: String) {
        notes.append(note)
    }

    func append(sampleBuffer: CMSampleBuffer, depthMillimetres: [Float], info: LineFrameInfo) {
        guard stopReason == nil else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startTime == nil {
            startTime = pts
            if writer.startWriting() {
                writer.startSession(atSourceTime: pts)
            } else {
                noteVideoProblem("the video encoder did not start")
            }
        }
        guard let start = startTime else { return }
        // Depth and frame data are kept even if the video encoder fails.
        switch writer.status {
        case .writing:
            if videoInput.isReadyForMoreMediaData {
                if !videoInput.append(sampleBuffer) {
                    if writer.status == .failed { noteVideoProblem("the video encoder stopped") } else { videoDropped += 1 }
                }
            } else {
                videoDropped += 1
            }
        case .failed:
            noteVideoProblem("the video encoder stopped")
        default:
            break
        }

        var frame = info
        frame.index = frameCount
        frame.time = (pts - start).seconds
        frame.travel = info.travel - travelOffset
        frame = frame.sanitized()
        do {
            try depthWriter.append(millimetres: depthMillimetres)
            try jsonWriter.append(frame)
            try framesWriter.line(Self.framesRow(frame))
            try zonesWriter.line(Self.zonesRow(frame, count: SpeedEstimator.tileColumns * SpeedEstimator.tileRows))
        } catch {
            stopReason = "the recording could not be written to storage (\(error.localizedDescription))"
            return
        }
        frameCount += 1
        elapsed = frame.time
        if frameCount % Self.storageCheckFrames == 0,
           let free = LineStorage.freeBytes(at: folder), free < LineStorage.stopBelow {
            stopReason = "iPhone storage is almost full (\(LineStorage.text(free)) left)"
        }
    }

    private func noteVideoProblem(_ what: String) {
        guard videoProblem == nil else { return }
        if let error = writer.error {
            videoProblem = "\(what) (\(error.localizedDescription))"
        } else {
            videoProblem = what
        }
    }

    /// Finishes the video first, then closes the data files on a background queue and calls `completion` once.
    /// Call only after the recorder has been taken off the capture queue.
    func finish(completion: @escaping @Sendable (LineRecordingResult) -> Void) {
        let queue = DispatchQueue(label: "phonelidar.line.finish", qos: .userInitiated)
        if writer.status == .writing {
            videoInput.markAsFinished()
            writer.finishWriting { [self] in
                queue.async { self.closeFiles(completion) }
            }
        } else {
            queue.async { self.closeFiles(completion) }
        }
    }

    private func closeFiles(_ completion: @Sendable (LineRecordingResult) -> Void) {
        if startTime != nil, writer.status != .completed {
            noteVideoProblem("the video could not be finished")
        }
        depthWriter.close()
        // A Recording.json left without its ending is repaired when it is read back (LineRecordingRepair).
        try? jsonWriter.close()
        do {
            try framesWriter.close()
        } catch {
            notes.append("Frames.csv is incomplete (\(error.localizedDescription)).")
        }
        do {
            try zonesWriter.close()
        } catch {
            notes.append("ZoneSpeeds.csv is incomplete (\(error.localizedDescription)).")
        }
        if let videoProblem {
            notes.insert("Video incomplete: \(videoProblem). Depth, speed and map data are not affected.", at: 0)
        } else if videoDropped > 0 {
            notes.insert(String(format: "Video: %ld of %ld frames skipped by the busy encoder (depth, speed and map data are complete).",
                                videoDropped, frameCount), at: 0)
        }
        completion(LineRecordingResult(folder: folder, frameCount: frameCount, duration: elapsed,
                                       direction: direction, notes: notes))
    }

    // MARK: CSV rows

    static let framesHeader = ["frame", "time_s", "speed_mm_s", "speed_m_min", "travel_mm",
                               "shift_px", "cross_shift_px", "track_quality", "median_distance_mm",
                               "tilt_x_deg", "tilt_y_deg", "surface_tilt_x_deg", "surface_tilt_y_deg",
                               "fastest_speed_mm_s", "fastest_zone"]

    /// One column per zone. Zone n: column n % 6 across the material (0 = top of the screen),
    /// row n / 6 along the travel (0 = right edge of the screen). Values mm/s, + = travel direction.
    static func zonesHeader(columns: Int, rows: Int) -> [String] {
        var header = ["frame", "time_s"]
        for i in 0..<(columns * rows) {
            header.append("zone\(i)_across\(i % columns)_along\(i / columns)_mm_s")
        }
        return header
    }

    /// `f` must be sanitized (no NaN / inf).
    static func framesRow(_ f: LineFrameInfo) -> String {
        func fixed(_ value: Double?, _ format: String) -> String {
            guard let value else { return "" }
            return String(format: format, value)
        }
        var fields: [String] = []
        fields.reserveCapacity(framesHeader.count)
        fields.append(String(f.index))
        fields.append(fixed(f.time, "%.4f"))
        fields.append(fixed(f.speed, "%.1f"))
        fields.append(fixed(f.speed.map { $0 * 0.06 }, "%.3f"))
        fields.append(fixed(f.travel, "%.1f"))
        fields.append(fixed(f.shiftPixels, "%.2f"))
        fields.append(fixed(f.crossShiftPixels, "%.2f"))
        fields.append(fixed(f.quality, "%.3f"))
        fields.append(fixed(f.medianDepth, "%.1f"))
        fields.append(fixed(f.tiltX, "%.2f"))
        fields.append(fixed(f.tiltY, "%.2f"))
        fields.append(fixed(f.surfaceTiltX, "%.2f"))
        fields.append(fixed(f.surfaceTiltY, "%.2f"))
        fields.append(fixed(f.fastestSpeed, "%.1f"))
        fields.append(f.fastestTile.map { String($0) } ?? "")
        return fields.joined(separator: ",")
    }

    static func zonesRow(_ f: LineFrameInfo, count: Int) -> String {
        var line = ["\(f.index)", String(format: "%.4f", f.time)]
        let speeds = f.tileSpeeds ?? []
        for i in 0..<count {
            if i < speeds.count, let v = speeds[i] {
                line.append(String(format: "%.1f", v))
            } else {
                line.append("")
            }
        }
        return line.joined(separator: ",")
    }
}
