import SwiftUI
import ARKit
import RealityKit

/// Free-form LiDAR mesh capture (ARKit scene reconstruction) with point-to-point measuring.
/// Suited to machinery, piping, conveyors and whole work areas.
struct MeshScanView: View {
    var onFinish: (UUID?) -> Void

    @Environment(ScanStore.self) private var store
    @State private var controller = MeshScanController()
    @State private var saving = false
    @State private var errorText: String?
    @State private var access = CameraAccess.State.checking

    var body: some View {
        ZStack {
            if access == .granted {
                // The crosshair is a subview of the ARView itself, so it is exactly at the point that is measured.
                ARViewContainer(controller: controller)
                    .ignoresSafeArea()
                controls
            } else {
                Color.black.ignoresSafeArea()
            }
            if access == .denied {
                CameraDeniedView { onFinish(nil) }
            }
        }
        .statusBarHidden()
        .keepScreenOn()
        .task {
            access = await CameraAccess.request() ? .granted : .denied
        }
    }

    private var controls: some View {
        ZStack {
            VStack(spacing: 10) {
                HStack {
                    Button("Cancel") {
                        controller.stop()
                        onFinish(nil)
                    }
                    .buttonStyle(.bordered)
                    .disabled(saving)

                    Spacer()

                    Button {
                        controller.toggleMesh()
                    } label: {
                        Image(systemName: controller.meshVisible ? "eye" : "eye.slash")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                if !controller.measurements.isEmpty {
                    measurementList
                }

                if saving {
                    VStack(spacing: 4) {
                        ProgressView(value: controller.saveProgress)
                        Text(controller.saveStage)
                            .font(.footnote)
                    }
                    .padding(8)
                    .foregroundStyle(.white)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                }

                Text(errorText ?? controller.message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 12) {
                    Button {
                        controller.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.measurements.isEmpty && !controller.hasPendingPoint)

                    Button {
                        controller.addPointAtCenter()
                    } label: {
                        Label(controller.hasPendingPoint ? "Set end point" : "Set start point",
                              systemImage: "scope")
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()

                    Button(saving ? "Saving…" : "Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(saving)
                }
            }
            .padding()
        }
    }

    private var measurementList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(controller.measurements.suffix(4)) { m in
                Text("\(m.label): \(Units.format(meters: m.meters))")
                    .font(.callout.monospacedDigit())
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private func save() {
        guard !saving else { return }
        saving = true
        errorText = nil
        Task { @MainActor in
            do {
                let id = try await controller.save(store: store)
                onFinish(id)
            } catch {
                errorText = ScanError.message(for: error)
                saving = false
            }
        }
    }
}

@MainActor
@Observable
final class MeshScanController {
    var measurements: [PointMeasurement] = []
    var hasPendingPoint = false
    var meshVisible = true
    var saveProgress: Double = 0
    var saveStage = "Preparing…"
    /// Set when the AR session fails or is interrupted.
    var sessionProblem: String?
    var message = "Sweep slowly over the equipment until the mesh covers it. Aim the crosshair and tap Set start point (or tap the screen) to measure."

    @ObservationIgnored private(set) var arView: ARView?
    @ObservationIgnored private var pendingPoint: SIMD3<Float>?
    @ObservationIgnored private var pendingMarker: AnchorEntity?
    @ObservationIgnored private var measurementEntities: [[AnchorEntity]] = []
    @ObservationIgnored private var sessionDelegate: MeshSessionDelegate?
    @ObservationIgnored private var isSaving = false

    func makeView() -> ARView {
        if let arView { return arView }
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.environment.sceneUnderstanding.options.insert(.collision)
        view.environment.sceneUnderstanding.options.insert(.occlusion)
        view.debugOptions.insert(.showSceneUnderstanding)

        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .none
        let delegate = MeshSessionDelegate()
        delegate.controller = self
        sessionDelegate = delegate
        view.session.delegate = delegate
        view.session.run(config)

        // Crosshair at the exact centre of the ARView (the point used for measuring).
        let crosshair = UIImageView(image: UIImage(
            systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .thin)))
        crosshair.tintColor = .white
        crosshair.layer.shadowColor = UIColor.black.cgColor
        crosshair.layer.shadowOpacity = 1
        crosshair.layer.shadowRadius = 2
        crosshair.layer.shadowOffset = .zero
        crosshair.isUserInteractionEnabled = false
        crosshair.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(crosshair)
        NSLayoutConstraint.activate([
            crosshair.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            crosshair.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        arView = view
        return view
    }

    func stop() {
        arView?.session.pause()
    }

    func toggleMesh() {
        meshVisible.toggle()
        if meshVisible {
            arView?.debugOptions.insert(.showSceneUnderstanding)
        } else {
            arView?.debugOptions.remove(.showSceneUnderstanding)
        }
    }

    func addPointAtCenter() {
        guard let view = arView else { return }
        addPoint(at: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
    }

    fileprivate func sessionFailed(_ error: Error) {
        sessionProblem = "Scanning stopped: \(error.localizedDescription)"
        message = sessionProblem ?? message
    }

    fileprivate func sessionInterrupted(_ interrupted: Bool) {
        if interrupted {
            message = "Scanning paused (camera in use or app in background)."
        } else {
            message = "Scanning again. Move slowly over the equipment."
        }
    }

    func addPoint(at screenPoint: CGPoint) {
        guard let view = arView, !isSaving else { return }
        guard let point = worldPoint(at: screenPoint, in: view) else {
            message = "No surface found there. Scan that area a bit more and try again."
            return
        }

        if let start = pendingPoint {
            let endMarker = makeMarker(at: point)
            let line = makeLine(from: start, to: point)
            let distance = Double(simd_distance(start, point))
            let label = "M\(measurements.count + 1)"
            measurements.append(PointMeasurement(label: label,
                                                 start: [start.x, start.y, start.z],
                                                 end: [point.x, point.y, point.z],
                                                 meters: distance))
            measurementEntities.append([pendingMarker, endMarker, line].compactMap { $0 })
            pendingPoint = nil
            pendingMarker = nil
            hasPendingPoint = false
            message = "\(label): \(Units.format(meters: distance))"
        } else {
            pendingPoint = point
            pendingMarker = makeMarker(at: point)
            hasPendingPoint = true
            message = "Start point set. Aim at the end point."
        }
    }

    func undo() {
        if let marker = pendingMarker {
            arView?.scene.removeAnchor(marker)
            pendingMarker = nil
            pendingPoint = nil
            hasPendingPoint = false
            message = "Start point removed."
            return
        }
        guard !measurements.isEmpty else { return }
        measurements.removeLast()
        if let entities = measurementEntities.popLast() {
            entities.forEach { arView?.scene.removeAnchor($0) }
        }
        message = "Last measurement removed."
    }

    func save(store: ScanStore) async throws -> UUID {
        guard !isSaving else { throw ScanError.noData }
        guard let view = arView, let frame = view.session.currentFrame else { throw ScanError.noData }
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !anchors.isEmpty else { throw ScanError.noMesh }
        isSaving = true
        defer { isSaving = false }
        saveProgress = 0
        saveStage = "Preparing…"

        // Copy the mesh out of ARKit on the main thread; the files are written in the background.
        // The session keeps running until the export has succeeded, so a failed save can simply be retried.
        let snapshot = try MeshExporter.snapshot(anchors: anchors)
        let measurements = self.measurements
        let folder = try store.newFolder(kind: .mesh)
        do {
            let result = try await Task.detached(priority: .userInitiated) { [weak self] () -> MeshExportResult in
                try MeshExporter.write(snapshot, to: folder.url, baseName: "Mesh") { stage, fraction in
                    Task { @MainActor in
                        self?.saveStage = stage
                        self?.saveProgress = fraction
                    }
                }
            }.value

            if !measurements.isEmpty {
                try CSV.measurements(measurements).write(
                    to: folder.url.appendingPathComponent("Measurements.csv"), atomically: true, encoding: .utf8)
            }

            let size = result.boundsMax - result.boundsMin
            var summary = [
                "Overall extents: \(Units.short(Double(size.x))) × \(Units.short(Double(size.y))) H × \(Units.short(Double(size.z)))",
                "Mesh: \(result.vertexCount) vertices, \(result.faceCount) triangles",
                "Units: metres, Y axis up"
            ]
            for m in measurements {
                summary.append("\(m.label): \(Units.format(meters: m.meters))")
            }

            let record = ScanRecord(id: UUID(),
                                    kind: .mesh,
                                    name: "Equipment " + Date().formatted(date: .abbreviated, time: .shortened),
                                    created: Date(),
                                    folderName: folder.name,
                                    primaryModel: result.usdzWritten ? "Mesh.usdz" : "Mesh.obj",
                                    summary: summary,
                                    measurements: measurements)
            try store.save(record)
            view.session.pause()
            return record.id
        } catch {
            store.discard(folderName: folder.name)
            throw error
        }
    }

    // MARK: - Helpers

    private func worldPoint(at point: CGPoint, in view: ARView) -> SIMD3<Float>? {
        if let hit = view.hitTest(point, query: .nearest, mask: .sceneUnderstanding).first {
            return hit.position
        }
        if let result = view.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first {
            let c = result.worldTransform.columns.3
            return SIMD3<Float>(c.x, c.y, c.z)
        }
        return nil
    }

    private func makeMarker(at point: SIMD3<Float>) -> AnchorEntity {
        let anchor = AnchorEntity(world: point)
        let sphere = ModelEntity(mesh: .generateSphere(radius: 0.006),
                                 materials: [UnlitMaterial(color: .systemYellow)])
        anchor.addChild(sphere)
        arView?.scene.addAnchor(anchor)
        return anchor
    }

    private func makeLine(from a: SIMD3<Float>, to b: SIMD3<Float>) -> AnchorEntity {
        let length = simd_distance(a, b)
        let anchor = AnchorEntity(world: (a + b) / 2)
        let bar = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.002, 0.002, max(length, 0.001))),
                              materials: [UnlitMaterial(color: .systemYellow)])
        if length > 0.0001 {
            bar.orientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: simd_normalize(b - a))
        }
        anchor.addChild(bar)
        arView?.scene.addAnchor(anchor)
        return anchor
    }
}

/// ARSessionDelegate lives in its own NSObject; callbacks hop to the main actor.
final class MeshSessionDelegate: NSObject, ARSessionDelegate {
    weak var controller: MeshScanController?

    func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.controller?.sessionFailed(error)
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in
            self?.controller?.sessionInterrupted(true)
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor [weak self] in
            self?.controller?.sessionInterrupted(false)
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    let controller: MeshScanController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> ARView {
        let view = controller.makeView()
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    @MainActor
    final class Coordinator: NSObject {
        let controller: MeshScanController

        init(controller: MeshScanController) {
            self.controller = controller
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            controller.addPoint(at: recognizer.location(in: view))
        }
    }
}
