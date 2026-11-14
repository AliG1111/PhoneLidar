import Foundation

/// Direction setting on the Line scan screen (FR-DIR-01): detected from the material's
/// movement, or set by hand when the detection has trouble.
enum DirectionSetting: String, Codable, CaseIterable, Identifiable {
    case auto
    case rightToLeft
    case leftToRight

    var id: String { rawValue }

    /// The direction set by hand; nil for Auto.
    var manual: TravelDirection? {
        switch self {
        case .auto: return nil
        case .rightToLeft: return .rightToLeft
        case .leftToRight: return .leftToRight
        }
    }

    var label: String { manual?.label ?? "Auto" }

    /// Readout under the speed: the direction in use, or why there is none yet.
    func travelText(detected: TravelDirection?) -> String {
        if let manual { return "Material travel \(manual.label) (set by hand)" }
        if let detected { return "Material travel \(detected.label) (detected)" }
        return "Detecting the travel direction: needs moving material with visible texture"
    }

    /// Recording refusal while Auto has not seen the material move yet (completes "Recording not started: …").
    static let notDetectedReason = "the travel direction has not been detected yet. The material has to move "
        + "under the phone with visible texture; wait for it to move, or set Direction to Right → Left or Left → Right"

    /// Scan-summary line for a recording whose direction came from the detection.
    static func detectedNote(_ direction: TravelDirection) -> String {
        "Travel direction \(direction.label) detected automatically from the material's movement."
    }
}

/// Decides which way the material moves from the texture tracker's shifts (design §6.16). Pure value type, owned by
/// the capture pipeline's data queue.
///
/// Every reading with match quality ≥ `minimumQuality` and a shift of at least `minimumShift` full-resolution pixels
/// is a vote for the direction of its sign. A direction is detected (or replaced) when at least `required` of the
/// last `window` votes agree. Readings without a vote (no texture lock, material standing still) leave the votes as
/// they are, so a detected direction is kept while the material stops and changes only on opposite movement.
struct TravelDirectionDetector {
    /// Votes kept (the most recent ones).
    static let window = 15
    /// Agreeing votes among the last `window` needed to detect or change the direction.
    static let required = 12
    /// Smallest shift that counts as movement, full-resolution pixels per tracked frame.
    static let minimumShift = 1.0
    /// Smallest match quality that counts (stricter than the speed gate `LineMotionMath.minimumTrackQuality`).
    static let minimumQuality = 0.15

    private(set) var detected: TravelDirection?
    /// Signs of the most recent votes (+1 = toward increasing buffer rows), oldest first.
    private var votes: [Int] = []

    /// Forgets the votes and the detected direction.
    mutating func reset() {
        detected = nil
        votes.removeAll(keepingCapacity: true)
    }

    /// Adds one tracked frame. `rowShift`: full-resolution pixels moved toward increasing buffer rows (+ = right → left
    /// on the portrait screen, `TravelDirection.bufferSign`); nil = no reading. Returns true when `detected` changed.
    @discardableResult
    mutating func add(rowShift: Double?, quality: Double) -> Bool {
        guard let shift = rowShift, shift.isFinite, quality.isFinite, quality >= Self.minimumQuality,
              abs(shift) >= Self.minimumShift else { return false }
        votes.append(shift > 0 ? 1 : -1)
        if votes.count > Self.window { votes.removeFirst(votes.count - Self.window) }
        let plus = votes.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
        let minus = votes.count - plus
        let winner: TravelDirection?
        if plus >= Self.required {
            winner = .rightToLeft
        } else if minus >= Self.required {
            winner = .leftToRight
        } else {
            winner = nil
        }
        guard let winner, winner != detected else { return false }
        detected = winner
        return true
    }
}
