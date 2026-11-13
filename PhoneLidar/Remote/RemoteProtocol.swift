import Foundation

// Pure protocol types of the phone-to-phone remote link (design §6.15). Foundation only; compiled by the test target.

/// Fixed values of the remote link.
enum RemoteLinkConstants {
    /// Bonjour service type (also listed under `NSBonjourServices` in Info.plist).
    static let serviceType = "_phonelidar._tcp"
    /// Handshake protocol version; both phones must run the same version.
    static let protocolVersion = 1
    /// Largest frame accepted before the handshake has finished, bytes.
    static let handshakeFrameLimit = 4_096
    /// Largest frame accepted afterwards: a 256 KiB chunk plus headers, or a scan list. 1 MiB + 1 KiB.
    static let frameLimit = 1_049_600
    /// File chunk size, bytes.
    static let chunkSize = 262_144
    /// Most file bytes the scanner sends before the remote has acknowledged them.
    static let ackWindow: Int64 = 2_097_152
    /// Scanner status period, s.
    static let statusInterval: Double = 0.25
    /// A side that has sent nothing for this long sends a ping, s.
    static let pingInterval: Double = 1
    /// A connection that received nothing for this long is closed, s.
    static let linkTimeout: Double = 8
    /// A handshake that has not finished after this long is closed, s.
    static let handshakeTimeout: Double = 10
    /// The remote stops waiting for a command answer after this long, s.
    static let commandTimeout: Double = 5
    /// The scanner restarts a failed listener after this delay, s.
    static let listenerRestartDelay: Double = 2
    /// Remote reconnect delays after consecutive failures, s (the last value repeats).
    static let reconnectDelays: [Double] = [1, 2, 4, 5]
    /// Free space a copy must leave on the remote phone, bytes.
    static let freeSpaceMargin: Int64 = 500_000_000
    /// Most scans in one scan list (newest first).
    static let maxListedScans = 200
    /// Most handshakes the scanner runs at the same time (a new one replaces the oldest).
    static let maxPendingConnections = 4
    /// The scanner closes an accepted connection that has not sent its hello after this long, s.
    static let helloTimeout: Double = 3
    /// Largest scan a remote accepts from a scan list, bytes (1 TB).
    static let maxScanBytes: Int64 = 1_000_000_000_000
}

/// Errors of the remote link's pure logic.
enum RemoteLinkError: LocalizedError, Equatable {
    case frameTooLarge(Int)
    case badHandshake
    case badRecord
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .frameTooLarge(let length): return "The other phone sent a frame that is too large (\(length) bytes)."
        case .badHandshake: return "The other phone sent an unexpected connection message."
        case .badRecord: return "The other phone sent a damaged message."
        case .authenticationFailed: return "A message from the other phone failed its security check."
        }
    }
}

// MARK: - Status

/// State of the scanner's Line scan screen, as shown on the remote.
enum RemotePhase: String, Codable, Sendable {
    /// The Line scan screen is not open on the scanner.
    case closed
    case starting
    case ready
    /// Start accepted; waiting for the first frame.
    case arming
    case recording
    case saving
    case building
    case failed
}

/// Camera system load on the scanner (`LinePressure`).
enum RemoteHeat: String, Codable, Sendable {
    case normal
    case serious
    case critical
}

/// Commands the remote can send.
enum RemoteAction: String, Codable, Sendable {
    case startRecording
    case stopRecording
}

/// Everything the remote shows about the scanner. Lengths in mm, speeds in mm/s, time in s, angles in degrees.
struct RemoteStatus: Codable, Equatable, Sendable {
    var lineScanOpen = false
    var phase: RemotePhase = .closed
    /// Text of a failed Line scan screen (camera off, configuration error).
    var failure: String?
    /// Recording time, s.
    var elapsed: Double = 0
    var frames: Int = 0
    /// Displayed speed (0.5 s average), mm/s.
    var speed: Double?
    /// Texture lock, 0…1.
    var lock: Double = 0
    /// Median distance to the surface, mm.
    var distance: Double?
    var heightMode = false
    /// Height above the baseline in the centre of the view, mm.
    var centerHeight: Double?
    /// The scanner's height reference is ready (the key keeps its pre-P16 name: a baseline, camera height or wall
    /// calibration).
    var baselineSaved = false
    var calibrating = false
    /// Bubble level (gravity minus the saved zero), degrees. +X = right edge high, +Y = top edge high.
    var levelX: Double?
    var levelY: Double?
    /// Camera or heat banner of the Line scan screen.
    var banner: String?
    /// Warnings kept on screen while recording.
    var warnings: [String] = []
    /// Last start/stop notice of the Line scan screen.
    var notice: String?
    var heat: RemoteHeat = .normal
    /// Free storage on the scanner, bytes.
    var freeBytes: Int64?
    /// Battery level 0…1.
    var battery: Double?
    var charging: Bool?
    /// Changes whenever the scanner's list of copyable scans changes.
    var scansVersion: Int = 0

