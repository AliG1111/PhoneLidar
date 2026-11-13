import XCTest

/// Profiles.bin coding, writer and reader, LaserRecording.json and LaserFrames.csv rows (design §14.6,
/// FR-LAS-07).
final class ProfilesFileTests: XCTestCase {
    private let columns = LaserColumns(first: 1, stride: 2, count: 6)

    // MARK: - Value coding

    func testRowsAreStoredInThirtySecondsOfAPixel() {
        XCTAssertEqual(ProfilesFile.encode(row: 0), 0)
        XCTAssertEqual(ProfilesFile.encode(row: 10.53125), 337)
        XCTAssertEqual(ProfilesFile.encode(row: 10.51), 336)       // 336.32 rounds down
        XCTAssertEqual(ProfilesFile.encode(row: 1000.25), 32_008)
        XCTAssertEqual(ProfilesFile.decode(row: 337), 10.53125)
        XCTAssertEqual(ProfilesFile.decode(row: 0), 0)
    }

    func testEncodeThenDecodeIsWithinHalfAStep() {
        for row in stride(from: Float(0), through: 2000, by: 7.318) {
            let back = ProfilesFile.decode(row: ProfilesFile.encode(row: row))
            XCTAssertEqual(back, row, accuracy: 1 / 64 + 1e-4, "row \(row)")
        }
    }

    func testMultiplesOfAThirtySecondRoundTripExactly() {
        for value in [UInt16(0), 1, 31, 32, 337, 32_008, 65_534] {
            let row = ProfilesFile.decode(row: value)
            XCTAssertEqual(ProfilesFile.encode(row: row), value)
        }
    }

    func testNaNNegativeAndTooLargeRowsBecomeNoRow() {
        XCTAssertEqual(ProfilesFile.encode(row: .nan), ProfilesFile.noRow)
        XCTAssertEqual(ProfilesFile.encode(row: .infinity), ProfilesFile.noRow)
        XCTAssertEqual(ProfilesFile.encode(row: -.infinity), ProfilesFile.noRow)
        XCTAssertEqual(ProfilesFile.encode(row: -0.01), ProfilesFile.noRow)
        XCTAssertEqual(ProfilesFile.encode(row: 2048), ProfilesFile.noRow)
        XCTAssertEqual(ProfilesFile.encode(row: 100_000), ProfilesFile.noRow)
        // 2047.96875 · 32 = 65535 is the marker itself.
        XCTAssertEqual(ProfilesFile.encode(row: 2047.96875), ProfilesFile.noRow)
        XCTAssertEqual(ProfilesFile.encode(row: 2047.9375), 65_534)
        XCTAssertTrue(ProfilesFile.decode(row: ProfilesFile.noRow).isNaN)
    }

    func testRecordSizeIsHeaderFieldsPlusTwoBytesPerColumn() {
        XCTAssertEqual(ProfilesFile.recordSize(columns: 6), 36)
        XCTAssertEqual(ProfilesFile.recordSize(columns: 960), 1944)
    }

    // MARK: - Writer and reader

    private let sampleRows: [[Float]] = [
        [10.5, .nan, 300.03125, 0, 1000.25, 2047.9375],
        [11, 12, 13, 14, 15, 16],
        [.nan, .nan, .nan, .nan, .nan, .nan]
    ]

    /// Writes three frames and returns the file URL.
    private func writeSample(flushBytes: Int = 256_000) throws -> URL {
        let url = try makeTempFolder().appendingPathComponent(ProfilesFile.fileName)
        let writer = try ProfilesFileWriter(url: url, columns: columns, flushBytes: flushBytes)
        try writer.append(time: 0, travel: -1.5, speed: nil, flags: 0, rows: sampleRows[0])
        try writer.append(time: 1.0 / 240, travel: 0, speed: 100.5,
                          flags: ProfilesFile.trackedFlag | ProfilesFile.speedFlag, rows: sampleRows[1])
        try writer.append(time: 0.5, travel: 12.25, speed: 250, flags: ProfilesFile.trackedFlag,
                          rows: sampleRows[2])
        XCTAssertEqual(writer.recordCount, 3)
        try writer.close()
        return url
    }

