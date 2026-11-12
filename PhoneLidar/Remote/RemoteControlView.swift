import SwiftUI

/// Remote phone: pair, start/stop, readouts and copies of the scanner's Line scans (FR-RMT-03, -07, -08, -10, -11).
struct RemoteControlView: View {
    var onClose: () -> Void
    var onOpenScan: (UUID) -> Void

    @Environment(RemoteLink.self) private var link
    @Environment(ScanStore.self) private var store
    @State private var pairingScanner: FoundScanner?
    @State private var codeText = ""
    @State private var showNearby = false
    @State private var confirmForget = false
    @State private var confirmDiscard: RemoteScanInfo?

    var body: some View {
        NavigationStack {
            List {
                linkSection
                if link.pairedScannerName == nil || showNearby || link.pairingTarget != nil {
                    nearbySection
                }
                if link.pairedScannerName != nil, link.isConnected || link.status != nil {
                    recordingSection
                    readoutsSection
                }
                if link.pairedScannerName != nil {
                    scansSection
                }
            }
            .navigationTitle("Remote control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onClose() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Pair a different scanner", systemImage: "plus.circle") { showNearby = true }
                        if link.pairedScannerName != nil {
                            Button("Forget scanner", systemImage: "trash", role: .destructive) { confirmForget = true }
                        }
                        Button("Turn the remote link off", systemImage: "power") {
                            link.disconnect()
                            onClose()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
            }
            .alert("Pair with \(pairingScanner?.name ?? "the scanner")",
                   isPresented: Binding(get: { pairingScanner != nil }, set: { if !$0 { pairingScanner = nil } })) {
                TextField("6-digit code", text: $codeText)
                    .keyboardType(.numberPad)
                Button("Pair") {
                    if let scanner = pairingScanner {
                        link.pair(with: scanner, code: codeText)
                        showNearby = false
                    }
                    codeText = ""
                }
                Button("Cancel", role: .cancel) { codeText = "" }
            } message: {
                Text("Enter the code shown on the scanner (Line scan › Remote › Pair a remote).")
            }
            .confirmationDialog("Forget the paired scanner?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) { link.forgetScanner() }
            } message: {
                Text("This phone has to pair again with a new code. Partly copied scans are kept.")
            }
            .confirmationDialog("Discard the partly copied files?",
                                isPresented: Binding(get: { confirmDiscard != nil }, set: { if !$0 { confirmDiscard = nil } }),
                                titleVisibility: .visible, presenting: confirmDiscard) { scan in
                Button("Discard", role: .destructive) { link.discardCopy(scan.id) }
            } message: { scan in
                Text("\(scan.name): the files copied so far are deleted from this phone. The scan stays on the scanner.")
            }
        }
        .keepScreenOn()
        .onAppear { link.setMode(.remote) }
    }

    // MARK: - Sections

    private var linkSection: some View {
        Section {
            Label(link.stateText, systemImage: linkSymbol)
                .foregroundStyle(linkColor)
            if let name = link.pairedScannerName {
                LabeledContent("Paired scanner", value: name)
            }
            if let error = link.pairError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Link")
        } footer: {
            Text("Wi-Fi must be on in Settings on both phones; no Wi-Fi network is needed. The scanner keeps recording if the link drops, and this phone reconnects by itself.")
        }
    }

