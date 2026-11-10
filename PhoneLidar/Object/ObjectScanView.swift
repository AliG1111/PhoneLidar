import SwiftUI
import RealityKit

/// Apple Object Capture: guided photo capture + on-device photogrammetry into a textured, real-scale USDZ.
/// Pass `resume` to run the reconstruction again on the photos already kept in a scan's Images folder.
struct ObjectScanView: View {
    var resume: ScanRecord? = nil
    var onFinish: (UUID?) -> Void

    @Environment(ScanStore.self) private var store
    @State private var controller = ObjectCaptureController()
    @State private var showDiscard = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let session = controller.session {
                ObjectCaptureView(session: session)
                    .ignoresSafeArea()
                CaptureOverlay(session: session, state: controller.captureState, onCancel: requestCancel)
            } else {
                statusView
            }
        }
        .statusBarHidden()
        .keepScreenOn()
        .task {
            if let resume {
                controller.resume(record: resume, store: store)
            } else if await CameraAccess.request() {
                controller.start(store: store)
            } else {
                controller.cameraDenied()
            }
        }
        .confirmationDialog("Discard this capture?",
                            isPresented: $showDiscard,
                            titleVisibility: .visible) {
            Button("Discard photos", role: .destructive) { discard() }
            Button("Keep scanning", role: .cancel) {}
        } message: {
            Text("The photos taken so far will be deleted.")
        }
    }

    @ViewBuilder
    private var statusView: some View {
        VStack(spacing: 16) {
            switch controller.phase {
            case .starting, .capturing:
                ProgressView("Starting camera…")
                    .tint(.white)
            case .cameraDenied:
                CameraDeniedView { onFinish(nil) }
            case .reconstructing:
                Text("Building the 3D model…")
                    .font(.headline)
                ProgressView(value: controller.progress)
                    .frame(maxWidth: 260)
                    .tint(.white)
                Text("\(Int(controller.progress * 100)) %")
                    .monospacedDigit()
                Text("Keep the app open. This can take several minutes. Your photos are already saved.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.gray)
                Button("Stop") { controller.cancelReconstruction() }
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
                Button("Close") { close() }
                    .buttonStyle(.bordered)
            case .kept(let message, let photos, let canRetry):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.yellow)
                Text("3D model not built")
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                Text("\(photos) photos are saved in the scan. You can share them or try again.")
                    .multilineTextAlignment(.center)
                if canRetry {
                    Button("Retry reconstruction") { controller.retry() }
                        .buttonStyle(.borderedProminent)
                }
                if let id = controller.savedID {
                    Button("Open scan") { onFinish(id) }
                        .buttonStyle(.bordered)
                }
                Button("Close") { close() }
                    .buttonStyle(.bordered)
            }
        }
        .foregroundStyle(.white)
        .padding()
    }

    /// Cancel during capture. Asks first when photos have been taken, because they are deleted.
    private func requestCancel() {
        if let session = controller.session, session.numberOfShotsTaken > 0 {
            showDiscard = true
        } else {
            discard()
        }
    }

    private func discard() {
        if controller.discardCapture() {
            onFinish(nil)
        }
    }

    private func close() {
        controller.discardCapture()
        onFinish(nil)
    }
}

private struct CaptureOverlay: View {
    let session: ObjectCaptureSession
    let state: ObjectCaptureSession.CaptureState
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                if canCancel {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)
                }
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
                switch state {
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

    /// Not while the photos are being saved or after the capture has finished.
    private var canCancel: Bool {
        switch state {
        case .finishing, .completed, .failed:
            return false
        default:
            return true
        }
    }

    private var hint: String {
        switch state {
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

/// Counts the photos (not the depth / gravity side files) in an Images folder.
enum ObjectPhotos {
    static func count(in images: URL) -> Int {
        let photoExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "dng"]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: images.path)) ?? []
        return names.filter { photoExtensions.contains(($0 as NSString).pathExtension.lowercased()) }.count
    }
}

private enum ReconstructionError: LocalizedError {
    case noModel

    var errorDescription: String? {
        "No model file was produced."
    }
}

@MainActor
@Observable
final class ObjectCaptureController {
    enum Phase: Equatable {
        case starting
        case cameraDenied
        case capturing
        case reconstructing
        case done
        /// Nothing worth keeping (no photos); the folder has been removed.
        case failed(String)
        /// The model was not built but the photos and a scan.json are kept.
        case kept(String, photos: Int, canRetry: Bool)
    }

