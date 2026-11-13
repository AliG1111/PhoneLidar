import Foundation
import CoreGraphics

/// The recording behind a map (a Line scan recording; the Laser line scan was removed in P16).
enum MapRecording: Sendable {
    /// `repaired`: Recording.json had to be repaired before it could be read.
    case lidar(LineRecordingInfo, repaired: Bool)

    var info: LineRecordingInfo {
        switch self {
        case .lidar(let info, _): return info
        }
    }

    var direction: TravelDirection { info.direction }

    /// The scan record's summary after a map build: recording line(s) kept, map lines replaced.
    func recordSummary(existing: [String], map: [String]) -> [String] {
        TopoMapBuilder.recordSummary(existing: existing, info: info, map: map)
    }
}

/// Map builds and replay inputs. Everything here runs off the main thread.
enum MapRebuild {
    /// Reads the recording in `folder` (a cut-off Recording.json is repaired on disk, as Line scan does after
    /// recording).
    static func load(folder: URL) throws -> MapRecording {
        let loaded = try LineRecordingRepair.loadInfo(folder: folder)
        return .lidar(loaded.info, repaired: loaded.repaired)
    }

    /// Builds the map (all files incl. TopoMap.png, staged together). `method` nil = the recording's. A camera-
    /// parallax map is built from Video.mov by `ParallaxMapBuilder` (design §15); `progress` (0…1) is reported by
    /// that builder only.
    static func build(folder: URL, recording: MapRecording, method: MapMethod?,
                      progress: (@Sendable (Double) -> Void)? = nil) async throws -> TopoMapBuilder.Output {
        let direction = recording.direction
        let composite: (CGImage, TopoStats) throws -> Data = { image, stats in
            try TopoMapRenderer.compositePNG(map: image, stats: stats, direction: direction)
        }
        switch recording {
        case .lidar(let info, let repaired):
            let resolved = method ?? info.mapMethod ?? .averaged
            var output: TopoMapBuilder.Output
            if resolved == .cameraParallax {
                output = try await ParallaxMapBuilder.build(folder: folder, info: info, composite: composite,
                                                            progress: progress)
            } else {
                output = try TopoMapBuilder.build(folder: folder, info: info, method: resolved, composite: composite)
            }
            if repaired { output.summary.insert(TopoMapBuilder.recordingRepairedNote, at: 0) }
            return output
        }
    }

    /// Per-frame replay inputs.
    static func replayFrames(folder: URL, recording: MapRecording) throws -> ReplayFrames {
        TopoReplaySource.replayFrames(info: recording.info)
    }
}
