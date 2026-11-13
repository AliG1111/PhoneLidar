import CryptoKit
import XCTest

final class RemoteCryptoTests: XCTestCase {
    // MARK: Pairing code and window

    func testPairingCodeGenerateNormalizeAndDisplay() {
        for _ in 0..<200 {
            let code = PairingCode.generate()
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(code.allSatisfy { ("0"..."9").contains($0) }, code)
        }
        XCTAssertEqual(PairingCode.normalized("123 456"), "123456")
        XCTAssertEqual(PairingCode.normalized(" 012-345 "), "012345")
        XCTAssertNil(PairingCode.normalized("12345"))
        XCTAssertNil(PairingCode.normalized("1234567"))
        XCTAssertNil(PairingCode.normalized("١٢٣٤٥٦"))          // only ASCII digits count
        XCTAssertEqual(PairingCode.display("012345"), "012 345")
        XCTAssertEqual(PairingCode.display("12"), "12")
    }

    func testPairingWindowExpiresAfterFiveMinutes() {
        let start = Date(timeIntervalSince1970: 1_000)
        let window = PairingWindow(now: start, code: "111111")
        XCTAssertTrue(window.isOpen(at: start.addingTimeInterval(299)))
        XCTAssertFalse(window.isOpen(at: start.addingTimeInterval(300)))
        XCTAssertEqual(window.remaining(at: start.addingTimeInterval(100)), 200, accuracy: 1e-9)
        XCTAssertEqual(window.remaining(at: start.addingTimeInterval(400)), 0)
    }

    func testPairingWindowWrongCodesDelayAndNewCode() {
        let start = Date(timeIntervalSince1970: 1_000)
        var window = PairingWindow(now: start, code: "111111")
        XCTAssertTrue(window.acceptsAttempt(at: start))
        for attempt in 1..<PairingWindow.maxWrongCodes {
            let time = start.addingTimeInterval(Double(attempt) * 3)
            window.registerWrongCode(now: time, newCode: { "222222" })
            XCTAssertEqual(window.code, "111111")
            XCTAssertFalse(window.acceptsAttempt(at: time.addingTimeInterval(1.9)))
            XCTAssertTrue(window.acceptsAttempt(at: time.addingTimeInterval(2)))
        }
        window.registerWrongCode(now: start.addingTimeInterval(20), newCode: { "222222" })
        XCTAssertEqual(window.code, "222222")
        XCTAssertEqual(window.wrongCodes, 0)
        // Wrong codes never extend the window.
        XCTAssertEqual(window.expires, start.addingTimeInterval(PairingWindow.duration))
        XCTAssertFalse(window.acceptsAttempt(at: start.addingTimeInterval(301)))
    }

    // MARK: Handshake

    private struct Pair {
        let remote: RemoteSessionKeys
        let scanner: RemoteSessionKeys
        let transcript: Data
    }

    private func handshake(remoteSecret: Data, scannerSecret: Data) throws -> Pair {
        let remoteKey = Curve25519.KeyAgreement.PrivateKey()
        let scannerKey = Curve25519.KeyAgreement.PrivateKey()
        let clientHello = try HandshakeMessage(type: .clientHello, version: 1, mode: .pair, deviceID: UUID(),
                                               deviceName: "Remote", publicKey: remoteKey.publicKey.rawRepresentation,
                                               nonce: RemoteHandshake.randomNonce()).encoded()
        let serverHello = try HandshakeMessage(type: .serverHello, version: 1, deviceID: UUID(), deviceName: "Scanner",
                                               publicKey: scannerKey.publicKey.rawRepresentation,
                                               nonce: RemoteHandshake.randomNonce()).encoded()
        let transcript = RemoteHandshake.transcript(clientHello: clientHello, serverHello: serverHello)
        let remote = try RemoteHandshake.keys(privateKey: remoteKey, peerPublicKey: scannerKey.publicKey.rawRepresentation,
                                              secret: remoteSecret, transcript: transcript)
        let scanner = try RemoteHandshake.keys(privateKey: scannerKey, peerPublicKey: remoteKey.publicKey.rawRepresentation,
                                               secret: scannerSecret, transcript: transcript)
        return Pair(remote: remote, scanner: scanner, transcript: transcript)
    }

