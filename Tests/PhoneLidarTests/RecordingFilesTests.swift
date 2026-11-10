import XCTest

/// Recording.json is written compactly, one frame per line, while recording (A-3); Frames.csv and ZoneSpeeds.csv
/// are streamed a row at a time. These tests cover the writers and the row formats.
final class RecordingJSONWriterTests: XCTestCase {
    private func makeHeader() -> LineRecordingHeader {
        LineRecordingHeader(depthWidth: 192, depthHeight: 256, videoWidth: 1080, videoHeight: 1920,
                            filteredDepth: true, shortShutter: false, direction: .leftToRight,
                            tileColumns: 6, tileRows: 4)
    }

    private func frame(_ index: Int) -> LineFrameInfo {
        var f = makeFrame(index: index, time: Double(index) / 30, speed: 200 + Double(index),
                          travel: Double(index) * 6.5, medianDepth: 900)
        f.tiltX = 0.25
        f.tileSpeeds = [210, nil, 190.5]
        return f
    }

    /// Writes a closed Recording.json holding `count` frames and returns its URL.
    private func writeRecording(count: Int, into folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("Recording.json")
        let writer = try RecordingJSONWriter(url: url, header: makeHeader())
        for i in 0..<count { try writer.append(frame(i)) }
        try writer.close()
        return url
    }

    func testHeaderIsOnDiskAsSoonAsTheWriterExists() throws {
        let url = try makeTempFolder().appendingPathComponent("Recording.json")
        let writer = try RecordingJSONWriter(url: url, header: makeHeader())
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("{"), text)
        XCTAssertTrue(text.hasSuffix("\"frames\":[\n"), text)
        XCTAssertEqual(text.split(separator: "\n").count, 1)
        try writer.close()
    }

    func testFileHasOneCompactFramePerLine() throws {
        let url = try writeRecording(count: 3, into: try makeTempFolder())
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.count, 1 + 3 + 1)               // header, three frames, closing line
        XCTAssertTrue(lines[0].hasSuffix("\"frames\":["))
        XCTAssertFalse(lines[1].hasPrefix(","))
        XCTAssertTrue(lines[2].hasPrefix(",{"), lines[2])
        XCTAssertTrue(lines[3].hasPrefix(",{"), lines[3])
        XCTAssertEqual(lines[4], "]}")
        // Compact: no pretty-printing white space around keys and values.
        XCTAssertFalse(text.contains(" : "))
        XCTAssertFalse(text.contains("  "))
        for line in lines[1...3] {
            let json = line.hasPrefix(",") ? String(line.dropFirst()) : line
            let decoded = try JSONDecoder().decode(LineFrameInfo.self, from: Data(json.utf8))
            XCTAssertEqual(decoded.medianDepth, 900)
        }
    }

    func testFileReadsBackWithTheNormalDecoder() throws {
        let url = try writeRecording(count: 4, into: try makeTempFolder())
        let info = try JSONDecoder.iso.decode(LineRecordingInfo.self, from: Data(contentsOf: url))
        XCTAssertEqual(info.frames.count, 4)
        XCTAssertEqual(info.depthWidth, 192)
        XCTAssertEqual(info.depthHeight, 256)
        XCTAssertEqual(info.videoWidth, 1080)
        XCTAssertEqual(info.videoHeight, 1920)
        XCTAssertTrue(info.filteredDepth)
        XCTAssertFalse(info.shortShutter)
        XCTAssertEqual(info.direction, .leftToRight)
        XCTAssertEqual(info.tileColumns, 6)
        XCTAssertEqual(info.tileRows, 4)
        XCTAssertEqual(info.frames.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(info.frames[3].time, 0.1, accuracy: 1e-12)
        XCTAssertEqual(info.frames[3].travel, 19.5, accuracy: 1e-12)
        XCTAssertEqual(info.frames[3].speed, 203)
        XCTAssertEqual(info.frames[3].tiltX, 0.25)
        XCTAssertNil(info.frames[3].shiftPixels)
        let zones = try XCTUnwrap(info.frames[3].tileSpeeds)
        XCTAssertEqual(zones.count, 3)
        XCTAssertEqual(zones[0], 210)
        XCTAssertNil(zones[1])
        XCTAssertEqual(zones[2], 190.5)
    }

    func testRecordingWithoutFramesIsStillValidJSON() throws {
        let url = try writeRecording(count: 0, into: try makeTempFolder())
        let info = try JSONDecoder.iso.decode(LineRecordingInfo.self, from: Data(contentsOf: url))
        XCTAssertTrue(info.frames.isEmpty)
        XCTAssertEqual(info.direction, .leftToRight)
    }

    func testHeaderKeysAreTheKeysOfLineRecordingInfo() throws {
        let url = try writeRecording(count: 2, into: try makeTempFolder())
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let info = LineRecordingInfo(depthWidth: 192, depthHeight: 256, videoWidth: 1080, videoHeight: 1920,
                                     filteredDepth: true, shortShutter: false, direction: .leftToRight,
                                     frames: [frame(0), frame(1)], tileColumns: 6, tileRows: 4)
        let encoded = try JSONEncoder().encode(info)
        let reference = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(written.keys), Set(reference.keys))
        XCTAssertEqual(written["direction"] as? String, "leftToRight")
        XCTAssertEqual(written["depthWidth"] as? Int, 192)
    }

    func testLargeRecordingIsFlushedWhileRecording() throws {
        let url = try makeTempFolder().appendingPathComponent("Recording.json")
        let writer = try RecordingJSONWriter(url: url, header: makeHeader())
        for i in 0..<1000 { try writer.append(frame(i)) }       // well over the 64 kB flush size
        let beforeClose = try Data(contentsOf: url).count
        XCTAssertGreaterThan(beforeClose, 64_000)
        try writer.close()
        let info = try JSONDecoder.iso.decode(LineRecordingInfo.self, from: Data(contentsOf: url))
        XCTAssertEqual(info.frames.count, 1000)
    }
}

