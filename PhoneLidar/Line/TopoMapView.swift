import SwiftUI
import Charts
import UIKit

/// Topographic map of a line recording with variance statistics and profiles.
struct TopoMapView: View {
    let folder: URL

    @State private var stats: TopoStats?
    @State private var profiles: TopoProfiles?
    @State private var mapImage: UIImage?
    @State private var direction: TravelDirection = .rightToLeft
    @State private var building = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
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
                } else if building {
                    HStack {
                        ProgressView()
                        Text("Building topographic map…")
                    }
                } else {
                    Text(message ?? "No map yet.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(heightMode
                     ? "Topographic map (height above baseline: dark blue = lowest, dark red = highest)"
                     : "Topographic map (dark blue = farthest, dark red = closest)")
            }

            if let stats {
                Section(heightMode ? "Surface height above baseline" : "Surface distance from camera") {
                    row("Mean", "%.2f mm", stats.mean)
                    row("Standard deviation", "%.3f mm", stats.stdDev)
                    row("Variance", "%.3f mm²", stats.variance)
                    if !heightMode {
                        row("Coefficient of variation", "%.3f %%", stats.cvPercent)
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
                    row("Repeat-reading noise (std dev)", "%.3f mm", stats.repeatStdDev)
                } header: {
                    Text("Variation components")
                } footer: {
                    Text("Across = lane-to-lane differences. Along = waves in the travel direction. "
                         + "Residual = what remains after removing both. Repeat-reading noise = scatter of the "
                         + "LiDAR readings that landed in the same cell.")
                }
                if let profiles, profiles.across.count >= 2 {
                    Section(heightMode ? "Across-width profile (height above baseline)"
                                       : "Across-width profile (up = closer to camera)") {
                        ProfileChart(points: profiles.across, xLabel: "Across (mm)", heightMode: heightMode)
                            .frame(height: 180)
                    }
                }
                if let profiles, profiles.along.count >= 2 {
                    Section(heightMode ? "Along-travel profile (height above baseline)"
                                       : "Along-travel profile (up = closer to camera)") {
                        ProfileChart(points: Self.thinned(profiles.along, to: 800), xLabel: "Along (mm)",
                                     heightMode: heightMode)
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
                    row("Cell size", "%.0f mm", stats.cellSize)
                    row("Coverage", "%.1f %%", stats.coveragePercent)
                    row("Readings per cell", "%.1f", stats.meanHitsPerCell)
                    row("Frames / duration", String(format: "%ld / %.1f s", stats.frames, stats.duration))
                }
            }

            Section {
                Button {
                    rebuild()
                } label: {
                    Label("Rebuild map", systemImage: "arrow.clockwise")
                }
                .disabled(building)
            } footer: {
                Text(heightMode
                     ? "Values are heights above the flat-surface baseline saved with this recording (Baseline.bin). TopoMap.png, TopoMap.csv, TopoStats.csv and the profile CSV files are in the scan's file list."
                     : "No baseline was saved with this recording, so values are distances from the camera. TopoMap.png, TopoMap.csv, TopoStats.csv and the profile CSV files are in the scan's file list.")
            }
        }
        .navigationTitle("Topographic map")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
    }

    private var heightMode: Bool { stats?.heightMode == true }

    private func row(_ title: String, _ format: String, _ value: Double) -> some View {
        row(title, String(format: format, value))
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).monospacedDigit()
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: folder.appendingPathComponent("Recording.json")),
           let info = try? JSONDecoder.iso.decode(LineRecordingInfo.self, from: data) {
            direction = info.direction
        }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("TopoStats.json")) {
            stats = try? JSONDecoder.iso.decode(TopoStats.self, from: data)
        }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("TopoProfiles.json")) {
            profiles = try? JSONDecoder().decode(TopoProfiles.self, from: data)
        }
        mapImage = UIImage(contentsOfFile: folder.appendingPathComponent("TopoMapGrid.png").path)
        if mapImage == nil && message == nil {
            message = "Map not built yet. Tap Rebuild map."
        }
    }

    private func rebuild() {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("Recording.json")),
              let info = try? JSONDecoder.iso.decode(LineRecordingInfo.self, from: data) else {
            message = "Recording.json is missing."
            return
        }
        building = true
        mapImage = nil
        let folder = self.folder
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<TopoMapBuilder.Output, Error> in
                do {
                    return .success(try TopoMapBuilder.build(folder: folder, info: info))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let output):
                TopoMapRenderer.writeComposite(map: output.mapImage, stats: output.stats, direction: info.direction,
                                               to: folder.appendingPathComponent("TopoMap.png"))
                message = nil
            case .failure(let error):
                message = "Map not built: \(error.localizedDescription)"
            }
            building = false
            load()
        }
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

    var body: some View {
        Chart(points) { point in
            LineMark(x: .value(xLabel, point.position),
                     y: .value(heightMode ? "Height (mm)" : "Distance (mm)", point.value))
                .interpolationMethod(.linear)
        }
        .chartYScale(domain: .automatic(includesZero: false, reversed: !heightMode))
        .chartXAxisLabel { Text(xLabel) }
        .chartYAxisLabel { Text(heightMode ? "Height above baseline (mm)" : "Distance (mm)") }
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
