import CryptoKit
import Foundation

public enum PechPechError: Error, Equatable, LocalizedError {
    case invalid(String), authenticationFailed, expired, identityConflict, messageConflict
    case spoolFull, storage(String), frameTooLarge(Int)
    public var errorDescription: String? {
        switch self {
        case .invalid(let s): return s
        case .authenticationFailed: return "Packet authentication failed."
        case .expired: return "Packet expired."
        case .identityConflict: return "The identity does not match the pinned endpoint."
        case .messageConflict: return "An existing message ID has different immutable contents."
        case .spoolFull: return "The bounded relay spool is full."
        case .storage(let s): return "Durable storage failed: \(s)"
        case .frameTooLarge(let n): return "Frame is too large (\(n) bytes)."
        }
    }
}

public enum WireCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from bytes: Data) throws -> T {
        try JSONDecoder().decode(type, from: bytes)
    }
    public static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
    public static func hash(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }
    public static func isAddress(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct PublicIdentity: Codable, Equatable, Sendable, Identifiable {
    public let signingKey: Data
    public let agreementKey: Data
    public var id: String { WireCoding.hash(signingKey + agreementKey).map { String(format: "%02x", $0) }.joined() }
    public init(signingKey: Data, agreementKey: Data) throws {
        self.signingKey = signingKey; self.agreementKey = agreementKey; try validate()
    }
    public func validate() throws {
        guard signingKey.count == 32, agreementKey.count == 32 else { throw PechPechError.authenticationFailed }
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: signingKey)
        _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreementKey)
    }
}

/// Store private representations in the host application's secure storage, never in packets.
public struct Identity: Sendable {
    public let signingPrivateKey: Data
    public let agreementPrivateKey: Data
    public var publicIdentity: PublicIdentity {
        try! PublicIdentity(signingKey: Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivateKey).publicKey.rawRepresentation,
                            agreementKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreementPrivateKey).publicKey.rawRepresentation)
    }
    public init() {
        signingPrivateKey = Curve25519.Signing.PrivateKey().rawRepresentation
        agreementPrivateKey = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
    }
    public init(signingPrivateKey: Data, agreementPrivateKey: Data) throws {
        _ = try Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivateKey)
        _ = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreementPrivateKey)
        self.signingPrivateKey = signingPrivateKey; self.agreementPrivateKey = agreementPrivateKey
    }
    public func sign(_ bytes: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivateKey).signature(for: bytes)
    }
}

public enum PacketPriority: Int, Codable, Sendable, CaseIterable {
    case bulk = 0, normal = 1, urgent = 2, receipt = 3
}

public struct Message: Codable, Equatable, Sendable, Identifiable {
    public static let maximumPayloadBytes = 4_096
    public let id: UUID
    public let senderID: String
    public let destinationID: String
    public let channel: String
    public let payload: Data
    public let createdAt: Int64
    public init(id: UUID = UUID(), senderID: String, destinationID: String, channel: String,
                payload: Data, createdAt: Int64 = WireCoding.now) throws {
        self.id = id; self.senderID = senderID; self.destinationID = destinationID
        self.channel = channel; self.payload = payload; self.createdAt = createdAt; try validate()
    }
    public func validate() throws {
        guard WireCoding.isAddress(senderID), WireCoding.isAddress(destinationID),
              !channel.isEmpty, channel.utf8.count <= 128,
              payload.count <= Self.maximumPayloadBytes, createdAt >= 0 else {
            throw PechPechError.invalid("Invalid message address, channel, time or payload size.")
        }
    }
    public var bodyHash: Data { get throws { WireCoding.hash(try WireCoding.encode(self)) } }
}

/// This acknowledges durable inbox bytes, never an application/business side effect.
public struct DeliveryReceipt: Codable, Equatable, Sendable {
    public let messageID: UUID
    public let bodyHash: Data
    public let senderID: String
    public let receiverID: String
    public let acceptedAt: Int64
    public init(messageID: UUID, bodyHash: Data, senderID: String, receiverID: String, acceptedAt: Int64) {
        self.messageID = messageID; self.bodyHash = bodyHash; self.senderID = senderID
        self.receiverID = receiverID; self.acceptedAt = acceptedAt
    }
}