    private func bytes(_ key: SymmetricKey) -> Data {
        RemoteHandshake.keyData(key)
    }

    func testBothSidesDeriveTheSameKeysAndConfirm() throws {
        let secret = RemoteHandshake.pairingSecret(code: "123456")
        let pair = try handshake(remoteSecret: secret, scannerSecret: secret)
        XCTAssertEqual(bytes(pair.remote.remoteConfirm), bytes(pair.scanner.remoteConfirm))
        XCTAssertEqual(bytes(pair.remote.scannerConfirm), bytes(pair.scanner.scannerConfirm))
        XCTAssertEqual(bytes(pair.remote.remoteToScanner), bytes(pair.scanner.remoteToScanner))
        XCTAssertEqual(bytes(pair.remote.scannerToRemote), bytes(pair.scanner.scannerToRemote))
        XCTAssertEqual(bytes(pair.remote.pairingKey), bytes(pair.scanner.pairingKey))
        XCTAssertEqual(bytes(pair.remote.pairingKey).count, 32)
        // Five different keys.
        let all = [pair.remote.remoteConfirm, pair.remote.scannerConfirm, pair.remote.remoteToScanner,
                   pair.remote.scannerToRemote, pair.remote.pairingKey].map(bytes)
        XCTAssertEqual(Set(all).count, 5)

        let mac = RemoteHandshake.confirmation(key: pair.remote.remoteConfirm, transcript: pair.transcript)
        XCTAssertEqual(mac.count, 32)
        XCTAssertTrue(RemoteHandshake.isValid(mac, key: pair.scanner.remoteConfirm, transcript: pair.transcript))
        XCTAssertFalse(RemoteHandshake.isValid(mac, key: pair.scanner.scannerConfirm, transcript: pair.transcript))
        XCTAssertFalse(RemoteHandshake.isValid(mac.prefix(31), key: pair.scanner.remoteConfirm, transcript: pair.transcript))
        var tampered = pair.transcript
        tampered[tampered.startIndex] ^= 1
        XCTAssertFalse(RemoteHandshake.isValid(mac, key: pair.scanner.remoteConfirm, transcript: tampered))
    }

    func testWrongCodeGivesDifferentKeysAndFailsConfirmation() throws {
        let pair = try handshake(remoteSecret: RemoteHandshake.pairingSecret(code: "123456"),
                                 scannerSecret: RemoteHandshake.pairingSecret(code: "123457"))
        XCTAssertNotEqual(bytes(pair.remote.remoteToScanner), bytes(pair.scanner.remoteToScanner))
        let mac = RemoteHandshake.confirmation(key: pair.remote.remoteConfirm, transcript: pair.transcript)
        XCTAssertFalse(RemoteHandshake.isValid(mac, key: pair.scanner.remoteConfirm, transcript: pair.transcript))
    }

