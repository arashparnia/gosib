import CryptoKit
import Foundation

/// Host-validated ciphertext and immutable routing metadata. The codec owns the
/// exact wire bytes and hash definition; the router never opens the payload.
public struct OpaquePacket: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let destinationID: String
    public let originID: String
    public let hopsRemaining: Int
    public let priority: Int
    public let expiresAt: Int64
    public let bytes: Data
    public let immutableHash: Data
    public init(id: UUID, destinationID: String, originID: String, hopsRemaining: Int,
                priority: Int, expiresAt: Int64, bytes: Data, immutableHash: Data) throws {
        self.id = id; self.destinationID = destinationID; self.originID = originID
        self.hopsRemaining = hopsRemaining; self.priority = priority; self.expiresAt = expiresAt
        self.bytes = bytes; self.immutableHash = immutableHash
        try validate()
    }
    public func validate(now: Int64 = WireCoding.now) throws {
        guard WireCoding.isAddress(destinationID), WireCoding.isAddress(originID),
              (0...8).contains(hopsRemaining), (0...3).contains(priority),
              !bytes.isEmpty, immutableHash.count == 32 else { throw PechPechError.invalid("Invalid opaque packet metadata.") }
        guard bytes.count <= RelayPacket.maximumBytes else { throw PechPechError.frameTooLarge(bytes.count) }
        let lifetime = expiresAt.subtractingReportingOverflow(now)
        guard !lifetime.overflow, lifetime.partialValue > 0, lifetime.partialValue <= 86_400_000 else { throw PechPechError.expired }
    }
}

public struct OpaqueHelloClaims: Codable, Equatable, Sendable {
    public let protocolName: String
    public let profile: String
    public let identity: PublicIdentity
    public let challenge: UUID
    public let echo: UUID?
    public let routes: [String: Int]
    public init(profile: String, identity: PublicIdentity, challenge: UUID, echo: UUID?, routes: [String: Int]) {
        protocolName = "pechpech-opaque-link-1"; self.profile = profile; self.identity = identity
        self.challenge = challenge; self.echo = echo; self.routes = routes
    }
}

public struct SignedOpaqueHello: Codable, Equatable, Sendable {
    public let kind: String
    public let claims: OpaqueHelloClaims
    public let signature: Data
    public init(identity: Identity, profile: String, challenge: UUID, echo: UUID? = nil, routes: [String: Int]) throws {
        kind = "pechpech-opaque-hello"
        claims = OpaqueHelloClaims(profile: profile, identity: identity.publicIdentity, challenge: challenge, echo: echo, routes: routes)
        signature = try identity.sign(WireCoding.encode(claims))
    }
    public func validate(profile: String) throws {
        try claims.identity.validate()
        guard kind == "pechpech-opaque-hello", claims.protocolName == "pechpech-opaque-link-1",
              claims.profile.utf8.elementsEqual(profile.utf8),
              !profile.isEmpty, profile.utf8.count <= 128, claims.routes.count <= 32,
              claims.routes.allSatisfy({ WireCoding.isAddress($0.key) && (0...7).contains($0.value) }),
              signature.count == 64,
              try Curve25519.Signing.PublicKey(rawRepresentation: claims.identity.signingKey)
                .isValidSignature(signature, for: WireCoding.encode(claims)) else { throw PechPechError.authenticationFailed }
    }
}

public struct OpaqueAckClaims: Codable, Equatable, Sendable {
    public let protocolName: String
    public let profile: String
    public let senderID: String
    public let packetID: UUID
    public let immutableHash: Data
    public let echo: UUID
    public init(profile: String, senderID: String, packetID: UUID, immutableHash: Data, echo: UUID) {
        protocolName = "pechpech-opaque-ack-1"; self.profile = profile; self.senderID = senderID
        self.packetID = packetID; self.immutableHash = immutableHash; self.echo = echo
    }
}