public enum EndpointEnvelope: Codable, Equatable, Sendable {
    case message(Message)
    case receipt(DeliveryReceipt)
    case receiptStored(messageID: UUID, bodyHash: Data)
    private enum Keys: String, CodingKey { case kind, message, receipt, messageID, bodyHash }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "message": self = .message(try c.decode(Message.self, forKey: .message))
        case "receipt": self = .receipt(try c.decode(DeliveryReceipt.self, forKey: .receipt))
        case "receiptStored": self = .receiptStored(messageID: try c.decode(UUID.self, forKey: .messageID), bodyHash: try c.decode(Data.self, forKey: .bodyHash))
        default: throw PechPechError.invalid("Unknown PechPech endpoint kind.")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .message(let m): try c.encode("message", forKey: .kind); try c.encode(m, forKey: .message)
        case .receipt(let r): try c.encode("receipt", forKey: .kind); try c.encode(r, forKey: .receipt)
        case .receiptStored(let id, let hash):
            try c.encode("receiptStored", forKey: .kind); try c.encode(id, forKey: .messageID); try c.encode(hash, forKey: .bodyHash)
        }
    }
}

public struct PacketHeader: Codable, Equatable, Sendable {
    public let protocolName: String
    public let version: Int
    public let packetID: UUID
    public let destinationID: String
    public let sender: PublicIdentity
    public let ephemeralKey: Data
    public let priority: PacketPriority
    public let expiresAt: Int64
    public let hopLimit: Int
    public init(packetID: UUID, destinationID: String, sender: PublicIdentity, ephemeralKey: Data,
                priority: PacketPriority, expiresAt: Int64, hopLimit: Int = 8,
                protocolName: String = "pechpech", version: Int = 2) {
        self.protocolName = protocolName; self.version = version; self.packetID = packetID
        self.destinationID = destinationID; self.sender = sender; self.ephemeralKey = ephemeralKey
        self.priority = priority; self.expiresAt = expiresAt; self.hopLimit = hopLimit
    }
}

/// Relays see routing metadata and ciphertext, never application plaintext.
public struct RelayPacket: Codable, Equatable, Sendable, Identifiable {
    public static let maximumBytes = 16_384
    public let header: PacketHeader
    public let encrypted: Data
    public var hopsRemaining: Int
    public var id: UUID { header.packetID }
    public var originID: String { header.sender.id }
    public var destinationID: String { header.destinationID }
    public var priority: PacketPriority { header.priority }
    public var expiresAt: Int64 { header.expiresAt }
    public init(header: PacketHeader, encrypted: Data, hopsRemaining: Int) {
        self.header = header; self.encrypted = encrypted; self.hopsRemaining = hopsRemaining
    }
    public func validate(now: Int64 = WireCoding.now) throws {
        try header.sender.validate()
        guard header.protocolName == "pechpech", header.version == 2,
              WireCoding.isAddress(destinationID), header.ephemeralKey.count == 32,
              (1...8).contains(header.hopLimit), (0...header.hopLimit).contains(hopsRemaining),
              encrypted.count >= 28, encrypted.count <= Self.maximumBytes else {
            throw PechPechError.invalid("Invalid PechPech relay metadata.")
        }
        // Subtraction is checked so hostile Int64 extremes cannot crash the decoder.
        let lifetime = expiresAt.subtractingReportingOverflow(now)
        guard !lifetime.overflow, lifetime.partialValue > 0, lifetime.partialValue <= 600_000 else { throw PechPechError.expired }
        guard try WireCoding.encode(self).count <= Self.maximumBytes else { throw PechPechError.frameTooLarge(try WireCoding.encode(self).count) }
    }
    public func forwarded() -> RelayPacket? {
        guard hopsRemaining > 0 else { return nil }
        var copy = self; copy.hopsRemaining -= 1; return copy
    }
}
