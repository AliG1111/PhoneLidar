import Foundation
import Network
import CryptoKit

// Network side of the remote link (design §3.9, §6.15). Every type here is confined to the link queue
// (`phonelidar.remote.link`) and reports to the main actor with DispatchQueue.main.async, which keeps order.

/// This phone on the link.
struct RemoteIdentity: Sendable, Equatable {
    let id: UUID
    /// Shown to the other phone and advertised as the Bonjour name.
    let name: String
}

/// Why a link connection closed.
enum RemoteCloseReason: Sendable, Equatable {
    case closedByUs
    case peerClosed
    /// No data on an open link for `linkTimeout`.
    case timeout
    /// The other phone did not answer a handshake step in time.
    case noAnswer
    /// The handshake did not finish within `handshakeTimeout`.
    case setupTimeout
    case refused(HandshakeMessage.Refusal)
    case wrongScanner
    case permissionDenied
    case failed(String)

    static let permissionText = "Local Network access is off for Phone LiDAR. Turn it on in Settings › Privacy & Security › Local Network."

    /// The reason without a final period, to be placed inside a sentence ("Link lost (…).").
    var text: String {
        var value = rawText
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    private var rawText: String {
        switch self {
        case .closedByUs: return "disconnected"
        case .peerClosed: return "the other phone closed the link"
        case .timeout: return String(format: "no data from the other phone for %.0f s", RemoteLinkConstants.linkTimeout)
        case .noAnswer: return String(format: "the other phone did not answer within %.0f s", RemoteLinkConstants.helloTimeout)
        case .setupTimeout: return String(format: "the connection was not set up within %.0f s", RemoteLinkConstants.handshakeTimeout)
        case .wrongScanner: return "a different phone answered"
        case .permissionDenied: return Self.permissionText
        case .failed(let text): return text
        case .refused(let refusal):
            switch refusal {
            case .version: return "update both phones to the same app build"
            case .notPaired: return "this phone is not paired with the scanner any more. Pair again"
            case .notPairing: return "the scanner is not pairing: tap Pair a remote on the scanner first"
            case .wrongCode: return "wrong code"
            case .authentication: return "the other phone could not be verified"
            case .busy:
                return "the scanner is busy (another pairing attempt, or the 2 s pause after a wrong code): try again in a few seconds"
            }
        }
    }
}

/// One link connection: handshake, encrypted records, liveness, and the file sender (scanner) or receiver (remote).
final class RemoteConnection: @unchecked Sendable {
    // Confined to `queue`: every NWConnection handler runs there and every public method hops there. The callbacks
    // are set on the main actor before `start()` and only read on the queue afterwards.

    enum Side: Sendable {
        case scanner(ScannerSecrets)
        case remote(mode: HandshakeMessage.Mode, secret: Data, expectedScanner: UUID)
    }

    struct Opened: Sendable {
        let peerID: UUID
        let peerName: String
        /// The pairing key after a pairing; nil when resuming.
        let newPairingKey: Data?
    }

    private enum State {
        case starting
        case awaitingClientHello
        case awaitingServerHello(sent: Data, key: Curve25519.KeyAgreement.PrivateKey)
        case awaitingClientConfirm(keys: RemoteSessionKeys, transcript: Data, mode: HandshakeMessage.Mode,
                                   peerID: UUID, peerName: String)
        case awaitingServerConfirm(keys: RemoteSessionKeys, transcript: Data, peerID: UUID, peerName: String)
        case refusing
        case open
        case closed
    }

    private final class FileSender {
        let transferID: UInt32
        let handle: FileHandle
        let size: Int64
        var next: Int64
        var acknowledged: Int64

        init(transferID: UInt32, handle: FileHandle, size: Int64, offset: Int64) {
            self.transferID = transferID
            self.handle = handle
            self.size = size
            self.next = offset
            self.acknowledged = offset
        }
    }

    private final class FileReceiver {
        let transferID: UInt32
        let handle: FileHandle
        let size: Int64
        var received: Int64
        var lastReport: TimeInterval = 0

        init(transferID: UInt32, handle: FileHandle, size: Int64, offset: Int64) {
            self.transferID = transferID
            self.handle = handle
            self.size = size
            self.received = offset
        }
    }

    let id = UUID()
    private let queue: DispatchQueue
    private let helloLock = NSLock()
    private var helloSeen = false

