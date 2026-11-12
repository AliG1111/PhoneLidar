import XCTest

/// Command refusals, status texts, copy rows, scan-list size and acceptance, and the scanner's pairing attempts.
final class RemoteRulesTests: XCTestCase {
    private func status(_ phase: RemotePhase, calibrating: Bool = false, failure: String? = nil) -> RemoteStatus {
        var status = RemoteStatus()
        status.lineScanOpen = phase != .closed
        status.phase = phase
        status.calibrating = calibrating
        status.failure = failure
        return status
    }

    // MARK: Commands

    func testStartRefusals() {
        XCTAssertNil(RemoteCommandRules.startRefusal(status(.ready), closing: false))
        XCTAssertEqual(RemoteCommandRules.startRefusal(status(.ready), closing: true), RemoteCommandRules.closingText)
        XCTAssertEqual(RemoteCommandRules.startRefusal(status(.ready, calibrating: true), closing: false),
                       "The scanner is calibrating the baseline.")
        XCTAssertEqual(RemoteCommandRules.startRefusal(status(.failed, failure: "Camera access is off"), closing: false),
                       "Camera access is off")
        for phase in [RemotePhase.closed, .starting, .arming, .recording, .saving, .building, .failed] {
            XCTAssertNotNil(RemoteCommandRules.startRefusal(status(phase), closing: false), phase.rawValue)
        }
    }

    func testStopRefusals() {
        for phase in [RemotePhase.arming, .recording] {
            XCTAssertNil(RemoteCommandRules.stopRefusal(status(phase), closing: false), phase.rawValue)
            XCTAssertEqual(RemoteCommandRules.stopRefusal(status(phase), closing: true), RemoteCommandRules.closingText)
        }
        for phase in [RemotePhase.closed, .starting, .ready, .saving, .building, .failed] {
            XCTAssertEqual(RemoteCommandRules.stopRefusal(status(phase), closing: false), "The scanner is not recording.")
        }
    }

    // MARK: Texts

    func testStatusTexts() {
        XCTAssertEqual(RemoteStatusText.phase(nil), "Waiting for the scanner's status…")
        var recording = status(.recording)
        recording.elapsed = 125.9
        recording.frames = 3_777
        XCTAssertEqual(RemoteStatusText.phase(recording), "● REC 2:05 · 3777 frames")
        XCTAssertEqual(RemoteStatusText.phase(status(.ready)), "Ready")
        XCTAssertEqual(RemoteStatusText.phase(status(.ready, calibrating: true)), "Calibrating baseline…")
        XCTAssertEqual(RemoteStatusText.phase(status(.closed)), "Line scan is not open on the scanner")
        // Out-of-range numbers from the other phone do not trap (R-3).
        var hostile = status(.recording)
        hostile.elapsed = 1e300
        hostile.frames = -4
        XCTAssertFalse(RemoteStatusText.phase(hostile).isEmpty)
        let clean = hostile.sanitized()
        XCTAssertEqual(clean.elapsed, 1e9)
        XCTAssertEqual(clean.frames, 0)

        var warned = status(.recording)
        warned.banner = "Phone is hot"
        warned.warnings = ["Baseline coverage only 70 %", "Phone is hot", "Baseline coverage only 70 %"]
        XCTAssertEqual(RemoteStatusText.alerts(warned), ["Phone is hot", "Baseline coverage only 70 %"])
        XCTAssertEqual(RemoteStatusText.alerts(status(.ready)), [])

        XCTAssertEqual(RemoteStatusText.heat(.critical), "Too hot: recording stopped")
        var battery = status(.ready)
        XCTAssertEqual(RemoteStatusText.battery(battery), "—")
        battery.battery = 0.83
        XCTAssertEqual(RemoteStatusText.battery(battery), "83 %")
        battery.charging = true
        XCTAssertEqual(RemoteStatusText.battery(battery), "83 % · charging")
        battery.charging = false
        XCTAssertEqual(RemoteStatusText.battery(battery), "83 % · on battery")
    }

    // MARK: Copy rows

