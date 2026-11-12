import Network
import XCTest

/// `RemoteConnection` end to end over localhost TCP: pairing, resume, refusals, encrypted messages, and a file copy
/// with resume and change detection. The scanner side is accepted by a plain `NWListener` (no Bonjour).
final class RemoteConnectionLoopbackTests: XCTestCase {
    /// What the callbacks saw. Callbacks run on the main thread, where the tests read it.
    private final class Events: @unchecked Sendable {
        var opened: [RemoteConnection.Opened] = []
        var messages: [RemoteMessage] = []
        var closes: [RemoteCloseReason] = []
        var wrongCodes = 0
        var filesDone: [UInt32] = []
        var filesFailed: [String] = []
    }

    private final class Harness: @unchecked Sendable {
        // `scanners` is changed on `queue` only; everything else on the main thread.
        let queue = DispatchQueue(label: "test.remote.link")
        let secrets = ScannerSecrets()
        let scannerIdentity = RemoteIdentity(id: UUID(), name: "Scanner TEST")
        let remoteIdentity = RemoteIdentity(id: UUID(), name: "Remote TEST")
        let scannerEvents = Events()
        let remoteEvents = Events()
        var listener: NWListener?
        var scanners: [RemoteConnection] = []
        var remotes: [RemoteConnection] = []
        /// When set, the scanner answers file requests with this file.
        var serveFile: URL?

        var firstScanner: RemoteConnection? { queue.sync { scanners.first } }

        func stop() {
            listener?.cancel()
            remotes.forEach { $0.cancel() }
            queue.sync { scanners.forEach { $0.cancel() } }
        }
    }

