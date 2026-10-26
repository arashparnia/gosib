import Foundation
import XCTest
import PechPechCore

private struct RoutingFaultEdge: Hashable {
    let first: String
    let second: String
    init(_ a: String, _ b: String) { first = min(a, b); second = max(a, b) }
}

/// A fixed seed changes scheduling, never cryptographic keys or protocol bytes.
@MainActor private final class RoutingFaultSchedule {
    enum Phase: Equatable { case receiptsBlocked, faults, reliable }
    private struct HeldFrame { let bytes: Data; let source: String; let destination: String }
    static let maximumHeldFrames = 128
    var phase = Phase.receiptsBlocked
    let senderID: String
    private var state: UInt64
    private var held: [HeldFrame] = []
    private(set) var losses = 0
    private(set) var duplicateCopies = 0
    private(set) var reorderedDeliveries = 0
    private(set) var blockedReceipts = 0
    private(set) var hopAcknowledgments = 0
    private(set) var peakHeldFrames = 0
    var isEmpty: Bool { held.isEmpty }

    init(seed: UInt64, senderID: String) { state = seed; self.senderID = senderID }

    func next(_ upperBound: Int) -> Int {
        precondition(upperBound > 0)
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return Int(value % UInt64(upperBound))
    }

    func shouldDeliver(_ bytes: Data, source: String, destination: String) -> Bool {
        guard let frame = try? WireCoding.decode(MeshFrame.self, from: bytes) else { return true }
        switch frame {
        case .hello:
            // Keep discovery/authentication deterministic; faults below affect data and hop ACKs.
            return true
        case .stored:
            hopAcknowledgments += 1
            if phase == .faults, next(6) == 0 { losses += 1; return false }
            return true
        case .packet(let packet):
            if phase == .receiptsBlocked, packet.destinationID == senderID, packet.priority == .receipt {
                blockedReceipts += 1
                return false
            }
            guard phase == .faults else { return true }
            let action = next(5)
            if action == 0 { losses += 1; return false }
            let pending = HeldFrame(bytes: bytes, source: source, destination: destination)
            append(pending)
            if action == 1, append(pending) { duplicateCopies += 1 }
            return false // The adapter still reports successful local queue admission.
        }
    }

    @discardableResult private func append(_ frame: HeldFrame) -> Bool {
        guard held.count < Self.maximumHeldFrames else { losses += 1; return false }
        held.append(frame)
        peakHeldFrames = max(peakHeldFrames, held.count)
        return true
    }

    func deliver(upTo limit: Int, links: [String: InMemoryPacketLink], edges: Set<RoutingFaultEdge>) {
        for _ in 0..<limit {
            guard !held.isEmpty else { return }
            let index = next(held.count)
            if index > 0 { reorderedDeliveries += 1 }
            let frame = held.remove(at: index)
            guard edges.contains(RoutingFaultEdge(frame.source, frame.destination)),
                  links[frame.source]?.isRunning == true, links[frame.destination]?.isRunning == true else {
                losses += 1
                continue
            }
            links[frame.destination]?.onMessage?(frame.bytes, frame.source)
        }
    }
}

final class RoutingFaultTests: XCTestCase {
    @MainActor func testSeededLossDuplicationReorderingAndRouteChangesPreserveDurableDelivery() async throws {
        let seeds: [UInt8] = [1, 7, 23, 101]
        for seed in seeds { try run(seed: seed) }
    }

    private func messageID(seed: UInt8, index: Int) -> UUID {
        UUID(uuid: (0x50, 0x50, seed, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, UInt8(index)))
    }

