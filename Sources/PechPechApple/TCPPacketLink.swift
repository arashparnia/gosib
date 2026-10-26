#if canImport(Network)
import Foundation
import PechPechCore
import Network

/// TCP transports opaque, application-authenticated envelopes. `includePeerToPeer`
/// permits Apple's direct Wi-Fi path; it does not force a connection to use it.
@MainActor
public final class TCPPacketLink: PacketLink {
    public var onState: ((String) -> Void)?
    public var onPeers: (([LinkPeer]) -> Void)?
    public var onMessage: ((Data, String) -> Void)?
    public var onLinkReady: ((String) -> Void)?
    public var onDisconnected: ((String) -> Void)?

    private let includePeerToPeer: Bool
    private let serviceType = "_pechpech._tcp"
    private let maximumFrameSize = 16_384
    private let maximumQueuedBytes = 262_144
    private var localServiceName = ""
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [String: NWConnection] = [:]
    private var names: [String: String] = [:]
    private var endpoints: [String: NWEndpoint] = [:]
    private var queuedBytes: [String: Int] = [:]
    private var readyPeers: Set<String> = []
    private var authenticatedPeers: Set<String> = []
    private var retries: [String: DispatchWorkItem] = [:]
    private var retryAttempts: [String: Int] = [:]
    private var setupTimeouts: [String: DispatchWorkItem] = [:]
    private var frameTimeouts: [String: DispatchWorkItem] = [:]
    private var generation = UUID()
    private(set) var running = false

    public init(includePeerToPeer: Bool = true) {
        self.includePeerToPeer = includePeerToPeer
    }

    /// Use a stable, unique node identity. Discovery names select topology, never trust.
    public func start(nodeName: String = UUID().uuidString) {
        let token = UUID()
        stopSession(token: token)
        guard generation == token, !running else { return }
        running = true
        localServiceName = DiscoveryName.make(from: nodeName)
        startListener(name: localServiceName)
        guard running, generation == token else { return }
        startBrowser()
    }

