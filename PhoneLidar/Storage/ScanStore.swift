import Foundation
import Observation

enum ScanKind: String, Codable, CaseIterable, Identifiable {
    case room
    case mesh
    case object
    case line
    /// A kind written by a newer version of the app. The scan still opens and its files can be shared.
    case unknown

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ScanKind(rawValue: raw) ?? .unknown
    }

    var title: String {
        switch self {
        case .room: return "Room scan"
        case .mesh: return "Equipment scan (LiDAR mesh)"
        case .object: return "Object capture"
        case .line: return "Line scan (moving material)"
        case .unknown: return "Scan"
        }
    }

    var symbol: String {
        switch self {
        case .room: return "square.split.bottomrightquarter"
        case .mesh: return "cube.transparent"
        case .object: return "cube.fill"
        case .line: return "barcode.viewfinder"
        case .unknown: return "questionmark.folder"
        }
    }
}

/// A point-to-point distance taken during a scan. Coordinates are metres in the scan's world space.
struct PointMeasurement: Codable, Identifiable, Hashable {
    var id = UUID()
    var label: String
    var start: [Float]
    var end: [Float]
    var meters: Double

    enum CodingKeys: String, CodingKey {
        case id, label, start, end, meters
    }
}

extension PointMeasurement {
    /// Tolerant: a missing field gets a neutral value instead of making the whole scan unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? "M"
        start = (try? c.decodeIfPresent([Float].self, forKey: .start)) ?? [0, 0, 0]
        end = (try? c.decodeIfPresent([Float].self, forKey: .end)) ?? [0, 0, 0]
        meters = (try? c.decodeIfPresent(Double.self, forKey: .meters)) ?? 0
    }
}

/// Metadata for one saved scan. Stored as scan.json inside the scan's folder.
struct ScanRecord: Codable, Identifiable, Hashable {
    var id: UUID
    var kind: ScanKind
    var name: String
    var created: Date
    var folderName: String
    var primaryModel: String?
    var files: [String] = []
    var summary: [String] = []
    var measurements: [PointMeasurement] = []
    /// The kind text exactly as read from scan.json when this build does not know it (`kind == .unknown`),
    /// so a rename or re-save writes a newer build's kind back unchanged. Nil for known kinds.
    var unknownKindText: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, kind, name, created, folderName, primaryModel, files, summary, measurements
    }
}

extension ScanRecord {
    /// Set on the decoder so a scan.json without an id still gets the same id every time it is loaded.
    static let folderNameInfoKey = CodingUserInfoKey(rawValue: "ca.gervais.phonelidar.scanFolderName")!

    /// Tolerant decoding (older and newer scan.json files): every field is optional, unknown keys are ignored
    /// and an unknown kind becomes `.unknown`. The schema written by `encode` is unchanged.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let folder = (decoder.userInfo[ScanRecord.folderNameInfoKey] as? String) ?? ""
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID.stable(from: folder)
        kind = (try? c.decodeIfPresent(ScanKind.self, forKey: .kind)) ?? .unknown
        if kind == .unknown, let text = try? c.decodeIfPresent(String.self, forKey: .kind),
           text != ScanKind.unknown.rawValue {
            unknownKindText = text
        }
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? folder
        created = (try? c.decodeIfPresent(Date.self, forKey: .created)) ?? Date.distantPast
        folderName = (try? c.decodeIfPresent(String.self, forKey: .folderName)) ?? folder
        primaryModel = try? c.decodeIfPresent(String.self, forKey: .primaryModel)
        files = (try? c.decodeIfPresent([String].self, forKey: .files)) ?? []
        summary = (try? c.decodeIfPresent([String].self, forKey: .summary)) ?? []
        measurements = (try? c.decodeIfPresent([PointMeasurement].self, forKey: .measurements)) ?? []
    }

    /// Same keys and values as the synthesized encoder, except that an unknown kind is written back as read.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if kind == .unknown, let unknownKindText {
            try c.encode(unknownKindText, forKey: .kind)
        } else {
            try c.encode(kind, forKey: .kind)
        }
        try c.encode(name, forKey: .name)
        try c.encode(created, forKey: .created)
        try c.encode(folderName, forKey: .folderName)
        try c.encodeIfPresent(primaryModel, forKey: .primaryModel)
        try c.encode(files, forKey: .files)
        try c.encode(summary, forKey: .summary)
        try c.encode(measurements, forKey: .measurements)
    }
}