    var phase: Phase = .starting
    var progress: Double = 0
    var session: ObjectCaptureSession?
    /// Copy of session.state, kept current from session.stateUpdates so the overlay redraws on every change.
    var captureState: ObjectCaptureSession.CaptureState = .initializing
    var savedID: UUID?

    @ObservationIgnored private var folder: (name: String, url: URL)?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var photogrammetry: PhotogrammetrySession?
    @ObservationIgnored private var store: ScanStore?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    /// True once the capture is finished: from then on the photos are never deleted.
    @ObservationIgnored private var captureFinished = false
    @ObservationIgnored private var reconstructionCancelled = false
    @ObservationIgnored private var modelComplete = false
    @ObservationIgnored private var recordID: UUID?
    @ObservationIgnored private var recordName = "Object " + Date().formatted(date: .abbreviated, time: .shortened)
    @ObservationIgnored private var recordCreated = Date()

    func cameraDenied() {
        guard !started else { return }
        started = true
        phase = .cameraDenied
    }

    func start(store: ScanStore) {
        guard !started else { return }
        started = true
        self.store = store
        guard ObjectCaptureSession.isSupported else {
            phase = .failed("Object Capture needs an iPhone with LiDAR (12 Pro or newer Pro) on iOS 17 or later.")
            return
        }
        var created: (name: String, url: URL)?
        do {
            let newFolder = try store.newFolder(kind: .object)
            created = newFolder
            folder = newFolder
            let images = newFolder.url.appendingPathComponent("Images", isDirectory: true)
            let checkpoint = newFolder.url.appendingPathComponent("Checkpoint", isDirectory: true)
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)

            var configuration = ObjectCaptureSession.Configuration()
            configuration.checkpointDirectory = checkpoint

            let newSession = ObjectCaptureSession()
            newSession.start(imagesDirectory: images, configuration: configuration)
            session = newSession
            captureState = newSession.state
            phase = .capturing

            // Follow the capture state: start reconstruction when the photos are saved.
            stateTask = Task { [weak self] in
                for await state in newSession.stateUpdates {
                    self?.captureStateChanged(state)
                }
            }
        } catch {
            if let created { store.discard(folderName: created.name) }
            folder = nil
            phase = .failed(ScanError.message(for: error))
        }
    }

    /// Re-runs the reconstruction on the photos kept in a scan's Images folder.
    func resume(record: ScanRecord, store: ScanStore) {
        guard !started else { return }
        started = true
        self.store = store
        folder = (record.folderName, store.folderURL(for: record))
        recordID = record.id
        savedID = record.id
        recordName = record.name
        recordCreated = record.created
        captureFinished = true
        phase = .reconstructing
        Task { await retryNow() }
    }

    func retry() {
        guard case .kept = phase else { return }
        phase = .reconstructing
        Task { await retryNow() }
    }

    private func retryNow() async {
        guard let folder else { return }
        // A half-written cache from the failed run can make the next run fail too.
        let checkpoint = folder.url.appendingPathComponent("Checkpoint", isDirectory: true)
        try? FileManager.default.removeItem(at: checkpoint)
        try? FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
        await runReconstruction()
    }

    private func captureStateChanged(_ state: ObjectCaptureSession.CaptureState) {
        captureState = state
        switch state {
        case .completed:
            stopListening()
            guard phase == .capturing else { return }
            captureFinished = true
            phase = .reconstructing
            Task { await runReconstruction() }
        case .failed(let error):
            stopListening()
            guard phase == .capturing else { return }
            session = nil
            let reason = "The capture stopped: \(ScanError.message(for: error))"
            if ObjectPhotos.count(in: imagesURL) > 0 {
                captureFinished = true
                keepPhotos(reason: reason)
            } else {
                if let folder { store?.discard(folderName: folder.name) }
                phase = .failed(reason + " Try again with more light and slower movement.")
            }
        default:
            break
        }
    }

    private func stopListening() {
        stateTask?.cancel()
        stateTask = nil
    }

    private var imagesURL: URL {
        (folder?.url ?? URL(fileURLWithPath: "/nonexistent")).appendingPathComponent("Images", isDirectory: true)
    }

    private func runReconstruction() async {
        guard let folder else { return }
        phase = .reconstructing
        progress = 0
        reconstructionCancelled = false
        modelComplete = false
        // The capture session must be released before photogrammetry can start on iOS.
        session = nil

        let images = imagesURL
        let checkpoint = folder.url.appendingPathComponent("Checkpoint", isDirectory: true)
        let modelURL = folder.url.appendingPathComponent("Model.usdz")
        try? FileManager.default.removeItem(at: modelURL)

        // Write the scan record before the long reconstruction, so the photos stay in the library
        // even if the app is closed or killed while the model is being built.
        let photos = ObjectPhotos.count(in: images)
        try? writeRecord(model: nil, summary: ["Model not built yet.",
                                                "\(photos) photos kept in the Images folder."])

        do {
            guard PhotogrammetrySession.isSupported else { throw ScanError.unsupported }
            var configuration = PhotogrammetrySession.Configuration()
            configuration.checkpointDirectory = checkpoint
            let reconstruction = try PhotogrammetrySession(input: images, configuration: configuration)
            photogrammetry = reconstruction
            if reconstructionCancelled { throw ScanError.cancelled }
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

            if reconstructionCancelled { throw ScanError.cancelled }
            let modelSize = (try? modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard modelSize > 0 else { throw ReconstructionError.noModel }
            modelComplete = true
            try? FileManager.default.removeItem(at: checkpoint)

            try writeRecord(model: "Model.usdz",
                            summary: ["Photos captured: \(ObjectPhotos.count(in: images)) (kept in the Images folder)",
                                      "Model.usdz is textured and at real-world scale (metres)"])
            phase = .done
        } catch {
            photogrammetry = nil
            var wasCancelled = reconstructionCancelled
            if case .cancelled? = error as? ScanError { wasCancelled = true }
            if wasCancelled {
                keepPhotos(reason: "Model building was stopped.")
            } else {
                keepPhotos(reason: ScanError.message(for: error))
            }
        }
    }

    /// The model was not built. The photos are never deleted here: write a scan.json so the scan shows in the
    /// library with its photos shareable, and offer a retry. Only a capture with no photos at all is removed.
    private func keepPhotos(reason: String) {
        guard let folder, let store else {
            phase = .failed(reason)
            return
        }
        let photos = ObjectPhotos.count(in: imagesURL)
        try? FileManager.default.removeItem(at: folder.url.appendingPathComponent("Checkpoint", isDirectory: true))
        if !modelComplete {
            try? FileManager.default.removeItem(at: folder.url.appendingPathComponent("Model.usdz"))
        }

        if photos == 0 && !modelComplete {
            if let id = recordID, let record = store.record(id: id) {
                store.delete(record)
            } else {
                store.discard(folderName: folder.name)
            }
            savedID = nil
            phase = .failed("No photos were captured. " + reason)
            return
        }

        let summary = ["Reconstruction failed: \(reason)",
                       "\(photos) photos kept in the Images folder. Use Share photos, or retry reconstruction."]
        try? writeRecord(model: modelComplete ? "Model.usdz" : nil, summary: summary)
        phase = .kept(reason, photos: photos, canRetry: PhotogrammetrySession.isSupported && photos > 0)
    }

    private func writeRecord(model: String?, summary: [String]) throws {
        guard let folder, let store else { return }
        let id = recordID ?? UUID()
        let record = ScanRecord(id: id,
                                kind: .object,
                                name: recordName,
                                created: recordCreated,
                                folderName: folder.name,
                                primaryModel: model,
                                summary: summary)
        try store.save(record)
        recordID = id
        savedID = id
    }

    /// Stops the model building. The photos are kept (see `keepPhotos`).
    func cancelReconstruction() {
        reconstructionCancelled = true
        photogrammetry?.cancel()
    }

    /// Cancel / Close. Deletes the folder only while the capture is still running or failed with nothing kept.
    /// Returns false when the capture had already finished, so nothing was discarded and the screen must stay.
    @discardableResult
    func discardCapture() -> Bool {
        if captureFinished {
            return phase != .capturing && phase != .reconstructing
        }
        stopListening()
        session?.cancel()
        session = nil
        if let folder {
            store?.discard(folderName: folder.name)
        }
        return true
    }
}
