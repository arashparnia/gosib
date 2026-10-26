import Foundation
import PechPechCore
import PechPechApple

// Built by CI as an independent package consumer. This does not start radios or
// access the Keychain: native construction, callbacks and delivery APIs compile.
@MainActor
func assembleHost(identity: Identity, databaseURL: URL,
                  recipient: PublicIdentity, permittedSenderIDs: Set<String>) throws -> MeshNode {
    let node = try MeshNode(
        identity: identity,
        store: MeshStore(url: databaseURL),
        links: [BLEPacketLink(), TCPPacketLink(includePeerToPeer: true)],
        authorize: { message, sender in
            permittedSenderIDs.contains(sender.id) && message.channel == "example.v1"
        }
    )
    node.onMessage = { received in _ = received.message.id }
    node.onDelivery = { message, receipt in
        precondition(message.id == receipt.messageID)
    }
    node.onEvent = { _ in }
    let message = try node.enqueue(to: recipient, channel: "example.v1",
                                   payload: Data("Synthetic consumer".utf8), startSending: false)
    node.pause(message.id)
    try node.resume(message.id)
    return node
}

print("PechPech products imported successfully; host example compiled without starting radios.")

@MainActor
func assembleOpaqueHost(
    identity: Identity,
    decode: @escaping (Data) throws -> OpaquePacket,
    forwarded: @escaping (OpaquePacket) throws -> OpaquePacket,
    loadPending: @escaping () async throws -> [OpaquePacket],
    persistRelay: @escaping (OpaquePacket) async throws -> Void,
    removeRelay: @escaping (UUID) async throws -> Void,
    receiveEndpoint: @escaping (OpaquePacket) async throws -> Void
) throws -> OpaquePacketRouter {
    try OpaquePacketRouter(
        identity: identity, profile: "com.example.protocol.v1",
        links: [BLEPacketLink(), TCPPacketLink(includePeerToPeer: true)],
        decode: decode, forwarded: forwarded, loadPending: loadPending,
        persistRelay: persistRelay, removeRelay: removeRelay,
        receiveEndpoint: receiveEndpoint
    )
}

// The host recreates this only when its own persisted session policy permits it.
// Construction does not start radios, restore keys or resume saved originals.
@MainActor
func assembleBackgroundHost(identity: Identity, databaseURL: URL,
                            permittedSenderIDs: Set<String>) throws -> MeshNode {
    let restoration = try BLERestorationConfiguration(
        centralIdentifier: "com.example.consumer.pechpech.central",
        peripheralIdentifier: "com.example.consumer.pechpech.peripheral")
    let node = try MeshNode(identity: identity, store: MeshStore(url: databaseURL),
        links: [BLEPacketLink(restoration: restoration)],
        authorize: { message, sender in
            permittedSenderIDs.contains(sender.id) && message.channel == "example.v1"
        })
    node.setRetryScheduling(.eventDriven)
    return node
}
