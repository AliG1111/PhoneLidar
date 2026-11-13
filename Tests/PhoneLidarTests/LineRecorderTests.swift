import AVFoundation
import CoreMedia
import CoreVideo
import XCTest

/// LineRecorder from the first appended frame to `finish` (Z-9), with synthetic camera buffers: frame index, time,
/// travel offset, counts, notes, sanitizing and the files it leaves. The video track is not checked (the simulator's
/// encoder may skip frames); depth and frame data never depend on it.
final class LineRecorderTests: XCTestCase {
    private let depthWidth = 16
    private let depthHeight = 12

    override func setUpWithError() throws {
        // AVAssetWriterInput raises an Objective-C exception for a codec it cannot encode.
        guard AVOutputSettingsAssistant.availableOutputSettingsPresets().contains(.hevc1920x1080) else {
            throw XCTSkip("No HEVC encoder on this simulator")
        }
    }

    /// A 320 × 240 video frame presented at `time` seconds.
    private func sampleBuffer(at time: Double) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        let created = CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                          attributes, &pixelBuffer)
        XCTAssertEqual(created, kCVReturnSuccess)
        let image = try XCTUnwrap(pixelBuffer)
        var format: CMVideoFormatDescription?
        let described = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                                                                     formatDescriptionOut: &format)
        XCTAssertEqual(described, 0)
        let description = try XCTUnwrap(format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 20, timescale: 600),
                                        presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 600),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let made = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                                                            formatDescription: description, sampleTiming: &timing,
                                                            sampleBufferOut: &sample)
        XCTAssertEqual(made, 0)
        return try XCTUnwrap(sample)
    }

    /// Frame info as the capture pipeline passes it: index and time are placeholders, travel is the session total.
    private func info(speed: Double?, travel: Double) -> LineFrameInfo {
        var tiles = [Double?](repeating: 120, count: 24)
        tiles[5] = nil
        return LineFrameInfo(index: 0, time: 0, speed: speed, travel: travel, shiftPixels: 3.25, crossShiftPixels: -0.5,
                             quality: 0.8, medianDepth: 1000, fx: 14, fy: 14, cx: 8, cy: 6,
                             tiltX: 0.5, tiltY: -1.25, surfaceTiltX: 0.25, surfaceTiltY: 0.75,
                             tileSpeeds: tiles, fastestSpeed: 120, fastestTile: 0)
    }

    private func makeRecorder(in folder: URL, travelOffset: Double) throws -> LineRecorder {
        try LineRecorder(folder: folder, videoWidth: 320, videoHeight: 240, depthWidth: depthWidth,
                         depthHeight: depthHeight, filteredDepth: true, shortShutter: false, direction: .leftToRight,
                         travelOffset: travelOffset)
    }

    /// Calls `finish` and waits for its completion.
    private func finish(_ recorder: LineRecorder) throws -> LineRecordingResult {
        final class Box: @unchecked Sendable {      // written once on the finish queue, read after the wait
            let lock = NSLock()
            var result: LineRecordingResult?
        }
        let box = Box()
        let done = expectation(description: "finish")
        recorder.finish { result in
            box.lock.withLock { box.result = result }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(box.lock.withLock { box.result })
    }

    private func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    func testAppendThenFinishWritesNumberedFramesWithRelativeTimeAndTravel() throws {
        let folder = try makeTempFolder()
        let recorder = try makeRecorder(in: folder, travelOffset: 100)
        XCTAssertTrue(LineRecordingRepair.hasMarker(folder))       // marked from the start
        for i in 0..<10 {
            // Camera clock starts at 50 s; the session travel is 100 mm when the recording starts.
            let depth = [Float](repeating: Float(1000 + i), count: depthWidth * depthHeight)
            recorder.append(sampleBuffer: try sampleBuffer(at: 50 + Double(i) / 30), depthMillimetres: depth,
                            info: info(speed: i == 4 ? nil : 150, travel: 100 + 5 * Double(i)))
            XCTAssertEqual(recorder.frameCount, i + 1)
        }
        XCTAssertNil(recorder.stopReason)
        XCTAssertEqual(recorder.elapsed, 9.0 / 30, accuracy: 1e-9)
        recorder.addNote("Baseline note.")

        let result = try finish(recorder)
        XCTAssertEqual(result.folder, folder)
        XCTAssertEqual(result.frameCount, 10)
        XCTAssertEqual(result.duration, 9.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(result.direction, .leftToRight)
        XCTAssertTrue(result.notes.contains("Baseline note."))
        XCTAssertFalse(result.notes.contains { $0.contains(".csv is incomplete") }, result.notes.joined(separator: "\n"))
        // The marker stays until the map step has read Recording.json back.
        XCTAssertTrue(LineRecordingRepair.hasMarker(folder))

        let loaded = try LineRecordingRepair.loadInfo(folder: folder)
        XCTAssertFalse(loaded.repaired)
        let recording = loaded.info
        XCTAssertEqual(recording.depthWidth, depthWidth)
        XCTAssertEqual(recording.depthHeight, depthHeight)
        XCTAssertEqual(recording.videoWidth, 320)
        XCTAssertEqual(recording.videoHeight, 240)
        XCTAssertEqual(recording.direction, .leftToRight)
        XCTAssertEqual(recording.filteredDepth, true)
        XCTAssertEqual(recording.shortShutter, false)
        XCTAssertEqual(recording.tileColumns, 6)
        XCTAssertEqual(recording.tileRows, 4)
        XCTAssertEqual(recording.frames.map(\.index), Array(0..<10))
        for (i, frame) in recording.frames.enumerated() {
            XCTAssertEqual(frame.time, Double(i) / 30, accuracy: 1e-9)
            XCTAssertEqual(frame.travel, 5 * Double(i), accuracy: 1e-9)      // travel offset subtracted
        }
        XCTAssertNil(recording.frames[4].speed)
        XCTAssertEqual(recording.frames[3].speed, 150)
        let tiles = try XCTUnwrap(recording.frames[0].tileSpeeds)
        XCTAssertEqual(tiles.count, 24)
        XCTAssertNil(tiles[5])
        XCTAssertEqual(tiles[0], 120)
        XCTAssertEqual(recording.summaryLine, "10 frames, 0.3 s, material travel Left → Right")

        let depth = try DepthFileReader(url: folder.appendingPathComponent("Depth.bin"))
        XCTAssertEqual(depth.frameCount, 10)
        XCTAssertEqual(depth.width, depthWidth)
        XCTAssertEqual(depth.height, depthHeight)
        XCTAssertEqual(try XCTUnwrap(depth.frame(7)?.first), 1007, accuracy: 0.05)

        let frames = try lines(folder.appendingPathComponent("Frames.csv"))
        XCTAssertEqual(frames.count, 12)            // header, 10 rows, the empty string after the last newline
        XCTAssertEqual(frames[0], LineRecorder.framesHeader.joined(separator: ","))
        XCTAssertTrue(frames[1].hasPrefix("0,0.0000,150.0,9.000,0.0,3.25,-0.50,0.800,1000.0,"), frames[1])
        XCTAssertTrue(frames[10].hasPrefix("9,0.3000,150.0,"), frames[10])
        XCTAssertEqual(frames[11], "")
        let zones = try lines(folder.appendingPathComponent("ZoneSpeeds.csv"))
        XCTAssertEqual(zones.count, 12)
        XCTAssertEqual(zones[0], LineRecorder.zonesHeader(columns: 6, rows: 4).joined(separator: ","))
        XCTAssertTrue(zones[1].hasPrefix("0,0.0000,120.0,120.0,120.0,120.0,120.0,,120.0"), zones[1])
    }

    /// The camera-parallax builder pairs video samples with frames using these marks (design §15.7, S2).
    func testVideoSkippedMarksMatchTheSamplesInVideoMov() async throws {
        let folder = try makeTempFolder()
        let recorder = try makeRecorder(in: folder, travelOffset: 0)
        let depth = [Float](repeating: 1000, count: depthWidth * depthHeight)
        for i in 0..<20 {
            recorder.append(sampleBuffer: try sampleBuffer(at: 10 + Double(i) / 30), depthMillimetres: depth,
                            info: info(speed: 150, travel: Double(i)))
        }
        let done = expectation(description: "finish")
        recorder.finish { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 30)
        let frames = try LineRecordingRepair.loadInfo(folder: folder).info.frames
        XCTAssertEqual(frames.count, 20)
        let written = ParallaxGeometry.videoFrameIndices(frames).count
        var decoded = 0
        if written > 0 {
            let asset = AVURLAsset(url: folder.appendingPathComponent("Video.mov"))
            let track = try await asset.loadTracks(withMediaType: .video).first
            let videoTrack = try XCTUnwrap(track)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            while let sample = output.copyNextSampleBuffer() {
                if CMSampleBufferGetNumSamples(sample) > 0 { decoded += 1 }
            }
        }
        XCTAssertEqual(decoded, written)
    }

    func testNonFiniteNumbersNeverReachTheFiles() throws {
        let folder = try makeTempFolder()
        let recorder = try makeRecorder(in: folder, travelOffset: 0)
        var bad = info(speed: .nan, travel: .infinity)
        bad.tiltX = .nan
        bad.surfaceTiltY = -.infinity
        bad.medianDepth = .nan
        bad.tileSpeeds = [.infinity, 5]
        bad.fastestSpeed = .nan
        for i in 0..<3 {
            recorder.append(sampleBuffer: try sampleBuffer(at: Double(i) / 30),
                            depthMillimetres: [Float](repeating: .nan, count: depthWidth * depthHeight), info: bad)
        }
        // JSONEncoder throws on NaN and inf: an unsanitized frame would have stopped the recording.
        XCTAssertNil(recorder.stopReason)
        let result = try finish(recorder)
        XCTAssertEqual(result.frameCount, 3)
        let text = try String(contentsOf: folder.appendingPathComponent("Recording.json"), encoding: .utf8)
            + String(contentsOf: folder.appendingPathComponent("Frames.csv"), encoding: .utf8)
            + String(contentsOf: folder.appendingPathComponent("ZoneSpeeds.csv"), encoding: .utf8)
        XCTAssertFalse(text.lowercased().contains("nan"))
        XCTAssertFalse(text.lowercased().contains("inf"))
        let frame = try XCTUnwrap(LineRecordingRepair.loadInfo(folder: folder).info.frames.last)
        XCTAssertNil(frame.speed)
        XCTAssertEqual(frame.travel, 0)
        XCTAssertEqual(frame.medianDepth, 0)
        XCTAssertNil(frame.tiltX)
        XCTAssertNil(frame.surfaceTiltY)
        XCTAssertNil(frame.fastestSpeed)
        XCTAssertNil(frame.fastestTile)
        let tiles = try XCTUnwrap(frame.tileSpeeds)
        XCTAssertEqual(tiles.count, 2)
        XCTAssertNil(tiles[0])
        XCTAssertEqual(tiles[1], 5)
        // NaN depth is stored as "no data".
        let depth = try DepthFileReader(url: folder.appendingPathComponent("Depth.bin"))
        XCTAssertEqual(depth.frame(2)?.allSatisfy { $0 == 0 }, true)
    }

    func testFinishWithoutFramesLeavesAValidEmptyRecording() throws {
        let folder = try makeTempFolder()
        let recorder = try makeRecorder(in: folder, travelOffset: 42)
        let result = try finish(recorder)
        XCTAssertEqual(result.frameCount, 0)
        XCTAssertEqual(result.duration, 0)
        // No frame reached the video encoder, so there is no video note either.
        XCTAssertTrue(result.notes.isEmpty, result.notes.joined(separator: "\n"))
        let loaded = try LineRecordingRepair.loadInfo(folder: folder)
        XCTAssertFalse(loaded.repaired)
        XCTAssertTrue(loaded.info.frames.isEmpty)
        XCTAssertEqual(try DepthFileReader(url: folder.appendingPathComponent("Depth.bin")).frameCount, 0)
        XCTAssertEqual(try lines(folder.appendingPathComponent("Frames.csv")).count, 2)      // header only
    }

    func testAShortDepthFrameIsPaddedWithNoData() throws {
        // A frame with a depth array of the wrong length is still written (missing pixels = no data) and counted.
        let folder = try makeTempFolder()
        let recorder = try makeRecorder(in: folder, travelOffset: 0)
        recorder.append(sampleBuffer: try sampleBuffer(at: 0), depthMillimetres: [500, 600], info: info(speed: 1, travel: 0))
        XCTAssertEqual(recorder.frameCount, 1)
        _ = try finish(recorder)
        let depth = try DepthFileReader(url: folder.appendingPathComponent("Depth.bin"))
        let frame = try XCTUnwrap(depth.frame(0))
        XCTAssertEqual(frame[0], 500, accuracy: 0.05)
        XCTAssertEqual(frame[1], 600, accuracy: 0.05)
        XCTAssertTrue(frame.dropFirst(2).allSatisfy { $0 == 0 })
    }
}

/// Folder protection while a line recording writes to a folder (`ScanStore.beginLineRecording`, Z-9). The store
/// works in the Documents/Scans folder of the test process; every folder made here is unique and removed at the end.
final class ScanStoreActiveRecordingTests: XCTestCase {
    @MainActor
    private func makeRecordingFolder(in store: ScanStore) throws -> (name: String, url: URL) {
        let name = "zz-unit-test-line-\(UUID().uuidString)"
        let url = store.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.appendingPathComponent(LineRecorder.inProgressMarker).path, contents: nil)
        try Data("partial".utf8).write(to: url.appendingPathComponent("Depth.bin"))
        return (name, url)
    }

    @MainActor
    func testAnActiveRecordingFolderIsNeitherListedNorDeletedAsIncomplete() throws {
        let store = ScanStore()
        let folder = try makeRecordingFolder(in: store)
        store.beginLineRecording(folder.name)
        store.reload()
        XCTAssertNil(store.incompleteScan(named: folder.name))
        XCTAssertFalse(store.deleteIncomplete(folderName: folder.name))
        store.discard(folderName: folder.name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("Depth.bin").path))

        // Once the recording has ended the folder is an incomplete scan again and can be deleted.
        store.endLineRecording(folder.name)
        store.reload()
        XCTAssertNotNil(store.incompleteScan(named: folder.name))
        XCTAssertTrue(store.deleteIncomplete(folderName: folder.name))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.url.path))
    }

    @MainActor
    func testAnActiveRecordingThatIsAlreadySavedIsListedAsASavedScan() throws {
        // After Stop the scan record is saved while the map is still being built (the folder stays active).
        let store = ScanStore()
        let folder = try makeRecordingFolder(in: store)
        store.beginLineRecording(folder.name)
        let record = ScanRecord(id: UUID(), kind: .line, name: "Line test", created: Date(), folderName: folder.name,
                                primaryModel: nil, summary: ["1 frames, 0.0 s, material travel Right → Left"])
        try store.save(record)
        XCTAssertEqual(store.record(id: record.id)?.folderName, folder.name)
        XCTAssertNil(store.incompleteScan(named: folder.name))
        XCTAssertEqual(store.record(id: record.id)?.files, ["Depth.bin"])
        store.endLineRecording(folder.name)
    }

    @MainActor
    func testRecoveryWaitsWhileARecordingIsActive() throws {
        let store = ScanStore()
        let folder = try makeRecordingFolder(in: store)
        store.beginLineRecording(folder.name)
        XCTAssertTrue(store.activeLineFolders.contains(folder.name))
        store.recoverLineRecordings()
        // No pass starts next to a running recording; one is queued for when it ends.
        XCTAssertFalse(store.recoveryRunning)
        XCTAssertTrue(store.recoveryRerunRequested)
        XCTAssertTrue(LineRecordingRepair.hasMarker(folder.url))
        // Ending the recording would run the queued pass, which needs the app (background task): not here.
        store.recoveryRerunRequested = false
        store.endLineRecording(folder.name)
        XCTAssertFalse(store.activeLineFolders.contains(folder.name))
        XCTAssertFalse(store.recoveryRunning)
    }
}
