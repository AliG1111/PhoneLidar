import Foundation

/// Settings and calibration of a laser line recording: `LaserRecording.json` (design §14.6). Written at Record
/// (`frameCount` nil) and again at Stop.
struct LaserRecordingInfo: Codable {
    var version: Int = 1
    var videoWidth: Int
    var videoHeight: Int
    /// Requested and delivered frame rate, frames/s.
    var frameRate: Double
    var activeFrameRate: Double
    var direction: TravelDirection
    var columnFirst: Int
    var columnStride: Int
    var columnCount: Int
    /// Intrinsics of the video buffer, px.
    var fx: Double
    var fy: Double
    var cx: Double
    var cy: Double
    /// Longest exposure allowed, s.
    var shutterLimit: Double
    var exposureBias: Double
    /// Search range above the belt, mm.
    var maxHeight: Double
    var mapMethod: MapMethod
    var calibration: LaserCalibration
    var frameCount: Int?
    var duration: Double?
    var droppedFrames: Int?
    var stopReason: String?

    static let fileName = "LaserRecording.json"

    var columns: LaserColumns {
        LaserColumns(first: columnFirst, stride: columnStride, count: columnCount)
    }

    static func exists(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(fileName).path)
    }

    static func load(from folder: URL) throws -> LaserRecordingInfo {
        let data = try Data(contentsOf: folder.appendingPathComponent(fileName))
        return try JSONDecoder.iso.decode(LaserRecordingInfo.self, from: data)
    }

    func save(to folder: URL) throws {
        try JSONEncoder.pretty.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// "1,234 profiles, 5.1 s at 240 fps, material travel Right → Left".
    var summaryLine: String {
        Self.summaryLine(frames: frameCount ?? 0, duration: duration ?? 0, fps: activeFrameRate, direction: direction)
    }

    static func summaryLine(frames: Int, duration: Double, fps: Double, direction: TravelDirection) -> String {
        String(format: "%ld profiles, %.1f s at %.0f fps, material travel %@", frames, duration, fps, direction.label)
    }

    static func isSummaryLine(_ line: String) -> Bool {
        line.range(of: "^[0-9]+ profiles, -?[0-9]+\\.[0-9] s at [0-9]+ fps, material travel ",
                   options: .regularExpression) != nil
    }
}

/// `Profiles.bin` constants and value coding (design §14.6).
enum ProfilesFile {
    static let fileName = "Profiles.bin"
    static let magic: [UInt8] = Array("PLLP".utf8)
    static let version: UInt32 = 1
    static let headerSize = 32
    /// Rows are stored in 1/rowScale px.
    static let rowScale: UInt32 = 32
    static let noRow: UInt16 = 0xFFFF
    /// Record flag: frame went through texture tracking.
    static let trackedFlag: UInt32 = 1
    /// Record flag: the tracking gave a speed.
    static let speedFlag: UInt32 = 2

    static func recordSize(columns: Int) -> Int { 24 + 2 * columns }

    /// Row (px) → stored value; NaN, negative or too large rows → `noRow`.
    @inline(__always)
    static func encode(row: Float) -> UInt16 {
        guard row.isFinite, row >= 0 else { return noRow }
        let scaled = (row * Float(rowScale)).rounded()
        guard scaled < Float(noRow) else { return noRow }
        return UInt16(scaled)
    }

    @inline(__always)
    static func decode(row: UInt16) -> Float {
        row == noRow ? .nan : Float(row) / Float(rowScale)
    }
}

/// Streams `Profiles.bin` (fixed-size records, buffered, written in blocks). Confined to one queue. After the first
/// failed write nothing more is written.
final class ProfilesFileWriter {
    let columns: LaserColumns
    private let handle: FileHandle
    private let flushBytes: Int
    private var buffer = Data()
    private var closed = false
    private(set) var failed = false
    private(set) var recordCount = 0

    init(url: URL, columns: LaserColumns, flushBytes: Int = 256_000) throws {
        guard columns.count > 0 else { throw LineError.badFile }
        self.columns = columns
        self.flushBytes = max(ProfilesFile.recordSize(columns: columns.count), flushBytes)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        var header = Data(ProfilesFile.magic)
        for value in [ProfilesFile.version, UInt32(columns.count), UInt32(columns.first), UInt32(columns.stride),
                      ProfilesFile.rowScale, 0, 0] {
            header.appendUInt32(value)
        }
        do {
            try handle.write(contentsOf: header)
        } catch {
            try? handle.close()
            throw error
        }
        buffer.reserveCapacity(self.flushBytes + ProfilesFile.recordSize(columns: columns.count))
    }

    /// Appends one frame. `rows` must hold `columns.count` values (buffer px, NaN = no detection).
    func append(time: Double, travel: Double, speed: Double?, flags: UInt32, rows: [Float]) throws {
        guard !failed, !closed else { throw LineError.writeFailed }
        guard rows.count == columns.count else { throw LineError.badFile }
        appendFloat64(time)
        appendFloat64(travel)
        let s = Float(speed ?? .nan)
        withUnsafeBytes(of: (s.isFinite ? s : .nan).bitPattern.littleEndian) { buffer.append(contentsOf: $0) }
        buffer.appendUInt32(flags)
        for row in rows {
            withUnsafeBytes(of: ProfilesFile.encode(row: row).littleEndian) { buffer.append(contentsOf: $0) }
        }
        recordCount += 1
        if buffer.count >= flushBytes { try flush() }
    }