    /// True means local socket queue admission only, never delivery or application receipt.
    @discardableResult public func send(_ data: Data, to peerID: String, priority: Int = 1) -> Bool {
        guard !data.isEmpty, data.count <= maximumFrameSize else {
            onState?("TCP rejected an empty or oversized envelope (limit 16 KiB).")
            return false
        }
        guard readyPeers.contains(peerID), let connection = connections[peerID] else {
            onState?("TCP link unavailable; caller retains responsibility for retry.")
            return false
        }
        let frame = LengthPrefixedFrame.encode(data)!
        let pending = queuedBytes[peerID, default: 0]
        guard pending + frame.count <= maximumQueuedBytes else {
            onState?("TCP send queue full; caller retains responsibility for retry.")
            return false
        }
        queuedBytes[peerID] = pending + frame.count
        let sentByteCount = frame.count
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self, self.connections[peerID] === connection else { return }
                self.queuedBytes[peerID] = max(0, self.queuedBytes[peerID, default: 0] - sentByteCount)
                if let error {
                    self.onState?("TCP send failed: \(error.localizedDescription)")
                    self.drop(peerID, connection: connection, retry: true)
                }
                // A completed socket send is never an application receipt.
            }
        })
        return true
    }

    /// Call only after application/protocol authentication succeeds. Ready links are
    /// not trusted until the caller validates its neighbor identity.
    public func confirmPeer(_ peerID: String) {
        guard readyPeers.contains(peerID), connections[peerID] != nil else { return }
        authenticatedPeers.insert(peerID)
        setupTimeouts.removeValue(forKey: peerID)?.cancel()
        // Neighbor readiness never grants application authorization; encrypted envelopes do that.
    }

    public func stop() {
        let token = UUID()
        // A stop from a stop notification still cancels an enclosing start,
        // without recursively publishing the same empty topology.
        guard running else { generation = token; return }
        stopSession(token: token)
    }

    private func stopSession(token: UUID) {
        running = false
        generation = token
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        retries.values.forEach { $0.cancel() }
        retries.removeAll()
        setupTimeouts.values.forEach { $0.cancel() }
        setupTimeouts.removeAll()
        frameTimeouts.values.forEach { $0.cancel() }
        frameTimeouts.removeAll()
        let disconnected = Array(connections.keys)
        connections.values.forEach {
            $0.stateUpdateHandler = nil
            $0.pathUpdateHandler = nil
            $0.cancel()
        }
        connections.removeAll()
        endpoints.removeAll()
        names.removeAll()
        readyPeers.removeAll()
        authenticatedPeers.removeAll()
        queuedBytes.removeAll()
        retryAttempts.removeAll()
        for peerID in disconnected {
            guard generation == token else { return }
            onDisconnected?(peerID)
        }
        guard generation == token else { return }
        onPeers?([])
    }

    private func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = includePeerToPeer
        return parameters
    }

    private var modeDescription: String {
        includePeerToPeer ? "Apple P2P enabled; LAN may also be selected" : "LAN control; Apple P2P disabled"
    }

    private func startListener(name: String) {
        do {
            let newListener = try NWListener(using: parameters())
            listener = newListener
            newListener.service = NWListener.Service(name: name, type: serviceType)
            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listener === newListener else { return }
                    switch state {
                    case .ready:
                        self.onState?("PechPech TCP relay listening; \(self.modeDescription).")
                    case .failed(let error):
                        self.onState?("TCP listener failed: \(error.localizedDescription)")
                    case .waiting(let error):
                        self.onState?("TCP listener waiting: \(error.localizedDescription)")
                    default: break
                    }
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.running, self.listener === newListener,
                          self.connections.count < 4 else {
                        connection.cancel()
                        return
                    }
                    let id = UUID().uuidString
                    self.names[id] = connection.endpoint.debugDescription
                    self.install(connection, peerID: id)
                }
            }
            newListener.start(queue: .main)
        } catch {
            onState?("Cannot start TCP listener: \(error.localizedDescription)")
        }
    }

    private func startBrowser() {
        guard running, browser == nil else { return }
        let newBrowser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters())
        browser = newBrowser
        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.browser === newBrowser else { return }
                switch state {
                case .ready:
                    self.onState?("Looking for nearby PechPech apps; \(self.modeDescription).")
                case .waiting(let error):
                    self.onState?("Discovery waiting: \(error.localizedDescription)")
                case .failed(let error):
                    self.onState?("Discovery failed: \(error.localizedDescription). Check local-network permission.")
                    guard self.running, self.browser === newBrowser else { return }
                    newBrowser.stateUpdateHandler = nil
                    newBrowser.browseResultsChangedHandler = nil
                    newBrowser.cancel()
                    self.browser = nil
                    let token = self.generation
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                        Task { @MainActor in
                            guard let self, self.generation == token else { return }
                            self.startBrowser()
                        }
                    }
                default: break
                }
            }
        }
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.browser === newBrowser, self.running else { return }
                let token = self.generation
                let candidates = results.map(\.endpoint).filter { self.displayName(for: $0) > self.localServiceName }
                    .sorted { self.identifier(for: $0) < self.identifier(for: $1) }
                let current = Array(candidates.prefix(32))
                let currentIDs = Set(current.map { self.identifier(for: $0) })
                for id in Array(self.endpoints.keys) where !currentIDs.contains(id) {
                    self.endpoints.removeValue(forKey: id)
                    self.retries.removeValue(forKey: id)?.cancel()
                    self.retryAttempts.removeValue(forKey: id)
                    if self.connections[id] == nil { self.names.removeValue(forKey: id) }
                }
                for endpoint in current {
                    // Select one TCP direction deterministically; this is topology, not trust.
                    guard self.displayName(for: endpoint) > self.localServiceName else { continue }
                    let id = self.identifier(for: endpoint)
                    self.endpoints[id] = endpoint
                    self.names[id] = self.displayName(for: endpoint)
                }
                self.connectAvailableEndpoints()
                guard self.running, self.generation == token else { return }
                self.publishPeers()
            }
        }
        newBrowser.start(queue: .main)
    }

    private func identifier(for endpoint: NWEndpoint) -> String {
        if case let .service(name, type, domain, _) = endpoint {
            return "bonjour:\(name).\(type).\(domain)"
        }
        return endpoint.debugDescription
    }

    private func displayName(for endpoint: NWEndpoint) -> String {
        if case let .service(name, _, _, _) = endpoint { return name }
        return endpoint.debugDescription
    }

    private func connectAvailableEndpoints() {
        guard running else { return }
        let token = generation
        let candidates = TCPConnectionCandidates.select(known: Set(endpoints.keys),
            connected: Set(connections.keys), retrying: Set(retries.keys))
        for id in candidates {
            // Callbacks during installation may stop the adapter or occupy another slot.
            guard running, generation == token, connections.count < 4 else { return }
            guard connections[id] == nil, retries[id] == nil, let endpoint = endpoints[id] else { continue }
            install(NWConnection(to: endpoint, using: parameters()), peerID: id)
        }
    }

    private func install(_ connection: NWConnection, peerID: String) {
        connections[peerID] = connection
        armSetupTimeout(peerID, connection: connection)
        publishPeers()
        guard running, connections[peerID] === connection else { return }
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connections[peerID] === connection else { return }
                switch state {
                case .ready:
                    self.readyPeers.insert(peerID)
                    self.retryAttempts[peerID] = 0
                    self.retries.removeValue(forKey: peerID)?.cancel()
                    self.armSetupTimeout(peerID, connection: connection)
                    self.onState?("TCP connected over \(self.pathDescription(connection.currentPath)); \(self.modeDescription).")
                    guard self.running, self.connections[peerID] === connection else { return }
                    self.onLinkReady?(peerID)
                    guard self.running, self.connections[peerID] === connection else { return }
                    self.readHeader(from: connection, peerID: peerID)
                    // Browser discovery continues until core authenticates the neighbor
                    // identity. TCP readiness is not authentication.
                case .failed(let error), .waiting(let error):
                    self.onState?("TCP connection interrupted: \(error.localizedDescription)")
                    self.drop(peerID, connection: connection, retry: true)
                case .cancelled:
                    self.drop(peerID, connection: connection, retry: true)
                default: break
                }
            }
        }
        connection.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self, self.connections[peerID] === connection,
                      self.readyPeers.contains(peerID) else { return }
                self.onState?("TCP path: \(self.pathDescription(path)); \(self.modeDescription).")
            }
        }
        connection.start(queue: .main)
    }

    private func pathDescription(_ path: NWPath?) -> String {
        guard let path else { return "unknown interface" }
        var types: [String] = []
        if path.usesInterfaceType(.wifi) { types.append("Wi-Fi") }
        if path.usesInterfaceType(.wiredEthernet) { types.append("Ethernet") }
        if path.usesInterfaceType(.cellular) { types.append("cellular") }
        if path.usesInterfaceType(.loopback) { types.append("loopback") }
        if path.usesInterfaceType(.other) { types.append("other") }
        return types.isEmpty ? "unknown interface" : types.joined(separator: ", ")
    }

    private func readHeader(from connection: NWConnection, peerID: String) {
        readExactly(4, from: connection, peerID: peerID) { [weak self] header in
            guard let self else { return }
            guard let length = LengthPrefixedFrame.payloadLength(header) else {
                self.onState?("TCP rejected an invalid frame length.")
                self.drop(peerID, connection: connection, retry: false)
                return
            }
            self.armFrameTimeout(peerID, connection: connection)
            self.readExactly(Int(length), from: connection, peerID: peerID) { [weak self] body in
                guard let self, self.connections[peerID] === connection else { return }
                self.frameTimeouts.removeValue(forKey: peerID)?.cancel()
                self.onMessage?(body, peerID)
                self.readHeader(from: connection, peerID: peerID)
            }
        }
    }

    private func readExactly(_ count: Int, from connection: NWConnection, peerID: String,
                             accumulated: Data = Data(), completion: @escaping (Data) -> Void) {
        guard connections[peerID] === connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: count - accumulated.count) {
            [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.connections[peerID] === connection else { return }
                if error != nil {
                    self.drop(peerID, connection: connection, retry: true)
                    return
                }
                var collected = accumulated
                if let data {
                    collected.append(data)
                    if !data.isEmpty { self.armFrameTimeout(peerID, connection: connection) }
                }
                if collected.count == count {
                    completion(collected)
                } else if isComplete || data == nil || data?.isEmpty == true {
                    self.drop(peerID, connection: connection, retry: true)
                } else {
                    self.readExactly(count, from: connection, peerID: peerID,
                                     accumulated: collected, completion: completion)
                }
            }
        }
    }

    private func drop(_ peerID: String, connection: NWConnection, retry: Bool) {
        guard connections[peerID] === connection else { return }
        let token = generation
        connections.removeValue(forKey: peerID)
        readyPeers.remove(peerID)
        authenticatedPeers.remove(peerID)
        setupTimeouts.removeValue(forKey: peerID)?.cancel()
        frameTimeouts.removeValue(forKey: peerID)?.cancel()
        queuedBytes.removeValue(forKey: peerID)
        connection.stateUpdateHandler = nil
        connection.pathUpdateHandler = nil
        connection.cancel()
        if !retry {
            // Invalid framing must not immediately redial the same discovery.
            // A later Bonjour result update may make the endpoint eligible again.
            endpoints.removeValue(forKey: peerID)
            retryAttempts.removeValue(forKey: peerID)
        }
        onDisconnected?(peerID)
        guard running, generation == token else { return }
        if endpoints[peerID] == nil { names.removeValue(forKey: peerID) }
        publishPeers()
        guard running, generation == token else { return }
        defer { connectAvailableEndpoints() }
        guard retry else { return }
        startBrowser()
        guard let endpoint = endpoints[peerID], retries[peerID] == nil else { return }
        let attempt = min(retryAttempts[peerID, default: 0] + 1, 4)
        retryAttempts[peerID] = attempt
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.running, self.generation == token else { return }
                self.retries.removeValue(forKey: peerID)
                // If all slots are occupied now, the endpoint remains eligible for
                // the next disconnect rather than losing its only retry opportunity.
                guard self.endpoints[peerID] == endpoint else { return }
                self.connectAvailableEndpoints()
            }
        }
        retries[peerID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(1 << (attempt - 1)), execute: work)
    }

    private func armSetupTimeout(_ peerID: String, connection: NWConnection) {
        setupTimeouts.removeValue(forKey: peerID)?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.connections[peerID] === connection,
                      !self.authenticatedPeers.contains(peerID) else { return }
                self.onState?("TCP setup or neighbor authentication timed out.")
                self.drop(peerID, connection: connection, retry: true)
            }
        }
        setupTimeouts[peerID] = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    private func armFrameTimeout(_ peerID: String, connection: NWConnection) {
        guard frameTimeouts[peerID] == nil else { return }
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.connections[peerID] === connection else { return }
                self.onState?("TCP partial frame timed out.")
                self.drop(peerID, connection: connection, retry: true)
            }
        }
        frameTimeouts[peerID] = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    private func publishPeers() {
        onPeers?(names.map { LinkPeer(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }
}
#endif