    private var nearbySection: some View {
        Section {
            if link.foundScanners.isEmpty {
                Text("Searching… On the scanner phone open Line scan › Remote and turn on Allow remote control.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(link.foundScanners) { scanner in
                Button {
                    codeText = ""
                    pairingScanner = scanner
                } label: {
                    HStack {
                        Label(scanner.name, systemImage: "iphone")
                        Spacer()
                        if link.pairingTarget == scanner.id {
                            ProgressView()
                        } else if scanner.id == link.pairedScannerID {
                            Text("Paired")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(link.pairingTarget != nil)
            }
        } header: {
            Text("Scanners nearby")
        } footer: {
            Text("Tap a scanner, then enter the code it shows.")
        }
    }

    private var recordingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.phaseText(link.status))
                    .font(.title2.weight(.bold).monospacedDigit())
                    .foregroundStyle(link.status?.phase == .recording ? Color.red : Color.primary)
                if let failure = link.status?.failure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if !link.isConnected {
                    Text("Last values received before the link dropped.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Button {
                    link.sendCommand(.startRecording)
                } label: {
                    Label("Start", systemImage: "record.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!canStart)

                Button {
                    link.sendCommand(.stopRecording)
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(.gray)
                .disabled(!canStop)
            }
            if let feedback = link.commandFeedback {
                Text(feedback)
                    .font(.callout)
            }
            if let notice = link.status?.notice {
                Text("Scanner: \(notice)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Recording")
        }
    }

    @ViewBuilder
    private var readoutsSection: some View {
        if let status = link.status {
            Section {
                ForEach(Self.alerts(status), id: \.self) { text in
                    Label(text, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                LabeledContent("Speed", value: SpeedText.main(status.speed))
                LabeledContent("", value: SpeedText.perMinute(status.speed))
                LabeledContent("Texture lock", value: String(format: "%.0f %%", status.lock * 100))
                LabeledContent("Distance", value: status.distance.map { String(format: "%.0f mm", $0) } ?? "—")
                if status.heightMode, let height = status.centerHeight {
                    LabeledContent("Height above baseline", value: String(format: "%+.1f mm", height))
                }
                LabeledContent("Baseline", value: status.calibrating ? "Calibrating…" : (status.baselineSaved ? "Calibrated" : "Not calibrated"))
                LabeledContent("Level", value: LineScanView.levelText(status.levelX, status.levelY))
                LabeledContent("Heat", value: Self.heatText(status.heat))
                LabeledContent("Free storage", value: status.freeBytes.map { LineStorage.text($0) } ?? "—")
                LabeledContent("Battery", value: Self.batteryText(status))
            } header: {
                Text("Scanner readouts")
            }
        }
    }

    private var scansSection: some View {
        Section {
            if !link.scansLoaded {
                Text(link.isConnected ? "Loading…" : "Connect to see the scanner's scans.")
                    .foregroundStyle(.secondary)
            } else if link.scannerScans.isEmpty {
                Text("No saved Line scans on the scanner.")
                    .foregroundStyle(.secondary)
            }
            ForEach(link.scannerScans) { scan in
                scanRow(scan)
            }
        } header: {
            HStack {
                Text("Scans on the scanner")
                Spacer()
                Button("Refresh") { link.refreshScans() }
                    .font(.caption)
                    .disabled(!link.isConnected)
            }
        } footer: {
            Text("A copy continues after a dropped link and pauses while the scanner records. Copied scans are listed under Saved scans on Home.")
        }
    }

    private func scanRow(_ scan: RemoteScanInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(scan.name)
                .font(.headline)
            Text("\(scan.created.formatted(date: .abbreviated, time: .shortened)) · \(Units.bytes(scan.totalBytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if store.record(id: scan.id) != nil {
                HStack {
                    Label("On this phone", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Open") { onOpenScan(scan.id) }
                        .buttonStyle(.bordered)
                }
            } else if let copy = link.copies[scan.id] {
                copyControls(scan, copy)
            } else {
                Button("Copy to this phone") { link.copy(scan.id) }
                    .buttonStyle(.bordered)
                    .disabled(!link.isConnected)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func copyControls(_ scan: RemoteScanInfo, _ copy: RemoteLink.CopyState) -> some View {
        switch copy.phase {
        case .queued, .copying, .waiting:
            ProgressView(value: copy.progress.fraction)
            Text(Self.copyText(copy))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Stop copy") { link.pauseCopy(scan.id) }
                .buttonStyle(.bordered)
        case .paused:
            ProgressView(value: copy.progress.fraction)
            Text(String(format: "Partly copied (%.0f %%)", copy.progress.fraction * 100))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Resume") { link.copy(scan.id) }
                    .buttonStyle(.bordered)
                    .disabled(!link.isConnected)
                Button("Discard", role: .destructive) { confirmDiscard = scan }
                    .buttonStyle(.bordered)
            }
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
            HStack {
                Button("Retry") { link.copy(scan.id) }
                    .buttonStyle(.bordered)
                    .disabled(!link.isConnected)
                Button("Discard", role: .destructive) { confirmDiscard = scan }
                    .buttonStyle(.bordered)
            }
        case .importing:
            HStack(spacing: 8) {
                ProgressView()
                Text("Adding to this phone's library…")
                    .font(.caption)
            }
        case .done:
            Label("Copied", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    // MARK: - Helpers

    private var canStart: Bool {
        guard link.isConnected, link.commandInFlight == nil, let status = link.status else { return false }
        return status.phase == .ready && !status.calibrating
    }

    private var canStop: Bool {
        guard link.isConnected, link.commandInFlight == nil, let status = link.status else { return false }
        return status.phase == .recording || status.phase == .arming
    }

    private var linkSymbol: String {
        switch link.linkState {
        case .connected: return "checkmark.circle.fill"
        case .lost, .problem: return "exclamationmark.triangle.fill"
        case .off, .waiting, .connecting: return "antenna.radiowaves.left.and.right"
        }
    }

    private var linkColor: Color {
        switch link.linkState {
        case .connected: return .green
        case .lost, .problem: return .orange
        case .off, .waiting, .connecting: return .primary
        }
    }

    static func phaseText(_ status: RemoteStatus?) -> String {
        guard let status else { return "Waiting for the scanner's status…" }
        switch status.phase {
        case .closed: return "Line scan is not open on the scanner"
        case .starting: return "Starting…"
        case .ready: return status.calibrating ? "Calibrating baseline…" : "Ready"
        case .arming: return "Starting recording…"
        case .recording:
            let seconds = Int(status.elapsed)
            return String(format: "● REC %ld:%02ld · %ld frames", seconds / 60, seconds % 60, status.frames)
        case .saving: return "Saving…"
        case .building: return "Building map…"
        case .failed: return "Error on the scanner"
        }
    }

    static func alerts(_ status: RemoteStatus) -> [String] {
        var lines: [String] = []
        if let banner = status.banner { lines.append(banner) }
        for warning in status.warnings where !lines.contains(warning) { lines.append(warning) }
        return lines
    }

    static func heatText(_ heat: RemoteHeat) -> String {
        switch heat {
        case .normal: return "Normal"
        case .serious: return "Hot: live overlay slowed"
        case .critical: return "Too hot: recording stopped"
        }
    }

    static func batteryText(_ status: RemoteStatus) -> String {
        guard let battery = status.battery else { return "—" }
        var text = String(format: "%.0f %%", battery * 100)
        if let charging = status.charging { text += charging ? " · charging" : " · on battery" }
        return text
    }

    static func copyText(_ copy: RemoteLink.CopyState) -> String {
        switch copy.phase {
        case .queued: return "Queued · " + copy.progress.text
        case .waiting(let reason): return reason + " · " + copy.progress.text
        default: return copy.progress.text
        }
    }
}
