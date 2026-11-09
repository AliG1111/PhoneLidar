import SwiftUI
import QuickLook

struct ScanDetailView: View {
    let scanID: UUID

    @Environment(ScanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var arPreviewURL: URL?
    @State private var showRename = false
    @State private var draftName = ""
    @State private var confirmDelete = false

    var body: some View {
        if let scan = store.record(id: scanID) {
            content(scan)
        } else {
            ContentUnavailableView("Scan not found", systemImage: "questionmark.folder")
        }
    }

    private func content(_ scan: ScanRecord) -> some View {
        List {
            Section {
                LabeledContent("Type", value: scan.kind.title)
                LabeledContent("Captured", value: scan.created.formatted(date: .abbreviated, time: .shortened))
            }

            if let model = scan.primaryModel {
                let modelURL = store.fileURL(model, in: scan)
                Section("3D model") {
                    NavigationLink {
                        ModelViewerScreen(url: modelURL)
                    } label: {
                        Label("Open 3D viewer (orbit, zoom, measure)", systemImage: "rotate.3d")
                    }
                    if modelURL.pathExtension.lowercased() == "usdz" {
                        Button {
                            arPreviewURL = modelURL
                        } label: {
                            Label("View in AR at real size", systemImage: "arkit")
                        }
                    }
                }
            }

            if scan.kind == .line {
                let folder = store.folderURL(for: scan)
                Section("Line scan") {
                    NavigationLink {
                        TopoMapView(folder: folder)
                    } label: {
                        Label("Topographic map + variance statistics", systemImage: "map")
                    }
                    NavigationLink {
                        LinePlaybackView(folder: folder)
                    } label: {
                        Label("Play back recording (with speed)", systemImage: "play.rectangle")
                    }
                }
            }

            if !scan.summary.isEmpty {
                Section("Summary") {
                    ForEach(Array(scan.summary.enumerated()), id: \.offset) { item in
                        Text(item.element)
                            .font(.callout.monospacedDigit())
                    }
                }
            }

            if !scan.measurements.isEmpty {
                Section("Measurements taken while scanning") {
                    ForEach(scan.measurements) { m in
                        LabeledContent(m.label, value: Units.format(meters: m.meters))
                    }
                }
            }

            Section {
                ForEach(scan.files, id: \.self) { name in
                    ShareLink(item: store.fileURL(name, in: scan)) {
                        Label(name, systemImage: icon(for: name))
                    }
                }
                if scan.files.count > 1 {
                    ShareLink(items: scan.files.map { store.fileURL($0, in: scan) }) {
                        Label("Share all files", systemImage: "square.and.arrow.up.on.square")
                    }
                }
            } header: {
                Text("Files")
            } footer: {
                Text("Tap a file to AirDrop, email, or save it to OneDrive / Google Drive. All files are also in the Files app under On My iPhone › Phone LiDAR › Scans › \(scan.folderName).")
            }

            Section {
                Button("Delete scan", role: .destructive) {
                    confirmDelete = true
                }
            }
        }
        .navigationTitle(scan.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Rename") {
                    draftName = scan.name
                    showRename = true
                }
            }
        }
        .alert("Rename scan", isPresented: $showRename) {
            TextField("Name", text: $draftName)
            Button("Save") { store.rename(scan, to: draftName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this scan and all of its files?",
                            isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.delete(scan)
                dismiss()
            }
        }
        .quickLookPreview($arPreviewURL)
    }

    private func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "usdz", "obj", "ply": return "cube"
        case "csv": return "tablecells"
        case "json": return "curlybraces"
        case "mov": return "film"
        case "png": return "photo"
        case "bin": return "externaldrive"
        default: return "doc"
        }
    }
}
