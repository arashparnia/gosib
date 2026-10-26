import Foundation

public struct LinkPeer: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// Adapters carry bytes. Discovery and successful queueing confer no endpoint trust.
@MainActor public protocol PacketLink: AnyObject {
    var onState: ((String) -> Void)? { get set }
    var onPeers: (([LinkPeer]) -> Void)? { get set }
    var onMessage: ((Data, String) -> Void)? { get set }
    var onLinkReady: ((String) -> Void)? { get set }
    var onDisconnected: ((String) -> Void)? { get set }
    /// A previously refused local send may fit after queue pressure decreases.
    /// This is a retry opportunity, never an endpoint delivery acknowledgment.
    var onWorkAvailable: (() -> Void)? { get set }
    func start(nodeName: String)
    /// True only means accepted into this adapter's local queue.
    @discardableResult func send(_ data: Data, to peerID: String, priority: Int) -> Bool
    func confirmPeer(_ peerID: String)
    func stop()
}

public extension PacketLink {
    /// Existing adapters may continue relying on their host's retry scheduling.
    var onWorkAvailable: (() -> Void)? {
        get { nil }
        set {}
    }
}