final class LineRecordingRepairTests: XCTestCase {
    private func makeHeader() -> LineRecordingHeader {
        LineRecordingHeader(depthWidth: 192, depthHeight: 256, videoWidth: 1080, videoHeight: 1920,
                            filteredDepth: true, shortShutter: true, direction: .rightToLeft,
                            tileColumns: 6, tileRows: 4)
    }

    /// The complete text of a Recording.json with `count` frames.
    private func recordingText(count: Int) throws -> String {
        let url = try makeTempFolder().appendingPathComponent("Recording.json")
        let writer = try RecordingJSONWriter(url: url, header: makeHeader())
        for i in 0..<count {
            try writer.append(makeFrame(index: i, time: Double(i) * 0.1, speed: 150, travel: Double(i) * 15))
        }
        try writer.close()
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func write(_ text: String, to folder: URL) throws {
        try Data(text.utf8).write(to: folder.appendingPathComponent("Recording.json"))
    }

    private func decode(_ data: Data) throws -> LineRecordingInfo {
        try JSONDecoder.iso.decode(LineRecordingInfo.self, from: data)
    }

    // MARK: - repairedData

    func testRepairKeepsEveryCompleteFrameOfACutOffFile() throws {
        let text = try recordingText(count: 5)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.count, 7)
        // Killed in the middle of writing frame 4: the closing line is missing and the last frame is cut.
        lines.removeLast()
        lines[lines.count - 1] = String(lines[lines.count - 1].prefix(25))
        let cut = Data(lines.joined(separator: "\n").utf8)
        XCTAssertThrowsError(try decode(cut))

        let repaired = try XCTUnwrap(LineRecordingRepair.repairedData(cut))
        let info = try decode(repaired)
        XCTAssertEqual(info.frames.count, 4)
        XCTAssertEqual(info.frames.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(info.frames[3].travel, 45, accuracy: 1e-9)
        XCTAssertEqual(info.direction, .rightToLeft)
        XCTAssertEqual(info.tileColumns, 6)
    }

    func testRepairOfAFileCutAtALineEndKeepsAllFrames() throws {
        let text = try recordingText(count: 3)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        lines.removeLast()      // only the closing "]}" is missing
        let cut = Data((lines.joined(separator: "\n") + "\n").utf8)
        let info = try decode(try XCTUnwrap(LineRecordingRepair.repairedData(cut)))
        XCTAssertEqual(info.frames.count, 3)
    }

    func testRepairOfAFileCutRightAfterTheHeaderHasNoFrames() throws {
        let text = try recordingText(count: 3)
        let headerLine = try XCTUnwrap(text.split(separator: "\n").first)
        let info = try decode(try XCTUnwrap(LineRecordingRepair.repairedData(Data((headerLine + "\n").utf8))))
        XCTAssertTrue(info.frames.isEmpty)
        XCTAssertEqual(info.videoWidth, 1080)
    }

    func testRepairDropsSeveralDamagedTrailingLines() throws {
        let text = try recordingText(count: 4)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        lines.removeLast()
        lines.append(",{\"index\":9,\"tim")      // a cut frame ...
        lines.append("garbage")                 // ... and junk after it
        let info = try decode(try XCTUnwrap(LineRecordingRepair.repairedData(Data(lines.joined(separator: "\n").utf8))))
        XCTAssertEqual(info.frames.count, 4)
    }

    func testRepairRefusesFilesThatWereNotWrittenLineByLine() throws {
        // A pretty-printed file from an earlier version, cut off.
        let older = "{\n  \"depthWidth\" : 192,\n  \"depthHeight\" : 256,\n  \"frames\" : [\n    {\n      \"index\" : 0,"
        XCTAssertNil(LineRecordingRepair.repairedData(Data(older.utf8)))
        XCTAssertNil(LineRecordingRepair.repairedData(Data()))
        XCTAssertNil(LineRecordingRepair.repairedData(Data("{\"depthW".utf8)))      // header itself cut
        XCTAssertNil(LineRecordingRepair.repairedData(Data("not json at all, not even close".utf8)))
    }

    // MARK: - loadInfo

    func testLoadInfoReadsAnIntactFileWithoutChangingIt() throws {
        let folder = try makeTempFolder()
        try write(try recordingText(count: 3), to: folder)
        let before = try Data(contentsOf: folder.appendingPathComponent("Recording.json"))
        let loaded = try LineRecordingRepair.loadInfo(folder: folder)
        XCTAssertFalse(loaded.repaired)
        XCTAssertEqual(loaded.info.frames.count, 3)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Recording.json")), before)
    }

    func testLoadInfoRepairsATruncatedFileOnDisk() throws {
        let folder = try makeTempFolder()
        let text = try recordingText(count: 6)
        // Cut in the middle of the fifth frame (index 4), as if the app was killed.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let cut = lines[0..<5].joined(separator: "\n") + "\n" + String(lines[5].prefix(20))
        try write(cut, to: folder)

        let loaded = try LineRecordingRepair.loadInfo(folder: folder)
        XCTAssertTrue(loaded.repaired)
        XCTAssertEqual(loaded.info.frames.count, 4)

        // The file on disk was repaired: a second read needs no repair and gives the same frames.
        let again = try LineRecordingRepair.loadInfo(folder: folder)
        XCTAssertFalse(again.repaired)
        XCTAssertEqual(again.info.frames.count, 4)
        XCTAssertEqual(again.info.frames.last?.travel ?? 0, 45, accuracy: 1e-9)
    }

    func testLoadInfoThrowsForMissingOrHopelessFiles() throws {
        let folder = try makeTempFolder()
        XCTAssertThrowsError(try LineRecordingRepair.loadInfo(folder: folder))      // no Recording.json
        try write("{\"depthW", to: folder)
        XCTAssertThrowsError(try LineRecordingRepair.loadInfo(folder: folder)) { assertLineError($0, .badFile) }
        // The hopeless file is left as it was.
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Recording.json"), encoding: .utf8),
                       "{\"depthW")
    }

