import Foundation
import PechPechCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

// This executable belongs only to the process-crash qualification harness.
// Every identity and message is synthetic; the driver supplies temporary stores.
private struct ProbeFailure: Error, LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}

private func require(_ condition: @autoclosure () throws -> Bool, _ detail: String) throws {
    guard try condition() else { throw ProbeFailure(detail: detail) }
}

private func readyForKill() -> Never {
    FileHandle.standardOutput.write(Data("PECHPECH_PROCESS_PROBE_READY\n".utf8))
    while true { _ = pause() }
}

private func expectStorageFull(_ operation: () throws -> Void) throws {
    #if os(Linux)
    try require(setenv("PECHPECH_PROBE_ENOSPC", "1", 1) == 0, "Cannot enable the synthetic ENOSPC switch.")
    defer { _ = unsetenv("PECHPECH_PROBE_ENOSPC") }
    do {
        try operation()
        throw ProbeFailure(detail: "The selected SQLite write unexpectedly succeeded under ENOSPC.")
    } catch let error as PechPechError {
        guard case .storage(let detail) = error, detail.hasPrefix("13:") else {
            throw ProbeFailure(detail: "Expected SQLITE_FULL (13), received \(error.localizedDescription)")
        }
    }
    #else
    throw ProbeFailure(detail: "ENOSPC qualification requires Linux.")
    #endif
}

private func run() throws {
    guard CommandLine.arguments.count == 3 else {
        throw ProbeFailure(detail: "Expected a probe mode and a temporary database path.")
    }
    let mode = CommandLine.arguments[1]
    // Openly specified repeated-byte seeds are test material, never operational keys.
    let sender = try Identity(signingPrivateKey: Data(repeating: 1, count: 32),
                              agreementPrivateKey: Data(repeating: 2, count: 32))
    let receiver = try Identity(signingPrivateKey: Data(repeating: 3, count: 32),
                                agreementPrivateKey: Data(repeating: 4, count: 32))
    let message = try Message(id: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!,
                              senderID: sender.publicIdentity.id, destinationID: receiver.publicIdentity.id,
                              channel: "synthetic.durability.v1", payload: Data("Synthetic process-crash probe".utf8),
                              createdAt: 1_700_000_000_000)
    let store = try MeshStore(url: URL(fileURLWithPath: CommandLine.arguments[2]))
    // Keep the SQLite handle open at the kill barrier, including optimized builds.
    defer { withExtendedLifetime(store) {} }
    let senderModes: Set<String> = ["queue-committed", "receipt-committed", "check-queue", "check-delivered",
                                    "full-queue", "full-receipt"]
    try store.bindIdentity(senderModes.contains(mode) ? sender.publicIdentity : receiver.publicIdentity)

    func accept() throws -> DeliveryReceipt {
        try store.accept(message, sender: sender.publicIdentity) { receipt in
            if mode == "inbox-uncommitted" { readyForKill() }
            return try EndpointCrypto.seal(.receipt(receipt), from: receiver, to: sender.publicIdentity,
                                           priority: .receipt, lifetimeMilliseconds: 600_000)
        }
    }

    switch mode {
    case "queue-committed":
        try store.queue(message, recipient: receiver.publicIdentity)
        readyForKill()
    case "receipt-committed":
        try store.queue(message, recipient: receiver.publicIdentity)
        let receipt = DeliveryReceipt(messageID: message.id, bodyHash: try message.bodyHash,
                                      senderID: sender.publicIdentity.id, receiverID: receiver.publicIdentity.id,
                                      acceptedAt: WireCoding.now)
        try store.saveReceipt(receipt, authenticatedReceiver: receiver.publicIdentity)
        readyForKill()
    case "inbox-committed", "inbox-uncommitted":
        _ = try accept()
        readyForKill()
    case "full-queue":
        try expectStorageFull { try store.queue(message, recipient: receiver.publicIdentity) }
        try require(store.outgoing(messageID: message.id) == nil, "Failed outbox write left a partial immutable record.")
        try store.queue(message, recipient: receiver.publicIdentity)
        try require(store.pending().map(\.message) == [message], "Outbox retry failed after ENOSPC was cleared.")
    case "full-inbox":
        try expectStorageFull { _ = try accept() }
        try require(store.inbox().isEmpty, "Failed inbox write left a partial message.")
        try require(store.outgoingReceipts().isEmpty, "Failed inbox write left a false endpoint receipt.")
        _ = try accept()
        try require(store.inbox().map(\.message) == [message], "Inbox retry failed after ENOSPC was cleared.")
        try require(store.outgoingReceipts().count == 1, "Inbox retry did not restore its durable receipt.")
    case "full-receipt":
        try store.queue(message, recipient: receiver.publicIdentity)
        let receipt = DeliveryReceipt(messageID: message.id, bodyHash: try message.bodyHash,
                                      senderID: sender.publicIdentity.id, receiverID: receiver.publicIdentity.id,
                                      acceptedAt: WireCoding.now)
        try expectStorageFull { try store.saveReceipt(receipt, authenticatedReceiver: receiver.publicIdentity) }
        try require(store.pending().map(\.message) == [message], "Failed receipt write falsely resolved the outbox.")
        try require(store.receipt(messageID: message.id) == nil, "Failed receipt write left partial delivery state.")
        try store.saveReceipt(receipt, authenticatedReceiver: receiver.publicIdentity)
        try require(store.pending().isEmpty, "Receipt retry failed after ENOSPC was cleared.")
    case "check-queue":
        try require(store.pending().map(\.message) == [message], "Committed immutable outbox did not survive SIGKILL.")
        try require(store.receipt(messageID: message.id) == nil, "Unconfirmed message gained a receipt after SIGKILL.")
    case "check-delivered":
        try require(store.pending().isEmpty, "Committed sender receipt did not resolve pending state after SIGKILL.")
        try require(store.outgoing(messageID: message.id)?.message == message, "Delivered immutable outbox history was lost.")
        let receipt = try store.receipt(messageID: message.id)
        try require(receipt?.bodyHash == message.bodyHash, "Saved sender receipt lost its immutable body hash.")
        try require(receipt?.receiverID == receiver.publicIdentity.id, "Saved sender receipt lost its pinned receiver.")
    case "check-inbox":
        try require(store.inbox().map(\.message) == [message], "Committed inbox did not survive SIGKILL.")
        guard let saved = try store.received(messageID: message.id), let packet = try store.outgoingReceipts().first else {
            throw ProbeFailure(detail: "Committed inbox and return receipt were not recovered together.")
        }
        try require(EndpointCrypto.open(packet, for: sender).envelope == .receipt(saved.receipt),
                    "Recovered return packet does not authenticate the durable inbox receipt.")
        try require(accept() == saved.receipt, "Replay changed the committed receipt after SIGKILL.")
        try require(store.inbox().count == 1, "Replay duplicated committed inbox bytes.")
    case "check-empty":
        try require(store.inbox().isEmpty, "An uncommitted inbox row survived SIGKILL.")
        try require(store.outgoingReceipts().isEmpty, "An uncommitted return packet survived SIGKILL.")
        _ = try accept()
        try require(store.inbox().map(\.message) == [message], "Retry could not recover after transaction rollback.")
        try require(store.outgoingReceipts().count == 1, "Retry failed to persist its endpoint receipt.")
    default:
        throw ProbeFailure(detail: "Unknown process-crash probe mode.")
    }
    print("PASS: \(mode)")
}

do { try run() }
catch {
    FileHandle.standardError.write(Data("Process-crash probe failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
