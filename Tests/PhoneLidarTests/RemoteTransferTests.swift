import XCTest

final class RemoteTransferTests: XCTestCase {
    private func file(_ name: String, _ size: Int64, _ modified: Double = 100) -> RemoteFileInfo {
        RemoteFileInfo(name: name, size: size, modified: modified)
    }

    private func scan(_ files: [RemoteFileInfo], id: UUID = UUID()) -> RemoteScanInfo {
        RemoteScanInfo(id: id, name: "Line 12 Nov 2026 at 07:48", created: Date(timeIntervalSince1970: 1_731_400_000),
                       summary: ["900 frames, 30.0 s, travel right → left"], files: files)
    }

    func testPlainNames() {
        for good in ["Video.mov", "TopoReplay_12.5s.png", "Depth.bin", String(repeating: "a", count: 255)] {
            XCTAssertTrue(RemoteFiles.isPlainName(good), good)
        }
        for bad in ["", ".", "..", ".transfer.json", "../Video.mov", "a/b", "a\\b", "nul\0x", String(repeating: "a", count: 256)] {
            XCTAssertFalse(RemoteFiles.isPlainName(bad), bad)
        }
    }

    func testListOffersPlainTopLevelFilesSmallestFirst() throws {
        let folder = try makeTempFolder()
        try Data(count: 300).write(to: folder.appendingPathComponent("Video.mov"))
        try Data(count: 20).write(to: folder.appendingPathComponent("TopoStats.csv"))
        try Data(count: 20).write(to: folder.appendingPathComponent("Frames.csv"))
        try Data(count: 5).write(to: folder.appendingPathComponent("scan.json"))
        try Data(count: 5).write(to: folder.appendingPathComponent(".recording-in-progress"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Images"), withIntermediateDirectories: true)
        try Data(count: 5).write(to: folder.appendingPathComponent("Images/photo.heic"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Link.bin"),
                                                   withDestinationURL: folder.appendingPathComponent("Video.mov"))
        let files = RemoteFiles.list(folder: folder)
        XCTAssertEqual(files.map(\.name), ["Frames.csv", "TopoStats.csv", "Video.mov"])
        XCTAssertEqual(files.map(\.size), [20, 20, 300])
        XCTAssertTrue(files.allSatisfy { $0.modified > 1_600_000_000 })
        XCTAssertEqual(RemoteFiles.list(folder: folder.appendingPathComponent("missing")), [])
        XCTAssertNil(RemoteFiles.info(of: folder.appendingPathComponent("Images")))
        XCTAssertNil(RemoteFiles.info(of: folder.appendingPathComponent("Link.bin")))
        XCTAssertEqual(RemoteFiles.info(of: folder.appendingPathComponent("Video.mov"))?.size, 300)
    }

    func testMatches() {
        let info = file("Depth.bin", 1_000, 1_731_400_123.456)
        XCTAssertTrue(RemoteFiles.matches(info, size: 1_000, modified: 1_731_400_123.4565))
        XCTAssertFalse(RemoteFiles.matches(info, size: 1_001, modified: 1_731_400_123.456))
        XCTAssertFalse(RemoteFiles.matches(info, size: 1_000, modified: 1_731_400_124))
    }

    func testResumeOffset() {
        let chunk: Int64 = 100
        XCTAssertEqual(RemoteFiles.resumeOffset(stagedSize: nil, expectedSize: 1_000, chunk: chunk), 0)
        XCTAssertEqual(RemoteFiles.resumeOffset(stagedSize: 0, expectedSize: 1_000, chunk: chunk), 0)
        XCTAssertEqual(RemoteFiles.resumeOffset(stagedSize: 99, expectedSize: 1_000, chunk: chunk), 0)
        XCTAssertEqual(RemoteFiles.resumeOffset(stagedSize: 150, expectedSize: 1_000, chunk: chunk), 0)
        XCTAssertEqual(RemoteFiles.resumeOffset(stagedSize: 250, expectedSize: 1_000, chunk: chunk), 100)
        XCTAssertEqual(RemoteFiles.resumeOffset(stagedSize: 300, expectedSize: 1_000, chunk: chunk), 200)
        XCTAssertEqual(RemoteFiles.resumeOffset(stagedSize: 999, expectedSize: 1_000, chunk: chunk), 800)
        XCTAssertEqual(RemoteFiles.resumeOffset(stagedSize: 1_000, expectedSize: 1_000, chunk: chunk), 1_000)
        XCTAssertEqual(RemoteFiles.resumeOffset(stagedSize: 1_001, expectedSize: 1_000, chunk: chunk), 0)
        XCTAssertEqual(RemoteFiles.resumeOffset(stagedSize: 600_000, expectedSize: 10_000_000), 262_144)
    }

    func testNeededFreeBytes() {
        XCTAssertEqual(RemoteFiles.neededFreeBytes(remaining: 1_000), 500_001_000)
        XCTAssertEqual(RemoteFiles.neededFreeBytes(remaining: -5), 500_000_000)
    }

    func testFilesToDiscardWhenTheScanChanged() {
        let old = scan([file("TopoMap.png", 10, 1), file("TopoStats.csv", 20, 1), file("Video.mov", 30, 1),
                        file("Gone.csv", 5, 1)])
        let new = scan([file("TopoMap.png", 10, 1), file("TopoStats.csv", 21, 1), file("Video.mov", 30, 2),
                        file("New.csv", 7, 1)], id: old.id)
        XCTAssertEqual(RemoteStaging.filesToDiscard(old: old, new: new), ["TopoStats.csv", "Video.mov", "Gone.csv"])
        XCTAssertEqual(RemoteStaging.filesToDiscard(old: old, new: old), [])
    }

    func testStagedBytesCompletenessAndSizesOnDisk() throws {
        let info = scan([file("A.csv", 10), file("B.bin", 100), file("C.mov", 1_000)])
        XCTAssertEqual(RemoteStaging.stagedBytes(sizes: [:], scan: info), 0)
        XCTAssertEqual(RemoteStaging.stagedBytes(sizes: ["A.csv": 10, "B.bin": 40, "C.mov": 5_000, "X": 9], scan: info), 1_050)
        XCTAssertFalse(RemoteStaging.isComplete(sizes: ["A.csv": 10, "B.bin": 100], scan: info))
        XCTAssertTrue(RemoteStaging.isComplete(sizes: ["A.csv": 10, "B.bin": 100, "C.mov": 1_000], scan: info))
        XCTAssertTrue(RemoteStaging.isComplete(sizes: [:], scan: scan([])))

        let folder = try makeTempFolder()
        try Data(count: 10).write(to: folder.appendingPathComponent("A.csv"))
        try Data(count: 40).write(to: folder.appendingPathComponent("B.bin"))
        XCTAssertEqual(RemoteStaging.stagedSizes(in: folder, scan: info), ["A.csv": 10, "B.bin": 40])
    }

    func testManifestRoundTripAndPaths() throws {
        let root = RemoteStaging.root(applicationSupport: try makeTempFolder())
        XCTAssertEqual(root.lastPathComponent, "RemoteIncoming")
        let info = scan([file("Video.mov", 30, 1_731_400_123.5)])
        let folder = RemoteStaging.folder(for: info.id, root: root)
        XCTAssertEqual(folder.lastPathComponent, info.id.uuidString)
        XCTAssertNil(RemoteStaging.loadManifest(in: folder))
        let manifest = RemoteStagingManifest(scan: info, scannerName: "iPhone 1A2B", started: Date(timeIntervalSince1970: 1_731_400_200))
        try RemoteStaging.saveManifest(manifest, in: folder)
        XCTAssertEqual(RemoteStaging.loadManifest(in: folder), manifest)
        // The manifest is hidden, so it is never offered or counted as a scan file.
        XCTAssertFalse(RemoteFiles.isPlainName(RemoteStaging.manifestName))
        XCTAssertEqual(RemoteFiles.list(folder: folder), [])
    }

    func testProgressRateAndTimeLeft() {
        var progress = TransferProgress(total: 100_000_000, done: 10_000_000)
        XCTAssertEqual(progress.fraction, 0.1, accuracy: 1e-12)
        XCTAssertNil(progress.rate)
        XCTAssertNil(progress.secondsLeft)
        progress.update(done: 10_000_000, time: 10)
        progress.update(done: 12_000_000, time: 10.2)              // under 0.5 s: no sample
        XCTAssertNil(progress.rate)
        XCTAssertEqual(progress.done, 12_000_000)
        progress.update(done: 20_000_000, time: 11)                // 10 MB/s
        XCTAssertEqual(progress.rate ?? 0, 10_000_000, accuracy: 1)
        progress.update(done: 40_000_000, time: 12)                // 20 MB/s → 0.7·10 + 0.3·20 = 13
        XCTAssertEqual(progress.rate ?? 0, 13_000_000, accuracy: 1)
        XCTAssertEqual(progress.secondsLeft ?? 0, 60_000_000 / 13_000_000, accuracy: 1e-9)
        progress.update(done: 30_000_000, time: 13)                // a resumed file starting earlier: no sample
        XCTAssertEqual(progress.rate ?? 0, 13_000_000, accuracy: 1)
        progress.update(done: 500_000_000, time: 14)               // clamped to the total
        XCTAssertEqual(progress.done, 100_000_000)
        XCTAssertEqual(progress.fraction, 1)
        progress.resetRate()
        XCTAssertNil(progress.rate)
        XCTAssertEqual(TransferProgress(total: 0).fraction, 0)
        XCTAssertEqual(TransferProgress(total: 10, done: 50).done, 10)
    }

    func testProgressText() {
        var progress = TransferProgress(total: 1_000_000_000)
        XCTAssertTrue(progress.text.contains(" of "), progress.text)
        XCTAssertFalse(progress.text.contains("left"))
        progress.update(done: 0, time: 0)
        progress.update(done: 10_000_000, time: 1)
        XCTAssertTrue(progress.text.contains("/s"), progress.text)
        XCTAssertTrue(progress.text.hasSuffix("2 min left"), progress.text)        // 99 s → 2 min
        XCTAssertEqual(TransferProgress.timeLeftText(42.4), "42 s left")
        XCTAssertEqual(TransferProgress.timeLeftText(0.2), "1 s left")
        XCTAssertEqual(TransferProgress.timeLeftText(61), "2 min left")
    }

    func testImportRecordKeepsTheScannersIdentity() {
        let info = scan([file("Video.mov", 30)])
        let copied = Date(timeIntervalSince1970: 1_731_500_000)
        let record = RemoteImport.record(from: info, scannerName: "iPhone 1A2B", folderName: "line_2026-11-12_080000",
                                         copied: copied)
        XCTAssertEqual(record.id, info.id)
        XCTAssertEqual(record.kind, .line)
        XCTAssertEqual(record.name, info.name)
        XCTAssertEqual(record.created, info.created)
        XCTAssertEqual(record.folderName, "line_2026-11-12_080000")
        XCTAssertNil(record.primaryModel)
        XCTAssertEqual(record.summary.count, 2)
        XCTAssertEqual(record.summary.first, info.summary.first)
        XCTAssertTrue(record.summary.last?.hasPrefix("Copied from iPhone 1A2B on ") == true, record.summary.last ?? "")
        XCTAssertTrue(record.summary.last?.hasSuffix(".") == true)
    }
}
