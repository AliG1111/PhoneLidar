import SwiftUI
import ARKit
import RoomPlan
import RealityKit

struct HomeView: View {
    @Environment(ScanStore.self) private var store
    @State private var path: [UUID] = []
    @State private var activeScan: ScanKind?

    var body: some View {
        NavigationStack(path: $path) {
            List {
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
                    }
                    .onDelete { offsets in
                        let doomed = offsets.map { store.scans[$0] }
                        doomed.forEach { store.delete($0) }
                    }
                }
            }
            .navigationTitle("Phone LiDAR")
            .navigationDestination(for: UUID.self) { id in
                ScanDetailView(scanID: id)
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
                    }
                }
                .environment(store)
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
