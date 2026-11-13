import Foundation
import AVFoundation
import CoreGraphics
import simd

/// Builds a camera-parallax map (design §15): decodes Video.mov, measures heights with `ParallaxProcessor` and
/// finishes the map files with `TopoMapBuilder.finish`. Runs off the main thread.
enum ParallaxMapBuilder {
    static func build(folder: URL, info: LineRecordingInfo, composite: ((CGImage, TopoStats) throws -> Data)?,
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
        let columns = model.columns(width: w, border: border)
        let lens = info.lens.flatMap { $0.isValid ? $0 : nil }
        let normal = ParallaxGeometry.beltNormal(frames: frames,
                                                 reference: model.reference ?? HeightReference.load(from: folder))
        let settings = ParallaxSettings()

        // Grid: the LiDAR maps' extent, cells of the patch spacing at the typical distance.
        guard let extent = TopoMapBuilder.extent(frames: frames, width: w, height: h, border: border,
                                                 sign: Double(sign), typicalDepth: zTypical) else {
            throw LineError.notEnoughData
        }
        let focals = frames.map { Double($0.fx) * Double(videoWidth) / Double(w) }.filter { $0 > 0 }.sorted()
        guard !focals.isEmpty else { throw LineError.notEnoughData }
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
        func addReadings(_ readings: [ParallaxReading]) {
            guard !readings.isEmpty else { return }
            cells.withAccumulator { acc in
                for r in readings {
                    guard columns.contains(r.depthU), r.depthV >= 0, r.depthV < h else { continue }
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
        var lastIndex = -1
        try await decode(videoURL: videoURL, width: videoWidth, height: videoHeight) { time, luma, bytesPerRow in
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
        guard added > 0 else {
            throw LineError.configuration(Self.noReadingsReason(counters))
        }

        var extraLines: [String] = []
        if let line = model.summaryLine { extraLines.append(line) }
        extraLines.append(summaryLine(counters: counters, ratio: processor.medianRatio, lens: lens != nil))
        return try TopoMapBuilder.finish(cells: cells, heightMode: heightMode, sensor: .cameraParallax,
                                         speeds: frames.map(\.speed), frameCount: frames.count,
                                         duration: frames.last?.time ?? 0, travel: TopoMapBuilder.travelRange(frames),
                                         extraLines: extraLines, folder: folder, heightReference: model.method,
                                         composite: composite) { _ in [] }
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

    static func noReadingsReason(_ c: ParallaxProcessor.Counters) -> String {
        if c.pairs == 0 {
            return "No camera-parallax heights: the material did not move a third of the picture between frames "
                + "(no travel, or the video does not match the recording)."
        }
        if c.patchesMatched == 0 {
            return "No camera-parallax heights: the surface texture could not be matched between frames. Use the "
                + "short shutter, add light, and keep the phone still."
        }
        return "No camera-parallax heights: no frame pair had enough LiDAR readings for its scale."
    }

    /// Index of the recording frame nearest `time` (seconds), nil when none lies within 25 ms.
    static func nearestFrame(time: Double, times: [Double]) -> Int? {
        guard !times.isEmpty, time.isFinite else { return nil }
        let i = LineMath.frameIndex(for: time, inTimes: times)
        var best = i
        if i + 1 < times.count, abs(times[i + 1] - time) < abs(times[i] - time) { best = i + 1 }
        return abs(times[best] - time) <= 0.025 ? best : nil
    }

    /// Decodes Video.mov in order and hands each frame's luma plane (buffer orientation) to `body` with its time
    /// from the start of the recording (seconds).
    private static func decode(videoURL: URL, width: Int, height: Int,
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
        var firstTime: Double?
        while let sample = output.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite else { continue }
            // Movie time normally starts at the first recorded frame; a source-clock timeline is shifted to it.
            if firstTime == nil { firstTime = pts > 1 ? pts : 0 }
            let time = pts - (firstTime ?? 0)
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
                  CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) == width,
                  CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) == height,
                  let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
                throw LineError.configuration(String(format: "Video.mov frames are not %ld × %ld like the recording.",
                                                     width, height))
            }
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let luma = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self),
                                           count: bytesPerRow * height)
            try body(time, luma, bytesPerRow)
        }
        if assetReader.status == .failed {
            throw LineError.configuration("Video.mov could not be decoded (\(assetReader.error?.localizedDescription ?? "unknown error")).")
        }
    }
}