    func testCopyRowKinds() {
        let progress = TransferProgress(total: 100, done: 40)
        func state(_ phase: RemoteCopyPhase) -> RemoteCopyState { RemoteCopyState(phase: phase, progress: progress) }
        XCTAssertEqual(RemoteCopyRow.kind(onThisPhone: true, state: state(.copying)), .open)
        XCTAssertEqual(RemoteCopyRow.kind(onThisPhone: false, state: nil), .copy)
        XCTAssertEqual(RemoteCopyRow.kind(onThisPhone: false, state: state(.queued)), .progress)
        XCTAssertEqual(RemoteCopyRow.kind(onThisPhone: false, state: state(.copying)), .progress)
        XCTAssertEqual(RemoteCopyRow.kind(onThisPhone: false, state: state(.waiting("busy"))), .progress)
        XCTAssertEqual(RemoteCopyRow.kind(onThisPhone: false, state: state(.paused)), .paused)
        XCTAssertEqual(RemoteCopyRow.kind(onThisPhone: false, state: state(.failed("disk full"))), .failed("disk full"))
        XCTAssertEqual(RemoteCopyRow.kind(onThisPhone: false, state: state(.importing)), .importing)
        // Copied, then deleted from this phone: the copy is offered again (B-2).
        XCTAssertEqual(RemoteCopyRow.kind(onThisPhone: false, state: state(.done)), .copy)
        XCTAssertEqual(RemoteCopyRow.kind(onThisPhone: true, state: state(.done)), .open)
    }

    // MARK: Scan lists from the other phone

    private func scan(_ files: [RemoteFileInfo], summaryLength: Int = 10) -> RemoteScanInfo {
        RemoteScanInfo(id: UUID(), name: "Line", created: Date(timeIntervalSince1970: 1_731_400_000),
                       summary: [String(repeating: "s", count: summaryLength)], files: files)
    }

    func testScanAcceptance() {
        let video = RemoteFileInfo(name: "Video.mov", size: 120_000_000, modified: 1)
        XCTAssertTrue(RemoteFiles.isAcceptable(scan([video, RemoteFileInfo(name: "Depth.bin", size: 0, modified: 2)])))
        XCTAssertFalse(RemoteFiles.isAcceptable(scan([])))
        XCTAssertFalse(RemoteFiles.isAcceptable(scan([RemoteFileInfo(name: "../x", size: 1, modified: 1)])))
        XCTAssertFalse(RemoteFiles.isAcceptable(scan([RemoteFileInfo(name: "scan.json", size: 1, modified: 1)])))
        XCTAssertFalse(RemoteFiles.isAcceptable(scan([video, video])))                         // duplicate name
        XCTAssertFalse(RemoteFiles.isAcceptable(scan([RemoteFileInfo(name: "a", size: -1, modified: 1)])))
        XCTAssertFalse(RemoteFiles.isAcceptable(scan([RemoteFileInfo(name: "a", size: 1, modified: .nan)])))
        XCTAssertFalse(RemoteFiles.isAcceptable(scan([RemoteFileInfo(name: "a", size: .max, modified: 1)])))
        let half = RemoteLinkConstants.maxScanBytes / 2 + 1
        XCTAssertFalse(RemoteFiles.isAcceptable(scan([RemoteFileInfo(name: "a", size: half, modified: 1),
                                                       RemoteFileInfo(name: "b", size: half, modified: 1)])))
    }

    func testTotalBytesNeverTraps() {
        let hostile = scan([RemoteFileInfo(name: "a", size: .max, modified: 1),
                            RemoteFileInfo(name: "b", size: .max, modified: 1),
                            RemoteFileInfo(name: "c", size: -5, modified: 1)])
        XCTAssertEqual(hostile.totalBytes, .max)
        XCTAssertEqual(scan([RemoteFileInfo(name: "c", size: -5, modified: 1)]).totalBytes, 0)
    }

    func testScanListFitsOneFrameKeepingTheNewest() throws {
        let scans = (0..<40).map { _ in scan([RemoteFileInfo(name: "Video.mov", size: 1, modified: 1)], summaryLength: 400) }
        let limit = 6_000
        let fitted = RemoteScanList.fitting(scans, limit: limit)
        XCTAssertFalse(fitted.isEmpty)
        XCTAssertLessThan(fitted.count, scans.count)
        XCTAssertEqual(fitted.map(\.id), scans.prefix(fitted.count).map(\.id))      // newest first, oldest dropped
        XCTAssertLessThanOrEqual(try RemoteRecord.message(.scans(fitted)).count, limit)
        XCTAssertEqual(RemoteScanList.fitting(Array(scans.prefix(3))).count, 3)
        XCTAssertEqual(RemoteScanList.fitting([scan([], summaryLength: 10_000)], limit: 1_000), [])
        XCTAssertEqual(RemoteScanList.fitting([]), [])
        let many = (0..<250).map { _ in scan([]) }
        XCTAssertEqual(RemoteScanList.fitting(many).count, RemoteLinkConstants.maxListedScans)
    }

    func testDuplicateScanIDsKeepTheNewest() {
        let first = scan([RemoteFileInfo(name: "a", size: 1, modified: 1)])
        var duplicate = scan([RemoteFileInfo(name: "b", size: 2, modified: 2)])
        duplicate = RemoteScanInfo(id: first.id, name: "copy", created: duplicate.created, summary: [], files: duplicate.files)
        let other = scan([RemoteFileInfo(name: "c", size: 3, modified: 3)])
        XCTAssertEqual(RemoteScanList.uniqueByID([first, duplicate, other]).map(\.name), ["Line", "Line"])
        XCTAssertEqual(RemoteScanList.uniqueByID([first, duplicate, other]).map(\.id), [first.id, other.id])
    }

