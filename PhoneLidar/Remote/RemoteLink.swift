import Foundation
import Network
import SwiftUI
import UIKit

/// What the Line scan screen offers the remote link on the scanner (FR-RMT-05, FR-RMT-07, FR-RMT-08).
@MainActor
protocol RemoteScannerTarget: AnyObject {
    /// The Line scan part of the status; `RemoteLink` adds storage, battery and the scan-list version.
    func remoteLineStatus() -> RemoteStatus
    /// Starts a recording exactly as the record button does. Nil when it is starting; otherwise the reason.
    func remoteStart() -> String?
    /// Stops the recording exactly as the record button does. Nil when it is stopping; otherwise the reason.
    func remoteStop() -> String?
}

/// The phone-to-phone remote link (FR-RMT, design §3.9, §6.15). One per app, in the SwiftUI environment.
@MainActor
@Observable
final class RemoteLink {
    enum Mode: String {
        case off
        case scanner
        case remote
    }

    enum LinkState: Equatable {
        case off
        /// Scanner: advertising, no remote connected. Remote: searching, or not paired.
        case waiting
        case connecting(String)
        case connected(String)
        /// The link dropped (reason); it comes back by itself.
        case lost(String)
        case problem(String)
    }

    typealias CopyPhase = RemoteCopyPhase
    typealias CopyState = RemoteCopyState

    private struct ActiveTransfer {
        let id: UInt32
        let scanID: UUID
        let name: String
        /// Bytes of the scan's files that were complete before this file.
        let baseBytes: Int64
    }

    private enum Keys {
        static let mode = "remoteLinkMode"
        static let deviceID = "remoteDeviceID"
    }

    // MARK: - State shown by the views

    private(set) var mode: Mode
    private(set) var linkState: LinkState = .off
    let identity: RemoteIdentity

    // Scanner
    private(set) var pairingWindow: PairingWindow?
    private(set) var pairedPeerName: String?
    private(set) var scannerNotice: String?

    // Remote
    private(set) var foundScanners: [FoundScanner] = []
    private(set) var remotePairing: RemotePairing?
    /// Scanner a pairing attempt is running with.
    private(set) var pairingTarget: UUID?
    private(set) var pairError: String?
    private(set) var status: RemoteStatus?
    private(set) var commandInFlight: RemoteAction?
    private(set) var commandFeedback: String?
    private(set) var scannerScans: [RemoteScanInfo] = []
    private(set) var scansLoaded = false
    private(set) var copies: [UUID: CopyState] = [:]
    /// Partly copied scans that the paired scanner does not offer now (deleted there, another scanner, list cut):
    /// shown so they can be discarded.
    private(set) var partialCopies: [RemoteStaging.Partial] = []

    // MARK: - Private

    @ObservationIgnored private let store: ScanStore
    @ObservationIgnored private let queue = DispatchQueue(label: "phonelidar.remote.link", qos: .userInitiated)
    @ObservationIgnored private var appActive = false

    // Scanner
    @ObservationIgnored private let secrets = ScannerSecrets()
    @ObservationIgnored private var listener: RemoteListener?
    @ObservationIgnored private var listenerRestart: Task<Void, Never>?
    /// Connections still in their handshake, oldest first.
    @ObservationIgnored private var pending: [RemoteConnection] = []
    @ObservationIgnored private var active: RemoteConnection?
    @ObservationIgnored private weak var target: RemoteScannerTarget?
    @ObservationIgnored private var statusLoop: Task<Void, Never>?
    @ObservationIgnored private var lastStatusBusy = false
    @ObservationIgnored private var freeBytes: Int64?
    @ObservationIgnored private var statusTicks = 0
    @ObservationIgnored private var scanListGeneration = 0
    @ObservationIgnored private var scannerPermissionDenied = false
    /// A scan list asked for while recording: sent when the scanner is idle again.
    @ObservationIgnored private var listRequestedWhileBusy = false

    // Remote
    @ObservationIgnored private var browser: RemoteBrowser?
    @ObservationIgnored private var browserRestart: Task<Void, Never>?
    @ObservationIgnored private var connection: RemoteConnection?
    @ObservationIgnored private var connectionOpen = false
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var commandCounter: UInt32 = 0
    @ObservationIgnored private var pendingCommandID: UInt32?
    @ObservationIgnored private var commandTimeout: Task<Void, Never>?
    @ObservationIgnored private var transferCounter: UInt32 = 0
    @ObservationIgnored private var copyQueue: [UUID] = []
    @ObservationIgnored private var activeTransfer: ActiveTransfer?
    @ObservationIgnored private var awaitingScanList = false
    /// After a `busy` refusal: no new file request until the next status arrives.
    @ObservationIgnored private var waitingForStatus = false
    @ObservationIgnored private var lastScansVersion: Int?

