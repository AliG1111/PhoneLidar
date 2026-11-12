import XCTest

final class RemoteProtocolTests: XCTestCase {
    // MARK: Frames

    func testFrameEncodingIsBigEndianLengthThenPayload() {
        let frame = RemoteFrame.encode(Data([9, 8, 7]))
        XCTAssertEqual(Array(frame), [0, 0, 0, 3, 9, 8, 7])
        XCTAssertEqual(Array(RemoteFrame.encode(Data())), [0, 0, 0, 0])
    }

    func testDecoderReassemblesFramesAcrossPushes() throws {
        var decoder = RemoteFrameDecoder(limit: 100)
        var stream = RemoteFrame.encode(Data("first".utf8))
        stream.append(RemoteFrame.encode(Data()))
        stream.append(RemoteFrame.encode(Data("third frame".utf8)))
        var frames: [Data] = []
        // One byte at a time.
        for byte in stream {
            decoder.push(Data([byte]))
            while let frame = try decoder.next() { frames.append(frame) }
        }
        XCTAssertEqual(frames, [Data("first".utf8), Data(), Data("third frame".utf8)])
        XCTAssertEqual(decoder.pendingBytes, 0)

        // All at once.
        var whole = RemoteFrameDecoder(limit: 100)
        whole.push(stream)
        XCTAssertEqual(try whole.next(), Data("first".utf8))
        XCTAssertEqual(try whole.next(), Data())
        XCTAssertEqual(try whole.next(), Data("third frame".utf8))
        XCTAssertNil(try whole.next())
    }

