import SwiftUI

/// Line scan screen › Remote: allow remote control, pair, forget (FR-RMT-01, FR-RMT-03).
struct RemoteScannerSheet: View {
    @Environment(RemoteLink.self) private var link
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForget = false

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
                                        Text("On the other phone: Home › Remote link › Control a scanner phone, pick \(link.identity.name) and enter this code. \(Int(window.remaining(at: context.date))) s left.")
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
                        }
                    } header: {
                        Text("Pairing")
                    } footer: {
                        Text("Pair once. The paired remote reconnects by itself whenever it is in range. A recording keeps running when the link drops, and this screen stays open after each save so the remote can start the next recording.")
                    }
                }
            }
            .navigationTitle("Remote control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Forget the paired remote?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) { link.forgetScannerPairing() }
            } message: {
                Text("It has to pair again with a new code before it can connect.")
            }
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

/// Home › Remote link.
struct RemoteHomeSection: View {
    var openRemote: () -> Void

    @Environment(RemoteLink.self) private var link
    @State private var confirmSwitch = false

    var body: some View {
        Section {
            Button {
                if link.mode == .scanner {
                    confirmSwitch = true
                } else {
                    openRemote()
                }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title2)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Control a scanner phone")
                            .font(.headline)
                        Text(link.mode == .remote
                             ? link.stateText
                             : "Start and stop a mounted Line scan phone, watch its readouts and copy its scans to this phone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .confirmationDialog("This phone is the scanner", isPresented: $confirmSwitch, titleVisibility: .visible) {
                Button("Use this phone as the remote") {
                    link.setMode(.remote)
                    openRemote()
                }
            } message: {
                Text("Remote control of this phone turns off. The other phone can then no longer connect to it.")
            }

            if link.mode == .scanner {
                HStack(spacing: 12) {
                    Label("Scanner: \(link.stateText)", systemImage: "barcode.viewfinder")
                        .font(.callout)
                    Spacer(minLength: 0)
                    Button("Turn off") { link.setMode(.off) }
                        .buttonStyle(.bordered)
                }
            }
        } header: {
            Text("Remote link")
        }
    }
}
