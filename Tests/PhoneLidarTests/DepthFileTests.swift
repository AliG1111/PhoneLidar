import XCTest

final class DepthFileTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try makeTempFolder()
    }

    private var depthURL: URL { folder.appendingPathComponent("Depth.bin") }

    private func write(width: Int, height: Int, frames: [[Float]]) throws {
        let writer = try DepthFileWriter(url: depthURL, width: width, height: height)
        for frame in frames {
            try writer.append(millimetres: frame)
        }
        writer.close()
    }

    private func gradientFrame(width: Int, height: Int, offset: Float) -> [Float] {
        (0..<(width * height)).map { 500 + offset + Float($0) * 0.7 }
    }

    // MARK: - Round trip

    func testRoundTripKeepsFramesWithinHalfAMillimetreTenth() throws {
        let frames = (0..<3).map { gradientFrame(width: 8, height: 6, offset: Float($0) * 100) }
        try write(width: 8, height: 6, frames: frames)
        let reader = try DepthFileReader(url: depthURL)
        XCTAssertEqual(reader.width, 8)
        XCTAssertEqual(reader.height, 6)
        XCTAssertEqual(reader.frameCount, 3)
        for (index, original) in frames.enumerated() {
            let decoded = try XCTUnwrap(reader.frame(index))
            XCTAssertEqual(decoded.count, original.count)
            for i in original.indices {
                XCTAssertEqual(decoded[i], original[i], accuracy: 0.0501, "frame \(index) pixel \(i)")
            }
        }
    }

    func testDistancesAreStoredInTenthsOfAMillimetre() throws {
        try write(width: 4, height: 4, frames: [[Float](repeating: 1234.5, count: 16)])
        let reader = try DepthFileReader(url: depthURL)
        XCTAssertEqual(try XCTUnwrap(reader.frame(0))[0], 1234.5, accuracy: 0.0001)
        // The raw payload holds UInt16 values of 12345 (= 1234.5 mm / 0.1 mm).
        let data = try Data(contentsOf: depthURL)
        let length = Int(data.readUInt32(at: 16))
        let compressed = data.subdata(in: 20..<(20 + length))
        let raw = try (compressed as NSData).decompressed(using: .lzfse) as Data
        XCTAssertEqual(raw.count, 16 * 2)
        XCTAssertEqual(UInt16(raw[0]) | (UInt16(raw[1]) << 8), 12345)
    }

    func testValuesRoundToTheNearestTenthOfAMillimetre() throws {
        let inputs: [Float] = [100.04, 100.06, 250.0, 0.06, 6499.9]
        try write(width: 5, height: 1, frames: [inputs])
        let decoded = try XCTUnwrap(DepthFileReader(url: depthURL).frame(0))
        XCTAssertEqual(decoded[0], 100.0, accuracy: 0.0001)
        XCTAssertEqual(decoded[1], 100.1, accuracy: 0.0001)
        XCTAssertEqual(decoded[2], 250.0, accuracy: 0.0001)
        XCTAssertEqual(decoded[3], 0.1, accuracy: 0.0001)
        XCTAssertEqual(decoded[4], 6499.9, accuracy: 0.001)
    }

    func testZeroMeansNoData() throws {
        let frame: [Float] = [0, 800, 0, 801.5, 0, 0]
        try write(width: 3, height: 2, frames: [frame])
        let decoded = try XCTUnwrap(DepthFileReader(url: depthURL).frame(0))
        XCTAssertEqual(decoded[0], 0)
        XCTAssertEqual(decoded[2], 0)
        XCTAssertEqual(decoded[4], 0)
        XCTAssertEqual(decoded[5], 0)
        XCTAssertEqual(decoded[1], 800, accuracy: 0.0501)
        XCTAssertEqual(decoded[3], 801.5, accuracy: 0.0501)
    }

    func testInvalidInputsAreStoredAsNoData() throws {
        // Negative, NaN, infinite, below 0.05 mm (rounds to zero) and at or beyond the 6500 mm limit.
        let frame: [Float] = [-5, .nan, .infinity, 0.04, 6500, 7000, 900]
        try write(width: 7, height: 1, frames: [frame])
        let decoded = try XCTUnwrap(DepthFileReader(url: depthURL).frame(0))
        XCTAssertEqual(Array(decoded.prefix(6)), [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(decoded[6], 900, accuracy: 0.0501)
    }

    func testAllNoDataFrameRoundTripsToZeros() throws {
        try write(width: 6, height: 5, frames: [[Float](repeating: 0, count: 30)])
        let decoded = try XCTUnwrap(DepthFileReader(url: depthURL).frame(0))
        XCTAssertEqual(decoded, [Float](repeating: 0, count: 30))
    }

    // MARK: - File layout

    func testHeaderLayout() throws {
        try write(width: 8, height: 6, frames: [gradientFrame(width: 8, height: 6, offset: 0)])
        let data = try Data(contentsOf: depthURL)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "PLDP")
        XCTAssertEqual(data.readUInt32(at: 4), 1)     // version
        XCTAssertEqual(data.readUInt32(at: 8), 8)     // width
        XCTAssertEqual(data.readUInt32(at: 12), 6)    // height
        // One frame: UInt32 byte count, then exactly that many compressed bytes.
        let length = Int(data.readUInt32(at: 16))
        XCTAssertEqual(data.count, 20 + length)
    }

    func testConstantFramesCompress() throws {
        let frame = [Float](repeating: 1000, count: 64 * 48)
        try write(width: 64, height: 48, frames: [frame, frame, frame])
        let size = try Data(contentsOf: depthURL).count
        XCTAssertLessThan(size, 3 * 64 * 48 * 2 / 4)
    }

    func testEmptyFileHasNoFrames() throws {
        try write(width: 8, height: 6, frames: [])
        let reader = try DepthFileReader(url: depthURL)
        XCTAssertEqual(reader.frameCount, 0)
        XCTAssertNil(reader.frame(0))
    }

    func testFramesCanBeReadOutOfOrderAndOutOfRangeIsNil() throws {
        let frames = (0..<4).map { [Float](repeating: 300 + Float($0) * 50, count: 12) }
        try write(width: 4, height: 3, frames: frames)
        let reader = try DepthFileReader(url: depthURL)
        XCTAssertEqual(try XCTUnwrap(reader.frame(3))[0], 450, accuracy: 0.0501)
        XCTAssertEqual(try XCTUnwrap(reader.frame(0))[0], 300, accuracy: 0.0501)
        XCTAssertEqual(try XCTUnwrap(reader.frame(2))[11], 400, accuracy: 0.0501)
        XCTAssertNil(reader.frame(-1))
        XCTAssertNil(reader.frame(4))
    }

    func testAnIncompleteLastFrameIsIgnored() throws {
        let frames = (0..<3).map { [Float](repeating: 500 + Float($0), count: 64 * 48) }
        try write(width: 64, height: 48, frames: frames)
        let data = try Data(contentsOf: depthURL)
        try data.dropLast(5).write(to: depthURL)
        let reader = try DepthFileReader(url: depthURL)
        XCTAssertEqual(reader.frameCount, 2)
        XCTAssertEqual(try XCTUnwrap(reader.frame(1))[0], 501, accuracy: 0.0501)
        XCTAssertNil(reader.frame(2))
    }

    // MARK: - Bad files

    func testReaderRejectsAMissingFile() {
        XCTAssertThrowsError(try DepthFileReader(url: depthURL))
    }

    func testReaderRejectsAShortFile() throws {
        try Data("PLDP".utf8).write(to: depthURL)
        XCTAssertThrowsError(try DepthFileReader(url: depthURL)) { assertLineError($0, .badFile) }
    }

    func testReaderRejectsAWrongMagic() throws {
        try write(width: 8, height: 6, frames: [gradientFrame(width: 8, height: 6, offset: 0)])
        var data = try Data(contentsOf: depthURL)
        data.replaceSubrange(0..<4, with: Data("XXXX".utf8))
        try data.write(to: depthURL)
        XCTAssertThrowsError(try DepthFileReader(url: depthURL)) { assertLineError($0, .badFile) }
    }

    func testReaderRejectsZeroDimensions() throws {
        var header = Data("PLDP".utf8)
        header.appendUInt32(1)
        header.appendUInt32(0)
        header.appendUInt32(6)
        try header.write(to: depthURL)
        XCTAssertThrowsError(try DepthFileReader(url: depthURL)) { assertLineError($0, .badFile) }
    }

    func testFrameWithCorruptPayloadDecodesToNil() throws {
        try write(width: 8, height: 6, frames: [gradientFrame(width: 8, height: 6, offset: 0)])
        var data = try Data(contentsOf: depthURL)
        let length = Int(data.readUInt32(at: 16))
        data.replaceSubrange(20..<(20 + length), with: [UInt8](repeating: 0xFF, count: length))
        try data.write(to: depthURL)
        let reader = try DepthFileReader(url: depthURL)
        XCTAssertEqual(reader.frameCount, 1)
        XCTAssertNil(reader.frame(0))
    }

    // MARK: - Window median

    private func windowFrame() -> [Float] {
        // 5 × 5, row-major; zeros are missing pixels.
        [0, 0, 0, 0, 0,
         0, 10, 20, 30, 0,
         0, 40, 0, 60, 0,
         0, 70, 80, 90, 0,
         0, 0, 0, 0, 0]
    }

    func testStaticSampleIsTheMedianOfValidPixelsInTheWindow() {
        // Eight valid pixels around the centre: 10, 20, 30, 40, 60, 70, 80, 90 -> element 4 of the sorted list.
        let median = DepthFileReader.sample(windowFrame(), width: 5, height: 5, u: 2, v: 2, radius: 1)
        XCTAssertEqual(median, 60)
    }

    func testStaticSampleWithRadiusZeroReadsOnePixel() {
        XCTAssertEqual(DepthFileReader.sample(windowFrame(), width: 5, height: 5, u: 1, v: 1, radius: 0), 10)
        XCTAssertNil(DepthFileReader.sample(windowFrame(), width: 5, height: 5, u: 2, v: 2, radius: 0))
    }

    func testStaticSampleIsNilWithoutValidPixelsOrOutsideTheFrame() {
        XCTAssertNil(DepthFileReader.sample(windowFrame(), width: 5, height: 5, u: 0, v: 0, radius: 0))
        XCTAssertNil(DepthFileReader.sample(windowFrame(), width: 5, height: 5, u: -1, v: 2, radius: 1))
        XCTAssertNil(DepthFileReader.sample(windowFrame(), width: 5, height: 5, u: 2, v: 5, radius: 1))
        XCTAssertNil(DepthFileReader.sample([1, 2, 3], width: 5, height: 5, u: 2, v: 2, radius: 1))
    }

    func testStaticSampleWindowIsClippedAtTheFrameEdge() {
        // Corner window covers (0,0), (1,0), (0,1), (1,1): only 10 is valid.
        XCTAssertEqual(DepthFileReader.sample(windowFrame(), width: 5, height: 5, u: 0, v: 0, radius: 1), 10)
    }

    func testReaderSampleMatchesTheStaticSampleOnTheDecodedFrame() throws {
        try write(width: 5, height: 5, frames: [windowFrame()])
        let reader = try DepthFileReader(url: depthURL)
        XCTAssertEqual(try XCTUnwrap(reader.sample(0, u: 2, v: 2, radius: 1)), 60, accuracy: 0.0501)
        XCTAssertEqual(try XCTUnwrap(reader.sample(0, u: 1, v: 1, radius: 0)), 10, accuracy: 0.0501)
        XCTAssertEqual(try XCTUnwrap(reader.sample(0, u: 0, v: 0, radius: 1)), 10, accuracy: 0.0501)
        XCTAssertNil(reader.sample(0, u: 2, v: 2, radius: 0))
        XCTAssertNil(reader.sample(0, u: 9, v: 2, radius: 1))
        XCTAssertNil(reader.sample(1, u: 2, v: 2, radius: 1))
    }
}
