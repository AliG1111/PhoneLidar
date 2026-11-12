import Foundation

// File listing, resume, staging, progress and import rules of the remote link's scan copy (design §6.15, §7.20).
// Foundation only; compiled by the test target.

/// Which files of a scan folder are offered and how a copy resumes.
enum RemoteFiles {
    /// Never offered: the remote writes its own `scan.json`.
    static let excludedNames: Set<String> = ["scan.json"]

    /// A plain file name: not empty, at most 255 UTF-8 bytes, no path separators, not hidden, no NUL.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && name != "." && name != ".." && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    /// Name, size and modification time of a regular file (not a link) with a plain name; nil otherwise.
    static func info(of url: URL) -> RemoteFileInfo? {
        let fresh = URL(fileURLWithPath: url.path)      // new URL: resource values are cached per URL object
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard isPlainName(fresh.lastPathComponent),
              let values = try? fresh.resourceValues(forKeys: keys),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize else { return nil }
        return RemoteFileInfo(name: fresh.lastPathComponent, size: Int64(size),
                              modified: (values.contentModificationDate ?? Date.distantPast).timeIntervalSince1970)
    }

    /// Files of a scan folder offered for copying: top-level non-hidden regular files with plain names except
    /// `scan.json`, smallest first (map and statistics before `Depth.bin` and `Video.mov`), then by name.
    /// An unreadable folder lists no files.
    static func list(folder: URL) -> [RemoteFileInfo] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                                     .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { info(of: $0) }
            .filter { !excludedNames.contains($0.name) }
            .sorted { ($0.size, $0.name) < ($1.size, $1.name) }
    }

    /// True when the file still has the size and modification time the remote asked for.
    static func matches(_ file: RemoteFileInfo, size: Int64, modified: Double) -> Bool {
        file.size == size && abs(file.modified - modified) < 0.001
    }

    /// Where a copy of one file continues. Complete (staged size = expected) → the expected size. Otherwise the
    /// staged size rounded down to a whole chunk, minus one chunk, so a torn tail is sent again; 0 when nothing
    /// is staged or the staged file is larger than expected.
    static func resumeOffset(stagedSize: Int64?, expectedSize: Int64,
                             chunk: Int64 = Int64(RemoteLinkConstants.chunkSize)) -> Int64 {
        guard let staged = stagedSize, staged > 0, staged <= expectedSize, chunk > 0 else { return 0 }
        if staged == expectedSize { return expectedSize }
        return max(0, (staged / chunk) * chunk - chunk)
    }

    /// Free space a copy needs on the remote phone, bytes.
    static func neededFreeBytes(remaining: Int64) -> Int64 {
        max(remaining, 0) + RemoteLinkConstants.freeSpaceMargin
    }
}

/// What a copy in progress was started from, saved next to its staged files as `.transfer.json`.
struct RemoteStagingManifest: Codable, Equatable {
    var scan: RemoteScanInfo
    var scannerName: String
    var started: Date
}

/// Staging folders of copies in progress: `Library/Application Support/RemoteIncoming/<scan UUID>/`.
enum RemoteStaging {
    static let manifestName = ".transfer.json"

    static func root(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("RemoteIncoming", isDirectory: true)
    }

    static func folder(for scanID: UUID, root: URL) -> URL {
        root.appendingPathComponent(scanID.uuidString, isDirectory: true)
    }