    private func waitUntil(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    private func startScanner(_ harness: Harness) throws -> NWEndpoint.Port {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { accepted in
            let connection = RemoteConnection(accepted: accepted, side: .scanner(harness.secrets),
                                              identity: harness.scannerIdentity, queue: harness.queue)
            let events = harness.scannerEvents
            connection.onOpen = { opened in events.opened.append(opened) }
            connection.onMessage = { [weak connection] message in
                events.messages.append(message)
                if case .fileRequest(let request) = message, let url = harness.serveFile {
                    connection?.startSending(request, url: url)
                }
            }
            connection.onClose = { reason, _ in events.closes.append(reason) }
            connection.onWrongCode = { events.wrongCodes += 1 }
            harness.scanners.append(connection)
            connection.start()
        }
        harness.listener = listener
        listener.start(queue: harness.queue)
        wait(for: [ready], timeout: 5)
        return try XCTUnwrap(listener.port)
    }

    @discardableResult
    private func connectRemote(_ harness: Harness, port: NWEndpoint.Port, mode: HandshakeMessage.Mode, secret: Data,
                               expectedScanner: UUID? = nil) -> RemoteConnection {
        let side = RemoteConnection.Side.remote(mode: mode, secret: secret,
                                                expectedScanner: expectedScanner ?? harness.scannerIdentity.id)
        let connection = RemoteConnection(endpoint: .hostPort(host: "127.0.0.1", port: port), side: side,
                                          identity: harness.remoteIdentity, queue: harness.queue)
        let events = harness.remoteEvents
        connection.onOpen = { opened in events.opened.append(opened) }
        connection.onMessage = { message in events.messages.append(message) }
        connection.onClose = { reason, _ in events.closes.append(reason) }
        connection.onFileDone = { transferID in events.filesDone.append(transferID) }
        connection.onFileFailed = { _, message in events.filesFailed.append(message) }
        harness.remotes.append(connection)
        connection.start()
        return connection
    }

    private func pair(_ harness: Harness, port: NWEndpoint.Port) throws -> (remote: RemoteConnection, key: Data) {
        harness.secrets.setWindow(PairingWindow(now: Date(), code: "123456"))
        let remote = connectRemote(harness, port: port, mode: .pair, secret: RemoteHandshake.pairingSecret(code: "123456"))
        waitUntil { harness.remoteEvents.opened.count == 1 && harness.scannerEvents.opened.count == 1 }
        return (remote, try XCTUnwrap(harness.remoteEvents.opened.first?.newPairingKey))
    }

    func testPairingThenResumeWithEncryptedMessages() throws {
        let harness = Harness()
        defer { harness.stop() }
        let port = try startScanner(harness)
        let (remote, key) = try pair(harness, port: port)
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(harness.scannerEvents.opened.first?.newPairingKey, key)
        XCTAssertEqual(harness.scannerEvents.opened.first?.peerID, harness.remoteIdentity.id)
        XCTAssertEqual(harness.scannerEvents.opened.first?.peerName, "Remote TEST")
        XCTAssertEqual(harness.remoteEvents.opened.first?.peerID, harness.scannerIdentity.id)
        XCTAssertEqual(harness.remoteEvents.opened.first?.peerName, "Scanner TEST")

        remote.send(.listScans)
        waitUntil { harness.scannerEvents.messages.contains(.listScans) }
        let scanner = try XCTUnwrap(harness.firstScanner)
        scanner.send(.commandResult(id: 7, accepted: false, message: "too hot"))
        waitUntil { harness.remoteEvents.messages.contains(.commandResult(id: 7, accepted: false, message: "too hot")) }

        remote.cancel()
        waitUntil { harness.scannerEvents.closes.count == 1 }

        harness.secrets.setPairing(RemotePairing(peerID: harness.remoteIdentity.id, peerName: "Remote TEST",
                                                 key: key, created: Date()))
        let resumed = connectRemote(harness, port: port, mode: .resume, secret: key)
        waitUntil { harness.remoteEvents.opened.count == 2 && harness.scannerEvents.opened.count == 2 }
        XCTAssertNil(harness.remoteEvents.opened.last?.newPairingKey)
        XCTAssertNil(harness.scannerEvents.opened.last?.newPairingKey)
        resumed.send(.listScans)
        waitUntil { harness.scannerEvents.messages.filter { $0 == .listScans }.count == 2 }
    }

    func testRefusals() throws {
        let harness = Harness()
        defer { harness.stop() }
        let port = try startScanner(harness)

        connectRemote(harness, port: port, mode: .pair, secret: RemoteHandshake.pairingSecret(code: "000000"))
        waitUntil { harness.remoteEvents.closes.contains(.refused(.notPairing)) }

        harness.secrets.setWindow(PairingWindow(now: Date(), code: "123456"))
        connectRemote(harness, port: port, mode: .pair, secret: RemoteHandshake.pairingSecret(code: "654321"))
        waitUntil { harness.remoteEvents.closes.contains(.refused(.wrongCode)) }
        waitUntil { harness.scannerEvents.wrongCodes == 1 }
        XCTAssertEqual(harness.secrets.currentWindow?.wrongCodes, 1)

        // Within 2 s of a wrong code the scanner answers busy, even with the right code.
        connectRemote(harness, port: port, mode: .pair, secret: RemoteHandshake.pairingSecret(code: "123456"))
        waitUntil { harness.remoteEvents.closes.contains(.refused(.busy)) }

        connectRemote(harness, port: port, mode: .resume, secret: Data(repeating: 1, count: 32))
        waitUntil { harness.remoteEvents.closes.contains(.refused(.notPaired)) }

        Thread.sleep(forTimeInterval: 2.1)
        connectRemote(harness, port: port, mode: .pair, secret: RemoteHandshake.pairingSecret(code: "123456"),
                      expectedScanner: UUID())
        waitUntil { harness.remoteEvents.closes.contains(.wrongScanner) }

        XCTAssertTrue(harness.remoteEvents.opened.isEmpty)
        XCTAssertTrue(harness.scannerEvents.opened.isEmpty)
    }

    func testFileCopyResumeAndChangeDetection() throws {
        let harness = Harness()
        defer { harness.stop() }
        let port = try startScanner(harness)
        let (remote, _) = try pair(harness, port: port)

        let folder = try makeTempFolder()
        let source = folder.appendingPathComponent("Depth.bin")
        let bytes = Data((0..<700_001).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try bytes.write(to: source)
        let info = try XCTUnwrap(RemoteFiles.info(of: source))
        harness.serveFile = source
        let scanID = UUID()
        func request(_ transferID: UInt32, offset: Int64, size: Int64? = nil) -> RemoteFileRequest {
            RemoteFileRequest(transferID: transferID, scanID: scanID, name: info.name, offset: offset,
                              size: size ?? info.size, modified: info.modified)
        }

        let destination = folder.appendingPathComponent("copy.bin")
        remote.requestFile(request(1, offset: 0), into: destination)
        waitUntil { harness.remoteEvents.filesDone.contains(1) }
        XCTAssertEqual(try Data(contentsOf: destination), bytes)

        // A torn partial copy: resume from a chunk boundary one chunk back; the tail is overwritten.
        var partial = bytes.prefix(600_000)
        partial.append(Data(repeating: 0xFF, count: 10))
        try Data(partial).write(to: destination)
        let offset = RemoteFiles.resumeOffset(stagedSize: Int64(partial.count), expectedSize: info.size)
        XCTAssertEqual(offset, 262_144)
        remote.requestFile(request(2, offset: offset), into: destination)
        waitUntil { harness.remoteEvents.filesDone.contains(2) }
        XCTAssertEqual(try Data(contentsOf: destination), bytes)

        // The opened file no longer matches the request: refused as changed.
        remote.requestFile(request(3, offset: 0, size: info.size + 1), into: folder.appendingPathComponent("other.bin"))
        waitUntil {
            harness.remoteEvents.messages.contains { message in
                if case .fileError(3, .changed, _) = message { return true }
                return false
            }
        }
        XCTAssertTrue(harness.remoteEvents.filesFailed.isEmpty)
        XCTAssertTrue(harness.remoteEvents.closes.isEmpty)
    }
}
