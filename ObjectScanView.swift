import SwiftUI
import RealityKit

/// Apple Object Capture: guided photo capture + on-device photogrammetry into a textured, real-scale USDZ.
struct ObjectScanView: View {
    var onFinish: (UUID?) -> Void

    @Environment(ScanStore.self) private var store
    @State private var controller = ObjectCaptureController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let session = controller.session {
                ObjectCaptureView(session: session)
                    .ignoresSafeArea()
                CaptureOverlay(session: session, onCancel: cancel)
            } else {
                statusView
            }
        }
        .statusBarHidden()
        .onAppear { controller.start(store: store) }
        .onChange(of: controller.stateName) { _, newValue in
            controller.stateChanged(to: newValue, store: store)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        VStack(spacing: 16) {
            switch controller.phase {
            case .starting, .capturing:
                ProgressView("Starting camera…")
                    .tint(.white)
            case .reconstructing:
                Text("Building the 3D model on the phone…")
                    .font(.headline)
                ProgressView(value: controller.progress)
                    .frame(maxWidth: 260)
                    .tint(.white)
                Text("\(Int(controller.progress * 100)) %")
                    .monospacedDigit()
                Text("Keep the app open. This can take several minutes.")
                    .font(.footnote)
                    .foregroundStyle(.gray)
                Button("Cancel") { cancel() }
                    .buttonStyle(.bordered)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                Text("Model saved")
                    .font(.headline)
                Button("Open scan") { onFinish(controller.savedID) }
                    .buttonStyle(.borderedProminent)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.yellow)
                Text(message)
                    .multilineTextAlignment(.center)
                Button("Close") { cancel() }
                    .buttonStyle(.bordered)
            }
        }
        .foregroundStyle(.white)
        .padding()
    }

    private func cancel() {
        controller.cancel()
        onFinish(nil)
    }
}

private struct CaptureOverlay: View {
    let session: ObjectCaptureSession
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Spacer()
            }

            Spacer()

            if !hint.isEmpty {
                Text(hint)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 12) {
                switch session.state {
                case .ready:
                    Button("Detect object") { _ = session.startDetecting() }
                        .buttonStyle(.borderedProminent)
                    if #available(iOS 18.0, *) {
                        Button("Area mode") { session.startCapturing() }
                            .buttonStyle(.bordered)
                    }
                case .detecting:
                    Button("Start capture") { session.startCapturing() }
                        .buttonStyle(.borderedProminent)
                case .capturing:
                    Text("Photos: \(session.numberOfShotsTaken) / \(session.maximumNumberOfInputImages)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.white)
                    Button("Finish") { session.finish() }
                        .buttonStyle(.borderedProminent)
                case .finishing:
                    ProgressView()
                        .tint(.white)
                default:
                    EmptyView()
                }
            }
        }
        .padding()
    }

    private var hint: String {
        switch session.state {
        case .ready:
            return "Point at the object. Tap Detect object (or Area mode for something too big for a box)."
        case .detecting:
            return "Drag the box edges to fit the object, then tap Start capture."
        case .capturing:
            return "Walk slowly around the object: one low, one middle and one high loop. Tap Finish when the ring is full."
        case .finishing:
            return "Saving photos…"
        default:
            return ""
        }
    }
}

@MainActor
@Observable
final class ObjectCaptureController {
    enum Phase: Equatable {
        case starting
        case capturing
        case reconstructing
        case done
        case failed(String)
    }

    var phase: Phase = .starting
    var progress: Double = 0
    var session: ObjectCaptureSession?
    var savedID: UUID?

    @ObservationIgnored private var folder: (name: String, url: URL)?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var photogrammetry: PhotogrammetrySession?

    /// Observable string form of the capture state so the view can react with onChange.
    var stateName: String {
        guard let session else { return "none" }
        switch session.state {
        case .initializing: return "initializing"
        case .ready: return "ready"
        case .detecting: return "detecting"
        case .capturing: return "capturing"
        case .finishing: return "finishing"
        case .completed: return "completed"
        case .failed: return "failed"
        @unknown default: return "unknown"
        }
    }

    func start(store: ScanStore) {
        guard !started else { return }
        started = true
        guard ObjectCaptureSession.isSupported else {
            phase = .failed("Object Capture needs an iPhone with LiDAR (12 Pro or newer Pro) on iOS 17 or later.")
            return
        }
        do {
            let newFolder = try store.newFolder(kind: .object)
            folder = newFolder
            let images = newFolder.url.appendingPathComponent("Images", isDirectory: true)
            let checkpoint = newFolder.url.appendingPathComponent("Checkpoint", isDirectory: true)
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)

            var configuration = ObjectCaptureSession.Configuration()
            configuration.checkpointDirectory = checkpoint

            let newSession = ObjectCaptureSession()
            try newSession.start(imagesDirectory: images, configuration: configuration)
            session = newSession
            phase = .capturing
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func stateChanged(to name: String, store: ScanStore) {
        switch name {
        case "completed":
            Task { await reconstruct(store: store) }
        case "failed":
            if phase == .capturing {
                session = nil
                phase = .failed("The capture session stopped. Try again with more light and slower movement.")
            }
        default:
            break
        }
    }

    func reconstruct(store: ScanStore) async {
        guard phase == .capturing, let folder else { return }
        phase = .reconstructing
        // The capture session must be released before photogrammetry can start on iOS.
        session = nil

        let images = folder.url.appendingPathComponent("Images", isDirectory: true)
        let checkpoint = folder.url.appendingPathComponent("Checkpoint", isDirectory: true)
        let modelURL = folder.url.appendingPathComponent("Model.usdz")

        do {
            guard PhotogrammetrySession.isSupported else { throw ScanError.unsupported }
            var configuration = PhotogrammetrySession.Configuration()
            configuration.checkpointDirectory = checkpoint
            let reconstruction = try PhotogrammetrySession(input: images, configuration: configuration)
            photogrammetry = reconstruction
            // iOS supports only the .reduced detail level for on-device reconstruction.
            try reconstruction.process(requests: [.modelFile(url: modelURL, detail: .reduced)])

            outputLoop: for try await output in reconstruction.outputs {
                switch output {
                case .requestProgress(_, fractionComplete: let fraction):
                    progress = fraction
                case .requestError(_, let error):
                    throw error
                case .processingCancelled:
                    throw ScanError.cancelled
                case .processingComplete:
                    break outputLoop
                default:
                    break
                }
            }
            photogrammetry = nil
            try? FileManager.default.removeItem(at: checkpoint)

            let photoCount = (try? FileManager.default.contentsOfDirectory(atPath: images.path).count) ?? 0
            let record = ScanRecord(id: UUID(),
                                    kind: .object,
                                    name: "Object " + Date().formatted(date: .abbreviated, time: .shortened),
                                    created: Date(),
                                    folderName: folder.name,
                                    primaryModel: "Model.usdz",
                                    summary: ["Photos captured: \(photoCount) (kept in the Images folder)",
                                              "Model.usdz is textured and at real-world scale (metres)"])
            try store.save(record)
            savedID = record.id
            phase = .done
        } catch {
            photogrammetry = nil
            phase = .failed("Model reconstruction failed: \(error.localizedDescription)")
        }
    }

    func cancel() {
        session?.cancel()
        session = nil
        photogrammetry?.cancel()
        photogrammetry = nil
        if phase != .done, let folder {
            try? FileManager.default.removeItem(at: folder.url)
        }
    }
}