    /// Status of a scanner whose Line scan screen is not open.
    static let closed = RemoteStatus()

    /// True while the scanner records, saves or builds a map: no files are sent then.
    var isBusy: Bool {
        switch phase {
        case .arming, .recording, .saving, .building: return true
        case .closed, .starting, .ready, .failed: return false
        }
    }

    /// The same status with every non-finite number removed (`JSONEncoder` throws on NaN and ∞) and time and frame
    /// count bounded, so a received status cannot make a view's integer conversion trap.
    func sanitized() -> RemoteStatus {
        func finite(_ value: Double?) -> Double? {
            guard let value, value.isFinite else { return nil }
            return value
        }
        var copy = self
        copy.elapsed = elapsed.isFinite ? min(max(elapsed, 0), 1e9) : 0
        copy.frames = max(frames, 0)
        copy.speed = finite(speed)
        copy.lock = lock.isFinite ? min(max(lock, 0), 1) : 0
        copy.distance = finite(distance)
        copy.centerHeight = finite(centerHeight)
        copy.levelX = finite(levelX)
        copy.levelY = finite(levelY)
        copy.battery = finite(battery)
        return copy
    }
}

// MARK: - Scans and files

/// One file of a scan on the scanner.
struct RemoteFileInfo: Codable, Equatable, Sendable {
    /// Plain file name inside the scan folder.
    var name: String
    /// Bytes.
    var size: Int64
    /// Modification time, seconds since 1970.
    var modified: Double
}

/// A saved Line scan the remote can copy.
struct RemoteScanInfo: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var created: Date
    var summary: [String]
    var files: [RemoteFileInfo]

    /// Sum of the file sizes; negative sizes count as 0 and an overflow gives `Int64.max` (sizes come from the
    /// other phone).
    var totalBytes: Int64 {
        files.reduce(Int64(0)) { total, file in
            let (sum, overflow) = total.addingReportingOverflow(max(file.size, 0))
            return overflow ? Int64.max : sum
        }
    }
}

/// The newest scans whose encoded `scans` message fits in one frame.
enum RemoteScanList {
    /// Largest record of a scan list, bytes: the frame limit minus room for the tag and headers.
    static var recordLimit: Int { RemoteLinkConstants.frameLimit - 1_024 }

    /// One entry per scan ID, the first (newest) kept: a folder duplicated in the Files app has the same ID.
    static func uniqueByID(_ scans: [RemoteScanInfo]) -> [RemoteScanInfo] {
        var seen = Set<UUID>()
        return scans.filter { seen.insert($0.id).inserted }
    }

    /// Keeps the newest scans (the list is newest first, at most `maxListedScans`) so the record fits `limit`.
    static func fitting(_ scans: [RemoteScanInfo], limit: Int = recordLimit) -> [RemoteScanInfo] {
        var list = Array(scans.prefix(RemoteLinkConstants.maxListedScans))
        while !list.isEmpty {
            guard let size = try? RemoteRecord.message(.scans(list)).count else { return [] }
            if size <= limit { return list }
            // Drop the oldest scans in proportion to the excess, at least one per pass.
            let keep = min(list.count - 1, Int(Double(list.count) * Double(limit) / Double(size)))
            list = Array(list.prefix(max(keep, 0)))
        }
        return list
    }
}

/// Bonjour service names of scanners (NFR-SEC-06). Bonjour renames a service whose name is already taken by adding
/// " (2)", " (3)", …, so a phone copying the scanner's name under its own ID appears as "iPhone 1A2B (2)", or takes
/// the name first and pushes the real scanner to "(2)". Names are compared without that suffix.
enum RemoteServiceName {
    /// `name` without a trailing Bonjour rename suffix " (n)" (n = digits).
    static func base(_ name: String) -> String {
        guard name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) else { return name }
        let digits = name[open.upperBound..<name.index(before: name.endIndex)]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return name }
        return String(name[..<open.lowerBound])
    }

    /// True when any of `names` and any of `otherNames` are the same name apart from a rename suffix.
    static func clash(_ names: [String], _ otherNames: [String]) -> Bool {
        let bases = Set(names.map(base))
        return otherNames.contains { bases.contains(base($0)) }
    }
}