    func testPairingKeyResumeAgrees() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let pair = try handshake(remoteSecret: key, scannerSecret: key)
        XCTAssertEqual(bytes(pair.remote.scannerToRemote), bytes(pair.scanner.scannerToRemote))
        let other = try handshake(remoteSecret: key, scannerSecret: Data(repeating: 7, count: 32))
        XCTAssertNotEqual(bytes(other.remote.scannerToRemote), bytes(other.scanner.scannerToRemote))
    }

    func testTranscriptBindsBothHellosAndTheirBoundary() {
        let a = Data("abc".utf8), b = Data("def".utf8)
        let t = RemoteHandshake.transcript(clientHello: a, serverHello: b)
        XCTAssertEqual(t.count, 32)
        XCTAssertEqual(t, RemoteHandshake.transcript(clientHello: a, serverHello: b))
        XCTAssertNotEqual(t, RemoteHandshake.transcript(clientHello: b, serverHello: a))
        XCTAssertNotEqual(RemoteHandshake.transcript(clientHello: Data("ab".utf8), serverHello: Data("cdef".utf8)),
                          RemoteHandshake.transcript(clientHello: Data("abc".utf8), serverHello: Data("def".utf8)))
    }

    func testBadPeerKeyThrows() {
        XCTAssertThrowsError(try RemoteHandshake.keys(privateKey: Curve25519.KeyAgreement.PrivateKey(),
                                                      peerPublicKey: Data(count: 31), secret: Data(),
                                                      transcript: Data(count: 32)))
    }

    func testHandshakeMessageJSONAndChecks() throws {
        let id = UUID()
        let hello = HandshakeMessage(type: .clientHello, version: 1, mode: .resume, deviceID: id, deviceName: "iPhone 1A2B",
                                     publicKey: Data(count: 32), nonce: Data(count: 32))
        let decoded = try HandshakeMessage.decode(hello.encoded())
        XCTAssertEqual(decoded, hello)
        XCTAssertTrue(decoded.isWellFormedHello)
        XCTAssertFalse(HandshakeMessage(type: .clientHello, deviceID: id, publicKey: Data(count: 31),
                                        nonce: Data(count: 32)).isWellFormedHello)
        XCTAssertFalse(HandshakeMessage(type: .clientHello, publicKey: Data(count: 32), nonce: Data(count: 32)).isWellFormedHello)
        let refused = try HandshakeMessage.decode(HandshakeMessage(type: .refused, refusal: .wrongCode).encoded())
        XCTAssertEqual(refused.refusal, .wrongCode)
        XCTAssertThrowsError(try HandshakeMessage.decode(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? RemoteLinkError, .badHandshake)
        }
        XCTAssertThrowsError(try HandshakeMessage.decode(Data("{\"type\":\"other\"}".utf8)))
    }

    // MARK: Secure channel

    private func channels() -> (remote: SecureChannel, scanner: SecureChannel) {
        let up = SymmetricKey(size: .bits256)
        let down = SymmetricKey(size: .bits256)
        return (SecureChannel(sendKey: up, receiveKey: down), SecureChannel(sendKey: down, receiveKey: up))
    }

    func testChannelRoundTripBothWays() throws {
        var (remote, scanner) = channels()
        for index in 0..<5 {
            let message = Data("message \(index)".utf8)
            let sealed = try remote.seal(message)
            XCTAssertEqual(sealed.count, message.count + SecureChannel.tagSize)
            XCTAssertNotEqual(sealed.prefix(message.count), message)
            XCTAssertEqual(try scanner.open(sealed), message)
            let reply = try scanner.seal(Data())
            XCTAssertEqual(try remote.open(reply), Data())
        }
        XCTAssertEqual(remote.sendCounter, 5)
        XCTAssertEqual(scanner.receiveCounter, 5)
    }

    func testChannelRejectsTamperReplayReorderAndWrongDirection() throws {
        var (remote, scanner) = channels()
        let first = try remote.seal(Data("one".utf8))
        let second = try remote.seal(Data("two".utf8))

        var tampered = first
        tampered[tampered.startIndex] ^= 0x01
        XCTAssertThrowsError(try scanner.open(tampered)) { XCTAssertEqual($0 as? RemoteLinkError, .authenticationFailed) }
        XCTAssertThrowsError(try scanner.open(second))                     // out of order
        XCTAssertThrowsError(try scanner.open(Data(count: 15)))            // shorter than a tag
        XCTAssertEqual(scanner.receiveCounter, 0)
        XCTAssertEqual(try scanner.open(first), Data("one".utf8))
        XCTAssertThrowsError(try scanner.open(first))                      // replay
        XCTAssertEqual(try scanner.open(second), Data("two".utf8))

        let own = try remote.seal(Data("echo".utf8))
        XCTAssertThrowsError(try remote.open(own))                         // the other direction's key
    }

    func testChannelOpensSlicedPayload() throws {
        var (remote, scanner) = channels()
        let sealed = try remote.seal(Data("slice".utf8))
        var padded = Data([0xAA, 0xBB])
        padded.append(sealed)
        XCTAssertEqual(try scanner.open(padded.dropFirst(2)), Data("slice".utf8))
    }

    func testNonceLayout() throws {
        let nonce = try SecureChannel.nonce(0x0102_0304_0506_0708)
        XCTAssertEqual(Array(nonce.withUnsafeBytes { Data($0) }),
                       [0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8])
    }
}
