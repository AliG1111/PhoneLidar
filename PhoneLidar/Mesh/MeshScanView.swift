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

    var body: some View {
        ZStack {
            ARViewContainer(controller: controller)
                .ignoresSafeArea()

            Image(systemName: "plus")
                .font(.system(size: 30, weight: .thin))
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 2)
                .allowsHitTesting(false)

            VStack(spacing: 10) {
                HStack {
                    Button("Cancel") {
                        controller.stop()
                        onFinish(nil)
                    }
                    .buttonStyle(.bordered)

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
        .statusBarHidden()
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
        saving = true
        errorText = nil
        Task { @MainActor in
            // Let the "Saving…" label render before the export blocks the main thread.
            try? await Task.sleep(for: .milliseconds(150))
            do {
                let id = try controller.save(store: store)
                onFinish(id)
            } catch {
                errorText = error.localizedDescription
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
    var message = "Sweep slowly over the equipment until the mesh covers it. Aim the crosshair and tap Set start point (or tap the screen) to measure."

    @ObservationIgnored private(set) var arView: ARView?
    @ObservationIgnored private var pendingPoint: SIMD3<Float>?
    @ObservationIgnored private var pendingMarker: AnchorEntity?
    @ObservationIgnored private var measurementEntities: [[AnchorEntity]] = []

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
        view.session.run(config)

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

    func addPoint(at screenPoint: CGPoint) {
        guard let view = arView else { return }
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

    func save(store: ScanStore) throws -> UUID {
        guard let view = arView, let frame = view.session.currentFrame else { throw ScanError.noData }
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !anchors.isEmpty else { throw ScanError.noMesh }
        view.session.pause()

        let folder = try store.newFolder(kind: .mesh)
        let result = try MeshExporter.export(anchors: anchors, to: folder.url, baseName: "Mesh")

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
        return record.id
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