    func testInProgressMarker() throws {
        let folder = try makeTempFolder()
        XCTAssertEqual(LineRecorder.inProgressMarker, ".recording-in-progress")
        XCTAssertFalse(LineRecordingRepair.hasMarker(folder))
        FileManager.default.createFile(atPath: folder.appendingPathComponent(LineRecorder.inProgressMarker).path,
                                       contents: nil)
        XCTAssertTrue(LineRecordingRepair.hasMarker(folder))
        LineRecordingRepair.clearMarker(in: folder)
        XCTAssertFalse(LineRecordingRepair.hasMarker(folder))
        LineRecordingRepair.clearMarker(in: folder)      // clearing again is harmless
    }
}

/// Finding and repairing line recordings that were never saved.
final class LineRecordingRecoveryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try makeTempFolder()
    }

    private func makeHeader() -> LineRecordingHeader {
        LineRecordingHeader(depthWidth: 192, depthHeight: 256, videoWidth: 1080, videoHeight: 1920,
                            filteredDepth: true, shortShutter: true, direction: .leftToRight,
                            tileColumns: 6, tileRows: 4)
    }

    /// Creates `line_<stamp>` holding the in-progress marker and, unless `frames` is nil, a Recording.json cut off
    /// in the middle of its last frame. All files are given an old modification date unless `recent`.
    @discardableResult
    private func makeUnsavedRecording(stamp: String = "2026-11-10_101500", frames: Int? = 5, recent: Bool = false,
                                      withScanJSON: Bool = false) throws -> URL {
        let folder = root.appendingPathComponent("line_\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appendingPathComponent(LineRecorder.inProgressMarker).path,
                                       contents: nil)
        if let frames {
            let complete = folder.appendingPathComponent("complete.json")
            let writer = try RecordingJSONWriter(url: complete, header: makeHeader())
            for i in 0..<frames {
                try writer.append(makeFrame(index: i, time: Double(i) * 0.1, speed: 100, travel: Double(i) * 10))
            }
            try writer.close()
            var text = try String(contentsOf: complete, encoding: .utf8)
            try FileManager.default.removeItem(at: complete)
            text = String(text.dropLast(30))       // the closing line and part of the last frame are missing
            try Data(text.utf8).write(to: folder.appendingPathComponent("Recording.json"))
        }
        if withScanJSON {
            try Data("{}".utf8).write(to: folder.appendingPathComponent("scan.json"))
        }
        if !recent {
            try ageFolder(folder)
        }
        return folder
    }

    /// Gives the folder, the marker and every file in it an old modification date. The scan skips a folder
    /// whose directory, marker or data files changed in the last `quietSeconds` (F-6), so the directory is aged
    /// last: creating or removing an entry changes its date.
    private func ageFolder(_ folder: URL) throws {
        let old = Date(timeIntervalSinceNow: -3600)
        let manager = FileManager.default
        for name in try manager.contentsOfDirectory(atPath: folder.path) {
            try manager.setAttributes([.modificationDate: old], ofItemAtPath: folder.appendingPathComponent(name).path)
        }
        try manager.setAttributes([.modificationDate: old], ofItemAtPath: folder.path)
    }

    func testAnUnsavedRecordingIsRepairedAndReported() throws {
        let folder = try makeUnsavedRecording(frames: 5)
        let outcome = LineRecordingRecovery.scan(root: root, active: ActiveFolderSet())
        XCTAssertEqual(outcome.recovered.count, 1)
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertFalse(outcome.deferred)
        let recovered = try XCTUnwrap(outcome.recovered.first)
        XCTAssertEqual(recovered.folderName, "line_2026-11-10_101500")
        XCTAssertTrue(recovered.summary[0].hasPrefix("4 frames, 0.3 s"), recovered.summary[0])
        XCTAssertTrue(recovered.summary[0].hasSuffix("Left → Right"), recovered.summary[0])
        XCTAssertTrue(recovered.summary.contains { $0.hasPrefix("Recovered:") })
        XCTAssertTrue(recovered.summary.contains { $0.hasPrefix("Map not built") })
        // The start time comes from the folder name.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        XCTAssertEqual(recovered.created, formatter.date(from: "2026-11-10_101500"))
        // F-6: the scan repairs Recording.json but leaves the marker; the library clears it only after it has
        // saved the scan record (ScanStore.addRecovered), so a failed save is retried on the next pass.
        XCTAssertTrue(LineRecordingRepair.hasMarker(folder))
        let loaded = try LineRecordingRepair.loadInfo(folder: folder)
        XCTAssertFalse(loaded.repaired)
        XCTAssertEqual(loaded.info.frames.count, 4)
    }

    func testRecentlyModifiedFoldersAreLeftAlone() throws {
        let folder = try makeUnsavedRecording(frames: 5, recent: true)
        // F-6: a folder touched within quietSeconds is skipped and the pass reports "run again later".
        let outcome = LineRecordingRecovery.scan(root: root, active: ActiveFolderSet())
        XCTAssertTrue(outcome.recovered.isEmpty)
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertTrue(outcome.deferred)
        XCTAssertTrue(LineRecordingRepair.hasMarker(folder))
    }

    func testNothingIsTouchedWhileARecordingIsActive() throws {
        let folder = try makeUnsavedRecording(frames: 5)
        // F-6: with an active recording the pass stops before the first folder (it used to skip only that one).
        let active = ActiveFolderSet()
        active.insert("line_2026-11-10_101500")
        let outcome = LineRecordingRecovery.scan(root: root, active: active)
        XCTAssertTrue(outcome.recovered.isEmpty)
        XCTAssertTrue(outcome.deferred)
        XCTAssertTrue(LineRecordingRepair.hasMarker(folder))
        // The cut-off Recording.json was not repaired either.
        XCTAssertTrue(try LineRecordingRepair.loadInfo(folder: folder).repaired)
    }

    func testAFolderThatNeverReceivedAFrameIsRemoved() throws {
        let folder = try makeUnsavedRecording(frames: nil)
        let outcome = LineRecordingRecovery.scan(root: root, active: ActiveFolderSet())
        XCTAssertTrue(outcome.recovered.isEmpty)
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testARecordingWithAScanRecordIsRepairedButNotReportedAgain() throws {
        let folder = try makeUnsavedRecording(frames: 5, withScanJSON: true)
        XCTAssertTrue(LineRecordingRecovery.scan(root: root, active: ActiveFolderSet()).recovered.isEmpty)
        XCTAssertFalse(LineRecordingRepair.hasMarker(folder))
        XCTAssertEqual(try LineRecordingRepair.loadInfo(folder: folder).info.frames.count, 4)
    }

    func testAnUnreadableRecordingIsKeptForALaterAttempt() throws {
        let folder = try makeUnsavedRecording(frames: nil)
        let url = folder.appendingPathComponent("Recording.json")
        try Data("{\"depthW".utf8).write(to: url)
        try ageFolder(folder)
        // F-6: an unreadable recording is reported in `failed` (shown as a library notice) and kept marked.
        let outcome = LineRecordingRecovery.scan(root: root, active: ActiveFolderSet())
        XCTAssertTrue(outcome.recovered.isEmpty)
        XCTAssertEqual(Array(outcome.failed.keys), ["line_2026-11-10_101500"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(LineRecordingRepair.hasMarker(folder))
    }

    func testAnUnreadableSavedScanIsKeptMarkedButNotReported() throws {
        // G-1: a saved scan (readable scan.json) is under Saved scans; reporting it would repeat the
        // "kept under Incomplete scans" notice on every pass.
        let folder = try makeUnsavedRecording(frames: nil, withScanJSON: true)
        try Data("{\"depthW".utf8).write(to: folder.appendingPathComponent("Recording.json"))
        try ageFolder(folder)
        let outcome = LineRecordingRecovery.scan(root: root, active: ActiveFolderSet())
        XCTAssertTrue(outcome.recovered.isEmpty)
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertFalse(outcome.deferred)
        // Still marked, so a later pass (after storage is freed) can repair it; the file is left as it was.
        XCTAssertTrue(LineRecordingRepair.hasMarker(folder))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Recording.json"), encoding: .utf8),
                       "{\"depthW")
    }

    func testAnUnreadableRecordingWithADamagedScanRecordIsReported() throws {
        // A scan.json the library cannot read leaves the folder under Incomplete scans, so the failure is shown.
        let folder = try makeUnsavedRecording(frames: nil)
        try Data("{\"depthW".utf8).write(to: folder.appendingPathComponent("Recording.json"))
        try Data("not json".utf8).write(to: folder.appendingPathComponent("scan.json"))
        try ageFolder(folder)
        XCTAssertFalse(ScanStore.hasReadableRecord(in: folder))
        let outcome = LineRecordingRecovery.scan(root: root, active: ActiveFolderSet())
        XCTAssertEqual(Array(outcome.failed.keys), ["line_2026-11-10_101500"])
        XCTAssertTrue(LineRecordingRepair.hasMarker(folder))
    }

    func testFoldersWithoutTheMarkerOrTheLinePrefixAreIgnored() throws {
        let unmarked = try makeUnsavedRecording(stamp: "2026-11-10_090000", frames: 5)
        LineRecordingRepair.clearMarker(in: unmarked)
        let other = root.appendingPathComponent("room_2026-11-10_080000", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: other.appendingPathComponent(LineRecorder.inProgressMarker).path,
                                       contents: nil)
        let outcome = LineRecordingRecovery.scan(root: root, active: ActiveFolderSet())
        XCTAssertTrue(outcome.recovered.isEmpty)
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertFalse(outcome.deferred)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertTrue(LineRecordingRepair.hasMarker(other))
    }
}

/// The text written to Frames.csv and ZoneSpeeds.csv row by row, and the other small recording helpers.
final class RecordingRowTests: XCTestCase {
    func testFramesHeaderHasFifteenColumns() {
        XCTAssertEqual(LineRecorder.framesHeader.count, 15)
        XCTAssertEqual(LineRecorder.framesHeader.first, "frame")
        XCTAssertEqual(LineRecorder.framesHeader.last, "fastest_zone")
    }

    func testFramesRowWithOnlyTheRequiredFields() {
        let row = LineRecorder.framesRow(makeFrame(index: 3, time: 0.1, speed: 219, travel: 12.34, medianDepth: 1000))
        XCTAssertEqual(row, "3,0.1000,219.0,13.140,12.3,,,1.000,1000.0,,,,,,")
        XCTAssertEqual(row.split(separator: ",", omittingEmptySubsequences: false).count, 15)
    }

    func testFramesRowWithEveryFieldAndNoSpeed() {
        var f = makeFrame(index: 7, time: 2.5, speed: nil, travel: -4.26, medianDepth: 1234.56)
        f.shiftPixels = 1.234
        f.crossShiftPixels = -0.5
        f.tiltX = 0.1
        f.tiltY = -0.25
        f.surfaceTiltX = 1.5
        f.surfaceTiltY = 2
        f.fastestSpeed = 250.04
        f.fastestTile = 9
        let row = LineRecorder.framesRow(f)
        XCTAssertEqual(row, "7,2.5000,,,-4.3,1.23,-0.50,1.000,1234.6,0.10,-0.25,1.50,2.00,250.0,9")
        XCTAssertEqual(row.split(separator: ",", omittingEmptySubsequences: false).count, 15)
    }

    func testZonesHeaderNamesEveryZone() {
        XCTAssertEqual(LineRecorder.zonesHeader(columns: 2, rows: 2),
                       ["frame", "time_s", "zone0_across0_along0_mm_s", "zone1_across1_along0_mm_s",
                        "zone2_across0_along1_mm_s", "zone3_across1_along1_mm_s"])
        XCTAssertEqual(LineRecorder.zonesHeader(columns: SpeedEstimator.tileColumns,
                                                rows: SpeedEstimator.tileRows).count,
                       2 + SpeedEstimator.tileColumns * SpeedEstimator.tileRows)
    }

    func testZonesRowLeavesMissingZonesBlank() {
        var f = makeFrame(index: 2, time: 0.5)
        f.tileSpeeds = [100.04, nil, -5]
        XCTAssertEqual(LineRecorder.zonesRow(f, count: 4), "2,0.5000,100.0,,-5.0,")
        XCTAssertEqual(LineRecorder.zonesRow(makeFrame(index: 0, time: 0), count: 2), "0,0.0000,,")
    }

    func testSanitizedFrameHasNoNonFiniteNumbers() throws {
        var f = makeFrame(index: 1, time: .nan, speed: .infinity, travel: -.infinity, medianDepth: .nan,
                          fx: .nan, fy: .infinity, cx: 32, cy: -.infinity)
        f.shiftPixels = .nan
        f.crossShiftPixels = 2
        f.tiltX = .infinity
        f.surfaceTiltY = .nan
        f.tileSpeeds = [10, .nan, nil, -.infinity]
        f.fastestSpeed = .nan
        f.fastestTile = 3
        let clean = f.sanitized()
        XCTAssertEqual(clean.index, 1)
        XCTAssertEqual(clean.time, 0)
        XCTAssertNil(clean.speed)
        XCTAssertEqual(clean.travel, 0)
        XCTAssertEqual(clean.medianDepth, 0)
        XCTAssertEqual(clean.fx, 0)
        XCTAssertEqual(clean.fy, 0)
        XCTAssertEqual(clean.cx, 32)
        XCTAssertEqual(clean.cy, 0)
        XCTAssertNil(clean.shiftPixels)
        XCTAssertEqual(clean.crossShiftPixels, 2)
        XCTAssertNil(clean.tiltX)
        XCTAssertNil(clean.surfaceTiltY)
        let zones = try XCTUnwrap(clean.tileSpeeds)
        XCTAssertEqual(zones.count, 4)
        XCTAssertEqual(zones[0], 10)
        XCTAssertNil(zones[1])
        XCTAssertNil(zones[2])
        XCTAssertNil(zones[3])
        XCTAssertNil(clean.fastestSpeed)
        XCTAssertNil(clean.fastestTile)        // a zone without a speed is dropped too
        // The sanitized frame can be encoded (the encoder refuses NaN and infinity).
        XCTAssertNoThrow(try JSONEncoder().encode(clean))
    }

    func testSanitizedKeepsAFiniteFrameAsItIs() {
        var f = makeFrame(index: 4, time: 1.5, speed: 220, travel: 33, medianDepth: 950)
        f.fastestSpeed = 300
        f.fastestTile = 5
        let clean = f.sanitized()
        XCTAssertEqual(clean.time, 1.5)
        XCTAssertEqual(clean.speed, 220)
        XCTAssertEqual(clean.travel, 33)
        XCTAssertEqual(clean.fastestSpeed, 300)
        XCTAssertEqual(clean.fastestTile, 5)
    }

    func testStorageThresholdsAndText() {
        XCTAssertGreaterThan(LineStorage.minimumToStart, LineStorage.stopBelow)
        XCTAssertEqual(LineStorage.text(850_000_000), "850 MB")
        XCTAssertEqual(LineStorage.text(1_000_000_000), "1.0 GB")
        XCTAssertEqual(LineStorage.text(2_540_000_000), "2.5 GB")
        XCTAssertEqual(LineStorage.text(-5), "0 MB")
    }

    func testFreeBytesOfAnExistingFolderIsKnown() throws {
        let folder = try makeTempFolder()
        let free = try XCTUnwrap(LineStorage.freeBytes(at: folder))
        XCTAssertGreaterThan(free, 0)
    }
}