extension UUID {
    /// A repeatable UUID derived from text (two FNV-1a style hashes).
    static func stable(from text: String) -> UUID {
        var h1: UInt64 = 0xcbf29ce484222325
        var h2: UInt64 = 0x9e3779b97f4a7c15
        for byte in text.utf8 {
            h1 = (h1 ^ UInt64(byte)) &* 0x100000001b3
            h2 = (h2 &* 0x100000001b3) ^ UInt64(byte)
        }
        var b: [UInt8] = []
        for shift in stride(from: 56, through: 0, by: -8) { b.append(UInt8((h1 >> UInt64(shift)) & 0xff)) }
        for shift in stride(from: 56, through: 0, by: -8) { b.append(UInt8((h2 >> UInt64(shift)) & 0xff)) }
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

/// A scan folder with no readable scan.json: the app was closed, crashed or ran out of space before the scan finished.
struct IncompleteScan: Identifiable, Hashable {
    var id: String { folderName }
    let folderName: String
    let date: Date
    let bytes: Int64
    let fileCount: Int
    /// A line recording still marked as in progress that has a Recording.json: the app was closed while it was
    /// recording or saving. Line-recording recovery repairs it and adds it to the saved scans.
    var interruptedRecording = false
}

/// Names of scan folders that a capture is writing to right now. Background work (line-recording recovery)
/// checks it between folders, and the library neither lists nor deletes these folders as incomplete.
/// `@unchecked Sendable`: every access to `names` holds `lock`.
final class ActiveFolderSet: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String> = []

    func insert(_ name: String) {
        lock.withLock { _ = names.insert(name) }
    }

    func remove(_ name: String) {
        lock.withLock { _ = names.remove(name) }
    }

    func contains(_ name: String) -> Bool {
        lock.withLock { names.contains(name) }
    }

    var isEmpty: Bool {
        lock.withLock { names.isEmpty }
    }
}

/// Navigation value for the incomplete-scan screen.
struct IncompleteRoute: Hashable {
    let folderName: String
}

/// One item inside a scan folder: a file, or a sub-folder (for example Images) with every file inside it.
struct FolderEntry: Identifiable {
    var id: String { name }
    let name: String
    let isDirectory: Bool
    let urls: [URL]
    let bytes: Int64
}

enum ScanError: LocalizedError {
    case noData
    case noMesh
    case unsupported
    case cancelled
    case diskFull

    var errorDescription: String? {
        switch self {
        case .noData: return "Nothing has been captured yet."
        case .noMesh: return "No LiDAR mesh yet. Move around the equipment until the mesh overlay covers it."
        case .unsupported: return "This device does not support this scan type."
        case .cancelled: return "Cancelled."
        case .diskFull: return "Not enough free space on the phone. Delete old scans or other files, then try again."
        }
    }

    /// Message for any error; disk-full errors get a plain-language text.
    static func message(for error: Error) -> String {
        isDiskFull(error) ? ScanError.diskFull.localizedDescription : error.localizedDescription
    }

    static func isDiskFull(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isDiskFull(underlying)
        }
        return false
    }
}

/// Saves every scan in Documents/Scans/<folder>/ so the files also show up in the Files app.
@MainActor
@Observable
final class ScanStore {
    private(set) var scans: [ScanRecord] = []
    /// Folders without a readable scan.json (interrupted recordings and captures).
    private(set) var incomplete: [IncompleteScan] = []
    let root: URL
    /// Folders a line recording is writing to, from Record until its map is built (set by the Line scan screen).
    let activeLineFolders = ActiveFolderSet()