    private func assertSameRows(_ actual: [Float], _ expected: [Float], file: StaticString = #filePath,
                                line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, e) in zip(actual, expected) {
            if e.isNaN {
                XCTAssertTrue(a.isNaN, file: file, line: line)
            } else {
                XCTAssertEqual(a, e, file: file, line: line)
            }
        }
    }

    func testWriterThenReaderRoundTrip() throws {
        let reader = try ProfilesFileReader(url: try writeSample())
        XCTAssertEqual(reader.columns, columns)
        XCTAssertEqual(reader.frameCount, 3)

        XCTAssertEqual(reader.time(0), 0)
        XCTAssertEqual(reader.time(1), 1.0 / 240)
        XCTAssertEqual(reader.time(2), 0.5)
        XCTAssertEqual(reader.travel(0), -1.5)
        XCTAssertEqual(reader.travel(1), 0)
        XCTAssertEqual(reader.travel(2), 12.25)
        XCTAssertNil(reader.speed(0))
        XCTAssertEqual(try XCTUnwrap(reader.speed(1)), 100.5, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(reader.speed(2)), 250, accuracy: 1e-6)
        XCTAssertEqual(reader.flags(0), 0)
        XCTAssertEqual(reader.flags(1), ProfilesFile.trackedFlag | ProfilesFile.speedFlag)
        XCTAssertEqual(reader.flags(2), ProfilesFile.trackedFlag)
        for i in 0..<3 {
            assertSameRows(reader.rows(i), sampleRows[i])
            for k in 0..<columns.count {
                let expected = sampleRows[i][k]
                if expected.isNaN {
                    XCTAssertTrue(reader.row(i, k).isNaN)
                } else {
                    XCTAssertEqual(reader.row(i, k), expected)
                }
            }
        }
    }

    func testWithRecordsGivesTheSameValuesAsTheAccessors() throws {
        let reader = try ProfilesFileReader(url: try writeSample())
        reader.withRecords { records in
            XCTAssertEqual(records.columns, 6)
            XCTAssertEqual(records.recordSize, 36)
            XCTAssertEqual(records.time(2), 0.5)
            XCTAssertEqual(records.travel(2), 12.25)
            XCTAssertEqual(records.speed(1) ?? 0, 100.5, accuracy: 1e-6)
            XCTAssertNil(records.speed(0))
            XCTAssertEqual(records.flags(1), 3)
            XCTAssertEqual(records.row(0, 2), 300.03125)
            XCTAssertTrue(records.row(0, 1).isNaN)
        }
    }

    func testFileLayout() throws {
        let url = try writeSample()
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, ProfilesFile.headerSize + 3 * ProfilesFile.recordSize(columns: 6))
        XCTAssertEqual(Array(data.prefix(4)), Array("PLLP".utf8))
        XCTAssertEqual(data.readUInt32(at: 4), 1)          // version
        XCTAssertEqual(data.readUInt32(at: 8), 6)          // columns
        XCTAssertEqual(data.readUInt32(at: 12), 1)         // first column
        XCTAssertEqual(data.readUInt32(at: 16), 2)         // stride
        XCTAssertEqual(data.readUInt32(at: 20), 32)        // row scale
    }

    func testSmallFlushBlocksGiveTheSameFile() throws {
        let big = try Data(contentsOf: try writeSample())
        let small = try Data(contentsOf: try writeSample(flushBytes: 1))
        XCTAssertEqual(big, small)
    }

    func testNonFiniteTimeAndTravelAreStoredAsZero() throws {
        let url = try makeTempFolder().appendingPathComponent(ProfilesFile.fileName)
        let writer = try ProfilesFileWriter(url: url, columns: columns)
        try writer.append(time: .nan, travel: .infinity, speed: .nan, flags: 0, rows: sampleRows[1])
        try writer.close()
        let reader = try ProfilesFileReader(url: url)
        XCTAssertEqual(reader.time(0), 0)
        XCTAssertEqual(reader.travel(0), 0)
        XCTAssertNil(reader.speed(0))
    }

    func testManyFramesRoundTrip() throws {
        let url = try makeTempFolder().appendingPathComponent(ProfilesFile.fileName)
        let writer = try ProfilesFileWriter(url: url, columns: columns, flushBytes: 500)
        for i in 0..<200 {
            try writer.append(time: Double(i) / 240, travel: Double(i) * 0.5, speed: i % 2 == 0 ? Double(i) : nil,
                              flags: UInt32(i % 4), rows: (0..<6).map { Float(i) + Float($0) * 0.5 })
        }
        try writer.close()
        let reader = try ProfilesFileReader(url: url)
        XCTAssertEqual(reader.frameCount, 200)
        XCTAssertEqual(reader.time(199), 199.0 / 240)
        XCTAssertEqual(reader.travel(150), 75)
        XCTAssertEqual(reader.flags(7), 3)
        XCTAssertEqual(reader.speed(10) ?? -1, 10, accuracy: 1e-6)
        XCTAssertNil(reader.speed(11))
        XCTAssertEqual(reader.row(120, 3), 121.5)
    }

    func testWriterRefusesBadInput() throws {
        let url = try makeTempFolder().appendingPathComponent(ProfilesFile.fileName)
        XCTAssertThrowsError(try ProfilesFileWriter(url: url, columns: LaserColumns(first: 0, stride: 1, count: 0))) {
            assertLineError($0, .badFile)
        }
        let writer = try ProfilesFileWriter(url: url, columns: columns)
        XCTAssertThrowsError(try writer.append(time: 0, travel: 0, speed: nil, flags: 0, rows: [1, 2, 3])) {
            assertLineError($0, .badFile)
        }
        XCTAssertEqual(writer.recordCount, 0)
        try writer.close()
        try writer.close()      // closing twice is harmless
        XCTAssertThrowsError(try writer.append(time: 0, travel: 0, speed: nil, flags: 0, rows: sampleRows[1])) {
            assertLineError($0, .writeFailed)
        }
    }

    // MARK: - Reader refusals

    /// The sample file with `edit` applied to its bytes.
    private func patchedSample(_ edit: (inout Data) -> Void) throws -> URL {
        let url = try writeSample()
        var data = try Data(contentsOf: url)
        edit(&data)
        try data.write(to: url)
        return url
    }

    func testCutOffLastRecordIsIgnored() throws {
        let url = try patchedSample { $0.removeLast(5) }
        let reader = try ProfilesFileReader(url: url)
        XCTAssertEqual(reader.frameCount, 2)
        assertSameRows(reader.rows(1), sampleRows[1])
        // A file holding only the header has no frames.
        let headerOnly = try patchedSample { $0 = Data($0.prefix(ProfilesFile.headerSize)) }
        XCTAssertEqual(try ProfilesFileReader(url: headerOnly).frameCount, 0)
    }

    func testBadMagicOrVersionOrScaleIsRejected() throws {
        let badMagic = try patchedSample { $0[0] = 0x58 }
        XCTAssertThrowsError(try ProfilesFileReader(url: badMagic)) { assertLineError($0, .badFile) }
        let badVersion = try patchedSample { $0[4] = 2 }
        XCTAssertThrowsError(try ProfilesFileReader(url: badVersion)) { assertLineError($0, .badFile) }
        let badScale = try patchedSample { $0[20] = 16 }
        XCTAssertThrowsError(try ProfilesFileReader(url: badScale)) { assertLineError($0, .badFile) }
    }

    func testImplausibleColumnLayoutsAreRejected() throws {
        let noColumns = try patchedSample { $0[8] = 0 }
        XCTAssertThrowsError(try ProfilesFileReader(url: noColumns)) { assertLineError($0, .badFile) }
        let tooManyColumns = try patchedSample { $0[8] = 0; $0[9] = 0x41 }          // 16,640
        XCTAssertThrowsError(try ProfilesFileReader(url: tooManyColumns)) { assertLineError($0, .badFile) }
        let zeroStride = try patchedSample { $0[16] = 0 }
        XCTAssertThrowsError(try ProfilesFileReader(url: zeroStride)) { assertLineError($0, .badFile) }
        let hugeStride = try patchedSample { $0[16] = 65 }
        XCTAssertThrowsError(try ProfilesFileReader(url: hugeStride)) { assertLineError($0, .badFile) }
        let farFirst = try patchedSample { $0[12] = 0; $0[13] = 0x40 }              // 16,384
        XCTAssertThrowsError(try ProfilesFileReader(url: farFirst)) { assertLineError($0, .badFile) }
    }

    func testFileShorterThanTheHeaderIsRejected() throws {
        let short = try patchedSample { $0 = Data($0.prefix(ProfilesFile.headerSize - 1)) }
        XCTAssertThrowsError(try ProfilesFileReader(url: short)) { assertLineError($0, .badFile) }
        let missing = try makeTempFolder().appendingPathComponent("Nothing.bin")
        XCTAssertThrowsError(try ProfilesFileReader(url: missing))
    }
}

