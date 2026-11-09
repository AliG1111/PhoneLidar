import Foundation
import Observation

enum ScanKind: String, Codable, CaseIterable, Identifiable {
    case room
    case mesh
    case object

    var id: String { rawValue }

    var title: String {
        switch self {
        case .room: return "Room scan"
        case .mesh: return "Equipment scan (LiDAR mesh)"
        case .object: return "Object capture"
        }
    }

    var symbol: String {
        switch self {
        case .room: return "square.split.bottomrightquarter"
        case .mesh: return "cube.transparent"
        case .object: return "cube.fill"
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
}

enum ScanError: LocalizedError {
    case noData
    case noMesh
    case unsupported
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noData: return "Nothing has been captured yet."
        case .noMesh: return "No LiDAR mesh yet. Move around the equipment until the mesh overlay covers it."
        case .unsupported: return "This device does not support this scan type."
        case .cancelled: return "Cancelled."
        }
    }
}

/// Saves every scan in Documents/Scans/<folder>/ so the files also show up in the Files app.
@MainActor
@Observable
final class ScanStore {
    private(set) var scans: [ScanRecord] = []
    let root: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func folderURL(for record: ScanRecord) -> URL {
        root.appendingPathComponent(record.folderName, isDirectory: true)
    }

    func fileURL(_ name: String, in record: ScanRecord) -> URL {
        folderURL(for: record).appendingPathComponent(name)
    }

    func record(id: UUID) -> ScanRecord? {
        scans.first { $0.id == id }
    }

    /// Creates an empty folder for a new scan.
    func newFolder(kind: ScanKind) throws -> (name: String, url: URL) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = "\(kind.rawValue)_\(formatter.string(from: Date()))"
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

    func delete(_ record: ScanRecord) {
        try? FileManager.default.removeItem(at: folderURL(for: record))
        reload()
    }

    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var loaded: [ScanRecord] = []
        for folder in folders {
            let metaURL = folder.appendingPathComponent("scan.json")
            guard let data = try? Data(contentsOf: metaURL),
                  var record = try? JSONDecoder.iso.decode(ScanRecord.self, from: data) else { continue }
            record.folderName = folder.lastPathComponent
            loaded.append(record)
        }
        scans = loaded.sorted { $0.created > $1.created }
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