public struct SignedOpaqueAck: Codable, Equatable, Sendable {
    public let kind: String
    public let claims: OpaqueAckClaims
    public let signature: Data
    public init(identity: Identity, profile: String, packet: OpaquePacket, echo: UUID) throws {
        kind = "pechpech-opaque-stored"
        claims = OpaqueAckClaims(profile: profile, senderID: identity.publicIdentity.id, packetID: packet.id,
                                 immutableHash: packet.immutableHash, echo: echo)
        signature = try identity.sign(WireCoding.encode(claims))
    }
    public func validate(sender: PublicIdentity, challenge: UUID, profile: String) throws {
        try sender.validate()
        guard kind == "pechpech-opaque-stored", claims.protocolName == "pechpech-opaque-ack-1",
              claims.profile.utf8.elementsEqual(profile.utf8),
              !profile.isEmpty, profile.utf8.count <= 128,
              claims.senderID == sender.id, claims.echo == challenge, claims.immutableHash.count == 32, signature.count == 64,
              try Curve25519.Signing.PublicKey(rawRepresentation: sender.signingKey)
                .isValidSignature(signature, for: WireCoding.encode(claims)) else { throw PechPechError.authenticationFailed }
    }
}

/// Routes host-owned packets through authenticated PechPech neighbor sessions.
/// This separate opaque profile does not use MeshNode's endpoint envelope or database.
/// The host must authenticate endpoint bytes and complete phase-specific processing
/// before receiveEndpoint returns. Volatile control phases need not be persisted;
/// business results must be durable before the host issues a business receipt.
/// A hop acknowledgment never means business delivery.
@MainActor public final class OpaquePacketRouter {
    public var onNeighbors: (([PublicIdentity]) -> Void)?
    public var onRoutes: (([String: Int]) -> Void)?
    public var onEvent: ((NodeEvent) -> Void)?
    public let identity: Identity
    public let profile: String
    private let links: [any PacketLink]
    private let decode: (Data) throws -> OpaquePacket
    private let forwarded: (OpaquePacket) throws -> OpaquePacket
    private let loadPending: () async throws -> [OpaquePacket]
    private let persistRelay: (OpaquePacket) async throws -> Void
    private let removeRelay: (UUID) async throws -> Void
    private let receiveEndpoint: (OpaquePacket) async throws -> Void
    private var timer: Task<Void, Never>?
    private var running = false
    private var stopping = false
    private var restartRequested = false
    private var generation: UInt64 = 0
    private var peers: [Slot: Peer] = [:]
    private var incoming = Set<UUID>()
    private var removing = Set<UUID>()
    private var flushingGeneration: UInt64?
    private var flushAgain = false
    private static let maximumPendingPerPass = 1_024
    private struct Slot: Hashable { let link: Int; let id: String }
    private final class Peer {
        let challenge = UUID()
        var remoteChallenge: UUID?
        var remoteIdentity: PublicIdentity?
        var echoed: UUID?
        var ready = false
        var lastHello = ContinuousClock.now
        var routes: [String: Int] = [:]
        var sent: [UUID: Data] = [:]
        var sourcePackets = Set<UUID>()
        var tokens: Double = 64
        var tokenAt = ContinuousClock.now
    }

    public init(identity: Identity, profile: String, links: [any PacketLink],
                decode: @escaping (Data) throws -> OpaquePacket,
                forwarded: @escaping (OpaquePacket) throws -> OpaquePacket,
                loadPending: @escaping () async throws -> [OpaquePacket],
                persistRelay: @escaping (OpaquePacket) async throws -> Void,
                removeRelay: @escaping (UUID) async throws -> Void,
                receiveEndpoint: @escaping (OpaquePacket) async throws -> Void) throws {
        guard !profile.isEmpty, profile.utf8.count <= 128 else { throw PechPechError.invalid("Invalid opaque profile identifier.") }
        guard Set(links.map { ObjectIdentifier($0) }).count == links.count else {
            throw PechPechError.invalid("Use a distinct packet-link instance for each adapter.")
        }
        self.identity = identity; self.profile = profile; self.links = links; self.decode = decode
        self.forwarded = forwarded; self.loadPending = loadPending; self.persistRelay = persistRelay
        self.removeRelay = removeRelay; self.receiveEndpoint = receiveEndpoint
        for (index, link) in links.enumerated() {
            link.onState = { [weak self] in self?.onEvent?(.linkState($0)) }
            link.onLinkReady = { [weak self] id in self?.linkReady(Slot(link: index, id: id)) }
            link.onMessage = { [weak self] bytes, id in self?.receive(bytes, from: Slot(link: index, id: id)) }
            link.onDisconnected = { [weak self] id in
                guard let self else { return }
                self.peers.removeValue(forKey: Slot(link: index, id: id)); self.publishTopology()
            }
        }
    }
    deinit { timer?.cancel() }