final class LaserRecordingInfoTests: XCTestCase {
    func testSaveAndLoadRoundTrip() throws {
        let folder = try makeTempFolder()
        XCTAssertFalse(LaserRecordingInfo.exists(in: folder))
        XCTAssertThrowsError(try LaserRecordingInfo.load(from: folder))

        var calibration = makeLaserCalibration(side: .right)
        calibration.scaleSource = .angle
        calibration.laserAngle = 28
        var info = makeLaserInfo(calibration: calibration, direction: .leftToRight, mapMethod: .averaged,
                                 frameCount: 1234, duration: 5.1)
        info.droppedFrames = 3
        info.stopReason = "Low storage"
        try info.save(to: folder)
        XCTAssertTrue(LaserRecordingInfo.exists(in: folder))

        let back = try LaserRecordingInfo.load(from: folder)
        XCTAssertEqual(back.version, 1)
        XCTAssertEqual(back.videoWidth, 400)
        XCTAssertEqual(back.videoHeight, 300)
        XCTAssertEqual(back.frameRate, 240)
        XCTAssertEqual(back.activeFrameRate, 240)
        XCTAssertEqual(back.direction, .leftToRight)
        XCTAssertEqual(back.columns, calibration.columns)
        XCTAssertEqual(back.fx, 1000)
        XCTAssertEqual(back.cy, 150)
        XCTAssertEqual(back.shutterLimit, 0.001)
        XCTAssertEqual(back.maxHeight, 100)
        XCTAssertEqual(back.mapMethod, .averaged)
        XCTAssertEqual(back.calibration, calibration)
        XCTAssertEqual(back.frameCount, 1234)
        XCTAssertEqual(back.duration, 5.1)
        XCTAssertEqual(back.droppedFrames, 3)
        XCTAssertEqual(back.stopReason, "Low storage")
    }

