import CoreGraphics
import XCTest

final class LineMathTests: XCTestCase {
    func testSmoothedAveragesWithinTheRadius() {
        let out = LineMath.smoothed([1, 2, 3, 4, 5], radius: 1)
        XCTAssertEqual(out, [1.5, 2, 3, 4, 4.5])
    }

    func testSmoothedSkipsMissingValues() {
        let out = LineMath.smoothed([1, nil, 3], radius: 1)
        XCTAssertEqual(out, [1, 2, 3])
    }

    func testSmoothedKeepsGapsThatHaveNoNeighbours() {
        let out = LineMath.smoothed([nil, nil, nil, 4], radius: 1)
        XCTAssertEqual(out, [nil, nil, 4, 4])
    }

    func testSmoothedWithRadiusZeroIsTheIdentity() {
        let input: [Double?] = [1, nil, 3]
        XCTAssertEqual(LineMath.smoothed(input, radius: 0), input)
    }

    func testSmoothedOfNothingIsNothing() {
        XCTAssertEqual(LineMath.smoothed([], radius: 3).count, 0)
    }

    func testSmoothedWithRadiusLargerThanTheSeriesIsTheMean() {
        let out = LineMath.smoothed([2, 4, 6], radius: 10)
        XCTAssertEqual(out, [4, 4, 4])
    }

    func testFrameIndexFindsTheLastFrameAtOrBeforeTheTime() {
        let frames = (0..<4).map { makeFrame(index: $0, time: Double($0) * 0.1) }
        XCTAssertEqual(LineMath.frameIndex(for: -1, in: frames), 0)
        XCTAssertEqual(LineMath.frameIndex(for: 0, in: frames), 0)
        XCTAssertEqual(LineMath.frameIndex(for: 0.05, in: frames), 0)
        XCTAssertEqual(LineMath.frameIndex(for: 0.1, in: frames), 1)
        XCTAssertEqual(LineMath.frameIndex(for: 0.15, in: frames), 1)
        XCTAssertEqual(LineMath.frameIndex(for: 0.25, in: frames), 2)
        XCTAssertEqual(LineMath.frameIndex(for: 99, in: frames), 3)
    }

    func testFrameIndexOfNoFramesIsZero() {
        XCTAssertEqual(LineMath.frameIndex(for: 1, in: []), 0)
    }
}

final class ZoneGridTests: XCTestCase {
    func testGridIsSixAcrossByFourAlong() {
        XCTAssertEqual(ZoneGrid.columns, 6)
        XCTAssertEqual(ZoneGrid.rows, 4)
    }

    func testTileAtDisplayPoint() {
        // Zones: columns run top → bottom of the portrait picture, rows run right → left.
        XCTAssertEqual(ZoneGrid.tile(atDisplay: CGPoint(x: 1, y: 0)), 0)              // top right
        XCTAssertEqual(ZoneGrid.tile(atDisplay: CGPoint(x: 0.999, y: 0.999)), 5)      // bottom right
        XCTAssertEqual(ZoneGrid.tile(atDisplay: CGPoint(x: 0, y: 0)), 18)             // top left
        XCTAssertEqual(ZoneGrid.tile(atDisplay: CGPoint(x: 0, y: 0.999)), 23)         // bottom left
        XCTAssertEqual(ZoneGrid.tile(atDisplay: CGPoint(x: 0.5, y: 0.5)), 15)         // row 2, column 3
    }

    func testTileAtDisplayPointClampsOutsideTheUnitSquare() {
        XCTAssertEqual(ZoneGrid.tile(atDisplay: CGPoint(x: 2, y: -1)), 0)
        XCTAssertEqual(ZoneGrid.tile(atDisplay: CGPoint(x: -1, y: 2)), 23)
    }

