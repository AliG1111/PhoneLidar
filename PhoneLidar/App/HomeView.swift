import SwiftUI
import ARKit
import RoomPlan
import RealityKit

struct HomeView: View {
    @Environment(ScanStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = NavigationPath()
    @State private var activeScan: ScanKind?
    @State private var pendingDelete: PendingDelete?
    @State private var deleteFailed = false

    /// What the delete confirmation is asking about. One dialog serves both lists.
    private enum PendingDelete {
        case scan(ScanRecord)
        case incomplete(IncompleteScan)

        var title: String {
            switch self {
            case .scan: return "Delete this scan and all of its files?"
            case .incomplete(let item):
                return item.interruptedRecording ? "Delete this interrupted recording?" : "Delete these files?"
            }
        }

        var detail: String {
            switch self {
            case .scan(let record): return record.name
            case .incomplete(let item):
                let name = "\(item.folderName) (\(Units.bytes(item.bytes)))"
                return item.interruptedRecording
                    ? name + ". It can be recovered instead: open it and tap Recover recording. Deleting removes its files permanently."
                    : name + ". Deleting removes the files permanently."
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let notice = store.recoveryNotice {
                    Section {
                        Label(notice, systemImage: "arrow.uturn.backward.circle.fill")
                            .font(.callout)
                        Button("OK") { store.recoveryNotice = nil }
                    } header: {
                        Text("Recordings recovered")
                    }
                }

                Section {
                    newScanRow(.room,
                               detail: "Walls, doors, windows and furniture with dimensions, floor area and a CSV report.",
                               supported: RoomCaptureSession.isSupported)
                    newScanRow(.mesh,
                               detail: "Raw LiDAR mesh of machinery, piping or a work area. Measure point-to-point while scanning.",
                               supported: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh))
                    newScanRow(.object,
                               detail: "Photo-textured 3D model of a part or assembly. Walk around it to capture.",
                               supported: ObjectCaptureSession.isSupported)
                    newScanRow(.line,
                               detail: "Phone fixed above moving material (portrait, travel right → left). Records LiDAR depth + video, measures speed, plays back, and builds a topographic map with variance statistics.",
                               supported: LineCapturePipeline.isSupported)
                } header: {
                    Text("New scan")
                } footer: {
                    Text("Requires an iPhone with LiDAR (12 Pro / Pro Max or a newer Pro model).")
                }

                Section("Saved scans") {
                    if store.scans.isEmpty {
                        Text("No scans yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.scans) { scan in
                        NavigationLink(value: scan.id) {
                            ScanRow(scan: scan)
                        }
                        // No full-swipe delete: it would remove the scan without asking.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) {
                                pendingDelete = .scan(scan)
                            }
                        }
                    }
                }

                if !store.incomplete.isEmpty {
                    Section {
                        ForEach(store.incomplete) { item in
                            NavigationLink(value: IncompleteRoute(folderName: item.folderName)) {
                                IncompleteRow(item: item)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Delete", role: .destructive) {
                                    pendingDelete = .incomplete(item)
                                }
                            }
                        }
                    } header: {
                        Text("Incomplete scans")
                    } footer: {
                        Text("These scans stopped before they finished (app closed, crash or full storage). Line recordings interrupted this way are recovered automatically and move to Saved scans; share or delete the others.")
                    }
                }
            }
            .navigationTitle("Phone LiDAR")
            .navigationDestination(for: UUID.self) { id in
                ScanDetailView(scanID: id)
            }
            .navigationDestination(for: IncompleteRoute.self) { route in
                IncompleteScanView(folderName: route.folderName)
            }
            .confirmationDialog(pendingDelete?.title ?? "Delete?",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible,
                                presenting: pendingDelete) { item in
                Button("Delete", role: .destructive) { confirmDelete(item) }
            } message: { item in
                Text(item.detail)
            }
            .fullScreenCover(item: $activeScan) { kind in
                Group {
                    switch kind {
                    case .room:
                        RoomScanView(onFinish: finished)
                    case .mesh:
                        MeshScanView(onFinish: finished)
                    case .object:
                        ObjectScanView(onFinish: finished)
                    case .line:
                        LineScanView(onFinish: finished)
                    case .unknown:
                        EmptyView()
                    }
                }
                .environment(store)
            }
            .alert("Could not delete", isPresented: $deleteFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Try again. If it keeps failing, delete the folder in the Files app.")
            }
            .task {
                // Library loaded: recover line recordings an earlier run left unsaved (in the background).
                store.recoverLineRecordings()
            }
            .onChange(of: activeScan) { _, newValue in
                // A scan screen just closed: pick up new, discarded and incomplete folders.
                if newValue == nil {
                    store.reload()
                    store.recoverLineRecordings()
                }
            }
            .onChange(of: scenePhase) { _, newValue in
                // Folders may have been changed in the Files app, or the app was killed while recording earlier.
                if newValue == .active && activeScan == nil {
                    store.reload()
                    store.recoverLineRecordings()
                }
            }
        }
    }

    private func newScanRow(_ kind: ScanKind, detail: String, supported: Bool) -> some View {
        Button {
            activeScan = kind
        } label: {
            HStack(spacing: 14) {
                Image(systemName: kind.symbol)
                    .font(.title2)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .font(.headline)
                    Text(supported ? detail : "Not supported on this device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .disabled(!supported)
    }

    private func confirmDelete(_ item: PendingDelete) {
        switch item {
        case .scan(let record):
            if !store.delete(record) { deleteFailed = true }
        case .incomplete(let incomplete):
            if !store.deleteIncomplete(folderName: incomplete.folderName) { deleteFailed = true }
        }
    }

    private func finished(_ id: UUID?) {
        activeScan = nil
        guard let id else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            path.append(id)
        }
    }
}

struct ScanRow: View {
    let scan: ScanRecord

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: scan.kind.symbol)
                .font(.title3)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(scan.name)
                    .font(.headline)
                Text(scan.created.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct IncompleteRow: View {
    let item: IncompleteScan

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: item.interruptedRecording ? "arrow.uturn.backward.circle" : "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.folderName)
                    .font(.headline)
                Text("\(Units.bytes(item.bytes)) · \(item.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if item.interruptedRecording {
                    Text("Interrupted line recording: recovers automatically")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
