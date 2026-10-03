import CryptoKit
import Foundation

public struct HelloClaims: Codable, Equatable, Sendable {
    public let protocolName: String
    public let identity: PublicIdentity
    public let challenge: UUID
    public let echo: UUID?
    public init(identity: PublicIdentity, challenge: UUID, echo: UUID? = nil) {
        protocolName = "gosib-link-1"; self.identity = identity; self.challenge = challenge; self.echo = echo
    }
}

public struct SignedHello: Codable, Equatable, Sendable {
    public let claims: HelloClaims
    public let signature: Data
    public init(identity: Identity, challenge: UUID, echo: UUID? = nil) throws {
        claims = HelloClaims(identity: identity.publicIdentity, challenge: challenge, echo: echo)
        signature = try identity.sign(WireCoding.encode(claims))
    }
    public func validate() throws {
        try claims.identity.validate()
        guard claims.protocolName == "gosib-link-1", signature.count == 64,
              try Curve25519.Signing.PublicKey(rawRepresentation: claims.identity.signingKey)
                .isValidSignature(signature, for: WireCoding.encode(claims)) else { throw GosibError.authenticationFailed }
    }
}

public struct RelayAckClaims: Codable, Equatable, Sendable {
    public let protocolName: String
    public let senderID: String
    public let packetID: UUID
    public let packetHash: Data
    public let echo: UUID
    public init(senderID: String, packetID: UUID, packetHash: Data, echo: UUID) {
        protocolName = "gosib-relay-ack-1"; self.senderID = senderID; self.packetID = packetID
        self.packetHash = packetHash; self.echo = echo
    }
}

public struct SignedRelayAck: Codable, Equatable, Sendable {
    public let claims: RelayAckClaims
    public let signature: Data
    public init(identity: Identity, packet: RelayPacket, echo: UUID) throws {
        claims = RelayAckClaims(senderID: identity.publicIdentity.id, packetID: packet.id,
                                packetHash: try Self.immutableHash(packet), echo: echo)
        signature = try identity.sign(WireCoding.encode(claims))
    }
    /// Remaining hops is mutable, so ACK binds the immutable header and ciphertext.
    public static func immutableHash(_ packet: RelayPacket) throws -> Data {
        WireCoding.hash(try WireCoding.encode(packet.header) + packet.encrypted)
    }
    public func validate(sender: PublicIdentity, challenge: UUID) throws {
        try sender.validate()
        guard claims.protocolName == "gosib-relay-ack-1", claims.senderID == sender.id,
              claims.echo == challenge, claims.packetHash.count == 32, signature.count == 64,
              try Curve25519.Signing.PublicKey(rawRepresentation: sender.signingKey)
                .isValidSignature(signature, for: WireCoding.encode(claims)) else { throw GosibError.authenticationFailed }
    }
}

public enum MeshFrame: Codable, Equatable, Sendable {
    case hello(SignedHello), packet(RelayPacket), stored(SignedRelayAck)
    private enum Keys: String, CodingKey { case kind, hello, packet, ack }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "hello": self = .hello(try c.decode(SignedHello.self, forKey: .hello))
        case "packet": self = .packet(try c.decode(RelayPacket.self, forKey: .packet))
        case "stored": self = .stored(try c.decode(SignedRelayAck.self, forKey: .ack))
        default: throw GosibError.invalid("Unknown Gosib link frame.")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .hello(let h): try c.encode("hello", forKey: .kind); try c.encode(h, forKey: .hello)
        case .packet(let p): try c.encode("packet", forKey: .kind); try c.encode(p, forKey: .packet)
        case .stored(let a): try c.encode("stored", forKey: .kind); try c.encode(a, forKey: .ack)
        }
    }
}
