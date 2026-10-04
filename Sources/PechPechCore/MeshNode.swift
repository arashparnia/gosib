import Foundation

public enum NodeEvent: Equatable, Sendable {
    case linkState(String)
    case waitingForRoute(UUID)
    case transmitting(UUID)
    case relayBackpressure
    case error(String)
}

/// Foreground store-and-forward scheduler. It never treats queueing or relay ACKs as delivery.
@MainActor public final class MeshNode {
    public let identity: Identity
    public let store: MeshStore
    public var onMessage: ((ReceivedMessage) -> Void)?
    public var onDelivery: ((Message, DeliveryReceipt) -> Void)?
    public var onPeers: (([PublicIdentity]) -> Void)?
    public var onEvent: ((NodeEvent) -> Void)?
    private let authorize: (Message, PublicIdentity) -> Bool
    private let links: [any PacketLink]
    private var timer: Task<Void, Never>?
    private var running = false
    private var active = Set<UUID>()
    private var origins: [UUID: RelayPacket] = [:]
    private var acknowledgments: [UUID: (packet: RelayPacket, hash: Data)] = [:]
    private var peers: [Slot: Peer] = [:]
    private var flushing = false
    private var flushAgain = false
    private struct Slot: Hashable { let link: Int; let id: String }
    private final class Peer {
        let challenge = UUID()
        var remoteChallenge: UUID?
        var remoteIdentity: PublicIdentity?
        var echoed: UUID?
        var ready = false
        var sent: [UUID: Data] = [:]
        var sourcePackets = Set<UUID>()
    }

    /// Authorization is required and application-defined. For a relay-only node, return false.
    public init(identity: Identity, store: MeshStore, links: [any PacketLink],
                authorize: @escaping (Message, PublicIdentity) -> Bool) throws {
        guard Set(links.map { ObjectIdentifier($0) }).count == links.count else {
            throw PechPechError.invalid("Use a distinct packet-link instance for each adapter.")
        }
        self.identity = identity; self.store = store; self.links = links; self.authorize = authorize
        try store.bindIdentity(identity.publicIdentity)
        for (index, link) in links.enumerated() {
            link.onState = { [weak self] in self?.onEvent?(.linkState($0)) }
            link.onLinkReady = { [weak self] id in self?.linkReady(Slot(link: index, id: id)) }
            link.onMessage = { [weak self] bytes, id in self?.receive(bytes, from: Slot(link: index, id: id)) }
            link.onDisconnected = { [weak self] id in
                guard let self else { return }
                self.peers.removeValue(forKey: Slot(link: index, id: id)); self.publishPeers()
            }
        }
    }
    deinit { timer?.cancel() }