    @MainActor private func run(seed: UInt8) throws {
        let context = "fault seed \(seed)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pechpech-routing-fault-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let senderIdentity = Identity(), receiverIdentity = Identity(), firstIdentity = Identity(), alternateIdentity = Identity()
        let network = InMemoryNetwork()
        let labels = ["sender", "first", "alternate", "receiver"]
        let links = Dictionary(uniqueKeysWithValues: labels.map { ($0, network.makeLink(id: $0)) })
        let stores = try Dictionary(uniqueKeysWithValues: labels.map {
            ($0, try MeshStore(url: directory.appendingPathComponent("\($0).sqlite")))
        })
        let senderStore = try XCTUnwrap(stores["sender"]), receiverStore = try XCTUnwrap(stores["receiver"])
        let sender = try MeshNode(identity: senderIdentity, store: senderStore, links: [try XCTUnwrap(links["sender"])],
                                  authorize: { _, _ in false })
        let first = try MeshNode(identity: firstIdentity, store: XCTUnwrap(stores["first"]),
                                 links: [XCTUnwrap(links["first"])], authorize: { _, _ in false })
        let alternate = try MeshNode(identity: alternateIdentity, store: XCTUnwrap(stores["alternate"]),
                                     links: [XCTUnwrap(links["alternate"])], authorize: { _, _ in false })
        let receiver = try MeshNode(identity: receiverIdentity, store: receiverStore, links: [XCTUnwrap(links["receiver"])]) {
            message, identity in identity == senderIdentity.publicIdentity && message.channel == "faults.v1"
        }
        let nodes = [sender, first, alternate, receiver]
        defer { network.shouldDeliver = nil; nodes.forEach { $0.stop() } }
        let schedule = RoutingFaultSchedule(seed: UInt64(seed), senderID: senderIdentity.publicIdentity.id)
        network.shouldDeliver = { schedule.shouldDeliver($0, source: $1, destination: $2) }
        var edges = Set<RoutingFaultEdge>()
        func connect(_ a: String, _ b: String) {
            if edges.insert(RoutingFaultEdge(a, b)).inserted { network.connect(a, b) }
        }
        func disconnect(_ a: String, _ b: String) {
            if edges.remove(RoutingFaultEdge(a, b)) != nil { network.disconnect(a, b) }
        }
        var arrivals: [UUID: Int] = [:], deliveries: [UUID: Int] = [:]
        receiver.onMessage = { received in
            arrivals[received.message.id, default: 0] += 1
            XCTAssertEqual(try? receiverStore.received(messageID: received.message.id)?.message, received.message, context)
            XCTAssertEqual(try? senderStore.outgoing(messageID: received.message.id)?.message, received.message,
                           "\(context): the original must be saved before a receiver callback")
        }
        sender.onDelivery = { message, receipt in
            deliveries[message.id, default: 0] += 1
            XCTAssertEqual(try? senderStore.receipt(messageID: message.id), receipt,
                           "\(context): completion requires a durably saved endpoint receipt")
            XCTAssertEqual(try? receiverStore.received(messageID: message.id)?.message, message,
                           "\(context): completion requires the exact durable recipient inbox result")
            XCTAssertEqual(receipt.receiverID, receiverIdentity.publicIdentity.id, context)
            XCTAssertEqual(receipt.senderID, senderIdentity.publicIdentity.id, context)
            XCTAssertEqual(receipt.bodyHash, try? message.bodyHash, context)
        }
        nodes.forEach { $0.start() }
        connect("sender", "first"); connect("first", "receiver")
        var originals: [Message] = []
        for index in 0..<8 {
            if index == 2 {
                // Two inbox results already exist, but hop ACKs cannot resolve their originals.
                XCTAssertEqual(try receiverStore.inbox().count, 2, context)
                XCTAssertEqual(try senderStore.pending().count, 2, context)
                XCTAssertTrue(deliveries.isEmpty, context)
                XCTAssertGreaterThan(schedule.blockedReceipts, 0, context)
                XCTAssertGreaterThan(schedule.hopAcknowledgments, 0, context)
                schedule.phase = .faults
                connect("sender", "alternate"); connect("alternate", "receiver")
            }
            var payload = Data([seed, UInt8(index), 0, 255])
            payload.append(Data("message \(index): caf\u{00E9}/\n".utf8))
            originals.append(try sender.enqueue(to: receiverIdentity.publicIdentity, channel: "faults.v1", payload: payload,
                id: messageID(seed: seed, index: index), priority: index.isMultiple(of: 3) ? .bulk : .urgent))
        }
        for step in 0..<16 {
            switch step {
            case 3: disconnect("first", "receiver")
            case 5: disconnect("sender", "first")
            case 7: connect("sender", "first")
            case 9: connect("first", "receiver")
            case 11: disconnect("sender", "alternate")
            case 13: connect("sender", "alternate")
            default: break
            }
            var order = Array(nodes.indices)
            for index in stride(from: order.count - 1, through: 1, by: -1) {
                order.swapAt(index, schedule.next(index + 1))
            }
            for index in order { nodes[index].tick() }
            schedule.deliver(upTo: 3 + schedule.next(5), links: links, edges: edges)
            try assertDurableState(originals: originals, sender: senderStore, receiver: receiverStore,
                                   arrivals: arrivals, deliveries: deliveries, context: context)
        }
        XCTAssertGreaterThan(schedule.losses, 0, context)
        XCTAssertGreaterThan(schedule.duplicateCopies, 0, context)
        XCTAssertGreaterThan(schedule.reorderedDeliveries, 0, context)
        XCTAssertLessThanOrEqual(schedule.peakHeldFrames, RoutingFaultSchedule.maximumHeldFrames, context)

        // Remove the initial outbound chain. Fair retries and returning receipts use the alternate relay.
        schedule.phase = .reliable
        disconnect("sender", "first"); disconnect("first", "receiver")
        connect("sender", "alternate"); connect("alternate", "receiver")
        for _ in 0..<12 {
            nodes.forEach { $0.tick() }
            schedule.deliver(upTo: RoutingFaultSchedule.maximumHeldFrames, links: links, edges: edges)
            if try senderStore.pending().isEmpty, schedule.isEmpty { break }
        }
        try assertDurableState(originals: originals, sender: senderStore, receiver: receiverStore,
                               arrivals: arrivals, deliveries: deliveries, context: context)
        XCTAssertTrue(try senderStore.pending().isEmpty, context)
        XCTAssertEqual(Set(try receiverStore.inbox().map { $0.message.id }), Set(originals.map(\.id)), context)
        for original in originals {
            XCTAssertEqual(arrivals[original.id], 1, context)
            XCTAssertEqual(deliveries[original.id], 1, context)
        }
        XCTAssertTrue(try XCTUnwrap(stores["first"]).inbox().isEmpty, context)
        XCTAssertTrue(try XCTUnwrap(stores["alternate"]).inbox().isEmpty, context)
        nodes.forEach { $0.stop() }
        let reopenedSender = try MeshStore(url: directory.appendingPathComponent("sender.sqlite"))
        let reopenedReceiver = try MeshStore(url: directory.appendingPathComponent("receiver.sqlite"))
        try assertDurableState(originals: originals, sender: reopenedSender, receiver: reopenedReceiver,
                               arrivals: arrivals, deliveries: deliveries, context: "\(context), reopened stores")
    }

