import Foundation
import AVFoundation
import CoreGraphics
import simd

/// Builds a camera-parallax map (design §15): decodes Video.mov, measures heights with `ParallaxProcessor` and
/// finishes the map files with `TopoMapBuilder.finish`. Runs off the main thread.
enum ParallaxMapBuilder {
    /// `area` overrides the recording's area of interest (nil = the recording's, else the whole picture; §17.4).
    static func build(folder: URL, info: LineRecordingInfo, area: ScanArea? = nil,
                      composite: ((CGImage, TopoStats) throws -> Data)?,
                      progress: (@Sendable (Double) -> Void)? = nil) async throws -> TopoMapBuilder.Output {
        let videoURL = folder.appendingPathComponent("Video.mov")
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw LineError.configuration("No Video.mov in this recording: a camera-parallax map needs the video. "
                                          + "Pick Averaged or Single reading.")
        }
        let reader = try DepthFileReader(url: folder.appendingPathComponent("Depth.bin"))
        let frames = Array(info.frames.prefix(reader.frameCount))
        guard frames.count >= 2 else { throw LineError.notEnoughData }
        let w = reader.width
        let h = reader.height
        let videoWidth = info.videoWidth
        let videoHeight = info.videoHeight
        guard videoWidth >= 64, videoHeight >= 64 else { throw LineError.badFile }
        let depths = frames.map(\.medianDepth).filter { $0 > 0 }.sorted()
        guard !depths.isEmpty else { throw LineError.notEnoughData }
        let zTypical = depths[depths.count / 2]
        let border = TopoMapBuilder.border(width: w, height: h)
        guard w > 2 * border + 4, h > 2 * border + 4 else { throw LineError.badFile }
        let sign = info.direction.bufferSign

        let model = MapHeightModel.load(folder: folder, width: w, height: h, frames: frames)
        let heightMode = model.isHeight
        let baseValues = model.baselineValues ?? []
        let plane = model.plane
        // Readings only from depth pixels inside the border, the side walls and the area of interest (FR-AOI-03).
        let area = (area ?? info.area ?? .whole).normalized
        let pixels = MapPixels.make(width: w, height: h, border: border, keptAcross: model.keptAcross, area: area)
        guard pixels.isUsable else {
            throw LineError.configuration(MapPixels.unusableMessage(sideWalls: model.keptAcross != nil,
                                                                    wholeArea: area.isWhole))
        }
        // Along the travel the readings were never limited by the border, only by the area (its rows of the depth map).
        let rowLo = max(0, Int((area.alongStart * Double(h)).rounded(.up)))
        let rowHi = min(h, Int((area.alongEnd * Double(h)).rounded(.down)))
        let areaRows = rowLo < rowHi ? rowLo..<rowHi : rowLo..<rowLo
        // The columns without the area: a reading inside these but outside the area was left out by the area.
        let unlimited = MapPixels.make(width: w, height: h, border: border, keptAcross: model.keptAcross, area: .whole)
        let lens = info.lens.flatMap { $0.isValid ? $0 : nil }
        let normal = ParallaxGeometry.beltNormal(frames: frames,
                                                 reference: model.reference ?? HeightReference.load(from: folder))
        let settings = ParallaxSettings()

        // Grid: the LiDAR maps' extent, cells of the patch spacing at the typical distance.
        guard let extent = TopoMapBuilder.extent(frames: frames, width: w, height: h, pixels: pixels,
                                                 sign: Double(sign), typicalDepth: zTypical) else {
            throw LineError.notEnoughData
        }
        let focals = frames.map { Double($0.fx) * Double(videoWidth) / Double(w) }.filter { $0 > 0 }.sorted()
        guard !focals.isEmpty else { throw LineError.notEnoughData }
        // Video focal length along the travel (pixels), for the travel a pair needs (design §15.9).
        let focalY = HeightMath.median(frames.map {
            LineMotionMath.videoFocalLength(depthFy: Double($0.fy), videoHeight: videoHeight, depthHeight: h)
        }.filter { $0 > 0 && $0.isFinite }) ?? 0
        var cell = ParallaxGeometry.cellSize(spacingPixels: settings.acrossStep, distance: zTypical,
                                             focal: focals[focals.count / 2])
        let qSpan = extent.q.upperBound - extent.q.lowerBound
        let xSpan = extent.x.upperBound - extent.x.lowerBound
        var cols = Int((qSpan / cell).rounded(.up)) + 1
        var rows = Int((xSpan / cell).rounded(.up)) + 1
        while cols * rows > TopoGridFile.maxCells {
            cell = ((cell * 1.25 - 1e-9) * 10).rounded(.up) / 10
            cols = Int((qSpan / cell).rounded(.up)) + 1
            rows = Int((xSpan / cell).rounded(.up)) + 1
        }
        let zRef: Float = heightMode ? 0 : Float(zTypical)
        var cells = MapCells(method: .cameraParallax, columns: cols, rows: rows, cell: cell,
                             qMin: extent.q.lowerBound, xMin: extent.x.lowerBound, zRef: zRef)

