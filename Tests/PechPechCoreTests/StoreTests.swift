import Foundation
import SQLite3
import XCTest
@testable import PechPechCore

final class StoreTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }
    private func url() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pechpech-test-\(UUID())")
        directories.append(directory)
        return directory.appendingPathComponent("mesh.sqlite")
    }
    private func store(_ identity: Identity, at url: URL? = nil) throws -> MeshStore {
        let store = try MeshStore(url: url ?? self.url())
        try store.bindIdentity(identity.publicIdentity)
        return store
    }
    private func message(_ sender: Identity, _ receiver: Identity, id: UUID = UUID(), payload: String = "synthetic payload") throws -> Message {
        try Message(id: id, senderID: sender.publicIdentity.id, destinationID: receiver.publicIdentity.id,
                    channel: "tests", payload: Data(payload.utf8))
    }
    private func accept(_ message: Message, from sender: Identity, at receiver: Identity, store: MeshStore) throws -> DeliveryReceipt {
        try store.accept(message, sender: sender.publicIdentity) {
            try EndpointCrypto.seal(.receipt($0), from: receiver, to: sender.publicIdentity, priority: .receipt)
        }
    }
    private func execute(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw PechPechError.storage("Cannot open synthetic fixture.") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw PechPechError.storage("Cannot apply synthetic failure trigger.") }
    }
    private func packet(_ sender: Identity, _ receiver: Identity, id: UUID = UUID(), priority: PacketPriority = .normal,
                        now: Int64, lifetime: Int64 = 600_000, encryptedBytes: Int = 28) -> RelayPacket {
        // An opaque relay stores ciphertext without decrypting it; these synthetic bytes
        // exercise resource admission only and are deliberately not valid AES-GCM envelopes.
        let header = PacketHeader(packetID: id, destinationID: receiver.publicIdentity.id, sender: sender.publicIdentity,
                                  ephemeralKey: sender.publicIdentity.agreementKey, priority: priority, expiresAt: now + lifetime)
        return RelayPacket(header: header, encrypted: Data(repeating: 7, count: encryptedBytes), hopsRemaining: 7)
    }

    func testBoundIdentityAndOutboxSurviveRestartAndRejectConflicts() throws {
        let sender = Identity(), receiver = Identity(), stranger = Identity(), path = url()
        let first = try store(sender, at: path), original = try message(sender, receiver)
        try first.queue(original, recipient: receiver.publicIdentity)
        try first.queue(original, recipient: receiver.publicIdentity)
        XCTAssertEqual(try first.pending().count, 1)
        let reopened = try store(sender, at: path)
        XCTAssertEqual(try reopened.pending().first?.message, original)
        XCTAssertEqual(try reopened.pending().first?.recipient, receiver.publicIdentity)
        XCTAssertThrowsError(try reopened.bindIdentity(stranger.publicIdentity))
        let changed = try Message(id: original.id, senderID: original.senderID, destinationID: original.destinationID,
                                  channel: original.channel, payload: Data("changed".utf8), createdAt: original.createdAt)
        XCTAssertThrowsError(try reopened.queue(changed, recipient: receiver.publicIdentity))
        XCTAssertThrowsError(try reopened.queue(original, recipient: stranger.publicIdentity))
        XCTAssertThrowsError(try reopened.queue(message(stranger, receiver), recipient: receiver.publicIdentity))
        XCTAssertEqual(try reopened.pending().first?.message, original)
    }

    func testIncompatibleCurrentNamespaceSchemaIsRejectedBeforeMutation() throws {
        for definition in [
            "id TEXT,payload BLOB NOT NULL,hash BLOB NOT NULL,receipt BLOB",
            "id TEXT PRIMARY KEY,payload BLOB NOT NULL,hash BLOB NOT NULL,receipt BLOB,future_version INTEGER NOT NULL DEFAULT 3",
            "id TEXT PRIMARY KEY,payload BLOB NOT NULL CHECK(length(payload)<1024),hash BLOB NOT NULL,receipt BLOB"
        ] {
            let path = url()
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try execute("CREATE TABLE pechpech_outbox(\(definition)); INSERT INTO pechpech_outbox(id,payload,hash) VALUES('sentinel',X'010203',X'040506');", at: path)
            XCTAssertThrowsError(try MeshStore(url: path))
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            func scalar(_ sql: String) throws -> String {
                var statement: OpaquePointer?
                XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
                defer { sqlite3_finalize(statement) }
                XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
                return String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0)))
            }
            XCTAssertEqual(try scalar("SELECT hex(payload)||':'||hex(hash) FROM pechpech_outbox WHERE id='sentinel';"), "010203:040506")
            XCTAssertEqual(try scalar("SELECT sql FROM sqlite_master WHERE name='pechpech_outbox';"), "CREATE TABLE pechpech_outbox(\(definition))")
            XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name GLOB 'pechpech_*';"), "1")
            XCTAssertEqual(try scalar("PRAGMA journal_mode;"), "delete")
        }
    }

    func testUnexpectedSchemaObjectsAreRejectedWithoutChangingOriginalRecords() throws {
        for object in [
            "CREATE TRIGGER erase_inbox AFTER INSERT ON pechpech_inbox BEGIN DELETE FROM pechpech_inbox WHERE id=NEW.id; END",
            "CREATE VIEW other_inbox AS SELECT * FROM pechpech_inbox",
            "CREATE INDEX custom_inbox_hash ON pechpech_inbox(hash)"
        ] {
            let path = url()
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try execute("CREATE TABLE pechpech_inbox(id TEXT PRIMARY KEY,payload BLOB NOT NULL,hash BLOB NOT NULL); INSERT INTO pechpech_inbox(id,payload,hash) VALUES('sentinel',X'010203',X'040506'); \(object);", at: path)
            XCTAssertThrowsError(try MeshStore(url: path))
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            func scalar(_ sql: String) throws -> String {
                var statement: OpaquePointer?
                XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
                defer { sqlite3_finalize(statement) }
                XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
                return String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0)))
            }
            XCTAssertEqual(try scalar("SELECT hex(payload)||':'||hex(hash) FROM pechpech_inbox WHERE id='sentinel';"), "010203:040506")
            XCTAssertEqual(try scalar("SELECT sql FROM sqlite_master WHERE type!='table' AND name NOT GLOB 'sqlite_*';"), object)
            XCTAssertEqual(try scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name GLOB 'pechpech_*';"), "1")
            XCTAssertEqual(try scalar("PRAGMA journal_mode;"), "delete")
        }
    }

    func testForeignSchemaIsRejectedWithoutChangingExistingRowsOrCreatingTables() throws {
        let path = url()
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try execute("CREATE TABLE foreign_outbox(id TEXT PRIMARY KEY,payload TEXT NOT NULL); INSERT INTO foreign_outbox(id,payload) VALUES('sentinel','preserve this original row');", at: path)
        XCTAssertThrowsError(try MeshStore(url: path))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func textRows(_ sql: String) throws -> [String] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw PechPechError.storage("Cannot inspect synthetic foreign database")
            }
            defer { sqlite3_finalize(statement) }
            var rows: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 0) { rows.append(String(cString: text)) }
            }
            return rows
        }
        XCTAssertEqual(try textRows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"), ["foreign_outbox"])
        XCTAssertEqual(try textRows("SELECT payload FROM foreign_outbox WHERE id='sentinel';"), ["preserve this original row"])
        XCTAssertEqual(try textRows("PRAGMA journal_mode;"), ["delete"], "Reject a foreign store before changing its journaling mode")
    }

    func testUnboundStoreAndWrongDestinationCannotRecordOwnedData() throws {
        let sender = Identity(), receiver = Identity(), stranger = Identity()
        let unbound = try MeshStore(url: url()), original = try message(sender, receiver)
        XCTAssertThrowsError(try unbound.queue(original, recipient: receiver.publicIdentity))
        XCTAssertThrowsError(try accept(original, from: sender, at: receiver, store: unbound))
        let bound = try store(receiver)
        XCTAssertThrowsError(try accept(message(sender, stranger), from: sender, at: stranger, store: bound))
        XCTAssertThrowsError(try bound.accept(original, sender: stranger.publicIdentity) { _ in throw PechPechError.invalid("Must not reach sealing hook") })
        XCTAssertTrue(try bound.inbox().isEmpty)
        XCTAssertTrue(try bound.outgoingReceipts().isEmpty)
    }

    func testDurableInboxReceiptReturnAndReplayAreOneResultAcrossRestart() throws {
        let sender = Identity(), receiver = Identity(), path = url()
        let inbox = try store(receiver, at: path), outbox = try store(sender), original = try message(sender, receiver)
        try outbox.queue(original, recipient: receiver.publicIdentity)
        let first = try accept(original, from: sender, at: receiver, store: inbox)
        let originalReturn = try XCTUnwrap(inbox.outgoingReceipts().first)
        XCTAssertEqual(try accept(original, from: sender, at: receiver, store: inbox), first)
        XCTAssertEqual(try inbox.outgoingReceipts().first, originalReturn, "Unchanged retries must reuse the saved ciphertext/packet ID")
        XCTAssertEqual(try inbox.inbox().count, 1)
        let restarted = try store(receiver, at: path)
        XCTAssertEqual(try restarted.received(messageID: original.id)?.receipt, first)
        XCTAssertEqual(try restarted.inbox().first?.message, original)
        let outgoing = try XCTUnwrap(restarted.outgoingReceipts().first)
        guard case .receipt(let decoded) = try EndpointCrypto.open(outgoing, for: sender).envelope else { return XCTFail("Return was not an endpoint receipt") }
        XCTAssertEqual(decoded, first)
        try outbox.saveReceipt(decoded, authenticatedReceiver: receiver.publicIdentity)
        XCTAssertTrue(try outbox.pending().isEmpty)
        XCTAssertEqual(try outbox.receipt(messageID: original.id), first)
        let changed = try Message(id: original.id, senderID: original.senderID, destinationID: original.destinationID,
                                  channel: original.channel, payload: Data("changed".utf8), createdAt: original.createdAt)
        XCTAssertThrowsError(try accept(changed, from: sender, at: receiver, store: restarted))
        XCTAssertEqual(try restarted.inbox().count, 1)
    }

    func testReceiptCreationOrStorageFailureRollsBackInboxAndReturn() throws {
        let sender = Identity(), receiver = Identity(), path = url(), original = try message(sender, receiver)
        let inbox = try store(receiver, at: path)
        XCTAssertThrowsError(try inbox.accept(original, sender: sender.publicIdentity) { _ in throw PechPechError.invalid("Synthetic seal failure") })
        XCTAssertTrue(try inbox.inbox().isEmpty)
        XCTAssertTrue(try inbox.outgoingReceipts().isEmpty)
        try execute("CREATE TRIGGER fail_returns BEFORE INSERT ON pechpech_returns BEGIN SELECT RAISE(ABORT,'synthetic storage failure'); END;", at: path)
        XCTAssertThrowsError(try accept(original, from: sender, at: receiver, store: inbox))
        XCTAssertTrue(try inbox.inbox().isEmpty)
        XCTAssertTrue(try inbox.outgoingReceipts().isEmpty)
        try execute("DROP TRIGGER fail_returns;", at: path)
        XCTAssertTrue(try store(receiver, at: path).inbox().isEmpty)
        XCTAssertNoThrow(try accept(original, from: sender, at: receiver, store: inbox))
        XCTAssertEqual(try inbox.inbox().count, 1)
    }

    func testOnlyMatchingEndpointReceiptResolvesOutboxAndRetiresReturn() throws {
        let sender = Identity(), receiver = Identity(), stranger = Identity(), original = try message(sender, receiver)
        let outbox = try store(sender), inbox = try store(receiver)
        try outbox.queue(original, recipient: receiver.publicIdentity)
        let receipt = try accept(original, from: sender, at: receiver, store: inbox)
        var wrongHash = receipt.bodyHash; wrongHash[wrongHash.startIndex] ^= 1
        let invalid = [
            DeliveryReceipt(messageID: UUID(), bodyHash: receipt.bodyHash, senderID: receipt.senderID, receiverID: receipt.receiverID, acceptedAt: receipt.acceptedAt),
            DeliveryReceipt(messageID: receipt.messageID, bodyHash: wrongHash, senderID: receipt.senderID, receiverID: receipt.receiverID, acceptedAt: receipt.acceptedAt),
            DeliveryReceipt(messageID: receipt.messageID, bodyHash: receipt.bodyHash, senderID: stranger.publicIdentity.id, receiverID: receipt.receiverID, acceptedAt: receipt.acceptedAt),
            DeliveryReceipt(messageID: receipt.messageID, bodyHash: receipt.bodyHash, senderID: receipt.senderID, receiverID: stranger.publicIdentity.id, acceptedAt: receipt.acceptedAt),
            DeliveryReceipt(messageID: receipt.messageID, bodyHash: receipt.bodyHash, senderID: receipt.senderID, receiverID: receipt.receiverID, acceptedAt: -1)
        ]
        for wrong in invalid { XCTAssertThrowsError(try outbox.saveReceipt(wrong, authenticatedReceiver: receiver.publicIdentity)) }
        XCTAssertThrowsError(try outbox.saveReceipt(receipt, authenticatedReceiver: stranger.publicIdentity))
        XCTAssertEqual(try outbox.pending().count, 1)
        XCTAssertThrowsError(try inbox.retireReturn(messageID: original.id, bodyHash: receipt.bodyHash, senderID: stranger.publicIdentity.id))
        XCTAssertThrowsError(try inbox.retireReturn(messageID: original.id, bodyHash: wrongHash, senderID: sender.publicIdentity.id))
        XCTAssertEqual(try inbox.outgoingReceipts().count, 1)
        try outbox.saveReceipt(receipt, authenticatedReceiver: receiver.publicIdentity)
        try outbox.saveReceipt(receipt, authenticatedReceiver: receiver.publicIdentity)
        try inbox.retireReturn(messageID: original.id, bodyHash: receipt.bodyHash, senderID: sender.publicIdentity.id)
        try inbox.retireReturn(messageID: original.id, bodyHash: receipt.bodyHash, senderID: sender.publicIdentity.id)
        XCTAssertTrue(try inbox.outgoingReceipts().isEmpty)
        XCTAssertEqual(try inbox.inbox().count, 1)
        let contradictory = DeliveryReceipt(messageID: receipt.messageID, bodyHash: receipt.bodyHash, senderID: receipt.senderID,
                                             receiverID: receipt.receiverID, acceptedAt: receipt.acceptedAt + 1)
        XCTAssertThrowsError(try outbox.saveReceipt(contradictory, authenticatedReceiver: receiver.publicIdentity))
        XCTAssertEqual(try outbox.receipt(messageID: original.id), receipt)
    }

    func testReceiptAndReturnRetirementStorageFailuresPreserveRetryState() throws {
        let sender = Identity(), receiver = Identity(), outboxURL = url(), inboxURL = url(), original = try message(sender, receiver)
        let outbox = try store(sender, at: outboxURL), inbox = try store(receiver, at: inboxURL)
        try outbox.queue(original, recipient: receiver.publicIdentity)
        let receipt = try accept(original, from: sender, at: receiver, store: inbox)
        try execute("CREATE TRIGGER fail_receipt BEFORE UPDATE OF receipt ON pechpech_outbox BEGIN SELECT RAISE(ABORT,'synthetic'); END;", at: outboxURL)
        XCTAssertThrowsError(try outbox.saveReceipt(receipt, authenticatedReceiver: receiver.publicIdentity))
        XCTAssertEqual(try outbox.pending().count, 1)
        XCTAssertNil(try outbox.receipt(messageID: original.id))
        try execute("DROP TRIGGER fail_receipt;", at: outboxURL)
        try outbox.saveReceipt(receipt, authenticatedReceiver: receiver.publicIdentity)
        try execute("CREATE TRIGGER fail_retirement BEFORE DELETE ON pechpech_returns BEGIN SELECT RAISE(ABORT,'synthetic'); END;", at: inboxURL)
        XCTAssertThrowsError(try inbox.retireReturn(messageID: original.id, bodyHash: receipt.bodyHash, senderID: sender.publicIdentity.id))
        XCTAssertEqual(try inbox.outgoingReceipts().count, 1)
        XCTAssertEqual(try inbox.inbox().count, 1)
        try execute("DROP TRIGGER fail_retirement;", at: inboxURL)
        try inbox.retireReturn(messageID: original.id, bodyHash: receipt.bodyHash, senderID: sender.publicIdentity.id)
        XCTAssertTrue(try inbox.outgoingReceipts().isEmpty)
    }

    func testRelayDuplicatesRequireAllImmutableMetadataAndOnlyLowerHopBudget() throws {
        let sender = Identity(), receiver = Identity(), relay = try store(Identity()), now = WireCoding.now
        let original = packet(sender, receiver, now: now)
        XCTAssertTrue(try relay.enqueueRelay(original, now: now))
        var fewer = original; fewer.hopsRemaining = 3
        XCTAssertFalse(try relay.enqueueRelay(fewer, now: now))
        XCTAssertFalse(try relay.enqueueRelay(original, now: now))
        XCTAssertEqual(try relay.relayPackets(now: now).first?.hopsRemaining, 3)
        let changedPriority = packet(sender, receiver, id: original.id, priority: .receipt, now: now)
        XCTAssertThrowsError(try relay.enqueueRelay(changedPriority, now: now))
        let changedExpiry = packet(sender, receiver, id: original.id, now: now, lifetime: 500_000)
        XCTAssertThrowsError(try relay.enqueueRelay(changedExpiry, now: now))
        let changedDestination = packet(sender, Identity(), id: original.id, now: now)
        XCTAssertThrowsError(try relay.enqueueRelay(changedDestination, now: now))
        let changedCipher = RelayPacket(header: original.header, encrypted: Data(repeating: 8, count: 28), hopsRemaining: 3)
        XCTAssertThrowsError(try relay.enqueueRelay(changedCipher, now: now))
        XCTAssertEqual(try relay.relayPackets(now: now).count, 1)
    }

    func testOriginAllowancePrioritizesUrgentTrafficAndPreservesOwnedData() throws {
        let sender = Identity(), receiver = Identity(), relayIdentity = Identity(), now = WireCoding.now
        let relay = try store(relayIdentity), ownMessage = try message(relayIdentity, receiver)
        try relay.queue(ownMessage, recipient: receiver.publicIdentity)
        for _ in 0..<MeshStore.maximumPacketsPerOrigin { try relay.enqueueRelay(packet(sender, receiver, priority: .bulk, now: now), now: now) }
        XCTAssertThrowsError(try relay.enqueueRelay(packet(sender, receiver, priority: .bulk, now: now), now: now))
        let urgent = packet(sender, receiver, priority: .urgent, now: now)
        XCTAssertTrue(try relay.enqueueRelay(urgent, now: now))
        XCTAssertEqual(try relay.relayPackets(now: now).count, MeshStore.maximumPacketsPerOrigin)
        XCTAssertEqual(try relay.relayPackets(now: now).first?.id, urgent.id)
        XCTAssertEqual(try relay.pending().first?.message, ownMessage)
        try relay.removeRelay(urgent.id)
        XCTAssertEqual(try relay.pending().count, 1)
    }

    func testGlobalSpoolBoundAndFailedAdmissionRollbackEveryVictim() throws {
        let receiver = Identity(), relayIdentity = Identity(), path = url(), relay = try store(relayIdentity, at: path), now = WireCoding.now
        for _ in 0..<4 {
            let sender = Identity()
            for _ in 0..<MeshStore.maximumPacketsPerOrigin { try relay.enqueueRelay(packet(sender, receiver, priority: .bulk, now: now, encryptedBytes: 11_000), now: now) }
        }
        let original = try relay.relayPackets(now: now)
        XCTAssertEqual(original.count, MeshStore.maximumRelayPackets)
        XCTAssertLessThanOrEqual(try original.reduce(0) { $0 + (try WireCoding.encode($1).count) }, MeshStore.maximumRelayBytes)
        XCTAssertThrowsError(try relay.enqueueRelay(packet(Identity(), receiver, priority: .bulk, now: now), now: now))
        XCTAssertEqual(try relay.relayPackets(now: now), original)
        try execute("CREATE TRIGGER fail_relay_insert BEFORE INSERT ON pechpech_relays BEGIN SELECT RAISE(ABORT,'synthetic'); END;", at: path)
        let urgent = packet(Identity(), receiver, priority: .receipt, now: now)
        XCTAssertThrowsError(try relay.enqueueRelay(urgent, now: now))
        XCTAssertEqual(try relay.relayPackets(now: now), original)
        try execute("DROP TRIGGER fail_relay_insert;", at: path)
        XCTAssertTrue(try relay.enqueueRelay(urgent, now: now))
        XCTAssertEqual(try relay.relayPackets(now: now).count, MeshStore.maximumRelayPackets)
        XCTAssertEqual(try relay.relayPackets(now: now).first?.id, urgent.id)
    }

    func testExpiredRelayAdmissionPrunesForeignBytesButNeverOwnedRecords() throws {
        let sender = Identity(), receiver = Identity(), relayIdentity = Identity(), relay = try store(relayIdentity), now = WireCoding.now
        let own = try message(relayIdentity, receiver)
        try relay.queue(own, recipient: receiver.publicIdentity)
        let expiring = packet(sender, receiver, now: now, lifetime: 1)
        try relay.enqueueRelay(expiring, now: now)
        let fresh = packet(sender, receiver, now: now + 2)
        try relay.enqueueRelay(fresh, now: now + 2)
        XCTAssertEqual(try relay.relayPackets(now: now + 2).map(\.id), [fresh.id])
        XCTAssertEqual(try relay.pending().first?.message, own)
        XCTAssertThrowsError(try relay.enqueueRelay(expiring, now: now + 2))
    }
}
