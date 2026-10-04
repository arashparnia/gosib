import CryptoKit
import Foundation

public enum EndpointCrypto {
    public static let keyDerivationDomain = "PECHPECH-2-X25519-HKDF-SHA256-AES256GCM-Ed25519"
    private struct SignedBytes: Codable { let payload: Data; let signature: Data }

    public static func seal(_ envelope: EndpointEnvelope, from sender: Identity, to recipient: PublicIdentity,
                            priority: PacketPriority = .normal, lifetimeMilliseconds: Int64 = 60_000,
                            packetID: UUID = UUID(), now: Int64 = WireCoding.now) throws -> RelayPacket {
        guard (1...600_000).contains(lifetimeMilliseconds), now >= 0 else { throw PechPechError.invalid("Invalid packet lifetime.") }
        let expiry = now.addingReportingOverflow(lifetimeMilliseconds)
        guard !expiry.overflow else { throw PechPechError.invalid("Packet expiry overflow.") }
        try recipient.validate()
        if case .message(let message) = envelope {
            try message.validate()
            guard message.senderID == sender.publicIdentity.id, message.destinationID == recipient.id else {
                throw PechPechError.identityConflict
            }
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let header = PacketHeader(packetID: packetID, destinationID: recipient.id, sender: sender.publicIdentity,
                                  ephemeralKey: ephemeral.publicKey.rawRepresentation, priority: priority, expiresAt: expiry.partialValue)
        let aad = try WireCoding.encode(header)
        let bytes = try WireCoding.encode(envelope)
        let signed = SignedBytes(payload: bytes, signature: try sender.sign(aad + bytes))
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient.agreementKey))
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(keyDerivationDomain.utf8), sharedInfo: aad, outputByteCount: 32)
        let box = try AES.GCM.seal(try WireCoding.encode(signed), using: key, authenticating: aad)
        guard let combined = box.combined else { throw PechPechError.authenticationFailed }
        let packet = RelayPacket(header: header, encrypted: combined, hopsRemaining: header.hopLimit)
        try packet.validate(now: now)
        return packet
    }

    public static func open(_ packet: RelayPacket, for recipient: Identity,
                            now: Int64 = WireCoding.now) throws -> (envelope: EndpointEnvelope, sender: PublicIdentity) {
        try packet.validate(now: now)
        guard packet.destinationID == recipient.publicIdentity.id else { throw PechPechError.identityConflict }
        do {
            let aad = try WireCoding.encode(packet.header)
            let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: recipient.agreementPrivateKey)
            let secret = try privateKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: packet.header.ephemeralKey))
            let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(keyDerivationDomain.utf8), sharedInfo: aad, outputByteCount: 32)
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: packet.encrypted), using: key, authenticating: aad)
            let signed = try WireCoding.decode(SignedBytes.self, from: plain)
            let signer = try Curve25519.Signing.PublicKey(rawRepresentation: packet.header.sender.signingKey)
            guard signer.isValidSignature(signed.signature, for: aad + signed.payload) else { throw PechPechError.authenticationFailed }
            let envelope = try WireCoding.decode(EndpointEnvelope.self, from: signed.payload)
            if case .message(let message) = envelope {
                try message.validate()
                guard message.senderID == packet.originID, message.destinationID == packet.destinationID else {
                    throw PechPechError.authenticationFailed
                }
            }
            return (envelope, packet.header.sender)
        } catch { throw PechPechError.authenticationFailed }
    }
}
