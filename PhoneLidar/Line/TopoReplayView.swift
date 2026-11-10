import SwiftUI
import SceneKit
import UIKit

/// Real-time topographic replay of a line recording: the map builds up line by line at the recorded speed
/// (or faster / slower) as a scrolling 3D strip, with the newest line at the right.
struct TopoReplayView: View {
    let folder: URL
    let title: String
    let created: Date?

    @Environment(ScanStore.self) private var store
    @State private var model: TopoReplayModel?
    @State private var status = "Loading recording…"
    @State private var failure: String?
    /// False once the screen has gone away: a replay that finishes loading afterwards is not started.
    @State private var visible = false

    var body: some View {
        Group {
            if let model {
                TopoReplayContent(model: model, filesChanged: refreshFileList)
            } else if let failure {
                ContentUnavailableView("Cannot replay this recording", systemImage: "exclamationmark.triangle",
                                       description: Text(failure))
            } else {
                ProgressView(status)
            }
        }
        .navigationTitle("Topographic replay")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
        .onAppear {
            visible = true
            OrientationLock.allow(.allButUpsideDown, rotateTo: .landscapeRight)
            model?.start()
        }
        .onDisappear {
            visible = false
            model?.stop()
            OrientationLock.allow(.portrait, rotateTo: .portrait)
        }
    }

    /// New files (TopoGrid.bin, saved images) appear in the scan's file list.
    private func refreshFileList() {
        let target = folder.standardizedFileURL.path
        if let record = store.scans.first(where: { store.folderURL(for: $0).standardizedFileURL.path == target }) {
            try? store.save(record)
        }
    }

    private struct Opened {
        var info: LineRecordingInfo
        var grid: TopoGridFile?
    }

    private struct Prepared {
        var source: TopoReplaySource
        var grid: TopoDisplayGrid
    }

    private enum LoadError: LocalizedError {
        case recording
        case build(String)

        var errorDescription: String? {
            switch self {
            case .recording: return "Recording.json is missing or damaged."
            case .build(let reason): return "The topographic map could not be built: \(reason)"
            }
        }
    }

    /// Reads, builds (once, for old recordings) and prepares everything off the main thread. The grid file is
    /// read once and handed on. Nothing is started if the screen went away meanwhile.
    private func load() async {
        guard model == nil, failure == nil else { return }
        let folder = self.folder
        let opened = await Task.detached(priority: .userInitiated) { () -> Opened? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("Recording.json")),
                  let info = try? JSONDecoder.iso.decode(LineRecordingInfo.self, from: data) else { return nil }
            return Opened(info: info, grid: TopoGridFile.load(from: folder))
        }.value
        guard !Task.isCancelled else { return }
        guard let opened else {
            failure = LoadError.recording.localizedDescription
            return
        }
        let info = opened.info
        var gridFile = opened.grid
        if gridFile == nil {
            // Recordings made before the replay existed: build the map once (this also writes TopoGrid.bin).
            status = "Building the topographic grid…"
            let built = await Task.detached(priority: .userInitiated) { () -> Result<TopoMapBuilder.Output, Error> in
                do {
                    return .success(try TopoMapBuilder.build(folder: folder, info: info))
                } catch {
                    return .failure(error)
                }
            }.value
            switch built {
            case .success(let output):
                // The files are written whether or not the screen is still open; keep the set complete.
                TopoMapRenderer.writeComposite(map: output.mapImage, stats: output.stats, direction: info.direction,
                                               to: folder.appendingPathComponent("TopoMap.png"))
                refreshFileList()
                gridFile = output.grid
            case .failure(let error):
                failure = LoadError.build(error.localizedDescription).localizedDescription
                return
            }
            guard !Task.isCancelled else { return }
        }
        guard let grid = gridFile else { return }
        status = "Preparing replay…"
        let result = await Task.detached(priority: .userInitiated) { () -> Result<Prepared, Error> in
            do {
                let source = try TopoReplaySource.make(grid: grid, info: info)
                let factor = TopoReplayModel.displayFactor(
                    source: source, lengthMM: source.widthMM * TopoReplayModel.defaultLengthFactor)
                return .success(Prepared(source: source, grid: TopoDisplayGrid.make(source: source, factor: factor)))
            } catch {
                return .failure(error)
            }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let prepared):
            let replay = TopoReplayModel(folder: folder, title: title, created: created, source: prepared.source,
                                         grid: prepared.grid)
            model = replay
            if visible {
                replay.start()
                replay.togglePlay()
            }
        case .failure(let error):
            failure = error.localizedDescription
        }
    }
}

