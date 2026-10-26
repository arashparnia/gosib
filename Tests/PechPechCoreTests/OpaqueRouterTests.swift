import Foundation
import XCTest
@testable import PechPechCore

private struct TestOpaqueWire: Codable, Equatable {
    let id: UUID
    let destinationID: String
    let originID: String
    var hopsRemaining: Int
    let priority: Int
    let expiresAt: Int64
    let payload: Data
    func descriptor() throws -> OpaquePacket {
        var immutable = self; immutable.hopsRemaining = 0
        return try OpaquePacket(id: id, destinationID: destinationID, originID: originID, hopsRemaining: hopsRemaining,
                                priority: priority, expiresAt: expiresAt, bytes: WireCoding.encode(self),
                                immutableHash: WireCoding.hash(WireCoding.encode(immutable)))
    }
}

@MainActor private final class OpaqueTestLink: PacketLink {
    var onState: ((String) -> Void)?
    var onPeers: (([LinkPeer]) -> Void)?
    var onMessage: ((Data, String) -> Void)?
    var onLinkReady: ((String) -> Void)?
    var onDisconnected: ((String) -> Void)?
    var name = ""
    var running = false
    var peers: [String: OpaqueTestLink] = [:]
    var sent: [Data] = []
    var drop: ((Data) -> Bool)?
    var reject: ((Data) -> Bool)?
    var didStop: (() -> Void)?
    var startCalls = 0
    var stopCalls = 0
    func start(nodeName: String) { startCalls += 1; name = nodeName; running = true; onState?("Started") }
    func stop() {
        stopCalls += 1
        running = false
        for other in Array(peers.values) { disconnect(other) }
        didStop?()
    }
    func confirmPeer(_ peerID: String) {}
    func send(_ data: Data, to peerID: String, priority: Int) -> Bool {
        guard running, let other = peers[peerID], other.running else { return false }
        if reject?(data) == true { return false }
        sent.append(data)
        if drop?(data) != true { other.onMessage?(data, name) }
        return true
    }
    func connect(_ other: OpaqueTestLink) {
        peers[other.name] = other; other.peers[name] = self
        onLinkReady?(other.name); other.onLinkReady?(name)
    }
    func disconnect(_ other: OpaqueTestLink) {
        peers.removeValue(forKey: other.name); other.peers.removeValue(forKey: name)
        onDisconnected?(other.name); other.onDisconnected?(name)
    }
    var packets: [TestOpaqueWire] { sent.compactMap { try? WireCoding.decode(TestOpaqueWire.self, from: $0) } }
    var acknowledgments: [SignedOpaqueAck] { sent.compactMap { try? WireCoding.decode(SignedOpaqueAck.self, from: $0) } }
}

@MainActor private final class OpaqueHost {
    var pending: [UUID: OpaquePacket] = [:]
    var inbox: [UUID: OpaquePacket] = [:]
    var calls = 0
    var relayWrites = 0
    var failRelay = false
    var failEndpoint = false
    var holdEndpoint: CheckedContinuation<Void, Never>?
    var endpointEntered = false
    var holdNextEndpoint = false
    func persist(_ packet: OpaquePacket) throws {
        if failRelay { throw PechPechError.spoolFull }
        relayWrites += 1
        if let existing = pending[packet.id] {
            guard existing.immutableHash == packet.immutableHash else { throw PechPechError.messageConflict }
            if packet.hopsRemaining < existing.hopsRemaining { pending[packet.id] = packet }
        } else { pending[packet.id] = packet }
    }
    func accept(_ packet: OpaquePacket) async throws {
        calls += 1; endpointEntered = true
        if holdNextEndpoint {
            holdNextEndpoint = false
            await withCheckedContinuation { holdEndpoint = $0 }
        }
        if failEndpoint { throw PechPechError.storage("Synthetic endpoint failure.") }
        if let existing = inbox[packet.id], existing.immutableHash != packet.immutableHash { throw PechPechError.messageConflict }
        inbox[packet.id] = packet
    }
}

