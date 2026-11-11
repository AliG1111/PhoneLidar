import XCTest

final class TopoGridFileTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try makeTempFolder()
    }

    private var fileURL: URL { folder.appendingPathComponent(TopoGridFile.fileName) }

    /// A grid whose cell (row r, column c) holds 10·r + c − 5 + `offset`, except the cells listed in `empty`,
    /// which hold NaN (no data).
    private func makeGrid(columns: Int = 4, rows: Int = 3, heightMode: Bool = true, offset: Float = 0,
                          empty: Set<Int> = []) -> TopoGridFile {
        var values = [Float](repeating: 0, count: columns * rows)
        for r in 0..<rows {
            for c in 0..<columns {
                values[r * columns + c] = empty.contains(r * columns + c) ? .nan : Float(10 * r + c) - 5 + offset
            }
        }
        return TopoGridFile(columns: columns, rows: rows, cell: 4.5, qMin: -123.25, xMin: -60.5,
                            heightMode: heightMode, values: values)
    }

    /// Writes `makeGrid(...)` to TopoGrid.bin and returns the values written.
    @discardableResult
    private func writeSample(columns: Int = 4, rows: Int = 3, heightMode: Bool = true, offset: Float = 0,
                             empty: Set<Int> = []) throws -> [Float] {
        let grid = makeGrid(columns: columns, rows: rows, heightMode: heightMode, offset: offset, empty: empty)
        try grid.write(to: fileURL)
        return grid.values
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

    func testDistanceModeGridKeepsItsAbsoluteValues() throws {
        let values = try writeSample(heightMode: false, offset: 1000)
        let grid = try XCTUnwrap(TopoGridFile.load(from: folder))
        XCTAssertFalse(grid.heightMode)
        XCTAssertEqual(grid.values, values)
        XCTAssertEqual(grid.values[0], 995)
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
        try writeSample(heightMode: false, offset: 900)
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

    func testWriteRefusesEmptyOrInconsistentGrids() {
        let url = fileURL
        let empty = TopoGridFile(columns: 0, rows: 3, cell: 4, qMin: 0, xMin: 0, heightMode: true, values: [])
        XCTAssertThrowsError(try empty.write(to: url)) { assertLineError($0, .badFile) }
        // Fewer values than columns × rows.
        let short = TopoGridFile(columns: 2, rows: 2, cell: 4, qMin: 0, xMin: 0, heightMode: true, values: [1, 2, 3])
        XCTAssertThrowsError(try short.write(to: url)) { assertLineError($0, .badFile) }
        let long = TopoGridFile(columns: 2, rows: 2, cell: 4, qMin: 0, xMin: 0, heightMode: true,
                                values: [1, 2, 3, 4, 5])
        XCTAssertThrowsError(try long.write(to: url)) { assertLineError($0, .badFile) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Version and size limits (B-9)

    func testFileIsWrittenAsVersionOne() throws {
        try writeSample()
        XCTAssertEqual(TopoGridFile.version, 1)
        XCTAssertEqual(try Data(contentsOf: fileURL).readUInt32(at: 4), 1)
    }

    func testLoadRejectsUnknownVersions() throws {
        for version: UInt32 in [0, 2, 0xFFFF_FFFF] {
            try writeSample()
            try patchUInt32(at: 4, version)
            XCTAssertNil(TopoGridFile.load(from: folder), "version \(version)")
        }
        try writeSample()
        XCTAssertNotNil(TopoGridFile.load(from: folder))
    }

    func testLoadRejectsAColumnTimesRowCountThatOverflows() throws {
        try writeSample()
        // 4294967295 × 4294967295 does not fit in Int: rejected instead of trapping.
        try patchUInt32(at: 8, 0xFFFF_FFFF)
        try patchUInt32(at: 12, 0xFFFF_FFFF)
        XCTAssertNil(TopoGridFile.load(from: folder))
    }

    func testLoadRejectsMoreThanTheMaximumCellCount() throws {
        XCTAssertEqual(TopoGridFile.maxCells, 3_000_000)
        try writeSample()
        // 3001 × 1000 = 3,001,000 cells is over the limit, whatever the file size says.
        try patchUInt32(at: 8, 3001)
        try patchUInt32(at: 12, 1000)
        XCTAssertNil(TopoGridFile.load(from: folder))
        // A header claiming a huge grid with no data behind it is rejected too.
        try patchUInt32(at: 8, 1_000_000)
        try patchUInt32(at: 12, 1_000_000)
        XCTAssertNil(TopoGridFile.load(from: folder))
    }

    func testGridOfExactlyTheMaximumCellCountRoundTrips() throws {
        let grid = TopoGridFile(columns: 3000, rows: 1000, cell: 10, qMin: 0, xMin: 0, heightMode: true,
                                values: [Float](repeating: 1.5, count: TopoGridFile.maxCells))
        try grid.write(to: fileURL)
        let loaded = try XCTUnwrap(TopoGridFile.load(from: folder))
        XCTAssertEqual(loaded.columns, 3000)
        XCTAssertEqual(loaded.rows, 1000)
        XCTAssertEqual(loaded.values.count, TopoGridFile.maxCells)
        XCTAssertEqual(loaded.values.last, 1.5)
    }

    func testWriteRefusesMoreThanTheMaximumCellCount() {
        let grid = TopoGridFile(columns: 3001, rows: 1000, cell: 10, qMin: 0, xMin: 0, heightMode: true,
                                values: [Float](repeating: 0, count: 3_001_000))
        XCTAssertThrowsError(try grid.write(to: fileURL)) { assertLineError($0, .badFile) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
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