/// When the scanner refuses a remote command (FR-RMT-07), from its Line scan status.
enum RemoteCommandRules {
    static let closingText = "Line scan is closing on the scanner."

    /// Nil when a Start can begin a recording; otherwise the reason shown on the remote.
    static func startRefusal(_ status: RemoteStatus, closing: Bool) -> String? {
        if closing { return closingText }
        switch status.phase {
        case .ready: return status.calibrating ? "The scanner is calibrating the baseline." : nil
        case .closed: return "Line scan is not open on the scanner."
        case .starting: return "The scanner's camera is still starting."
        case .arming, .recording: return "The scanner is already recording."
        case .saving, .building: return "The scanner is still saving the last recording."
        case .failed: return status.failure ?? "The Line scan screen on the scanner shows an error."
        }
    }

    /// Nil when a Stop can stop the recording; otherwise the reason shown on the remote.
    static func stopRefusal(_ status: RemoteStatus, closing: Bool) -> String? {
        if closing { return closingText }
        switch status.phase {
        case .arming, .recording: return nil
        case .closed, .starting, .ready, .saving, .building, .failed: return "The scanner is not recording."
        }
    }
}

/// Texts of the scanner status on the remote screen.
enum RemoteStatusText {
    static func phase(_ status: RemoteStatus?) -> String {
        guard let status else { return "Waiting for the scanner's status…" }
        switch status.phase {
        case .closed: return "Line scan is not open on the scanner"
        case .starting: return "Starting…"
        case .ready: return status.calibrating ? "Calibrating baseline…" : "Ready"
        case .arming: return "Starting recording…"
        case .recording:
            let seconds = status.elapsed.isFinite ? Int(min(max(status.elapsed, 0), 1e9)) : 0
            return String(format: "● REC %ld:%02ld · %ld frames", seconds / 60, seconds % 60, status.frames)
        case .saving: return "Saving…"
        case .building: return "Building map…"
        case .failed: return "Error on the scanner"
        }
    }

    /// Banner first, then the recording warnings, without repeats.
    static func alerts(_ status: RemoteStatus) -> [String] {
        var lines: [String] = []
        for line in [status.banner].compactMap({ $0 }) + status.warnings where !lines.contains(line) {
            lines.append(line)
        }
        return lines
    }

    static func heat(_ heat: RemoteHeat) -> String {
        switch heat {
        case .normal: return "Normal"
        case .serious: return "Hot: live overlay slowed"
        case .critical: return "Too hot: recording stopped"
        }
    }

    static func battery(_ status: RemoteStatus) -> String {
        guard let battery = status.battery else { return "—" }
        var text = String(format: "%.0f %%", battery * 100)
        if let charging = status.charging { text += charging ? " · charging" : " · on battery" }
        return text
    }
}

/// Remote → scanner: send one file from `offset`. `size` and `modified` are what the remote's list says; the
/// scanner refuses with `changed` when the file differs.
struct RemoteFileRequest: Codable, Equatable, Sendable {
    var transferID: UInt32
    var scanID: UUID
    var name: String
    var offset: Int64
    var size: Int64
    var modified: Double
}

/// Why the scanner did not (or stopped to) send a file.
enum RemoteFileProblem: String, Codable, Sendable {
    /// The scanner records, saves or builds a map; ask again when it is idle.
    case busy
    /// The file's size or modification time differ from the request; copy it again from the start.
    case changed
    /// The scan or file is not offered any more.
    case missing
    /// Reading the file failed.
    case failed
}

// MARK: - Messages

/// JSON messages exchanged after the handshake.
enum RemoteMessage: Codable, Equatable, Sendable {
    case ping
    case status(RemoteStatus)
    case command(id: UInt32, action: RemoteAction)
    case commandResult(id: UInt32, accepted: Bool, message: String?)
    case listScans
    case scans([RemoteScanInfo])
    case fileRequest(RemoteFileRequest)
    case fileEnd(transferID: UInt32, size: Int64)
    case fileError(transferID: UInt32, reason: RemoteFileProblem, message: String)
    case chunkAck(transferID: UInt32, received: Int64)
    case cancelTransfer(transferID: UInt32)
}