final class OpaqueRouterTests: XCTestCase {
    private let profile = "tests.opaque.v1"
    @MainActor private func router(_ identity: Identity, _ link: OpaqueTestLink, _ host: OpaqueHost,
                                  profile: String? = nil) throws -> OpaquePacketRouter {
        try OpaquePacketRouter(identity: identity, profile: profile ?? self.profile, links: [link],
            decode: { try WireCoding.decode(TestOpaqueWire.self, from: $0).descriptor() },
            forwarded: {
                var wire = try WireCoding.decode(TestOpaqueWire.self, from: $0.bytes)
                wire.hopsRemaining -= 1
                return try wire.descriptor()
            }, loadPending: { Array(host.pending.values) }, persistRelay: { try host.persist($0) },
            removeRelay: { host.pending.removeValue(forKey: $0) }, receiveEndpoint: { try await host.accept($0) })
    }
    private func packet(_ sender: Identity, _ receiver: Identity, id: UUID = UUID(), hops: Int = 8,
                        priority: Int = 2, payload: Data = Data([1])) throws -> OpaquePacket {
        try TestOpaqueWire(id: id, destinationID: receiver.publicIdentity.id, originID: sender.publicIdentity.id,
                           hopsRemaining: hops, priority: priority, expiresAt: WireCoding.now + 60_000, payload: payload).descriptor()
    }
    @MainActor private func settle() async { for _ in 0..<40 { await Task.yield() } }

    @MainActor func testTwoHopUsesHostPersistenceAndSpendsOneHopBeforeStorage() async throws {
        let a = Identity(), relay = Identity(), b = Identity()
        let la = OpaqueTestLink(), lr = OpaqueTestLink(), lb = OpaqueTestLink()
        let ha = OpaqueHost(), hr = OpaqueHost(), hb = OpaqueHost()
        let sender = try router(a, la, ha), middle = try router(relay, lr, hr), receiver = try router(b, lb, hb)
        defer { sender.stop(); middle.stop(); receiver.stop() }
        sender.start(); middle.start(); receiver.start(); la.connect(lr); lr.connect(lb)
        await settle(); await sender.tick(); await middle.tick(); await receiver.tick()
        let original = try packet(a, b)
        // Keep the durable relay copy so another flush can prove it is not decremented twice.
        lb.drop = { (try? WireCoding.decode(SignedOpaqueAck.self, from: $0)) != nil }
        try await sender.sendOrigin(original); await settle()
        XCTAssertEqual(hr.pending[original.id]?.hopsRemaining, 7)
        XCTAssertEqual(hb.inbox[original.id]?.hopsRemaining, 7)
        XCTAssertEqual(hb.inbox[original.id]?.immutableHash, original.immutableHash)
        XCTAssertTrue(ha.pending.isEmpty)
        await middle.tick(); await settle()
        XCTAssertTrue(lr.packets.filter { $0.id == original.id }.allSatisfy { $0.hopsRemaining == 7 })
        XCTAssertEqual(sender.routes[b.publicIdentity.id], 2)
        XCTAssertEqual(hb.inbox.count, 1)
    }

    @MainActor func testDeniedOriginQueueIsRetryableAndNeverResumedFromSpool() async throws {
        let a = Identity(), b = Identity(), la = OpaqueTestLink(), lb = OpaqueTestLink(), ha = OpaqueHost(), hb = OpaqueHost()
        let sender = try router(a, la, ha), receiver = try router(b, lb, hb)
        defer { sender.stop(); receiver.stop() }
        sender.start(); receiver.start(); la.connect(lb); await settle()
        let original = try packet(a, b)
        la.reject = { (try? WireCoding.decode(TestOpaqueWire.self, from: $0)) != nil }
        try await sender.sendOrigin(original); await settle()
        XCTAssertTrue(hb.inbox.isEmpty)
        XCTAssertTrue(ha.pending.isEmpty)
        la.reject = nil
        await sender.tick(); await settle()
        XCTAssertTrue(hb.inbox.isEmpty, "The SDK must not resume an ephemeral origin attempt.")
        try await sender.sendOrigin(original); await settle()
        XCTAssertEqual(hb.inbox[original.id]?.bytes, original.bytes)
        XCTAssertEqual(la.packets.count, 1)
    }

