import XCTest

final class TopoGridFileTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try makeTempFolder()
    }

    private var fileURL: URL { folder.appendingPathComponent(TopoGridFile.fileName) }

    /// Writes a 4 × 3 grid whose cell (row r, column c) has mean 10·r + c and one reading,
    /// except the cells listed in `empty`, which have no readings.
    @discardableResult
    private func writeSample(columns: Int = 4, rows: Int = 3, heightMode: Bool = true, zRef: Float = 0,
                             empty: Set<Int> = []) throws -> [Float] {
        var means = [Float](repeating: 0, count: columns * rows)
        var hits = [UInt16](repeating: 1, count: columns * rows)
        for r in 0..<rows {
            for c in 0..<columns {
                means[r * columns + c] = Float(10 * r + c) - 5
                if empty.contains(r * columns + c) { hits[r * columns + c] = 0 }
            }
        }
        try TopoGridFile.write(to: fileURL, columns: columns, rows: rows, cell: 4.5, qMin: -123.25, xMin: -60.5,
                               heightMode: heightMode, zRef: zRef, means: means, hits: hits)
        return means
    }

    private func patch(at offset: Int, with bytes: Data) throws {
        var data = try Data(contentsOf: fileURL)
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        try data.write(to: fileURL)
    }

    private func patchUInt32(at offset: Int, _ value: UInt32) throws {
        var bytes = Data()
        bytes.appendUInt32(value)
        try patch(at: offset, with: bytes)
    }

    private func patchFloat64(at offset: Int, _ value: Double) throws {
        var bytes = Data()
        bytes.appendFloat64(value)
        try patch(at: offset, with: bytes)
    }

    // MARK: - Round trip

    func testRoundTripPreservesHeaderFieldsAndValues() throws {
        let means = try writeSample()
        let grid = try XCTUnwrap(TopoGridFile.load(from: folder))
        XCTAssertEqual(grid.columns, 4)
        XCTAssertEqual(grid.rows, 3)
        XCTAssertEqual(grid.cell, 4.5)
        XCTAssertEqual(grid.qMin, -123.25)
        XCTAssertEqual(grid.xMin, -60.5)
        XCTAssertTrue(grid.heightMode)
        XCTAssertEqual(grid.values, means)
    }

    func testValuesAreOffsetByTheReferenceDistance() throws {
        let means = try writeSample(heightMode: false, zRef: 1000)
        let grid = try XCTUnwrap(TopoGridFile.load(from: folder))
        XCTAssertFalse(grid.heightMode)
        XCTAssertEqual(grid.values, means.map { 1000 + $0 })
    }

    func testCellsWithoutReadingsComeBackAsNaN() throws {
        let means = try writeSample(empty: [0, 5, 11])
        let grid = try XCTUnwrap(TopoGridFile.load(from: folder))
        for i in 0..<12 {
            if [0, 5, 11].contains(i) {
                XCTAssertTrue(grid.values[i].isNaN, "cell \(i) should be NaN")
            } else {
                XCTAssertEqual(grid.values[i], means[i], "cell \(i)")
            }
        }
    }

    func testAnAllEmptyGridRoundTripsAsAllNaN() throws {
        try writeSample(empty: Set(0..<12))
        let grid = try XCTUnwrap(TopoGridFile.load(from: folder))
        XCTAssertEqual(grid.values.count, 12)
        XCTAssertTrue(grid.values.allSatisfy { $0.isNaN })
    }

    func testRowMajorLayoutIsRowsByColumns() throws {
        try writeSample(columns: 5, rows: 2)
        let grid = try XCTUnwrap(TopoGridFile.load(from: folder))
        XCTAssertEqual(grid.columns, 5)
        XCTAssertEqual(grid.rows, 2)
        // Cell (row 1, column 3): mean 10 · 1 + 3 − 5 = 8 at index row · columns + column.
        XCTAssertEqual(grid.values[1 * 5 + 3], 8)
    }

    // MARK: - File format

    func testFileLayoutMatchesTheDocumentedFormat() throws {
        try writeSample()
        let data = try Data(contentsOf: fileURL)
        XCTAssertEqual(TopoGridFile.headerSize, 48)
        XCTAssertEqual(data.count, 48 + 12 * 4)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "PLTG")
        XCTAssertEqual(data.readUInt32(at: 4), 1)          // version
        XCTAssertEqual(data.readUInt32(at: 8), 4)          // columns
        XCTAssertEqual(data.readUInt32(at: 12), 3)         // rows
        XCTAssertEqual(data.readFloat64(at: 16), 4.5)      // cell size
        XCTAssertEqual(data.readFloat64(at: 24), -123.25)  // qMin
        XCTAssertEqual(data.readFloat64(at: 32), -60.5)    // xMin
        XCTAssertEqual(data.readUInt32(at: 40), 1)         // height mode
        XCTAssertEqual(data.readUInt32(at: 44), 0)         // reserved
        // First value (row 0, column 0), little-endian Float32 right after the header.
        XCTAssertEqual(data.readUInt32(at: 48), Float(-5).bitPattern)
    }

    func testHeightModeFlagIsZeroForDistances() throws {
        try writeSample(heightMode: false, zRef: 900)
        let data = try Data(contentsOf: fileURL)
        XCTAssertEqual(data.readUInt32(at: 40), 0)
    }

    func testWriteReplacesAnExistingFile() throws {
        try writeSample(columns: 4, rows: 3)
        try writeSample(columns: 2, rows: 2)
        let grid = try XCTUnwrap(TopoGridFile.load(from: folder))
        XCTAssertEqual(grid.columns, 2)
        XCTAssertEqual(grid.rows, 2)
        XCTAssertEqual(try Data(contentsOf: fileURL).count, 48 + 4 * 4)
    }

    func testWriteSkipsEmptyOrInconsistentInput() throws {
        let url = fileURL
        try TopoGridFile.write(to: url, columns: 0, rows: 3, cell: 4, qMin: 0, xMin: 0, heightMode: true,
                               zRef: 0, means: [], hits: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // Fewer means / hit counts than columns × rows.
        try TopoGridFile.write(to: url, columns: 2, rows: 2, cell: 4, qMin: 0, xMin: 0, heightMode: true,
                               zRef: 0, means: [1, 2, 3], hits: [1, 1, 1, 1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try TopoGridFile.write(to: url, columns: 2, rows: 2, cell: 4, qMin: 0, xMin: 0, heightMode: true,
                               zRef: 0, means: [1, 2, 3, 4], hits: [1, 1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Rejection of bad files

    func testLoadRejectsAMissingFile() {
        XCTAssertNil(TopoGridFile.load(from: folder))
    }

    func testLoadRejectsAnEmptyFile() throws {
        try Data().write(to: fileURL)
        XCTAssertNil(TopoGridFile.load(from: folder))
    }

    func testLoadRejectsAFileShorterThanTheHeader() throws {
        try writeSample()
        let data = try Data(contentsOf: fileURL)
        try data.prefix(47).write(to: fileURL)
        XCTAssertNil(TopoGridFile.load(from: folder))
    }

    func testLoadRejectsAWrongMagic() throws {
        try writeSample()
        try patch(at: 0, with: Data("PLDP".utf8))
        XCTAssertNil(TopoGridFile.load(from: folder))
    }

    func testLoadRejectsATruncatedValueBlock() throws {
        try writeSample()
        let data = try Data(contentsOf: fileURL)
        try data.dropLast(1).write(to: fileURL)
        XCTAssertNil(TopoGridFile.load(from: folder))
        try data.prefix(48).write(to: fileURL)
        XCTAssertNil(TopoGridFile.load(from: folder))
    }

    func testLoadRejectsZeroDimensions() throws {
        try writeSample()
        try patchUInt32(at: 8, 0)
        XCTAssertNil(TopoGridFile.load(from: folder))
        try writeSample()
        try patchUInt32(at: 12, 0)
        XCTAssertNil(TopoGridFile.load(from: folder))
    }

    func testLoadRejectsDimensionsLargerThanTheData() throws {
        try writeSample()
        try patchUInt32(at: 8, 5)       // header now claims 5 × 3 = 15 values, the file holds 12
        XCTAssertNil(TopoGridFile.load(from: folder))
    }

    func testLoadRejectsInvalidCellSizeAndOrigins() throws {
        for (offset, value) in [(16, 0.0), (16, -1.0), (16, Double.nan), (16, Double.infinity),
                                (24, Double.nan), (24, Double.infinity), (32, Double.nan), (32, -Double.infinity)] {
            try writeSample()
            try patchFloat64(at: offset, value)
            XCTAssertNil(TopoGridFile.load(from: folder), "offset \(offset), value \(value)")
        }
    }

    func testLoadAcceptsTrailingBytes() throws {
        let means = try writeSample()
        var data = try Data(contentsOf: fileURL)
        data.append(contentsOf: [1, 2, 3])
        try data.write(to: fileURL)
        XCTAssertEqual(TopoGridFile.load(from: folder)?.values, means)
    }
}