    init(store: ScanStore) {
        self.store = store
        identity = Self.loadIdentity()
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: Keys.mode) ?? "") ?? .off
    }

    private static func loadIdentity() -> RemoteIdentity {
        let defaults = UserDefaults.standard
        let id: UUID
        if let text = defaults.string(forKey: Keys.deviceID), let saved = UUID(uuidString: text) {
            id = saved
        } else {
            id = UUID()
            defaults.set(id.uuidString, forKey: Keys.deviceID)
        }
        return RemoteIdentity(id: id, name: "\(UIDevice.current.name) \(id.uuidString.prefix(4))")
    }

    // MARK: - Mode and lifecycle

    var isConnected: Bool {
        if case .connected = linkState { return true }
        return false
    }

    var pairedScannerName: String? { remotePairing?.peerName }
    var pairedScannerID: UUID? { remotePairing?.peerID }

    /// One role at a time; the role is kept across launches (FR-RMT-01).
    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        stopEverything()
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Keys.mode)
        scannerNotice = nil
        pairError = nil
        startIfNeeded()
    }

    /// The link runs only while the app is in the foreground (FR-RMT-12).
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            appActive = true
            startIfNeeded()
        case .background:
            appActive = false
            stopEverything()
        default:
            break
        }
    }

    private func startIfNeeded() {
        guard appActive else { return }
        switch mode {
        case .off:
            linkState = .off
        case .scanner:
            startScanner()
        case .remote:
            startRemote()
        }
    }

    private func stopEverything() {
        listenerRestart?.cancel()
        listenerRestart = nil
        listener?.cancel()
        listener = nil
        for connection in pending { connection.cancel() }
        pending = []
        active?.cancel()
        active = nil
        statusLoop?.cancel()
        statusLoop = nil
        pairingWindow = nil
        secrets.setWindow(nil)

        browserRestart?.cancel()
        browserRestart = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        connectionOpen = false
        foundScanners = []
        pairingTarget = nil
        if pendingCommandID != nil { finishCommand("The link was stopped before the scanner answered.") }
        pauseActiveTransfer(waiting: "Continues when the link is back")
        linkState = .off
    }

    // MARK: - Texts

    var stateText: String {
        switch linkState {
        case .off:
            return "Off"
        case .waiting:
            if mode == .scanner {
                return pairedPeerName.map { "Waiting for \($0) to connect" } ?? "Waiting for a remote to pair"
            }
            return pairedScannerName.map { "Searching for \($0)…" } ?? "Not paired: pick a scanner below"
        case .connecting(let name):
            return "Connecting to \(name)…"
        case .connected(let name):
            return "Connected to \(name)"
        case .lost(let reason):
            return mode == .scanner
                ? "Link lost (\(reason)). The scanner keeps running; the remote reconnects by itself."
                : "Link lost (\(reason)). Reconnecting…"
        case .problem(let text):
            return text
        }
    }

    /// Short text for the chip on the Line scan screen.
    var scannerChipText: String {
        switch linkState {
        case .connected(let name): return "Remote: \(name)"
        case .lost: return "Remote: link lost, waiting"
        case .problem: return "Remote: see Remote settings"
        case .off, .waiting, .connecting: return "Remote: waiting"
        }
    }

    // MARK: - Scanner side

    func attachScanner(_ newTarget: RemoteScannerTarget) {
        target = newTarget
        sendStatus()
    }

    func detachScanner(_ oldTarget: RemoteScannerTarget) {
        if target === oldTarget { target = nil }
        sendStatus()
    }

    /// The Line scan screen of this phone starts a recording (record button or remote command). A scanner stops
    /// any file send at once; a remote pauses its own copy while it records (NFR-REL-07).
    func recordingStarts() {
        switch mode {
        case .scanner:
            guard let connection = active else { return }
            lastStatusBusy = true
            connection.stopSending(reason: .busy, message: "The scanner started recording; the copy continues when it is idle.")
            sendStatus()
        case .remote:
            if let transfer = activeTransfer {
                connection?.cancelFile(transferID: transfer.id)
                activeTransfer = nil
            }
            for id in copyQueue { copies[id]?.phase = .waiting(Self.localRecordingText) }
        case .off:
            break
        }
    }

    private static let localRecordingText = "Paused while this phone records"

    /// True while this phone's own Line scan screen records, saves or builds a map.
    private var localBusy: Bool {
        target?.remoteLineStatus().isBusy ?? false
    }

    func openPairingWindow() {
        let window = PairingWindow(now: Date())
        secrets.setWindow(window)
        pairingWindow = window
        scannerNotice = nil
    }

    func closePairingWindow() {
        secrets.setWindow(nil)
        pairingWindow = nil
    }

    func forgetScannerPairing() {
        RemoteKeychain.delete(account: RemoteKeychain.scannerAccount)
        secrets.setPairing(nil)
        pairedPeerName = nil
        active?.cancel()
        active = nil
        statusLoop?.cancel()
        statusLoop = nil
        scannerNotice = nil
        linkState = mode == .scanner && appActive ? .waiting : .off
    }

    private func startScanner() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let pairing = RemoteKeychain.load(account: RemoteKeychain.scannerAccount)
        secrets.setPairing(pairing)
        pairedPeerName = pairing?.peerName
        if active == nil { linkState = .waiting }
        if listener == nil { startListener() }
    }

    private func startListener() {
        let newListener = RemoteListener(identity: identity, queue: queue)
        newListener.onEvent = { [weak self, weak newListener] event in
            guard let self, let newListener, self.listener === newListener else { return }
            self.listenerEvent(event)
        }
        newListener.onConnection = { [weak self] box in
            self?.accept(box.connection)
        }
        listener = newListener
        do {
            try newListener.start()
        } catch {
            listenerFailed(error.localizedDescription)
        }
    }

    private func listenerEvent(_ event: RemoteListener.Event) {
        guard mode == .scanner, appActive else { return }
        switch event {
        case .ready:
            // A ready listener does not prove Local Network access; only the probe does.
            if active == nil, !scannerPermissionDenied, case .problem = linkState { linkState = .waiting }
        case .permissionGranted:
            scannerPermissionDenied = false
            if active == nil, case .problem = linkState { linkState = .waiting }
        case .permissionDenied:
            scannerPermissionDenied = true
            if active == nil { linkState = .problem(RemoteCloseReason.permissionText) }
        case .failed(let message):
            listenerFailed(message)
        }
    }

    /// The scanner keeps trying: a failed listener is started again after 2 s (FR-RMT-06).
    private func listenerFailed(_ message: String) {
        listener?.cancel()
        listener = nil
        if active == nil { linkState = .problem("The link stopped (\(message)); restarting…") }
        listenerRestart?.cancel()
        listenerRestart = Task { [weak self] in
            try? await Task.sleep(for: .seconds(RemoteLinkConstants.listenerRestartDelay))
            guard let self, !Task.isCancelled else { return }
            self.listenerRestart = nil
            guard self.mode == .scanner, self.appActive, self.listener == nil else { return }
            self.startListener()
        }
    }

    private func accept(_ accepted: NWConnection) {
        guard mode == .scanner, appActive, listener != nil else {
            accepted.cancel()
            return
        }
        // A full set of handshakes makes room by dropping the oldest one that has not sent a hello (silent
        // connections); handshakes in progress are kept and the new connection is refused instead.
        if pending.count >= RemoteLinkConstants.maxPendingConnections {
            guard let index = pending.firstIndex(where: { !$0.hasHello }) else {
                accepted.cancel()
                return
            }
            pending.remove(at: index).cancel()
        }
        let connection = RemoteConnection(accepted: accepted, side: .scanner(secrets), identity: identity, queue: queue)
        let cid = connection.id
        connection.onOpen = { [weak self] opened in self?.scannerOpened(cid, opened) }
        connection.onMessage = { [weak self] message in self?.scannerReceived(cid, message) }
        connection.onClose = { [weak self] reason, _ in self?.scannerClosed(cid, reason) }
        connection.onWrongCode = { [weak self] in self?.wrongCodeEntered() }
        pending.append(connection)
        connection.start()
    }

    private func scannerOpened(_ cid: UUID, _ opened: RemoteConnection.Opened) {
        guard let index = pending.firstIndex(where: { $0.id == cid }) else {
            // Replaced by a newer handshake after it had finished: the remote already holds the new key, so the
            // pairing is stored here too and the remote's next connection resumes with it.
            if opened.newPairingKey != nil, mode == .scanner, appActive { storePairing(opened) }
            return
        }
        let connection = pending.remove(at: index)
        guard mode == .scanner, appActive else {
            connection.cancel()
            return
        }
        if opened.newPairingKey != nil {
            storePairing(opened)
        } else if secrets.currentPairing?.peerID != opened.peerID {
            // Another remote paired while this one was connecting.
            connection.cancel()
            return
        }
        // An authenticated connection replaces the previous one (a remote that reconnected before this phone
        // noticed the drop, or a newly paired remote).
        active?.cancel()
        active = connection
        linkState = .connected(opened.peerName)
        lastStatusBusy = false
        startStatusLoop()
        sendStatus()
    }

    private func storePairing(_ opened: RemoteConnection.Opened) {
        guard let key = opened.newPairingKey else { return }
        let pairing = RemotePairing(peerID: opened.peerID, peerName: opened.peerName, key: key, created: Date())
        secrets.setPairing(pairing)
        closePairingWindow()
        pairedPeerName = opened.peerName
        do {
            try RemoteKeychain.save(pairing, account: RemoteKeychain.scannerAccount)
            scannerNotice = "Paired with \(opened.peerName)."
        } catch {
            scannerNotice = "Paired with \(opened.peerName) until the app closes: \(error.localizedDescription)"
        }
    }

    private func scannerClosed(_ cid: UUID, _ reason: RemoteCloseReason) {
        if let index = pending.firstIndex(where: { $0.id == cid }) {
            pending.remove(at: index)
            return
        }
        guard let current = active, current.id == cid else { return }
        active = nil
        statusLoop?.cancel()
        statusLoop = nil
        guard mode == .scanner, appActive else { return }
        linkState = .lost(reason.text)
    }

    private func wrongCodeEntered() {
        pairingWindow = secrets.currentWindow
        scannerNotice = "A wrong code was entered on a remote phone."
    }

    private func scannerReceived(_ cid: UUID, _ message: RemoteMessage) {
        guard let connection = active, connection.id == cid else { return }
        switch message {
        case .command(let id, let action):
            runCommand(id: id, action: action, on: connection)
        case .listScans:
            if localBusy {
                listRequestedWhileBusy = true        // folder listing waits until the recording is saved
            } else {
                sendScanList(on: connection)
            }
        case .fileRequest(let request):
            serveFile(request, on: connection)
        default:
            break
        }
    }

    private func runCommand(id: UInt32, action: RemoteAction, on connection: RemoteConnection) {
        let refusal: String?
        if let target {
            switch action {
            case .startRecording: refusal = target.remoteStart()
            case .stopRecording: refusal = target.remoteStop()
            }
        } else {
            refusal = "Line scan is not open on the scanner."
        }
        connection.send(.commandResult(id: id, accepted: refusal == nil, message: refusal))
        sendStatus()
    }

    private func startStatusLoop() {
        statusLoop?.cancel()
        statusLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(RemoteLinkConstants.statusInterval))
                guard let self, !Task.isCancelled else { return }
                self.sendStatus()
            }
        }
    }

    /// Current status to the connected remote. Stops a file send when the scanner becomes busy (NFR-REL-07).
    private func sendStatus() {
        guard let connection = active else { return }
        var current = target?.remoteLineStatus() ?? .closed
        statusTicks += 1
        if freeBytes == nil || statusTicks % 4 == 0 {
            freeBytes = LineStorage.freeBytes(at: store.root)
        }
        current.freeBytes = freeBytes
        let device = UIDevice.current
        current.battery = device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil
        switch device.batteryState {
        case .unknown: current.charging = nil
        case .charging, .full: current.charging = true
        case .unplugged: current.charging = false
        @unknown default: current.charging = nil
        }
        current.scansVersion = scansVersion()
        if current.isBusy && !lastStatusBusy {
            connection.stopSending(reason: .busy, message: "The scanner started recording; the copy continues when it is idle.")
        }
        lastStatusBusy = current.isBusy
        connection.send(.status(current.sanitized()))
        if !current.isBusy, listRequestedWhileBusy {
            listRequestedWhileBusy = false
            sendScanList(on: connection)
        }
    }

    /// Saved Line scans not being recorded or built, newest first.
    private func copyableScans() -> [ScanRecord] {
        let active = store.activeLineFolders
        var seen = Set<UUID>()
        // One entry per ID (a folder duplicated in the Files app keeps its ID); the newest is kept, which is also
        // the record `store.record(id:)` serves.
        return Array(store.scans
            .filter { $0.kind == .line && !active.contains($0.folderName) && seen.insert($0.id).inserted }
            .prefix(RemoteLinkConstants.maxListedScans))
    }

    private func scansVersion() -> Int {
        var hasher = Hasher()
        for scan in copyableScans() {
            hasher.combine(scan.id)
            hasher.combine(scan.name)
            hasher.combine(scan.files)
        }
        return hasher.finalize()
    }

    /// Lists the folders off the main actor; only the newest request's list is sent, so lists arrive in order,
    /// and the list is cut to the newest scans that fit one frame.
    private func sendScanList(on connection: RemoteConnection) {
        let items = copyableScans().map { scan in
            (RemoteScanInfo(id: scan.id, name: scan.name, created: scan.created, summary: scan.summary, files: []),
             store.folderURL(for: scan))
        }
        scanListGeneration += 1
        let generation = scanListGeneration
        let cid = connection.id
        Task { [weak self] in
            let list = await Task.detached(priority: .utility) {
                RemoteScanList.fitting(items.map { item -> RemoteScanInfo in
                    var info = item.0
                    info.files = RemoteFiles.list(folder: item.1)
                    return info
                })
            }.value
            guard let self, self.scanListGeneration == generation,
                  let current = self.active, current.id == cid else { return }
            current.send(.scans(list))
        }
    }

    /// Validates a file request against this phone's own listing (FR-RMT-04), then starts the send.
    private func serveFile(_ request: RemoteFileRequest, on connection: RemoteConnection) {
        func refuse(_ reason: RemoteFileProblem, _ message: String) {
            connection.send(.fileError(transferID: request.transferID, reason: reason, message: message))
        }
        let current = target?.remoteLineStatus() ?? .closed
        guard !current.isBusy else {
            refuse(.busy, "The scanner is recording, saving or building a map.")
            return
        }
        guard RemoteFiles.isPlainName(request.name), !RemoteFiles.excludedNames.contains(request.name),
              let record = store.record(id: request.scanID), record.kind == .line,
              !store.activeLineFolders.contains(record.folderName) else {
            refuse(.missing, "\(request.name) is not offered by the scanner.")
            return
        }
        let url = store.folderURL(for: record).appendingPathComponent(request.name)
        guard let info = RemoteFiles.info(of: url) else {
            refuse(.missing, "\(request.name) is no longer on the scanner.")
            return
        }
        guard RemoteFiles.matches(info, size: request.size, modified: request.modified) else {
            refuse(.changed, "\(request.name) changed on the scanner.")
            return
        }
        guard request.offset >= 0, request.offset <= info.size else {
            refuse(.failed, "The copy asked for a part of \(request.name) that does not exist.")
            return
        }
        connection.startSending(request, url: url)
    }

    // MARK: - Remote side

    private func startRemote() {
        remotePairing = RemoteKeychain.load(account: RemoteKeychain.remoteAccount)
        refreshPartials()
        if connection == nil { linkState = .waiting }
        if browser == nil { startBrowser() }
    }

    private func startBrowser() {
        let newBrowser = RemoteBrowser(queue: queue)
        newBrowser.onEvent = { [weak self, weak newBrowser] event in
            guard let self, let newBrowser, self.browser === newBrowser else { return }
            self.browserEvent(event)
        }
        newBrowser.onResults = { [weak self, weak newBrowser] found in
            guard let self, let newBrowser, self.browser === newBrowser else { return }
            self.browseResults(found)
        }
        browser = newBrowser
        newBrowser.start()
    }

    private func browserEvent(_ event: RemoteBrowser.Event) {
        guard mode == .remote, appActive else { return }
        switch event {
        case .ready:
            if connection == nil, case .problem = linkState { linkState = .waiting }
        case .permissionDenied:
            if connection == nil { linkState = .problem(RemoteCloseReason.permissionText) }
        case .failed(let message):
            browser?.cancel()
            browser = nil
            foundScanners = []
            if connection == nil { linkState = .problem("Searching stopped (\(message)); restarting…") }
            browserRestart?.cancel()
            browserRestart = Task { [weak self] in
                try? await Task.sleep(for: .seconds(RemoteLinkConstants.listenerRestartDelay))
                guard let self, !Task.isCancelled else { return }
                self.browserRestart = nil
                guard self.mode == .remote, self.appActive, self.browser == nil else { return }
                self.startBrowser()
            }
        }
    }

    private func browseResults(_ found: [FoundScanner]) {
        foundScanners = found.filter { $0.id != identity.id }
        connectIfPossible()
    }

    private func connectIfPossible() {
        guard mode == .remote, appActive, connection == nil, reconnectTask == nil, pairingTarget == nil,
              let pairing = remotePairing,
              let scanner = foundScanners.first(where: { $0.id == pairing.peerID }),
              !scanner.endpoints.isEmpty else { return }
        connect(to: scanner, handshake: .resume, secret: pairing.key)
    }

    private func connect(to scanner: FoundScanner, handshake: HandshakeMessage.Mode, secret: Data) {
        let endpoint = scanner.endpoints[failures % scanner.endpoints.count]
        let newConnection = RemoteConnection(endpoint: endpoint,
                                             side: .remote(mode: handshake, secret: secret, expectedScanner: scanner.id),
                                             identity: identity, queue: queue)
        let cid = newConnection.id
        newConnection.onOpen = { [weak self] opened in self?.remoteOpened(cid, opened) }
        newConnection.onMessage = { [weak self] message in self?.remoteReceived(cid, message) }
        newConnection.onClose = { [weak self] reason, _ in self?.remoteClosed(cid, reason) }
        newConnection.onFileProgress = { [weak self] transferID, bytes in self?.fileProgress(cid, transferID, bytes) }
        newConnection.onFileDone = { [weak self] transferID in self?.fileDone(cid, transferID) }
        newConnection.onFileFailed = { [weak self] transferID, message in self?.fileFailed(cid, transferID, message) }
        connection = newConnection
        connectionOpen = false
        linkState = .connecting(scanner.name)
        newConnection.start()
    }

    /// Pairs with a scanner found nearby, using the code it shows (FR-RMT-03).
    func pair(with scanner: FoundScanner, code text: String) {
        guard mode == .remote, appActive else { return }
        guard let code = PairingCode.normalized(text) else {
            pairError = "Enter the 6 digits shown on the scanner."
            return
        }
        guard !scanner.endpoints.isEmpty else {
            pairError = "\(scanner.name) is out of reach."
            return
        }
        // A phone pretending to be the scanner could learn the code from a pairing attempt (NFR-SEC-06), so pairing
        // is refused while two services claim the same scanner ID or name.
        let clash = foundScanners.contains { other in
            other.id != scanner.id && other.names.contains(where: { scanner.names.contains($0) || $0 == scanner.name })
        }
        guard !scanner.isAmbiguous, !clash else {
            pairError = "More than one phone answers as \(scanner.name), so pairing is refused. Make sure only the scanner has Allow remote control on, move away from other phones, then try again."
            return
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        dropConnection()
        pairError = nil
        pairingTarget = scanner.id
        failures = 0
        connect(to: scanner, handshake: .pair, secret: RemoteHandshake.pairingSecret(code: code))
    }

    func forgetScanner() {
        RemoteKeychain.delete(account: RemoteKeychain.remoteAccount)
        remotePairing = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        dropConnection()
        status = nil
        scannerScans = []
        scansLoaded = false
        for id in copyQueue { copies[id]?.phase = .paused }
        copyQueue.removeAll()
        refreshPartials()
        linkState = mode == .remote && appActive ? .waiting : .off
    }

    /// Stops the remote link on this phone (the pairing is kept).
    func disconnect() {
        setMode(.off)
    }

    /// Closes the current connection without reconnecting from its close callback.
    private func dropConnection() {
        connection?.cancel()
        connection = nil
        connectionOpen = false
        if pendingCommandID != nil { finishCommand("The link was closed before the scanner answered.") }
        pauseActiveTransfer(waiting: "Continues when the link is back")
    }

    private func remoteOpened(_ cid: UUID, _ opened: RemoteConnection.Opened) {
        guard let current = connection, current.id == cid else { return }
        connectionOpen = true
        failures = 0
        pairError = nil
        if let key = opened.newPairingKey {
            let pairing = RemotePairing(peerID: opened.peerID, peerName: opened.peerName, key: key, created: Date())
            remotePairing = pairing
            pairingTarget = nil
            do {
                try RemoteKeychain.save(pairing, account: RemoteKeychain.remoteAccount)
            } catch {
                pairError = "Paired until the app closes: \(error.localizedDescription)"
            }
        }
        linkState = .connected(opened.peerName)
        // The scanner sends its status straight away; a new scan-list version asks for the list.
        lastScansVersion = nil
    }

    private func remoteClosed(_ cid: UUID, _ reason: RemoteCloseReason) {
        guard let current = connection, current.id == cid else { return }
        connection = nil
        connectionOpen = false
        if pendingCommandID != nil { finishCommand("The link was lost before the scanner answered.") }
        pauseActiveTransfer(waiting: "Link lost: continues after reconnecting")
        guard mode == .remote, appActive else { return }
        if pairingTarget != nil {
            pairingTarget = nil
            pairError = "Pairing failed: \(reason.text)."
            linkState = .waiting
            connectIfPossible()
            return
        }
        // A refusal is not authenticated (any phone can claim to be the scanner), so it never removes the pairing;
        // a `notPaired` refusal is shown and the remote keeps trying.
        linkState = .lost(reason.text)
        scheduleReconnect()
    }

    /// Retries 1, 2, 4, then every 5 s; every third failure restarts the browser (FR-RMT-06).
    private func scheduleReconnect() {
        reconnectTask?.cancel()
        failures += 1
        let delays = RemoteLinkConstants.reconnectDelays
        let delay = delays[min(failures - 1, delays.count - 1)]
        let restartBrowser = failures % 3 == 0
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            guard self.mode == .remote, self.appActive else { return }
            if restartBrowser {
                self.browser?.cancel()
                self.browser = nil
                self.foundScanners = []
                self.startBrowser()
            } else {
                self.connectIfPossible()
            }
        }
    }

    private func remoteReceived(_ cid: UUID, _ message: RemoteMessage) {
        guard let current = connection, current.id == cid, connectionOpen else { return }
        switch message {
        case .status(let received):
            // Numbers from the other phone are bounded before any view converts them.
            let newStatus = received.sanitized()
            status = newStatus
            waitingForStatus = false
            if lastScansVersion != newStatus.scansVersion {
                lastScansVersion = newStatus.scansVersion
                requestScanList()
            }
            if !newStatus.isBusy { pumpCopies() }
        case .commandResult(let id, let accepted, let text):
            commandAnswered(id: id, accepted: accepted, text: text)
        case .scans(let list):
            receivedScans(list)
        case .fileError(let transferID, let reason, let text):
            fileRefused(transferID, reason: reason, text: text)
        default:
            break
        }
    }

    // MARK: Commands

    /// Start or Stop on the scanner; the answer (or 5 s without one) is shown (FR-RMT-07).
    func sendCommand(_ action: RemoteAction) {
        guard let current = connection, connectionOpen, pendingCommandID == nil else { return }
        commandCounter &+= 1
        let id = commandCounter
        pendingCommandID = id
        commandInFlight = action
        commandFeedback = "Waiting for the scanner…"
        current.send(.command(id: id, action: action))
        commandTimeout?.cancel()
        commandTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(RemoteLinkConstants.commandTimeout))
            guard let self, !Task.isCancelled, self.pendingCommandID == id else { return }
            self.finishCommand("No answer from the scanner.")
        }
    }

    private func commandAnswered(id: UInt32, accepted: Bool, text: String?) {
        guard pendingCommandID == id, let action = commandInFlight else { return }
        if accepted {
            finishCommand(action == .startRecording ? "Recording started." : "Recording stopped: the scanner is saving it.")
        } else {
            finishCommand("Refused: " + (text ?? "no reason given."))
        }
    }

    private func finishCommand(_ feedback: String) {
        pendingCommandID = nil
        commandInFlight = nil
        commandTimeout?.cancel()
        commandTimeout = nil
        commandFeedback = feedback
    }

    // MARK: Scan list and copies

    func refreshScans() {
        requestScanList()
    }

    private func requestScanList() {
        guard let current = connection, connectionOpen else { return }
        current.send(.listScans)
    }

    private var stagingRoot: URL {
        RemoteStaging.root(applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory,
                                                                         in: .userDomainMask)[0])
    }

    private func stagingFolder(_ scanID: UUID) -> URL {
        RemoteStaging.folder(for: scanID, root: stagingRoot)
    }

    private func receivedScans(_ list: [RemoteScanInfo]) {
        awaitingScanList = false
        // Entries from the other phone are checked before use: names, sizes and totals (no traps on peer input).
        scannerScans = RemoteScanList.uniqueByID(list.filter { RemoteFiles.isAcceptable($0) })
        scansLoaded = true
        for scan in scannerScans where activeTransfer?.scanID != scan.id {
            reconcileStaging(scan)
        }
        for id in copyQueue where !scannerScans.contains(where: { $0.id == id }) {
            copies[id]?.phase = .failed("No longer offered by the scanner.")
        }
        copyQueue.removeAll { id in !scannerScans.contains { $0.id == id } }
        refreshPartials()
        pumpCopies()
    }

    /// Staging folders of scans the scanner does not offer now (not queued or copying).
    private func refreshPartials() {
        let offered = Set(scannerScans.map(\.id))
        partialCopies = RemoteStaging.partials(root: stagingRoot).filter { partial in
            !offered.contains(partial.id) && !copyQueue.contains(partial.id) && activeTransfer?.scanID != partial.id
        }
    }

    /// Drops staged files that no longer match the scanner's files, and shows partly copied scans.
    private func reconcileStaging(_ scan: RemoteScanInfo) {
        let folder = stagingFolder(scan.id)
        guard let manifest = RemoteStaging.loadManifest(in: folder) else { return }
        let manager = FileManager.default
        do {
            for name in RemoteStaging.filesToDiscard(old: manifest.scan, new: scan) {
                let url = folder.appendingPathComponent(name)
                if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            }
            if manifest.scan != scan {
                try RemoteStaging.saveManifest(RemoteStagingManifest(scan: scan, scannerName: manifest.scannerName,
                                                                     started: manifest.started), in: folder)
            }
        } catch {
            copyQueue.removeAll { $0 == scan.id }
            copies[scan.id] = CopyState(phase: .failed("The partly copied files could not be updated (\(error.localizedDescription)). Discard and copy again."),
                                        progress: TransferProgress(total: scan.totalBytes))
            return
        }
        let staged = RemoteStaging.stagedBytes(sizes: RemoteStaging.stagedSizes(in: folder, scan: scan), scan: scan)
        if copies[scan.id] == nil {
            copies[scan.id] = CopyState(phase: .paused, progress: TransferProgress(total: scan.totalBytes, done: staged))
        } else if copyQueue.contains(scan.id) {
            copies[scan.id]?.progress = TransferProgress(total: scan.totalBytes, done: staged)
        }
    }

    /// Copy to this phone (FR-RMT-10, FR-RMT-11). Also Resume and Retry.
    func copy(_ scanID: UUID) {
        guard let scan = scannerScans.first(where: { $0.id == scanID }), !copyQueue.contains(scanID) else { return }
        guard store.record(id: scanID) == nil else {
            copies[scanID] = nil
            return
        }
        let folder = stagingFolder(scanID)
        let staged = RemoteStaging.stagedBytes(sizes: RemoteStaging.stagedSizes(in: folder, scan: scan), scan: scan)
        let needed = RemoteFiles.neededFreeBytes(remaining: scan.totalBytes - staged)
        if let free = LineStorage.freeBytes(at: store.root), free < needed {
            copies[scanID] = CopyState(phase: .failed("Not enough free storage on this phone: \(LineStorage.text(free)) free, \(LineStorage.text(needed)) needed."),
                                       progress: TransferProgress(total: scan.totalBytes, done: staged))
            return
        }
        do {
            let existing = RemoteStaging.loadManifest(in: folder)
            try RemoteStaging.saveManifest(RemoteStagingManifest(scan: scan,
                                                                 scannerName: existing?.scannerName ?? pairedScannerName ?? "the scanner",
                                                                 started: existing?.started ?? Date()), in: folder)
        } catch {
            copies[scanID] = CopyState(phase: .failed("The copy could not be prepared (\(error.localizedDescription))."),
                                       progress: TransferProgress(total: scan.totalBytes, done: staged))
            return
        }
        copies[scanID] = CopyState(phase: .queued, progress: TransferProgress(total: scan.totalBytes, done: staged))
        copyQueue.append(scanID)
        pumpCopies()
    }

    func pauseCopy(_ scanID: UUID) {
        copyQueue.removeAll { $0 == scanID }
        if let transfer = activeTransfer, transfer.scanID == scanID {
            connection?.cancelFile(transferID: transfer.id)
            activeTransfer = nil
        }
        copies[scanID]?.phase = .paused
        copies[scanID]?.progress.resetRate()
        pumpCopies()
    }

    func discardCopy(_ scanID: UUID) {
        pauseCopy(scanID)
        let folder = stagingFolder(scanID)
        do {
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            copies[scanID] = nil
        } catch {
            copies[scanID]?.phase = .failed("The partly copied files could not be deleted (\(error.localizedDescription)).")
        }
        refreshPartials()
    }

    /// The active file transfer stops (link lost or closed); the scan stays queued and continues later.
    private func pauseActiveTransfer(waiting text: String) {
        if let transfer = activeTransfer {
            activeTransfer = nil
            copies[transfer.scanID]?.progress.resetRate()
        }
        for id in copyQueue {
            copies[id]?.phase = .waiting(text)
        }
    }

    /// Starts the next file of the first queued scan, or imports a scan whose files are all staged.
    private func pumpCopies() {
        guard activeTransfer == nil, !awaitingScanList, !waitingForStatus, let current = connection,
              connectionOpen else { return }
        while let scanID = copyQueue.first {
            guard let scan = scannerScans.first(where: { $0.id == scanID }) else {
                copyQueue.removeFirst()
                copies[scanID]?.phase = .failed("No longer offered by the scanner.")
                continue
            }
            guard let scannerStatus = status, !scannerStatus.isBusy, !localBusy else {
                let text = localBusy ? Self.localRecordingText
                    : (status == nil ? "Waiting for the scanner's status" : "Paused while the scanner records, saves or builds a map")
                for id in copyQueue { copies[id]?.phase = .waiting(text) }
                return
            }
            let folder = stagingFolder(scanID)
            let sizes = RemoteStaging.stagedSizes(in: folder, scan: scan)
            guard let file = scan.files.first(where: { sizes[$0.name] != $0.size }) else {
                importCopy(scan, staging: folder)
                continue
            }
            let offset = RemoteFiles.resumeOffset(stagedSize: sizes[file.name], expectedSize: file.size)
            let baseBytes = scan.files.filter { sizes[$0.name] == $0.size }.reduce(Int64(0)) { $0 + $1.size }
            transferCounter &+= 1
            let request = RemoteFileRequest(transferID: transferCounter, scanID: scanID, name: file.name,
                                            offset: offset, size: file.size, modified: file.modified)
            activeTransfer = ActiveTransfer(id: transferCounter, scanID: scanID, name: file.name, baseBytes: baseBytes)
            copies[scanID]?.phase = .copying
            copies[scanID]?.progress.update(done: baseBytes + offset, time: ProcessInfo.processInfo.systemUptime)
            current.requestFile(request, into: folder.appendingPathComponent(file.name))
            return
        }
    }

    private func fileProgress(_ cid: UUID, _ transferID: UInt32, _ bytes: Int64) {
        guard connection?.id == cid, let transfer = activeTransfer, transfer.id == transferID else { return }
        copies[transfer.scanID]?.progress.update(done: transfer.baseBytes + bytes, time: ProcessInfo.processInfo.systemUptime)
    }

    private func fileDone(_ cid: UUID, _ transferID: UInt32) {
        guard connection?.id == cid, let transfer = activeTransfer, transfer.id == transferID else { return }
        activeTransfer = nil
        pumpCopies()
    }

    private func fileFailed(_ cid: UUID, _ transferID: UInt32, _ message: String) {
        guard connection?.id == cid, let transfer = activeTransfer, transfer.id == transferID else { return }
        activeTransfer = nil
        copyQueue.removeAll { $0 == transfer.scanID }
        copies[transfer.scanID]?.phase = .failed("\(transfer.name): \(message). The part already copied is kept; tap Retry.")
        pumpCopies()
    }

    private func fileRefused(_ transferID: UInt32, reason: RemoteFileProblem, text: String) {
        guard let transfer = activeTransfer, transfer.id == transferID else { return }
        activeTransfer = nil
        switch reason {
        case .busy:
            copies[transfer.scanID]?.phase = .waiting("Paused while the scanner records, saves or builds a map")
            copies[transfer.scanID]?.progress.resetRate()
            // The last status may still say idle; ask again only after a newer one.
            waitingForStatus = true
        case .changed:
            let url = stagingFolder(transfer.scanID).appendingPathComponent(transfer.name)
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } catch {
                copyQueue.removeAll { $0 == transfer.scanID }
                copies[transfer.scanID]?.phase = .failed("\(transfer.name) changed on the scanner and the old part could not be deleted (\(error.localizedDescription)).")
                pumpCopies()
                return
            }
            copies[transfer.scanID]?.phase = .waiting("The scan changed on the scanner; refreshing")
            awaitingScanList = true
            requestScanList()
        case .missing, .failed:
            copyQueue.removeAll { $0 == transfer.scanID }
            copies[transfer.scanID]?.phase = .failed(text)
            requestScanList()
        }
        pumpCopies()
    }

    /// Moves the staged files into a new scan folder and adds the scan to the library (design §6.15 step 4).
    private func importCopy(_ scan: RemoteScanInfo, staging: URL) {
        copyQueue.removeAll { $0 == scan.id }
        guard store.record(id: scan.id) == nil else {
            copies[scan.id]?.phase = .failed("This scan is already on this phone.")
            return
        }
        copies[scan.id]?.phase = .importing
        let scannerName = RemoteStaging.loadManifest(in: staging)?.scannerName ?? pairedScannerName ?? "the scanner"
        let manager = FileManager.default
        var created: (name: String, url: URL)?
        var moved: [String] = []
        do {
            let folder = try store.newFolder(kind: .line)
            created = folder
            for file in scan.files {
                try manager.moveItem(at: staging.appendingPathComponent(file.name),
                                     to: folder.url.appendingPathComponent(file.name))
                moved.append(file.name)
            }
            try store.save(RemoteImport.record(from: scan, scannerName: scannerName, folderName: folder.name,
                                               copied: Date()))
        } catch {
            // Put the files back so the copy is not lost. The new folder (no scan.json) is removed only when it is
            // empty again; otherwise it stays under Incomplete scans with the files that could not be moved back.
            var left: [String] = []
            if let created {
                for name in moved {
                    do {
                        try manager.moveItem(at: created.url.appendingPathComponent(name),
                                             to: staging.appendingPathComponent(name))
                    } catch {
                        left.append(name)
                    }
                }
                if left.isEmpty { store.discard(folderName: created.name) }
            }
            var text = "The copy could not be added to this phone's library (\(error.localizedDescription))."
            if let created, !left.isEmpty {
                text += " \(left.count) file(s) are in Incomplete scans on Home (\(created.name)); share or delete them there, then copy again."
            } else {
                text += " Tap Retry."
            }
            copies[scan.id]?.phase = .failed(text)
            return
        }
        // Only the manifest is left in the staging folder; a leftover folder is harmless.
        try? manager.removeItem(at: staging)
        copies[scan.id] = CopyState(phase: .done, progress: TransferProgress(total: scan.totalBytes, done: scan.totalBytes))
    }
}
