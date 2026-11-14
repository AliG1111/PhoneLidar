import SwiftUI

// Height reference on the Line scan screen (design §16, FR-HREF): empty-belt baseline, camera height + phone tilt,
// or side-wall tops measured by the LiDAR.

extension LineScanModel {
    /// The chosen reference is usable: a baseline for the empty belt, else a camera height or a wall calibration.
    var heightReferenceReady: Bool {
        heightReference.method == .emptyBelt ? baseline != nil : heightReference.isPlaneReady
    }

    var topBand: WallBand { heightReference.topBand ?? .defaultTop }
    var bottomBand: WallBand { heightReference.bottomBand ?? .defaultBottom }

    /// Level zero handed to the belt plane (0 when not zeroed: gravity is the belt normal).
    private var zero: (x: Double, y: Double) {
        levelZeroed ? (levelZeroX, levelZeroY) : (0, 0)
    }

    /// One line on the state of a camera-height or side-wall reference.
    var referenceStatusText: String {
        switch heightReference.method {
        case .emptyBelt:
            return baseline == nil ? "No baseline: values are distances from the camera."
                : "Heights above the empty-belt baseline."
        case .cameraHeight:
            guard let h = heightReference.beltDistance else {
                return "Enter the camera height (lens to belt) under Height reference: values are distances meanwhile."
            }
            return String(format: "Heights above the belt: camera %.0f mm above it · level %@", h,
                          levelZeroed ? "zeroed on the belt" : "from gravity (no zero)")
        case .sideWalls:
            guard let walls = heightReference.walls else {
                return heightReference.wallHeight == nil
                    ? "Enter the wall height and calibrate on the side walls under Height reference."
                    : "Mark the wall tops and calibrate on the side walls under Height reference."
            }
            return String(format: "Heights above the belt: belt %.0f mm from the camera · walls %.0f mm high · "
                          + "the walls differ by %.1f mm", walls.beltDistance, walls.wallHeight, walls.disagreement)
        }
    }

    /// Warnings for a camera-height or side-wall reference (`short` = the ones kept on screen while recording).
    func referenceWarnings(short: Bool) -> [String] {
        var lines: [String] = []
        switch heightReference.method {
        case .emptyBelt:
            break
        case .cameraHeight:
            if !short, heightReference.isPlaneReady, !levelZeroed {
                lines.append("Level not zeroed: gravity is taken as the belt normal, so the belt must be level. "
                             + "For a sloped belt lay the phone flat on it and tap Zero here.")
            }
        case .sideWalls:
            guard let walls = heightReference.walls else { break }
            if let x = levelX, let y = levelY {
                let moved = ((x - walls.tiltX) * (x - walls.tiltX) + (y - walls.tiltY) * (y - walls.tiltY)).squareRoot()
                if moved > 0.3 {
                    lines.append(short
                        ? String(format: "Tilt changed %.1f° since the wall calibration", moved)
                        : String(format: "Phone tilt changed %.1f° since the wall calibration — calibrate again", moved))
                }
            }
            if walls.disagreement > WallCalibration.disagreementWarning {
                lines.append(short
                    ? String(format: "Walls differ by %.1f mm", walls.disagreement)
                    : String(format: "The two walls differ by %.1f mm: check the level zero, the wall height and "
                             + "that each band is on a wall top", walls.disagreement))
            }
            if !short {
                if walls.filteredDepth != filteredDepth {
                    lines.append("The walls were measured with \(walls.filteredDepth ? "filtered" : "raw") depth — "
                                 + "calibrate again for this setting")
                }
                if walls.topBand != topBand || walls.bottomBand != bottomBand {
                    lines.append("The wall bands moved since the calibration — calibrate again")
                }
            }
        }
        return lines
    }

    /// Sends the reference in use to the capture pipeline (live heights; the baseline copied into recordings).
    func applyHeightReference() {
        if heightReference.method != .emptyBelt, let distance = heightReference.beltDistance {
            pipeline.setHeightPlane(LiveHeightPlane(distance: distance, zeroX: zero.x, zeroY: zero.y))
            pipeline.setBaseline(nil)
        } else {
            pipeline.setHeightPlane(nil)
            pipeline.setBaseline(heightReference.method == .emptyBelt ? baseline : nil)
        }
    }

