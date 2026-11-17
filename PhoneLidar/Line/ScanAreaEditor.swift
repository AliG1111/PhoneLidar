import SwiftUI
import AVFoundation
import CoreGraphics

/// The area of interest drawn over a picture (design §17.2): outside dimmed, a yellow frame, and handles while
/// editing. Draws in its container's coordinates; `picture` is the picture's rectangle there. Takes no touches.
struct ScanAreaOverlay: View {
    var area: ScanArea
    var picture: CGRect
    var editing: Bool

    var body: some View {
        let frame = Self.rect(area, in: picture)
        ZStack {
            Path { path in
                path.addRect(picture)
                path.addRect(frame)
            }
            .fill(Color.black.opacity(editing ? 0.55 : 0.4), style: FillStyle(eoFill: true))
            Path { path in path.addRect(frame) }
                .stroke(Color.yellow, lineWidth: editing ? 3 : 2)
            if editing {
                ForEach(Array(Self.handles(of: frame).enumerated()), id: \.offset) { _, point in
                    Circle()
                        .fill(Color.yellow)
                        .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                        .frame(width: 16, height: 16)
                        .position(point)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The area's rectangle in the container, from the picture rectangle.
    static func rect(_ area: ScanArea, in picture: CGRect) -> CGRect {
        let a = area.pictureRect
        return CGRect(x: picture.minX + a.minX * picture.width, y: picture.minY + a.minY * picture.height,
                      width: a.width * picture.width, height: a.height * picture.height)
    }

    /// Corners and edge midpoints.
    private static func handles(of r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }
}

/// Transparent layer that edits the area with one finger (`ScanArea.grab`, `dragged`): an edge or corner follows
/// the finger, a drag inside moves the whole area. `onChange` reports the area while dragging, `onEnd` once at the
/// end, `onCancel` when a drag ends without `onEnd` (the system cancelled it) so the caller drops its draft. Fills
/// its container; `picture` is the picture's rectangle in the container's coordinates. VoiceOver moves the edges in
/// steps through the accessibility actions.
struct ScanAreaDragLayer: View {
    var area: ScanArea
    var picture: CGRect
    var onChange: (ScanArea) -> Void
    var onEnd: (ScanArea) -> Void
    var onCancel: () -> Void = {}

    /// Touch distance (points) within which an edge is grabbed.
    static let reach: CGFloat = 28
    /// Edge step of one accessibility action, fraction of the picture.
    static let accessibilityStep = 0.05
    private static let hint = "Drag an edge or corner of the yellow frame to resize it, or inside it to move it."

    /// True while a finger is down; SwiftUI resets it when the drag ends or is cancelled.
    @GestureState private var dragging = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(dragGesture)
            // Any order of onEnded and this reset works: the result does not depend on the draft.
            .onChange(of: dragging) { _, isDragging in
                if !isDragging { onCancel() }
            }
            .accessibilityElement()
            .accessibilityLabel(Text("Area of interest"))
            .accessibilityValue(Text(area.text))
            .accessibilityHint(Text(Self.hint))
            .accessibilityActions { edgeActions }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                if let moved = moved(value) { onChange(moved) }
            }
            .onEnded { value in
                if let moved = moved(value) { onEnd(moved) }
            }
    }

    /// VoiceOver actions: each moves one edge by `accessibilityStep`.
    @ViewBuilder private var edgeActions: some View {
        Button("Left edge to the left") { step(.left, dx: -1, dy: 0) }
        Button("Left edge to the right") { step(.left, dx: 1, dy: 0) }
        Button("Right edge to the left") { step(.right, dx: -1, dy: 0) }
        Button("Right edge to the right") { step(.right, dx: 1, dy: 0) }
        Button("Top edge up") { step(.top, dx: 0, dy: -1) }
        Button("Top edge down") { step(.top, dx: 0, dy: 1) }
        Button("Bottom edge up") { step(.bottom, dx: 0, dy: -1) }
        Button("Bottom edge down") { step(.bottom, dx: 0, dy: 1) }
    }

    /// The area for this drag: what the touch first grabbed on the saved `area`, moved by the translation. Worked out
    /// from the gesture value alone, so a cancelled drag leaves nothing behind for the next one.
    private func moved(_ value: DragGesture.Value) -> ScanArea? {
        guard picture.width > 0, picture.height > 0 else { return nil }
        let point = CGPoint(x: (value.startLocation.x - picture.minX) / picture.width,
                            y: (value.startLocation.y - picture.minY) / picture.height)
        let grab = area.grab(at: point, reachX: Double(Self.reach / picture.width),
                             reachY: Double(Self.reach / picture.height))
        guard !grab.isEmpty else { return nil }
        return area.dragged(grab, dx: Double(value.translation.width / picture.width),
                            dy: Double(value.translation.height / picture.height))
    }

    private func step(_ grab: ScanAreaGrab, dx: Double, dy: Double) {
        onEnd(area.dragged(grab, dx: dx * Self.accessibilityStep, dy: dy * Self.accessibilityStep))
    }
}

/// One still picture of a recording for choosing its area of interest: the camera picture at the middle of the
/// recording, or its depth picture when there is no video. CGImage is immutable, so the value can cross actors.
struct RecordingPicture: @unchecked Sendable {
    var image: CGImage
    var orientation: Image.Orientation
    /// Width / height of the portrait picture.
    var aspect: CGFloat
    var caption: String

    /// Reads the picture off the main thread; nil when the recording has neither a readable video nor depth.
    static func load(folder: URL) async -> RecordingPicture? {
        // Only the frame times and the depth size are needed: a cut-off file is repaired in memory.
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("Recording.json")),
              let info = (try? JSONDecoder.iso.decode(LineRecordingInfo.self, from: data))
                ?? LineRecordingRepair.repairedData(data).flatMap({
                    try? JSONDecoder.iso.decode(LineRecordingInfo.self, from: $0)
                }) else { return nil }
        let aspect = CGFloat(max(info.depthHeight, 1)) / CGFloat(max(info.depthWidth, 1))
        let middle = info.frames.count / 2
        let time = info.frames.isEmpty ? 0 : max(0, info.frames[middle].time)
        if let image = await videoFrame(folder: folder, time: time) {
            return RecordingPicture(image: image, orientation: .up, aspect: aspect,
                                    caption: String(format: "Camera picture at %.1f s of the recording", time))
        }
        if let image = depthFrame(folder: folder, index: middle) {
            return RecordingPicture(image: image, orientation: .right, aspect: aspect,
                                    caption: "Depth picture (no camera picture could be read)")
        }
        return nil
    }

    /// The movie's picture near `time` (s), turned to portrait by the movie's transform like playback.
    private static func videoFrame(folder: URL, time: Double) async -> CGImage? {
        let url = folder.appendingPathComponent("Video.mov")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: 1440, height: 1440)
        for seconds in [time, 0] {
            if let picture = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) {
                return picture.image
            }
        }
        return nil
    }

    /// The depth frame `index` in colour (landscape buffer; shown with orientation `.right`).
    private static func depthFrame(folder: URL, index: Int) -> CGImage? {
        guard let reader = try? DepthFileReader(url: folder.appendingPathComponent("Depth.bin")),
              reader.frameCount > 0 else { return nil }
        guard let depth = reader.frame(min(max(index, 0), reader.frameCount - 1)) else { return nil }
        return depth.withUnsafeBufferPointer { buffer -> CGImage? in
            guard let range = DepthColors.percentileRange(buffer, step: 3) else { return nil }
            return DepthColors.image(millimetres: buffer, width: reader.width, height: reader.height,
                                     near: range.lowerBound, far: range.upperBound)
        }
    }
}

