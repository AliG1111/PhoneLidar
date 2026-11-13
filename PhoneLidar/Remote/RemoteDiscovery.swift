import Foundation
import Network

// Discovery side of the remote link (design §3.9, §6.15): Bonjour advertising on the scanner, browsing on the remote.
// Handlers run on the link queue (`phonelidar.remote.link`) and report to the main actor in order.

/// Hands an accepted `NWConnection` to the main actor.
final class AcceptedConnection: @unchecked Sendable {
    // Immutable; the connection is only started later, on the link queue.
    let connection: NWConnection

    init(_ connection: NWConnection) {
        self.connection = connection
    }
}

/// A scanner found by the browser. `endpoints`: every advertised path to it (peer-to-peer, Wi-Fi).
struct FoundScanner: Identifiable, Equatable, @unchecked Sendable {
    // Immutable values; NWEndpoint is a value type.
    let id: UUID
    let name: String
    let endpoints: [NWEndpoint]
    /// Every service name advertised with this ID. One scanner has one name on every interface; Bonjour renames a
    /// second service that copies the name, so more than one name means another phone claims this scanner's ID.
    var names: [String] = []

    var isAmbiguous: Bool { names.count > 1 }
}

/// Bonjour advertising and accepting connections on the scanner.
final class RemoteListener: @unchecked Sendable {
    // `listener` is created and cancelled on the main actor; its handlers run on `queue` and only read the
    // callbacks, which are set before `start()`.
    enum Event: Sendable {
        case ready
        /// The permission probe can browse: Local Network access is on.
        case permissionGranted
        case permissionDenied
        case failed(String)
    }

    private let queue: DispatchQueue
    private let identity: RemoteIdentity
    private var listener: NWListener?
    /// A listener can stay ready while Local Network access is off (its service is then not advertised), so a
    /// browser for the same service type tells whether access is on (TN3179: browsing reports DNS error −65570).
    private var probe: NWBrowser?

    var onEvent: (@MainActor @Sendable (Event) -> Void)?
    var onConnection: (@MainActor @Sendable (AcceptedConnection) -> Void)?

    init(identity: RemoteIdentity, queue: DispatchQueue) {
        self.identity = identity
        self.queue = queue
    }

    func start() throws {
        let listener = try NWListener(using: RemoteConnection.parameters())
        let txt = NWTXTRecord(["id": identity.id.uuidString, "v": String(RemoteLinkConstants.protocolVersion)])
        listener.service = NWListener.Service(name: identity.name, type: RemoteLinkConstants.serviceType,
                                              domain: nil, txtRecord: txt.data)
        listener.stateUpdateHandler = { [weak self] state in
            self?.stateChanged(state)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accepted(connection)
        }
        self.listener = listener
        listener.start(queue: queue)

        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let probe = NWBrowser(for: .bonjour(type: RemoteLinkConstants.serviceType, domain: nil), using: parameters)
        probe.stateUpdateHandler = { [weak self] state in
            self?.probeStateChanged(state)
        }
        self.probe = probe
        probe.start(queue: queue)
    }

    func cancel() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        probe?.stateUpdateHandler = nil
        probe?.cancel()
        probe = nil
    }

    private func probeStateChanged(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            report(.permissionGranted)
        case .waiting(let error), .failed(let error):
            if RemoteConnection.isPolicyDenied(error) { report(.permissionDenied) }
        default:
            break
        }
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            report(.ready)
        case .waiting(let error):
            if RemoteConnection.isPolicyDenied(error) { report(.permissionDenied) }
        case .failed(let error):
            report(RemoteConnection.isPolicyDenied(error) ? .permissionDenied
                                                          : .failed(RemoteConnection.describe(network: error)))
        default:
            break
        }
    }

    private func accepted(_ connection: NWConnection) {
        guard let callback = onConnection else {
            connection.cancel()
            return
        }
        let box = AcceptedConnection(connection)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { callback(box) }
        }
    }

    private func report(_ event: Event) {
        guard let callback = onEvent else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { callback(event) }
        }
    }
}

/// Finds advertising scanners on the remote.
final class RemoteBrowser: @unchecked Sendable {
    // `browser` is created and cancelled on the main actor; its handlers run on `queue` and only read the
    // callbacks, which are set before `start()`.
    enum Event: Sendable {
        case ready
        case permissionDenied
        case failed(String)
    }

    private let queue: DispatchQueue
    private var browser: NWBrowser?

    var onEvent: (@MainActor @Sendable (Event) -> Void)?
    var onResults: (@MainActor @Sendable ([FoundScanner]) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteLinkConstants.serviceType, domain: nil),
                                using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            self?.stateChanged(state)
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.resultsChanged(results)
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func cancel() {
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
    }

    private func stateChanged(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            report(.ready)
        case .waiting(let error):
            if RemoteConnection.isPolicyDenied(error) { report(.permissionDenied) }
        case .failed(let error):
            report(RemoteConnection.isPolicyDenied(error) ? .permissionDenied
                                                          : .failed(RemoteConnection.describe(network: error)))
        default:
            break
        }
    }

    /// Groups results by the TXT `id` (one scanner can be reachable over several interfaces) and keeps every
    /// service name seen for an ID, so a second phone claiming the same ID shows up as ambiguous.
    private func resultsChanged(_ results: Set<NWBrowser.Result>) {
        var names: [UUID: [String]] = [:]
        var endpoints: [UUID: [NWEndpoint]] = [:]
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint,
                  case .bonjour(let txt) = result.metadata,
                  let text = txt.dictionary["id"], let id = UUID(uuidString: text) else { continue }
            if !(names[id] ?? []).contains(name) { names[id, default: []].append(name) }
            endpoints[id, default: []].append(result.endpoint)
        }
        let found = names.map { entry -> FoundScanner in
            let sorted = entry.value.sorted()
            return FoundScanner(id: entry.key, name: sorted.first ?? "iPhone", endpoints: endpoints[entry.key] ?? [],
                                names: sorted)
        }
        .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
        guard let callback = onResults else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { callback(found) }
        }
    }

    private func report(_ event: Event) {
        guard let callback = onEvent else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { callback(event) }
        }
    }
}