    func testRecordingStartedButNotStoppedHasNoFrameCount() throws {
        let folder = try makeTempFolder()
        try makeLaserInfo().save(to: folder)
        let back = try LaserRecordingInfo.load(from: folder)
        XCTAssertNil(back.frameCount)
        XCTAssertNil(back.duration)
        XCTAssertEqual(back.summaryLine, "0 profiles, 0.0 s at 240 fps, material travel Right → Left")
    }

    func testSummaryLine() {
        let info = makeLaserInfo(direction: .rightToLeft, frameCount: 1234, duration: 5.1)
        XCTAssertEqual(info.summaryLine, "1234 profiles, 5.1 s at 240 fps, material travel Right → Left")
        XCTAssertEqual(LaserRecordingInfo.summaryLine(frames: 7, duration: 0.04, fps: 120, direction: .leftToRight),
                       "7 profiles, 0.0 s at 120 fps, material travel Left → Right")
    }

    func testSummaryLineRecognition() {
        XCTAssertTrue(LaserRecordingInfo.isSummaryLine("1234 profiles, 5.1 s at 240 fps, material travel Right → Left"))
        XCTAssertTrue(LaserRecordingInfo.isSummaryLine(
            LaserRecordingInfo.summaryLine(frames: 3, duration: 12.34, fps: 60, direction: .leftToRight)))
        XCTAssertFalse(LaserRecordingInfo.isSummaryLine("120 frames, 4.0 s, material travel Right → Left"))
        XCTAssertFalse(LaserRecordingInfo.isSummaryLine("Scanned 1.20 m long × 0.60 m wide"))
        XCTAssertFalse(LaserRecordingInfo.isSummaryLine("profiles, 5.1 s at 240 fps, material travel Right → Left"))
        XCTAssertFalse(LaserRecordingInfo.isSummaryLine("1234 profiles, 5 s at 240 fps, material travel Right → Left"))
        // A LiDAR recording line is not a laser line and the other way round.
        XCTAssertFalse(LineRecordingInfo.isSummaryLine("1234 profiles, 5.1 s at 240 fps, material travel Right → Left"))
    }
}

final class LaserFramesCSVTests: XCTestCase {
    func testHeader() {
        XCTAssertEqual(LaserFramesCSV.header.count, 7)
        XCTAssertEqual(LaserFramesCSV.header.first, "frame")
        XCTAssertEqual(LaserFramesCSV.header.last, "max_height_mm")
        XCTAssertEqual(LaserFramesCSV.fileName, "LaserFrames.csv")
    }

    func testRowWithEveryField() {
        let row = LaserFramesCSV.row(frame: 3, time: 0.123456, speed: 219.04, travel: 12.5, detectedPercent: 97.3,
                                     medianHeight: 1.234, maxHeight: 4.5)
        XCTAssertEqual(row, "3,0.12346,219.0,12.50,97.3,1.23,4.50")
        XCTAssertEqual(row.split(separator: ",").count, LaserFramesCSV.header.count)
    }

    func testMissingAndNonFiniteValuesStayBlank() {
        let row = LaserFramesCSV.row(frame: 0, time: 0, speed: nil, travel: -2.5, detectedPercent: 0,
                                     medianHeight: nil, maxHeight: .nan)
        XCTAssertEqual(row, "0,0.00000,,-2.50,0.0,,")
        let infinite = LaserFramesCSV.row(frame: 1, time: 0.5, speed: .infinity, travel: 0, detectedPercent: 50,
                                          medianHeight: .nan, maxHeight: 1)
        XCTAssertEqual(infinite, "1,0.50000,,0.00,50.0,,1.00")
    }
}
