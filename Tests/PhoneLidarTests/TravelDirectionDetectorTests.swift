import XCTest

final class TravelDirectionDetectorTests: XCTestCase {
    private let good = 0.6

    /// Adds `count` readings and returns how many of them reported a change.
    @discardableResult
    private func feed(_ detector: inout TravelDirectionDetector, shift: Double?, quality: Double = 0.6,
                      count: Int) -> Int {
        var changes = 0
        for _ in 0..<count where detector.add(rowShift: shift, quality: quality) { changes += 1 }
        return changes
    }

    func testStartsUndetected() {
        XCTAssertNil(TravelDirectionDetector().detected)
    }

    func testMovementTowardIncreasingRowsIsRightToLeft() {
        var detector = TravelDirectionDetector()
        feed(&detector, shift: 24, count: TravelDirectionDetector.required - 1)
        XCTAssertNil(detector.detected, "one vote short")
        XCTAssertTrue(detector.add(rowShift: 24, quality: good))
        XCTAssertEqual(detector.detected, .rightToLeft)
        XCTAssertEqual(TravelDirection.rightToLeft.bufferSign, 1)
    }

    func testMovementTowardDecreasingRowsIsLeftToRight() {
        var detector = TravelDirectionDetector()
        let changes = feed(&detector, shift: -3.5, count: TravelDirectionDetector.required)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(detector.detected, .leftToRight)
    }

    func testFurtherAgreeingVotesReportNoChange() {
        var detector = TravelDirectionDetector()
        let changes = feed(&detector, shift: 10, count: 40)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(detector.detected, .rightToLeft)
    }

    func testWeakOrMissingReadingsDoNotVote() {
        var detector = TravelDirectionDetector()
        feed(&detector, shift: nil, count: 30)
        feed(&detector, shift: 20, quality: TravelDirectionDetector.minimumQuality - 0.01, count: 30)
        feed(&detector, shift: TravelDirectionDetector.minimumShift * 0.9, count: 30)
        feed(&detector, shift: .nan, count: 30)
        feed(&detector, shift: .infinity, count: 30)
        feed(&detector, shift: 20, quality: .nan, count: 30)
        XCTAssertNil(detector.detected)
        // The thresholds themselves count.
        feed(&detector, shift: TravelDirectionDetector.minimumShift, quality: TravelDirectionDetector.minimumQuality,
             count: TravelDirectionDetector.required)
        XCTAssertEqual(detector.detected, .rightToLeft)
    }

    func testDirectionIsKeptWhileTheMaterialStopsOrLosesLock() {
        var detector = TravelDirectionDetector()
        feed(&detector, shift: -12, count: 20)
        XCTAssertEqual(detector.feedNothingChanges(), 0)
        feed(&detector, shift: 0, count: 200)          // standing still
        feed(&detector, shift: nil, count: 200)        // blank surface
        XCTAssertEqual(detector.detected, .leftToRight)
    }

    func testReversalNeedsAClearMajority() {
        var detector = TravelDirectionDetector()
        feed(&detector, shift: 30, count: 20)
        XCTAssertEqual(detector.detected, .rightToLeft)
        feed(&detector, shift: -30, count: TravelDirectionDetector.required - 1)
        XCTAssertEqual(detector.detected, .rightToLeft, "11 of the last 15 votes are not enough")
        XCTAssertTrue(detector.add(rowShift: -30, quality: good))
        XCTAssertEqual(detector.detected, .leftToRight)
    }

    func testAlternatingNoiseNeverDetects() {
        var detector = TravelDirectionDetector()
        for i in 0..<300 {
            detector.add(rowShift: i % 2 == 0 ? 5 : -5, quality: good)
        }
        XCTAssertNil(detector.detected)
    }

    func testOccasionalWrongVotesAreTolerated() {
        var detector = TravelDirectionDetector()
        // Every fifth reading points the wrong way (a false match): 12 of 15 still agree.
        for i in 0..<15 {
            detector.add(rowShift: i % 5 == 4 ? -8 : 8, quality: good)
        }
        XCTAssertEqual(detector.detected, .rightToLeft)
    }

    func testResetForgetsVotesAndDirection() {
        var detector = TravelDirectionDetector()
        feed(&detector, shift: 9, count: 20)
        detector.reset()
        XCTAssertNil(detector.detected)
        feed(&detector, shift: -9, count: TravelDirectionDetector.required - 1)
        XCTAssertNil(detector.detected, "old votes must not count after a reset")
    }

    // MARK: - DirectionSetting

    func testSettingsMapToDirections() {
        XCTAssertNil(DirectionSetting.auto.manual)
        XCTAssertEqual(DirectionSetting.rightToLeft.manual, .rightToLeft)
        XCTAssertEqual(DirectionSetting.leftToRight.manual, .leftToRight)
        XCTAssertEqual(DirectionSetting.allCases.first, .auto)
        XCTAssertEqual(DirectionSetting.auto.label, "Auto")
        XCTAssertEqual(DirectionSetting.leftToRight.label, TravelDirection.leftToRight.label)
    }

    func testTravelTexts() {
        XCTAssertEqual(DirectionSetting.rightToLeft.travelText(detected: .leftToRight),
                       "Material travel Right → Left (set by hand)")
        XCTAssertEqual(DirectionSetting.auto.travelText(detected: .leftToRight),
                       "Material travel Left → Right (detected)")
        XCTAssertTrue(DirectionSetting.auto.travelText(detected: nil).hasPrefix("Detecting the travel direction"))
        XCTAssertEqual(DirectionSetting.detectedNote(.rightToLeft),
                       "Travel direction Right → Left detected automatically from the material's movement.")
        XCTAssertFalse(DirectionSetting.notDetectedReason.hasSuffix("."), "completes a sentence that adds the period")
    }

    func testSettingRawValuesAreStable() {
        // Stored in UserDefaults ("laserDirectionSetting").
        XCTAssertEqual(DirectionSetting(rawValue: "auto"), .auto)
        XCTAssertEqual(DirectionSetting(rawValue: "rightToLeft"), .rightToLeft)
        XCTAssertEqual(DirectionSetting(rawValue: "leftToRight"), .leftToRight)
    }
}

private extension TravelDirectionDetector {
    /// Readings without a vote never report a change.
    mutating func feedNothingChanges() -> Int {
        var changes = 0
        for _ in 0..<50 where add(rowShift: nil, quality: 0) { changes += 1 }
        return changes
    }
}