/// Chooses the area of interest of a saved recording over one of its pictures (Topographic map › Set area…).
struct ScanAreaSheet: View {
    let folder: URL
    var onUse: (ScanArea) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var area: ScanArea
    @State private var draft: ScanArea?
    @State private var picture: RecordingPicture?
    @State private var loading = true

    init(folder: URL, initial: ScanArea, onUse: @escaping (ScanArea) -> Void) {
        self.folder = folder
        self.onUse = onUse
        _area = State(initialValue: initial.normalized)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Text("Drag an edge or corner of the yellow frame, or drag inside it to move it. The map uses only "
                     + "the readings inside the frame; the recording keeps the full picture, so you can change "
                     + "this again later.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GeometryReader { geometry in
                    let rect = PlaybackModel.fitRect(in: geometry.size, aspect: picture?.aspect ?? 0.75)
                    ZStack {
                        Color.black
                        if let picture {
                            Image(decorative: picture.image, scale: 1, orientation: picture.orientation)
                                .resizable()
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                        } else if loading {
                            ProgressView().tint(.white)
                        } else {
                            Text("No picture could be read from this recording.")
                                .font(.footnote)
                                .foregroundStyle(.white)
                        }
                        ScanAreaOverlay(area: draft ?? area, picture: rect, editing: true)
                        ScanAreaDragLayer(area: area, picture: rect,
                                          onChange: { draft = $0 },
                                          onEnd: { area = $0; draft = nil },
                                          onCancel: { draft = nil })
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                if let picture {
                    Text(picture.caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text((draft ?? area).text)
                        .font(.callout.monospacedDigit())
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Spacer()
                    Button("Whole picture") { area = .whole }
                        .buttonStyle(.bordered)
                        .disabled(area.isWhole)
                }
            }
            .padding()
            .navigationTitle("Area of interest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use this area") {
                        onUse(area)
                        dismiss()
                    }
                }
            }
            // Downward drags on the picture must move the frame, not pull the sheet away (Cancel closes it).
            .interactiveDismissDisabled()
            .task {
                let folder = self.folder
                let loaded = await Task.detached(priority: .userInitiated) {
                    await RecordingPicture.load(folder: folder)
                }.value
                picture = loaded
                loading = false
            }
        }
    }
}
