import Foundation
import CryptoKit

// Pairing, handshake key schedule and the encrypted channel of the remote link (design §6.15). CryptoKit only;
// compiled by the test target.

/// The 6-digit code the scanner shows for pairing.
enum PairingCode {
    static let length = 6

    /// Uniformly random 6 digits from the system's cryptographic random generator.
    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(format: "%06d", Int.random(in: 0..<1_000_000, using: &generator))
    }

    /// The code typed by the user without spaces or other characters; nil unless exactly 6 ASCII digits remain.
    static func normalized(_ text: String) -> String? {
        let digits = text.filter { ("0"..."9").contains($0) }
        return digits.count == length ? String(digits) : nil
    }

    /// "123 456".
    static func display(_ code: String) -> String {
        guard code.count == length else { return code }
        return String(code.prefix(3)) + " " + String(code.suffix(3))
    }
}

/// The time during which the scanner accepts a pairing, and its code. Guessing is limited three ways: the window
/// closes 5 minutes after it opened (wrong codes never extend it), an attempt is refused for 2 s after a wrong
/// code, and every 5 wrong codes the code changes.
struct PairingWindow: Equatable, Sendable {
    static let duration: TimeInterval = 300
    static let maxWrongCodes = 5
    static let wrongCodeDelay: TimeInterval = 2

    var code: String
    var expires: Date
    /// Wrong codes since the current code was made.
    var wrongCodes = 0
    var lastWrongCode: Date?

    init(now: Date, code: String = PairingCode.generate()) {
        self.code = code
        self.expires = now.addingTimeInterval(Self.duration)
    }

    func isOpen(at now: Date) -> Bool {
        now < expires
    }

    /// Open, and not within `wrongCodeDelay` of the last wrong code.
    func acceptsAttempt(at now: Date) -> Bool {
        guard isOpen(at: now) else { return false }
        guard let lastWrongCode else { return true }
        return now.timeIntervalSince(lastWrongCode) >= Self.wrongCodeDelay
    }

    /// Seconds left (0 once closed).
    func remaining(at now: Date) -> TimeInterval {
        max(0, expires.timeIntervalSince(now))
    }

    /// Counts a wrong code. After `maxWrongCodes` the code changes; the closing time stays.
    mutating func registerWrongCode(now: Date, newCode: () -> String = PairingCode.generate) {
        wrongCodes += 1
        lastWrongCode = now
        if wrongCodes >= Self.maxWrongCodes {
            code = newCode()
            wrongCodes = 0
        }
    }
}

/// The phone this phone is paired with, and the shared key (design §7.20, stored by `RemoteKeychain`).
struct RemotePairing: Codable, Equatable, Sendable {
    var peerID: UUID
    var peerName: String
    /// 32-byte pairing key.
    var key: Data
    var created: Date
}

/// The scanner's pairing state read during handshakes. Locked: read on the link queue, changed on the main actor.
/// Only one pairing handshake runs at a time, so parallel connections cannot test several codes per 2 s.
final class ScannerSecrets: @unchecked Sendable {
    enum Lookup: Equatable, Sendable {
        case secret(Data)
        case refused(HandshakeMessage.Refusal)
    }

    private let lock = NSLock()
    private var window: PairingWindow?
    private var pairing: RemotePairing?
    private var pairAttemptActive = false

    var currentWindow: PairingWindow? { lock.withLock { window } }
    var currentPairing: RemotePairing? { lock.withLock { pairing } }

    func setWindow(_ newWindow: PairingWindow?) {
        lock.withLock { window = newWindow }
    }

    func setPairing(_ newPairing: RemotePairing?) {
        lock.withLock { pairing = newPairing }
    }

    /// The secret for a handshake. `pair`: the code of an open window that is not pausing after a wrong code and
    /// has no other pairing handshake running; a returned secret reserves the attempt until `endPairAttempt`.
    /// `resume`: the stored key of the paired remote.
    func lookup(mode: HandshakeMessage.Mode, peerID: UUID, now: Date) -> Lookup {
        lock.withLock {
            switch mode {
            case .pair:
                guard let window, window.isOpen(at: now) else { return .refused(.notPairing) }
                guard window.acceptsAttempt(at: now), !pairAttemptActive else { return .refused(.busy) }
                pairAttemptActive = true
                return .secret(RemoteHandshake.pairingSecret(code: window.code))
            case .resume:
                guard let pairing, pairing.peerID == peerID else { return .refused(.notPaired) }
                return .secret(pairing.key)
            }
        }
    }

    /// Ends the reserved pairing attempt; a wrong code is counted (new code after too many).
    func endPairAttempt(wrongCode: Bool, now: Date) {
        lock.withLock {
            pairAttemptActive = false
            if wrongCode { window?.registerWrongCode(now: now) }
        }
    }
}