    @MainActor func testEndpointStorageFailureHasNoHopAckAndIdenticalRetryReprocesses() async throws {
        let a = Identity(), b = Identity(), la = OpaqueTestLink(), lb = OpaqueTestLink(), ha = OpaqueHost(), hb = OpaqueHost()
        let sender = try router(a, la, ha), receiver = try router(b, lb, hb)
        defer { sender.stop(); receiver.stop() }
        sender.start(); receiver.start(); la.connect(lb); await settle()
        let original = try packet(a, b)
        hb.failEndpoint = true
        try await sender.sendOrigin(original); await settle()
        XCTAssertTrue(hb.inbox.isEmpty); XCTAssertTrue(lb.acknowledgments.isEmpty)
        hb.failEndpoint = false
        await sender.tick(); try await sender.sendOrigin(original); await settle()
        XCTAssertEqual(hb.inbox.count, 1); XCTAssertEqual(lb.acknowledgments.count, 1)
        await sender.tick(); try await sender.sendOrigin(original); await settle()
        XCTAssertEqual(hb.calls, 3, "Authenticated endpoint retries must recover lost business acknowledgments.")
        XCTAssertEqual(hb.inbox.count, 1)
    }

    @MainActor func testRelayStorageFailureHasNoAckAndRetryUsesSameHopBudget() async throws {
        let a = Identity(), relay = Identity(), b = Identity(), la = OpaqueTestLink(), lr = OpaqueTestLink()
        let ha = OpaqueHost(), hr = OpaqueHost(), sender = try router(a, la, ha), middle = try router(relay, lr, hr)
        defer { sender.stop(); middle.stop() }
        sender.start(); middle.start(); la.connect(lr); await settle()
        let original = try packet(a, b)
        hr.failRelay = true
        try await sender.sendOrigin(original); await settle()
        XCTAssertTrue(hr.pending.isEmpty); XCTAssertTrue(lr.acknowledgments.isEmpty)
        hr.failRelay = false
        await sender.tick(); try await sender.sendOrigin(original); await settle()
        XCTAssertEqual(hr.pending[original.id]?.hopsRemaining, 7)
        XCTAssertEqual(lr.acknowledgments.first?.claims.immutableHash, original.immutableHash)
    }

    @MainActor func testProfileMismatchCannotCreateNeighborOrCarryPackets() async throws {
        let a = Identity(), b = Identity(), la = OpaqueTestLink(), lb = OpaqueTestLink(), ha = OpaqueHost(), hb = OpaqueHost()
        let sender = try router(a, la, ha), receiver = try router(b, lb, hb, profile: "other.profile")
        defer { sender.stop(); receiver.stop() }
        sender.start(); receiver.start(); la.connect(lb); await settle()
        XCTAssertTrue(sender.connectedIdentities.isEmpty); XCTAssertTrue(receiver.connectedIdentities.isEmpty)
        try await sender.sendOrigin(packet(a, b)); await settle()
        XCTAssertTrue(hb.inbox.isEmpty)
    }