    /// Starts links and foreign relay forwarding. Restored outbox messages remain paused.
    public func start() {
        guard !running else { return }
        running = true
        for link in links {
            // Native adapter callbacks can synchronously ask the host to stop.
            // Do not start another radio or a retry task after that explicit stop.
            guard running else { return }
            link.start(nodeName: identity.publicIdentity.id)
        }
        guard running else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.tick()
            }
        }
        flush()
    }
    /// Already transmitted packets cannot be recalled. Original immutable records remain saved.
    public func stop() {
        running = false; timer?.cancel(); timer = nil
        active.removeAll(); origins.removeAll(); acknowledgments.removeAll(); peers.removeAll()
        for link in links { link.stop() }
        publishPeers()
    }

    /// Save first; caller starts transmission explicitly or while the node is running.
    @discardableResult public func enqueue(to recipient: PublicIdentity, channel: String, payload: Data,
                                          id: UUID = UUID(), priority: PacketPriority = .urgent,
                                          startSending: Bool = true) throws -> Message {
        guard recipient.id != identity.publicIdentity.id else { throw PechPechError.invalid("Use local storage for self-addressed messages.") }
        let message: Message
        if let saved = try store.outgoing(messageID: id) {
            // Retry the saved creation time and bytes rather than constructing a
            // different immutable message for the same caller-supplied ID.
            guard saved.recipient == recipient, saved.priority == priority,
                  saved.message.senderID == identity.publicIdentity.id,
                  saved.message.channel == channel, saved.message.payload == payload else {
                throw PechPechError.messageConflict
            }
            message = saved.message
            if try store.receipt(messageID: id) != nil { return message }
        } else {
            message = try Message(id: id, senderID: identity.publicIdentity.id, destinationID: recipient.id,
                                  channel: channel, payload: payload)
        }
        // Qualify the actual wrapped packet size before committing an unusable outbox entry.
        let packet = try EndpointCrypto.seal(.message(message), from: identity, to: recipient, priority: priority)
        guard try WireCoding.encode(MeshFrame.packet(packet)).count <= RelayPacket.maximumBytes else {
            throw PechPechError.frameTooLarge(try WireCoding.encode(MeshFrame.packet(packet)).count)
        }
        try store.queue(message, recipient: recipient, priority: priority)
        if running && startSending { active.insert(message.id); origins[message.id] = packet; flush() }
        return message
    }
    /// Explicitly resume an original saved message after stop/restart or UI interruption.
    public func resume(_ messageID: UUID) throws {
        guard try store.pending().contains(where: { $0.message.id == messageID }) else { return }
        active.insert(messageID); flush()
    }
    public func pause(_ messageID: UUID) {
        active.remove(messageID); origins.removeValue(forKey: messageID)
    }
    public var connectedIdentities: [PublicIdentity] {
        var unique: [String: PublicIdentity] = [:]
        for peer in peers.values where peer.ready {
            if let identity = peer.remoteIdentity { unique[identity.id] = identity }
        }
        return unique.values.sorted { $0.id < $1.id }
    }
    /// Also useful to drive deterministic test adapters; normal foreground retries run each second.
    public func tick() {
        guard running else { return }
        for (slot, peer) in peers {
            peer.sent.removeAll(); peer.sourcePackets.removeAll()
            // One side may be ready while its last echo was dropped. Continue
            // periodic echoes on ready links so the other side can recover.
            sendHello(to: slot)
        }
        flush()
    }

    private func linkReady(_ slot: Slot) {
        guard running else { return }
        if peers[slot] == nil { peers[slot] = Peer() }
        sendHello(to: slot)
    }
    private func sendHello(to slot: Slot) {
        guard let peer = peers[slot] else { return }
        do {
            let hello = try SignedHello(identity: identity, challenge: peer.challenge, echo: peer.remoteChallenge)
            let previousEcho = peer.echoed
            // Set before sending to bound synchronous adapter reentrancy.
            peer.echoed = peer.remoteChallenge
            if !send(.hello(hello), to: slot, priority: .receipt) { peer.echoed = previousEcho }
        } catch { report(error) }
    }
    private func receive(_ bytes: Data, from slot: Slot) {
        guard running, bytes.count <= RelayPacket.maximumBytes else { return }
        do {
            let frame = try WireCoding.decode(MeshFrame.self, from: bytes)
            if case .hello(let hello) = frame {
                try hello.validate()
                if peers[slot] == nil { peers[slot] = Peer() }
                guard let peer = peers[slot], hello.claims.identity.id != identity.publicIdentity.id else { throw PechPechError.identityConflict }
                if let old = peer.remoteIdentity, old != hello.claims.identity { throw PechPechError.identityConflict }
                // Identity stays bound to a link until disconnect; fresh local challenge
                // echo proves possession instead of trusting a replayed advertisement.
                peer.remoteIdentity = hello.claims.identity
                if let old = peer.remoteChallenge, old != hello.claims.challenge { throw PechPechError.authenticationFailed }
                peer.remoteChallenge = hello.claims.challenge
                if hello.claims.echo == peer.challenge {
                    guard connectedIdentities.contains(hello.claims.identity) || connectedIdentities.count < 4 else {
                        throw PechPechError.invalid("The four-neighbor limit is reached.")
                    }
                    let wasReady = peer.ready; peer.ready = true
                    links[slot.link].confirmPeer(slot.id)
                    if !wasReady { publishPeers() }
                }
                if peer.echoed != hello.claims.challenge { sendHello(to: slot) }
                if peer.ready { flush() }
                return
            }
            guard let peer = peers[slot], peer.ready, let neighbor = peer.remoteIdentity else { throw PechPechError.authenticationFailed }
            switch frame {
            case .hello: break
            case .stored(let ack):
                try ack.validate(sender: neighbor, challenge: peer.challenge)
                guard peer.sent[ack.claims.packetID] == ack.claims.packetHash else { throw PechPechError.authenticationFailed }
                // Only opaque relay copies are removed. Original outbox and return
                // records can be retired only by their authenticated endpoint receipt.
                try store.removeRelay(ack.claims.packetID)
            case .packet(let packet):
                try packet.validate()
                if packet.destinationID == identity.publicIdentity.id {
                    try receiveEndpoint(packet)
                } else {
                    guard packet.hopsRemaining > 0, packet.originID != identity.publicIdentity.id else { return }
                    _ = try store.enqueueRelay(packet)
                    peer.sourcePackets.insert(packet.id)
                }
                // This ACK is issued only after durable admission or endpoint persistence.
                if let echo = peer.remoteChallenge {
                    let ack = try SignedRelayAck(identity: identity, packet: packet, echo: echo)
                    _ = send(.stored(ack), to: slot, priority: .receipt)
                }
                flush()
            }
        } catch PechPechError.spoolFull { onEvent?(.relayBackpressure) }
        catch { report(error) }
    }

    private func receiveEndpoint(_ packet: RelayPacket) throws {
        let opened = try EndpointCrypto.open(packet, for: identity)
        switch opened.envelope {
        case .message(let message):
            try message.validate()
            guard message.senderID == opened.sender.id, message.destinationID == identity.publicIdentity.id,
                  authorize(message, opened.sender) else { throw PechPechError.authenticationFailed }
            let previous = try store.received(messageID: message.id)
            _ = try store.accept(message, sender: opened.sender) { receipt in
                try EndpointCrypto.seal(.receipt(receipt), from: identity, to: opened.sender,
                                        priority: .receipt, lifetimeMilliseconds: 600_000)
            }
            if previous == nil, let saved = try store.received(messageID: message.id) { onMessage?(saved) }
        case .receipt(let receipt):
            let previous = try store.receipt(messageID: receipt.messageID)
            let message = try store.pending().first { $0.message.id == receipt.messageID }?.message
            try store.saveReceipt(receipt, authenticatedReceiver: opened.sender)
            active.remove(receipt.messageID); origins.removeValue(forKey: receipt.messageID)
            // Independent endpoint ACK stops durable receiver receipt retries.
            let ack: RelayPacket
            if let cached = acknowledgments[receipt.messageID], cached.hash == receipt.bodyHash,
               cached.packet.destinationID == opened.sender.id, cached.packet.expiresAt > WireCoding.now + 5_000 {
                ack = cached.packet
            } else {
                acknowledgments = acknowledgments.filter { $0.value.packet.expiresAt > WireCoding.now }
                if acknowledgments.count >= 512 { acknowledgments.removeAll() }
                ack = try EndpointCrypto.seal(.receiptStored(messageID: receipt.messageID, bodyHash: receipt.bodyHash),
                                              from: identity, to: opened.sender, priority: .receipt)
                acknowledgments[receipt.messageID] = (ack, receipt.bodyHash)
            }
            forward(ack)
            if previous == nil, let message { onDelivery?(message, receipt) }
        case .receiptStored(let messageID, let hash):
            try store.retireReturn(messageID: messageID, bodyHash: hash, senderID: opened.sender.id)
        }
    }

    private func flush() {
        guard running else { return }
        if flushing { flushAgain = true; return }
        flushing = true
        defer { flushing = false }
        // Reentrant in-memory links can deliver and ACK synchronously; a bounded
        // second pass consumes any receipt newly committed by those callbacks.
        var passes = 0
        repeat {
            flushAgain = false; passes += 1
            do {
                for packet in try store.outgoingReceipts() { forward(packet) }
                for pending in try store.pending() where active.contains(pending.message.id) {
                    let message = pending.message
                    if origins[message.id]?.expiresAt ?? 0 <= WireCoding.now + 5_000 {
                        origins[message.id] = try EndpointCrypto.seal(.message(message), from: identity,
                                                                    to: pending.recipient, priority: pending.priority)
                    }
                    if connectedIdentities.isEmpty { onEvent?(.waitingForRoute(message.id)) }
                    else { onEvent?(.transmitting(message.id)) }
                    if let packet = origins[message.id] { forward(packet) }
                }
                for packet in try store.relayPackets() { forward(packet, foreign: true) }
            } catch { report(error) }
        } while flushAgain && passes < 2
    }
    private func forward(_ packet: RelayPacket, foreign: Bool = false) {
        guard running else { return }
        // Snapshot slots, since test adapters may disconnect synchronously in send.
        let destinations = peers.keys.sorted { a, b in
            let aDirect = peers[a]?.remoteIdentity?.id == packet.destinationID
            let bDirect = peers[b]?.remoteIdentity?.id == packet.destinationID
            if aDirect != bDirect { return aDirect }
            return a.link == b.link ? a.id < b.id : a.link < b.link
        }
        for slot in destinations {
            guard let peer = peers[slot], peer.ready, let neighbor = peer.remoteIdentity,
                  neighbor.id != packet.originID, peer.sent[packet.id] == nil,
                  !peer.sourcePackets.contains(packet.id) else { continue }
            guard let sentPacket = foreign ? packet.forwarded() : packet else { continue }
            do {
                let hash = try SignedRelayAck.immutableHash(sentPacket)
                peer.sent[packet.id] = hash
                if !send(.packet(sentPacket), to: slot, priority: packet.priority) { peer.sent.removeValue(forKey: packet.id) }
            } catch { peer.sent.removeValue(forKey: packet.id); report(error) }
        }
    }
    @discardableResult private func send(_ frame: MeshFrame, to slot: Slot, priority: PacketPriority) -> Bool {
        do {
            let bytes = try WireCoding.encode(frame)
            guard bytes.count <= RelayPacket.maximumBytes else { throw PechPechError.frameTooLarge(bytes.count) }
            return links[slot.link].send(bytes, to: slot.id, priority: priority.rawValue)
        } catch { report(error); return false }
    }
    private func publishPeers() { onPeers?(connectedIdentities) }
    private func report(_ error: Error) { onEvent?(.error(error.localizedDescription)) }
}
