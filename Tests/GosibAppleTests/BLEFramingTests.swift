
import Foundation
import XCTest
@testable import GosibApple

/// Exercises codecs without instantiating any radio manager.
final class BLEFramingTests: XCTestCase {
    struct CheckFailure: Error, CustomStringConvertible { let description: String }
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw CheckFailure(description: message) }
    }
    private static func drain(_ outbox: inout BLEOutbox, receiver: inout BLEReassembler, maximum: Int = 20) throws -> [Data] {
        var messages: [Data] = [], fragments = 0
        while let fragment = outbox.nextFragment(maximumValueBytes: maximum) {
            try check(fragment.data.count <= maximum, "A value exceeds the negotiated BLE limit.")
            if let message = try receiver.append(fragment.data) { messages.append(message) }
            outbox.consume(payloadBytes: fragment.payloadBytes)
            fragments += 1
            try check(fragments <= 3_000, "The fragment queue stopped making progress.")
        }
        try check(outbox.messages.isEmpty && outbox.byteCount == 0, "Outbox accounting did not drain.")
        return messages
    }
    static func roundTrip(_ data: Data, maximum: Int) throws {
        var outbox = BLEOutbox(), receiver = BLEReassembler()
        outbox.enqueue(data, id: 99, priority: 2)
        let messages = try drain(&outbox, receiver: &receiver, maximum: maximum)
        try check(messages == [data], "Message boundaries or bytes changed.")
    }
    static func rejects(_ bytes: Data) throws {
        var receiver = BLEReassembler()
        do { _ = try receiver.append(bytes) }
        catch { return }
        throw CheckFailure(description: "Malformed or out-of-order bytes were accepted.")
    }
    func testFramingAndQueueInvariants() throws {
        try Self.runOriginalBoundarySuite()
    }

    private static func runOriginalBoundarySuite() throws {
        for maximum in [20, 21, 64, 185, 512] {
            for count in [0, 1, 7, 8, 9, 19, 20, 255, 256, 1_024, 16_383, 16_384] {
                try roundTrip(Data((0..<count).map { UInt8($0 % 251) }), maximum: maximum)
            }
        }
        let sliced = Data((0..<100).map { UInt8($0) })
        try roundTrip(sliced[10..<90], maximum: 20)

        // Highest priority first at an idle message boundary; equal priority retains FIFO order.
        var idle = BLEOutbox(), idleReceiver = BLEReassembler()
        let low = Data(repeating: 1, count: 40), normal = Data([2]), order = Data([3]), receiptA = Data([4]), receiptB = Data([5]), ack = Data([6])
        idle.enqueue(low, id: 1, priority: 0); idle.enqueue(normal, id: 2, priority: 1)
        idle.enqueue(order, id: 3, priority: 2); idle.enqueue(receiptA, id: 4, priority: 3)
        idle.enqueue(receiptB, id: 5, priority: 3); idle.enqueue(ack, id: 6, priority: 4)
        let idleMessages = try drain(&idle, receiver: &idleReceiver)
        try check(idleMessages == [ack, receiptA, receiptB, order, normal, low], "Idle priority or equal-priority FIFO is incorrect.")

        // A withResponse first fragment is already issued while offset is still zero. New high
        // priority messages must wait for that exact head; its write response consumes its bytes.
        for firstSize in [1, 5, 8, 9, 80] {
            var inFlight = BLEOutbox(), receiver = BLEReassembler()
            let original = Data(repeating: 7, count: firstSize), urgent = Data([8, 9]), control = Data([10])
            inFlight.enqueue(original, id: 101, priority: 0)
            let first = inFlight.nextFragment(maximumValueBytes: 20)!
            try check(inFlight.messages[0].offset == 0, "A response must be awaited before consuming its payload.")
            inFlight.enqueue(urgent, id: 102, priority: 3, protectCurrent: true)
            inFlight.enqueue(control, id: 103, priority: 4, protectCurrent: true)
            try check(inFlight.nextFragment(maximumValueBytes: 20)?.data == first.data, "An in-flight first fragment was preempted before its write response.")
            var messages: [Data] = []
            if let completed = try receiver.append(first.data) { messages.append(completed) }
            inFlight.consume(payloadBytes: first.payloadBytes) // emulate didWriteValue success
            messages += try drain(&inFlight, receiver: &receiver)
            try check(messages == [original, control, urgent], "Write-response consumption corrupted an in-flight message or priority order.")
        }

        // Started streams keep their remaining fragments together on notify/withoutResponse paths.
        var started = BLEOutbox(), startedReceiver = BLEReassembler()
        started.enqueue(low, id: 201, priority: 0)
        let first = started.nextFragment(maximumValueBytes: 20)!
        _ = try startedReceiver.append(first.data); started.consume(payloadBytes: first.payloadBytes)
        started.enqueue(normal, id: 202, priority: 1); started.enqueue(order, id: 203, priority: 2)
        started.enqueue(receiptA, id: 204, priority: 3)
        let startedMessages = try drain(&started, receiver: &startedReceiver)
        try check(startedMessages == [low, receiptA, order, normal], "A started message was split by a priority packet.")

        // Once a message completes, the next unstarted low-priority message can be preempted.
        var boundary = BLEOutbox(), boundaryReceiver = BLEReassembler()
        boundary.enqueue(normal, id: 301, priority: 0); boundary.enqueue(low, id: 302, priority: 0)
        let completed = boundary.nextFragment(maximumValueBytes: 20)!
        try check(try boundaryReceiver.append(completed.data) == normal, "The first small message did not complete.")
        boundary.consume(payloadBytes: completed.payloadBytes)
        boundary.enqueue(receiptA, id: 303, priority: 3)
        let boundaryMessages = try drain(&boundary, receiver: &boundaryReceiver)
        try check(boundaryMessages == [receiptA, low], "Priority was not honored after a completed stream.")

        // Rejected/backpressured notification attempts leave the exact fragment intact.
        var blocked = BLEOutbox()
        blocked.enqueue(low, id: 401, priority: 0)
        let pending = blocked.nextFragment(maximumValueBytes: 20)!
        for _ in 0..<10 { try check(blocked.nextFragment(maximumValueBytes: 20)?.data == pending.data, "Backpressure consumed or changed an unsent fragment.") }
        try check(blocked.byteCount == low.count && blocked.messages[0].offset == 0, "Backpressure changed byte accounting.")

        // Different neighbors have independent reassembly state, even when their local IDs match.
        var a = BLEOutbox(), b = BLEOutbox(), ra = BLEReassembler(), rb = BLEReassembler()
        let payloadA = Data(repeating: 17, count: 1_024), payloadB = Data(repeating: 18, count: 16_384)
        a.enqueue(payloadA, id: 500, priority: 2); b.enqueue(payloadB, id: 500, priority: 0)
        var receivedA: [Data] = [], receivedB: [Data] = []
        while !a.messages.isEmpty || !b.messages.isEmpty {
            if let fragment = a.nextFragment(maximumValueBytes: 20) {
                if let message = try ra.append(fragment.data) { receivedA.append(message) }; a.consume(payloadBytes: fragment.payloadBytes)
            }
            if let fragment = b.nextFragment(maximumValueBytes: 185) {
                if let message = try rb.append(fragment.data) { receivedB.append(message) }; b.consume(payloadBytes: fragment.payloadBytes)
            }
        }
        try check(receivedA == [payloadA] && receivedB == [payloadB], "Interleaved neighbors mixed message buffers.")

        let oversized = BLEOutboundMessage(id: 1, data: Data(repeating: 1, count: 16_385), priority: 2)
        try check(BLEFragment.encode(oversized, maximumValueBytes: 20) == nil, "An oversized packet was framed.")
        try check(BLEFragment.encode(BLEOutboundMessage(id: 1, data: Data([1]), priority: 2), maximumValueBytes: 12) == nil, "A header-only negotiated value was accepted.")
        try rejects(Data()); try rejects(Data(repeating: 0, count: 12))
        let frame = BLEFragment.encode(BLEOutboundMessage(id: 1, data: Data(repeating: 1, count: 20), priority: 2), maximumValueBytes: 20)!.data
        for field in 0...3 { var invalid = frame; invalid[field] ^= 0xff; try rejects(invalid) }
        var zeroID = frame; for field in 4...7 { zeroID[field] = 0 }; try rejects(zeroID)
        var tooLarge = frame; tooLarge[8] = 0x40; tooLarge[9] = 1; try rejects(tooLarge)
        var sequence = frame; sequence[11] = 8; try rejects(sequence)
        var expired = BLEReassembler(); _ = try expired.append(frame)
        try check(expired.discardIfInactive(before: .greatestFiniteMagnitude), "An inactive partial stream was retained.")

        print("PASS: Gosib BLE framing: 60 boundary round trips, sliced Data, idle/FIFO priority, five in-flight first-fragment cases, started-stream protection, priority at message boundaries, unchanged backpressure frames, independent neighbor buffers and malformed/size/sequence bounds.")
        print("No Bluetooth managers or physical radios were exercised.")
    }
}