    /// Writes a camera-height or side-wall reference (with the level zero in use) into a new recording folder.
    /// Returns summary lines for the recording when the reference is missing or could not be written.
    func copyHeightReference(into folder: URL) -> [String] {
        guard heightReference.method != .emptyBelt else { return [] }
        guard heightReference.isPlaneReady else {
            return ["Height reference \(heightReference.method.label.lowercased()) not set up: map and playback show "
                    + "distances from the camera."]
        }
        var copy = heightReference
        copy.levelZeroX = zero.x
        copy.levelZeroY = zero.y
        do {
            try copy.save(to: folder)
            return []
        } catch {
            return ["Height reference not copied into the recording (\(error.localizedDescription)): the map shows "
                    + "distances from the camera."]
        }
    }

    /// Reads the stored reference. A damaged file is moved aside (never overwritten) and reported (P16-3).
    func loadHeightReference() {
        let folder = HeightReference.standardFolder
        switch HeightReference.read(from: folder) {
        case .missing:
            heightReference = HeightReference()
        case .loaded(let reference):
            heightReference = reference
        case .damaged(let reason):
            heightReference = HeightReference()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd_HHmmss"
            let aside = folder.appendingPathComponent("HeightReference-unreadable-\(formatter.string(from: Date())).json")
            do {
                try FileManager.default.moveItem(at: folder.appendingPathComponent(HeightReference.fileName), to: aside)
                calibrationMessage = "HeightReference.json could not be read (\(reason)); it was kept as "
                    + "\(aside.lastPathComponent). Set up the height reference again."
            } catch {
                referenceSaveBlocked = true
                calibrationMessage = "HeightReference.json could not be read (\(reason)) and is left as it is: "
                    + "height reference changes are not saved until it is removed (Files › Phone LiDAR › Calibration)."
            }
        }
    }

    private func saveReference() {
        guard !referenceSaveBlocked else {
            calibrationMessage = "Height reference in use but not saved: the unreadable HeightReference.json in "
                + "Calibration must be removed first."
            return
        }
        do {
            try heightReference.save(to: HeightReference.standardFolder)
        } catch {
            calibrationMessage = "Height reference in use but not saved: \(error.localizedDescription)"
        }
    }

    func setReferenceMethod(_ method: HeightReferenceMethod) {
        guard !calibrating, heightReference.method != method else { return }
        heightReference.method = method
        calibrationMessage = nil
        saveReference()
        applyHeightReference()
    }

    /// Parses a typed length in mm (comma or point); nil unless 1 mm … 10 m.
    static func millimetres(_ text: String) -> Double? {
        guard let v = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              v.isFinite, v >= 1, v <= 10_000 else { return nil }
        return v
    }

    func setCameraHeight(_ text: String) {
        guard let v = Self.millimetres(text) else {
            calibrationMessage = "Enter the camera height in mm (lens to belt, 1–10000)."
            return
        }
        heightReference.cameraHeight = v
        calibrationMessage = nil
        saveReference()
        applyHeightReference()
    }

    func setWallHeight(_ text: String) {
        guard let v = Self.millimetres(text) else {
            calibrationMessage = "Enter the wall height in mm (wall top above the belt)."
            return
        }
        heightReference.wallHeight = v
        // The measured wall-top distances do not depend on the wall height: only the belt moves.
        heightReference.walls?.wallHeight = v
        calibrationMessage = nil
        saveReference()
        applyHeightReference()
    }

    /// Moves a wall band so its centre is at `center` (fraction of the picture, top → bottom), keeping its width.
    func moveBand(top: Bool, to center: Double) {
        let band = top ? topBand : bottomBand
        let half = (band.end - band.start) / 2
        let c = min(max(center, half), 1 - half)
        let moved = WallBand(start: c - half, end: c + half).clamped
        if top { heightReference.topBand = moved } else { heightReference.bottomBand = moved }
    }

    /// Width of both wall bands (fraction of the picture), kept around their centres.
    func setBandWidth(_ width: Double) {
        func resized(_ band: WallBand) -> WallBand {
            let half = max(WallBand.minimumWidth, width) / 2
            let c = min(max(band.center, half), 1 - half)
            return WallBand(start: c - half, end: c + half).clamped
        }
        heightReference.topBand = resized(topBand)
        heightReference.bottomBand = resized(bottomBand)
    }

    func bandsChanged() {
        saveReference()
    }

