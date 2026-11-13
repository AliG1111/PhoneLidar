import XCTest

/// Laser line detection on synthetic luma images (design §14.3, FR-LAS-03).
final class LaserLineDetectorTests: XCTestCase {
    private let width = 100
    private let height = 120
    private var columns: LaserColumns { LaserColumns.make(width: width, stride: 2) }

    /// Luma image: `background` everywhere; each column u holds a Gaussian line of `sigma` px and `peak` grey levels
    /// centred on row `center(u)` (nil = no line in that column).
    private func makeImage(background: Double = 20, peak: Double = 150, sigma: Double = 2.5,
                           center: (Int) -> Double?) -> [UInt8] {
        var pixels = [UInt8](repeating: UInt8(background), count: width * height)
        for u in 0..<width {
            guard let c = center(u) else { continue }
            for v in 0..<height {
                let d = Double(v) - c
                let value = background + (peak - background) * exp(-d * d / (2 * sigma * sigma))
                pixels[v * width + u] = UInt8(min(255, max(0, value.rounded())))
            }
        }
        return pixels
    }

    /// A different sub-pixel row in every column, 40.00 … 40.99.
    private func subPixelCenter(_ u: Int) -> Double {
        40 + Double((u * 7) % 100) / 100
    }

    // MARK: - Columns