    @MainActor func testStaleWrongHashAndForeignProfileAcksCannotRemoveHostRelay() async throws {
        let origin = Identity(), relay = Identity(), endpoint = Identity(), lr = OpaqueTestLink(), lb = OpaqueTestLink()
        let hr = OpaqueHost(), hb = OpaqueHost(), middle = try router(relay, lr, hr), receiver = try router(endpoint, lb, hb)
        defer { middle.stop(); receiver.stop() }
        let original = try packet(origin, endpoint, hops: 7)
        hr.pending[original.id] = original
        lb.drop = { (try? WireCoding.decode(SignedOpaqueAck.self, from: $0)) != nil }
        middle.start(); receiver.start(); lr.connect(lb); await settle()
        let hello = try XCTUnwrap(lr.sent.compactMap { try? WireCoding.decode(SignedOpaqueHello.self, from: $0) }.last)
        let wrongPacket = try packet(origin, endpoint, id: original.id, hops: 7, payload: Data([9]))
        let candidates = [
            try SignedOpaqueAck(identity: endpoint, profile: profile, packet: original, echo: UUID()),
            try SignedOpaqueAck(identity: endpoint, profile: profile, packet: wrongPacket, echo: hello.claims.challenge),
            try SignedOpaqueAck(identity: endpoint, profile: "foreign", packet: original, echo: hello.claims.challenge)
        ]
        for candidate in candidates {
            lr.onMessage?(try WireCoding.encode(candidate), endpoint.publicIdentity.id); await settle()
            XCTAssertNotNil(hr.pending[original.id])
        }
        let valid = try SignedOpaqueAck(identity: endpoint, profile: profile, packet: original, echo: hello.claims.challenge)
        lr.onMessage?(try WireCoding.encode(valid), endpoint.publicIdentity.id); await settle()
        XCTAssertNil(hr.pending[original.id])
    }

    @MainActor func testStopWhileEndpointAwaitsPersistencePreventsLateHopAck() async throws {
        let a = Identity(), b = Identity(), la = OpaqueTestLink(), lb = OpaqueTestLink(), ha = OpaqueHost(), hb = OpaqueHost()
        let sender = try router(a, la, ha), receiver = try router(b, lb, hb)
        defer { sender.stop(); receiver.stop() }
        sender.start(); receiver.start(); la.connect(lb); await settle()
        hb.holdNextEndpoint = true
        let original = try packet(a, b)
        try await sender.sendOrigin(original); await settle()
        XCTAssertTrue(hb.endpointEntered)
        receiver.stop()
        let continuation = try XCTUnwrap(hb.holdEndpoint); hb.holdEndpoint = nil; continuation.resume()
        await settle()
        XCTAssertEqual(hb.inbox.count, 1, "Already-started host writes cannot be recalled.")
        XCTAssertTrue(lb.acknowledgments.isEmpty)
    }

    @MainActor func testPendingPriorityAndDeniedQueueAdmissionAreRetryable() async throws {
        let origin = Identity(), relay = Identity(), endpoint = Identity(), lr = OpaqueTestLink(), lb = OpaqueTestLink()
        let hr = OpaqueHost(), hb = OpaqueHost(), middle = try router(relay, lr, hr), receiver = try router(endpoint, lb, hb)
        defer { middle.stop(); receiver.stop() }
        let packets = try [0, 2, 3].map { try packet(origin, endpoint, hops: 7, priority: $0) }
        packets.forEach { hr.pending[$0.id] = $0 }
        lr.reject = { (try? WireCoding.decode(TestOpaqueWire.self, from: $0)) != nil }
        middle.start(); receiver.start(); lr.connect(lb); await settle()
        XCTAssertTrue(lr.packets.isEmpty)
        lr.reject = nil
        await middle.flush(); await settle()
        XCTAssertEqual(lr.packets.map(\.priority), [3, 2, 0])
        XCTAssertEqual(hb.inbox.count, 3)
    }

    @MainActor func testInvalidForwardingCodecCannotPersistOrAcknowledge() async throws {
        let a = Identity(), relay = Identity(), endpoint = Identity(), la = OpaqueTestLink(), lr = OpaqueTestLink()
        let ha = OpaqueHost(), hr = OpaqueHost(), sender = try router(a, la, ha)
        let middle = try OpaquePacketRouter(identity: relay, profile: profile, links: [lr],
            decode: { try WireCoding.decode(TestOpaqueWire.self, from: $0).descriptor() },
            forwarded: { $0 }, // A broken codec does not spend a hop.
            loadPending: { Array(hr.pending.values) }, persistRelay: { try hr.persist($0) },
            removeRelay: { hr.pending.removeValue(forKey: $0) }, receiveEndpoint: { try await hr.accept($0) })
        defer { sender.stop(); middle.stop() }
        sender.start(); middle.start(); la.connect(lr); await settle()
        try await sender.sendOrigin(packet(a, endpoint)); await settle()
        XCTAssertTrue(hr.pending.isEmpty); XCTAssertTrue(lr.acknowledgments.isEmpty)
    }

