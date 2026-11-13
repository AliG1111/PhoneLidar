import SwiftUI
import Charts
import UIKit

/// Topographic map of a line recording with variance statistics and profiles.
struct TopoMapView: View {
    let folder: URL

    @Environment(ScanStore.self) private var store
    @State private var stats: TopoStats?
    @State private var profiles: TopoProfiles?
    @State private var mapImage: UIImage?
    @State private var direction: TravelDirection = .rightToLeft
    /// Method chosen in the picker for the next rebuild (nil = the method of the map on screen).
    @State private var methodChoice: MapMethod?
    /// Method chosen when the recording was made.
    @State private var recordedMethod: MapMethod = .averaged
    @State private var loaded = false
    @State private var building = false
    /// Progress of a camera-parallax build (0…1), nil otherwise.
    @State private var buildProgress: Double?
    /// Last rebuild failure; shown even when an older map is still on screen.
    @State private var message: String?

    var body: some View {
        List {
            Section {
                if let message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if building {
                    HStack {
                        if let buildProgress {
                            ProgressView(value: buildProgress)
                                .frame(width: 80)
                            Text(String(format: "Measuring camera parallax… %.0f %%", buildProgress * 100))
                        } else {
                            ProgressView()
                            Text("Building topographic map…")
                        }
                    }
                }
                if let mapImage {
                    ZoomableImage(image: mapImage)
                        .frame(height: 280)
                        .listRowInsets(EdgeInsets())
                    if let stats {
                        if stats.heightMode == true {
                            DepthLegend(lowHeight: Float(stats.colorFar), highHeight: Float(stats.colorNear))
                        } else {
                            DepthLegend(near: Float(stats.colorNear), far: Float(stats.colorFar))
                        }
                    }
                    Label(direction == .rightToLeft
                          ? "Material travelled right → left; leading edge at the left. Pinch to zoom."
                          : "Material travelled left → right; leading edge at the right. Pinch to zoom.",
                          systemImage: direction == .rightToLeft ? "arrow.left" : "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !building {
                    Text(loaded ? "Map not built yet. Tap Rebuild map." : "Loading…")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(heightMode
                     ? "Topographic map (height above \(referenceName): dark blue = lowest, dark red = highest)"
                     : "Topographic map (dark blue = farthest, dark red = closest)")
            }

            if let stats {
                Section(heightMode ? "Surface height above \(referenceName)" : "Surface distance from camera") {
                    row("Mean", "%.2f mm", stats.mean)
                    row("Standard deviation", "%.3f mm", stats.stdDev)
                    row("Variance", "%.3f mm²", stats.variance)
                    if !heightMode {
                        row("Coefficient of variation", stats.cvPercent.map { String(format: "%.3f %%", $0) } ?? "—")
                    }
                    row(heightMode ? "Minimum (lowest)" : "Minimum (closest)", "%.1f mm", stats.minimum)
                    row(heightMode ? "Maximum (highest)" : "Maximum (farthest)", "%.1f mm", stats.maximum)
                    row("Range", "%.1f mm", stats.range)
                    row("P1 / P99", String(format: "%.1f / %.1f mm", stats.p1, stats.p99))
                    row("P5 / median / P95", String(format: "%.1f / %.1f / %.1f mm", stats.p5, stats.median, stats.p95))
                }
                Section {
                    row("Across-width profile std dev", "%.3f mm", stats.acrossStdDev)
                    row("Across-width profile range", "%.2f mm", stats.acrossRange)
                    row("Along-travel profile std dev", "%.3f mm", stats.alongStdDev)
                    row("Along-travel profile range", "%.2f mm", stats.alongRange)
                    row("Local residual std dev", "%.3f mm", stats.residualStdDev)
                    if stats.isSingleReading {
                        row("Repeat-reading noise (std dev)", "—")
                    } else {
                        row("Repeat-reading noise (std dev)", "%.3f mm", stats.repeatStdDev)
                    }
                } header: {
                    Text("Variation components")
                } footer: {
                    Text("Across = lane-to-lane differences. Along = waves in the travel direction. "
                         + "Residual = what remains after removing both. Repeat-reading noise = scatter of the "
                         + "readings that landed in the same cell (none for a single-reading map).")
                }
                if let profiles, profiles.across.count >= 2 {
                    Section(heightMode ? "Across-width profile (height above \(referenceName))"
                                       : "Across-width profile (up = closer to camera)") {
                        ProfileChart(points: profiles.across, xLabel: "Across (mm)", heightMode: heightMode,
                                     aboveBelt: stats.heightAboveBelt)
                            .frame(height: 180)
                    }
                }
                if let profiles, profiles.along.count >= 2 {
                    Section(heightMode ? "Along-travel profile (height above \(referenceName))"
                                       : "Along-travel profile (up = closer to camera)") {
                        ProfileChart(points: Self.thinned(profiles.along, to: 800), xLabel: "Along (mm)",
                                     heightMode: heightMode, aboveBelt: stats.heightAboveBelt)
                            .frame(height: 180)
                    }
                }
                Section("Speed") {
                    if let mean = stats.speedMean {
                        row("Mean", String(format: "%.1f mm/s  (%.2f m/min)", mean, mean * 0.06))
                    }
                    if let sd = stats.speedStdDev { row("Std dev", "%.2f mm/s", sd) }
                    if let lo = stats.speedMin, let hi = stats.speedMax {
                        row("Min / max", String(format: "%.0f / %.0f mm/s", lo, hi))
                    }
                    row("Frames with texture lock", "%.0f %%", stats.speedTrackedPercent)
                }
                Section("Scan") {
                    row("Length × width", String(format: "%.2f × %.2f m", stats.lengthMM / 1000, stats.widthMM / 1000))
                    row("Cell size", TopoMapBuilder.cellText(stats.cellSize) + " mm")
                    row("Coverage", "%.1f %%", stats.coveragePercent)
                    row("Map method", (stats.mapMethod ?? .averaged).label)
                    row("Readings per cell", "%.1f", stats.meanHitsPerCell)
                    row("Frames / duration", String(format: "%ld / %.1f s", stats.frames, stats.duration))
                }
            }

            Section {
                Picker("Map method", selection: Binding(
                    get: { methodChoice ?? stats?.mapMethod ?? recordedMethod },
                    set: { methodChoice = $0 })) {
                    ForEach(MapMethod.allCases) { method in
                        Text(method == .singleReading ? "Single reading" : method.shortLabel).tag(method)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(building)
                Button {
                    rebuild()
                } label: {
                    Label("Rebuild map", systemImage: "arrow.clockwise")
                }
                .disabled(building)
            } footer: {
                Text(footerText)
            }
        }
        .navigationTitle("Topographic map")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var heightMode: Bool { stats?.heightMode == true }

    /// What the heights are measured from, for titles.
    private var referenceName: String {
        stats?.heightAboveBelt == true ? "the belt" : "baseline"
    }

    private var footerText: String {
        let files = "TopoMap.png, TopoMap.csv, TopoStats.csv and the profile CSV files are in the scan's file list."
        let method = "Averaged: the mean of every LiDAR reading in the cell. Single reading: each cell holds one "
            + "LiDAR reading, nothing is averaged (the reading taken closest to the scan line, ScanLineProfiles.csv). "
            + "Camera parallax: heights from how far each patch of the surface moved in the video, scaled by the "
            + "LiDAR; one reading per cell. "
        let values: String
        switch stats?.heightReference {
        case .cameraHeight?:
            values = "Values are heights above the belt from the camera height and the phone tilt "
                + "(HeightReference.json). "
        case .sideWalls?:
            values = "Values are heights above the belt from the side-wall tops (HeightReference.json). "
        default:
            values = heightMode
                ? "Values are heights above the flat-surface baseline saved with this recording (Baseline.bin). "
                : "No height reference was saved with this recording, so values are distances from the camera. "
        }
        return method + values + files
    }

    private func row(_ title: String, _ format: String, _ value: Double) -> some View {
        row(title, String(format: format, value))
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).monospacedDigit()
        }
    }

    private struct Loaded {
        var direction: TravelDirection?
        var recordedMethod: MapMethod?
        var stats: TopoStats?
        var profiles: TopoProfiles?
        var image: UIImage?
    }

    /// Reads the saved map files off the main thread.
    private func load() async {
        let folder = self.folder
        let result = await Task.detached(priority: .userInitiated) { () -> Loaded in
            var out = Loaded()
            // Only the direction is needed here: a cut-off file is repaired in memory (Rebuild map repairs it on
            // disk and notes that in the summary).
            if let data = try? Data(contentsOf: folder.appendingPathComponent("Recording.json")),
               let info = (try? JSONDecoder.iso.decode(LineRecordingInfo.self, from: data))
                ?? LineRecordingRepair.repairedData(data).flatMap({
                    try? JSONDecoder.iso.decode(LineRecordingInfo.self, from: $0)
                }) {
                out.direction = info.direction
                out.recordedMethod = info.mapMethod ?? .averaged
            }
            if let data = try? Data(contentsOf: folder.appendingPathComponent("TopoStats.json")) {
                out.stats = try? JSONDecoder.iso.decode(TopoStats.self, from: data)
            }
            if let data = try? Data(contentsOf: folder.appendingPathComponent("TopoProfiles.json")) {
                out.profiles = try? JSONDecoder().decode(TopoProfiles.self, from: data)
            }
            out.image = UIImage(contentsOfFile: folder.appendingPathComponent("TopoMapGrid.png").path)
            return out
        }.value
        if let value = result.direction { direction = value }
        if let value = result.recordedMethod { recordedMethod = value }
        stats = result.stats
        profiles = result.profiles
        mapImage = result.image
        loaded = true
    }

    private func rebuild() {
        guard !building else { return }
        building = true
        message = nil
        let folder = self.folder
        let method = methodChoice ?? stats?.mapMethod ?? recordedMethod
        buildProgress = method == .cameraParallax ? 0 : nil
        let report: @Sendable (Double) -> Void = { value in
            Task { @MainActor in
                if building { buildProgress = value }
            }
        }
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                () async -> Result<(recording: MapRecording, output: TopoMapBuilder.Output), Error> in
                do {
                    guard let recording = try? MapRebuild.load(folder: folder) else {
                        throw RebuildError.recordingMissing
                    }
                    // TopoMap.png is rendered here, off the main thread, and staged with the other files.
                    let output = try await MapRebuild.build(folder: folder, recording: recording, method: method,
                                                            progress: report)
                    return .success((recording: recording, output: output))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let built):
                message = updateScanRecord(recording: built.recording, mapSummary: built.output.summary)
                methodChoice = nil
            case .failure(let error):
                message = "Map not rebuilt: \(error.localizedDescription)"
            }
            await load()
            building = false
            buildProgress = nil
        }
    }

    /// New and replaced files appear in the scan's file list and the summary shows the new statistics.
    /// Returns a message when the scan record could not be saved, nil otherwise.
    private func updateScanRecord(recording: MapRecording, mapSummary: [String]) -> String? {
        let target = folder.standardizedFileURL.path
        guard var record = store.scans.first(where: { store.folderURL(for: $0).standardizedFileURL.path == target })
        else { return nil }
        record.summary = recording.recordSummary(existing: record.summary, map: mapSummary)
        do {
            try store.save(record)
            return nil
        } catch {
            return "Map rebuilt, but the scan summary was not updated: \(error.localizedDescription)"
        }
    }

    private enum RebuildError: LocalizedError {
        case recordingMissing

        var errorDescription: String? { "The recording file (Recording.json) is missing or damaged." }
    }

    private static func thinned(_ points: [ProfilePoint], to limit: Int) -> [ProfilePoint] {
        guard points.count > limit, limit > 0 else { return points }
        let step = Int((Double(points.count) / Double(limit)).rounded(.up))
        return stride(from: 0, to: points.count, by: step).map { points[$0] }
    }
}

/// Line chart of a profile with the distance axis reversed (higher = closer to the camera).
struct ProfileChart: View {
    let points: [ProfilePoint]
    let xLabel: String
    var heightMode = false
    /// Heights above the belt (camera height or side walls) rather than above the baseline.
    var aboveBelt = false

