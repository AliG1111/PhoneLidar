import SwiftUI
import RoomPlan

/// Room scanning with Apple's RoomPlan: walls, doors, windows, openings and furniture as dimensioned boxes.
struct RoomScanView: View {
    var onFinish: (UUID?) -> Void

    @Environment(ScanStore.self) private var store
    @State private var controller = RoomScanController()
    @State private var saving = false
    @State private var saveError: String?
    @State private var access = CameraAccess.State.checking

    var body: some View {
        ZStack(alignment: .bottom) {
            if access == .granted {
                RoomCaptureContainer(controller: controller)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
            if access == .denied {
                CameraDeniedView { onFinish(nil) }
            }
            if access == .granted {
                controls
            }
        }
        .statusBarHidden()
        .keepScreenOn()
        .task {
            access = await CameraAccess.request() ? .granted : .denied
        }
    }

    private var controls: some View {
        ZStack(alignment: .bottom) {

            VStack(spacing: 10) {
                if let message = saveError ?? controller.errorText {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    Button("Cancel") {
                        controller.cancel()
                        onFinish(nil)
                    }
                    .buttonStyle(.bordered)
                    .disabled(saving)

                    Spacer()

                    switch controller.phase {
                    case .scanning:
                        Button("Done scanning") { controller.finishScanning() }
                            .buttonStyle(.borderedProminent)
                    case .processing:
                        ProgressView()
                            .tint(.white)
                    case .review:
                        Button(saving ? "Saving…" : "Save scan") { save() }
                            .buttonStyle(.borderedProminent)
                            .disabled(saving || controller.result == nil)
                    }
                }
            }
            .padding()
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        saveError = nil
        Task { @MainActor in
            do {
                let id = try await controller.save(store: store)
                onFinish(id)
            } catch {
                saveError = ScanError.message(for: error)
                saving = false
            }
        }
    }
}

@MainActor
@Observable
final class RoomScanController {
    enum Phase {
        case scanning
        case processing
        case review
    }

    var phase: Phase = .scanning
    var errorText: String?
    var result: CapturedRoom?

    @ObservationIgnored private(set) var captureView: RoomCaptureView?
    @ObservationIgnored private var delegate: RoomDelegate?

    /// Created lazily so only one RoomCaptureView (and AR session) ever exists.
    func makeView() -> RoomCaptureView {
        if let captureView { return captureView }
        let view = RoomCaptureView(frame: .zero)
        let delegate = RoomDelegate()
        delegate.controller = self
        view.delegate = delegate
        view.captureSession.delegate = delegate
        self.delegate = delegate
        captureView = view
        view.captureSession.run(configuration: RoomCaptureSession.Configuration())
        return view
    }

    func finishScanning() {
        guard phase == .scanning else { return }
        phase = .processing
        captureView?.captureSession.stop()
    }

    func cancel() {
        if phase == .scanning {
            captureView?.captureSession.stop()
        }
    }

    /// The AR session stopped on its own (not from Done scanning).
    fileprivate func sessionEnded(with error: Error) {
        guard phase == .scanning else { return }
        errorText = "Scanning stopped: \(ScanError.message(for: error))"
    }

    fileprivate func received(_ room: CapturedRoom, error: Error?) {
        if let error {
            errorText = error.localizedDescription
        }
        result = room
        phase = .review
    }

    func save(store: ScanStore) async throws -> UUID {
        guard let room = result else { throw ScanError.noData }
        let folder = try store.newFolder(kind: .room)
        do {
            // Export off the main thread so the screen keeps showing "Saving…".
            let summary = try await Task.detached(priority: .userInitiated) { () -> [String] in
                // USDZ file names must not start with a digit (USD prim naming rule).
                try room.export(to: folder.url.appendingPathComponent("Room.usdz"), exportOptions: .parametric)
                try? room.export(to: folder.url.appendingPathComponent("RoomMesh.usdz"), exportOptions: .mesh)

                let json = try JSONEncoder.pretty.encode(room)
                try json.write(to: folder.url.appendingPathComponent("CapturedRoom.json"), options: .atomic)

                let report = RoomReport(room: room)
                try report.csv.write(to: folder.url.appendingPathComponent("RoomReport.csv"),
                                     atomically: true, encoding: .utf8)
                return report.summaryLines
            }.value

            let record = ScanRecord(id: UUID(),
                                    kind: .room,
                                    name: "Room " + Date().formatted(date: .abbreviated, time: .shortened),
                                    created: Date(),
                                    folderName: folder.name,
                                    primaryModel: "Room.usdz",
                                    summary: summary)
            try store.save(record)
            return record.id
        } catch {
            store.discard(folderName: folder.name)
            throw error
        }
    }
}

/// RoomCaptureViewDelegate inherits NSCoding, so it lives in its own NSObject class.
final class RoomDelegate: NSObject, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    weak var controller: RoomScanController?

    override init() {
        super.init()
    }

    required init?(coder: NSCoder) {
        super.init()
    }

    func encode(with coder: NSCoder) {}

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            self?.controller?.sessionEnded(with: error)
        }
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        Task { @MainActor [weak self] in
            self?.controller?.received(processedResult, error: error)
        }
    }
}

struct RoomCaptureContainer: UIViewRepresentable {
    let controller: RoomScanController

    func makeUIView(context: Context) -> RoomCaptureView {
        controller.makeView()
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}

    static func dismantleUIView(_ uiView: RoomCaptureView, coordinator: ()) {
        uiView.captureSession.stop()
    }
}