    func testDecoderRejectsOversizeFrameBeforeItsBytesArrive() {
        var decoder = RemoteFrameDecoder(limit: 10)
        decoder.push(Data([0, 0, 0, 11]))
        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? RemoteLinkError, .frameTooLarge(11))
        }
    }

    func testDecoderLimitCanChangeBetweenFrames() throws {
        var decoder = RemoteFrameDecoder(limit: 4)
        var stream = RemoteFrame.encode(Data("ok".utf8))
        stream.append(RemoteFrame.encode(Data(repeating: 1, count: 50)))
        decoder.push(stream)
        XCTAssertEqual(try decoder.next(), Data("ok".utf8))
        decoder.limit = 64
        XCTAssertEqual(try decoder.next()?.count, 50)
    }

    func testDecoderCompactsAndKeepsPartialFrame() throws {
        var decoder = RemoteFrameDecoder(limit: 1_000)
        for index in 0..<50 {
            decoder.push(RemoteFrame.encode(Data(repeating: UInt8(index), count: 20)))
            XCTAssertEqual(try decoder.next(), Data(repeating: UInt8(index), count: 20))
        }
        let next = RemoteFrame.encode(Data("tail".utf8))
        decoder.push(next.prefix(5))
        XCTAssertNil(try decoder.next())
        decoder.push(next.dropFirst(5))
        XCTAssertEqual(try decoder.next(), Data("tail".utf8))
    }

    // MARK: Records

    func testEveryMessageRoundTrips() throws {
        let scan = RemoteScanInfo(id: UUID(), name: "Line 12 Nov", created: Date(timeIntervalSince1970: 1_731_400_000.25),
                                  summary: ["900 frames"], files: [RemoteFileInfo(name: "Video.mov", size: 123_456_789,
                                                                                  modified: 1_731_400_123.5)])
        var status = RemoteStatus()
        status.lineScanOpen = true
        status.phase = .recording
        status.elapsed = 61.5
        status.frames = 1_845
        status.speed = 612.4
        status.warnings = ["Baseline coverage only 72 %"]
        status.freeBytes = 12_000_000_000
        status.scansVersion = -42
        let messages: [RemoteMessage] = [
            .ping,
            .status(status),
            .command(id: 7, action: .startRecording),
            .commandResult(id: 7, accepted: false, message: "too hot"),
            .commandResult(id: 8, accepted: true, message: nil),
            .listScans,
            .scans([scan]),
            .fileRequest(RemoteFileRequest(transferID: 3, scanID: scan.id, name: "Video.mov", offset: 262_144,
                                           size: 123_456_789, modified: 1_731_400_123.5)),
            .fileEnd(transferID: 3, size: 123_456_789),
            .fileError(transferID: 3, reason: .busy, message: "recording"),
            .chunkAck(transferID: 3, received: 524_288),
            .cancelTransfer(transferID: 3),
        ]
        for message in messages {
            let record = try RemoteRecord.message(message)
            XCTAssertEqual(record.first, RemoteRecord.messageKind)
            XCTAssertEqual(try RemoteRecord.decode(record), .message(message))
        }
    }

    func testChunkRecordRoundTrip() throws {
        let data = Data((0..<300).map { UInt8($0 % 251) })
        let record = RemoteRecord.chunk(transferID: 0xDEAD_BEEF, offset: 5_000_000_000, data: data)
        XCTAssertEqual(record.count, RemoteRecord.chunkHeaderSize + data.count)
        XCTAssertEqual(Array(record.prefix(5)), [2, 0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(try RemoteRecord.decode(record), .chunk(transferID: 0xDEAD_BEEF, offset: 5_000_000_000, data: data))
        // A record that is a slice of a larger buffer decodes the same.
        var padded = Data([1, 2, 3])
        padded.append(record)
        XCTAssertEqual(try RemoteRecord.decode(padded.dropFirst(3)),
                       .chunk(transferID: 0xDEAD_BEEF, offset: 5_000_000_000, data: data))
        XCTAssertEqual(try RemoteRecord.decode(RemoteRecord.chunk(transferID: 1, offset: 0, data: Data())),
                       .chunk(transferID: 1, offset: 0, data: Data()))
    }

    func testBadAndUnknownRecords() throws {
        XCTAssertThrowsError(try RemoteRecord.decode(Data())) { XCTAssertEqual($0 as? RemoteLinkError, .badRecord) }
        XCTAssertThrowsError(try RemoteRecord.decode(Data([2, 0, 0, 0])))
        var hugeOffset = Data([2, 0, 0, 0, 1])
        hugeOffset.appendBigEndian(UInt64.max)
        XCTAssertThrowsError(try RemoteRecord.decode(hugeOffset))
        XCTAssertEqual(try RemoteRecord.decode(Data([9, 1, 2])), .unknown)
        var future = Data([RemoteRecord.messageKind])
        future.append(Data("{\"newThing\":{}}".utf8))
        XCTAssertEqual(try RemoteRecord.decode(future), .unknown)
    }

    // MARK: Status

    func testStatusSanitizedDropsNonFiniteNumbersSoItEncodes() throws {
        var status = RemoteStatus()
        status.elapsed = .infinity
        status.speed = .nan
        status.lock = 1.7
        status.distance = -.infinity
        status.centerHeight = .nan
        status.levelX = .nan
        status.levelY = 0.4
        status.battery = .nan
        XCTAssertThrowsError(try RemoteRecord.message(.status(status)))
        let clean = status.sanitized()
        XCTAssertEqual(clean.elapsed, 0)
        XCTAssertNil(clean.speed)
        XCTAssertEqual(clean.lock, 1)
        XCTAssertNil(clean.distance)
        XCTAssertNil(clean.centerHeight)
        XCTAssertNil(clean.levelX)
        XCTAssertEqual(clean.levelY, 0.4)
        XCTAssertNil(clean.battery)
        XCTAssertNoThrow(try RemoteRecord.message(.status(clean)))
    }

    func testStatusBusyPhases() {
        let busy: [RemotePhase] = [.arming, .recording, .saving, .building]
        for phase in [RemotePhase.closed, .starting, .ready, .arming, .recording, .saving, .building, .failed] {
            var status = RemoteStatus()
            status.phase = phase
            XCTAssertEqual(status.isBusy, busy.contains(phase), phase.rawValue)
        }
        XCTAssertFalse(RemoteStatus.closed.lineScanOpen)
        XCTAssertEqual(RemoteStatus.closed.phase, .closed)
    }

    func testScanTotalBytesAndBigEndianHelpers() {
        let scan = RemoteScanInfo(id: UUID(), name: "a", created: Date(), summary: [],
                                  files: [RemoteFileInfo(name: "a", size: 10, modified: 0),
                                          RemoteFileInfo(name: "b", size: 5_000_000_000, modified: 0)])
        XCTAssertEqual(scan.totalBytes, 5_000_000_010)
        var data = Data([0xFF])
        data.appendBigEndian(UInt32(0x0102_0304))
        data.appendBigEndian(UInt64(0x0A0B_0C0D_0E0F_1011))
        XCTAssertEqual(data.bigEndianUInt32(at: 1), 0x0102_0304)
        XCTAssertEqual(data.bigEndianUInt64(at: 5), 0x0A0B_0C0D_0E0F_1011)
        XCTAssertEqual(data.dropFirst().bigEndianUInt32(at: 0), 0x0102_0304)
    }
}