    /// Scanner: true once a well-formed hello arrived (read on the main actor to pick a connection to drop).
    var hasHello: Bool { helloLock.withLock { helloSeen } }
    private let connection: NWConnection
    private let side: Side
    private let identity: RemoteIdentity

    var onOpen: (@MainActor @Sendable (Opened) -> Void)?
    var onMessage: (@MainActor @Sendable (RemoteMessage) -> Void)?
    /// Reason, and whether the handshake had finished.
    var onClose: (@MainActor @Sendable (RemoteCloseReason, Bool) -> Void)?
    var onWrongCode: (@MainActor @Sendable () -> Void)?
    /// Remote: bytes of the current file received so far (≤ 4 Hz, and at the end).
    var onFileProgress: (@MainActor @Sendable (UInt32, Int64) -> Void)?
    var onFileDone: (@MainActor @Sendable (UInt32) -> Void)?
    var onFileFailed: (@MainActor @Sendable (UInt32, String) -> Void)?

    private var state: State = .starting
    private var decoder = RemoteFrameDecoder(limit: RemoteLinkConstants.handshakeFrameLimit)
    private var channel: SecureChannel?
    private var timer: DispatchSourceTimer?
    private var startedAt: TimeInterval = 0
    private var lastReceive: TimeInterval = 0
    private var lastSend: TimeInterval = 0
    private var wasOpen = false
    private var sender: FileSender?
    private var receiver: FileReceiver?
    /// Scanner: this connection holds the one pairing attempt (`ScannerSecrets.lookup`) until its confirm or close.
    private var holdsPairAttempt = false
    /// Scanner: when the server hello was sent (the remote answers with its confirm straight away).
    private var serverHelloSentAt: TimeInterval = 0

    /// Remote side: connects to a scanner endpoint.
    init(endpoint: NWEndpoint, side: Side, identity: RemoteIdentity, queue: DispatchQueue) {
        self.connection = NWConnection(to: endpoint, using: Self.parameters())
        self.side = side
        self.identity = identity
        self.queue = queue
    }

    /// Scanner side: a connection accepted by the listener.
    init(accepted: NWConnection, side: Side, identity: RemoteIdentity, queue: DispatchQueue) {
        self.connection = accepted
        self.side = side
        self.identity = identity
        self.queue = queue
    }

    /// TCP with keep-alive over peer-to-peer Wi-Fi (also used by the listener).
    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    /// DNS error −65570 (`kDNSServiceErr_PolicyDenied`): Local Network permission is off.
    static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == -65570 }
        return false
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func cleanName(_ name: String?) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "iPhone" : String(trimmed.prefix(60))
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Short text for a network error (NWError's own description is a debug string).
    static func describe(network error: NWError) -> String {
        switch error {
        case .posix(let code):
            return "network error: " + String(cString: strerror(code.rawValue)).lowercased()
        case .dns(let code):
            return "network name error \(code)"
        case .tls(let status):
            return "secure connection error \(status)"
        default:
            return "network error"
        }
    }

    // MARK: - Public (any thread)

    func start() {
        queue.async { [self] in
            guard case .starting = state else { return }
            let time = Self.now
            startedAt = time
            lastReceive = time
            lastSend = time
            connection.stateUpdateHandler = { [weak self] newState in
                self?.connectionStateChanged(newState)
            }
            connection.start(queue: queue)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                self?.tick()
            }
            timer.resume()
            self.timer = timer
        }
    }

    func cancel() {
        queue.async { [self] in
            close(.closedByUs)
        }
    }

    func send(_ message: RemoteMessage) {
        queue.async { [self] in
            sendNow(message)
        }
    }

    /// Scanner: streams `url` from `request.offset` (the request was validated on the main actor).
    func startSending(_ request: RemoteFileRequest, url: URL) {
        queue.async { [self] in
            guard case .open = state else { return }
            closeSender()
            do {
                let handle = try FileHandle(forReadingFrom: url)
                // The file may have been replaced (Rebuild map renames new files over old ones) after the main actor
                // checked it by path: compare the opened file itself.
                guard Self.opened(handle, matches: request) else {
                    try? handle.close()
                    sendNow(.fileError(transferID: request.transferID, reason: .changed,
                                       message: "\(request.name) changed on the scanner."))
                    return
                }
                try handle.seek(toOffset: UInt64(request.offset))
                sender = FileSender(transferID: request.transferID, handle: handle, size: request.size,
                                    offset: request.offset)
            } catch {
                sendNow(.fileError(transferID: request.transferID, reason: .failed, message: Self.describe(error)))
                return
            }
            pumpSender()
        }
    }

