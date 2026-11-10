import SwiftUI

/// A scan folder that has no scan.json (stopped before it finished). Its files can be shared or deleted.
struct IncompleteScanView: View {
    let folderName: String

    @Environment(ScanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [FolderEntry] = []
    @State private var confirmDelete = false
    @State private var deleteFailed = false

    private var allURLs: [URL] {
        entries.flatMap { $0.urls }
    }

    var body: some View {
        List {
            if let item = store.incompleteScan(named: folderName) {
                Section {
                    LabeledContent("Folder", value: item.folderName)
                    LabeledContent("Date", value: item.date.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Size", value: Units.bytes(item.bytes))
                    LabeledContent("Files", value: "\(item.fileCount)")
                } footer: {
                    Text("This scan stopped before it finished, so it has no model or summary. The files it saved are kept here.")
                }

                Section {
                    if entries.isEmpty {
                        Text("No files.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        if entry.isDirectory {
                            ShareLink(items: entry.urls) {
                                Label("\(entry.name) (\(entry.urls.count) files, \(Units.bytes(entry.bytes)))",
                                      systemImage: "folder")
                            }
                        } else if let url = entry.urls.first {
                            ShareLink(item: url) {
                                Label("\(entry.name) (\(Units.bytes(entry.bytes)))",
                                      systemImage: scanFileIcon(for: entry.name))
                            }
                        }
                    }
                    if allURLs.count > 1 {
                        ShareLink(items: allURLs) {
                            Label("Share all files (\(allURLs.count))", systemImage: "square.and.arrow.up.on.square")
                        }
                    }
                } header: {
                    Text("Files")
                } footer: {
                    Text("Also in the Files app under On My iPhone › Phone LiDAR › Scans › \(folderName).")
                }

                Section {
                    Button("Delete these files", role: .destructive) {
                        confirmDelete = true
                    }
                }
            } else {
                ContentUnavailableView("Folder not found", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle("Incomplete scan")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            entries = store.entries(inFolderNamed: folderName)
        }
        .confirmationDialog("Delete these files?",
                            isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if store.deleteIncomplete(folderName: folderName) {
                    dismiss()
                } else {
                    deleteFailed = true
                }
            }
        } message: {
            Text("They cannot be recovered.")
        }
        .alert("Could not delete", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try again. If it keeps failing, delete the folder in the Files app.")
        }
    }
}
