import XCTest

final class StorageModelTests: XCTestCase {
    func testScanKindMetadata() {
        XCTAssertEqual(ScanKind.allCases.count, 4)
        XCTAssertEqual(ScanKind.line.rawValue, "line")
        XCTAssertEqual(ScanKind.line.title, "Line scan (moving material)")
        XCTAssertEqual(ScanKind.room.title, "Room scan")
        for kind in ScanKind.allCases {
            XCTAssertFalse(kind.symbol.isEmpty)
            XCTAssertEqual(kind.id, kind.rawValue)
        }
    }

    func testScanErrorMessages() {
        XCTAssertEqual(ScanError.noData.errorDescription, "Nothing has been captured yet.")
        XCTAssertEqual(ScanError.cancelled.errorDescription, "Cancelled.")
        XCTAssertNotNil(ScanError.noMesh.errorDescription)
        XCTAssertNotNil(ScanError.unsupported.errorDescription)
    }

    func testScanRecordJSONRoundTrip() throws {
        let measurement = PointMeasurement(label: "Door, wide", start: [0, 1, 2], end: [3, 4, 5], meters: 2.5)
        let record = ScanRecord(id: UUID(), kind: .mesh, name: "Press", created: Date(timeIntervalSince1970: 1_700_000_000),
                                folderName: "mesh_2023-11-14_221320", primaryModel: "Mesh.usdz",
                                files: ["Mesh.obj", "Mesh.usdz"], summary: ["12 m²"], measurements: [measurement])
        let data = try JSONEncoder.pretty.encode(record)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"created\" : \"2023-11-14T22:13:20Z\""), json)
        XCTAssertTrue(json.contains("\"kind\" : \"mesh\""), json)
        let decoded = try JSONDecoder.iso.decode(ScanRecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }
}
