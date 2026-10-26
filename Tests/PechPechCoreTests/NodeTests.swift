import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import PechPechCore

@MainActor private final class MemoryLink: PacketLink {
    var onState: ((String) -> Void)?
    var onPeers: (([LinkPeer]) -> Void)?
    var onMessage: ((Data, String) -> Void)?
    var onLinkReady: ((String) -> Void)?
    var onDisconnected: ((String) -> Void)?
    var onWorkAvailable: (() -> Void)?
    var name = ""
    var running = false
    var peers: [String: MemoryLink] = [:]
    var sent: [MeshFrame] = []
    var sendAttempts = 0
    var drop: ((MeshFrame, String) -> Bool)?
    var reject: ((MeshFrame, String) -> Bool)?
    var onStop: (() -> Void)?
    var stopCount = 0
    func start(nodeName: String) { name = nodeName; running = true; onState?("Started") }
    func stop() {
        stopCount += 1
        running = false
        for other in Array(peers.values) { disconnect(other) }
        onStop?()
    }
    func confirmPeer(_ peerID: String) {}
    func send(_ data: Data, to peerID: String, priority: Int) -> Bool {
        sendAttempts += 1
        guard running, let other = peers[peerID], other.running,
              let frame = try? WireCoding.decode(MeshFrame.self, from: data) else { return false }
        if reject?(frame, peerID) == true { return false }
        sent.append(frame)
        if drop?(frame, peerID) != true { other.onMessage?(data, name) }
        return true // Queue admission remains true even for a deliberately lost test packet.
    }
    func connect(_ other: MemoryLink) {
        peers[other.name] = other; other.peers[name] = self
        onLinkReady?(other.name); other.onLinkReady?(name)
    }
    func disconnect(_ other: MemoryLink) {
        peers.removeValue(forKey: other.name); other.peers.removeValue(forKey: name)
        onDisconnected?(other.name); other.onDisconnected?(name)
    }
    var packetCount: Int { sent.filter { if case .packet = $0 { return true }; return false }.count }
}

