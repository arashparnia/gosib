import Foundation
import GosibCore
import GosibApple

@main struct GosibDemo {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gosib-example-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sender = Identity(), relay = Identity(), receiver = Identity()
        let network = InMemoryNetwork()
        let senderLink = network.makeLink(id: "sender"), relayLink = network.makeLink(id: "relay"), receiverLink = network.makeLink(id: "receiver")
        let senderStore = try MeshStore(url: directory.appendingPathComponent("sender.sqlite"))
        let relayStore = try MeshStore(url: directory.appendingPathComponent("relay.sqlite"))
        let receiverStore = try MeshStore(url: directory.appendingPathComponent("receiver.sqlite"))
        let a = try MeshNode(identity: sender, store: senderStore, links: [senderLink], authorize: { _, _ in false })
        let r = try MeshNode(identity: relay, store: relayStore, links: [relayLink], authorize: { _, _ in false })
        let b = try MeshNode(identity: receiver, store: receiverStore, links: [receiverLink]) { message, identity in
            identity == sender.publicIdentity && message.channel == "example.notes"
        }
        var deliveries = 0, arrivals = 0
        var diagnostics: [String] = []
        var originalFrame: Data?
        network.shouldDeliver = { bytes, source, destination in
            if source == "sender", destination == "relay", originalFrame == nil,
               let frame = try? WireCoding.decode(MeshFrame.self, from: bytes),
               case .packet(let packet) = frame, packet.destinationID == receiver.publicIdentity.id {
                originalFrame = bytes
            }
            return true
        }
        b.onMessage = { received in
            arrivals += 1
            print("Receiver persisted: \(String(decoding: received.message.payload, as: UTF8.self))")
        }
        a.onDelivery = { _, receipt in
            deliveries += 1
            print("Sender verified durable endpoint receipt for \(receipt.messageID)")
        }
        for node in [a, r, b] {
            node.onEvent = { event in
                if case .error(let text) = event { diagnostics.append(text); print("Diagnostic: \(text)") }
            }
            node.start()
        }
        defer { a.stop(); r.stop(); b.stop() }
        network.connect("sender", "relay"); network.connect("relay", "receiver")
        let message = try a.enqueue(to: receiver.publicIdentity, channel: "example.notes", payload: Data("Station A is ready.".utf8))
        // Simulate duplication of the actual sent frame, while its next-hop
        // acknowledgment is still tracked by the sender's current attempt.
        guard let originalFrame else { throw GosibError.invalid("No message frame was transmitted.") }
        _ = senderLink.send(originalFrame, to: "relay", priority: PacketPriority.urgent.rawValue)
        for node in [a, r, b] { node.tick() }
        guard deliveries == 1, arrivals == 1, diagnostics.isEmpty,
              try senderStore.pending().isEmpty, try receiverStore.inbox().count == 1,
              try senderStore.receipt(messageID: message.id) != nil else {
            throw GosibError.invalid("The in-memory delivery example did not complete.")
        }
        print("PASS: two-hop encrypted delivery, durable receipt, duplicate suppression; no radio or physical latency claim.")
    }
}
