import Foundation
import UIKit

/// Reads Recording.json back, repairing one that was cut off (app killed, storage full) while recording.
/// The recorder writes the header and `"frames":[` on the first line and one frame per line, so a cut-off
/// file is repaired by keeping every complete frame line and adding the closing `]}`.
enum LineRecordingRepair {
    /// Decodes the folder's Recording.json; if it does not decode, repairs it on disk and decodes that.
    /// `repaired` is true when the file had to be repaired, now or by an earlier read: the repair writes
    /// `"repaired":true` into the file, so every later reader (Rebuild map, replay) still adds
    /// `TopoMapBuilder.recordingRepairedNote` (G-5). Throws if it cannot be read or repaired.
    static func loadInfo(folder: URL) throws -> (info: LineRecordingInfo, repaired: Bool) {
        let url = folder.appendingPathComponent("Recording.json")
        let data = try Data(contentsOf: url)
        if let info = try? JSONDecoder.iso.decode(LineRecordingInfo.self, from: data) {
            return (info, info.repaired == true)
        }
        guard let fixed = repairedData(data) else { throw LineError.badFile }
        let info = try JSONDecoder.iso.decode(LineRecordingInfo.self, from: fixed)
        try fixed.write(to: url, options: .atomic)
        return (info, true)
    }

    /// Key added at the start of a repaired file's header line (`LineRecordingInfo.repaired`).
    static let repairedKey = Array("\"repaired\":true,".utf8)

    /// Recording.json rebuilt from its header line and every complete frame line, with `"repaired":true`
    /// added to the header, or nil if the file was not written line by line (recordings from earlier versions
    /// are never changed).
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
        // `{` + "repaired":true, + the rest of the header (once: a file repaired before keeps its single key).
        var out = Data(header.prefix(1))
        if header.range(of: Data("\"repaired\":".utf8)) == nil {
            out.append(contentsOf: repairedKey)
        }
        out.append(contentsOf: header.dropFirst())
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

/// The scan record Line scan was about to save when the recording stopped (G-2). Written to the recording
/// folder just before the first scan.json save and removed once that save succeeds, so if the save fails (or the
/// app is closed in between) recovery adds the scan with its real summary: stop reason and recorder notes.
/// Hidden file `.pending-scan.json`, pretty JSON `{"created": ISO-8601, "name": text, "summary": [text]}`;
/// every key is optional for readers, and a missing or unreadable file means "use the generic summary".
struct LinePendingSave: Codable {
    static let fileName = ".pending-scan.json"

    var name: String?
    var created: Date?
    var summary: [String]?

    func write(to folder: URL) throws {
        try JSONEncoder.pretty.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// The folder's pending save, or nil if there is none or it cannot be read.
    static func load(from folder: URL) -> LinePendingSave? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder.iso.decode(LinePendingSave.self, from: data)
    }

    /// Removes the file once scan.json holds the record (missing already is fine).
    static func remove(from folder: URL) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(fileName))
    }
}

/// Finds line recordings that were never saved (the app was closed or killed while recording or saving)
/// and makes them openable again. The library runs it in the background (`ScanStore.recoverLineRecordings`).
enum LineRecordingRecovery {
    struct Recovered: Sendable {
        var folderName: String
        var created: Date
        var summary: [String]
        /// Name Line scan meant to give the scan (from `LinePendingSave`), else nil.
        var name: String? = nil
    }

    /// Summary line of a recording recovered with its pending save: it stopped normally, only the save failed.
    static let pendingSaveNote = "Recovered: the recording stopped normally, but the scan could not be added to the "
        + "list at the time; the app added it later."

    /// Summary of a recovery with a pending save: Line scan's own lines with `pendingSaveNote` after the first
    /// line, and `TopoMapBuilder.recordingRepairedNote` too if Recording.json had to be repaired.
    static func pendingSummary(_ lines: [String], repaired: Bool) -> [String] {
        var notes = [pendingSaveNote]
        if repaired, !lines.contains(TopoMapBuilder.recordingRepairedNote) {
            notes.append(TopoMapBuilder.recordingRepairedNote)
        }
        var out = lines
        out.insert(contentsOf: notes, at: min(1, out.count))
        return out
    }