    func testTileForDepthPixel() {
        XCTAssertEqual(ZoneGrid.tile(u: 0, v: 0, width: 192, height: 256), 0)
        XCTAssertEqual(ZoneGrid.tile(u: 191, v: 255, width: 192, height: 256), 23)
        XCTAssertEqual(ZoneGrid.tile(u: 32, v: 64, width: 192, height: 256), 7)       // column 1, row 1
        XCTAssertEqual(ZoneGrid.tile(u: 190, v: 0, width: 192, height: 256), 5)
        XCTAssertEqual(ZoneGrid.tile(u: 0, v: 255, width: 192, height: 256), 18)
    }

    func testTileForDepthPixelClampsOutOfRangePixels() {
        XCTAssertEqual(ZoneGrid.tile(u: -5, v: -5, width: 192, height: 256), 0)
        XCTAssertEqual(ZoneGrid.tile(u: 1000, v: 1000, width: 192, height: 256), 23)
    }

    func testDisplayCenterOfTile() throws {
        let first = try XCTUnwrap(ZoneGrid.displayCenter(ofTile: 0))
        XCTAssertEqual(first.x, 0.875, accuracy: 1e-9)
        XCTAssertEqual(first.y, 0.5 / 6, accuracy: 1e-9)
        let last = try XCTUnwrap(ZoneGrid.displayCenter(ofTile: 23))
        XCTAssertEqual(last.x, 0.125, accuracy: 1e-9)
        XCTAssertEqual(last.y, 5.5 / 6, accuracy: 1e-9)
    }

    func testDisplayCenterOutOfRangeIsNil() {
        XCTAssertNil(ZoneGrid.displayCenter(ofTile: -1))
        XCTAssertNil(ZoneGrid.displayCenter(ofTile: 24))
    }

    func testEveryTileCentreMapsBackToItsTile() throws {
        for tile in 0..<(ZoneGrid.columns * ZoneGrid.rows) {
            let centre = try XCTUnwrap(ZoneGrid.displayCenter(ofTile: tile))
            XCTAssertEqual(ZoneGrid.tile(atDisplay: centre), tile)
        }
    }
}

final class SpeedTextTests: XCTestCase {
    func testMainAndShortRoundToWholeMillimetresPerSecond() {
        XCTAssertEqual(SpeedText.main(612.4), "612 mm/s")
        XCTAssertEqual(SpeedText.short(612.4), "612 mm/s")
        XCTAssertEqual(SpeedText.main(-50.6), "-51 mm/s")
        XCTAssertEqual(SpeedText.main(0), "0 mm/s")
    }

    func testMissingSpeedShowsADash() {
        XCTAssertEqual(SpeedText.main(nil), "— mm/s")
        XCTAssertEqual(SpeedText.short(nil), "— mm/s")
    }

    func testPerMinuteConvertsToMetresAndFeetPerMinute() {
        // 1000 mm/s = 60 m/min = 196.85 ft/min
        XCTAssertEqual(SpeedText.perMinute(1000), "60.00 m/min  ·  196.9 ft/min")
        // 500 mm/s = 30 m/min = 98.43 ft/min
        XCTAssertEqual(SpeedText.perMinute(500), "30.00 m/min  ·  98.4 ft/min")
        XCTAssertEqual(SpeedText.perMinute(0), "0.00 m/min  ·  0.0 ft/min")
        // A 12 ft/s (3657.6 mm/s) belt: 219.456 m/min = 720 ft/min.
        XCTAssertEqual(SpeedText.perMinute(3657.6), "219.46 m/min  ·  720.0 ft/min")
    }

    func testMissingSpeedMeansNoTextureLock() {
        XCTAssertEqual(SpeedText.perMinute(nil), "no texture lock")
    }
}

final class TravelDirectionTests: XCTestCase {
    func testBufferSign() {
        XCTAssertEqual(TravelDirection.rightToLeft.bufferSign, 1)
        XCTAssertEqual(TravelDirection.leftToRight.bufferSign, -1)
    }

    func testLabelsAndRawValues() {
        XCTAssertEqual(TravelDirection.rightToLeft.label, "Right → Left")
        XCTAssertEqual(TravelDirection.leftToRight.label, "Left → Right")
        XCTAssertEqual(TravelDirection(rawValue: "leftToRight"), .leftToRight)
        XCTAssertEqual(TravelDirection.allCases.count, 2)
    }
}