    @MainActor func testRestartDoesNotWaitForObsoleteLoadOrSendItsPackets() async throws {
        let origin = Identity(), relay = Identity(), endpoint = Identity(), lr = OpaqueTestLink(), lb = OpaqueTestLink()
        let hr = OpaqueHost(), hb = OpaqueHost(), receiver = try router(endpoint, lb, hb)
        let obsolete = try packet(origin, endpoint, hops: 7, payload: Data([8]))
        let current = try packet(origin, endpoint, hops: 7, payload: Data([9]))
        var continuation: CheckedContinuation<[OpaquePacket], Never>?
        var firstLoad = true
        let middle = try OpaquePacketRouter(identity: relay, profile: profile, links: [lr],
            decode: { try WireCoding.decode(TestOpaqueWire.self, from: $0).descriptor() },
            forwarded: { $0 }, loadPending: {
                if firstLoad {
                    firstLoad = false
                    return await withCheckedContinuation { continuation = $0 }
                }
                return Array(hr.pending.values)
            }, persistRelay: { try hr.persist($0) }, removeRelay: { hr.pending.removeValue(forKey: $0) },
            receiveEndpoint: { try await hr.accept($0) })
        defer { middle.stop(); receiver.stop() }
        middle.start(); await settle()
        XCTAssertNotNil(continuation)
        middle.stop(); hr.pending[current.id] = current
        receiver.start(); middle.start(); lr.connect(lb); await settle()
        XCTAssertNotNil(hb.inbox[current.id], "A new generation can flush while an obsolete host read is suspended.")
        let obsoleteContinuation = try XCTUnwrap(continuation); continuation = nil; obsoleteContinuation.resume(returning: [obsolete])
        await settle()
        XCTAssertNil(hb.inbox[obsolete.id])
        XCTAssertFalse(lr.packets.contains { $0.id == obsolete.id })
    }

    @MainActor func testReentrantRestartDuringSendCannotContinueOriginInNewSession() async throws {
        let origin = Identity(), first = Identity(), second = Identity(), destination = Identity()
        let la = OpaqueTestLink(), l1 = OpaqueTestLink(), l2 = OpaqueTestLink()
        let ha = OpaqueHost(), h1 = OpaqueHost(), h2 = OpaqueHost()
        let sender = try router(origin, la, ha), r1 = try router(first, l1, h1), r2 = try router(second, l2, h2)
        defer { sender.stop(); r1.stop(); r2.stop() }
        sender.start(); r1.start(); r2.start(); la.connect(l1); la.connect(l2); await settle()
        var restarted = false
        la.reject = { bytes in
            guard !restarted, (try? WireCoding.decode(TestOpaqueWire.self, from: bytes)) != nil else { return false }
            restarted = true
            sender.stop(); sender.start(); la.connect(l1); la.connect(l2)
            return true
        }
        let original = try packet(origin, destination)
        try await sender.sendOrigin(original); await settle()
        XCTAssertTrue(restarted)
        XCTAssertTrue(la.packets.isEmpty, "An obsolete forwarding loop must not continue over newly authenticated links.")
        XCTAssertTrue(h1.pending.isEmpty); XCTAssertTrue(h2.pending.isEmpty)
        try await sender.sendOrigin(original); await settle()
        XCTAssertEqual(h1.pending[original.id]?.immutableHash, original.immutableHash)
        XCTAssertEqual(h2.pending[original.id]?.immutableHash, original.immutableHash)
    }

