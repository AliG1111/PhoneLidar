import SwiftUI
import RoomPlan

/// Room scanning with Apple's RoomPlan: walls, doors, windows, openings and furniture as dimensioned boxes.
struct RoomScanView: View {
    var onFinish: (UUID?) -> Void

    @Environment(ScanStore.self) private var store
    @State private var controller = RoomScanController()
    @State private var saving = false
    @State private var saveError: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            RoomCaptureContainer(controller: controller)
                .ignoresSafeArea()

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
        .statusBarHidden()
    }

    private func save() {
        saving = true
        saveError = nil
        do {
            let id = try controller.save(store: store)
            onFinish(id)
        } catch {
            saveError = error.localizedDescription
            saving = false
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

    fileprivate func received(_ room: CapturedRoom, error: Error?) {
        if let error {
            errorText = error.localizedDescription
        }
        result = room
        phase = .review
    }

    func save(store: ScanStore) throws -> UUID {
        guard let room = result else { throw ScanError.noData }
        let folder = try store.newFolder(kind: .room)

        // USDZ file names must not start with a digit (USD prim naming rule).
        try room.export(to: folder.url.appendingPathComponent("Room.usdz"), exportOptions: .parametric)
        try? room.export(to: folder.url.appendingPathComponent("RoomMesh.usdz"), exportOptions: .mesh)

        let json = try JSONEncoder.pretty.encode(room)
        try json.write(to: folder.url.appendingPathComponent("CapturedRoom.json"), options: .atomic)

        let report = RoomReport(room: room)
        try report.csv.write(to: folder.url.appendingPathComponent("RoomReport.csv"),
                             atomically: true, encoding: .utf8)

        let record = ScanRecord(id: UUID(),
                                kind: .room,
                                name: "Room " + Date().formatted(date: .abbreviated, time: .shortened),
                                created: Date(),
                                folderName: folder.name,
                                primaryModel: "Room.usdz",
                                summary: report.summaryLines)
        try store.save(record)
        return record.id
    }
}

/// RoomCaptureViewDelegate inherits NSCoding, so it lives in its own NSObject class.
final class RoomDelegate: NSObject, RoomCaptureViewDelegate {
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
}
