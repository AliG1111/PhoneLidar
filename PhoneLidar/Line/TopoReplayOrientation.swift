import Foundation
import simd

/// Orientation of the topographic replay camera (FR-RPL-06, design §6.11): a unit quaternion that turns camera axes
/// into scene axes (camera right = +x, up = +y, looking along −z). There are no limits: drags and twists compose
/// rotations, so every orientation can be reached, including views from below and upside down.
///
/// Angles for the settings sheet: rotation = R_y(turn) · R_x(−tilt) · R_z(roll), degrees. Tilt is the height of the
/// eye above the strip's plane (+90 = straight above, −90 = straight below, range −90…90), turn the rotation about
/// the vertical axis (+ = eye moves toward the newest end), roll the rotation about the line of sight.
struct ReplayOrientation: Equatable {
    var rotation: simd_quatf

    /// Default 3D view: 42° above the strip, square on to the front edge (the pre-free-rotation default).
    static let defaultTilt = 42.0
    static let standard = ReplayOrientation(turn: 0, tilt: defaultTilt, roll: 0)
    /// Straight above, front edge at the bottom (Map mode).
    static let top = ReplayOrientation(turn: 0, tilt: 90, roll: 0)

    init(rotation: simd_quatf) {
        self.rotation = simd_normalize(rotation)
    }

    init(turn: Double, tilt: Double, roll: Double) {
        let d = Double.pi / 180
        let qTurn = simd_quatf(angle: Float(turn * d), axis: SIMD3<Float>(0, 1, 0))
        let qTilt = simd_quatf(angle: Float(-tilt * d), axis: SIMD3<Float>(1, 0, 0))
        let qRoll = simd_quatf(angle: Float(roll * d), axis: SIMD3<Float>(0, 0, 1))
        self.init(rotation: qTurn * qTilt * qRoll)
    }

    /// Camera axes in scene coordinates.
    var right: SIMD3<Float> { rotation.act(SIMD3<Float>(1, 0, 0)) }
    var up: SIMD3<Float> { rotation.act(SIMD3<Float>(0, 1, 0)) }
    /// Points from the strip toward the eye.
    var back: SIMD3<Float> { rotation.act(SIMD3<Float>(0, 0, 1)) }

    /// (turn, tilt, roll) in degrees; turn and roll in −180…180, tilt in −90…90. Straight above or below
    /// (|tilt| = 90) turn and roll describe the same rotation: roll is then reported as 0.
    var angles: (turn: Double, tilt: Double, roll: Double) {
        let m = simd_matrix3x3(rotation)          // columns: right, up, back
        let r = 180 / Double.pi
        let sinTilt = Double(max(-1, min(1, m.columns.2.y)))
        if abs(sinTilt) > 0.999_999 {
            // Within about 0.1° of straight above or below: R_x(∓90°)·R_z(roll) = R_y(±roll)·R_x(∓90°).
            let turn = atan2(Double(-m.columns.0.z), Double(m.columns.0.x)) * r
            return (turn, sinTilt > 0 ? 90 : -90, 0)
        }
        let tilt = asin(sinTilt) * r
        let turn = atan2(Double(m.columns.2.x), Double(m.columns.2.z)) * r
        let roll = atan2(Double(m.columns.0.y), Double(m.columns.1.y)) * r
        return (turn, tilt, roll)
    }


    /// Trackball drag: the strip turns the way the finger moves, about the screen's axes, by `radiansPerPoint` per
    /// point of finger travel (`dx` + = right, `dy` + = down, as in UIKit). Unlimited and the same in every
    /// orientation.
    func dragged(dx: Double, dy: Double, radiansPerPoint: Double) -> ReplayOrientation {
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0, length.isFinite, radiansPerPoint.isFinite else { return self }
        // Finger right turns the near side of the strip right (about the screen's up axis); finger down turns it
        // down (about the screen's right axis). The camera turns the opposite way about the same camera axis.
        let axis = SIMD3<Float>(Float(dy / length), Float(dx / length), 0)
        let step = simd_quatf(angle: Float(-length * radiansPerPoint), axis: axis)
        return ReplayOrientation(rotation: rotation * step)
    }

    /// Two-finger twist: the strip turns with the fingers about the line of sight. `radians` + = clockwise on the
    /// screen (`UIRotationGestureRecognizer`).
    func twisted(by radians: Double) -> ReplayOrientation {
        guard radians.isFinite, radians != 0 else { return self }
        let step = simd_quatf(angle: Float(radians), axis: SIMD3<Float>(0, 0, 1))
        return ReplayOrientation(rotation: rotation * step)
    }

    static func == (a: ReplayOrientation, b: ReplayOrientation) -> Bool {
        a.rotation.vector == b.rotation.vector
    }
}

/// Angles on the settings sliders (degrees). The replay model keeps them as set while a slider moves and builds the
/// orientation from them; gestures and reset replace them with `ReplayOrientation.angles`. Reading them back from
/// the orientation after every slider step would jump straight above or below, where turn and roll describe the
/// same rotation (roll reads back as 0).
struct ReplayAngles: Equatable {
    var turn: Double
    var tilt: Double
    var roll: Double

    init(turn: Double, tilt: Double, roll: Double) {
        self.turn = turn
        self.tilt = tilt
        self.roll = roll
    }

    init(_ orientation: ReplayOrientation) {
        let a = orientation.angles
        self.init(turn: a.turn, tilt: a.tilt, roll: a.roll)
    }

    var orientation: ReplayOrientation { ReplayOrientation(turn: turn, tilt: tilt, roll: roll) }
}