    /// Result of one pass over the Scans folder.
    struct Outcome: Sendable {
        /// Repaired recordings with frames and no scan.json, still marked: the caller adds each to the library
        /// and then clears its marker (`LineRecordingRepair.clearMarker`).
        var recovered: [Recovered] = []
        /// Marked folders without a readable scan.json (listed under Incomplete scans) whose Recording.json exists
        /// but could not be read or repaired: folder name → reason. Saved scans that fail are left marked and not
        /// listed; a marked folder without Recording.json loses its marker instead (Z-2).
        var failed: [String: String] = [:]
        /// Some folders were skipped because they were in use or only just written: run again later.
        var deferred = false
    }

    /// Folders touched more recently than this are left alone (they may still be in use).
    static let quietSeconds: TimeInterval = 30

    /// Repairs every `line_` folder still marked as in progress. Runs off the main thread. Stops (deferred)
    /// as soon as a recording is active, and never touches a folder modified in the last `quietSeconds`
    /// (a running recording writes Depth.bin every frame; a new one creates its folder and marker first).
    static func scan(root: URL, active: ActiveFolderSet) -> Outcome {
        let manager = FileManager.default
        let folders = ((try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("line_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var outcome = Outcome()
        for folder in folders {
            // Never work next to a running recording; the next pass picks up the rest.
            guard active.isEmpty else {
                outcome.deferred = true
                break
            }
            let name = folder.lastPathComponent
            guard LineRecordingRepair.hasMarker(folder) else { continue }
            if recentlyModified(folder) {
                outcome.deferred = true
                continue
            }
            let contents = ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0 != LineRecorder.inProgressMarker }
            if contents.isEmpty {
                try? manager.removeItem(at: folder)      // only the marker, long untouched: never received a frame
                continue
            }
            guard ScanStore.isInterruptedRecording(folder) else {
                // No Recording.json to repair (the recorder stopped before creating it). The library uses the same
                // rule: such a folder is a plain incomplete scan, so the marker goes and the folder is not reported
                // as failed on every pass (Z-2).
                LineRecordingRepair.clearMarker(in: folder)
                continue
            }
            let loaded: (info: LineRecordingInfo, repaired: Bool)
            do {
                loaded = try LineRecordingRepair.loadInfo(folder: folder)
            } catch {
                // Kept marked: retried next pass. Only a folder listed under Incomplete scans (no readable
                // scan.json) is reported; a saved scan stays under Saved scans and its viewers say why it
                // cannot be played, so reporting it would repeat the notice on every pass (G-1).
                if !ScanStore.hasReadableRecord(in: folder) {
                    outcome.failed[name] = ScanError.message(for: error)
                }
                continue
            }
            let info = loaded.info
            guard !info.frames.isEmpty,
                  !manager.fileExists(atPath: folder.appendingPathComponent("scan.json").path) else {
                // Nothing to add (no frames, or already a saved scan whose map step was cut short).
                LinePendingSave.remove(from: folder)
                LineRecordingRepair.clearMarker(in: folder)
                continue
            }
            if let pending = LinePendingSave.load(from: folder), let lines = pending.summary, !lines.isEmpty {
                // Stopped normally; only the scan.json save failed (G-2): keep Line scan's own summary.
                outcome.recovered.append(Recovered(folderName: name, created: pending.created ?? startDate(of: folder),
                                                   summary: pendingSummary(lines, repaired: loaded.repaired),
                                                   name: pending.name))
                continue
            }
            let summary = [
                String(format: "%ld frames, %.1f s, material travel %@",
                       info.frames.count, info.frames.last?.time ?? 0, info.direction.label),
                "Recovered: the app closed before this recording was saved. The last seconds and the end of the video may be missing.",
                "Map not built yet: open Topographic map and tap Rebuild map."
            ]
            outcome.recovered.append(Recovered(folderName: name, created: startDate(of: folder), summary: summary))
        }
        return outcome
    }

    /// True if the folder itself (entries added or removed), its marker or a data file changed recently.
    private static func recentlyModified(_ folder: URL) -> Bool {
        let now = Date()
        var paths = [folder.path]
        for file in [LineRecorder.inProgressMarker, "Recording.json", "Depth.bin", "Video.mov",
                     "Frames.csv", "ZoneSpeeds.csv"] {
            paths.append(folder.appendingPathComponent(file).path)
        }
        for path in paths {
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

// MARK: - Library side (main actor)

extension ScanStore {
    /// Marks `folderName` as being written by a line recording: recovery does not run, and the library neither
    /// lists nor deletes the folder as incomplete, until `endLineRecording`.
    func beginLineRecording(_ folderName: String) {
        activeLineFolders.insert(folderName)
    }

    /// The recording in `folderName` is saved (or abandoned). Runs a recovery pass that was held back.
    func endLineRecording(_ folderName: String) {
        activeLineFolders.remove(folderName)
        if activeLineFolders.isEmpty, recoveryRerunRequested {
            recoverLineRecordings()
        }
    }

    /// Adds line recordings left unsaved by an earlier run (app closed or killed while recording or saving) to
    /// the library, in the background, and sets `recoveryNotice` when it added any or one failed for the first
    /// time. Call when the library loads and when the app becomes active; never runs while a recording is active
    /// (it runs when that recording ends instead). A call during a pass schedules one more pass.
    func recoverLineRecordings() {
        guard activeLineFolders.isEmpty else {
            recoveryRerunRequested = true
            return
        }
        guard !recoveryRunning else {
            recoveryRerunRequested = true
            return
        }
        recoveryRunning = true
        recoveryRerunRequested = false
        let root = self.root
        let active = activeLineFolders
        // Repairs are atomic file replacements, so being suspended when background time runs out is harmless.
        let activity = BackgroundActivity(name: "Recover line recordings")
        Task { @MainActor in
            let outcome = await Task.detached(priority: .utility) {
                LineRecordingRecovery.scan(root: root, active: active)
            }.value
            self.addRecovered(outcome)
            self.recoveryRunning = false
            activity.end()
            if self.recoveryRerunRequested {
                self.recoverLineRecordings()
            } else if outcome.deferred {
                self.scheduleRecoveryRetry()
            } else {
                self.recoveryRetries = 0
            }
        }
    }

    /// Folders were still being written: look again once they have been quiet long enough (a few times at most).
    private func scheduleRecoveryRetry() {
        guard recoveryRetries < 4 else {
            recoveryRetries = 0
            return
        }
        recoveryRetries += 1
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(LineRecordingRecovery.quietSeconds + 2))
            self.recoverLineRecordings()
        }
    }

    private func addRecovered(_ outcome: LineRecordingRecovery.Outcome) {
        let manager = FileManager.default
        var added = 0
        var failures = outcome.failed
        for item in outcome.recovered {
            let folder = folderURL(named: item.folderName)
            // Deleted meanwhile, being recorded into, or already saved: leave it.
            guard manager.fileExists(atPath: folder.path),
                  !activeLineFolders.contains(item.folderName),
                  !scans.contains(where: { $0.folderName == item.folderName }),
                  !manager.fileExists(atPath: folder.appendingPathComponent("scan.json").path) else { continue }
            let baseName = item.name ?? ("Line " + item.created.formatted(date: .abbreviated, time: .shortened))
            let record = ScanRecord(id: UUID(),
                                    kind: .line,
                                    name: baseName + " (recovered)",
                                    created: item.created,
                                    folderName: item.folderName,
                                    primaryModel: nil,
                                    summary: item.summary)
            do {
                try save(record)
                LinePendingSave.remove(from: folder)
                LineRecordingRepair.clearMarker(in: folder)
                added += 1
            } catch {
                // Still marked, so the next pass tries again.
                failures[item.folderName] = "it could not be added to the list (\(ScanError.message(for: error)))"
            }
        }
        let firstTime = failures.filter { recoveryFailures[$0.key] == nil }
        recoveryFailures.merge(failures) { _, latest in latest }
        reload()      // the pass may have repaired, unmarked or removed folders; also prunes recoveryFailures

        var parts: [String] = []
        if added == 1 {
            parts.append("Recovered 1 line recording that had not been saved. It is under Saved scans "
                         + "(marked “recovered”); open Topographic map and tap Rebuild map to build its map.")
        } else if added > 1 {
            parts.append("Recovered \(added) line recordings that had not been saved. They are under "
                         + "Saved scans (marked “recovered”); open Topographic map and tap Rebuild map to build their maps.")
        }
        if firstTime.count == 1, let failure = firstTime.first {
            parts.append("The interrupted recording \(failure.key) could not be recovered: \(failure.value). "
                         + "Its files are kept under Incomplete scans.")
        } else if firstTime.count > 1 {
            parts.append("\(firstTime.count) interrupted recordings could not be recovered. Their files are kept under "
                         + "Incomplete scans; open one to see why.")
        }
        guard !parts.isEmpty else { return }
        let text = parts.joined(separator: " ")
        recoveryNotice = recoveryNotice.map { $0 + "\n\n" + text } ?? text
    }
}

/// A UIKit background task that ends exactly once: on `end()`, or when iOS runs out of background time.
@MainActor
final class BackgroundActivity {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