        let processor = ParallaxProcessor(settings: settings, width: videoWidth, height: videoHeight, sign: sign,
                                          normal: normal, acrossPerAlong: ParallaxGeometry.acrossPerAlong(frames: frames),
                                          depthWidth: w, depthHeight: h, depthFrame: { reader.frame($0) })

        // Readings → cells: the reading nearest each cell centre is kept (one reading per cell, nothing averaged).
        var added = 0
        var insideArea = 0
        var outside = OutsideArea()
        func addReadings(_ readings: [ParallaxReading]) {
            guard !readings.isEmpty else { return }
            cells.withAccumulator { acc in
                for r in readings {
                    guard r.depthV >= 0, r.depthV < h else { continue }
                    guard pixels.columns.contains(r.depthU), areaRows.contains(r.depthV) else {
                        if unlimited.columns.contains(r.depthU) {
                            outside.add(u: r.depthU, v: r.depthV, width: w, height: h)
                        }
                        continue
                    }
                    insideArea += 1
                    let value: Float
                    if let plane {
                        value = Float(plane.height(of: r.point))
                    } else if heightMode {
                        let b = baseValues[r.depthV * w + r.depthU]
                        guard b > 0, b.isFinite else { continue }
                        value = b - Float(r.point.z)
                    } else {
                        value = Float(r.point.z)
                    }
                    let q = Double(sign) * r.travel - r.point.y
                    let x = r.point.x
                    guard let idx = acc.index(q: q, x: x) else { continue }
                    let centre = (q: acc.qMin + ((q - acc.qMin) / acc.cell).rounded(.down) * acc.cell + acc.cell / 2,
                                  x: acc.xMin + ((x - acc.xMin) / acc.cell).rounded(.down) * acc.cell + acc.cell / 2)
                    acc.add(value, at: idx, score: Float(abs(q - centre.q) + abs(x - centre.x)))
                    added += 1
                }
            }
        }

        let times = frames.map(\.time)
        // A source-clock timeline is anchored at the first frame whose picture was written (design §15.7).
        let firstWritten = ParallaxGeometry.videoFrameIndices(frames).first.map { times[$0] } ?? 0
        var lastIndex = -1
        var videoPictures = 0
        try await decode(videoURL: videoURL, width: videoWidth, height: videoHeight,
                         firstSampleTime: firstWritten) { time, luma, bytesPerRow in
            videoPictures += 1
            guard let index = nearestFrame(time: time, times: times), index > lastIndex else { return }
            lastIndex = index
            let f = frames[index]
            let camera = ParallaxCamera(frame: f, videoWidth: videoWidth, videoHeight: videoHeight,
                                        depthWidth: w, depthHeight: h, lens: lens)
            let input = ParallaxProcessor.FrameInput(index: index, travel: f.travel, medianDepth: f.medianDepth,
                                                     camera: camera)
            addReadings(processor.add(input, luma: luma, bytesPerRow: bytesPerRow))
            if index % 15 == 0 { progress?(Double(index) / Double(frames.count)) }
        }
        addReadings(processor.finish())
        progress?(1)
        let counters = processor.counters
        // Every height lay outside the area: say where they were (otherwise the usual diagnosis names the cause).
        if added == 0, insideArea == 0, let message = outside.message() {
            throw LineError.configuration(message)
        }
        guard added > 0 else {
            let facts = ParallaxBuildFacts(
                videoPictures: videoPictures, recordingFrames: frames.count,
                speedReadings: frames.reduce(0) { $0 + ($1.speed == nil ? 0 : 1) },
                forwardTravel: ParallaxDiagnosis.forwardTravel(frames.map(\.travel)),
                backwardTravel: ParallaxDiagnosis.forwardTravel(frames.map { -$0.travel }),
                neededTravel: ParallaxDiagnosis.neededTravel(settings: settings, videoHeight: videoHeight,
                                                             distance: zTypical, focalY: focalY),
                distance: zTypical, frameRate: ParallaxDiagnosis.frameRate(times: times))
            throw LineError.configuration(ParallaxDiagnosis.reason(counters: counters, facts: facts,
                                                                   settings: settings))
        }