    /// Measures both wall tops (90 frames ≈ 3 s) with the phone still.
    func calibrateWalls() {
        guard phase == .ready, !calibrating else { return }
        guard let wallHeight = heightReference.wallHeight, wallHeight > 0 else {
            calibrationMessage = WallCalibrationError.noWallHeight.errorDescription
            return
        }
        calibrating = true
        calibrationKind = .walls
        calibrationMessage = nil
        calibrationProgress = 0
        let capture = WallCapture(target: 90, topBand: topBand, bottomBand: bottomBand, wallHeight: wallHeight,
                                  zeroX: zero.x, zeroY: zero.y, filtered: filteredDepth)
        pipeline.captureWalls(capture) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.finishWalls(result)
            }
        }
    }

    private func finishWalls(_ outcome: Result<WallCalibration, Error>) {
        calibrating = false
        calibrationKind = nil
        calibrationProgress = nil
        switch outcome {
        case .success(let walls):
            heightReference.walls = walls
            heightReference.topBand = walls.topBand
            heightReference.bottomBand = walls.bottomBand
            saveReference()
            applyHeightReference()
        case .failure(let error):
            calibrationMessage = error.localizedDescription
        }
    }

    func clearWalls() {
        heightReference.walls = nil
        calibrationMessage = nil
        saveReference()
        applyHeightReference()
    }
}

/// Sheet to choose and set up the height reference.
struct HeightReferenceSheet: View {
    let model: LineScanModel
    @Environment(\.dismiss) private var dismiss
    @State private var cameraHeightText = ""
    @State private var wallHeightText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Reference", selection: Binding(
                        get: { model.heightReference.method },
                        set: { model.setReferenceMethod($0) })) {
                        ForEach(HeightReferenceMethod.allCases) { method in
                            Text(method.label).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.calibrating)
                } footer: {
                    Text(methodFooter)
                }

                switch model.heightReference.method {
                case .emptyBelt:
                    emptyBeltSection
                case .cameraHeight:
                    cameraHeightSection
                case .sideWalls:
                    sideWallSections
                }

                if let message = model.calibrationMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                let warnings = model.referenceWarnings(short: false)
                if !warnings.isEmpty {
                    Section {
                        ForEach(warnings, id: \.self) { line in
                            Label(line, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle("Height reference")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                cameraHeightText = model.heightReference.cameraHeight.map { String(format: "%.0f", $0) } ?? ""
                wallHeightText = model.heightReference.wallHeight.map { String(format: "%.0f", $0) } ?? ""
            }
        }
    }

    private var methodFooter: String {
        switch model.heightReference.method {
        case .emptyBelt:
            return "Calibrate on the empty belt: each depth pixel gets its own zero. The most accurate reference "
                + "when the belt can be cleared."
        case .cameraHeight:
            return "Heights = camera height − distance along the belt normal. The belt is taken as flat; the phone "
                + "tilt comes from the level (zero it with the phone flat on the belt). Accuracy follows the "
                + "tape measurement of the camera height and the LiDAR distance."
        case .sideWalls:
            return "The LiDAR measures both wall tops; with the wall height above the belt this gives the belt "
                + "without clearing it. The belt is taken as flat; maps keep only the part between the walls."
        }
    }

    private var progressRow: some View {
        Group {
            if let progress = model.calibrationProgress {
                ProgressView(value: progress) {
                    Text(String(format: "Hold still — %.0f %%", progress * 100))
                }
            } else if model.calibrating {
                HStack {
                    ProgressView()
                    Text("Working…")
                }
            }
        }
    }

    private var emptyBeltSection: some View {
        Section("Empty-belt baseline") {
            if let baseline = model.baseline {
                Text(String(format: "Set: %.0f mm away, coverage %.0f %%", baseline.info.meanDistance,
                            baseline.info.coveragePercent))
                    .monospacedDigit()
            } else {
                Text("No baseline yet.")
            }
            progressRow
            Button(model.baseline == nil ? "Calibrate baseline on the empty belt" : "Recalibrate") {
                model.calibrateBaseline()
            }
            .disabled(model.calibrating || model.phase != .ready)
            if model.baseline != nil {
                Button("Clear baseline", role: .destructive) { model.clearBaseline() }
                    .disabled(model.calibrating)
            }
        }
    }

    private var cameraHeightSection: some View {
        Section {
            HStack {
                TextField("Camera height (lens to belt), mm", text: $cameraHeightText)
                    .keyboardType(.decimalPad)
                Button("Set") { model.setCameraHeight(cameraHeightText) }
                    .buttonStyle(.bordered)
            }
            if let h = model.heightReference.cameraHeight {
                LabeledContent("In use", value: String(format: "%.0f mm", h))
            }
            LabeledContent("Phone vs zero", value: LineScanView.levelText(model.levelX, model.levelY))
            LabeledContent("Level zero", value: model.levelZeroed ? "set" : "not set (gravity)")
        } header: {
            Text("Camera height")
        } footer: {
            Text("Measure from the camera lens straight down to the belt. With a tape measure to ±5 mm the heights "
                 + "are within about ±5 mm plus the LiDAR distance error.")
        }
    }

    @ViewBuilder
    private var sideWallSections: some View {
        Section {
            HStack {
                TextField("Wall top above the belt, mm", text: $wallHeightText)
                    .keyboardType(.decimalPad)
                Button("Set") { model.setWallHeight(wallHeightText) }
                    .buttonStyle(.bordered)
            }
            if let h = model.heightReference.wallHeight {
                LabeledContent("In use", value: String(format: "%.0f mm", h))
            }
        } header: {
            Text("Wall height")
        } footer: {
            Text("Measure from the belt to the top of the side walls (±1 mm). One height for both walls.")
        }

        Section {
            WallBandPicture(model: model)
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            HStack {
                Text("Band width")
                Slider(value: Binding(
                    get: { model.topBand.end - model.topBand.start },
                    set: { model.setBandWidth($0) }), in: 0.02...0.25,
                    onEditingChanged: { editing in
                        if !editing { model.bandsChanged() }
                    })
            }
            progressRow
            Button("Calibrate on the side walls") { model.calibrateWalls() }
                .disabled(model.calibrating || model.phase != .ready || model.heightReference.wallHeight == nil)
            if let walls = model.heightReference.walls {
                LabeledContent("Belt from the camera", value: String(format: "%.0f mm", walls.beltDistance))
                LabeledContent("Top wall", value: String(format: "%.1f mm (%ld readings, ±%.1f)", walls.topDistance,
                                                         walls.topReadings, walls.topSpread))
                LabeledContent("Bottom wall", value: String(format: "%.1f mm (%ld readings, ±%.1f)",
                                                            walls.bottomDistance, walls.bottomReadings,
                                                            walls.bottomSpread))
                LabeledContent("Walls differ by", value: String(format: "%.1f mm", walls.disagreement))
                Button("Clear wall calibration", role: .destructive) { model.clearWalls() }
                    .disabled(model.calibrating)
            }
        } header: {
            Text("Wall tops")
        } footer: {
            Text("Drag each band onto a wall top (the closest, dark-red stripe at the top and bottom of the depth "
                 + "picture), keep the phone still and calibrate (about 3 s). The wall tops must be wider than "
                 + "about two LiDAR spots: ≈ 10 cm at 1 m, ≈ 30 cm at 3 m.")
        }
    }
}