    public var connectedIdentities: [PublicIdentity] {
        var unique: [String: PublicIdentity] = [:]
        for peer in peers.values where peer.ready {
            if let identity = peer.remoteIdentity { unique[identity.id] = identity }
        }
        return unique.values.sorted { $0.id < $1.id }
    }
    /// Signed route advertisements are reachability hints, not endpoint authorization.
    public var routes: [String: Int] {
        var result = [identity.publicIdentity.id: 0]
        for peer in peers.values where peer.ready {
            guard let neighbor = peer.remoteIdentity else { continue }
            result[neighbor.id] = min(result[neighbor.id] ?? 8, 1)
            for (destination, hops) in peer.routes where destination != identity.publicIdentity.id && hops < 7 {
                result[destination] = min(result[destination] ?? 8, hops + 1)
            }
        }
        let sorted = result.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }
        return Dictionary(uniqueKeysWithValues: sorted.prefix(32).map { ($0.key, $0.value) })
    }
    public func start() {
        if stopping { restartRequested = true; return }
        guard !running else { return }
        running = true; generation &+= 1
        let epoch = generation
        for link in links {
            guard isCurrent(epoch) else { return }
            link.start(nodeName: identity.publicIdentity.id)
        }
        guard isCurrent(epoch) else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.isCurrent(epoch) else { return }
                await self.tick()
            }
        }
        Task { [weak self] in
            guard let self, self.isCurrent(epoch) else { return }
            await self.flush()
        }
    }
    /// Stops new sends. Host operations already awaiting durable completion cannot be recalled.
    public func stop() {
        if stopping { restartRequested = false; return }
        guard running else { return }
        running = false; generation &+= 1; timer?.cancel(); timer = nil
        stopping = true
        defer {
            stopping = false
            if restartRequested { restartRequested = false; start() }
        }
        peers.removeAll(); incoming.removeAll(); removing.removeAll()
        // Finish tearing down every adapter before honoring a callback's restart.
        for link in links { link.stop() }
        publishTopology()
    }

    /// A single explicit attempt. This never saves an origin in a relay spool or
    /// resumes it later; the host owns immutable commands and foreground retry intent.
    public func sendOrigin(_ packet: OpaquePacket) async throws {
        guard running else { return }
        let epoch = generation
        try packet.validate()
        guard packet.originID == identity.publicIdentity.id else { throw PechPechError.identityConflict }
        if packet.destinationID == identity.publicIdentity.id {
            try await receiveEndpoint(packet)
            guard isCurrent(epoch) else { return }
        } else {
            if connectedIdentities.isEmpty { onEvent?(.waitingForRoute(packet.id)) }
            else { onEvent?(.transmitting(packet.id)) }
            guard isCurrent(epoch) else { return }
            forward(packet)
        }
    }

    /// Foreground retry pass. Stored foreign packets have already spent one hop
    /// before durable admission and are not decremented again during retries.
    public func tick() async {
        guard running else { return }
        let epoch = generation
        for (slot, peer) in peers {
            guard isCurrent(epoch) else { return }
            guard peers[slot] === peer else { continue }
            peer.sent.removeAll(); peer.sourcePackets.removeAll()
            if peer.ready && peer.lastHello.duration(to: .now) > .seconds(15) { peer.ready = false }
            sendHello(to: slot)
        }
        guard isCurrent(epoch) else { return }
        publishTopology()
        guard isCurrent(epoch) else { return }
        await flush()
    }
    public func flush() async {
        guard running else { return }
        let epoch = generation
        if flushingGeneration == epoch { flushAgain = true; return }
        flushingGeneration = epoch
        defer { if flushingGeneration == epoch { flushingGeneration = nil } }
        var passes = 0
        repeat {
            flushAgain = false; passes += 1
            do {
                let pending = try await loadPending()
                guard isCurrent(epoch) else { return }
                let sorted = pending.sorted {
                    if $0.priority != $1.priority { return $0.priority > $1.priority }
                    if $0.expiresAt != $1.expiresAt { return $0.expiresAt < $1.expiresAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
                for packet in sorted.prefix(Self.maximumPendingPerPass) {
                    guard isCurrent(epoch) else { return }
                    do { try packet.validate(); forward(packet) }
                    catch PechPechError.expired { continue }
                }
            } catch { if isCurrent(epoch) { report(error) } }
        } while flushAgain && passes < 2 && isCurrent(epoch)
    }

    private func isCurrent(_ epoch: UInt64) -> Bool { running && epoch == generation }
    private func linkReady(_ slot: Slot) {
        guard running, peer(for: slot) != nil else { return }
        sendHello(to: slot)
    }
    private func peer(for slot: Slot) -> Peer? {
        if let existing = peers[slot] { return existing }
        // A custom adapter cannot manufacture unbounded unauthenticated handles.
        guard peers.keys.filter({ $0.link == slot.link }).count < 4 else { return nil }
        let peer = Peer(); peers[slot] = peer; return peer
    }
    private func sendHello(to slot: Slot) {
        guard running, let peer = peers[slot] else { return }
        let epoch = generation
        do {
            let hello = try SignedOpaqueHello(identity: identity, profile: profile, challenge: peer.challenge,
                                               echo: peer.remoteChallenge, routes: routes)
            let previous = peer.echoed; peer.echoed = peer.remoteChallenge
            if !send(try WireCoding.encode(hello), to: slot, priority: 3, epoch: epoch) { peer.echoed = previous }
        } catch { if isCurrent(epoch) { report(error) } }
    }
    private func receive(_ bytes: Data, from slot: Slot) {
        guard running, !bytes.isEmpty, bytes.count <= RelayPacket.maximumBytes,
              let peer = peer(for: slot), takeToken(peer) else { return }
        let epoch = generation
        do {
            if let hello = try? WireCoding.decode(SignedOpaqueHello.self, from: bytes) {
                try hello.validate(profile: profile)
                guard hello.claims.identity.id != identity.publicIdentity.id else { throw PechPechError.identityConflict }
                if let prior = peer.remoteIdentity, prior != hello.claims.identity { throw PechPechError.identityConflict }
                if let prior = peer.remoteChallenge, prior != hello.claims.challenge { throw PechPechError.authenticationFailed }
                peer.remoteIdentity = hello.claims.identity; peer.remoteChallenge = hello.claims.challenge
                peer.lastHello = .now; peer.routes = hello.claims.routes
                if hello.claims.echo == peer.challenge {
                    guard connectedIdentities.contains(hello.claims.identity) || connectedIdentities.count < 4 else {
                        throw PechPechError.invalid("The four-neighbor limit is reached.")
                    }
                    let wasReady = peer.ready; peer.ready = true
                    links[slot.link].confirmPeer(slot.id)
                    guard isCurrent(epoch), peers[slot] === peer else { return }
                    if !wasReady { publishTopology() }
                    guard isCurrent(epoch), peers[slot] === peer else { return }
                }
                if peer.echoed != hello.claims.challenge { sendHello(to: slot) }
                guard isCurrent(epoch), peers[slot] === peer else { return }
                if peer.ready {
                    publishTopology()
                    guard isCurrent(epoch), peers[slot] === peer else { return }
                    Task { [weak self] in
                        guard let self, self.isCurrent(epoch) else { return }
                        await self.flush()
                    }
                }
                return
            }
            guard peer.ready, let neighbor = peer.remoteIdentity else { throw PechPechError.authenticationFailed }
            if let ack = try? WireCoding.decode(SignedOpaqueAck.self, from: bytes) {
                try ack.validate(sender: neighbor, challenge: peer.challenge, profile: profile)
                guard peer.sent[ack.claims.packetID] == ack.claims.immutableHash else { throw PechPechError.authenticationFailed }
                guard !removing.contains(ack.claims.packetID), removing.count < 64 else { return }
                removing.insert(ack.claims.packetID)
                Task { [weak self] in
                    guard let self else { return }
                    defer { if self.generation == epoch { self.removing.remove(ack.claims.packetID) } }
                    guard self.isCurrent(epoch) else { return }
                    do { try await self.removeRelay(ack.claims.packetID) }
                    catch { if self.isCurrent(epoch) { self.report(error) } }
                }
                return
            }
            let packet = try decode(bytes)
            guard isCurrent(epoch), peers[slot] === peer, peer.ready else { return }
            guard packet.bytes == bytes else {
                throw PechPechError.invalid("The host decoder changed the original packet bytes.")
            }
            try packet.validate()
            guard !incoming.contains(packet.id), incoming.count < 64 else { return }
            if packet.destinationID != identity.publicIdentity.id {
                guard packet.hopsRemaining > 0, packet.originID != identity.publicIdentity.id else { return }
            }
            incoming.insert(packet.id)
            Task { [weak self] in
                guard let self else { return }
                defer { if self.generation == epoch { self.incoming.remove(packet.id) } }
                guard self.isCurrent(epoch) else { return }
                do {
                    try packet.validate()
                    let saved: OpaquePacket?
                    if packet.destinationID == self.identity.publicIdentity.id {
                        try await self.receiveEndpoint(packet); saved = nil
                    } else {
                        let next = try self.forwarded(packet)
                        guard self.isCurrent(epoch), self.peers[slot] === peer, peer.ready else { return }
                        guard next.id == packet.id, next.destinationID == packet.destinationID, next.originID == packet.originID,
                              next.priority == packet.priority, next.expiresAt == packet.expiresAt,
                              next.immutableHash == packet.immutableHash, next.hopsRemaining == packet.hopsRemaining - 1 else {
                            throw PechPechError.invalid("The host forwarding codec changed immutable packet metadata.")
                        }
                        try next.validate()
                        try await self.persistRelay(next); saved = next
                    }
                    guard self.isCurrent(epoch), self.peers[slot] === peer, peer.ready else { return }
                    try packet.validate()
                    peer.sourcePackets.insert(packet.id)
                    if peer.sourcePackets.count > Self.maximumPendingPerPass { peer.sourcePackets.removeAll() }
                    if let echo = peer.remoteChallenge {
                        let ack = try SignedOpaqueAck(identity: self.identity, profile: self.profile, packet: packet, echo: echo)
                        _ = self.send(try WireCoding.encode(ack), to: slot, priority: 3, epoch: epoch)
                    }
                    guard self.isCurrent(epoch) else { return }
                    if let saved { self.forward(saved, excluding: slot) }
                    guard self.isCurrent(epoch) else { return }
                    await self.flush()
                } catch { if self.isCurrent(epoch) { self.report(error) } }
            }
        } catch { if isCurrent(epoch) { report(error) } }
    }
    private func forward(_ packet: OpaquePacket, excluding source: Slot? = nil) {
        guard running else { return }
        let epoch = generation
        let destinations = peers.keys.sorted { a, b in
            let aDirect = peers[a]?.remoteIdentity?.id == packet.destinationID
            let bDirect = peers[b]?.remoteIdentity?.id == packet.destinationID
            if aDirect != bDirect { return aDirect }
            let aDistance = peers[a]?.routes[packet.destinationID] ?? 8
            let bDistance = peers[b]?.routes[packet.destinationID] ?? 8
            if aDistance != bDistance { return aDistance < bDistance }
            return a.link == b.link ? a.id < b.id : a.link < b.link
        }
        for slot in destinations {
            guard isCurrent(epoch) else { return }
            guard slot != source, let peer = peers[slot], peer.ready, let neighbor = peer.remoteIdentity,
                  neighbor.id != packet.originID, peer.sent[packet.id] == nil,
                  !peer.sourcePackets.contains(packet.id), peer.sent.count < Self.maximumPendingPerPass else { continue }
            // Set before synchronous custom-adapter reentrancy, roll back on local backpressure.
            peer.sent[packet.id] = packet.immutableHash
            if !send(packet.bytes, to: slot, priority: packet.priority, epoch: epoch) { peer.sent.removeValue(forKey: packet.id) }
        }
    }
    private func send(_ bytes: Data, to slot: Slot, priority: Int, epoch: UInt64) -> Bool {
        guard isCurrent(epoch), !bytes.isEmpty, bytes.count <= RelayPacket.maximumBytes else { return false }
        return links[slot.link].send(bytes, to: slot.id, priority: priority)
    }
    private func takeToken(_ peer: Peer) -> Bool {
        let now = ContinuousClock.now, components = peer.tokenAt.duration(to: now).components
        let elapsed = Double(components.seconds) + Double(components.attoseconds) / 1e18
        peer.tokens = min(64, peer.tokens + max(0, elapsed) * 32); peer.tokenAt = now
        guard peer.tokens >= 1 else { return false }
        peer.tokens -= 1; return true
    }
    private func publishTopology() {
        let epoch = generation
        onNeighbors?(connectedIdentities)
        guard generation == epoch else { return }
        onRoutes?(routes)
    }
    private func report(_ error: Error) {
        if let error = error as? PechPechError, error == .spoolFull { onEvent?(.relayBackpressure) }
        else { onEvent?(.error(error.localizedDescription)) }
    }
}