    private func appendFloat64(_ value: Double) {
        withUnsafeBytes(of: (value.isFinite ? value : 0).bitPattern.littleEndian) { buffer.append(contentsOf: $0) }
    }

    func flush() throws {
        guard !failed else { throw LineError.writeFailed }
        guard !buffer.isEmpty, !closed else { return }
        do {
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        } catch {
            failed = true
            throw error
        }
    }

    func close() throws {
        guard !closed else { return }
        defer {
            closed = true
            try? handle.close()
        }
        try flush()
        try handle.synchronize()
    }
}

/// Reads `Profiles.bin` (memory-mapped). A cut-off last record is ignored.
final class ProfilesFileReader: @unchecked Sendable {     // immutable after init
    let columns: LaserColumns
    let frameCount: Int
    private let data: Data
    private let recordSize: Int

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= ProfilesFile.headerSize,
              Array(data.prefix(4)) == ProfilesFile.magic,
              data.readUInt32(at: 4) == ProfilesFile.version,
              data.readUInt32(at: 20) == ProfilesFile.rowScale else { throw LineError.badFile }
        let count = Int(data.readUInt32(at: 8))
        let first = Int(data.readUInt32(at: 12))
        let stride = Int(data.readUInt32(at: 16))
        guard count > 0, count <= 16_384, stride > 0, stride <= 64, first < 16_384 else { throw LineError.badFile }
        columns = LaserColumns(first: first, stride: stride, count: count)
        recordSize = ProfilesFile.recordSize(columns: count)
        frameCount = (data.count - ProfilesFile.headerSize) / recordSize
        self.data = data
    }

    private func offset(_ index: Int) -> Int { ProfilesFile.headerSize + index * recordSize }

    /// Runs `body` with the file's bytes and a decoder of its records (fast access for map building).
    func withRecords<R>(_ body: (Records) throws -> R) rethrows -> R {
        try data.withUnsafeBytes { raw in
            try body(Records(raw: raw, recordSize: recordSize, columns: columns.count))
        }
    }

    /// Decodes records from the raw file bytes; valid only inside `withRecords`.
    struct Records {
        let raw: UnsafeRawBufferPointer
        let recordSize: Int
        let columns: Int

        @inline(__always)
        private func base(_ index: Int) -> Int { ProfilesFile.headerSize + index * recordSize }

        @inline(__always)
        func time(_ index: Int) -> Double {
            Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: base(index), as: UInt64.self)))
        }

        @inline(__always)
        func travel(_ index: Int) -> Double {
            Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: base(index) + 8,
                                                                      as: UInt64.self)))
        }

        @inline(__always)
        func speed(_ index: Int) -> Double? {
            let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: base(index) + 16, as: UInt32.self))
            let value = Float(bitPattern: bits)
            return value.isFinite ? Double(value) : nil
        }

        @inline(__always)
        func flags(_ index: Int) -> UInt32 {
            UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: base(index) + 20, as: UInt32.self))
        }

        @inline(__always)
        func row(_ index: Int, _ k: Int) -> Float {
            ProfilesFile.decode(row: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: base(index) + 24 + 2 * k,
                                                                           as: UInt16.self)))
        }
    }

    /// Time of frame `index` (s from the first frame).
    func time(_ index: Int) -> Double { withRecords { $0.time(index) } }

    /// Travel at frame `index`, mm.
    func travel(_ index: Int) -> Double { withRecords { $0.travel(index) } }

    /// Speed reading of frame `index` (mm/s), nil when the frame had none.
    func speed(_ index: Int) -> Double? { withRecords { $0.speed(index) } }

    func flags(_ index: Int) -> UInt32 { withRecords { $0.flags(index) } }

    /// Detected row (buffer px) of profile column `k` in frame `index`, NaN = none.
    func row(_ index: Int, _ k: Int) -> Float { withRecords { $0.row(index, k) } }

    /// All rows of frame `index`.
    func rows(_ index: Int) -> [Float] {
        withRecords { records in (0..<columns.count).map { records.row(index, $0) } }
    }
}

/// `LaserFrames.csv` rows (design §14.6).
enum LaserFramesCSV {
    static let fileName = "LaserFrames.csv"
    static let header = ["frame", "time_s", "speed_mm_s", "travel_mm", "detected_pct", "median_height_mm",
                         "max_height_mm"]

    static func row(frame: Int, time: Double, speed: Double?, travel: Double, detectedPercent: Double,
                    medianHeight: Double?, maxHeight: Double?) -> String {
        func fixed(_ value: Double?, _ format: String) -> String {
            guard let value, value.isFinite else { return "" }
            return String(format: format, value)
        }
        return [
            "\(frame)", String(format: "%.5f", time), fixed(speed, "%.1f"), String(format: "%.2f", travel),
            String(format: "%.1f", detectedPercent), fixed(medianHeight, "%.2f"), fixed(maxHeight, "%.2f")
        ].joined(separator: ",")
    }
}
