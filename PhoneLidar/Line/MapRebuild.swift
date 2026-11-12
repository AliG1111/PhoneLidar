import Foundation
import CoreGraphics

/// The recording behind a map: a LiDAR line recording or a laser line recording (design §14.1).
enum MapRecording: Sendable {
    /// `repaired`: Recording.json had to be repaired before it could be read.
    case lidar(LineRecordingInfo, repaired: Bool)
    case laser(LaserRecordingInfo)

    var direction: TravelDirection {
        switch self {
        case .lidar(let info, _): return info.direction
        case .laser(let info): return info.direction
        }
    }

    /// Map method chosen when the recording was made.
    var recordedMethod: MapMethod {
        switch self {
        case .lidar(let info, _): return info.mapMethod ?? .averaged
        case .laser(let info): return info.mapMethod
        }
    }

    var isLaser: Bool {
        if case .laser = self { return true }
        return false
    }

    /// The scan record's summary after a map build: recording line(s) kept, map lines replaced.
    func recordSummary(existing: [String], map: [String]) -> [String] {
        switch self {
        case .lidar(let info, _): return TopoMapBuilder.recordSummary(existing: existing, info: info, map: map)
        case .laser(let info): return LaserMapBuilder.recordSummary(existing: existing, info: info, map: map)
        }
    }
}

/// Map builds and replay inputs for both sensors. Everything here runs off the main thread.
enum MapRebuild {
    /// Reads the recording in `folder` (a laser recording when `LaserRecording.json` exists; a cut-off
    /// Recording.json is repaired on disk, as Line scan does after recording).
    static func load(folder: URL) throws -> MapRecording {
        if LaserRecordingInfo.exists(in: folder) {
            return .laser(try LaserRecordingInfo.load(from: folder))
        }
        let loaded = try LineRecordingRepair.loadInfo(folder: folder)
        return .lidar(loaded.info, repaired: loaded.repaired)
    }

    /// Builds the map (all files incl. TopoMap.png, staged together). `method` nil = the recording's.
    static func build(folder: URL, recording: MapRecording, method: MapMethod?) throws -> TopoMapBuilder.Output {
        let direction = recording.direction
        let composite: (CGImage, TopoStats) throws -> Data = { image, stats in
            try TopoMapRenderer.compositePNG(map: image, stats: stats, direction: direction)
        }
        switch recording {
        case .lidar(let info, let repaired):
            var output = try TopoMapBuilder.build(folder: folder, info: info, method: method, composite: composite)
            if repaired { output.summary.insert(TopoMapBuilder.recordingRepairedNote, at: 0) }
            return output
        case .laser(let info):
            return try LaserMapBuilder.build(folder: folder, info: info, method: method, composite: composite)
        }
    }

    /// Per-frame replay inputs.
    static func replayFrames(folder: URL, recording: MapRecording) throws -> ReplayFrames {
        switch recording {
        case .lidar(let info, _): return TopoReplaySource.replayFrames(info: info)
        case .laser(let info): return try LaserMapBuilder.replayFrames(folder: folder, info: info)
        }
    }
}
