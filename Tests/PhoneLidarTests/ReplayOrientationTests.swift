import simd
import XCTest

final class ReplayOrientationTests: XCTestCase {
    /// Float maths, also after hundreds of composed steps.
    private let tolerance: Float = 5e-4

    private func assertVector(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ message: String = "",
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_length(a - b), tolerance, "\(a) vs \(b) \(message)", file: file, line: line)
    }

    /// Same rotation (q and −q are the same rotation).
    private func assertSameRotation(_ a: ReplayOrientation, _ b: ReplayOrientation, _ message: String = "",
                                    file: StaticString = #filePath, line: UInt = #line) {
        assertVector(a.right, b.right, message, file: file, line: line)
        assertVector(a.up, b.up, message, file: file, line: line)
        assertVector(a.back, b.back, message, file: file, line: line)
    }

    private func radians(_ degrees: Double) -> Float { Float(degrees * .pi / 180) }

    // MARK: - Fixed views

    func testDefaultMatchesTheEarlierFixedCamera() {
        // Before free rotation: elevation 42°, back = (0, sin e, cos e), right = +x, up = right × −back.
        let e = radians(ReplayOrientation.defaultTilt)
        let o = ReplayOrientation.standard
        assertVector(o.back, SIMD3<Float>(0, sin(e), cos(e)))
        assertVector(o.right, SIMD3<Float>(1, 0, 0))
        assertVector(o.up, simd_normalize(simd_cross(SIMD3<Float>(1, 0, 0), -o.back)))
    }

    func testResetTargetIsExactSoTheResetButtonCanTellTheDefaultView() {
        // TopoReplayModel.isDefaultView compares with `.standard` exactly: the default must rebuild identically and
        // any gesture must leave it.
        XCTAssertEqual(ReplayOrientation(turn: 0, tilt: ReplayOrientation.defaultTilt, roll: 0), .standard)
        XCTAssertNotEqual(ReplayOrientation.standard.dragged(dx: 3, dy: 0, radiansPerPoint: 0.01), .standard)
        XCTAssertNotEqual(ReplayOrientation.standard.dragged(dx: 0, dy: -3, radiansPerPoint: 0.01), .standard)
        XCTAssertNotEqual(ReplayOrientation.standard.twisted(by: 0.05), .standard)
        XCTAssertNotEqual(ReplayOrientation.top, .standard)
    }

    func testTopViewLooksStraightDownWithTheFrontEdgeAtTheBottom() {
        let o = ReplayOrientation.top
        assertVector(o.back, SIMD3<Float>(0, 1, 0))
        assertVector(o.right, SIMD3<Float>(1, 0, 0))
        assertVector(o.up, SIMD3<Float>(0, 0, -1))      // back edge (−z) at the top of the screen
    }

    // MARK: - Angles

    func testAnglesRoundTrip() {
        for turn in [-170.0, -90, -30, 0, 45, 135, 179] {
            for tilt in [-89.0, -60, -10, 0, 42, 75, 89] {
                for roll in [-150.0, -45, 0, 20, 90, 175] {
                    let a = ReplayOrientation(turn: turn, tilt: tilt, roll: roll).angles
                    let label = "\(turn) \(tilt) \(roll)"
                    XCTAssertEqual(a.turn, turn, accuracy: 0.01, label)
                    XCTAssertEqual(a.tilt, tilt, accuracy: 0.01, label)
                    XCTAssertEqual(a.roll, roll, accuracy: 0.01, label)
                }
            }
        }
    }

    func testStraightAboveOrBelowReportsRollZeroForTheSameRotation() {
        for tilt in [90.0, -90.0] {
            for (turn, roll) in [(0.0, 30.0), (60.0, -45.0), (-120.0, 170.0)] {
                let o = ReplayOrientation(turn: turn, tilt: tilt, roll: roll)
                let a = o.angles
                XCTAssertEqual(a.tilt, tilt)
                XCTAssertEqual(a.roll, 0)
                assertSameRotation(ReplayOrientation(turn: a.turn, tilt: a.tilt, roll: a.roll), o, "\(tilt) \(turn) \(roll)")
            }
        }
    }

    func testSliderAnglesFollowTheOrientation() {
        let angles = ReplayAngles(ReplayOrientation(turn: 30, tilt: 20, roll: -10))
        XCTAssertEqual(angles.turn, 30, accuracy: 0.01)
        XCTAssertEqual(angles.tilt, 20, accuracy: 0.01)
        XCTAssertEqual(angles.roll, -10, accuracy: 0.01)
        assertSameRotation(angles.orientation, ReplayOrientation(turn: 30, tilt: 20, roll: -10))
    }

    func testRollSliderStraightAboveTurnsByTheSliderAngle() {
        // R1: straight above, roll reads back as 0. Slider steps 1…10° must give a 10° roll, not 1 + 2 + … + 10.
        var angles = ReplayAngles(turn: 25, tilt: 90, roll: 0)
        for step in 1...10 {
            angles.roll = Double(step)
        }
        XCTAssertEqual(angles.roll, 10)
        assertSameRotation(angles.orientation, ReplayOrientation(turn: 35, tilt: 90, roll: 0))
        assertSameRotation(angles.orientation, ReplayOrientation(turn: 25, tilt: 90, roll: 10))
    }

    // MARK: - Gestures

    /// Screen position (x right, y up) of a scene direction seen from `o`.
    private func screen(_ p: SIMD3<Float>, _ o: ReplayOrientation) -> (x: Float, y: Float) {
        (simd_dot(p, o.right), simd_dot(p, o.up))
    }

    func testDragRightTurnsTheNearSideRight() {
        let start = ReplayOrientation.standard
        let near = start.back                       // the side of the strip facing the eye, at the screen centre
        let moved = start.dragged(dx: 20, dy: 0, radiansPerPoint: 0.01)
        let p = screen(near, moved)
        XCTAssertGreaterThan(p.x, 0.1)
        XCTAssertEqual(p.y, 0, accuracy: tolerance)
    }

    func testDragDownTurnsTheNearSideDownAndRaisesTheEye() {
        let start = ReplayOrientation.standard
        let moved = start.dragged(dx: 0, dy: 20, radiansPerPoint: 0.01)
        let p = screen(start.back, moved)
        XCTAssertLessThan(p.y, -0.1)
        XCTAssertEqual(p.x, 0, accuracy: tolerance)
        XCTAssertGreaterThan(moved.angles.tilt, start.angles.tilt, "same feel as the earlier drag-down = higher view")
    }

    func testDragsFollowTheFingerInAnyOrientation() {
        // Upside down and rolled: the near side still moves with the finger on screen.
        let start = ReplayOrientation(turn: 140, tilt: -70, roll: 120)
        let right = screen(start.back, start.dragged(dx: 15, dy: 0, radiansPerPoint: 0.01))
        XCTAssertGreaterThan(right.x, 0.1)
        let down = screen(start.back, start.dragged(dx: 0, dy: 15, radiansPerPoint: 0.01))
        XCTAssertLessThan(down.y, -0.1)
    }

    func testTwistClockwiseTurnsTheStripClockwise() {
        let start = ReplayOrientation(turn: 25, tilt: 30, roll: 0)
        let moved = start.twisted(by: 0.2)
        let p = screen(start.right, moved)         // a point at the right edge moves down when turned clockwise
        XCTAssertLessThan(p.y, -0.1)
        XCTAssertGreaterThan(p.x, 0.9)
        assertVector(moved.back, start.back, "a twist keeps the line of sight")
    }

    func testNoLimits() {
        // Over the top: dragging down 120° from 42° above puts the eye 162° round, behind and above the strip.
        let over = ReplayOrientation.standard.dragged(dx: 0, dy: 120, radiansPerPoint: .pi / 180)
        let e = radians(162)
        assertVector(over.back, SIMD3<Float>(0, sin(e), cos(e)))
        // Underneath.
        let under = ReplayOrientation.standard.dragged(dx: 0, dy: -100, radiansPerPoint: .pi / 180)
        XCTAssertEqual(under.angles.tilt, -58, accuracy: 0.01)
        // Full turns in small steps come back to the start, in every direction.
        for (dx, dy) in [(1.0, 0.0), (0.0, 1.0), (0.6, -0.8)] {
            var o = ReplayOrientation.standard
            for _ in 0..<360 { o = o.dragged(dx: dx, dy: dy, radiansPerPoint: .pi / 180) }
            assertSameRotation(o, .standard, "\(dx) \(dy)")
        }
        var rolled = ReplayOrientation.standard
        for _ in 0..<720 { rolled = rolled.twisted(by: .pi / 360) }
        assertSameRotation(rolled, .standard)
    }

    func testRotationStaysUnitLength() {
        var o = ReplayOrientation.standard
        for i in 0..<5000 {
            o = o.dragged(dx: Double(i % 7) - 3, dy: Double(i % 5) - 2, radiansPerPoint: 0.013).twisted(by: 0.01)
        }
        XCTAssertEqual(simd_length(o.rotation.vector), 1, accuracy: 1e-5)
    }

    func testEmptyOrInvalidGesturesChangeNothing() {
        let o = ReplayOrientation(turn: 10, tilt: 20, roll: 30)
        XCTAssertEqual(o.dragged(dx: 0, dy: 0, radiansPerPoint: 0.01), o)
        XCTAssertEqual(o.dragged(dx: .nan, dy: 1, radiansPerPoint: 0.01), o)
        XCTAssertEqual(o.dragged(dx: 1, dy: 1, radiansPerPoint: .infinity), o)
        XCTAssertEqual(o.twisted(by: 0), o)
        XCTAssertEqual(o.twisted(by: .nan), o)
        XCTAssertNotEqual(o.twisted(by: 0.1), o)
    }
}
