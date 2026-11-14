import SwiftUI
import ARKit
import RoomPlan
import RealityKit

struct HomeView: View {
    @Environment(ScanStore.self) private var store
    @Environment(RemoteLink.self) private var link
    @Environment(\.scenePhase) private var scenePhase
    @State private var showRemote = false
    @State private var path = NavigationPath()
    @State private var activeScan: ScanKind?
    @State private var pendingDelete: PendingDelete?
    /// Text of the "Could not delete" alert; nil when it is not shown.
    @State private var deleteFailure: String?
    /// Select mode: tapping a saved or incomplete scan ticks it instead of opening it.
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<LibrarySelection>()

    private static let singleDeleteFailure = "Try again. If it keeps failing, delete the folder in the Files app."

    /// What the delete confirmation is asking about. One dialog serves both lists and Select mode.
    private enum PendingDelete {
        case scan(ScanRecord)
        case incomplete(IncompleteScan)
        case selection(LibraryDeletePlan)

        var title: String {
            switch self {
            case .scan: return "Delete this scan and all of its files?"
            case .incomplete(let item):
                return item.interruptedRecording ? "Delete this interrupted recording?" : "Delete these files?"
            case .selection(let plan): return plan.title
            }
        }

        var detail: String {
            switch self {
            case .scan(let record): return record.name
            case .selection(let plan): return plan.message
            case .incomplete(let item):
                let name = "\(item.folderName) (\(Units.bytes(item.bytes)))"
                return item.interruptedRecording
                    ? name + ". It can be recovered instead: open it and tap Recover recording. Deleting removes its files permanently."
                    : name + ". Deleting removes the files permanently."
            }
        }
    }

    /// Only `.active`: SwiftUI also reports `.transient` edit mode during a row swipe, which is not Select mode.
    private var selecting: Bool { editMode == .active }

    /// Rows that can be ticked in Select mode: every saved and incomplete scan, except an interrupted recording
    /// while a recovery pass may be repairing it (G-4). Saved scans go by folder: a copy made in the Files app
    /// keeps the original's id.
    private var selectableItems: Set<LibrarySelection> {
        var items = Set(store.scans.map { LibrarySelection.scan($0.folderName) })
        for item in store.incomplete where !deleteBlocked(item) {
            items.insert(.incomplete(item.folderName))
        }
        return items
    }

    /// What Select all ticks: like `selectableItems`, but without interrupted recordings, which recover by
    /// themselves (they can still be ticked one by one).
    private var selectAllItems: Set<LibrarySelection> {
        var items = Set(store.scans.map { LibrarySelection.scan($0.folderName) })
        for item in store.incomplete where !item.interruptedRecording {
            items.insert(.incomplete(item.folderName))
        }
        return items
    }

    /// The ticked rows that can still be deleted.
    private var selectedItems: Set<LibrarySelection> { selection.intersection(selectableItems) }

    private func deleteBlocked(_ item: IncompleteScan) -> Bool {
        item.interruptedRecording && store.recoveryRunning
    }

    private var pendingDeleteShown: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var deleteFailureShown: Binding<Bool> {
        Binding(get: { deleteFailure != nil }, set: { if !$0 { deleteFailure = nil } })
    }

    var body: some View {
        NavigationStack(path: $path) {
            library
                .navigationTitle("Phone LiDAR")
                .toolbar { selectionToolbar }
                .navigationDestination(for: UUID.self) { id in
                    ScanDetailView(scanID: id)
                }
                .navigationDestination(for: IncompleteRoute.self) { route in
                    IncompleteScanView(folderName: route.folderName)
                }
                .confirmationDialog(pendingDelete?.title ?? "Delete?",
                                    isPresented: pendingDeleteShown,
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
                    .environment(link)
                }
                .alert("Could not delete", isPresented: deleteFailureShown) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(deleteFailure ?? "")
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
        .fullScreenCover(isPresented: $showRemote) {
            RemoteControlView(onClose: { showRemote = false }, onOpenScan: openCopiedScan)
                .environment(store)
                .environment(link)
        }
    }

    /// Closes the Remote screen and opens a copied scan.
    private func openCopiedScan(_ id: UUID) {
        showRemote = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            path.append(id)
        }
    }

