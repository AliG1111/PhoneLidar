import XCTest

/// `ReplayFrames`, `TopoReplaySource.make(grid:direction:frames:)` (design §6.10, §14.7), the time-array overload of
/// `LineMath.frameIndex`, and the `mapMethod` of Recording.json (design §13.2, FR-SFM-01).
final class ReplayFramesTests: XCTestCase {
    private func makeGrid(columns: Int = 12, rows: Int = 6, heightMode: Bool = true,
                          value: (Int, Int) -> Float = { _, c in Float(c) }) -> TopoGridFile {
        var values = [Float](repeating: .nan, count: columns * rows)
        for r in 0..<rows {
            for c in 0..<columns { values[r * columns + c] = value(r, c) }
        }
        return TopoGridFile(columns: columns, rows: rows, cell: 10, qMin: 0, xMin: -30, heightMode: heightMode,
                            values: values)
    }

    /// 21 frames 0.1 s apart, 10 mm of travel each, from 210 mm (64 × 48 depth map, 10 mm depth pixels).
    private func makeInfo(direction: TravelDirection = .rightToLeft) -> LineRecordingInfo {
        let frames = (0..<21).map { i in
            makeFrame(index: i, time: Double(i) * 0.1, speed: 100, travel: 210 + Double(i) * 10)
        }
        return LineRecordingInfo(depthWidth: 64, depthHeight: 48, videoWidth: 1080, videoHeight: 1920,
                                 filteredDepth: true, shortShutter: true, direction: direction, frames: frames)
    }

    // MARK: - LiDAR replay frames

    func testLidarReplayFramesCarryTimesTravelSpeedsAndTheViewEdge() {
        let info = makeInfo()
        let frames = TopoReplaySource.replayFrames(info: info)
        XCTAssertEqual(frames.times.count, 21)
        XCTAssertEqual(frames.travel.count, 21)
        XCTAssertEqual(frames.speeds.count, 21)
        XCTAssertEqual(frames.reveal.count, 21)
        XCTAssertEqual(frames.times[5], 0.5, accuracy: 1e-12)
        XCTAssertEqual(frames.travel[5], 260, accuracy: 1e-12)
        XCTAssertEqual(frames.speeds[5], 100)
        // Row 45 is 21 pixels · 10 mm below the centre: the newest complete line is 210 mm behind the travel.
        for i in 0..<21 { XCTAssertEqual(frames.reveal[i], 10 * Double(i), accuracy: 1e-9) }
    }

    func testLidarReplayFramesRevealOtherEdgeForLeftToRightTravel() {
        let frames = TopoReplaySource.replayFrames(info: makeInfo(direction: .leftToRight))
        // Row 2 is 22 pixels · 10 mm above the centre; sign = −1.
        for i in 0..<21 { XCTAssertEqual(frames.reveal[i], 210 + 10 * Double(i) - 220, accuracy: 1e-9) }
    }

    func testFramesWithoutAFocalLengthHaveNoRevealPosition() {
        var info = makeInfo()
        info.frames[3] = makeFrame(index: 3, time: 0.3, speed: 100, travel: 240, fy: 0)
        let frames = TopoReplaySource.replayFrames(info: info)
        XCTAssertTrue(frames.reveal[3].isNaN)
        XCTAssertFalse(frames.reveal[2].isNaN)
        XCTAssertEqual(frames.reveal[4], 40, accuracy: 1e-9)
    }

    // MARK: - make(grid:info:) is make(grid:direction:frames:)

    private func assertSameSource(_ a: TopoReplaySource, _ b: TopoReplaySource, file: StaticString = #filePath,
                                  line: UInt = #line) {
        XCTAssertEqual(a.heightMode, b.heightMode, file: file, line: line)
        XCTAssertEqual(a.referenceDistance, b.referenceDistance, file: file, line: line)
        XCTAssertEqual(a.cell, b.cell, file: file, line: line)
        XCTAssertEqual(a.rows, b.rows, file: file, line: line)
        XCTAssertEqual(a.columns, b.columns, file: file, line: line)
        XCTAssertEqual(a.values, b.values, file: file, line: line)
        XCTAssertEqual(a.pStart, b.pStart, file: file, line: line)
        XCTAssertEqual(a.acrossStart, b.acrossStart, file: file, line: line)
        XCTAssertEqual(a.frameTimes, b.frameTimes, file: file, line: line)
        XCTAssertEqual(a.revealP, b.revealP, file: file, line: line)
        XCTAssertEqual(a.speeds, b.speeds, file: file, line: line)
        XCTAssertEqual(a.recordingDuration, b.recordingDuration, file: file, line: line)
        XCTAssertEqual(a.runOutSpeed, b.runOutSpeed, file: file, line: line)
        XCTAssertEqual(a.duration, b.duration, file: file, line: line)
        XCTAssertEqual(a.median, b.median, file: file, line: line)
        XCTAssertEqual(a.robustStdDev, b.robustStdDev, file: file, line: line)
        XCTAssertEqual(a.p01, b.p01, file: file, line: line)
        XCTAssertEqual(a.p99, b.p99, file: file, line: line)
    }