    var body: some View {
        Chart(points) { point in
            LineMark(x: .value(xLabel, point.position),
                     y: .value(heightMode ? "Height (mm)" : "Distance (mm)", point.value))
                .interpolationMethod(.linear)
        }
        .chartYScale(domain: .automatic(includesZero: false, reversed: !heightMode))
        .chartXAxisLabel { Text(xLabel) }
        .chartYAxisLabel {
            Text(heightMode ? (aboveBelt ? "Height above the belt (mm)" : "Height above baseline (mm)") : "Distance (mm)")
        }
    }
}

/// Pinch-to-zoom, scrollable image. Starts fitted to the view's height.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomScrollView {
        ZoomScrollView(image: image)
    }

    func updateUIView(_ uiView: ZoomScrollView, context: Context) {
        if uiView.imageView.image !== image {
            uiView.imageView.image = image
            uiView.resetLayout()
        }
    }

    final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
        let imageView = UIImageView()
        private var laidOutSize: CGSize = .zero

        init(image: UIImage) {
            super.init(frame: .zero)
            delegate = self
            backgroundColor = UIColor(white: 0.85, alpha: 1)
            showsHorizontalScrollIndicator = true
            showsVerticalScrollIndicator = true
            bouncesZoom = true
            imageView.image = image
            imageView.layer.magnificationFilter = .nearest
            addSubview(imageView)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func resetLayout() {
            laidOutSize = .zero
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let image = imageView.image, image.size.width > 0, image.size.height > 0,
                  bounds.width > 0, bounds.height > 0 else { return }
            if bounds.size != laidOutSize {
                laidOutSize = bounds.size
                zoomScale = 1
                // Fit the height (scroll along the length); fall back to fitting the width for short maps.
                var scale = bounds.height / image.size.height
                if image.size.width * scale < bounds.width {
                    scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
                }
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                imageView.frame = CGRect(origin: .zero, size: size)
                contentSize = size
                minimumZoomScale = min(1, bounds.width / size.width)
                maximumZoomScale = 20
            }
            let insetX = max(0, (bounds.width - contentSize.width) / 2)
            let insetY = max(0, (bounds.height - contentSize.height) / 2)
            contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }
    }
}
