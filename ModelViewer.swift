import SwiftUI
import UIKit
import SceneKit
import ModelIO
import SceneKit.ModelIO
import simd

/// Orbit / zoom / pan any saved model and measure point-to-point on its surface.
struct ModelViewerScreen: View {
    let url: URL

    @State private var model = ViewerModel()
    @State private var scene: SCNScene?

    var body: some View {
        ZStack(alignment: .bottom) {
            if let scene {
                SceneKitContainer(scene: scene, model: model)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ProgressView("Loading model…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(model.loadError ?? model.status)
                    .font(.footnote)
                ForEach(Array(model.measurements.enumerated()), id: \.offset) { item in
                    Text("#\(item.offset + 1)  \(Units.format(meters: item.element))")
                        .font(.callout.monospacedDigit())
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
        }
        .navigationTitle(url.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    model.setMeasureMode(!model.measureMode)
                } label: {
                    Image(systemName: model.measureMode ? "ruler.fill" : "ruler")
                }
                Button {
                    model.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(model.measurements.isEmpty)
            }
        }
        .onAppear {
            if scene == nil {
                scene = model.load(url: url)
            }
        }
    }
}

@MainActor
@Observable
final class ViewerModel {
    var measureMode = false
    var measurements: [Double] = []
    var status = "Drag to orbit, pinch to zoom, two-finger drag to pan. Tap the ruler to measure."
    var loadError: String?

    @ObservationIgnored weak var scnView: SCNView?
    @ObservationIgnored private(set) var scene: SCNScene?
    @ObservationIgnored private(set) var center = SCNVector3Zero
    @ObservationIgnored private var radius: Float = 1
    @ObservationIgnored private var markerRadius: Float = 0.005
    @ObservationIgnored private var pending: SIMD3<Float>?
    @ObservationIgnored private var markerNodes: [SCNNode] = []

    func load(url: URL) -> SCNScene {
        if let scene { return scene }

        let loaded: SCNScene
        let ext = url.pathExtension.lowercased()
        if ext == "obj" || ext == "ply" {
            let asset = MDLAsset(url: url)
            loaded = SCNScene(mdlAsset: asset)
            let material = SCNMaterial()
            material.diffuse.contents = UIColor(white: 0.78, alpha: 1)
            material.isDoubleSided = true
            loaded.rootNode.enumerateHierarchy { node, _ in
                if node.geometry != nil {
                    node.geometry?.materials = [material]
                }
            }
        } else {
            do {
                loaded = try SCNScene(url: url, options: nil)
            } catch {
                loadError = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
                loaded = SCNScene()
            }
        }

        let sphere = loaded.rootNode.boundingSphere
        center = sphere.center
        radius = max(Float(sphere.radius), 0.05)
        markerRadius = max(radius * 0.008, 0.002)

        let camera = SCNCamera()
        camera.zNear = Double(radius) * 0.005
        camera.zFar = Double(radius) * 50
        camera.fieldOfView = 55
        let cameraNode = SCNNode()
        cameraNode.name = "viewerCamera"
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(center.x, center.y + radius * 0.6, center.z + radius * 2.2)
        cameraNode.look(at: center)
        loaded.rootNode.addChildNode(cameraNode)

        scene = loaded
        return loaded
    }

    func setMeasureMode(_ on: Bool) {
        measureMode = on
        pending = nil
        status = on
            ? "Measure: tap two points on the model."
            : "Drag to orbit, pinch to zoom, two-finger drag to pan."
    }

    func handleTap(at point: CGPoint) {
        guard measureMode, let view = scnView else { return }
        let hits = view.hitTest(point, options: nil)
        guard let hit = hits.first(where: { $0.node.name != "measureMarker" }) else {
            status = "Tap directly on the model surface."
            return
        }
        let w = hit.worldCoordinates
        let p = SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z))
        addSphere(at: p)

        if let start = pending {
            addLine(from: start, to: p)
            let distance = Double(simd_distance(start, p))
            measurements.append(distance)
            status = "#\(measurements.count): \(Units.format(meters: distance))"
            pending = nil
        } else {
            pending = p
            status = "First point set. Tap the second point."
        }
    }

    func clear() {
        markerNodes.forEach { $0.removeFromParentNode() }
        markerNodes.removeAll()
        measurements.removeAll()
        pending = nil
        status = measureMode ? "Measure: tap two points on the model." : "Cleared."
    }

    private func addSphere(at p: SIMD3<Float>) {
        let sphere = SCNSphere(radius: CGFloat(markerRadius))
        sphere.firstMaterial?.diffuse.contents = UIColor.systemYellow
        sphere.firstMaterial?.lightingModel = .constant
        let node = SCNNode(geometry: sphere)
        node.simdPosition = p
        node.name = "measureMarker"
        scene?.rootNode.addChildNode(node)
        markerNodes.append(node)
    }

    private func addLine(from a: SIMD3<Float>, to b: SIMD3<Float>) {
        let length = simd_distance(a, b)
        guard length > 0 else { return }
        let cylinder = SCNCylinder(radius: CGFloat(markerRadius * 0.35), height: CGFloat(length))
        cylinder.firstMaterial?.diffuse.contents = UIColor.systemYellow
        cylinder.firstMaterial?.lightingModel = .constant
        let node = SCNNode(geometry: cylinder)
        node.simdPosition = (a + b) / 2
        node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(b - a))
        node.name = "measureMarker"
        scene?.rootNode.addChildNode(node)
        markerNodes.append(node)
    }
}

struct SceneKitContainer: UIViewRepresentable {
    let scene: SCNScene
    let model: ViewerModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(withName: "viewerCamera", recursively: false)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .secondarySystemBackground
        view.defaultCameraController.target = model.center
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        model.scnView = view
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject {
        let model: ViewerModel

        init(model: ViewerModel) {
            self.model = model
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            model.handleTap(at: recognizer.location(in: view))
        }
    }
}