    @MainActor func testForwardingCallbackRestartCannotBeginObsoleteHostWrite() async throws {
        let origin = Identity(), relay = Identity(), endpoint = Identity(), la = OpaqueTestLink(), lr = OpaqueTestLink()
        let ha = OpaqueHost(), hr = OpaqueHost(), sender = try router(origin, la, ha)
        weak var middleReference: OpaquePacketRouter?
        var restarted = false
        let middle = try OpaquePacketRouter(identity: relay, profile: profile, links: [lr],
            decode: { try WireCoding.decode(TestOpaqueWire.self, from: $0).descriptor() },
            forwarded: { packet in
                var wire = try WireCoding.decode(TestOpaqueWire.self, from: packet.bytes)
                wire.hopsRemaining -= 1
                let next = try wire.descriptor()
                if !restarted {
                    restarted = true; middleReference?.stop(); middleReference?.start()
                }
                return next
            }, loadPending: { Array(hr.pending.values) }, persistRelay: { try hr.persist($0) },
            removeRelay: { hr.pending.removeValue(forKey: $0) }, receiveEndpoint: { try await hr.accept($0) })
        middleReference = middle
        defer { sender.stop(); middle.stop() }
        sender.start(); middle.start(); la.connect(lr); await settle()
        try await sender.sendOrigin(packet(origin, endpoint)); await settle()
        XCTAssertTrue(restarted)
        XCTAssertEqual(hr.relayWrites, 0, "A host write that has not begun must respect a stop from the forwarding callback.")
        XCTAssertTrue(hr.pending.isEmpty); XCTAssertTrue(lr.acknowledgments.isEmpty)
    }

    @MainActor func testStopIsIdempotentWhenTopologyCallbackStopsAgain() throws {
        let node = try router(Identity(), OpaqueTestLink(), OpaqueHost())
        var notifications = 0
        node.onNeighbors = { _ in
            notifications += 1
            if notifications < 3 { node.stop() }
        }
        node.start(); node.stop()
        XCTAssertEqual(notifications, 1)
        node.stop()
        XCTAssertEqual(notifications, 1)
    }

    @MainActor func testRestartFromAdapterStopWaitsForEveryAdapterToStop() throws {
        let first = OpaqueTestLink(), second = OpaqueTestLink()
        let node = try OpaquePacketRouter(identity: Identity(), profile: profile, links: [first, second],
            decode: { _ in throw PechPechError.invalid("Unused.") }, forwarded: { $0 }, loadPending: { [] },
            persistRelay: { _ in }, removeRelay: { _ in }, receiveEndpoint: { _ in })
        defer { first.didStop = nil; node.stop() }
        first.didStop = { node.start() }
        node.start(); node.stop()
        XCTAssertTrue(first.running); XCTAssertTrue(second.running)
        XCTAssertEqual(first.startCalls, 2); XCTAssertEqual(second.startCalls, 2)
        XCTAssertEqual(first.stopCalls, 1); XCTAssertEqual(second.stopCalls, 1)
    }

    @MainActor func testStopDuringAdapterTeardownCancelsDeferredRestart() throws {
        let first = OpaqueTestLink(), second = OpaqueTestLink()
        let node = try OpaquePacketRouter(identity: Identity(), profile: profile, links: [first, second],
            decode: { _ in throw PechPechError.invalid("Unused.") }, forwarded: { $0 }, loadPending: { [] },
            persistRelay: { _ in }, removeRelay: { _ in }, receiveEndpoint: { _ in })
        defer { first.didStop = nil; node.stop() }
        first.didStop = { node.start(); node.stop() }
        node.start(); node.stop()
        XCTAssertFalse(first.running); XCTAssertFalse(second.running)
        XCTAssertEqual(first.startCalls, 1); XCTAssertEqual(second.startCalls, 1)
        XCTAssertEqual(first.stopCalls, 1); XCTAssertEqual(second.stopCalls, 1)
    }