    // Line-recording recovery state, driven by `recoverLineRecordings()` (LineRecordingRecovery.swift).
    /// Message about recordings recovered in the background, shown on the Home screen until dismissed.
    var recoveryNotice: String?
    /// Interrupted recordings whose last recovery attempt failed: folder name → reason.
    var recoveryFailures: [String: String] = [:]
    /// True while a recovery pass is running.
    var recoveryRunning = false
    /// A recovery pass was asked for while one was running or a recording was active: run one more.
    @ObservationIgnored var recoveryRerunRequested = false
    /// Delayed retries in a row for folders that were still being written (bounded).
    @ObservationIgnored var recoveryRetries = 0

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func folderURL(for record: ScanRecord) -> URL {
        root.appendingPathComponent(record.folderName, isDirectory: true)
    }

    func folderURL(named name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    func fileURL(_ name: String, in record: ScanRecord) -> URL {
        folderURL(for: record).appendingPathComponent(name)
    }

    func record(id: UUID) -> ScanRecord? {
        scans.first { $0.id == id }
    }

    func incompleteScan(named name: String) -> IncompleteScan? {
        incomplete.first { $0.folderName == name }
    }

    /// Creates an empty folder for a new scan. The name is unique even if two scans start in the same second.
    func newFolder(kind: ScanKind) throws -> (name: String, url: URL) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let base = "\(kind.rawValue)_\(formatter.string(from: Date()))"
        var name = base
        var counter = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
            name = "\(base)_\(counter)"
            counter += 1
        }
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (name, url)
    }

    func save(_ record: ScanRecord) throws {
        var updated = record
        updated.files = regularFiles(in: folderURL(for: updated))
        let data = try JSONEncoder.pretty.encode(updated)
        try data.write(to: folderURL(for: updated).appendingPathComponent("scan.json"), options: .atomic)
        reload()
    }

    func rename(_ record: ScanRecord, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = record
        updated.name = trimmed
        try? save(updated)
    }

    /// Deletes a saved scan's folder. Refuses unless the folder is a direct child of the Scans folder and its
    /// scan.json still belongs to this record. Returns false if nothing was deleted.
    @discardableResult
    func delete(_ record: ScanRecord) -> Bool {
        defer { reload() }
        guard let url = validatedScanFolder(named: record.folderName),
              let onDisk = Self.decodeRecord(in: url), onDisk.id == record.id else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    /// Deletes a folder that has no readable scan.json (an incomplete scan, or a failed save).
    /// A folder that holds a saved scan, or that a line recording is writing to, is never removed by this call.
    @discardableResult
    func deleteIncomplete(folderName: String) -> Bool {
        defer { reload() }
        guard !activeLineFolders.contains(folderName),
              let url = validatedScanFolder(named: folderName), Self.decodeRecord(in: url) == nil else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    /// Clean-up after a failed or cancelled save: same rules as `deleteIncomplete`.
    func discard(folderName: String) {
        deleteIncomplete(folderName: folderName)
    }

    func reload() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey, .contentModificationDateKey]
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var loaded: [ScanRecord] = []
        var orphans: [IncompleteScan] = []
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if var record = Self.decodeRecord(in: folder) {
                if record.created == Date.distantPast { record.created = Self.folderDate(folder) }
                loaded.append(record)
            } else if !activeLineFolders.contains(folder.lastPathComponent) {
                // A folder a recording is still writing to is not incomplete: it is left out until saved.
                let files = Self.allFiles(under: folder)
                orphans.append(IncompleteScan(folderName: folder.lastPathComponent,
                                              date: Self.folderDate(folder),
                                              bytes: files.reduce(Int64(0)) { $0 + $1.bytes },
                                              fileCount: files.count,
                                              interruptedRecording: Self.isInterruptedRecording(folder)))
            }
        }
        scans = loaded.sorted { $0.created > $1.created }
        incomplete = orphans.sorted { $0.date > $1.date }
        if !recoveryFailures.isEmpty {
            // Forget failures of folders that were recovered, deleted or are no longer marked as interrupted.
            let interrupted = Set(orphans.filter { $0.interruptedRecording }.map { $0.folderName })
            recoveryFailures = recoveryFailures.filter { interrupted.contains($0.key) }
        }
    }

    /// A `line_` folder with the recording-in-progress marker and a Recording.json (see `IncompleteScan`).
    /// Line-recording recovery applies the same rule: it clears the marker of a folder without Recording.json,
    /// which then stays listed as a plain incomplete scan (Z-2). Reads files only: safe off the main thread.
    nonisolated static func isInterruptedRecording(_ folder: URL) -> Bool {
        let manager = FileManager.default
        return folder.lastPathComponent.hasPrefix("line_")
            && manager.fileExists(atPath: folder.appendingPathComponent(LineRecorder.inProgressMarker).path)
            && manager.fileExists(atPath: folder.appendingPathComponent("Recording.json").path)
    }

    /// Top-level items of a scan folder. Files are listed as they are; a sub-folder carries every file inside it.
    /// `Checkpoint` (a photogrammetry cache) is left out.
    func entries(inFolderNamed name: String) -> [FolderEntry] {
        guard let folder = validatedScanFolder(named: name) else { return [] }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []
        var result: [FolderEntry] = []
        for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            if values?.isDirectory == true {
                if item.lastPathComponent == "Checkpoint" { continue }
                let files = Self.allFiles(under: item)
                guard !files.isEmpty else { continue }
                result.append(FolderEntry(name: item.lastPathComponent, isDirectory: true,
                                          urls: files.map { $0.url },
                                          bytes: files.reduce(Int64(0)) { $0 + $1.bytes }))
            } else if values?.isRegularFile == true {
                result.append(FolderEntry(name: item.lastPathComponent, isDirectory: false,
                                          urls: [item], bytes: Int64(values?.fileSize ?? 0)))
            }
        }
        return result
    }

    // MARK: - Helpers

    /// The folder URL for a name, only if the name is a plain folder name and the folder is a real (non-link)
    /// directory directly inside the Scans folder.
    private func validatedScanFolder(named name: String) -> URL? {
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."),
              !name.contains("/"), !name.contains("\\") else { return nil }
        let url = root.appendingPathComponent(name, isDirectory: true)
        guard url.standardizedFileURL.deletingLastPathComponent().path == root.standardizedFileURL.path else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return nil }
        return url
    }

    /// True if the folder has a scan.json the library can read, so it is listed under Saved scans (not Incomplete).
    /// Reads files only: safe to call off the main thread (line-recording recovery does).
    nonisolated static func hasReadableRecord(in folder: URL) -> Bool {
        decodeRecord(in: folder) != nil
    }

    nonisolated private static func decodeRecord(in folder: URL) -> ScanRecord? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("scan.json")) else { return nil }
        let decoder = JSONDecoder.iso
        decoder.userInfo[ScanRecord.folderNameInfoKey] = folder.lastPathComponent
        guard var record = try? decoder.decode(ScanRecord.self, from: data) else { return nil }
        record.folderName = folder.lastPathComponent
        return record
    }

    private static func folderDate(_ folder: URL) -> Date {
        let values = try? folder.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date()
    }

    private static func allFiles(under folder: URL) -> [(url: URL, bytes: Int64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var result: [(url: URL, bytes: Int64)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            result.append((url, Int64(values.fileSize ?? 0)))
        }
        return result.sorted { $0.url.path < $1.url.path }
    }

    private func regularFiles(in folder: URL) -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { $0.lastPathComponent }
            .filter { $0 != "scan.json" }
            .sorted()
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