    func testColumnsAreEveryStrideColumnCentredInEachStep() {
        let c = LaserColumns.make(width: 10, stride: 4)
        XCTAssertEqual(c.first, 2)
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c.u(0), 2)
        XCTAssertEqual(c.u(1), 6)
        let one = LaserColumns.make(width: 7, stride: 1)
        XCTAssertEqual(one.first, 0)
        XCTAssertEqual(one.count, 7)
        XCTAssertEqual(LaserColumns.make(width: 7, stride: 0).stride, 1)
        XCTAssertEqual(LaserColumns.make(width: 7, stride: -3).stride, 1)
    }

    func testEveryColumnIsInsideTheBufferAndTheNextOneIsNot() {
        for stride in 1...5 {
            for width in 1...40 {
                let c = LaserColumns.make(width: width, stride: stride)
                if c.count > 0 {
                    XCTAssertLessThan(c.u(c.count - 1), width, "width \(width) stride \(stride)")
                }
                XCTAssertGreaterThanOrEqual(c.u(c.count), width, "width \(width) stride \(stride)")
            }
        }
    }

    func testBufferNarrowerThanTheFirstColumnHasNoColumns() {
        XCTAssertEqual(LaserColumns.make(width: 1, stride: 2).count, 0)
        XCTAssertEqual(LaserColumns.make(width: 0, stride: 2).count, 0)
        XCTAssertEqual(LaserColumns.make(width: 2, stride: 2).count, 1)
    }

    // MARK: - Sub-pixel centre

    func testGaussianLinesAreFoundWithinATwentiethOfAPixel() {
        let image = makeImage(center: subPixelCenter)
        let result = LaserLineDetector.detect(pixels: image, width: width, height: height, columns: columns)
        XCTAssertEqual(result.rows.count, columns.count)
        XCTAssertEqual(result.detected, columns.count)
        XCTAssertEqual(result.detectedFraction, 1, accuracy: 1e-12)
        for k in 0..<columns.count {
            XCTAssertEqual(Double(result.rows[k]), subPixelCenter(columns.u(k)), accuracy: 0.05, "column \(k)")
        }
    }

    func testNarrowLinesAreFoundWithinATenthOfAPixel() {
        // The half-height centre of gravity of a 1.5 px sigma line is biased by up to ~0.08 px.
        let image = makeImage(sigma: 1.5, center: subPixelCenter)
        let result = LaserLineDetector.detect(pixels: image, width: width, height: height, columns: columns)
        XCTAssertEqual(result.detected, columns.count)
        for k in 0..<columns.count {
            XCTAssertEqual(Double(result.rows[k]), subPixelCenter(columns.u(k)), accuracy: 0.1, "column \(k)")
        }
    }

    func testLineOnAnIntegerRowIsFoundExactly() {
        let image = makeImage(center: { _ in 60 })
        let result = LaserLineDetector.detect(pixels: image, width: width, height: height, columns: columns)
        for row in result.rows { XCTAssertEqual(row, 60, accuracy: 1e-3) }
    }

    func testSaturatedPlateauGivesItsCentre() {
        var pixels = [UInt8](repeating: 20, count: width * height)
        for u in 0..<width {
            for v in 38...42 { pixels[v * width + u] = 255 }
        }
        var result = LaserLineDetector.detect(pixels: pixels, width: width, height: height, columns: columns)
        XCTAssertEqual(result.detected, columns.count)
        for row in result.rows { XCTAssertEqual(row, 40, accuracy: 1e-4) }

        // An even plateau (rows 38…41) is centred between its two middle rows.
        for u in 0..<width { pixels[42 * width + u] = 20 }
        result = LaserLineDetector.detect(pixels: pixels, width: width, height: height, columns: columns)
        for row in result.rows { XCTAssertEqual(row, 39.5, accuracy: 1e-4) }
    }

    // MARK: - Contrast

    func testPeakLessThanThirtyLevelsAboveTheBackgroundIsNotALine() {
        // Integer centre: the brightest pixel is exactly `peak`; the background is 20.
        let weak = makeImage(peak: 49, center: { _ in 40 })
        var result = LaserLineDetector.detect(pixels: weak, width: width, height: height, columns: columns)
        XCTAssertEqual(result.detected, 0)
        XCTAssertTrue(result.rows.allSatisfy { $0.isNaN })
        XCTAssertEqual(result.detectedFraction, 0)

        let enough = makeImage(peak: 50, center: { _ in 40 })
        result = LaserLineDetector.detect(pixels: enough, width: width, height: height, columns: columns)
        XCTAssertEqual(result.detected, columns.count)
        for row in result.rows { XCTAssertEqual(row, 40, accuracy: 0.05) }
    }

    func testMinimumContrastCanBeChanged() {
        let weak = makeImage(peak: 49, center: { _ in 40 })
        let result = LaserLineDetector.detect(pixels: weak, width: width, height: height, columns: columns,
                                              minContrast: 10)
        XCTAssertEqual(result.detected, columns.count)
        let strict = makeImage(peak: 150, center: { _ in 40 })
        XCTAssertEqual(LaserLineDetector.detect(pixels: strict, width: width, height: height, columns: columns,
                                                minContrast: 131).detected, 0)
    }

    func testAFlatImageHasNoLine() {
        let flat = [UInt8](repeating: 77, count: width * height)
        let result = LaserLineDetector.detect(pixels: flat, width: width, height: height, columns: columns)
        XCTAssertEqual(result.detected, 0)
        XCTAssertTrue(result.rows.allSatisfy { $0.isNaN })
    }

    // MARK: - Detected count

    func testColumnsWithoutALineAreNaNAndNotCounted() {
        let image = makeImage(center: { u in u < 50 ? nil : 40 })
        let result = LaserLineDetector.detect(pixels: image, width: width, height: height, columns: columns)
        XCTAssertEqual(result.detected, 25)     // columns u = 51, 53 … 99
        XCTAssertEqual(result.detectedFraction, 0.5, accuracy: 1e-12)
        for k in 0..<columns.count {
            XCTAssertEqual(result.rows[k].isNaN, columns.u(k) < 50, "column \(k)")
        }
    }

    func testColumnsBeyondTheBufferStayNaN() {
        let wide = LaserColumns(first: 1, stride: 2, count: 80)    // u up to 159, the image has 100 columns
        let image = makeImage(center: { _ in 40 })
        let result = LaserLineDetector.detect(pixels: image, width: width, height: height, columns: wide)
        XCTAssertEqual(result.rows.count, 80)
        XCTAssertEqual(result.detected, 50)
        XCTAssertTrue(result.rows[50...].allSatisfy { $0.isNaN })
    }

    // MARK: - Search band

    func testOnlyRowsInsideTheBandAreSearched() {
        // A weaker line at row 40 and a brighter one at row 90 in every column.
        var pixels = makeImage(peak: 150, center: { _ in 40 })
        let bright = makeImage(peak: 200, center: { _ in 90 })
        for i in 0..<pixels.count { pixels[i] = max(pixels[i], bright[i]) }

        var result = LaserLineDetector.detect(pixels: pixels, width: width, height: height, columns: columns)
        for row in result.rows { XCTAssertEqual(row, 90, accuracy: 0.05) }

        result = LaserLineDetector.detect(pixels: pixels, width: width, height: height, columns: columns,
                                          rowLo: 0, rowHi: 60)
        for row in result.rows { XCTAssertEqual(row, 40, accuracy: 0.05) }

        result = LaserLineDetector.detect(pixels: pixels, width: width, height: height, columns: columns,
                                          rowLo: 60, rowHi: 120)
        for row in result.rows { XCTAssertEqual(row, 90, accuracy: 0.05) }

        // Neither line in the band: only background there.
        result = LaserLineDetector.detect(pixels: pixels, width: width, height: height, columns: columns,
                                          rowLo: 105, rowHi: 120)
        XCTAssertEqual(result.detected, 0)
    }

    func testBandIsClampedToTheImageAndNeedsThreeRows() {
        let image = makeImage(center: { _ in 40 })
        let clamped = LaserLineDetector.detect(pixels: image, width: width, height: height, columns: columns,
                                               rowLo: -50, rowHi: 5000)
        XCTAssertEqual(clamped.detected, columns.count)
        let tooThin = LaserLineDetector.detect(pixels: image, width: width, height: height, columns: columns,
                                               rowLo: 39, rowHi: 41)
        XCTAssertEqual(tooThin.detected, 0)
        let empty = LaserLineDetector.detect(pixels: image, width: width, height: height, columns: columns,
                                             rowLo: 80, rowHi: 40)
        XCTAssertEqual(empty.detected, 0)
    }

    // MARK: - Buffers

    func testRowPaddingIsNotRead() {
        let image = makeImage(center: subPixelCenter)
        let rowBytes = 128
        var padded = [UInt8](repeating: 255, count: rowBytes * height)     // padding stays bright
        for v in 0..<height {
            for u in 0..<width { padded[v * rowBytes + u] = image[v * width + u] }
        }
        let reference = LaserLineDetector.detect(pixels: image, width: width, height: height, columns: columns)
        let result = padded.withUnsafeBufferPointer { buffer in
            LaserLineDetector.detect(luma: buffer.baseAddress!, width: width, height: height, rowBytes: rowBytes,
                                     columns: columns, rowLo: 0, rowHi: height)
        }
        XCTAssertEqual(result.detected, reference.detected)
        XCTAssertEqual(result.rows, reference.rows)
    }

    func testRowBytesSmallerThanTheWidthFindsNothing() {
        let image = makeImage(center: { _ in 40 })
        let result = image.withUnsafeBufferPointer { buffer in
            LaserLineDetector.detect(luma: buffer.baseAddress!, width: width, height: height, rowBytes: width - 1,
                                     columns: columns, rowLo: 0, rowHi: height)
        }
        XCTAssertEqual(result.detected, 0)
        XCTAssertEqual(result.rows.count, columns.count)
    }

    func testTooSmallOrEmptyImagesFindNothing() {
        let image = makeImage(center: { _ in 40 })
        var result = LaserLineDetector.detect(pixels: Array(image.dropLast()), width: width, height: height,
                                              columns: columns)
        XCTAssertEqual(result.detected, 0)
        XCTAssertEqual(result.rows.count, columns.count)
        XCTAssertTrue(result.rows.allSatisfy { $0.isNaN })
        result = LaserLineDetector.detect(pixels: [], width: 0, height: 0, columns: columns)
        XCTAssertEqual(result.detected, 0)
        XCTAssertEqual(result.detectedFraction, 0)
        let none = LaserLineDetector.detect(pixels: image, width: width, height: height,
                                            columns: LaserColumns(first: 0, stride: 1, count: 0))
        XCTAssertTrue(none.rows.isEmpty)
        XCTAssertEqual(none.detectedFraction, 0)
    }
}