    static func loadManifest(in folder: URL) -> RemoteStagingManifest? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(manifestName)) else { return nil }
        return try? JSONDecoder.iso.decode(RemoteStagingManifest.self, from: data)
    }

    static func saveManifest(_ manifest: RemoteStagingManifest, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(manifest).write(to: folder.appendingPathComponent(manifestName), options: .atomic)
    }

    /// Staged files to delete because the scan changed on the scanner: files whose size or modification time
    /// differ in the new list, and files the new list no longer has.
    static func filesToDiscard(old: RemoteScanInfo, new: RemoteScanInfo) -> [String] {
        let current = Dictionary(new.files.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return old.files.compactMap { file in
            guard let now = current[file.name], RemoteFiles.matches(now, size: file.size, modified: file.modified) else {
                return file.name
            }
            return nil
        }
    }

    /// Sizes of the staged files of `scan` that exist (by name).
    static func stagedSizes(in folder: URL, scan: RemoteScanInfo) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for file in scan.files where RemoteFiles.isPlainName(file.name) {
            let url = folder.appendingPathComponent(file.name)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? NSNumber {
                sizes[file.name] = size.int64Value
            }
        }
        return sizes
    }

    /// Bytes of `scan` already staged: each listed file's staged size, at most its expected size.
    static func stagedBytes(sizes: [String: Int64], scan: RemoteScanInfo) -> Int64 {
        scan.files.reduce(Int64(0)) { total, file in
            total + min(max(sizes[file.name] ?? 0, 0), file.size)
        }
    }

    /// True when every listed file is staged with its full size.
    static func isComplete(sizes: [String: Int64], scan: RemoteScanInfo) -> Bool {
        scan.files.allSatisfy { sizes[$0.name] == $0.size }
    }
}

/// Copy progress with a smoothed rate.
struct TransferProgress: Equatable, Sendable {
    var total: Int64
    var done: Int64
    /// Smoothed copy rate, bytes/s (nil until measured).
    var rate: Double?
    private var sampleTime: Double?
    private var sampleDone: Int64 = 0

    init(total: Int64, done: Int64 = 0) {
        self.total = max(total, 0)
        self.done = min(max(done, 0), self.total)
    }

    /// `time` in seconds on a monotonic clock. The rate is sampled at least 0.5 s apart and smoothed
    /// (0.3 × new + 0.7 × old); a decrease of `done` (a resumed file starting earlier) is not a rate sample.
    mutating func update(done newDone: Int64, time: Double) {
        done = min(max(newDone, 0), total)
        guard let start = sampleTime else {
            sampleTime = time
            sampleDone = done
            return
        }
        let interval = time - start
        guard interval >= 0.5 else { return }
        let instant = Double(done - sampleDone) / interval
        if instant >= 0 {
            rate = rate.map { 0.7 * $0 + 0.3 * instant } ?? instant
        }
        sampleTime = time
        sampleDone = done
    }

    /// Forgets the rate (after a pause), so the next samples start a new measurement.
    mutating func resetRate() {
        rate = nil
        sampleTime = nil
    }

    var fraction: Double {
        total > 0 ? Double(done) / Double(total) : 0
    }

    var secondsLeft: Double? {
        guard let rate, rate > 1 else { return nil }
        return Double(total - done) / rate
    }

    /// "12.3 MB of 1.2 GB · 8.4 MB/s · 2 min left".
    var text: String {
        var parts = ["\(Units.bytes(done)) of \(Units.bytes(total))"]
        if let rate, rate > 1 {
            parts.append("\(Units.bytes(Int64(rate)))/s")
        }
        if let left = secondsLeft {
            parts.append(Self.timeLeftText(left))
        }
        return parts.joined(separator: " · ")
    }

    static func timeLeftText(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0f s left", max(seconds, 1)) }
        return String(format: "%.0f min left", (seconds / 60).rounded(.up))
    }
}

/// The library record of a copied scan.
enum RemoteImport {
    static func copiedLine(scannerName: String, date: Date) -> String {
        "Copied from \(scannerName) on \(date.formatted(date: .abbreviated, time: .shortened))."
    }

    /// Same ID, name, date and summary as on the scanner, plus the "Copied from …" line.
    static func record(from scan: RemoteScanInfo, scannerName: String, folderName: String, copied: Date) -> ScanRecord {
        ScanRecord(id: scan.id,
                   kind: .line,
                   name: scan.name,
                   created: scan.created,
                   folderName: folderName,
                   primaryModel: nil,
                   summary: scan.summary + [copiedLine(scannerName: scannerName, date: copied)])
    }
}