    private func assertDurableState(originals: [Message], sender: MeshStore, receiver: MeshStore,
                                    arrivals: [UUID: Int], deliveries: [UUID: Int], context: String) throws {
        let inbox = try receiver.inbox()
        XCTAssertEqual(Set(inbox.map { $0.message.id }).count, inbox.count, context)
        XCTAssertTrue(Set(inbox.map { $0.message.id }).isSubset(of: Set(originals.map(\.id))), context)
        var unresolved = Set<UUID>()
        for original in originals {
            let saved = try XCTUnwrap(sender.outgoing(messageID: original.id), context)
            XCTAssertEqual(try WireCoding.encode(saved.message), try WireCoding.encode(original), context)
            if let received = try receiver.received(messageID: original.id) {
                XCTAssertEqual(try WireCoding.encode(received.message), try WireCoding.encode(original), context)
            }
            if let receipt = try sender.receipt(messageID: original.id) {
                let received = try XCTUnwrap(receiver.received(messageID: original.id), context)
                XCTAssertEqual(receipt, received.receipt, context)
                XCTAssertEqual(receipt.bodyHash, try original.bodyHash, context)
                XCTAssertEqual(receipt.receiverID, original.destinationID, context)
                XCTAssertEqual(receipt.senderID, original.senderID, context)
            } else { unresolved.insert(original.id) }
            XCTAssertLessThanOrEqual(arrivals[original.id, default: 0], 1, context)
            XCTAssertLessThanOrEqual(deliveries[original.id, default: 0], 1, context)
        }
        XCTAssertEqual(Set(try sender.pending().map { $0.message.id }), unresolved, context)
    }
}