    /// Size and modification time of an open file, from `fstat`, against the request.
    private static func opened(_ handle: FileHandle, matches request: RemoteFileRequest) -> Bool {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return false }
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        return Int64(info.st_size) == request.size && abs(modified - request.modified) < 0.001
    }

    /// Scanner: stops a running send and tells the remote why.
    func stopSending(reason: RemoteFileProblem, message: String) {
        queue.async { [self] in
            failSend(reason, message)
        }
    }

    /// Remote: prepares `url` (truncated to `request.offset`, created if missing), then asks for the file.
    func requestFile(_ request: RemoteFileRequest, into url: URL) {
        queue.async { [self] in
            guard case .open = state else { return }
            closeReceiver()
            do {
                let manager = FileManager.default
                if !manager.fileExists(atPath: url.path), !manager.createFile(atPath: url.path, contents: nil) {
                    throw CocoaError(.fileWriteUnknown)
                }
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: UInt64(request.offset))
                try handle.seek(toOffset: UInt64(request.offset))
                receiver = FileReceiver(transferID: request.transferID, handle: handle, size: request.size,
                                        offset: request.offset)
            } catch {
                report(fileFailed: request.transferID, "the file could not be prepared (\(Self.describe(error)))")
                return
            }
            sendNow(.fileRequest(request))
        }
    }

    /// Remote: stops receiving a file (what arrived is kept) and tells the scanner.
    func cancelFile(transferID: UInt32) {
        queue.async { [self] in
            guard receiver?.transferID == transferID else { return }
            closeReceiver()
            sendNow(.cancelTransfer(transferID: transferID))
        }
    }

    // MARK: - Connection

    private var isClosedOrRefusing: Bool {
        switch state {
        case .closed, .refusing: return true
        default: return false
        }
    }

    private var isOpen: Bool {
        if case .open = state { return true }
        return false
    }

    private func connectionStateChanged(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            guard case .starting = state else { return }
            switch side {
            case .scanner:
                state = .awaitingClientHello
            case .remote(let mode, _, _):
                sendClientHello(mode: mode)
            }
            receiveNext()
        case .waiting(let error):
            // NWConnection retries by itself; the handshake time limit ends a wait that does not recover.
            if Self.isPolicyDenied(error) { close(.permissionDenied) }
        case .failed(let error):
            close(Self.isPolicyDenied(error) ? .permissionDenied : .failed(Self.describe(network: error)))
        case .cancelled:
            close(.peerClosed)
        default:
            break
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosedOrRefusing else { return }
            if let data, !data.isEmpty {
                self.lastReceive = Self.now
                self.decoder.push(data)
                self.drainFrames()
            }
            guard !self.isClosedOrRefusing else { return }
            if let error {
                self.close(.failed(Self.describe(network: error)))
            } else if isComplete {
                self.close(.peerClosed)
            } else {
                self.receiveNext()
            }
        }
    }

    private func drainFrames() {
        do {
            while !isClosedOrRefusing, let frame = try decoder.next() {
                try handle(frame: frame)
            }
        } catch {
            close(.failed(Self.describe(error)))
        }
    }

    private func handle(frame: Data) throws {
        switch state {
        case .open:
            guard let record = try channel?.open(frame) else { throw RemoteLinkError.authenticationFailed }
            try handle(record: record)
        case .awaitingClientHello:
            try handleClientHello(frame)
        case .awaitingServerHello(let sent, let key):
            try handleServerHello(frame, sent: sent, key: key)
        case .awaitingClientConfirm(let keys, let transcript, let mode, let peerID, let peerName):
            try handleClientConfirm(frame, keys: keys, transcript: transcript, mode: mode, peerID: peerID, peerName: peerName)
        case .awaitingServerConfirm(let keys, let transcript, let peerID, let peerName):
            try handleServerConfirm(frame, keys: keys, transcript: transcript, peerID: peerID, peerName: peerName)
        case .starting, .refusing, .closed:
            break
        }
    }

    // MARK: - Handshake

    private func sendClientHello(mode: HandshakeMessage.Mode) {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let hello = HandshakeMessage(type: .clientHello, version: RemoteLinkConstants.protocolVersion, mode: mode,
                                     deviceID: identity.id, deviceName: identity.name,
                                     publicKey: key.publicKey.rawRepresentation, nonce: RemoteHandshake.randomNonce())
        do {
            let data = try hello.encoded()
            state = .awaitingServerHello(sent: data, key: key)
            sendFrame(data)
        } catch {
            close(.failed(Self.describe(error)))
        }
    }

    /// Scanner, step 2.
    private func handleClientHello(_ frame: Data) throws {
        guard case .scanner(let secrets) = side else { throw RemoteLinkError.badHandshake }
        let hello = try HandshakeMessage.decode(frame)
        guard hello.type == .clientHello, hello.isWellFormedHello, let mode = hello.mode,
              let peerID = hello.deviceID, let peerKey = hello.publicKey else { throw RemoteLinkError.badHandshake }
        helloLock.withLock { helloSeen = true }
        guard hello.version == RemoteLinkConstants.protocolVersion else {
            refuse(.version)
            return
        }
        let secret: Data
        switch secrets.lookup(mode: mode, peerID: peerID, now: Date()) {
        case .refused(let refusal):
            refuse(refusal)
            return
        case .secret(let value):
            secret = value
            holdsPairAttempt = mode == .pair
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        let reply = try HandshakeMessage(type: .serverHello, version: RemoteLinkConstants.protocolVersion,
                                         deviceID: identity.id, deviceName: identity.name,
                                         publicKey: key.publicKey.rawRepresentation,
                                         nonce: RemoteHandshake.randomNonce()).encoded()
        let transcript = RemoteHandshake.transcript(clientHello: frame, serverHello: reply)
        let keys = try RemoteHandshake.keys(privateKey: key, peerPublicKey: peerKey, secret: secret, transcript: transcript)
        state = .awaitingClientConfirm(keys: keys, transcript: transcript, mode: mode, peerID: peerID,
                                       peerName: Self.cleanName(hello.deviceName))
        serverHelloSentAt = Self.now
        sendFrame(reply)
    }

    /// Scanner, steps 4–5.
    private func handleClientConfirm(_ frame: Data, keys: RemoteSessionKeys, transcript: Data,
                                     mode: HandshakeMessage.Mode, peerID: UUID, peerName: String) throws {
        guard case .scanner(let secrets) = side else { throw RemoteLinkError.badHandshake }
        let message = try HandshakeMessage.decode(frame)
        let valid = message.type == .confirm && message.mac.map {
            RemoteHandshake.isValid($0, key: keys.remoteConfirm, transcript: transcript)
        } == true
        if mode == .pair {
            secrets.endPairAttempt(wrongCode: !valid, now: Date())
            holdsPairAttempt = false
        }
        guard valid else {
            if mode == .pair {
                if let callback = onWrongCode { deliver { callback() } }
                refuse(.wrongCode)
            } else {
                refuse(.authentication)
            }
            return
        }
        let reply = try HandshakeMessage(type: .confirm,
                                         mac: RemoteHandshake.confirmation(key: keys.scannerConfirm,
                                                                           transcript: transcript)).encoded()
        sendFrame(reply)
        let newKey = mode == .pair ? RemoteHandshake.keyData(keys.pairingKey) : nil
        open(channel: SecureChannel(sendKey: keys.scannerToRemote, receiveKey: keys.remoteToScanner),
             opened: Opened(peerID: peerID, peerName: peerName, newPairingKey: newKey))
    }

    /// Remote, step 3.
    private func handleServerHello(_ frame: Data, sent: Data, key: Curve25519.KeyAgreement.PrivateKey) throws {
        guard case .remote(_, let secret, let expected) = side else { throw RemoteLinkError.badHandshake }
        let message = try HandshakeMessage.decode(frame)
        if message.type == .refused {
            close(.refused(message.refusal ?? .authentication))
            return
        }
        guard message.type == .serverHello, message.isWellFormedHello, let scannerID = message.deviceID,
              let scannerKey = message.publicKey else { throw RemoteLinkError.badHandshake }
        guard message.version == RemoteLinkConstants.protocolVersion else {
            close(.refused(.version))
            return
        }
        guard scannerID == expected else {
            close(.wrongScanner)
            return
        }
        let transcript = RemoteHandshake.transcript(clientHello: sent, serverHello: frame)
        let keys = try RemoteHandshake.keys(privateKey: key, peerPublicKey: scannerKey, secret: secret,
                                            transcript: transcript)
        let confirm = try HandshakeMessage(type: .confirm,
                                           mac: RemoteHandshake.confirmation(key: keys.remoteConfirm,
                                                                             transcript: transcript)).encoded()
        state = .awaitingServerConfirm(keys: keys, transcript: transcript, peerID: scannerID,
                                       peerName: Self.cleanName(message.deviceName))
        sendFrame(confirm)
    }

    /// Remote, step 5.
    private func handleServerConfirm(_ frame: Data, keys: RemoteSessionKeys, transcript: Data,
                                     peerID: UUID, peerName: String) throws {
        guard case .remote(let mode, _, _) = side else { throw RemoteLinkError.badHandshake }
        let message = try HandshakeMessage.decode(frame)
        if message.type == .refused {
            close(.refused(message.refusal ?? .authentication))
            return
        }
        guard message.type == .confirm, let mac = message.mac,
              RemoteHandshake.isValid(mac, key: keys.scannerConfirm, transcript: transcript) else {
            close(.refused(.authentication))
            return
        }
        let newKey = mode == .pair ? RemoteHandshake.keyData(keys.pairingKey) : nil
        open(channel: SecureChannel(sendKey: keys.remoteToScanner, receiveKey: keys.scannerToRemote),
             opened: Opened(peerID: peerID, peerName: peerName, newPairingKey: newKey))
    }

    private func open(channel: SecureChannel, opened: Opened) {
        self.channel = channel
        state = .open
        wasOpen = true
        decoder.limit = RemoteLinkConstants.frameLimit
        lastReceive = Self.now
        if let callback = onOpen { deliver { callback(opened) } }
    }

    /// Sends a refusal, then closes once it has been handed to the network.
    private func refuse(_ refusal: HandshakeMessage.Refusal) {
        state = .refusing
        guard let data = try? HandshakeMessage(type: .refused, refusal: refusal).encoded() else {
            close(.refused(refusal))
            return
        }
        connection.send(content: RemoteFrame.encode(data), completion: .contentProcessed { [weak self] _ in
            self?.close(.refused(refusal))
        })
    }

    // MARK: - Records

    private func handle(record: Data) throws {
        switch try RemoteRecord.decode(record) {
        case .chunk(let transferID, let offset, let data):
            receiveChunk(transferID: transferID, offset: offset, data: data)
        case .message(let message):
            switch message {
            case .ping:
                break
            case .chunkAck(let transferID, let received):
                acknowledge(transferID: transferID, received: received)
            case .cancelTransfer(let transferID):
                if sender?.transferID == transferID { closeSender() }
            case .fileEnd(let transferID, let size):
                finishReceive(transferID: transferID, size: size)
            case .fileError(let transferID, _, _):
                if receiver?.transferID == transferID { closeReceiver() }
                forward(message)
            default:
                forward(message)
            }
        case .unknown:
            break
        }
    }

    private func forward(_ message: RemoteMessage) {
        if let callback = onMessage { deliver { callback(message) } }
    }

    private func sendNow(_ message: RemoteMessage) {
        guard isOpen else { return }
        // Encoding only fails for non-finite numbers; statuses are sanitized before they are sent.
        guard let record = try? RemoteRecord.message(message) else { return }
        sendRecord(record)
    }

    private func sendRecord(_ record: Data) {
        guard isOpen else { return }
        do {
            guard let sealed = try channel?.seal(record) else { return }
            sendFrame(sealed)
        } catch {
            close(.failed("Encryption failed: \(Self.describe(error))"))
        }
    }

    private func sendFrame(_ payload: Data) {
        lastSend = Self.now
        connection.send(content: RemoteFrame.encode(payload), completion: .contentProcessed { [weak self] error in
            if let error { self?.close(.failed(Self.describe(network: error))) }
        })
    }

    // MARK: - File sender (scanner)

    private func pumpSender() {
        guard isOpen, let sender else { return }
        while sender.next < sender.size, sender.next - sender.acknowledged < RemoteLinkConstants.ackWindow {
            let count = Int(min(Int64(RemoteLinkConstants.chunkSize), sender.size - sender.next))
            let data: Data
            do {
                data = try sender.handle.read(upToCount: count) ?? Data()
            } catch {
                failSend(.failed, "the file could not be read (\(Self.describe(error)))")
                return
            }
            guard data.count == count else {
                failSend(.changed, "the file got shorter while it was being copied")
                return
            }
            sendRecord(RemoteRecord.chunk(transferID: sender.transferID, offset: sender.next, data: data))
            sender.next += Int64(count)
            guard isOpen else { return }
        }
        if sender.next >= sender.size {
            let transferID = sender.transferID
            let size = sender.size
            closeSender()
            sendNow(.fileEnd(transferID: transferID, size: size))
        }
    }

    private func acknowledge(transferID: UInt32, received: Int64) {
        guard let sender, sender.transferID == transferID else { return }
        sender.acknowledged = max(sender.acknowledged, min(received, sender.next))
        pumpSender()
    }

    private func failSend(_ reason: RemoteFileProblem, _ message: String) {
        guard let sender else { return }
        let transferID = sender.transferID
        closeSender()
        sendNow(.fileError(transferID: transferID, reason: reason, message: message))
    }

    private func closeSender() {
        if let sender {
            // A read handle: closing cannot lose data.
            try? sender.handle.close()
        }
        sender = nil
    }

    // MARK: - File receiver (remote)

    private func receiveChunk(transferID: UInt32, offset: Int64, data: Data) {
        // A chunk of a cancelled or finished transfer is ignored.
        guard let receiver, receiver.transferID == transferID else { return }
        guard offset == receiver.received, offset + Int64(data.count) <= receiver.size else {
            failReceive("the scanner sent a part of the file out of order")
            return
        }
        do {
            try receiver.handle.write(contentsOf: data)
        } catch {
            failReceive("the file could not be written (\(Self.describe(error)))")
            return
        }
        receiver.received += Int64(data.count)
        sendNow(.chunkAck(transferID: transferID, received: receiver.received))
        let time = Self.now
        if time - receiver.lastReport >= 0.25 {
            receiver.lastReport = time
            report(progress: transferID, receiver.received)
        }
    }

    private func finishReceive(transferID: UInt32, size: Int64) {
        guard let receiver, receiver.transferID == transferID else { return }
        guard receiver.received == size, size == receiver.size else {
            failReceive("the file arrived incomplete (\(receiver.received) of \(receiver.size) bytes)")
            return
        }
        do {
            try receiver.handle.synchronize()
            try receiver.handle.close()
        } catch {
            failReceive("the file could not be saved (\(Self.describe(error)))")
            return
        }
        self.receiver = nil
        report(progress: transferID, size)
        if let callback = onFileDone { deliver { callback(transferID) } }
    }

    private func failReceive(_ message: String) {
        guard let receiver else { return }
        let transferID = receiver.transferID
        closeReceiver()
        sendNow(.cancelTransfer(transferID: transferID))
        report(fileFailed: transferID, message)
    }

    private func closeReceiver() {
        if let receiver {
            // Every write went through `write(contentsOf:)`, which throws on failure; closing only releases the handle.
            try? receiver.handle.close()
        }
        receiver = nil
    }

    private func report(progress transferID: UInt32, _ bytes: Int64) {
        if let callback = onFileProgress { deliver { callback(transferID, bytes) } }
    }

    private func report(fileFailed transferID: UInt32, _ message: String) {
        if let callback = onFileFailed { deliver { callback(transferID, message) } }
    }

    // MARK: - Liveness and closing

    private func tick() {
        let time = Self.now
        switch state {
        case .open:
            if time - lastReceive > RemoteLinkConstants.linkTimeout {
                close(.timeout)
            } else if time - lastSend >= RemoteLinkConstants.pingInterval {
                sendNow(.ping)
            }
        case .closed:
            break
        case .awaitingClientHello:
            // An accepted connection that stays silent would hold a handshake slot.
            if time - startedAt > RemoteLinkConstants.helloTimeout { close(.noAnswer) }
        case .awaitingClientConfirm:
            // The remote sends its confirm right after the server hello; a silent one would hold the pairing attempt.
            if time - serverHelloSentAt > RemoteLinkConstants.helloTimeout { close(.noAnswer) }
        default:
            if time - startedAt > RemoteLinkConstants.handshakeTimeout { close(.setupTimeout) }
        }
    }

    private func close(_ reason: RemoteCloseReason) {
        if case .closed = state { return }
        state = .closed
        timer?.cancel()
        timer = nil
        if holdsPairAttempt, case .scanner(let secrets) = side {
            // Abandoned before its confirm: no code was tested, so it is not counted as wrong.
            secrets.endPairAttempt(wrongCode: false, now: Date())
            holdsPairAttempt = false
        }
        closeSender()
        closeReceiver()
        connection.stateUpdateHandler = nil
        connection.cancel()
        if let callback = onClose {
            let finishedHandshake = wasOpen
            deliver { callback(reason, finishedHandshake) }
        }
    }

    /// Runs `work` on the main actor, in the order of the calls.
    private func deliver(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { work() }
        }
    }
}
