import Foundation

/// Reads Recording.json back, repairing one that was cut off (app killed, storage full) while recording.
/// The recorder writes the header and `"frames":[` on the first line and one frame per line, so a cut-off
/// file is repaired by keeping every complete frame line and adding the closing `]}`.
enum LineRecordingRepair {
    /// Decodes the folder's Recording.json; if it does not decode, repairs it on disk and decodes that.
    /// `repaired` is true when the file had to be repaired. Throws if it cannot be read or repaired.
    static func loadInfo(folder: URL) throws -> (info: LineRecordingInfo, repaired: Bool) {
        let url = folder.appendingPathComponent("Recording.json")
        let data = try Data(contentsOf: url)
        if let info = try? JSONDecoder.iso.decode(LineRecordingInfo.self, from: data) {
            return (info, false)
        }
        guard let fixed = repairedData(data) else { throw LineError.badFile }
        let info = try JSONDecoder.iso.decode(LineRecordingInfo.self, from: fixed)
        try fixed.write(to: url, options: .atomic)
        return (info, true)
    }

    /// Recording.json rebuilt from its header line and every complete frame line, or nil if the file
    /// was not written line by line (recordings from earlier versions are never changed).
    static func repairedData(_ data: Data) -> Data? {
        let newline = UInt8(ascii: "\n")
        let lines = data.split(separator: newline, omittingEmptySubsequences: true)
        guard let header = lines.first, header.count > 12, header.first == UInt8(ascii: "{"),
              header.last == UInt8(ascii: "[") else { return nil }
        // Only the end of the file can be incomplete: drop trailing lines until one is a whole frame.
        let decoder = JSONDecoder()
        var end = lines.count
        while end > 1 {
            var line = Data(lines[end - 1])
            if line.first == UInt8(ascii: ",") { line = Data(line.dropFirst()) }
            if (try? decoder.decode(LineFrameInfo.self, from: line)) != nil { break }
            end -= 1
        }
        var out = Data(header)
        if end > 1 {
            for i in 1..<end {
                out.append(newline)
                out.append(contentsOf: lines[i])
            }
        }
        out.append(contentsOf: Array("\n]}\n".utf8))
        return out
    }

    /// Removes the "recording in progress" marker once the recording reads back correctly.
    static func clearMarker(in folder: URL) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(LineRecorder.inProgressMarker))
    }

    static func hasMarker(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(LineRecorder.inProgressMarker).path)
    }
}

/// Finds line recordings that were never saved (the app was closed or killed while recording or saving)
/// and makes them openable again.
enum LineRecordingRecovery {
    struct Recovered: Sendable {
        var folderName: String
        var created: Date
        var summary: [String]
    }

    /// Folders touched more recently than this are left alone (they may still be in use).
    static let quietSeconds: TimeInterval = 30

    /// Repairs every `line_*` folder still marked as in progress. Returns the recordings that have frames
    /// but no scan.json, so the caller can add them to the library. Runs off the main thread.
    static func scan(root: URL, skipping active: String?) -> [Recovered] {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])) ?? []
        var found: [Recovered] = []
        for folder in folders where folder.lastPathComponent.hasPrefix("line_") {
            let name = folder.lastPathComponent
            guard name != active, LineRecordingRepair.hasMarker(folder), !recentlyModified(folder) else { continue }
            let contents = ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0 != LineRecorder.inProgressMarker }
            if contents.isEmpty {
                try? manager.removeItem(at: folder)      // recording never received a frame
                continue
            }
            guard let loaded = try? LineRecordingRepair.loadInfo(folder: folder) else { continue }   // retried next time
            LineRecordingRepair.clearMarker(in: folder)
            let info = loaded.info
            guard !info.frames.isEmpty,
                  !manager.fileExists(atPath: folder.appendingPathComponent("scan.json").path) else { continue }
            let summary = [
                String(format: "%ld frames, %.1f s, material travel %@",
                       info.frames.count, info.frames.last?.time ?? 0, info.direction.label),
                "Recovered: the app closed before this recording was saved. The last seconds and the end of the video may be missing.",
                "Map not built yet: open Topographic map and tap Rebuild map."
            ]
            found.append(Recovered(folderName: name, created: startDate(of: folder), summary: summary))
        }
        return found
    }

    private static func recentlyModified(_ folder: URL) -> Bool {
        let now = Date()
        for file in ["Recording.json", "Depth.bin", "Video.mov"] {
            let path = folder.appendingPathComponent(file).path
            if let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
               now.timeIntervalSince(date) < quietSeconds {
                return true
            }
        }
        return false
    }

    /// Start time from the folder name (line_yyyy-MM-dd_HHmmss), else the folder's creation date.
    private static func startDate(of folder: URL) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = String(folder.lastPathComponent.dropFirst("line_".count))
        if let date = formatter.date(from: stamp) { return date }
        let attributes = try? FileManager.default.attributesOfItem(atPath: folder.path)
        return attributes?[.creationDate] as? Date ?? Date()
    }
}
