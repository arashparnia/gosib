import Foundation
import SQLite3

public struct PendingMessage: Codable, Equatable, Sendable {
    public let message: Message
    public let recipient: PublicIdentity
    public let priority: PacketPriority
    public init(message: Message, recipient: PublicIdentity, priority: PacketPriority = .urgent) {
        self.message = message; self.recipient = recipient; self.priority = priority
    }
}

public struct ReceivedMessage: Codable, Equatable, Sendable {
    public let message: Message
    public let sender: PublicIdentity
    public let receipt: DeliveryReceipt
    public init(message: Message, sender: PublicIdentity, receipt: DeliveryReceipt) {
        self.message = message; self.sender = sender; self.receipt = receipt
    }
}

/// WAL/FULL durable owned records and a separately bounded, opaque relay spool.
/// Calls are serialized; do not perform slow work in makeReceiptPacket.
public final class MeshStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public static let maximumRelayPackets = 512
    public static let maximumRelayBytes = 8 * 1_024 * 1_024
    public static let maximumPacketsPerOrigin = 128

    public init(url: URL) throws {
        guard url.isFileURL else { throw PechPechError.invalid("Use a local database file URL.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let connection else {
            if let connection { sqlite3_close_v2(connection) }
            throw PechPechError.storage("Cannot open database.")
        }
        do {
            sqlite3_busy_timeout(connection, 5_000)
            // A renamed namespace must not silently hide a previous host's
            // durable records by adding a parallel empty schema to its file.
            try Self.requireCompatibleSchema(connection)
            try Self.exec(connection, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
            guard try Self.textScalar(connection, "PRAGMA journal_mode;") == "wal",
                  try Self.textScalar(connection, "PRAGMA synchronous;") == "2" else {
                throw PechPechError.storage("WAL/FULL durability could not be enabled.")
            }
            try Self.exec(connection, """
                CREATE TABLE IF NOT EXISTS pechpech_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS pechpech_outbox (id TEXT PRIMARY KEY, payload BLOB NOT NULL, hash BLOB NOT NULL, receipt BLOB);
                CREATE TABLE IF NOT EXISTS pechpech_inbox (id TEXT PRIMARY KEY, payload BLOB NOT NULL, hash BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS pechpech_returns (id TEXT PRIMARY KEY, packet BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS pechpech_relays (id TEXT PRIMARY KEY, payload BLOB NOT NULL, priority INTEGER NOT NULL, expires INTEGER NOT NULL, origin TEXT NOT NULL);
                """)
            db = connection
        } catch { sqlite3_close_v2(connection); throw error }
    }
    deinit { if let db { sqlite3_close_v2(db) } }

    private static func requireCompatibleSchema(_ db: OpaquePointer) throws {
        let allowed: Set<String> = ["pechpech_metadata", "pechpech_outbox", "pechpech_inbox", "pechpech_returns", "pechpech_relays"]
        let query = try statement(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT GLOB 'sqlite_*';")
        defer { sqlite3_finalize(query) }
        while true {
            switch sqlite3_step(query) {
            case SQLITE_DONE: return
            case SQLITE_ROW:
                guard let name = sqlite3_column_text(query, 0), allowed.contains(String(cString: name)) else {
                    throw PechPechError.storage("This database uses another storage namespace. Preserve its records and perform a reviewed migration before upgrading.")
                }
            default: throw error(db)
            }
        }
    }

    /// A database belongs to one durable endpoint identity, including after restart.
    public func bindIdentity(_ identity: PublicIdentity) throws {
        try identity.validate()
        try database { db in
            try Self.transaction(db) {
                let s = try Self.statement(db, "INSERT OR IGNORE INTO pechpech_metadata(key,value) VALUES('identity',?);")
                defer { sqlite3_finalize(s) }
                try Self.bind(identity.id, s, 1, db); try Self.done(s, db)
                guard try Self.textScalar(db, "SELECT value FROM pechpech_metadata WHERE key='identity';") == identity.id else {
                    throw PechPechError.identityConflict
                }
            }
        }
    }

    /// Persist immutable data and the pinned recipient before any transmission.
    public func queue(_ message: Message, recipient: PublicIdentity, priority: PacketPriority = .urgent) throws {
        try message.validate(); try recipient.validate()
        guard message.destinationID == recipient.id else { throw PechPechError.identityConflict }
        let pending = PendingMessage(message: message, recipient: recipient, priority: priority)
        let bytes = try WireCoding.encode(pending), hash = try message.bodyHash
        try database { db in
            try Self.transaction(db) {
                guard try Self.textScalar(db, "SELECT value FROM pechpech_metadata WHERE key='identity';") == message.senderID else {
                    throw PechPechError.identityConflict
                }
                if let old = try Self.blobRow(db, "SELECT payload FROM pechpech_outbox WHERE id=?;", message.id.uuidString) {
                    guard try WireCoding.decode(PendingMessage.self, from: old) == pending else { throw PechPechError.messageConflict }
                    return
                }
                let s = try Self.statement(db, "INSERT INTO pechpech_outbox(id,payload,hash) VALUES(?,?,?);")
                defer { sqlite3_finalize(s) }
                try Self.bind(message.id.uuidString, s, 1, db); try Self.bind(bytes, s, 2, db)
                try Self.bind(hash, s, 3, db); try Self.done(s, db)
            }
        }
    }

    public func pending() throws -> [PendingMessage] {
        try database { try Self.rows($0, "SELECT payload FROM pechpech_outbox WHERE receipt IS NULL ORDER BY rowid;", as: PendingMessage.self) }
    }
    public func inbox() throws -> [ReceivedMessage] {
        try database { try Self.rows($0, "SELECT payload FROM pechpech_inbox ORDER BY rowid;", as: ReceivedMessage.self) }
    }
    public func received(messageID: UUID) throws -> ReceivedMessage? {
        try database { db in
            guard let bytes = try Self.blobRow(db, "SELECT payload FROM pechpech_inbox WHERE id=?;", messageID.uuidString) else { return nil }
            return try WireCoding.decode(ReceivedMessage.self, from: bytes)
        }
    }
    public func receipt(messageID: UUID) throws -> DeliveryReceipt? {
        try database { db in
            guard let bytes = try Self.blobRow(db, "SELECT receipt FROM pechpech_outbox WHERE id=?;", messageID.uuidString) else { return nil }
            return try WireCoding.decode(DeliveryReceipt.self, from: bytes)
        }
    }

    /// Inbox bytes, deduplication result and outgoing receipt commit in one transaction.
    /// Caller must authenticate and authorize the sender before calling this method.
    @discardableResult public func accept(_ message: Message, sender: PublicIdentity,
                                          makeReceiptPacket: (DeliveryReceipt) throws -> RelayPacket) throws -> DeliveryReceipt {
        try message.validate(); try sender.validate()
        guard message.senderID == sender.id else { throw PechPechError.identityConflict }
        let hash = try message.bodyHash
        return try database { db in
            try Self.transaction(db) {
                guard try Self.textScalar(db, "SELECT value FROM pechpech_metadata WHERE key='identity';") == message.destinationID else {
                    throw PechPechError.identityConflict
                }
                let receipt: DeliveryReceipt
                if let bytes = try Self.blobRow(db, "SELECT payload FROM pechpech_inbox WHERE id=?;", message.id.uuidString) {
                    let old = try WireCoding.decode(ReceivedMessage.self, from: bytes)
                    guard old.message == message, old.sender == sender else { throw PechPechError.messageConflict }
                    receipt = old.receipt
                } else {
                    receipt = DeliveryReceipt(messageID: message.id, bodyHash: hash, senderID: sender.id,
                                              receiverID: message.destinationID, acceptedAt: WireCoding.now)
                    let received = ReceivedMessage(message: message, sender: sender, receipt: receipt)
                    let s = try Self.statement(db, "INSERT INTO pechpech_inbox(id,payload,hash) VALUES(?,?,?);")
                    defer { sqlite3_finalize(s) }
                    try Self.bind(message.id.uuidString, s, 1, db); try Self.bind(try WireCoding.encode(received), s, 2, db)
                    try Self.bind(hash, s, 3, db); try Self.done(s, db)
                }
                // An unchanged durable result reuses its existing ciphertext/packet ID.
                // Repeated sender retries must not fill relays with fresh receipt IDs.
                if let bytes = try Self.blobRow(db, "SELECT packet FROM pechpech_returns WHERE id=?;", message.id.uuidString) {
                    let existing = try WireCoding.decode(RelayPacket.self, from: bytes)
                    if existing.expiresAt > WireCoding.now + 5_000 { return receipt }
                }
                let packet = try makeReceiptPacket(receipt)
                try packet.validate()
                guard packet.originID == message.destinationID, packet.destinationID == sender.id,
                      packet.priority == .receipt else { throw PechPechError.identityConflict }
                let s = try Self.statement(db, "INSERT OR REPLACE INTO pechpech_returns(id,packet) VALUES(?,?);")
                defer { sqlite3_finalize(s) }
                try Self.bind(message.id.uuidString, s, 1, db); try Self.bind(try WireCoding.encode(packet), s, 2, db)
                try Self.done(s, db)
                return receipt
            }
        }
    }

    /// A relay ACK can never call this. It requires a matching authenticated endpoint.
    public func saveReceipt(_ receipt: DeliveryReceipt, authenticatedReceiver: PublicIdentity) throws {
        try authenticatedReceiver.validate()
        try database { db in
            try Self.transaction(db) {
                guard let bytes = try Self.blobRow(db, "SELECT payload FROM pechpech_outbox WHERE id=?;", receipt.messageID.uuidString) else {
                    throw PechPechError.invalid("Receipt has no original immutable outbox message.")
                }
                let pending = try WireCoding.decode(PendingMessage.self, from: bytes)
                guard pending.recipient == authenticatedReceiver, receipt.receiverID == authenticatedReceiver.id,
                      receipt.senderID == pending.message.senderID, receipt.bodyHash == (try pending.message.bodyHash),
                      receipt.acceptedAt >= 0 else { throw PechPechError.authenticationFailed }
                if let old = try Self.blobRow(db, "SELECT receipt FROM pechpech_outbox WHERE id=?;", receipt.messageID.uuidString) {
                    guard try WireCoding.decode(DeliveryReceipt.self, from: old) == receipt else { throw PechPechError.messageConflict }
                    return
                }
                let s = try Self.statement(db, "UPDATE pechpech_outbox SET receipt=? WHERE id=?;")
                defer { sqlite3_finalize(s) }
                try Self.bind(try WireCoding.encode(receipt), s, 1, db); try Self.bind(receipt.messageID.uuidString, s, 2, db)
                try Self.done(s, db)
            }
        }
    }

    public func outgoingReceipts(now: Int64 = WireCoding.now) throws -> [RelayPacket] {
        try database { db in
            let packets = try Self.rows(db, "SELECT packet FROM pechpech_returns ORDER BY rowid;", as: RelayPacket.self)
            // An expired return is regenerated when the original sender retries; never
            // delete its immutable result just because the transport packet expired.
            return packets.filter { $0.expiresAt > now }
        }
    }
    public func retireReturn(messageID: UUID, bodyHash: Data, senderID: String) throws {
        try database { db in
            try Self.transaction(db) {
                guard let bytes = try Self.blobRow(db, "SELECT payload FROM pechpech_inbox WHERE id=?;", messageID.uuidString) else { return }
                let original = try WireCoding.decode(ReceivedMessage.self, from: bytes)
                guard original.sender.id == senderID, original.receipt.bodyHash == bodyHash else { throw PechPechError.authenticationFailed }
                let s = try Self.statement(db, "DELETE FROM pechpech_returns WHERE id=?;")
                defer { sqlite3_finalize(s) }; try Self.bind(messageID.uuidString, s, 1, db); try Self.done(s, db)
            }
        }
    }

    /// True means newly admitted; false means an identical immutable packet is stored.
    @discardableResult public func enqueueRelay(_ packet: RelayPacket, now: Int64 = WireCoding.now) throws -> Bool {
        try packet.validate(now: now)
        let bytes = try WireCoding.encode(packet)
        return try database { db in
            try Self.transaction(db) {
                let prune = try Self.statement(db, "DELETE FROM pechpech_relays WHERE expires<=?;")
                defer { sqlite3_finalize(prune) }; sqlite3_bind_int64(prune, 1, now); try Self.done(prune, db)
                if let old = try Self.blobRow(db, "SELECT payload FROM pechpech_relays WHERE id=?;", packet.id.uuidString) {
                    let existing = try WireCoding.decode(RelayPacket.self, from: old)
                    guard existing.header == packet.header, existing.encrypted == packet.encrypted else { throw PechPechError.messageConflict }
                    // Loops must never replenish hop budgets, including after restart.
                    if packet.hopsRemaining < existing.hopsRemaining {
                        let s = try Self.statement(db, "UPDATE pechpech_relays SET payload=? WHERE id=?;")
                        defer { sqlite3_finalize(s) }
                        try Self.bind(bytes, s, 1, db); try Self.bind(packet.id.uuidString, s, 2, db); try Self.done(s, db)
                    }
                    return false
                }
                while try Self.originCount(db, origin: packet.originID) >= Self.maximumPacketsPerOrigin {
                    let s = try Self.statement(db, "DELETE FROM pechpech_relays WHERE id=(SELECT id FROM pechpech_relays WHERE origin=? AND priority<? ORDER BY priority,rowid LIMIT 1);")
                    defer { sqlite3_finalize(s) }
                    try Self.bind(packet.originID, s, 1, db); sqlite3_bind_int(s, 2, Int32(packet.priority.rawValue)); try Self.done(s, db)
                    guard sqlite3_changes(db) > 0 else { throw PechPechError.spoolFull }
                }
                while true {
                    let s = try Self.statement(db, "SELECT COUNT(*),COALESCE(SUM(length(payload)),0) FROM pechpech_relays;")
                    guard sqlite3_step(s) == SQLITE_ROW else { sqlite3_finalize(s); throw Self.error(db) }
                    let fits = sqlite3_column_int(s, 0) < Self.maximumRelayPackets &&
                        sqlite3_column_int64(s, 1) + Int64(bytes.count) <= Self.maximumRelayBytes
                    sqlite3_finalize(s)
                    if fits { break }
                    let victim = try Self.statement(db, "DELETE FROM pechpech_relays WHERE id=(SELECT id FROM pechpech_relays WHERE priority<? ORDER BY priority,rowid LIMIT 1);")
                    defer { sqlite3_finalize(victim) }; sqlite3_bind_int(victim, 1, Int32(packet.priority.rawValue)); try Self.done(victim, db)
                    guard sqlite3_changes(db) > 0 else { throw PechPechError.spoolFull }
                }
                let s = try Self.statement(db, "INSERT INTO pechpech_relays(id,payload,priority,expires,origin) VALUES(?,?,?,?,?);")
                defer { sqlite3_finalize(s) }
                try Self.bind(packet.id.uuidString, s, 1, db); try Self.bind(bytes, s, 2, db)
                sqlite3_bind_int(s, 3, Int32(packet.priority.rawValue)); sqlite3_bind_int64(s, 4, packet.expiresAt)
                try Self.bind(packet.originID, s, 5, db); try Self.done(s, db)
                return true
            }
        }
    }
    public func relayPackets(now: Int64 = WireCoding.now) throws -> [RelayPacket] {
        try database { db in
            let s = try Self.statement(db, "SELECT payload FROM pechpech_relays WHERE expires>? ORDER BY priority DESC,rowid;")
            defer { sqlite3_finalize(s) }; sqlite3_bind_int64(s, 1, now)
            var packets: [RelayPacket] = []
            while true {
                switch sqlite3_step(s) {
                case SQLITE_ROW: packets.append(try WireCoding.decode(RelayPacket.self, from: Self.blob(s, 0)))
                case SQLITE_DONE: return packets
                default: throw Self.error(db)
                }
            }
        }
    }
    public func removeRelay(_ id: UUID) throws {
        try database { db in
            let s = try Self.statement(db, "DELETE FROM pechpech_relays WHERE id=?;")
            defer { sqlite3_finalize(s) }; try Self.bind(id.uuidString, s, 1, db); try Self.done(s, db)
        }
    }

    private func database<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw PechPechError.storage("Database is unavailable.") }; return try operation(db)
    }
    private static func originCount(_ db: OpaquePointer, origin: String) throws -> Int {
        let s = try statement(db, "SELECT COUNT(*) FROM pechpech_relays WHERE origin=?;")
        defer { sqlite3_finalize(s) }; try bind(origin, s, 1, db)
        guard sqlite3_step(s) == SQLITE_ROW else { throw error(db) }; return Int(sqlite3_column_int(s, 0))
    }
    private static func rows<T: Decodable>(_ db: OpaquePointer, _ sql: String, as type: T.Type) throws -> [T] {
        let s = try statement(db, sql); defer { sqlite3_finalize(s) }; var result: [T] = []
        while true {
            switch sqlite3_step(s) {
            case SQLITE_ROW: result.append(try WireCoding.decode(type, from: blob(s, 0)))
            case SQLITE_DONE: return result
            default: throw error(db)
            }
        }
    }
    private static func blobRow(_ db: OpaquePointer, _ sql: String, _ id: String) throws -> Data? {
        let s = try statement(db, sql); defer { sqlite3_finalize(s) }; try bind(id, s, 1, db)
        let step = sqlite3_step(s)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw error(db) }
        if sqlite3_column_type(s, 0) == SQLITE_NULL { return nil }
        return blob(s, 0)
    }
    private static func textScalar(_ db: OpaquePointer, _ sql: String) throws -> String {
        let s = try statement(db, sql); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW, let bytes = sqlite3_column_text(s, 0) else { throw error(db) }
        return String(cString: bytes)
    }
    private static func blob(_ s: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(s, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, column)))
    }
    private static func statement(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw error(db) }; return s
    }
    private static func bind(_ value: String, _ s: OpaquePointer, _ i: Int32, _ db: OpaquePointer) throws {
        guard sqlite3_bind_text(s, i, value, -1, transient) == SQLITE_OK else { throw error(db) }
    }
    private static func bind(_ value: Data, _ s: OpaquePointer, _ i: Int32, _ db: OpaquePointer) throws {
        let result = value.withUnsafeBytes { sqlite3_bind_blob(s, i, $0.baseAddress, Int32(value.count), transient) }
        guard result == SQLITE_OK else { throw error(db) }
    }
    private static func done(_ s: OpaquePointer, _ db: OpaquePointer) throws {
        guard sqlite3_step(s) == SQLITE_DONE else { throw error(db) }
    }
    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error(db) }
    }
    private static func transaction<T>(_ db: OpaquePointer, _ operation: () throws -> T) throws -> T {
        try exec(db, "BEGIN IMMEDIATE;")
        do { let result = try operation(); try exec(db, "COMMIT;"); return result }
        catch { try? exec(db, "ROLLBACK;"); throw error }
    }
    private static func error(_ db: OpaquePointer) -> PechPechError {
        .storage("\(sqlite3_errcode(db)): \(String(cString: sqlite3_errmsg(db)))")
    }
}