    @MainActor func testDecoderCannotSubstituteOriginalPacketBytes() async throws {
        let origin = Identity(), endpoint = Identity(), la = OpaqueTestLink(), lb = OpaqueTestLink()
        let ha = OpaqueHost(), hb = OpaqueHost(), sender = try router(origin, la, ha)
        let receiver = try OpaquePacketRouter(identity: endpoint, profile: profile, links: [lb], decode: { bytes in
            let packet = try WireCoding.decode(TestOpaqueWire.self, from: bytes).descriptor()
            return try OpaquePacket(id: packet.id, destinationID: packet.destinationID, originID: packet.originID,
                hopsRemaining: packet.hopsRemaining, priority: packet.priority, expiresAt: packet.expiresAt,
                bytes: Data([0]), immutableHash: packet.immutableHash)
        }, forwarded: { $0 }, loadPending: { [] }, persistRelay: { _ in }, removeRelay: { _ in },
           receiveEndpoint: { try await hb.accept($0) })
        defer { sender.stop(); receiver.stop() }
        sender.start(); receiver.start(); la.connect(lb); await settle()
        try await sender.sendOrigin(packet(origin, endpoint)); await settle()
        XCTAssertEqual(hb.calls, 0); XCTAssertTrue(hb.inbox.isEmpty); XCTAssertTrue(lb.acknowledgments.isEmpty)
    }

    @MainActor func testOpaqueControlsCannotAuthenticateInGenericMeshProtocol() throws {
        let a = Identity(), b = Identity(), opaque = try packet(a, b), challenge = UUID()
        let hello = try SignedOpaqueHello(identity: a, profile: profile, challenge: challenge, routes: [a.publicIdentity.id: 0])
        XCTAssertNoThrow(try hello.validate(profile: profile))
        XCTAssertThrowsError(try WireCoding.decode(SignedHello.self, from: WireCoding.encode(hello)).validate())
        let ack = try SignedOpaqueAck(identity: b, profile: profile, packet: opaque, echo: challenge)
        XCTAssertNoThrow(try ack.validate(sender: b.publicIdentity, challenge: challenge, profile: profile))
        XCTAssertThrowsError(try WireCoding.decode(SignedRelayAck.self, from: WireCoding.encode(ack)).validate(sender: b.publicIdentity, challenge: challenge))
    }

    @MainActor func testRepeatedValidAckHasOnlyOneSuspendedRetirementCallback() async throws {
        let origin = Identity(), relay = Identity(), endpoint = Identity(), lr = OpaqueTestLink(), lb = OpaqueTestLink()
        let hr = OpaqueHost(), hb = OpaqueHost(), receiver = try router(endpoint, lb, hb)
        let original = try packet(origin, endpoint, hops: 7)
        hr.pending[original.id] = original
        var calls = 0
        var continuation: CheckedContinuation<Void, Never>?
        let middle = try OpaquePacketRouter(identity: relay, profile: profile, links: [lr],
            decode: { try WireCoding.decode(TestOpaqueWire.self, from: $0).descriptor() }, forwarded: { $0 },
            loadPending: { Array(hr.pending.values) }, persistRelay: { try hr.persist($0) }, removeRelay: { id in
                calls += 1
                await withCheckedContinuation { continuation = $0 }
                hr.pending.removeValue(forKey: id)
            }, receiveEndpoint: { try await hr.accept($0) })
        defer { middle.stop(); receiver.stop() }
        middle.start(); receiver.start(); lr.connect(lb); await settle()
        XCTAssertEqual(calls, 1)
        let ack = try XCTUnwrap(lb.acknowledgments.first)
        for _ in 0..<30 { lr.onMessage?(try WireCoding.encode(ack), endpoint.publicIdentity.id) }
        await settle(); XCTAssertEqual(calls, 1)
        let pending = try XCTUnwrap(continuation); continuation = nil; pending.resume()
        await settle(); XCTAssertTrue(hr.pending.isEmpty)
    }

    @MainActor func testDuplicateAdapterInstanceIsRejectedBeforeCallbacksAreOverwritten() throws {
        let identity = Identity(), link = OpaqueTestLink()
        XCTAssertThrowsError(try OpaquePacketRouter(identity: identity, profile: profile, links: [link, link],
            decode: { _ in throw PechPechError.invalid("Unused.") }, forwarded: { $0 }, loadPending: { [] },
            persistRelay: { _ in }, removeRelay: { _ in }, receiveEndpoint: { _ in }))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pechpech-duplicate-link-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MeshStore(url: directory.appendingPathComponent("mesh.sqlite"))
        XCTAssertThrowsError(try MeshNode(identity: identity, store: store, links: [link, link], authorize: { _, _ in false }))
        XCTAssertNil(link.onLinkReady)
        XCTAssertNil(link.onMessage)
    }