    /// The Home list. In Select mode the saved and incomplete scans can be ticked; the other rows are disabled.
    private var library: some View {
        List(selection: selecting ? $selection : nil) {
            if let notice = store.recoveryNotice {
                Section {
                    Label(notice, systemImage: "arrow.uturn.backward.circle.fill")
                        .font(.callout)
                    Button("OK") { store.recoveryNotice = nil }
                } header: {
                    Text("Line recordings")
                }
                .disabled(selecting)
            }
            newScanSection
                .disabled(selecting)
            RemoteHomeSection(openRemote: { showRemote = true })
                .disabled(selecting)
            savedSection
            if !store.incomplete.isEmpty {
                incompleteSection
            }
        }
        .environment(\.editMode, $editMode)
        // Rows can vanish while ticked (deleted, recovered, or locked by a recovery pass): untick them.
        .onChange(of: store.scans) { _, _ in pruneSelection() }
        .onChange(of: store.incomplete) { _, _ in pruneSelection() }
        .onChange(of: store.recoveryRunning) { _, _ in pruneSelection() }
    }

    private var newScanSection: some View {
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
            Text("Room, equipment, object and line scans require an iPhone with LiDAR (12 Pro / Pro Max or a newer Pro model).")
        }
    }

    private var savedSection: some View {
        Section("Saved scans") {
            if store.scans.isEmpty {
                Text("No scans yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.scans) { scan in
                NavigationLink(value: scan.id) {
                    ScanRow(scan: scan)
                }
                .tag(LibrarySelection.scan(scan.folderName))
                // No full-swipe delete: it would remove the scan without asking.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Delete", role: .destructive) {
                        pendingDelete = .scan(scan)
                    }
                }
            }
        }
    }

    private var incompleteSection: some View {
        Section {
            ForEach(store.incomplete) { item in
                NavigationLink(value: IncompleteRoute(folderName: item.folderName)) {
                    IncompleteRow(item: item)
                }
                .tag(LibrarySelection.incomplete(item.folderName))
                .selectionDisabled(deleteBlocked(item))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // Not while recovery may be repairing or saving this folder (G-4).
                    if !deleteBlocked(item) {
                        Button("Delete", role: .destructive) {
                            pendingDelete = .incomplete(item)
                        }
                    }
                }
            }
        } header: {
            Text("Incomplete scans")
        } footer: {
            Text("These scans stopped before they finished (app closed, crash or full storage). Line recordings interrupted this way are recovered automatically and move to Saved scans; share or delete the others.")
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

    @ToolbarContentBuilder
    private var selectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if selecting {
                Button("Done") { endSelecting() }
                    .bold()
            } else if !selectableItems.isEmpty {
                Button("Select") {
                    withAnimation { editMode = .active }
                }
            }
        }
        if selecting {
            ToolbarItemGroup(placement: .bottomBar) {
                let all = selectAllItems
                if !selection.isEmpty && selection.isSuperset(of: all) {
                    Button("Deselect all") { selection.removeAll() }
                } else {
                    Button("Select all") { selection.formUnion(all) }
                        .disabled(all.isEmpty)
                }
                Spacer()
                Button("Delete (\(selectedItems.count))", role: .destructive) { askToDeleteSelection() }
                    .tint(.red)
                    .disabled(selectedItems.isEmpty)
            }
        }
    }

    private func askToDeleteSelection() {
        let plan = store.deletePlan(for: selectedItems)
        guard !plan.isEmpty else { return }
        pendingDelete = .selection(plan)
    }

    private func endSelecting() {
        withAnimation { editMode = .inactive }
        selection.removeAll()
    }

    private func pruneSelection() {
        guard selecting else { return }
        let valid = selectableItems
        if !selection.isSubset(of: valid) { selection.formIntersection(valid) }
        if store.scans.isEmpty && store.incomplete.isEmpty { endSelecting() }
    }

    private func confirmDelete(_ item: PendingDelete) {
        switch item {
        case .scan(let record):
            if !store.delete(record) { deleteFailure = Self.singleDeleteFailure }
        case .incomplete(let incomplete):
            // The dialog may have been open when a recovery pass started: refuse and leave the folder alone (G-4).
            if incomplete.interruptedRecording && store.recoveryRunning {
                deleteFailure = Self.singleDeleteFailure
                return
            }
            if !store.deleteIncomplete(folderName: incomplete.folderName) { deleteFailure = Self.singleDeleteFailure }
        case .selection(let plan):
            // Each scan is checked again on disk; recovery may have started since the dialog opened (G-4).
            let result = store.delete(plan)
            endSelecting()
            deleteFailure = result.failureMessage
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