final class NodeTests: XCTestCase {
    private struct UnvalidatedSignedBytes: Codable { let payload: Data; let signature: Data }
    private var directories: [URL] = []
    override func tearDown() { directories.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
    private func url() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pechpech-node-test-\(UUID())")
        directories.append(folder); return folder.appendingPathComponent("node.sqlite")
    }
    @MainActor private func node(_ identity: Identity, _ link: MemoryLink, path: URL? = nil,
                                authorize: @escaping (Message, PublicIdentity) -> Bool = { _, _ in true }) throws -> MeshNode {
        try MeshNode(identity: identity, store: MeshStore(url: path ?? url()), links: [link], authorize: authorize)
    }
    private func forgedEnvelope(_ envelope: EndpointEnvelope, from sender: Identity, to recipient: PublicIdentity) throws -> RelayPacket {
        // Independent CryptoKit construction models a foreign implementation that bypasses
        // the reference seal API's semantic checks while producing valid authentication.
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let header = PacketHeader(packetID: UUID(), destinationID: recipient.id, sender: sender.publicIdentity,
                                  ephemeralKey: ephemeral.publicKey.rawRepresentation, priority: .normal, expiresAt: WireCoding.now + 60_000)
        let aad = try WireCoding.encode(header), payload = try WireCoding.encode(envelope)
        let signed = UnvalidatedSignedBytes(payload: payload, signature: try sender.sign(aad + payload))
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient.agreementKey))
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(EndpointCrypto.keyDerivationDomain.utf8), sharedInfo: aad, outputByteCount: 32)
        let box = try AES.GCM.seal(try WireCoding.encode(signed), using: key, authenticating: aad)
        return RelayPacket(header: header, encrypted: try XCTUnwrap(box.combined), hopsRemaining: 8)
    }

    @MainActor func testTwoHopDeliveryAndSeparateDurableRelayAcknowledgment() async throws {
        let a = Identity(), b = Identity(), r = Identity(), la = MemoryLink(), lb = MemoryLink(), lr = MemoryLink()
        let sender = try node(a, la), receiver = try node(b, lb), relay = try node(r, lr, authorize: { _, _ in false })
        defer { sender.stop(); receiver.stop(); relay.stop() }
        sender.start(); receiver.start(); relay.start(); la.connect(lr); lr.connect(lb)
        var received = 0, delivered = 0
        receiver.onMessage = { _ in received += 1 }; sender.onDelivery = { _, _ in delivered += 1 }
        let message = try sender.enqueue(to: b.publicIdentity, channel: "test", payload: Data("hello".utf8))
        for _ in 0..<3 { sender.tick(); relay.tick(); receiver.tick() }
        XCTAssertEqual(received, 1); XCTAssertEqual(delivered, 1)
        XCTAssertEqual(try receiver.store.inbox().first?.message, message)
        XCTAssertTrue(try sender.store.pending().isEmpty)
        XCTAssertTrue(try relay.store.inbox().isEmpty)
        XCTAssertTrue(try receiver.store.outgoingReceipts().isEmpty)
        XCTAssertTrue(lr.sent.contains { if case .stored = $0 { return true }; return false })
    }

    @MainActor func testLostEndpointReceiptLeavesPendingUntilAuthenticatedRetry() async throws {
        let a = Identity(), b = Identity(), la = MemoryLink(), lb = MemoryLink()
        let sender = try node(a, la), receiver = try node(b, lb)
        defer { sender.stop(); receiver.stop() }
        sender.start(); receiver.start(); la.connect(lb)
        lb.drop = { frame, _ in if case .packet(let p) = frame { return p.priority == .receipt }; return false }
        var received = 0, delivered = 0
        receiver.onMessage = { _ in received += 1 }; sender.onDelivery = { _, _ in delivered += 1 }
        let message = try sender.enqueue(to: b.publicIdentity, channel: "test", payload: Data([1]))
        XCTAssertEqual(try receiver.store.inbox().count, 1)
        XCTAssertEqual(try sender.store.pending().first?.message.id, message.id)
        XCTAssertEqual(delivered, 0)
        XCTAssertTrue(lb.sent.contains { if case .stored = $0 { return true }; return false })
        lb.drop = nil
        sender.tick(); receiver.tick()
        XCTAssertEqual(received, 1); XCTAssertEqual(delivered, 1)
        XCTAssertTrue(try sender.store.pending().isEmpty)
        XCTAssertTrue(try receiver.store.outgoingReceipts().isEmpty)
    }

    @MainActor func testReceiptReturnsViaNewRelayAfterOutboundChainDisappears() async throws {
        let a = Identity(), b = Identity(), r1 = Identity(), r2 = Identity()
        let la = MemoryLink(), lb = MemoryLink(), l1 = MemoryLink(), l2 = MemoryLink()
        let sender = try node(a, la), receiver = try node(b, lb)
        let first = try node(r1, l1, authorize: { _, _ in false }), alternate = try node(r2, l2, authorize: { _, _ in false })
        defer { sender.stop(); receiver.stop(); first.stop(); alternate.stop() }
        [sender, receiver, first, alternate].forEach { $0.start() }
        la.connect(l1); l1.connect(lb)
        lb.drop = { frame, destination in
            if case .packet(let p) = frame { return destination == r1.publicIdentity.id && p.priority == .receipt }
            return false
        }
        let original = try sender.enqueue(to: b.publicIdentity, channel: "test", payload: Data([2]))
        XCTAssertEqual(try receiver.store.inbox().count, 1)
        XCTAssertEqual(try sender.store.pending().count, 1)
        la.disconnect(l1); lb.disconnect(l1)
        la.connect(l2); l2.connect(lb)
        for _ in 0..<3 { receiver.tick(); alternate.tick(); sender.tick() }
        XCTAssertTrue(try sender.store.pending().isEmpty)
        XCTAssertEqual(try sender.store.receipt(messageID: original.id)?.bodyHash, try original.bodyHash)
        XCTAssertEqual(try receiver.store.inbox().count, 1)
        XCTAssertTrue(try alternate.store.inbox().isEmpty)
    }

    @MainActor func testStopAndRestartDoNotResumeOldIntentUntilExplicitResume() async throws {
        let a = Identity(), b = Identity(), la = MemoryLink(), lb = MemoryLink(), path = url()
        let sender = try node(a, la, path: path), receiver = try node(b, lb)
        defer { sender.stop(); receiver.stop() }
        sender.start()
        let original = try sender.enqueue(to: b.publicIdentity, channel: "test", payload: Data([3]))
        sender.stop(); receiver.start()
        let restartedLink = MemoryLink(), restarted = try node(a, restartedLink, path: path)
        defer { restarted.stop() }
        restarted.start(); restartedLink.connect(lb); restarted.tick(); receiver.tick()
        XCTAssertEqual(restartedLink.packetCount, 0)
        XCTAssertTrue(try receiver.store.inbox().isEmpty)
        XCTAssertEqual(try restarted.store.pending().first?.message, original)
        try restarted.resume(original.id)
        XCTAssertEqual(try receiver.store.inbox().first?.message, original)
        XCTAssertTrue(try restarted.store.pending().isEmpty)
    }

    @MainActor func testStopDuringAdapterStartDoesNotStartLaterAdapters() async throws {
        let identity = Identity(), first = MemoryLink(), second = MemoryLink()
        let mesh = try MeshNode(identity: identity, store: MeshStore(url: url()), links: [first, second], authorize: { _, _ in false })
        defer { mesh.stop() }
        mesh.onEvent = { event in
            if case .linkState("Started") = event { mesh.stop() }
        }
        mesh.start()
        XCTAssertFalse(first.running)
        XCTAssertFalse(second.running)
        XCTAssertEqual(second.name, "")
        mesh.onEvent = nil
        mesh.start()
        XCTAssertTrue(first.running)
        XCTAssertTrue(second.running)
    }

    @MainActor func testEnqueueKnownIDReusesSavedSnapshotAndDoesNotResendDeliveredMessage() async throws {
        let a = Identity(), b = Identity(), la = MemoryLink(), lb = MemoryLink()
        let sender = try node(a, la), receiver = try node(b, lb)
        defer { sender.stop(); receiver.stop() }
        let original = try Message(senderID: a.publicIdentity.id, destinationID: b.publicIdentity.id,
                                   channel: "saved", payload: Data([3]), createdAt: 1)
        try sender.store.queue(original, recipient: b.publicIdentity)
        sender.start(); receiver.start(); la.connect(lb)
        let retried = try sender.enqueue(to: b.publicIdentity, channel: original.channel, payload: original.payload, id: original.id)
        XCTAssertEqual(retried, original)
        XCTAssertEqual(try sender.store.outgoing(messageID: original.id)?.message, original)
        XCTAssertEqual(try receiver.store.inbox().first?.message, original)
        XCTAssertNotNil(try sender.store.receipt(messageID: original.id))
        let before = la.packetCount
        XCTAssertEqual(try sender.enqueue(to: b.publicIdentity, channel: original.channel, payload: original.payload, id: original.id), original)
        XCTAssertEqual(la.packetCount, before)
        XCTAssertThrowsError(try sender.enqueue(to: b.publicIdentity, channel: original.channel, payload: Data([4]), id: original.id))
        XCTAssertThrowsError(try sender.enqueue(to: b.publicIdentity, channel: "changed", payload: original.payload, id: original.id))
        XCTAssertThrowsError(try sender.enqueue(to: b.publicIdentity, channel: original.channel, payload: original.payload, id: original.id, priority: .bulk))
    }

    @MainActor func testRetryRejectsCanonicallyEquivalentButDifferentChannelBytes() async throws {
        let a = Identity(), b = Identity(), link = MemoryLink(), sender = try node(a, link)
        let original = try sender.enqueue(to: b.publicIdentity, channel: "caf\u{00e9}", payload: Data([1]))
        XCTAssertThrowsError(try sender.enqueue(to: b.publicIdentity, channel: "cafe\u{0301}",
                                               payload: original.payload, id: original.id)) { error in
            XCTAssertEqual(error as? PechPechError, .messageConflict)
        }
        XCTAssertEqual(try sender.store.pending().first?.message, original)
    }

    @MainActor func testStopCallbackIsIdempotent() async throws {
        let link = MemoryLink(), mesh = try node(Identity(), link)
        defer { mesh.onPeers = nil; mesh.stop() }
        var callbacks = 0
        mesh.onPeers = { _ in
            callbacks += 1
            // Bound recursion in the regression so a broken implementation fails cleanly.
            if callbacks < 5 { mesh.stop() }
        }
        mesh.start(); mesh.stop(); mesh.stop()
        XCTAssertEqual(callbacks, 1)
        XCTAssertFalse(link.running)
    }

    @MainActor func testRestartDuringForwardDoesNotSendOldOriginToNewSession() async throws {
        let a = Identity(), b = Identity(), c = Identity(), destination = Identity()
        let la = MemoryLink(), lb = MemoryLink(), lc = MemoryLink()
        let sender = try node(a, la), first = try node(b, lb), second = try node(c, lc)
        defer { la.drop = nil; sender.stop(); first.stop(); second.stop() }
        sender.start(); first.start(); second.start(); la.connect(lb); la.connect(lc)
        var restarted = false
        la.drop = { frame, _ in
            guard case .packet = frame, !restarted else { return false }
            restarted = true
            sender.stop(); sender.start(); la.connect(lb); la.connect(lc)
            return true
        }
        let original = try sender.enqueue(to: destination.publicIdentity, channel: "test", payload: Data([1]))
        XCTAssertTrue(restarted)
        XCTAssertEqual(la.packetCount, 1)
        XCTAssertTrue(try first.store.relayPackets().isEmpty)
        XCTAssertTrue(try second.store.relayPackets().isEmpty)
        XCTAssertEqual(try sender.store.pending().first?.message, original)
        sender.tick()
        XCTAssertEqual(la.packetCount, 1)
    }

    @MainActor func testPauseDuringSendStopsFurtherOriginAttempts() async throws {
        let a = Identity(), b = Identity(), c = Identity(), destination = Identity()
        let la = MemoryLink(), lb = MemoryLink(), lc = MemoryLink()
        let sender = try node(a, la), first = try node(b, lb), second = try node(c, lc)
        defer { la.drop = nil; sender.stop(); first.stop(); second.stop() }
        sender.start(); first.start(); second.start(); la.connect(lb); la.connect(lc)
        let messageID = UUID()
        la.drop = { frame, _ in
            guard case .packet = frame else { return false }
            sender.pause(messageID)
            return true
        }
        let original = try sender.enqueue(to: destination.publicIdentity, channel: "test", payload: Data([1]), id: messageID)
        XCTAssertEqual(la.packetCount, 1)
        sender.tick()
        XCTAssertEqual(la.packetCount, 1)
        XCTAssertEqual(try sender.store.pending().first?.message, original)
    }

    @MainActor func testRestartRequestedDuringStopWaitsForAllAdaptersToClose() async throws {
        let first = MemoryLink(), second = MemoryLink()
        let mesh = try MeshNode(identity: Identity(), store: MeshStore(url: url()), links: [first, second], authorize: { _, _ in false })
        defer { first.onStop = nil; mesh.stop() }
        var requested = false
        first.onStop = {
            guard !requested else { return }
            requested = true; mesh.start()
            XCTAssertFalse(first.running)
        }
        mesh.start(); mesh.stop()
        XCTAssertTrue(requested)
        XCTAssertEqual(first.stopCount, 1); XCTAssertEqual(second.stopCount, 1)
        XCTAssertTrue(first.running); XCTAssertTrue(second.running)
    }

    @MainActor func testLaterStopCancelsRestartRequestedDuringAdapterTeardown() async throws {
        let first = MemoryLink(), second = MemoryLink()
        let mesh = try MeshNode(identity: Identity(), store: MeshStore(url: url()), links: [first, second], authorize: { _, _ in false })
        defer { first.onStop = nil; second.onStop = nil; mesh.stop() }
        first.onStop = { mesh.start() }
        second.onStop = { mesh.stop() }
        mesh.start(); mesh.stop()
        XCTAssertEqual(first.stopCount, 1); XCTAssertEqual(second.stopCount, 1)
        XCTAssertFalse(first.running); XCTAssertFalse(second.running)
    }

    @MainActor func testRestartDuringInboxCallbackDoesNotSendObsoleteHopAck() async throws {
        let a = Identity(), b = Identity(), la = MemoryLink(), lb = MemoryLink()
        let sender = try node(a, la), receiver = try node(b, lb)
        defer { receiver.onMessage = nil; sender.stop(); receiver.stop() }
        sender.start(); receiver.start(); la.connect(lb)
        var framesAtRestart: Int?
        receiver.onMessage = { _ in
            receiver.stop(); receiver.start(); lb.connect(la)
            framesAtRestart = lb.sent.count
        }
        let original = try sender.enqueue(to: b.publicIdentity, channel: "test", payload: Data([1]))
        let boundary = try XCTUnwrap(framesAtRestart)
        XCTAssertFalse(lb.sent.dropFirst(boundary).contains { if case .stored = $0 { return true }; return false })
        XCTAssertEqual(try receiver.store.inbox().first?.message, original)
        for _ in 0..<3 { sender.tick(); receiver.tick() }
        XCTAssertTrue(try sender.store.pending().isEmpty)
    }

    @MainActor func testCustomAdapterCannotAllocateUnboundedUnauthenticatedHandles() async throws {
        let identity = Identity(), other = Identity(), link = MemoryLink(), remote = MemoryLink()
        let mesh = try node(identity, link), neighbor = try node(other, remote)
        defer { mesh.stop(); neighbor.stop() }
        mesh.start(); neighbor.start()
        for index in 0..<128 { link.onLinkReady?("untrusted-\(index)") }
        XCTAssertEqual(link.sendAttempts, 4)
        link.connect(remote)
        XCTAssertTrue(mesh.connectedIdentities.isEmpty)
        link.onDisconnected?("untrusted-0")
        link.connect(remote)
        XCTAssertEqual(mesh.connectedIdentities, [other.publicIdentity])
    }

    @MainActor func testAuthorizationRejectsAuthenticatedSenderWithoutFalseReceipt() async throws {
        let a = Identity(), b = Identity(), la = MemoryLink(), lb = MemoryLink()
        let sender = try node(a, la), receiver = try node(b, lb, authorize: { _, _ in false })
        defer { sender.stop(); receiver.stop() }
        sender.start(); receiver.start(); la.connect(lb)
        let original = try sender.enqueue(to: b.publicIdentity, channel: "test", payload: Data([4]))
        sender.tick(); receiver.tick()
        XCTAssertTrue(try receiver.store.inbox().isEmpty)
        XCTAssertTrue(try receiver.store.outgoingReceipts().isEmpty)
        XCTAssertEqual(try sender.store.pending().first?.message, original)
        XCTAssertNil(try sender.store.receipt(messageID: original.id))
    }

    @MainActor func testAuthenticatedEnvelopeCannotSpoofMessageSenderOrDestination() async throws {
        let a = Identity(), b = Identity(), stranger = Identity(), la = MemoryLink(), lb = MemoryLink()
        let sender = try node(a, la), receiver = try node(b, lb)
        defer { sender.stop(); receiver.stop() }
        sender.start(); receiver.start(); la.connect(lb)
        let spoofedMessages = [
            try Message(senderID: stranger.publicIdentity.id, destinationID: b.publicIdentity.id, channel: "test", payload: Data([1])),
            try Message(senderID: a.publicIdentity.id, destinationID: stranger.publicIdentity.id, channel: "test", payload: Data([2]))
        ]
        for message in spoofedMessages {
            XCTAssertThrowsError(try EndpointCrypto.seal(.message(message), from: a, to: b.publicIdentity))
            let packet = try forgedEnvelope(.message(message), from: a, to: b.publicIdentity)
            XCTAssertThrowsError(try EndpointCrypto.open(packet, for: b))
            XCTAssertTrue(la.send(try WireCoding.encode(MeshFrame.packet(packet)), to: b.publicIdentity.id, priority: 1))
        }
        XCTAssertTrue(try receiver.store.inbox().isEmpty)
        XCTAssertTrue(try receiver.store.outgoingReceipts().isEmpty)
        XCTAssertThrowsError(try sender.enqueue(to: a.publicIdentity, channel: "self", payload: Data([3])))
        XCTAssertTrue(try sender.store.pending().isEmpty)
    }

    @MainActor func testDroppedOrRejectedFinalHelloEchoRecoversWithoutReconnect() async throws {
        for rejectAdmission in [false, true] {
            let a = Identity(), b = Identity(), la = MemoryLink(), lb = MemoryLink()
            let sender = try node(a, la), receiver = try node(b, lb)
            defer { sender.stop(); receiver.stop() }
            var lost = false
            let loseFinalEcho: (MeshFrame, String) -> Bool = { frame, _ in
                if case .hello(let hello) = frame, hello.claims.echo != nil, !lost {
                    lost = true; return true
                }
                return false
            }
            if rejectAdmission { la.reject = loseFinalEcho } else { la.drop = loseFinalEcho }
            sender.start(); receiver.start(); la.connect(lb)
            XCTAssertTrue(lost)
            let message = try sender.enqueue(to: b.publicIdentity, channel: "test", payload: Data([10]))
            for _ in 0..<6 { sender.tick(); receiver.tick() }
            XCTAssertEqual(sender.connectedIdentities, [b.publicIdentity])
            XCTAssertEqual(receiver.connectedIdentities, [a.publicIdentity])
            XCTAssertEqual(try receiver.store.inbox().first?.message, message)
            XCTAssertTrue(try sender.store.pending().isEmpty)
        }
    }

    @MainActor func testOutboxStorageFailurePreventsAnyPacketTransmission() async throws {
        let a = Identity(), b = Identity(), la = MemoryLink(), lb = MemoryLink(), path = url()
        let sender = try node(a, la, path: path), receiver = try node(b, lb)
        defer { sender.stop(); receiver.stop() }
        sender.start(); receiver.start(); la.connect(lb)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER fail_queue BEFORE INSERT ON pechpech_outbox BEGIN SELECT RAISE(ABORT,'synthetic'); END;", nil, nil, nil), SQLITE_OK)
        let before = la.packetCount
        XCTAssertThrowsError(try sender.enqueue(to: b.publicIdentity, channel: "test", payload: Data([5])))
        XCTAssertEqual(la.packetCount, before)
        XCTAssertTrue(try receiver.store.inbox().isEmpty)
        XCTAssertTrue(try sender.store.pending().isEmpty)
    }

    @MainActor func testLinkIdentityCannotChangeUntilDisconnect() async throws {
        let a = Identity(), b = Identity(), attacker = Identity(), la = MemoryLink(), lb = MemoryLink()
        let sender = try node(a, la), receiver = try node(b, lb)
        defer { sender.stop(); receiver.stop() }
        sender.start(); receiver.start(); la.connect(lb)
        XCTAssertEqual(sender.connectedIdentities, [b.publicIdentity])
        let malicious = try SignedHello(identity: attacker, challenge: UUID())
        la.onMessage?(try WireCoding.encode(MeshFrame.hello(malicious)), b.publicIdentity.id)
        XCTAssertEqual(sender.connectedIdentities, [b.publicIdentity])
        let original = try sender.enqueue(to: b.publicIdentity, channel: "test", payload: Data([6]))
        XCTAssertEqual(try receiver.store.inbox().first?.message, original)
        XCTAssertTrue(try sender.store.pending().isEmpty)
    }

    @MainActor func testNoRouteRemainsDurableAndPauseStopsNewAttempts() async throws {
        let a = Identity(), b = Identity(), la = MemoryLink(), sender = try node(a, la)
        defer { sender.stop() }
        var events: [NodeEvent] = []
        sender.onEvent = { events.append($0) }; sender.start()
        let original = try sender.enqueue(to: b.publicIdentity, channel: "test", payload: Data([7]))
        XCTAssertTrue(events.contains(.waitingForRoute(original.id)))
        XCTAssertEqual(try sender.store.pending().first?.message, original)
        XCTAssertEqual(la.packetCount, 0)
        sender.pause(original.id); events.removeAll(); sender.tick()
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(try sender.store.pending().count, 1)
    }

    @MainActor func testWritableEventRetriesRefusedOriginWithoutTimerTick() async throws {
        let a = Identity(), b = Identity(), la = MemoryLink(), lb = MemoryLink()
        let sender = try node(a, la), receiver = try node(b, lb)
        defer { sender.stop(); receiver.stop() }
        sender.setRetryScheduling(.eventDriven); receiver.setRetryScheduling(.eventDriven)
        sender.start(); receiver.start(); la.connect(lb)
        la.reject = { frame, _ in if case .packet = frame { return true }; return false }
        let original = try sender.enqueue(to: b.publicIdentity, channel: "wake", payload: Data([1]))
        XCTAssertTrue(try receiver.store.inbox().isEmpty)
        la.reject = nil
        for _ in 0..<8 { la.onWorkAvailable?() }
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(try receiver.store.inbox().first?.message, original)
        XCTAssertTrue(try sender.store.pending().isEmpty)
        XCTAssertEqual(la.packetCount, 2, "One origin packet plus its independent endpoint receipt-stored acknowledgment")
    }

    @MainActor func testEventDrivenSchedulingKeepsLinksWithoutPeriodicRetriesAndPreservesStopIntent() async throws {
        let a = Identity(), b = Identity(), la = MemoryLink(), lb = MemoryLink()
        let sender = try node(a, la), receiver = try node(b, lb)
        defer { sender.stop(); receiver.stop() }
        sender.setRetryScheduling(.eventDriven); receiver.setRetryScheduling(.eventDriven)
        sender.start(); receiver.start(); la.connect(lb)
        la.drop = { frame, _ in if case .packet = frame { return true }; return false }
        let original = try sender.enqueue(to: b.publicIdentity, channel: "background", payload: Data([1]))
        let before = la.sent.count
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertEqual(la.sent.count, before, "Event-driven mode must not rely on a running one-second task")
        XCTAssertTrue(la.running); XCTAssertTrue(lb.running)
        la.drop = nil
        sender.setRetryScheduling(.periodic)
        XCTAssertTrue(try sender.store.pending().isEmpty)
        XCTAssertEqual(try receiver.store.inbox().first?.message, original)
        sender.stop(); sender.setRetryScheduling(.eventDriven); sender.start(); la.connect(lb)
        XCTAssertEqual(sender.retryScheduling, .eventDriven)
        let pending = try sender.enqueue(to: b.publicIdentity, channel: "paused", payload: Data([2]), startSending: false)
        la.onWorkAvailable?()
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(try sender.store.pending().map(\.message), [pending])
        XCTAssertEqual(try receiver.store.inbox().count, 1)
    }

    @MainActor func testWritableEventDoesNotRepeatAdmittedOriginOrResumeAfterStop() async throws {
        let a = Identity(), b = Identity(), la = MemoryLink(), lb = MemoryLink()
        let sender = try node(a, la), receiver = try node(b, lb)
        defer { sender.stop(); receiver.stop() }
        sender.start(); receiver.start(); la.connect(lb)
        la.drop = { frame, _ in if case .packet = frame { return true }; return false }
        let original = try sender.enqueue(to: b.publicIdentity, channel: "wake", payload: Data([1]))
        let admitted = la.packetCount
        for _ in 0..<8 { la.onWorkAvailable?() }
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(la.packetCount, admitted)
        // Work already scheduled before stop must not leak into the replacement session.
        la.onWorkAvailable?(); sender.stop(); sender.start(); la.connect(lb)
        la.drop = nil; la.onWorkAvailable?()
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(la.packetCount, admitted)
        XCTAssertTrue(try receiver.store.inbox().isEmpty)
        XCTAssertEqual(try sender.store.pending().first?.message, original)
    }

    @MainActor func testSingleFreedQueueSlotServicesPayloadBeforeRedundantHello() async throws {
        let a = Identity(), b = Identity(), la = MemoryLink(), lb = MemoryLink()
        let sender = try node(a, la), receiver = try node(b, lb)
        defer { sender.stop(); receiver.stop() }
        sender.setRetryScheduling(.eventDriven); receiver.setRetryScheduling(.eventDriven)
        sender.start(); receiver.start(); la.connect(lb)
        var full = true
        la.reject = { _, _ in
            guard !full else { return true }
            full = true
            return false
        }
        let original = try sender.enqueue(to: b.publicIdentity, channel: "capacity", payload: Data([1]))
        XCTAssertTrue(try receiver.store.inbox().isEmpty)
        full = false
        la.onWorkAvailable?()
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(try receiver.store.inbox().first?.message, original)
        XCTAssertTrue(try sender.store.pending().isEmpty)
        XCTAssertEqual(la.packetCount, 1)
    }

    @MainActor func testStaleOrWrongPacketRelayAckCannotRetireSpoolOrOwnedMessage() async throws {
        let a = Identity(), relayID = Identity(), origin = Identity(), unreachable = Identity()
        let la = MemoryLink(), lr = MemoryLink(), sender = try node(a, la), relay = try node(relayID, lr, authorize: { _, _ in false })
        defer { sender.stop(); relay.stop() }
        sender.start(); relay.start(); la.connect(lr)
        la.drop = { frame, _ in if case .stored = frame { return true }; return false }
        let owned = try relay.enqueue(to: unreachable.publicIdentity, channel: "owned", payload: Data([8]), startSending: false)
        let foreignMessage = try Message(senderID: origin.publicIdentity.id, destinationID: unreachable.publicIdentity.id,
                                         channel: "foreign", payload: Data([9]))
        let foreign = try EndpointCrypto.seal(.message(foreignMessage), from: origin, to: unreachable.publicIdentity)
        try relay.store.enqueueRelay(foreign)
        relay.tick()
        XCTAssertEqual(try relay.store.relayPackets().map(\.id), [foreign.id])
        let challenge = try XCTUnwrap(lr.sent.compactMap { frame -> UUID? in
            if case .hello(let hello) = frame { return hello.claims.challenge }; return nil
        }.last)
        let stale = try SignedRelayAck(identity: a, packet: foreign, echo: UUID())
        lr.onMessage?(try WireCoding.encode(MeshFrame.stored(stale)), a.publicIdentity.id)
        XCTAssertEqual(try relay.store.relayPackets().count, 1)
        var badBytes = foreign.encrypted; badBytes[badBytes.startIndex] ^= 1
        let different = RelayPacket(header: foreign.header, encrypted: badBytes, hopsRemaining: foreign.hopsRemaining)
        let mismatch = try SignedRelayAck(identity: a, packet: different, echo: challenge)
        lr.onMessage?(try WireCoding.encode(MeshFrame.stored(mismatch)), a.publicIdentity.id)
        XCTAssertEqual(try relay.store.relayPackets().count, 1)
        let valid = try SignedRelayAck(identity: a, packet: foreign, echo: challenge)
        lr.onMessage?(try WireCoding.encode(MeshFrame.stored(valid)), a.publicIdentity.id)
        XCTAssertTrue(try relay.store.relayPackets().isEmpty)
        XCTAssertEqual(try relay.store.pending().first?.message, owned)
        XCTAssertNil(try relay.store.receipt(messageID: owned.id))
    }
}
