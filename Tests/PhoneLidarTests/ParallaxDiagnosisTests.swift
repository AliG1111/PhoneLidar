import XCTest

/// Why a camera-parallax build measured nothing (design §15.9): the facts and the message picked from them.
final class ParallaxDiagnosisTests: XCTestCase {
    private typealias Counters = ParallaxProcessor.Counters

    /// A recording 1 m above the material, 1440-pixel picture along the travel, 30 frames/s.
    private func facts(travel: Double, speedReadings: Int = 300, pictures: Int = 900) -> ParallaxBuildFacts {
        ParallaxBuildFacts(videoPictures: pictures, recordingFrames: 900, speedReadings: speedReadings,
                           forwardTravel: travel,
                           neededTravel: ParallaxDiagnosis.neededTravel(settings: ParallaxSettings(), videoHeight: 1440,
                                                                        distance: 1000, focalY: 1512),
                           distance: 1000, frameRate: 30)
    }

    func testForwardTravelIsTheLargestGainOfOneForwardStretch() {
        XCTAssertEqual(ParallaxDiagnosis.forwardTravel([0, 10, 5, 30, -100, -50]), 50)
        XCTAssertEqual(ParallaxDiagnosis.forwardTravel([0, 10, 5, 30]), 30)
        XCTAssertEqual(ParallaxDiagnosis.forwardTravel([40, 30, 20]), 0)
        XCTAssertEqual(ParallaxDiagnosis.forwardTravel([0, .nan, 25, .infinity]), 25)
        XCTAssertEqual(ParallaxDiagnosis.forwardTravel([]), 0)
    }

    func testNeededTravelIsAThirdOfThePictureAtTheDistance() {
        let needed = ParallaxDiagnosis.neededTravel(settings: ParallaxSettings(), videoHeight: 1440, distance: 1000,
                                                    focalY: 1512)
        XCTAssertEqual(needed, 1440.0 / 3 * 1000 / 1512, accuracy: 1e-9)
        XCTAssertEqual(ParallaxDiagnosis.neededTravel(settings: ParallaxSettings(), videoHeight: 1440, distance: 1000,
                                                      focalY: 0), 0)
        XCTAssertEqual(ParallaxDiagnosis.neededTravel(settings: ParallaxSettings(), videoHeight: 0, distance: 1000,
                                                      focalY: 1512), 0)
        XCTAssertEqual(ParallaxDiagnosis.neededTravel(settings: ParallaxSettings(), videoHeight: 1440, distance: .nan,
                                                      focalY: 1512), 0)
    }

    func testFrameRateFromTheFrameTimes() {
        XCTAssertEqual(ParallaxDiagnosis.frameRate(times: (0..<31).map { Double($0) / 30 }), 30, accuracy: 1e-9)
        XCTAssertEqual(ParallaxDiagnosis.frameRate(times: [1.5]), 0)
        XCTAssertEqual(ParallaxDiagnosis.frameRate(times: [2, 2]), 0)
    }

    func testPairsFormedKeepTheMatchAndScaleMessages() {
        let texture = ParallaxDiagnosis.reason(counters: Counters(framesSeen: 300, pairs: 5), facts: facts(travel: 900))
        XCTAssertTrue(texture.contains("could not be matched"), texture)
        let scale = ParallaxDiagnosis.reason(counters: Counters(framesSeen: 300, pairs: 5, patchesMatched: 40),
                                             facts: facts(travel: 900))
        XCTAssertTrue(scale.contains("enough LiDAR readings for its scale"), scale)
    }

    func testNoPictureLinedUpWithTheRecording() {
        let none = ParallaxDiagnosis.reason(counters: Counters(), facts: facts(travel: 900, pictures: 0))
        XCTAssertTrue(none.contains("no picture could be read from Video.mov"), none)
        let mismatch = ParallaxDiagnosis.reason(counters: Counters(), facts: facts(travel: 900, pictures: 450))
        XCTAssertTrue(mismatch.contains("none of the 450 pictures"), mismatch)
        XCTAssertTrue(mismatch.contains("does not match the recording"), mismatch)
    }

    func testNoTextureLockMeansNoTravel() {
        let reason = ParallaxDiagnosis.reason(counters: Counters(framesSeen: 300, templatesStored: 1),
                                              facts: facts(travel: 0, speedReadings: 0))
        XCTAssertTrue(reason.contains("never locked onto the surface texture"), reason)
    }

