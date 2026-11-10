import SwiftUI

/// A scan folder that has no scan.json (stopped before it finished). Its files can be shared or deleted;
/// an interrupted line recording can also be recovered (it is recovered automatically as well).
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

    private var isInterruptedRecording: Bool {
        store.incompleteScan(named: folderName)?.interruptedRecording == true
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
                    if item.interruptedRecording {
                        Text("This line recording was interrupted: the app closed while it was recording or saving. "
                             + "The app recovers it automatically (once its files have been untouched for 30 seconds): "
                             + "Recording.json is repaired and the recording moves to Saved scans.")
                    } else {
                        Text("This scan stopped before it finished, so it has no model or summary. The files it saved are kept here.")
                    }
                }

                if item.interruptedRecording {
                    recoverSection
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
                    Button(item.interruptedRecording ? "Delete this recording" : "Delete these files", role: .destructive) {
                        confirmDelete = true
                    }
                    // Not while recovery may be repairing or saving this folder.
                    .disabled(item.interruptedRecording && store.recoveryRunning)
                }
            } else if let record = store.scans.first(where: { $0.folderName == folderName }) {
                // Recovered (or saved) while this screen was open.
                Section {
                    Label("Recording recovered", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    NavigationLink(value: record.id) {
                        Label("Open \(record.name)", systemImage: record.kind.symbol)
                    }
                } footer: {
                    Text("It is now under Saved scans.")
                }
            } else {
                ContentUnavailableView("Folder not found", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(isInterruptedRecording ? "Interrupted recording" : "Incomplete scan")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            entries = store.entries(inFolderNamed: folderName)
        }
        .confirmationDialog(isInterruptedRecording ? "Delete this interrupted recording?" : "Delete these files?",
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
            if isInterruptedRecording {
                Text("It can be recovered instead: tap Recover recording. Deleting removes its files permanently.")
            } else {
                Text("Deleting removes the files permanently.")
            }
        }
        .alert("Could not delete", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try again. If it keeps failing, delete the folder in the Files app.")
        }
    }

    private var recoverSection: some View {
        Section {
            if store.recoveryRunning {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Recovering…")
                }
            } else {
                Button {
                    store.recoverLineRecordings()
                } label: {
                    Label("Recover recording", systemImage: "arrow.uturn.backward.circle")
                }
            }
            if let reason = store.recoveryFailures[folderName] {
                Label("Last attempt failed: \(reason)", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Recovery")
        } footer: {
            Text("Recover before sharing, so Recording.json is repaired first. A recording that stopped less than "
                 + "30 seconds ago is recovered shortly afterwards.")
        }
    }
}
