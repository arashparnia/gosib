import Foundation

/// Deterministic topology adapter for examples and tests. It models no hardware/radio timing.
@MainActor public final class InMemoryNetwork {
    private var links: [String: InMemoryPacketLink] = [:]
    private var neighbors: [String: Set<String>] = [:]
    /// Returning false models loss after successful local adapter queueing.
    public var shouldDeliver: ((Data, String, String) -> Bool)?
    public init() {}
    public func makeLink(id: String) -> InMemoryPacketLink {
        precondition(links[id] == nil, "Use one unique ID per in-memory endpoint.")
        let link = InMemoryPacketLink(id: id, network: self)
        links[id] = link; return link
    }
    public func connect(_ a: String, _ b: String) {
        precondition(a != b && links[a] != nil && links[b] != nil)
        neighbors[a, default: []].insert(b); neighbors[b, default: []].insert(a)
        announce(a, b); announce(b, a)
    }
    public func disconnect(_ a: String, _ b: String) {
        neighbors[a]?.remove(b); neighbors[b]?.remove(a)
        links[a]?.onDisconnected?(b); links[b]?.onDisconnected?(a)
        publish(a); publish(b)
    }
    fileprivate func start(_ id: String) {
        for neighbor in neighbors[id] ?? [] { announce(id, neighbor); announce(neighbor, id) }
    }
    fileprivate func stop(_ id: String) {
        for neighbor in neighbors[id] ?? [] {
            links[neighbor]?.onDisconnected?(id)
        }
    }
    fileprivate func send(_ bytes: Data, from: String, to: String) -> Bool {
        guard links[from]?.isRunning == true, links[to]?.isRunning == true,
              neighbors[from]?.contains(to) == true, bytes.count <= RelayPacket.maximumBytes else { return false }
        if shouldDeliver?(bytes, from, to) ?? true { links[to]?.onMessage?(bytes, from) }
        return true
    }
    private func announce(_ from: String, _ to: String) {
        guard links[from]?.isRunning == true, links[to]?.isRunning == true else { return }
        links[from]?.onLinkReady?(to); publish(from)
    }
    private func publish(_ id: String) {
        let peers = (neighbors[id] ?? []).filter { links[$0]?.isRunning == true }.sorted()
            .map { LinkPeer(id: $0, name: $0) }
        links[id]?.onPeers?(peers)
    }
}

@MainActor public final class InMemoryPacketLink: PacketLink {
    public var onState: ((String) -> Void)?
    public var onPeers: (([LinkPeer]) -> Void)?
    public var onMessage: ((Data, String) -> Void)?
    public var onLinkReady: ((String) -> Void)?
    public var onDisconnected: ((String) -> Void)?
    public let id: String
    public private(set) var isRunning = false
    private weak var network: InMemoryNetwork?
    fileprivate init(id: String, network: InMemoryNetwork) { self.id = id; self.network = network }
    public func start(nodeName: String) { isRunning = true; network?.start(id); onState?("In-memory topology active") }
    @discardableResult public func send(_ data: Data, to peerID: String, priority: Int) -> Bool {
        network?.send(data, from: id, to: peerID) ?? false
    }
    public func confirmPeer(_ peerID: String) {}
    public func stop() { isRunning = false; network?.stop(id); onState?("Stopped") }
}