    func testMakeFromInfoGivesTheSameResultAsMakeFromItsReplayFrames() throws {
        for direction in TravelDirection.allCases {
            for heightMode in [true, false] {
                let grid = makeGrid(heightMode: heightMode) { r, c in 1000 - Float(c) + Float(r) * 0.25 }
                let info = makeInfo(direction: direction)
                let fromInfo = try TopoReplaySource.make(grid: grid, info: info)
                let fromFrames = try TopoReplaySource.make(grid: grid, direction: direction,
                                                           frames: TopoReplaySource.replayFrames(info: info))
                assertSameSource(fromInfo, fromFrames)
            }
        }
    }

    // MARK: - Custom frames

    func testCustomFramesGiveAMonotonicRevealStartingAtTheFirstValidOne() throws {
        let frames = ReplayFrames(times: [0, 0.1, 0.2, 0.3], travel: [0, 10, 20, 30],
                                  speeds: [100, nil, 100, 100], reveal: [.nan, 5, 3, 25])
        let source = try TopoReplaySource.make(grid: makeGrid(), direction: .rightToLeft, frames: frames)
        XCTAssertEqual(source.revealP, [5, 5, 5, 25])       // NaN takes the first valid value; never decreases
        XCTAssertEqual(source.frameTimes, [0, 0.1, 0.2, 0.3])
        XCTAssertEqual(source.recordingDuration, 0.3, accuracy: 1e-12)
        XCTAssertEqual(source.speeds.count, 4)
        XCTAssertGreaterThan(source.duration, source.recordingDuration)     // the rest of the map runs out
    }

    func testFramesMustBeConsistentAndHaveARevealPosition() {
        let grid = makeGrid()
        let good = ReplayFrames(times: [0, 0.1], travel: [0, 10], speeds: [100, 100], reveal: [0, 10])
        XCTAssertNoThrow(try TopoReplaySource.make(grid: grid, direction: .rightToLeft, frames: good))

        var shortSpeeds = good
        shortSpeeds.speeds = [100]
        XCTAssertThrowsError(try TopoReplaySource.make(grid: grid, direction: .rightToLeft, frames: shortSpeeds)) {
            assertLineError($0, .notEnoughData)
        }
        var shortReveal = good
        shortReveal.reveal = [0]
        XCTAssertThrowsError(try TopoReplaySource.make(grid: grid, direction: .rightToLeft, frames: shortReveal)) {
            assertLineError($0, .notEnoughData)
        }
        var shortTravel = good
        shortTravel.travel = [0, 10, 20]
        XCTAssertThrowsError(try TopoReplaySource.make(grid: grid, direction: .rightToLeft, frames: shortTravel)) {
            assertLineError($0, .notEnoughData)
        }
        let none = ReplayFrames(times: [], travel: [], speeds: [], reveal: [])
        XCTAssertThrowsError(try TopoReplaySource.make(grid: grid, direction: .rightToLeft, frames: none)) {
            assertLineError($0, .notEnoughData)
        }
        var unknownReveal = good
        unknownReveal.reveal = [.nan, .nan]
        XCTAssertThrowsError(try TopoReplaySource.make(grid: grid, direction: .rightToLeft, frames: unknownReveal)) {
            assertLineError($0, .notEnoughData)
        }
    }

    func testLeftToRightFramesReverseTheColumns() throws {
        let frames = ReplayFrames(times: [0, 0.1], travel: [0, 10], speeds: [100, 100], reveal: [0, 10])
        let rtl = try TopoReplaySource.make(grid: makeGrid(), direction: .rightToLeft, frames: frames)
        let ltr = try TopoReplaySource.make(grid: makeGrid(), direction: .leftToRight, frames: frames)
        XCTAssertEqual(rtl.values[0], 0)
        XCTAssertEqual(ltr.values[0], 11)
        XCTAssertEqual(rtl.pStart, 0, accuracy: 1e-9)
        XCTAssertEqual(ltr.pStart, -120, accuracy: 1e-9)
    }
}

final class FrameIndexTests: XCTestCase {
    private let times: [Double] = [0, 0.1, 0.2, 0.3]