    func testPartialCopiesAreFoundInTheStagingRoot() throws {
        let root = try makeTempFolder()
        XCTAssertEqual(RemoteStaging.partials(root: root.appendingPathComponent("missing")), [])
        let older = scan([RemoteFileInfo(name: "Video.mov", size: 100, modified: 1)])
        let newer = scan([RemoteFileInfo(name: "Depth.bin", size: 50, modified: 1)])
        let olderFolder = RemoteStaging.folder(for: older.id, root: root)
        try RemoteStaging.saveManifest(RemoteStagingManifest(scan: older, scannerName: "iPhone A", started: Date(timeIntervalSince1970: 1)),
                                       in: olderFolder)
        try Data(count: 40).write(to: olderFolder.appendingPathComponent("Video.mov"))
        try RemoteStaging.saveManifest(RemoteStagingManifest(scan: newer, scannerName: "iPhone B", started: Date(timeIntervalSince1970: 2)),
                                       in: RemoteStaging.folder(for: newer.id, root: root))
        // A folder whose name is not its manifest's scan ID, and a folder without a manifest, are ignored.
        try RemoteStaging.saveManifest(RemoteStagingManifest(scan: scan([]), scannerName: "x", started: Date()),
                                       in: root.appendingPathComponent("not-an-id"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: true)
        let partials = RemoteStaging.partials(root: root)
        XCTAssertEqual(partials.map(\.id), [newer.id, older.id])
        XCTAssertEqual(partials.map(\.stagedBytes), [0, 40])
        XCTAssertEqual(partials.last?.manifest.scannerName, "iPhone A")
    }

    // MARK: Scanner pairing attempts

    func testScannerSecretsAllowOnePairingAttemptAtATime() {
        let secrets = ScannerSecrets()
        let now = Date(timeIntervalSince1970: 1_000)
        let peer = UUID()
        XCTAssertEqual(secrets.lookup(mode: .pair, peerID: peer, now: now), .refused(.notPairing))
        secrets.setWindow(PairingWindow(now: now, code: "123456"))
        XCTAssertEqual(secrets.lookup(mode: .pair, peerID: peer, now: now),
                       .secret(RemoteHandshake.pairingSecret(code: "123456")))
        // A second, parallel attempt waits for the first one.
        XCTAssertEqual(secrets.lookup(mode: .pair, peerID: UUID(), now: now), .refused(.busy))
        // Abandoned without a confirm: not a wrong code, the next attempt may start at once.
        secrets.endPairAttempt(wrongCode: false, now: now)
        XCTAssertEqual(secrets.currentWindow?.wrongCodes, 0)
        XCTAssertNotNil(lookupSecret(secrets, now: now))
        // A wrong code is counted and pauses attempts for 2 s.
        secrets.endPairAttempt(wrongCode: true, now: now)
        XCTAssertEqual(secrets.currentWindow?.wrongCodes, 1)
        XCTAssertEqual(secrets.lookup(mode: .pair, peerID: peer, now: now.addingTimeInterval(1)), .refused(.busy))
        XCTAssertNotNil(lookupSecret(secrets, now: now.addingTimeInterval(2)))
        secrets.endPairAttempt(wrongCode: false, now: now)
        // Closed window.
        XCTAssertEqual(secrets.lookup(mode: .pair, peerID: peer, now: now.addingTimeInterval(301)), .refused(.notPairing))
    }

    func testScannerSecretsResumeNeedsThePairedRemote() {
        let secrets = ScannerSecrets()
        let peer = UUID()
        let now = Date()
        XCTAssertEqual(secrets.lookup(mode: .resume, peerID: peer, now: now), .refused(.notPaired))
        let key = Data(repeating: 9, count: 32)
        secrets.setPairing(RemotePairing(peerID: peer, peerName: "iPhone 1A2B", key: key, created: now))
        XCTAssertEqual(secrets.lookup(mode: .resume, peerID: peer, now: now), .secret(key))
        XCTAssertEqual(secrets.lookup(mode: .resume, peerID: UUID(), now: now), .refused(.notPaired))
        // Resuming never takes the pairing attempt.
        secrets.setWindow(PairingWindow(now: now, code: "000000"))
        XCTAssertNotNil(lookupSecret(secrets, now: now))
    }

    private func lookupSecret(_ secrets: ScannerSecrets, now: Date) -> Data? {
        if case .secret(let data) = secrets.lookup(mode: .pair, peerID: UUID(), now: now) { return data }
        return nil
    }
}
