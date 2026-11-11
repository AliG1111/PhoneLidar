import Foundation
import XCTest

extension XCTestCase {
    /// A fresh empty folder in the temporary directory, removed when the test finishes.
    func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneLidarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// Fails the test unless `error` is the given `LineError` (which has no `Equatable` conformance).
func assertLineError(_ error: Error, _ expected: LineError, file: StaticString = #filePath, line: UInt = #line) {
    guard let lineError = error as? LineError else {
        XCTFail("Expected a LineError, got \(error)", file: file, line: line)
        return
    }
    XCTAssertEqual(lineError.errorDescription, expected.errorDescription, file: file, line: line)
}

/// A recorded-frame description with sensible defaults for tests that only care about a few fields.
func makeFrame(index: Int = 0, time: Double = 0, speed: Double? = nil, travel: Double = 0,
               medianDepth: Double = 1000, fx: Float = 100, fy: Float = 100,
               cx: Float = 32, cy: Float = 24) -> LineFrameInfo {
    LineFrameInfo(index: index, time: time, speed: speed, travel: travel, shiftPixels: nil,
                  crossShiftPixels: nil, quality: 1, medianDepth: medianDepth,
                  fx: fx, fy: fy, cx: cx, cy: cy)
}