    func testIndexIsTheLastTimeNotAfterTheGivenOne() {
        XCTAssertEqual(LineMath.frameIndex(for: -1, inTimes: times), 0)
        XCTAssertEqual(LineMath.frameIndex(for: 0, inTimes: times), 0)
        XCTAssertEqual(LineMath.frameIndex(for: 0.05, inTimes: times), 0)
        XCTAssertEqual(LineMath.frameIndex(for: 0.1, inTimes: times), 1)
        XCTAssertEqual(LineMath.frameIndex(for: 0.15, inTimes: times), 1)
        XCTAssertEqual(LineMath.frameIndex(for: 0.25, inTimes: times), 2)
        XCTAssertEqual(LineMath.frameIndex(for: 0.3, inTimes: times), 3)
        XCTAssertEqual(LineMath.frameIndex(for: 99, inTimes: times), 3)
    }

    func testEmptyAndSingleTimes() {
        XCTAssertEqual(LineMath.frameIndex(for: 1, inTimes: []), 0)
        XCTAssertEqual(LineMath.frameIndex(for: 1, inTimes: [5]), 0)
        XCTAssertEqual(LineMath.frameIndex(for: 9, inTimes: [5]), 0)
    }

    func testEqualTimesGiveTheLastOfThem() {
        XCTAssertEqual(LineMath.frameIndex(for: 1, inTimes: [0, 1, 1, 2]), 2)
    }

    func testAgreesWithTheFrameOverload() {
        let frames = times.enumerated().map { makeFrame(index: $0.offset, time: $0.element) }
        for t in stride(from: -0.1, through: 0.5, by: 0.025) {
            XCTAssertEqual(LineMath.frameIndex(for: t, inTimes: times), LineMath.frameIndex(for: t, in: frames),
                           "t = \(t)")
        }
    }
}

final class RecordingMapMethodTests: XCTestCase {
    private func makeHeader(mapMethod: MapMethod? = nil) -> LineRecordingHeader {
        LineRecordingHeader(depthWidth: 192, depthHeight: 256, videoWidth: 1080, videoHeight: 1920,
                            filteredDepth: true, shortShutter: false, direction: .leftToRight,
                            tileColumns: 6, tileRows: 4, mapMethod: mapMethod)
    }

    /// Writes a Recording.json with two frames and returns its raw JSON object and the decoded info.
    private func write(_ header: LineRecordingHeader) throws -> ([String: Any], LineRecordingInfo) {
        let url = try makeTempFolder().appendingPathComponent("Recording.json")
        let writer = try RecordingJSONWriter(url: url, header: header)
        try writer.append(makeFrame(index: 0))
        try writer.append(makeFrame(index: 1, time: 0.1))
        try writer.close()
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (object, try JSONDecoder.iso.decode(LineRecordingInfo.self, from: data))
    }

    func testSingleReadingIsWrittenToTheHeaderAndReadBack() throws {
        let (object, info) = try write(makeHeader(mapMethod: .singleReading))
        XCTAssertEqual(object["mapMethod"] as? String, "singleReading")
        XCTAssertEqual(info.mapMethod, .singleReading)
        XCTAssertEqual(info.frames.count, 2)
    }

    func testAveragedRecordingsKeepThePreP11Header() throws {
        let (object, info) = try write(makeHeader(mapMethod: nil))
        XCTAssertNil(object["mapMethod"])
        XCTAssertNil(info.mapMethod)
    }

    func testRecordingInfoWithoutAMethodDecodesAsNil() throws {
        let info = LineRecordingInfo(depthWidth: 64, depthHeight: 48, videoWidth: 1080, videoHeight: 1920,
                                     filteredDepth: true, shortShutter: true, direction: .rightToLeft, frames: [])
        let encoded = try JSONEncoder().encode(info)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["mapMethod"])
        XCTAssertNil(try JSONDecoder().decode(LineRecordingInfo.self, from: encoded).mapMethod)
    }

    func testRecordingInfoRoundTripsTheMethod() throws {
        var info = LineRecordingInfo(depthWidth: 64, depthHeight: 48, videoWidth: 1080, videoHeight: 1920,
                                     filteredDepth: true, shortShutter: true, direction: .rightToLeft, frames: [])
        info.mapMethod = .singleReading
        let back = try JSONDecoder().decode(LineRecordingInfo.self, from: try JSONEncoder().encode(info))
        XCTAssertEqual(back.mapMethod, .singleReading)
    }

    func testAnUnknownMethodFromANewerBuildReadsAsAveraged() throws {
        let info = LineRecordingInfo(depthWidth: 64, depthHeight: 48, videoWidth: 1080, videoHeight: 1920,
                                     filteredDepth: true, shortShutter: true, direction: .rightToLeft, frames: [])
        let encoded = try JSONEncoder().encode(info)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["mapMethod"] = "median"
        let edited = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try JSONDecoder().decode(LineRecordingInfo.self, from: edited).mapMethod, .averaged)
    }
}