// MARK: - Content

private struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct TopoReplayContent: View {
    @Bindable var model: TopoReplayModel
    let filesChanged: @MainActor () -> Void
    @State private var showSettings = false
    @State private var shareFile: ShareFile?

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width > geometry.size.height {
                landscape(geometry.size)
            } else {
                portrait(geometry.size)
            }
        }
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    if let url = model.saveImage() {
                        filesChanged()
                        shareFile = ShareFile(url: url)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel("Save image")
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Replay settings")
            }
        }
        .sheet(isPresented: $showSettings) {
            ReplaySettingsView(model: model)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $shareFile) { file in
            ActivityView(items: [file.url])
        }
    }

    // MARK: Layouts

    private func landscape(_ size: CGSize) -> some View {
        VStack(spacing: 3) {
            header
            HStack(alignment: .top, spacing: 6) {
                VStack(spacing: 2) {
                    sceneView
                    AlongChart(model: model)
                        .frame(height: 46)
                    ColorBar(model: model)
                        .frame(height: 34)
                }
                AcrossPanel(model: model, vertical: true)
                    .frame(width: min(180, size.width * 0.19))
            }
            transportRow
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    private func portrait(_ size: CGSize) -> some View {
        VStack(spacing: 6) {
            header
            sceneView
                .frame(height: size.height * 0.40)
            AlongChart(model: model)
                .frame(height: 58)
            ColorBar(model: model)
                .frame(height: 36)
            AcrossPanel(model: model, vertical: false)
                .frame(maxHeight: .infinity)
            VStack(spacing: 6) {
                buttonsRow
                timeRow
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    private var sceneView: some View {
        ReplaySceneView(model: model)
            .overlay(alignment: .topTrailing) {
                Text(model.mode == .map ? "Map · newest line ▍" : "Strip + newest line")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(4)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                Text(String(format: "window %.2f m  ·  drag to tilt, pinch to zoom, double-tap to reset",
                            model.stripLengthMM / 1000))
                    .font(.system(size: 9))
                    .foregroundStyle(.gray)
                    .padding(4)
                    .allowsHitTesting(false)
            }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(model.title) — \(model.valueName.lowercased())")
                .font(.caption.weight(.bold))
                .foregroundStyle(.black)
                .lineLimit(1)
            Text(model.timeText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color(red: 0.1, green: 0.35, blue: 0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(model.statsText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.gray)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Transport

    private var transportRow: some View {
        HStack(spacing: 10) {
            transportButtons
            speedMenu
            timeSlider
            modePicker
                .frame(width: 110)
        }
        .frame(height: 34)
    }

    private var buttonsRow: some View {
        HStack(spacing: 12) {
            transportButtons
            Spacer(minLength: 4)
            speedMenu
            modePicker
                .frame(width: 110)
        }
    }

    private var timeRow: some View {
        timeSlider
    }

    private var transportButtons: some View {
        HStack(spacing: 14) {
            Button {
                model.restart()
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .accessibilityLabel("Restart")
            Button {
                model.step(-1)
            } label: {
                Image(systemName: "backward.frame.fill")
            }
            .accessibilityLabel("Step back one frame")
            Button {
                model.togglePlay()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 30)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            Button {
                model.step(1)
            } label: {
                Image(systemName: "forward.frame.fill")
            }
            .accessibilityLabel("Step forward one frame")
        }
        .font(.callout)
    }

    private var speedMenu: some View {
        Menu {
            ForEach(TopoReplayModel.speedPresets, id: \.self) { value in
                Button {
                    model.setSpeed(value)
                } label: {
                    if abs(model.speed - value) < 1e-6 {
                        Label(Self.speedText(value) + (value == 1 ? "  real time" : ""), systemImage: "checkmark")
                    } else {
                        Text(Self.speedText(value) + (value == 1 ? "  real time" : ""))
                    }
                }
            }
        } label: {
            Label(Self.speedText(model.speed), systemImage: "speedometer")
                .font(.callout.monospacedDigit())
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityLabel("Replay speed")
    }

    private var timeSlider: some View {
        HStack(spacing: 6) {
            Slider(value: Binding(get: { model.time }, set: { model.seek(to: $0) }),
                   in: 0...max(model.duration, 0.01))
            Text(String(format: "%.1f / %.1f s", model.time, model.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.black)
                .fixedSize()
        }
    }

    private var modePicker: some View {
        Picker("View", selection: $model.mode) {
            ForEach(TopoReplayModel.Mode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    static func speedText(_ value: Double) -> String {
        if value >= 1, value.rounded() == value { return String(format: "%.0f×", value) }
        if value >= 1 { return String(format: "%.1f×", value) }
        return String(format: "%.2g×", value)
    }
}

// MARK: - 3D view

private struct ReplaySceneView: UIViewRepresentable {
    let model: TopoReplayModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> ReplaySCNView {
        let view = ReplaySCNView(frame: .zero)
        view.scene = model.sceneContent.scene
        view.pointOfView = model.sceneContent.cameraNode
        view.backgroundColor = .white
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.rendersContinuously = false
        view.preferredFramesPerSecond = 60
        let model = self.model
        view.onResize = { size in
            guard size.width > 0, size.height > 0 else { return }
            model.viewAspect = Double(size.width / size.height)
        }
        let coordinator = context.coordinator
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinched(_:)))
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.panned(_:)))
        pan.maximumNumberOfTouches = 1
        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(doubleTap)
        model.scnView = view
        return view
    }

    func updateUIView(_ uiView: ReplaySCNView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject {
        let model: TopoReplayModel
        private var startZoom = 1.0
        private var startElevation = 0.0
        private var startShear = 0.0

        init(model: TopoReplayModel) {
            self.model = model
        }

        @objc func pinched(_ recognizer: UIPinchGestureRecognizer) {
            if recognizer.state == .began { startZoom = model.zoom }
            model.zoom = min(max(startZoom * Double(recognizer.scale), 0.5), 8)
        }

        @objc func panned(_ recognizer: UIPanGestureRecognizer) {
            guard model.mode == .threeD, let view = recognizer.view, view.bounds.width > 0 else { return }
            if recognizer.state == .began {
                startElevation = model.elevation
                startShear = model.shear
            }
            let move = recognizer.translation(in: view)
            model.shear = min(max(startShear + Double(move.x / view.bounds.width) * 1.6, -1.2), 1.2)
            model.elevation = min(max(startElevation + Double(move.y / view.bounds.height) * 80, 5), 90)
        }

        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            model.resetView()
        }
    }
}

final class ReplaySCNView: SCNView {
    var onResize: (@MainActor (CGSize) -> Void)?
    private var reportedSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != reportedSize {
            reportedSize = bounds.size
            onResize?(bounds.size)
        }
    }
}

// MARK: - Charts

/// Mean height of every visible line along the window (newest at the right), with the tolerance band.
private struct AlongChart: View {
    let model: TopoReplayModel

    var body: some View {
        let points = model.alongPoints
        let ticks = model.timeTicks
        let target = model.target
        let tolerance = max(model.tolerance, 1e-6)
        let digits = ReplayNumbers.decimals(for: model.valueStep)
        Canvas { context, size in
            let left: CGFloat = 40
            let bottom: CGFloat = 12
            let plot = CGRect(x: left, y: 2, width: max(size.width - left - 4, 1), height: max(size.height - bottom - 4, 1))
            let lo = target - 3 * tolerance
            let hi = target + 3 * tolerance
            func y(_ v: Double) -> CGFloat {
                plot.maxY - plot.height * CGFloat(min(max((v - lo) / (hi - lo), 0), 1))
            }
            var axis = Path()
            axis.move(to: CGPoint(x: plot.minX, y: plot.maxY + 1))
            axis.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY + 1))
            context.stroke(axis, with: .color(.gray.opacity(0.6)), lineWidth: 1)
            for v in [target - tolerance, target + tolerance] {
                var band = Path()
                band.move(to: CGPoint(x: plot.minX, y: y(v)))
                band.addLine(to: CGPoint(x: plot.maxX, y: y(v)))
                context.stroke(band, with: .color(Color(red: 0.55, green: 0.85, blue: 0.5)), lineWidth: 1)
                context.draw(Text(ReplayNumbers.text(v, decimals: digits)).font(.system(size: 8)).foregroundStyle(.gray),
                             at: CGPoint(x: left - 4, y: y(v)), anchor: .trailing)
            }
            if points.count >= 2 {
                var line = Path()
                for (i, p) in points.enumerated() {
                    let q = CGPoint(x: plot.minX + plot.width * CGFloat(p.x), y: y(Double(p.y)))
                    if i == 0 { line.move(to: q) } else { line.addLine(to: q) }
                }
                context.stroke(line, with: .color(Color(red: 0.25, green: 0.55, blue: 0.25)), lineWidth: 1.3)
            }
            for tick in ticks {
                let x = plot.minX + plot.width * CGFloat(tick.position)
                let anchor: UnitPoint = tick.position <= 0 ? .topLeading : (tick.position >= 1 ? .topTrailing : .top)
                context.draw(Text(tick.label).font(.system(size: 8).monospacedDigit()).foregroundStyle(.gray),
                             at: CGPoint(x: x, y: plot.maxY + 2), anchor: anchor)
            }
            context.draw(Text("line avg").font(.system(size: 8)).foregroundStyle(.gray),
                         at: CGPoint(x: 2, y: plot.minY), anchor: .topLeading)
        }
    }
}

/// Across-width profile: newest line (red) and the last second's average (grey dashed), with target and tolerance.
private struct AcrossPanel: View {
    let model: TopoReplayModel
    let vertical: Bool

    var body: some View {
        let newest = model.newestProfile
        let average = model.averageProfile
        let fractions = model.acrossFractions
        let target = model.target
        let tolerance = max(model.tolerance, 1e-6)
        let digits = ReplayNumbers.decimals(for: model.valueStep)
        let widthMM = model.source.widthMM
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                legend(color: .red, dashed: false, text: "newest line")
                legend(color: .gray, dashed: true, text: "1 s average")
            }
            Canvas { context, size in
                let inset: CGFloat = 14
                let plot = CGRect(x: 4, y: 2, width: max(size.width - 8, 1), height: max(size.height - inset - 4, 1))
                let lo = target - 3 * tolerance
                let hi = target + 3 * tolerance
                func valueFraction(_ v: Double) -> CGFloat { CGFloat(min(max((v - lo) / (hi - lo), 0), 1)) }
                /// fraction across: 0 = top of the recording screen (back of the strip).
                func point(across a: CGFloat, value v: Double) -> CGPoint {
                    if vertical {
                        return CGPoint(x: plot.minX + plot.width * valueFraction(v), y: plot.minY + plot.height * a)
                    }
                    return CGPoint(x: plot.minX + plot.width * a, y: plot.maxY - plot.height * valueFraction(v))
                }
                context.stroke(Path(plot), with: .color(.gray.opacity(0.3)), lineWidth: 0.5)
                let bandColor = Color(red: 0.55, green: 0.85, blue: 0.5)
                let guides: [(value: Double, color: Color, dash: [CGFloat])] = [
                    (target, Color(red: 0.3, green: 0.7, blue: 0.3), []),
                    (target - tolerance, bandColor, [3, 2]),
                    (target + tolerance, bandColor, [3, 2])
                ]
                for (v, color, dash) in guides {
                    var line = Path()
                    line.move(to: point(across: 0, value: v))
                    line.addLine(to: point(across: 1, value: v))
                    context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: dash))
                }
                func profile(_ values: [Float]) -> Path {
                    var path = Path()
                    var started = false
                    let n = values.count
                    for (i, v) in values.enumerated() {
                        guard v.isFinite else {
                            started = false
                            continue
                        }
                        let across = fractions.count == n ? CGFloat(fractions[i]) : (CGFloat(i) + 0.5) / CGFloat(max(n, 1))
                        let q = point(across: across, value: Double(v))
                        if started { path.addLine(to: q) } else { path.move(to: q) }
                        started = true
                    }
                    return path
                }
                context.stroke(profile(average), with: .color(.gray), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                context.stroke(profile(newest), with: .color(.red), lineWidth: 1.3)

                let labelFont = Font.system(size: 8).monospacedDigit()
                if vertical {
                    let labels: [(value: Double, anchor: UnitPoint)] = [(lo, .topLeading), (target, .top),
                                                                        (hi, .topTrailing)]
                    for (v, anchor) in labels {
                        context.draw(Text(ReplayNumbers.text(v, decimals: digits)).font(labelFont).foregroundStyle(.gray),
                                     at: CGPoint(x: point(across: 1, value: v).x, y: plot.maxY + 2), anchor: anchor)
                    }
                } else {
                    context.draw(Text("top of screen").font(labelFont).foregroundStyle(.gray),
                                 at: CGPoint(x: plot.minX, y: plot.maxY + 2), anchor: .topLeading)
                    context.draw(Text(String(format: "across %.0f mm", widthMM)).font(labelFont).foregroundStyle(.gray),
                                 at: CGPoint(x: plot.midX, y: plot.maxY + 2), anchor: .top)
                    context.draw(Text("bottom").font(labelFont).foregroundStyle(.gray),
                                 at: CGPoint(x: plot.maxX, y: plot.maxY + 2), anchor: .topTrailing)
                    for v in [lo, target, hi] {
                        context.draw(Text(ReplayNumbers.text(v, decimals: digits)).font(labelFont).foregroundStyle(.gray),
                                     at: CGPoint(x: plot.minX + 2, y: point(across: 0, value: v).y), anchor: .leading)
                    }
                }
            }
            if vertical {
                Text(String(format: "top of screen ↑  across %.0f mm  ↓ bottom", widthMM))
                    .font(.system(size: 8))
                    .foregroundStyle(.gray)
                    .lineLimit(2)
            }
        }
    }

    private func legend(color: Color, dashed: Bool, text: String) -> some View {
        HStack(spacing: 3) {
            Canvas { context, size in
                var line = Path()
                line.move(to: CGPoint(x: 0, y: size.height / 2))
                line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(line, with: .color(color),
                               style: StrokeStyle(lineWidth: 1.3, dash: dashed ? [2, 2] : []))
            }
            .frame(width: 14, height: 6)
            Text(text)
                .font(.system(size: 9))
                .foregroundStyle(.gray)
        }
    }
}

/// Colour bar: target ± 2 tolerances, labelled at every tolerance step.
private struct ColorBar: View {
    let model: TopoReplayModel

    var body: some View {
        let digits = ReplayNumbers.decimals(for: model.valueStep)
        VStack(spacing: 1) {
            LinearGradient(colors: ReplayPalette.gradient, startPoint: .leading, endPoint: .trailing)
                .frame(height: 11)
            GeometryReader { geometry in
                ForEach(0..<5, id: \.self) { k in
                    let value = model.target + Double(k - 2) * model.tolerance
                    Text(ReplayNumbers.text(value, decimals: digits))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.black)
                        .fixedSize()
                        .position(x: Self.labelX(k, width: geometry.size.width), y: 6)
                }
            }
            .frame(height: 12)
            Text(model.colorBarCaption)
                .font(.system(size: 9))
                .foregroundStyle(.gray)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private static func labelX(_ k: Int, width: CGFloat) -> CGFloat {
        let x = width * CGFloat(k) / 4
        return min(max(x, 16), width - 16)
    }
}

// MARK: - Settings

private struct ReplaySettingsView: View {
    @Bindable var model: TopoReplayModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: "tortoise")
                        Slider(value: Binding(get: { log10(model.speed) }, set: { model.setSpeed(pow(10, $0)) }),
                               in: -1...log10(20))
                        Image(systemName: "hare")
                    }
                    Picker("Preset", selection: Binding(get: { model.speed }, set: { model.setSpeed($0) })) {
                        ForEach(TopoReplayModel.speedPresets, id: \.self) { value in
                            Text(TopoReplayContent.speedText(value)).tag(value)
                        }
                        if !TopoReplayModel.speedPresets.contains(model.speed) {
                            Text(TopoReplayContent.speedText(model.speed)).tag(model.speed)
                        }
                    }
                } header: {
                    Text("Replay speed: " + TopoReplayContent.speedText(model.speed))
                } footer: {
                    Text("1× replays at the recorded rate (real time). 0.1× – 20×.")
                }

                Section {
                    Stepper(value: $model.target, step: model.valueStep) {
                        valueRow("Target", model.target)
                    }
                    Stepper(value: $model.tolerance, in: model.valueStep...10_000, step: model.valueStep) {
                        valueRow("± Tolerance", model.tolerance)
                    }
                    Button("Reset to recording median ± robust std dev") {
                        model.resetTargetAndTolerance()
                    }
                } header: {
                    Text("Target and tolerance")
                } footer: {
                    Text("Green = target ± tolerance. The colour scale runs from target − 2 tolerances (blue) to "
                         + "target + 2 tolerances (red). The pink and blue planes mark the tolerance band.")
                }

                Section("Strip") {
                    sliderRow(String(format: "Window length %.2f m", model.stripLengthMM / 1000),
                              value: $model.lengthFactor, range: 1...10)
                    sliderRow(String(format: "Height scale %.2f × width", model.heightScale),
                              value: $model.heightScale, range: 0.15...2)
                    Toggle("Smooth surface (3 × 3)", isOn: $model.smooth)
                    Toggle("Tolerance planes", isOn: $model.showPlanes)
                }

                Section("View") {
                    Picker("View", selection: $model.mode) {
                        ForEach(TopoReplayModel.Mode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    sliderRow(String(format: "View angle %.0f°", model.elevation), value: $model.elevation, range: 5...90)
                    sliderRow(String(format: "Side angle %.2f", model.shear), value: $model.shear, range: -1.2...1.2)
                    sliderRow(String(format: "Zoom %.1f×", model.zoom), value: $model.zoom, range: 0.5...8)
                    Button("Reset view") { model.resetView() }
                }
            }
            .navigationTitle("Replay settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func valueRow(_ title: String, _ value: Double) -> some View {
        LabeledContent(title) {
            Text(ReplayNumbers.text(value, decimals: ReplayNumbers.decimals(for: model.valueStep)) + " mm")
                .monospacedDigit()
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout.monospacedDigit())
            Slider(value: value, in: range)
        }
    }
}

// MARK: - Share

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