final class LineErrorTests: XCTestCase {
    func testEveryErrorHasAMessage() {
        XCTAssertNotNil(LineError.noLiDAR.errorDescription)
        XCTAssertNotNil(LineError.badFile.errorDescription)
        XCTAssertNotNil(LineError.notEnoughData.errorDescription)
        XCTAssertEqual(LineError.configuration("Cannot record video.").errorDescription, "Cannot record video.")
    }
}

final class BinaryHelperTests: XCTestCase {
    func testAppendUInt32IsLittleEndian() {
        var data = Data()
        data.appendUInt32(0x12345678)
        XCTAssertEqual(Array(data), [0x78, 0x56, 0x34, 0x12])
    }

    func testReadUInt32RoundTrip() {
        var data = Data()
        for value: UInt32 in [0, 1, 255, 65_536, 0xDEADBEEF, UInt32.max] {
            data.appendUInt32(value)
        }
        XCTAssertEqual(data.readUInt32(at: 0), 0)
        XCTAssertEqual(data.readUInt32(at: 4), 1)
        XCTAssertEqual(data.readUInt32(at: 8), 255)
        XCTAssertEqual(data.readUInt32(at: 12), 65_536)
        XCTAssertEqual(data.readUInt32(at: 16), 0xDEADBEEF)
        XCTAssertEqual(data.readUInt32(at: 20), UInt32.max)
    }

    func testReadUInt32WorksOnADataSlice() {
        var data = Data([9, 9])
        data.appendUInt32(0xCAFEBABE)
        let slice = data.dropFirst(2)
        XCTAssertEqual(slice.readUInt32(at: 0), 0xCAFEBABE)
    }

    func testFloat64RoundTrip() {
        var data = Data()
        let values: [Double] = [0, 1, -123.25, 1e-300, 1e300, .infinity, -.infinity]
        for value in values { data.appendFloat64(value) }
        XCTAssertEqual(data.count, values.count * 8)
        for (index, value) in values.enumerated() {
            XCTAssertEqual(data.readFloat64(at: index * 8), value)
        }
    }

    func testFloat64PreservesNaNAndNegativeZero() {
        var data = Data()
        data.appendFloat64(.nan)
        data.appendFloat64(-0.0)
        XCTAssertTrue(data.readFloat64(at: 0).isNaN)
        let zero = data.readFloat64(at: 8)
        XCTAssertEqual(zero, 0)
        XCTAssertEqual(zero.sign, .minus)
    }

    func testFloat64IsLittleEndianLowWordFirst() {
        var data = Data()
        data.appendFloat64(1.0)   // 0x3FF0000000000000
        XCTAssertEqual(Array(data), [0, 0, 0, 0, 0, 0, 0xF0, 0x3F])
    }
}

final class TextFileWriterTests: XCTestCase {
    func testLinesAreWrittenWithNewlinesAfterClose() throws {
        let url = try makeTempFolder().appendingPathComponent("out.csv")
        let writer = try TextFileWriter(url: url)
        try writer.line("a,b")
        try writer.line("1,2")
        try writer.close()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a,b\n1,2\n")
    }

    func testFlushWritesBufferedLines() throws {
        let url = try makeTempFolder().appendingPathComponent("out.txt")
        let writer = try TextFileWriter(url: url)
        try writer.line("first")
        try writer.flush()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "first\n")
        try writer.line("second")
        try writer.close()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "first\nsecond\n")
    }

    func testLargeOutputIsFlushedInChunks() throws {
        let url = try makeTempFolder().appendingPathComponent("big.txt")
        let writer = try TextFileWriter(url: url)
        let line = String(repeating: "x", count: 999)
        for _ in 0..<1200 { try writer.line(line) }
        // More than 1 MB was buffered, so part of it must already be on disk before close().
        let before = try Data(contentsOf: url).count
        XCTAssertGreaterThan(before, 0)
        try writer.close()
        XCTAssertEqual(try Data(contentsOf: url).count, 1200 * 1000)
    }
}