/// Plaintext of one secure frame: a JSON message (kind 1) or a file chunk (kind 2: transfer ID UInt32 BE,
/// offset UInt64 BE, data).
enum RemoteRecord {
    static let messageKind: UInt8 = 1
    static let chunkKind: UInt8 = 2
    /// Bytes before the data of a chunk record.
    static let chunkHeaderSize = 13

    enum Content: Equatable {
        case message(RemoteMessage)
        case chunk(transferID: UInt32, offset: Int64, data: Data)
        /// A message this build does not understand (a newer app version): ignored.
        case unknown
    }

    static func message(_ message: RemoteMessage) throws -> Data {
        var data = Data([messageKind])
        data.append(try JSONEncoder().encode(message))
        return data
    }

    static func chunk(transferID: UInt32, offset: Int64, data: Data) -> Data {
        var record = Data(capacity: chunkHeaderSize + data.count)
        record.append(chunkKind)
        record.appendBigEndian(transferID)
        record.appendBigEndian(UInt64(max(offset, 0)))
        record.append(data)
        return record
    }

    /// Throws `badRecord` for an empty record, a chunk shorter than its header or an offset above `Int64.max`.
    static func decode(_ record: Data) throws -> Content {
        let bytes = Data(record)                       // index from 0
        guard let kind = bytes.first else { throw RemoteLinkError.badRecord }
        switch kind {
        case messageKind:
            guard let message = try? JSONDecoder().decode(RemoteMessage.self, from: bytes.dropFirst()) else {
                return .unknown
            }
            return .message(message)
        case chunkKind:
            guard bytes.count >= chunkHeaderSize else { throw RemoteLinkError.badRecord }
            let transferID = bytes.bigEndianUInt32(at: 1)
            let offset = bytes.bigEndianUInt64(at: 5)
            guard offset <= UInt64(Int64.max) else { throw RemoteLinkError.badRecord }
            return .chunk(transferID: transferID, offset: Int64(offset), data: Data(bytes[chunkHeaderSize...]))
        default:
            return .unknown
        }
    }
}

// MARK: - Frames

/// A frame on the wire: 4-byte big-endian length, then the payload.
enum RemoteFrame {
    static func encode(_ payload: Data) -> Data {
        var frame = Data(capacity: 4 + payload.count)
        frame.appendBigEndian(UInt32(payload.count))
        frame.append(payload)
        return frame
    }
}

/// Splits received bytes into frames. `limit` is checked before a frame's bytes are waited for, and can change
/// between frames (handshake limit, then the larger limit).
struct RemoteFrameDecoder {
    var limit: Int
    private var buffer = Data()
    /// Bytes of `buffer` already handed out.
    private var consumed = 0

    init(limit: Int) {
        self.limit = limit
    }

    /// Bytes received but not yet returned as frames.
    var pendingBytes: Int { buffer.count - consumed }

    mutating func push(_ data: Data) {
        buffer.append(data)
    }

    /// The next complete frame's payload, or nil when more bytes are needed.
    mutating func next() throws -> Data? {
        guard pendingBytes >= 4 else {
            compact()
            return nil
        }
        let base = buffer.startIndex + consumed
        let length = Int(buffer[base]) << 24 | Int(buffer[base + 1]) << 16 | Int(buffer[base + 2]) << 8 | Int(buffer[base + 3])
        guard length <= limit else { throw RemoteLinkError.frameTooLarge(length) }
        guard pendingBytes - 4 >= length else {
            compact()
            return nil
        }
        let payload = Data(buffer[(base + 4)..<(base + 4 + length)])
        consumed += 4 + length
        return payload
    }

    /// Drops handed-out bytes once they are at least half of the buffer (amortized O(n)).
    private mutating func compact() {
        guard consumed > 0, consumed * 2 >= buffer.count else { return }
        buffer = Data(buffer[(buffer.startIndex + consumed)...])
        consumed = 0
    }
}

// MARK: - Big-endian helpers

extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    /// Big-endian UInt32 at `offset` from `startIndex`. The caller checks the length.
    func bigEndianUInt32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return (base..<(base + 4)).reduce(UInt32(0)) { ($0 << 8) | UInt32(self[$1]) }
    }

    /// Big-endian UInt64 at `offset` from `startIndex`. The caller checks the length.
    func bigEndianUInt64(at offset: Int) -> UInt64 {
        let base = startIndex + offset
        return (base..<(base + 8)).reduce(UInt64(0)) { ($0 << 8) | UInt64(self[$1]) }
    }
}