    func testIndependentOpaqueControlVectorMatchesCanonicalBytesAndSignatures() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "opaque-control-v1", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try WireCoding.decode([String: String].self, from: Data(contentsOf: url))
        let identity = try Identity(signingPrivateKey: Data(repeating: 0x11, count: 32),
                                    agreementPrivateKey: Data(repeating: 0x12, count: 32))
        let fixtureProfile = try XCTUnwrap(fixture["profile"])
        let challenge = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(fixture["challenge"])))
        let echo = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(fixture["echo"])))
        let routes = try WireCoding.decode([String: Int].self, from: Data(try XCTUnwrap(fixture["routesJSON"]).utf8))
        XCTAssertEqual(identity.publicIdentity.id, fixture["address"])
        XCTAssertEqual(String(decoding: try WireCoding.encode(identity.publicIdentity), as: UTF8.self), fixture["publicIdentityJSON"])
        for (prefix, helloEcho) in [("hello", Optional(echo)), ("helloWithoutEcho", nil)] {
            let hello = try WireCoding.decode(SignedOpaqueHello.self, from: Data(try XCTUnwrap(fixture[prefix + "JSON"]).utf8))
            XCTAssertNoThrow(try hello.validate(profile: fixtureProfile))
            XCTAssertEqual(String(decoding: try WireCoding.encode(hello.claims), as: UTF8.self), fixture[prefix + "ClaimsJSON"])
            XCTAssertEqual(String(decoding: try WireCoding.encode(hello), as: UTF8.self), fixture[prefix + "JSON"])
            XCTAssertEqual(hello.signature.base64EncodedString(), fixture[prefix + "SignatureBase64"])
            let generated = try SignedOpaqueHello(identity: identity, profile: fixtureProfile, challenge: challenge,
                                                  echo: helloEcho, routes: routes)
            XCTAssertEqual(generated.claims, hello.claims)
            // Signing implementations may randomize valid Ed25519 signatures;
            // interoperability requires identical signed bytes and verification.
            XCTAssertNoThrow(try generated.validate(profile: fixtureProfile))
        }
        let ack = try WireCoding.decode(SignedOpaqueAck.self, from: Data(try XCTUnwrap(fixture["ackJSON"]).utf8))
        XCTAssertNoThrow(try ack.validate(sender: identity.publicIdentity, challenge: echo, profile: fixtureProfile))
        XCTAssertEqual(String(decoding: try WireCoding.encode(ack.claims), as: UTF8.self), fixture["ackClaimsJSON"])
        XCTAssertEqual(String(decoding: try WireCoding.encode(ack), as: UTF8.self), fixture["ackJSON"])
        XCTAssertEqual(ack.signature.base64EncodedString(), fixture["ackSignatureBase64"])
        let descriptor = try OpaquePacket(id: XCTUnwrap(UUID(uuidString: try XCTUnwrap(fixture["packetID"]))),
            destinationID: String(repeating: "ab", count: 32), originID: identity.publicIdentity.id,
            hopsRemaining: 7, priority: 2, expiresAt: WireCoding.now + 60_000, bytes: Data([1]),
            immutableHash: XCTUnwrap(Data(base64Encoded: try XCTUnwrap(fixture["immutableHashBase64"]))))
        let generatedAck = try SignedOpaqueAck(identity: identity, profile: fixtureProfile, packet: descriptor, echo: echo)
        XCTAssertEqual(generatedAck.claims, ack.claims)
        XCTAssertNoThrow(try generatedAck.validate(sender: identity.publicIdentity, challenge: echo, profile: fixtureProfile))
    }
}
