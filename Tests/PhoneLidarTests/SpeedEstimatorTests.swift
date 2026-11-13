import CoreVideo
import XCTest

final class SpeedEstimatorTests: XCTestCase {
    private let width = 960
    private let height = 720

    /// Smooth, non-repeating synthetic texture (sum of incommensurate sinusoids), 0…255.
    private static let waves: [(kx: Double, ky: Double, phase: Double)] =
        [310.0, 190, 130, 97, 71, 53, 43, 37].enumerated().map { k, wavelength in
            let angle = Double(k) * 0.7 + 0.3
            let f = 2 * Double.pi / wavelength
            return (f * cos(angle), f * sin(angle), Double(k) * 1.3)
        }

    private func texture(_ x: Double, _ y: Double) -> UInt8 {
        var sum = 0.0
        for wave in Self.waves {
            sum += sin(x * wave.kx + y * wave.ky + wave.phase) / 8
        }
        return UInt8(max(0, min(255, 128 + 220 * sum)))
    }

    /// Buffer holding the texture moved by (`along` rows, `across` columns); rows run along the travel.
    private func makeBuffer(format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            width: Int? = nil, height: Int? = nil, along: Double = 0, across: Double = 0,
                            flat: Bool = false) throws -> CVPixelBuffer {
        let w = width ?? self.width
        let h = height ?? self.height
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, w, h, format, nil, &created), kCVReturnSuccess)
        let buffer = try XCTUnwrap(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        for y in 0..<h {
            for x in 0..<w {
                let value: UInt8 = flat ? 100 : texture(Double(x) - across, Double(y) - along)
                if tenBit {
                    let row = (base + y * stride).assumingMemoryBound(to: UInt16.self)
                    row[x] = UInt16(value) << 8
                } else {
                    let row = (base + y * stride).assumingMemoryBound(to: UInt8.self)
                    row[x] = value
                }
            }
        }
        return buffer
    }

    /// First frame returns nil; the second returns the shift between them.
    private func estimate(_ estimator: SpeedEstimator, along: Double, across: Double = 0,
                          format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) throws -> TextureShift {
        let sign = Double(estimator.travelSign)
        XCTAssertNil(estimator.process(try makeBuffer(format: format)))
        // Material moving in the travel direction by `along` pixels: current(y) = previous(y − sign · along).
        return try XCTUnwrap(estimator.process(try makeBuffer(format: format, along: sign * along, across: across)))
    }

    // MARK: - Whole-picture shift

    func testIdenticalFramesGiveZeroShiftAndHighQuality() throws {
        let shift = try estimate(SpeedEstimator(), along: 0)
        XCTAssertEqual(shift.along, 0, accuracy: 0.5)
        XCTAssertEqual(shift.across, 0, accuracy: 0.5)
        XCTAssertGreaterThan(shift.quality, 0.5)
    }

    /// Whole-pixel shifts land on the half-scale grid, so the estimate is essentially exact.
    private let wholePixelTolerance = 0.15
    /// Fractional shifts go through parabolic refinement of a SAD cost at half scale (2 px per step). A port of the
    /// estimator run on this texture showed a worst case of about 0.20 px; 0.3 px keeps margin for rounding
    /// differences while still failing an estimator without sub-pixel refinement (error up to 1 px) or with a flipped sign.
    private let fractionalTolerance = 0.3

    func testKnownShiftAlongTheTravelIsRecovered() throws {
        for pixels in [8.0, 24.0, 40.0, 100.0] {
            let shift = try estimate(SpeedEstimator(), along: pixels)
            XCTAssertEqual(shift.along, pixels, accuracy: wholePixelTolerance, "shift \(pixels)")
            XCTAssertEqual(shift.across, 0, accuracy: wholePixelTolerance, "shift \(pixels)")
            XCTAssertGreaterThan(shift.quality, 0.5, "shift \(pixels)")
        }
    }

    func testSubPixelShiftIsRecovered() throws {
        for pixels in [23.25, 23.5, 23.75, 24.25, 24.5, 24.75, 40.3, 100.5] {
            let shift = try estimate(SpeedEstimator(), along: pixels)
            XCTAssertEqual(shift.along, pixels, accuracy: fractionalTolerance, "shift \(pixels)")
            XCTAssertEqual(shift.across, 0, accuracy: fractionalTolerance, "shift \(pixels)")
        }
    }

    func testSubPixelShiftIsRecoveredInTheOtherTravelDirection() throws {
        for pixels in [23.5, 24.25, 40.5] {
            let estimator = SpeedEstimator()
            estimator.travelSign = -1
            let shift = try estimate(estimator, along: pixels)
            XCTAssertEqual(shift.along, pixels, accuracy: fractionalTolerance, "shift \(pixels)")
        }
    }

    func testFractionalShiftAcrossAndAlongIsRecovered() throws {
        for (along, across) in [(12.5, 3.25), (30.75, -5.5), (24.5, 8.5)] {
            let shift = try estimate(SpeedEstimator(), along: along, across: across)
            XCTAssertEqual(shift.along, along, accuracy: fractionalTolerance, "along \(along)")
            XCTAssertEqual(shift.across, across, accuracy: fractionalTolerance, "across \(across)")
        }
    }

    func testShiftAcrossTheTravelIsRecovered() throws {
        let shift = try estimate(SpeedEstimator(), along: 24, across: 8)
        XCTAssertEqual(shift.along, 24, accuracy: wholePixelTolerance)
        XCTAssertEqual(shift.across, 8, accuracy: wholePixelTolerance)
    }

    func testOppositeTravelDirectionGivesTheSameSignedShift() throws {
        let estimator = SpeedEstimator()
        estimator.travelSign = -1
        let shift = try estimate(estimator, along: 24)
        XCTAssertEqual(shift.along, 24, accuracy: wholePixelTolerance)
    }

    func testMotionInTheOtherDirectionIsNegative() throws {
        let shift = try estimate(SpeedEstimator(), along: -16)
        XCTAssertEqual(shift.along, -16, accuracy: wholePixelTolerance)
    }

    // MARK: - Searching both ways (automatic direction, design §6.16)

    func testSearchingBothWaysMeasuresFastMovementAgainstTheTravelSign() throws {
        // 100 px against the sign is far past the one-way search's 48 px backward range.
        for travelSign in [1, -1] {
            for pixels in [-100.0, -40.5, -8.0] {
                let estimator = SpeedEstimator()
                estimator.travelSign = travelSign
                estimator.searchesBothWays = true
                let shift = try estimate(estimator, along: pixels)
                XCTAssertEqual(shift.along, pixels, accuracy: fractionalTolerance, "sign \(travelSign), \(pixels)")
                XCTAssertGreaterThan(shift.quality, 0.5, "sign \(travelSign), \(pixels)")
            }
        }
    }

    func testSearchingBothWaysStillMeasuresMovementWithTheTravelSign() throws {
        for travelSign in [1, -1] {
            for pixels in [0.0, 8.0, 24.5, 100.0, 200.0] {
                let estimator = SpeedEstimator()
                estimator.travelSign = travelSign
                estimator.searchesBothWays = true
                let shift = try estimate(estimator, along: pixels, across: 3)
                XCTAssertEqual(shift.along, pixels, accuracy: fractionalTolerance, "sign \(travelSign), \(pixels)")
                XCTAssertEqual(shift.across, 3, accuracy: fractionalTolerance, "sign \(travelSign), \(pixels)")
            }
        }
    }

    func testSwitchingTheSearchModeNeedsNoReset() throws {
        let estimator = SpeedEstimator()
        estimator.searchesBothWays = true
        XCTAssertNil(estimator.process(try makeBuffer()))
        let first = try XCTUnwrap(estimator.process(try makeBuffer(along: 24)))
        XCTAssertEqual(first.along, 24, accuracy: wholePixelTolerance)
        // One-way search on the next frame compares with the frame just processed.
        estimator.searchesBothWays = false
        let second = try XCTUnwrap(estimator.process(try makeBuffer(along: 48)))
        XCTAssertEqual(second.along, 24, accuracy: wholePixelTolerance)
    }

    func testSearchingBothWaysDoesNotChangeTheZones() throws {
        let estimator = SpeedEstimator()
        estimator.searchesBothWays = true
        _ = try estimate(estimator, along: 24)
        XCTAssertEqual(estimator.lastTiles.count, SpeedEstimator.tileColumns * SpeedEstimator.tileRows)
        let tiles = estimator.lastTiles.compactMap { $0 }
        XCTAssertGreaterThanOrEqual(tiles.count, 20)
        for tile in tiles {
            XCTAssertEqual(tile.along, 24, accuracy: 1.5)
        }
    }

    func testSearchingBothWaysOnAShortCropStillWorks() throws {
        // Laser mode: the smallest crop (216 rows) leaves 6 coarse steps each way (48 px).
        let estimator = SpeedEstimator()
        estimator.searchesBothWays = true
        let rows = 0..<SpeedEstimator.minimumTrackingRows
        XCTAssertNil(estimator.process(try makeBuffer(), rows: rows, zones: false))
        let back = try XCTUnwrap(estimator.process(try makeBuffer(along: -20), rows: rows, zones: false))
        XCTAssertEqual(back.along, -20, accuracy: fractionalTolerance)
        let forward = try XCTUnwrap(estimator.process(try makeBuffer(along: 0), rows: rows, zones: false))
        XCTAssertEqual(forward.along, 20, accuracy: fractionalTolerance)
    }

    func testTenBitBuffersGiveTheSameShift() throws {
        let shift = try estimate(SpeedEstimator(), along: 24, format: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        XCTAssertEqual(shift.along, 24, accuracy: wholePixelTolerance)
    }

    func testTrackedRegionStaysInsideTheNormalizedPicture() throws {
        let shift = try estimate(SpeedEstimator(), along: 24)
        XCTAssertGreaterThanOrEqual(shift.regionX.lowerBound, 0)
        XCTAssertLessThanOrEqual(shift.regionX.upperBound, 1)
        XCTAssertGreaterThanOrEqual(shift.regionY.lowerBound, 0)
        XCTAssertLessThanOrEqual(shift.regionY.upperBound, 1)
        XCTAssertGreaterThan(shift.regionY.upperBound, shift.regionY.lowerBound)
    }

    func testFeaturelessSurfaceHasNoTextureQuality() throws {
        let estimator = SpeedEstimator()
        XCTAssertNil(estimator.process(try makeBuffer(flat: true)))
        let shift = estimator.process(try makeBuffer(flat: true))
        XCTAssertEqual(shift?.quality ?? 0, 0)
    }

    // MARK: - Zones

    func testEveryZoneMeasuresTheSameUniformShift() throws {
        let estimator = SpeedEstimator()
        _ = try estimate(estimator, along: 24)
        XCTAssertEqual(estimator.lastTiles.count, SpeedEstimator.tileColumns * SpeedEstimator.tileRows)
        var measured = 0
        for tile in estimator.lastTiles {
            guard let tile else { continue }
            measured += 1
            XCTAssertEqual(tile.along, 24, accuracy: 1.5)
            XCTAssertEqual(tile.across, 0, accuracy: 1.5)
            XCTAssertGreaterThan(tile.quality, 0.3)
        }
        XCTAssertGreaterThanOrEqual(measured, 20)
    }

    func testZonesForTheOppositeTravelDirection() throws {
        let estimator = SpeedEstimator()
        estimator.travelSign = -1
        _ = try estimate(estimator, along: 24)
        var measured = 0
        for tile in estimator.lastTiles {
            guard let tile else { continue }
            measured += 1
            XCTAssertEqual(tile.along, 24, accuracy: 1.5)
        }
        XCTAssertGreaterThanOrEqual(measured, 20)
    }

    // MARK: - State handling

    func testFirstFrameAfterResetHasNothingToCompareWith() throws {
        let estimator = SpeedEstimator()
        _ = try estimate(estimator, along: 24)
        estimator.reset()
        XCTAssertNil(estimator.process(try makeBuffer(along: 24)))
        XCTAssertNotNil(estimator.process(try makeBuffer(along: 48)))
    }

    func testChangingTheFrameSizeRestartsTracking() throws {
        let estimator = SpeedEstimator()
        XCTAssertNil(estimator.process(try makeBuffer()))
        XCTAssertNil(estimator.process(try makeBuffer(width: 640, height: 480)))
        XCTAssertTrue(estimator.lastTiles.isEmpty)
        XCTAssertNotNil(estimator.process(try makeBuffer(width: 640, height: 480, along: 8)))
    }

    func testUnsupportedOrTooSmallBuffersAreIgnored() throws {
        let estimator = SpeedEstimator()
        XCTAssertNil(estimator.process(try makeBuffer(width: 100, height: 100)))
        var bgra: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 256, 256, kCVPixelFormatType_32BGRA, nil, &bgra)
        XCTAssertNil(estimator.process(try XCTUnwrap(bgra)))
    }

    // MARK: - Image pyramid

    func testHalfLevelAveragesTwoByTwoBlocks() throws {
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                       kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange] {
            let buffer = try makeBuffer(format: format, width: 256, height: 192)
            let level = try XCTUnwrap(SpeedEstimator.halfLevel(from: buffer))
            XCTAssertEqual(level.width, 128)
            XCTAssertEqual(level.height, 96)
            XCTAssertEqual(level.pixels.count, 128 * 96)
            let expected = (Int(texture(0, 0)) + Int(texture(1, 0)) + Int(texture(0, 1)) + Int(texture(1, 1))) >> 2
            XCTAssertEqual(Int(level.pixels[0]), expected)
        }
    }

    func testDownsampleAveragesTwoByTwoBlocks() {
        let level = SpeedEstimator.Level(width: 4, height: 4, pixels: [
            10, 20, 30, 40,
            50, 60, 70, 80,
            90, 100, 110, 120,
            130, 140, 150, 160
        ])
        let half = SpeedEstimator.downsample(level)
        XCTAssertEqual(half.width, 2)
        XCTAssertEqual(half.height, 2)
        XCTAssertEqual(half.pixels, [35, 55, 115, 135])
    }

    func testDownsampleDropsAnOddLastRowAndColumn() {
        let level = SpeedEstimator.Level(width: 5, height: 3, pixels: [UInt8](repeating: 8, count: 15))
        let half = SpeedEstimator.downsample(level)
        XCTAssertEqual(half.width, 2)
        XCTAssertEqual(half.height, 1)
        XCTAssertEqual(half.pixels, [8, 8])
    }
}