    func testShortTravelStatesTheTravelAndWhatIsNeeded() {
        let reason = ParallaxDiagnosis.reason(counters: Counters(framesSeen: 300, templatesStored: 40),
                                              facts: facts(travel: 120))
        XCTAssertTrue(reason.contains("moved 120 mm"), reason)
        XCTAssertTrue(reason.contains("at least 317 mm"), reason)
        XCTAssertTrue(reason.contains("at 1.00 m from the camera"), reason)
    }

    func testTravelHeldFromBeforeRecordIsNotCalledNoLock() {
        // No speed reading during the recording, but a held speed moved the material far enough.
        let reason = ParallaxDiagnosis.reason(counters: Counters(framesSeen: 200, templatesStored: 40),
                                              facts: facts(travel: 400, speedReadings: 0))
        XCTAssertFalse(reason.contains("never locked"), reason)
        XCTAssertTrue(reason.contains("moved 400 mm"), reason)
        XCTAssertTrue(reason.contains("between two of the 200 frames that have a video picture"), reason)
        XCTAssertTrue(reason.contains("the recording has 900 frames"), reason)
    }

    func testTravelAgainstTheRecordingsDirectionIsNamed() {
        var against = facts(travel: 0)
        against.backwardTravel = 500
        let reason = ParallaxDiagnosis.reason(counters: Counters(framesSeen: 300, templatesStored: 1),
                                              facts: against)
        XCTAssertTrue(reason.contains("moved 500 mm against the recording's travel direction (and 0 mm along it)"),
                      reason)
        // Also when the speed never locked during the recording (a held speed moved it backwards).
        against.speedReadings = 0
        let held = ParallaxDiagnosis.reason(counters: Counters(framesSeen: 300, templatesStored: 1), facts: against)
        XCTAssertTrue(held.contains("against the recording's travel direction"), held)
        // Forward travel that is enough wins over a longer jog backwards.
        var both = facts(travel: 400)
        both.backwardTravel = 600
        let forward = ParallaxDiagnosis.reason(counters: Counters(framesSeen: 300, templatesStored: 40), facts: both)
        XCTAssertFalse(forward.contains("against"), forward)
    }

    func testTravelJustAboveTheNeededTravelIsANearMiss() {
        let reason = ParallaxDiagnosis.reason(counters: Counters(framesSeen: 300, templatesStored: 40),
                                              facts: facts(travel: 330))
        XCTAssertTrue(reason.contains("moved 330 mm, only just the 317 mm a pair needs"), reason)
        XCTAssertTrue(reason.contains("at 1.00 m from the camera"), reason)
    }

    func testHeightsMeasuredButOutsideTheMap() {
        let reason = ParallaxDiagnosis.reason(counters: Counters(framesSeen: 300, pairs: 5, pairsWithScale: 3,
                                                                 patchesMatched: 40, readings: 1200),
                                              facts: facts(travel: 900))
        XCTAssertTrue(reason.contains("1200 heights were measured, but none fell inside the map"), reason)
    }

    func testNoTemplatesMeansNoLiDARReadings() {
        let reason = ParallaxDiagnosis.reason(counters: Counters(framesSeen: 300), facts: facts(travel: 900))
        XCTAssertTrue(reason.contains("LiDAR readings needed to start a match"), reason)
    }

    func testSlowMaterialStatesTheFrameLimitAndTheSpeedNeeded() {
        let reason = ParallaxDiagnosis.reason(counters: Counters(framesSeen: 900, templatesStored: 40,
                                                                 pendingDropped: 3),
                                              facts: facts(travel: 900))
        XCTAssertTrue(reason.contains("longer than 600 frames (about 20 s)"), reason)
        XCTAssertTrue(reason.contains("(317 mm)"), reason)
        XCTAssertTrue(reason.contains("at least 16 mm/s at 1.00 m"), reason)

        var unknownRate = facts(travel: 900)
        unknownRate.frameRate = 0
        let plain = ParallaxDiagnosis.reason(counters: Counters(framesSeen: 900, templatesStored: 40,
                                                                pendingDropped: 3), facts: unknownRate)
        XCTAssertFalse(plain.contains("about"), plain)
        XCTAssertFalse(plain.contains("mm/s"), plain)
        XCTAssertTrue(plain.hasSuffix("(317 mm)."), plain)
    }

    func testTheFallbackSummaryLineIsReplacedByTheNextMapBuild() {
        let line = ParallaxDiagnosis.fallbackSummaryLine(reason: "No camera-parallax heights: test.")
        XCTAssertTrue(TopoMapBuilder.isMapSummaryLine(line))
        XCTAssertTrue(line.hasSuffix("No camera-parallax heights: test."))
        XCTAssertTrue(ParallaxDiagnosis.fallbackNotice(reason: "R.").hasSuffix("Averaged LiDAR map. R."))
    }
}
