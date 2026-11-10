import XCTest

final class DepthColorsTests: XCTestCase {
    func testJetPaletteEndpointsAndMiddle() {
        XCTAssertTrue(DepthColors.rgb(0) == (0, 0, 127))        // dark blue = far
        XCTAssertTrue(DepthColors.rgb(0.5) == (127, 255, 127))
        XCTAssertTrue(DepthColors.rgb(1) == (127, 0, 0))        // dark red = near
        XCTAssertTrue(DepthColors.rgb(-3) == DepthColors.rgb(0))
        XCTAssertTrue(DepthColors.rgb(9) == DepthColors.rgb(1))
        XCTAssertEqual(DepthColors.lut.count, 256)
    }

    func testDistanceIndexRunsFromFarToNear() {
        XCTAssertEqual(DepthColors.index(distance: 500, near: 500, far: 1500), 255)
        XCTAssertEqual(DepthColors.index(distance: 1500, near: 500, far: 1500), 0)
        XCTAssertEqual(DepthColors.index(distance: 1000, near: 500, far: 1500), 127)
        XCTAssertEqual(DepthColors.index(distance: 100, near: 500, far: 1500), 255)
        XCTAssertEqual(DepthColors.index(distance: 9000, near: 500, far: 1500), 0)
    }

    func testValueIndexRunsFromLowToHigh() {
        XCTAssertEqual(DepthColors.index(value: 0, low: 0, high: 10), 0)
        XCTAssertEqual(DepthColors.index(value: 10, low: 0, high: 10), 255)
        XCTAssertEqual(DepthColors.index(value: -5, low: 0, high: 10), 0)
        XCTAssertEqual(DepthColors.index(value: 99, low: 0, high: 10), 255)
        XCTAssertEqual(DepthColors.index(value: 5, low: 5, high: 5), 0)      // zero span does not divide by zero
    }

    func testFiniteRangeUsesPercentilesAndIgnoresNaN() {
        var values = (0..<100).map { Float($0) }
        values.append(.nan)
        let range = values.withUnsafeBufferPointer { DepthColors.finiteRange($0) }
        XCTAssertEqual(range, 1...97)
    }

    func testFiniteRangeNeedsSixteenSamplesAndHasAMinimumSpan() {
        let few = [Float](repeating: 1, count: 15)
        XCTAssertNil(few.withUnsafeBufferPointer { DepthColors.finiteRange($0) })
        let flat = [Float](repeating: -2, count: 20)
        XCTAssertEqual(flat.withUnsafeBufferPointer { DepthColors.finiteRange($0) }, -2...(-1.5))
    }

    func testPercentileRangeIgnoresNonPositiveValues() {
        var values = [Float](repeating: 0, count: 50)
        values += (0..<100).map { 1000 + Float($0) }
        values.append(.nan)
        let range = values.withUnsafeBufferPointer { DepthColors.percentileRange($0) }
        XCTAssertEqual(range, 1001...1097)
        let flat = [Float](repeating: 800, count: 20)
        XCTAssertEqual(flat.withUnsafeBufferPointer { DepthColors.percentileRange($0) }, 800...801)
    }

    func testImagesHaveTheRequestedSizeOrAreNil() {
        let values: [Float] = [.nan, 5, 0, 10, 3, 7]
        values.withUnsafeBufferPointer { buffer in
            let image = DepthColors.heightImage(buffer, width: 3, height: 2, low: 0, high: 10)
            XCTAssertEqual(image?.width, 3)
            XCTAssertEqual(image?.height, 2)
            XCTAssertNil(DepthColors.heightImage(buffer, width: 4, height: 2, low: 0, high: 10))
            XCTAssertNil(DepthColors.heightImage(buffer, width: 0, height: 2, low: 0, high: 10))
            XCTAssertEqual(DepthColors.image(millimetres: buffer, width: 3, height: 2, near: 1, far: 9)?.width, 3)
            XCTAssertNil(DepthColors.image(millimetres: buffer, width: 5, height: 2, near: 1, far: 9))
        }
    }
}