        var extraLines: [String] = []
        if let line = model.summaryLine { extraLines.append(line) }
        if let line = area.summaryLine { extraLines.append(line) }
        extraLines.append(summaryLine(counters: counters, ratio: processor.medianRatio, lens: lens != nil))
        return try TopoMapBuilder.finish(cells: cells, heightMode: heightMode, sensor: .cameraParallax,
                                         speeds: frames.map(\.speed), frameCount: frames.count,
                                         duration: frames.last?.time ?? 0, travel: TopoMapBuilder.travelRange(frames),
                                         extraLines: extraLines, folder: folder, heightReference: model.method,
                                         area: area, composite: composite) { _ in [] }
    }

    /// Heights left out only because they lay outside the area of interest, and where they lay in the portrait
    /// picture, for the message when no height is inside the area (design §17.4).
    struct OutsideArea {
        private(set) var count = 0
        private var left = Double.infinity, right = -Double.infinity
        private var top = Double.infinity, bottom = -Double.infinity

        init() {}

        /// A reading at depth pixel (u, v) of a `width` × `height` depth map.
        mutating func add(u: Int, v: Int, width: Int, height: Int) {
            guard width > 0, height > 0 else { return }
            count += 1
            let x = 1 - (Double(v) + 0.5) / Double(height)      // portrait picture, left → right
            let y = (Double(u) + 0.5) / Double(width)           // top → bottom
            left = min(left, x)
            right = max(right, x)
            top = min(top, y)
            bottom = max(bottom, y)
        }

        /// Nil when no reading was left out by the area.
        func message() -> String? {
            guard count > 0 else { return nil }
            return String(format: "No camera-parallax heights inside the area of interest: %ld heights were measured "
                          + "at %.0f–%.0f %% of the picture from the left and %.0f–%.0f %% from the top, all outside "
                          + "the area. Camera parallax measures around the middle of the picture along the travel; "
                          + "move the area's edges to include that part (Area of interest › Set area…), or pick "
                          + "Averaged or Single reading.", count, left * 100, right * 100, top * 100, bottom * 100)
        }
    }

    /// Summary line of a parallax map (a map line, replaced on rebuild).
    static func summaryLine(counters: ParallaxProcessor.Counters, ratio: Double?, lens: Bool) -> String {
        let matched = counters.patchesTried > 0
            ? 100 * Double(counters.patchesMatched) / Double(counters.patchesTried) : 0
        var line = String(format: "Camera parallax: %ld of %ld frame pairs scaled by the LiDAR, %ld points "
                          + "(%.0f %% of patches matched)", counters.pairsWithScale, counters.pairs,
                          counters.readings, matched)
        if let ratio { line += String(format: ", LiDAR scale ×%.3f of the recorded travel", ratio) }
        line += lens ? "; lens distortion corrected"
            : "; no lens calibration in this recording (heights toward the picture edges carry the lens distortion)"
        return line
    }

    /// Index of the recording frame nearest `time` (seconds), nil when none lies within 25 ms.
    static func nearestFrame(time: Double, times: [Double]) -> Int? {
        guard !times.isEmpty, time.isFinite else { return nil }
        let i = LineMath.frameIndex(for: time, inTimes: times)
        var best = i
        if i + 1 < times.count, abs(times[i + 1] - time) < abs(times[i] - time) { best = i + 1 }
        return abs(times[best] - time) <= 0.025 ? best : nil
    }

    /// Decodes Video.mov in order and hands each frame's luma plane (buffer orientation) to `body` with its time from
    /// the start of the recording (seconds). Movie time starts at the session start, which is the first recorded frame
    /// even when that frame's picture was not written. A source-clock timeline (first sample > 1 s) is shifted so its
    /// first sample is at `firstSampleTime`, the time of the first frame whose picture was written (P16-6, S1).
    private static func decode(videoURL: URL, width: Int, height: Int, firstSampleTime: Double,
                               body: (Double, UnsafeBufferPointer<UInt8>, Int) throws -> Void) async throws {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw LineError.configuration("Video.mov has no video track.")
        }
        let assetReader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ])
        output.alwaysCopiesSampleData = false
        guard assetReader.canAdd(output) else { throw LineError.configuration("Video.mov cannot be read.") }
        assetReader.add(output)
        guard assetReader.startReading() else {
            throw LineError.configuration("Video.mov cannot be read (\(assetReader.error?.localizedDescription ?? "unknown error")).")
        }
        defer { if assetReader.status == .reading { assetReader.cancelReading() } }
        var offset: Double?
        var finished = false
        while !finished {
            // One pool per frame: AVFoundation's per-sample objects are released as the decode goes (P16-5).
            try autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else {
                    finished = true
                    return
                }
                // The anchor comes from the first buffer that carries a frame, before any image check (T1).
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard pts.isFinite, CMSampleBufferGetNumSamples(sample) > 0 else { return }
                if offset == nil { offset = pts <= 1 ? 0 : pts - firstSampleTime }
                let time = pts - (offset ?? 0)
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
                CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
                guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
                      CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) == width,
                      CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) == height,
                      let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
                    throw LineError.configuration(String(format: "Video.mov frames are not %ld × %ld like the "
                                                         + "recording.", width, height))
                }
                let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                let luma = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self),
                                               count: bytesPerRow * height)
                try body(time, luma, bytesPerRow)
            }
        }
        if assetReader.status == .failed {
            throw LineError.configuration("Video.mov could not be decoded (\(assetReader.error?.localizedDescription ?? "unknown error")).")
        }
    }
}