/// Live depth picture with the two wall bands; drag a band to move it.
private struct WallBandPicture: View {
    let model: LineScanModel

    var body: some View {
        ZStack {
            if let image = model.depthImage {
                Image(decorative: image, scale: 1, orientation: .right)
                    .resizable()
                    .interpolation(.none)
            } else {
                Color.black
                Text("Waiting for the camera…").foregroundStyle(.white)
            }
            GeometryReader { geometry in
                let size = geometry.size
                ZStack(alignment: .topLeading) {
                    band(model.topBand, label: "Top wall", size: size)
                    band(model.bottomBand, label: "Bottom wall", size: size)
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                // Drag anywhere: the band on the side of the touch (from the midpoint between the bands) follows.
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard size.height > 0 else { return }
                        let start = Double(value.startLocation.y / size.height)
                        let top = start < (model.topBand.center + model.bottomBand.center) / 2
                        model.moveBand(top: top, to: Double(value.location.y / size.height))
                    }
                    .onEnded { _ in model.bandsChanged() })
            }
        }
        .aspectRatio(CGFloat(model.pictureAspect), contentMode: .fit)
        .frame(maxHeight: 340)
        .frame(maxWidth: .infinity)
    }

    private func band(_ band: WallBand, label: String, size: CGSize) -> some View {
        Rectangle()
            .fill(Color.orange.opacity(0.3))
            .overlay(Rectangle().stroke(Color.orange, lineWidth: 2))
            .overlay(alignment: .leading) {
                Text(label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
            }
            .frame(width: size.width, height: max(6, CGFloat(band.end - band.start) * size.height))
            .position(x: size.width / 2, y: CGFloat(band.center) * size.height)
            .allowsHitTesting(false)
    }
}
