import SwiftUI

/// Line scan screen › Remote: allow remote control, pair, forget (FR-RMT-01, FR-RMT-03).
struct RemoteScannerSheet: View {
    @Environment(RemoteLink.self) private var link
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Allow remote control", isOn: Binding(get: { link.mode == .scanner },
                                                                 set: { link.setMode($0 ? .scanner : .off) }))
                } footer: {
                    Text("A second iPhone with Phone LiDAR can then start and stop recordings, show this screen's readouts and copy saved Line scans. Wi-Fi must be on in Settings on both phones; no Wi-Fi network is needed.")
                }

                if link.mode == .scanner {
                    RemoteScannerSections()
                }
            }
            .navigationTitle("Remote control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// The scanner's link state and pairing (code, paired remote, forget), shown while remote control is allowed.
/// Used by the Line scan sheet and by Home › Connect to the other phone (FR-RMT-03).
struct RemoteScannerSections: View {
    @Environment(RemoteLink.self) private var link
    @State private var confirmForget = false

    var body: some View {
        Section("Link") {
            Label(link.stateText, systemImage: link.isConnected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                .foregroundStyle(link.isConnected ? Color.green : Color.primary)
            LabeledContent("This phone", value: link.identity.name)
            if let notice = link.scannerNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            if let window = link.pairingWindow {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if window.isOpen(at: context.date) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Pairing code")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(PairingCode.display(window.code))
                                .font(.system(size: 44, weight: .bold, design: .monospaced))
                                .accessibilityLabel("Pairing code \(window.code.map { String($0) }.joined(separator: " "))")
                            Text("On the other phone: Home › Connect to the other phone › Control a scanner phone, pick \(link.identity.name) and enter this code. \(Int(window.remaining(at: context.date))) s left.")
                                .font(.footnote)
                        }
                    } else {
                        Text("The code has expired.")
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Stop pairing", role: .cancel) { link.closePairingWindow() }
            } else {
                Button(link.pairedPeerName == nil ? "Pair a remote" : "Pair a different remote") {
                    link.openPairingWindow()
                }
            }
            if let name = link.pairedPeerName {
                LabeledContent("Paired remote", value: name)
                Button("Forget \(name)", role: .destructive) { confirmForget = true }
                    .confirmationDialog("Forget the paired remote?", isPresented: $confirmForget, titleVisibility: .visible) {
                        Button("Forget", role: .destructive) { link.forgetScannerPairing() }
                    } message: {
                        Text("It has to pair again with a new code before it can connect.")
                    }
            }
        } header: {
            Text("Pairing")
        } footer: {
            Text("Pair once. The paired remote reconnects by itself whenever it is in range. A recording keeps running when the link drops, and the Line scan screen stays open after each save so the remote can start the next recording.")
        }
    }
}

/// Remote-link state on the Line scan screen, shown while remote control is allowed.
struct RemoteStatusChip: View {
    @Environment(RemoteLink.self) private var link

    var body: some View {
        if link.mode == .scanner {
            Label(link.scannerChipText, systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(chipColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.7), in: Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var chipColor: Color {
        switch link.linkState {
        case .connected: return .green
        case .lost, .problem: return .orange
        case .off, .waiting, .connecting: return .white
        }
    }
}

/// Home › Remote link: one button to connect this phone with the other one, either way, plus the current role
/// with a shortcut (FR-RMT-01).
struct RemoteHomeSection: View {
    /// Opens Home › Connect to the other phone (`PhoneLinkSheet`).
    var openLink: () -> Void
    /// Opens the Remote screen (this phone is the remote).
    var openRemote: () -> Void

    @Environment(RemoteLink.self) private var link

    var body: some View {
        Section {
            Button(action: openLink) {
                HStack(spacing: 14) {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.title2)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect to the other phone")
                            .font(.headline)
                        Text("Let the other phone connect to this one (the mounted Line scan phone), or connect to it (the phone in your hand) to start and stop recordings, watch the readouts and copy scans.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            switch link.mode {
            case .scanner:
                HStack(spacing: 12) {
                    Label("Scanner: \(link.stateText)", systemImage: "barcode.viewfinder")
                        .font(.callout)
                    Spacer(minLength: 0)
                    Button("Turn off") { link.setMode(.off) }
                        .buttonStyle(.bordered)
                }
            case .remote:
                HStack(spacing: 12) {
                    Label("Remote: \(link.stateText)", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.callout)
                    Spacer(minLength: 0)
                    Button("Open", action: openRemote)
                        .buttonStyle(.bordered)
                }
            case .off:
                EmptyView()
            }
        } header: {
            Text("Remote link")
        }
    }
}

/// Home › Connect to the other phone: let the other phone connect to this one (scanner role) or connect to the
/// other phone (remote role). One role at a time (FR-RMT-01, FR-RMT-03).
struct PhoneLinkSheet: View {
    /// Closes this sheet and opens the Remote screen.
    var onControlScanner: () -> Void

    @Environment(RemoteLink.self) private var link
    @Environment(\.dismiss) private var dismiss
    /// This phone is the remote and the user turned on Allow remote control: asks before the remote link stops.
    @State private var confirmScanner = false
    /// This phone is the scanner and the user tapped Control a scanner phone: asks before remote control turns off.
    @State private var confirmRemote = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("This phone", value: link.identity.name)
                    LabeledContent("Role", value: roleText)
                } footer: {
                    Text("Both phones need Phone LiDAR open and Wi-Fi switched on in Settings; no Wi-Fi network is needed. A phone has one role at a time.")
                }

                Section {
                    Toggle("Allow remote control", isOn: allowRemoteControl)
                } header: {
                    Text("Let the other phone connect to this one")
                } footer: {
                    Text("Use this on the mounted Line scan phone. The other phone can then connect, show this phone's readouts and copy its saved Line scans. It can start and stop recordings while Line scan is open on this phone. The screen stays awake while this page is open.")
                }

                if link.mode == .scanner {
                    RemoteScannerSections()
                }

                Section {
                    Button {
                        if link.mode == .scanner {
                            confirmRemote = true
                        } else {
                            onControlScanner()
                        }
                    } label: {
                        Label(link.mode == .remote ? "Open Remote control" : "Control a scanner phone",
                              systemImage: "antenna.radiowaves.left.and.right")
                    }
                } header: {
                    Text("Connect to the other phone")
                } footer: {
                    Text("Use this on the phone in your hand: pick the scanner and enter the code it shows. Then start and stop its recordings, watch its readouts and copy its scans to this phone.")
                }
            }
            .navigationTitle("Connect phones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("This phone is the remote", isPresented: $confirmScanner, titleVisibility: .visible) {
                Button("Allow remote control of this phone") { link.setMode(.scanner) }
            } message: {
                Text("The link to the scanner stops and any copy pauses. The pairing is kept, so this phone can be the remote again later.")
            }
            .confirmationDialog("This phone is the scanner", isPresented: $confirmRemote, titleVisibility: .visible) {
                Button("Use this phone as the remote") {
                    link.setMode(.remote)
                    onControlScanner()
                }
            } message: {
                Text("Remote control of this phone turns off. The other phone can then no longer connect to it.")
            }
        }
        .keepScreenOn()
    }

    private var roleText: String {
        switch link.mode {
        case .off: return "Not connected"
        case .scanner: return "Scanner (the other phone connects to this one)"
        case .remote: return "Remote (this phone connects to the scanner)"
        }
    }

    /// On: this phone becomes the scanner (after a confirmation when it is the remote). Off: the link stops.
    private var allowRemoteControl: Binding<Bool> {
        Binding(get: { link.mode == .scanner },
                set: { allow in
                    if !allow {
                        link.setMode(.off)
                    } else if link.mode == .remote {
                        confirmScanner = true
                    } else {
                        link.setMode(.scanner)
                    }
                })
    }
}
