import XCTest

/// Watchdog of the laser calibration capture: a capture stops with a reason when the camera stalls or runs far
/// slower than its format, instead of waiting for ever (design §14.2, FR-LAS-04).
final class LaserCaptureWatchTests: XCTestCase {
    private func progress(elapsed: Double, sinceLastFrame: Double, delivered: Int, dropped: Int = 0,
                          collected: Int, target: Int = 60, expected: Double = 1,
                          width: Int = 1920, height: Int = 1080) -> LaserCaptureWatch.Progress {
        LaserCaptureWatch.Progress(elapsed: elapsed, sinceLastFrame: sinceLastFrame, delivered: delivered,
                                   dropped: dropped, collected: collected, target: target, expectedDuration: expected,
                                   width: width, height: height)
    }

    func testRunningCaptureKeepsGoing() {
        // 240 fps, half a second in, frames arriving.
        XCTAssertNil(LaserCaptureWatch.stallReason(progress(elapsed: 0.5, sinceLastFrame: 0.004, delivered: 120,
                                                            collected: 30)))
        // Just under the frame gap and the time limit.
        XCTAssertNil(LaserCaptureWatch.stallReason(progress(elapsed: 4.9, sinceLastFrame: 1.99, delivered: 900,
                                                            collected: 59)))
    }

    func testNoFramesAtAllStops() throws {
        let reason = try XCTUnwrap(LaserCaptureWatch.stallReason(progress(elapsed: 2.0, sinceLastFrame: 2.0,
                                                                          delivered: 0, collected: 0,
                                                                          width: 0, height: 0)))
        XCTAssertEqual(reason, "no camera frames arrived in 2 s")
    }

    func testFramesStoppingMidCaptureStops() throws {
        let reason = try XCTUnwrap(LaserCaptureWatch.stallReason(progress(elapsed: 2.6, sinceLastFrame: 2.1,
                                                                          delivered: 96, dropped: 3,
                                                                          collected: 24)))
        XCTAssertEqual(reason, "the camera stopped sending frames 2 s ago (24 of 60 frames collected, 96 camera "
                       + "frames, 3 dropped)")
    }

    func testSlowCaptureStopsAtTheLimit() throws {
        // Expected 1 s: the limit is the 5 s minimum.
        XCTAssertNil(LaserCaptureWatch.stallReason(progress(elapsed: 4.99, sinceLastFrame: 0.03, delivered: 150,
                                                            collected: 37)))
        let reason = try XCTUnwrap(LaserCaptureWatch.stallReason(progress(elapsed: 5.0, sinceLastFrame: 0.03,
                                                                          delivered: 150, dropped: 7,
                                                                          collected: 37, width: 1920,
                                                                          height: 1440)))
        XCTAssertEqual(reason, "only 37 of 60 frames collected in 5 s (camera 30 fps, 1920 × 1440, 7 frames dropped)")
    }

    func testFramesStoppingWinsOverTheTimeLimit() throws {
        let reason = try XCTUnwrap(LaserCaptureWatch.stallReason(progress(elapsed: 6, sinceLastFrame: 3,
                                                                          delivered: 10, collected: 2)))
        XCTAssertTrue(reason.hasPrefix("the camera stopped sending frames"), reason)
    }

    func testLimitScalesWithTheExpectedDuration() {
        XCTAssertEqual(LaserCaptureWatch.limit(expectedDuration: 0.125), 5)     // shim: 30 frames at 240 fps
        XCTAssertEqual(LaserCaptureWatch.limit(expectedDuration: 1), 5)
        XCTAssertEqual(LaserCaptureWatch.limit(expectedDuration: 2), 8)
        XCTAssertEqual(LaserCaptureWatch.limit(expectedDuration: .nan), 5)
        XCTAssertEqual(LaserCaptureWatch.limit(expectedDuration: .infinity), 5)
        XCTAssertEqual(LaserCaptureWatch.limit(expectedDuration: -1), 5)
        // A long expected capture is not cut short.
        XCTAssertNil(LaserCaptureWatch.stallReason(progress(elapsed: 7.9, sinceLastFrame: 0.1, delivered: 237,
                                                            collected: 59, expected: 2)))
    }
}
