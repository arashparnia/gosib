import CryptoKit
import Foundation
import XCTest
@testable import PechPechCore

final class CryptoAndModelTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000
    // These obvious repeated-byte keys are synthetic test inputs, never operational identities.
    private func identity(_ byte: UInt8) throws -> Identity {
        try Identity(signingPrivateKey: Data(repeating: byte, count: 32), agreementPrivateKey: Data(repeating: byte &+ 1, count: 32))
    }
    private func message(_ sender: Identity, _ receiver: Identity, payload: Data = Data("hello / café\n".utf8)) throws -> Message {
        try Message(id: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!,
                    senderID: sender.publicIdentity.id, destinationID: receiver.publicIdentity.id,
                    channel: "test/chat", payload: payload, createdAt: now)
    }
    private func edit(_ packet: RelayPacket, header changes: [String: Any]) throws -> RelayPacket {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: WireCoding.encode(packet)) as? [String: Any])
        var header = try XCTUnwrap(object["header"] as? [String: Any])
        for (key, value) in changes { header[key] = value }
        object["header"] = header
        return try WireCoding.decode(RelayPacket.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func withProtocol<T: Codable, C: Codable>(_ signed: T, claimsType: C.Type,
                                                     protocolName: String, signer: Identity) throws -> T {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: WireCoding.encode(signed)) as? [String: Any])
        var claimsObject = try XCTUnwrap(object["claims"] as? [String: Any])
        claimsObject["protocolName"] = protocolName
        let claims = try WireCoding.decode(claimsType, from: JSONSerialization.data(withJSONObject: claimsObject))
        object["claims"] = claimsObject
        object["signature"] = try signer.sign(WireCoding.encode(claims)).base64EncodedString()
        return try WireCoding.decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testEndpointRoundTripAndFreshRandomness() throws {
        let sender = try identity(1), receiver = try identity(3), stranger = try identity(5)
        let input = EndpointEnvelope.message(try message(sender, receiver))
        let packet = try EndpointCrypto.seal(input, from: sender, to: receiver.publicIdentity, priority: .urgent, now: now)
        let opened = try EndpointCrypto.open(packet, for: receiver, now: now)
        XCTAssertEqual(opened.envelope, input)
        XCTAssertEqual(opened.sender, sender.publicIdentity)
        XCTAssertThrowsError(try EndpointCrypto.open(packet, for: stranger, now: now))
        let second = try EndpointCrypto.seal(input, from: sender, to: receiver.publicIdentity, priority: .urgent, now: now)
        XCTAssertNotEqual(packet.id, second.id)
        XCTAssertNotEqual(packet.header.ephemeralKey, second.header.ephemeralKey)
        XCTAssertNotEqual(packet.encrypted, second.encrypted)
    }

    func testAllImmutableHeaderFieldsAreAuthenticated() throws {
        let sender = try identity(1), receiver = try identity(3), stranger = try identity(5)
        let packet = try EndpointCrypto.seal(.message(message(sender, receiver)), from: sender, to: receiver.publicIdentity, now: now)
        let strangerObject = try JSONSerialization.jsonObject(with: WireCoding.encode(stranger.publicIdentity))
        let mutations: [[String: Any]] = [
            ["packetID": "FFEEDDCC-BBAA-9988-7766-554433221100"],
            ["expiresAt": now + 59_000], ["priority": PacketPriority.receipt.rawValue],
            ["hopLimit": 7], ["sender": strangerObject],
            ["ephemeralKey": stranger.publicIdentity.agreementKey.base64EncodedString()],
            ["destinationID": stranger.publicIdentity.id], ["version": 1], ["protocolName": "foreign"]
        ]
        for changes in mutations {
            let changed = try edit(packet, header: changes)
            XCTAssertThrowsError(try EndpointCrypto.open(changed, for: receiver, now: now), "Accepted tampered header: \(changes.keys.sorted())")
        }
        var altered = packet.encrypted
        altered[altered.startIndex + altered.count / 2] ^= 1
        XCTAssertThrowsError(try EndpointCrypto.open(RelayPacket(header: packet.header, encrypted: altered, hopsRemaining: packet.hopsRemaining), for: receiver, now: now))
        XCTAssertThrowsError(try EndpointCrypto.open(RelayPacket(header: packet.header, encrypted: Data(packet.encrypted.prefix(28)), hopsRemaining: packet.hopsRemaining), for: receiver, now: now))
    }

    func testHopBudgetCanDecreaseWithoutChangingEndpointAuthentication() throws {
        let sender = try identity(1), receiver = try identity(3)
        let original = try EndpointCrypto.seal(.message(message(sender, receiver)), from: sender, to: receiver.publicIdentity, now: now)
        var packet = original
        for _ in 0..<8 { packet = try XCTUnwrap(packet.forwarded()) }
        XCTAssertEqual(packet.hopsRemaining, 0)
        XCTAssertNil(packet.forwarded())
        XCTAssertEqual(packet.header, original.header)
        XCTAssertEqual(packet.encrypted, original.encrypted)
        XCTAssertEqual(try EndpointCrypto.open(packet, for: receiver, now: now).envelope, try EndpointCrypto.open(original, for: receiver, now: now).envelope)
        packet.hopsRemaining = 9
        XCTAssertThrowsError(try packet.validate(now: now))
        packet.hopsRemaining = -1
        XCTAssertThrowsError(try packet.validate(now: now))
    }

    func testPreviousWireVersionAndForeignNamespaceCannotOpenOrEnterRelaySpool() throws {
        let sender = try identity(1), receiver = try identity(3), relay = try identity(5)
        let packet = try EndpointCrypto.seal(.message(message(sender, receiver)), from: sender, to: receiver.publicIdentity, now: now)
        XCTAssertEqual(packet.header.protocolName, "pechpech")
        XCTAssertEqual(packet.header.version, 2)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pechpech-version-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MeshStore(url: directory.appendingPathComponent("mesh.sqlite"))
        try store.bindIdentity(relay.publicIdentity)
        let incompatibleHeaders: [[String: Any]] = [
            ["version": 1], ["protocolName": "foreign", "version": 1],
            ["protocolName": "foreign", "version": 2]
        ]
        for changes in incompatibleHeaders {
            let incompatible = try edit(packet, header: changes)
            XCTAssertThrowsError(try incompatible.validate(now: now))
            XCTAssertThrowsError(try EndpointCrypto.open(incompatible, for: receiver, now: now))
            XCTAssertThrowsError(try store.enqueueRelay(incompatible, now: now))
        }
        XCTAssertTrue(try store.relayPackets(now: now).isEmpty)
        XCTAssertTrue(try store.enqueueRelay(packet, now: now))
    }

    func testValidlySignedPreviousAndForeignControlNamespacesAreRejected() throws {
        let sender = try identity(1), receiver = try identity(3), challenge = UUID()
        let hello = try SignedHello(identity: sender, challenge: challenge)
        XCTAssertEqual(hello.claims.protocolName, "pechpech-link-2")
        XCTAssertNoThrow(try hello.validate())
        let packet = try EndpointCrypto.seal(.message(message(sender, receiver)), from: sender, to: receiver.publicIdentity, now: now)
        let ack = try SignedRelayAck(identity: sender, packet: packet, echo: challenge)
        XCTAssertEqual(ack.claims.protocolName, "pechpech-relay-ack-2")
        XCTAssertNoThrow(try ack.validate(sender: sender.publicIdentity, challenge: challenge))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: sender.publicIdentity.signingKey)
        for protocolName in ["pechpech-link-1", "foreign-link-1"] {
            let incompatible = try withProtocol(hello, claimsType: HelloClaims.self, protocolName: protocolName, signer: sender)
            XCTAssertTrue(publicKey.isValidSignature(incompatible.signature, for: try WireCoding.encode(incompatible.claims)))
            XCTAssertThrowsError(try incompatible.validate())
        }
        for protocolName in ["pechpech-relay-ack-1", "foreign-relay-ack-1"] {
            let incompatible = try withProtocol(ack, claimsType: RelayAckClaims.self, protocolName: protocolName, signer: sender)
            XCTAssertTrue(publicKey.isValidSignature(incompatible.signature, for: try WireCoding.encode(incompatible.claims)))
            XCTAssertThrowsError(try incompatible.validate(sender: sender.publicIdentity, challenge: challenge))
        }
    }

    func testHostileTimestampExtremesAndLifetimesNeverOverflow() throws {
        let sender = try identity(1), receiver = try identity(3)
        let packet = try EndpointCrypto.seal(.message(message(sender, receiver)), from: sender, to: receiver.publicIdentity, now: now)
        XCTAssertThrowsError(try EndpointCrypto.seal(.message(message(sender, receiver)), from: sender, to: receiver.publicIdentity, now: Int64.max))
        XCTAssertThrowsError(try EndpointCrypto.seal(.message(message(sender, receiver)), from: sender, to: receiver.publicIdentity, now: -1))
        for lifetime: Int64 in [0, -1, 600_001, Int64.max, Int64.min] {
            XCTAssertThrowsError(try EndpointCrypto.seal(.message(message(sender, receiver)), from: sender, to: receiver.publicIdentity, lifetimeMilliseconds: lifetime, now: now))
        }
        for expiry in [Int64.min, now, now - 1, now + 600_001, Int64.max] {
            let changed = try edit(packet, header: ["expiresAt": expiry])
            XCTAssertThrowsError(try changed.validate(now: now))
        }
        XCTAssertThrowsError(try edit(packet, header: ["expiresAt": Int64.max]).validate(now: Int64.min))
        XCTAssertNoThrow(try packet.validate(now: now + 59_999))
        XCTAssertThrowsError(try packet.validate(now: now + 60_000))
    }

    func testIdentityAndAddressBounds() throws {
        XCTAssertThrowsError(try PublicIdentity(signingKey: Data(repeating: 0, count: 31), agreementKey: Data(repeating: 0, count: 32)))
        XCTAssertThrowsError(try Identity(signingPrivateKey: Data(), agreementPrivateKey: Data(repeating: 1, count: 32)))
        let valid = try identity(1).publicIdentity.id
        XCTAssertTrue(WireCoding.isAddress(valid))
        for address in [valid.uppercased(), String(repeating: "g", count: 64), String(repeating: "é", count: 64), String(valid.dropLast()), valid + "0"] {
            XCTAssertFalse(WireCoding.isAddress(address))
        }
    }

    func testMessageBoundsAndExactBinarySnapshot() throws {
        let sender = try identity(1), receiver = try identity(3)
        let payload = Data((0..<Message.maximumPayloadBytes).map { UInt8($0 % 251) })
        let original = try message(sender, receiver, payload: payload)
        XCTAssertEqual(try WireCoding.decode(Message.self, from: WireCoding.encode(original)), original)
        let packet = try EndpointCrypto.seal(.message(original), from: sender, to: receiver.publicIdentity, now: now)
        XCTAssertLessThanOrEqual(try WireCoding.encode(packet).count, RelayPacket.maximumBytes)
        XCTAssertEqual(try EndpointCrypto.open(packet, for: receiver, now: now).envelope, .message(original))
        XCTAssertThrowsError(try message(sender, receiver, payload: Data(repeating: 1, count: Message.maximumPayloadBytes + 1)))
        XCTAssertThrowsError(try Message(senderID: sender.publicIdentity.id, destinationID: receiver.publicIdentity.id, channel: "", payload: Data(), createdAt: now))
        XCTAssertThrowsError(try Message(senderID: sender.publicIdentity.id, destinationID: receiver.publicIdentity.id, channel: String(repeating: "é", count: 65), payload: Data(), createdAt: now))
        XCTAssertThrowsError(try Message(senderID: sender.publicIdentity.id, destinationID: receiver.publicIdentity.id, channel: "test", payload: Data(), createdAt: -1))
        XCTAssertThrowsError(try WireCoding.decode(EndpointEnvelope.self, from: Data("{\"kind\":\"unrecognized\"}".utf8)))
    }

    func testMessageEqualityPreservesUnicodeEncodingAndAuthenticatedHash() throws {
        let sender = try identity(1), receiver = try identity(3)
        let composed = "caf\u{00e9}", decomposed = "cafe\u{0301}"
        XCTAssertEqual(composed, decomposed, "Swift's linguistic equality must not define immutable message bytes")
        let original = try Message(senderID: sender.publicIdentity.id, destinationID: receiver.publicIdentity.id,
                                   channel: composed, payload: Data([1]), createdAt: now)
        let changed = try Message(id: original.id, senderID: original.senderID, destinationID: original.destinationID,
                                  channel: decomposed, payload: original.payload, createdAt: original.createdAt)
        XCTAssertNotEqual(original, changed)
        XCTAssertNotEqual(try original.bodyHash, try changed.bodyHash)
        for message in [original, changed] {
            let decoded = try WireCoding.decode(Message.self, from: WireCoding.encode(message))
            XCTAssertEqual(decoded, message)
            XCTAssertTrue(decoded.channel.utf8.elementsEqual(message.channel.utf8))
            let packet = try EndpointCrypto.seal(.message(message), from: sender, to: receiver.publicIdentity, now: now)
            XCTAssertEqual(try EndpointCrypto.open(packet, for: receiver, now: now).envelope, .message(message))
        }
    }

    func testCanonicalInteropVector() throws {
        let vectorURL = try XCTUnwrap(Bundle.module.url(forResource: "canonical-v2", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: vectorURL)) as? [String: String])
        let sender = try identity(1), receiver = try identity(3)
        let message = try self.message(sender, receiver)
        XCTAssertEqual(sender.publicIdentity.id, fixture["senderAddress"])
        XCTAssertEqual(receiver.publicIdentity.id, fixture["receiverAddress"])
        XCTAssertEqual(String(decoding: try WireCoding.encode(message), as: UTF8.self), fixture["messageJSON"])
        XCTAssertEqual(try message.bodyHash.base64EncodedString(), fixture["messageHashBase64"])
        let packet = try WireCoding.decode(RelayPacket.self, from: Data(try XCTUnwrap(fixture["packetJSON"]).utf8))
        XCTAssertEqual(packet.header.protocolName, "pechpech")
        XCTAssertEqual(packet.header.version, 2)
        XCTAssertEqual(String(decoding: try WireCoding.encode(packet.header), as: UTF8.self), fixture["headerJSON"])
        XCTAssertEqual(try EndpointCrypto.open(packet, for: receiver, now: now).envelope, .message(message))
        let signatureInput = Data(try XCTUnwrap(fixture["signatureInputUTF8"]).utf8)
        XCTAssertEqual(signatureInput, try WireCoding.encode(packet.header) + WireCoding.encode(EndpointEnvelope.message(message)))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: sender.publicIdentity.signingKey)
        let signature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(fixture["signatureBase64"])))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: signatureInput))
        XCTAssertTrue(publicKey.isValidSignature(try sender.sign(signatureInput), for: signatureInput))
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: receiver.publicIdentity.agreementKey))
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(EndpointCrypto.keyDerivationDomain.utf8),
                                               sharedInfo: try WireCoding.encode(packet.header), outputByteCount: 32)
        XCTAssertEqual(key.withUnsafeBytes { Data($0).base64EncodedString() }, fixture["derivedKeyBase64"])
        XCTAssertEqual(EndpointCrypto.keyDerivationDomain, fixture["keyDerivationDomain"])
        XCTAssertEqual(EndpointCrypto.keyDerivationDomain, "PECHPECH-2-X25519-HKDF-SHA256-AES256GCM-Ed25519")
    }

    func testUnicodeImmutableMessageInteropVector() throws {
        let vectorURL = try XCTUnwrap(Bundle.module.url(forResource: "unicode-v2", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: vectorURL)) as? [String: String])
        let sender = try identity(1), receiver = try identity(3)
        XCTAssertEqual(sender.publicIdentity.id, fixture["senderAddress"])
        XCTAssertEqual(receiver.publicIdentity.id, fixture["receiverAddress"])
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(fixture["messageID"])))
        for (name, channel) in [("composed", "caf\u{00e9}"), ("decomposed", "cafe\u{0301}")] {
            let message = try Message(id: id, senderID: sender.publicIdentity.id, destinationID: receiver.publicIdentity.id,
                                      channel: channel, payload: Data([1]), createdAt: now)
            XCTAssertEqual(channel.utf8.map { String(format: "%02x", $0) }.joined(), fixture[name + "ChannelUTF8Hex"])
            // Compare bytes: normal Swift String equality folds Unicode normalization.
            XCTAssertEqual(try WireCoding.encode(message), Data(try XCTUnwrap(fixture[name + "MessageJSON"]).utf8))
            XCTAssertEqual(try message.bodyHash.base64EncodedString(), fixture[name + "MessageHashBase64"])
        }
        XCTAssertNotEqual(fixture["composedMessageHashBase64"], fixture["decomposedMessageHashBase64"])
    }
}