/// Plain JSON message of the handshake. `Data` fields are base64 in JSON.
struct HandshakeMessage: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case clientHello
        case serverHello
        case confirm
        case refused
    }

    enum Mode: String, Codable, Sendable {
        /// First connection: authenticated by the pairing code.
        case pair
        /// Later connections: authenticated by the stored pairing key.
        case resume
    }

    enum Refusal: String, Codable, Sendable {
        case version
        case notPaired
        case notPairing
        case wrongCode
        case authentication
        case busy
    }

    var type: Kind
    var version: Int?
    var mode: Mode?
    var deviceID: UUID?
    var deviceName: String?
    /// X25519 public key, 32 bytes.
    var publicKey: Data?
    /// 32 random bytes.
    var nonce: Data?
    /// HMAC-SHA256 confirmation, 32 bytes.
    var mac: Data?
    var refusal: Refusal?

    init(type: Kind, version: Int? = nil, mode: Mode? = nil, deviceID: UUID? = nil, deviceName: String? = nil,
         publicKey: Data? = nil, nonce: Data? = nil, mac: Data? = nil, refusal: Refusal? = nil) {
        self.type = type
        self.version = version
        self.mode = mode
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.nonce = nonce
        self.mac = mac
        self.refusal = refusal
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) throws -> HandshakeMessage {
        do {
            return try JSONDecoder().decode(HandshakeMessage.self, from: data)
        } catch {
            throw RemoteLinkError.badHandshake
        }
    }

    /// True for a hello with a 32-byte key and nonce and a device ID.
    var isWellFormedHello: Bool {
        deviceID != nil && publicKey?.count == 32 && nonce?.count == 32
    }
}

/// Keys of one connection, all 256-bit.
struct RemoteSessionKeys {
    let remoteConfirm: SymmetricKey
    let scannerConfirm: SymmetricKey
    let remoteToScanner: SymmetricKey
    let scannerToRemote: SymmetricKey
    /// Stored by both phones after a pairing.
    let pairingKey: SymmetricKey
}

/// Key schedule and confirmations (design §6.15, steps 3–5).
enum RemoteHandshake {
    static let transcriptLabel = Data("PhoneLidar remote link v1".utf8)

    /// SHA-256 over the label and both hellos exactly as sent, each preceded by its 4-byte big-endian length.
    static func transcript(clientHello: Data, serverHello: Data) -> Data {
        var hash = SHA256()
        hash.update(data: transcriptLabel)
        var length = Data()
        length.appendBigEndian(UInt32(clientHello.count))
        hash.update(data: length)
        hash.update(data: clientHello)
        length = Data()
        length.appendBigEndian(UInt32(serverHello.count))
        hash.update(data: length)
        hash.update(data: serverHello)
        return Data(hash.finalize())
    }

    /// Secret mixed into the key schedule when pairing.
    static func pairingSecret(code: String) -> Data {
        Data("code:\(code)".utf8)
    }

    /// IKM = X25519 shared secret ‖ secret; each key = HKDF-SHA256(IKM, salt: transcript, info: its label).
    static func keys(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKey: Data, secret: Data,
                     transcript: Data) throws -> RemoteSessionKeys {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        var material = shared.withUnsafeBytes { Data($0) }
        material.append(secret)
        let inputKey = SymmetricKey(data: material)
        func derive(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: inputKey, salt: transcript, info: Data(label.utf8),
                                   outputByteCount: 32)
        }
        return RemoteSessionKeys(remoteConfirm: derive("remote confirm"),
                                 scannerConfirm: derive("scanner confirm"),
                                 remoteToScanner: derive("remote to scanner"),
                                 scannerToRemote: derive("scanner to remote"),
                                 pairingKey: derive("pairing key"))
    }

    static func confirmation(key: SymmetricKey, transcript: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: transcript, using: key))
    }

    /// Constant-time check of a confirmation.
    static func isValid(_ mac: Data, key: SymmetricKey, transcript: Data) -> Bool {
        mac.count == SHA256.byteCount && HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: transcript, using: key)
    }

    static func randomNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    static func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}

/// ChaChaPoly channel of one connection. Nonce = 4 zero bytes ‖ 64-bit big-endian counter, one counter per
/// direction from 0, so replayed, dropped, reordered or altered frames fail to open.
struct SecureChannel {
    static let tagSize = 16

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private(set) var sendCounter: UInt64 = 0
    private(set) var receiveCounter: UInt64 = 0

    init(sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
    }

    static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        bytes.appendBigEndian(counter)
        return try ChaChaPoly.Nonce(data: bytes)
    }

    /// Ciphertext ‖ tag.
    mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(sendCounter))
        sendCounter += 1
        return box.ciphertext + box.tag
    }

    /// Throws `authenticationFailed` for a payload that does not open with the next receive counter.
    mutating func open(_ payload: Data) throws -> Data {
        guard payload.count >= Self.tagSize else { throw RemoteLinkError.authenticationFailed }
        let bytes = Data(payload)
        let split = bytes.count - Self.tagSize
        do {
            let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(receiveCounter),
                                               ciphertext: bytes[..<split], tag: bytes[split...])
            let plaintext = try ChaChaPoly.open(box, using: receiveKey)
            receiveCounter += 1
            return plaintext
        } catch {
            throw RemoteLinkError.authenticationFailed
        }
    }
}
