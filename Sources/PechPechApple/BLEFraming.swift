import Foundation

/// Internal wire framing is independent of the app envelope. Twelve bytes of
/// header leaves eight payload bytes at the minimum 20-byte ATT value length.
enum BLEFragment {
    static let headerBytes = 12
    static let maximumMessageBytes = 16 * 1024

    struct Encoded {
        let data: Data
        let payloadBytes: Int
    }

    static func encode(_ message: BLEOutboundMessage, maximumValueBytes: Int) -> Encoded? {
        guard maximumValueBytes > headerBytes, message.data.count <= maximumMessageBytes else { return nil }
        let count = min(message.data.count - message.offset, maximumValueBytes - headerBytes)
        let total = UInt16(message.data.count)
        let offset = UInt16(message.offset)
        let id = message.id
        var result = Data([
            0x50, 0x50, 0x02, 0x00,
            UInt8((id >> 24) & 0xff), UInt8((id >> 16) & 0xff),
            UInt8((id >> 8) & 0xff), UInt8(id & 0xff),
            UInt8((total >> 8) & 0xff), UInt8(total & 0xff),
            UInt8((offset >> 8) & 0xff), UInt8(offset & 0xff)
        ])
        result.append(message.data.subdata(in: message.offset..<(message.offset + count)))
        return Encoded(data: result, payloadBytes: count)
    }
}

struct BLEOutboundMessage {
    let id: UInt32
    let data: Data
    var offset = 0
    let priority: Int
}

struct BLEOutbox {
    var messages: [BLEOutboundMessage] = []
    var byteCount = 0
    var waitingForCapacity = false

    mutating func enqueue(_ data: Data, id: UInt32, priority: Int, protectCurrent: Bool = false) {
        // Data slices may keep a nonzero startIndex. Frames use byte offsets
        // relative to zero, so materialize a normalized Data value first.
        let message = BLEOutboundMessage(id: id, data: Data(data), priority: priority)
        // Finish any already-started frame stream, then select the highest-priority packet.
        let protected = ((messages.first?.offset ?? 0) > 0 || protectCurrent) && !messages.isEmpty ? 1 : 0
        let index = messages.indices.dropFirst(protected).first { messages[$0].priority < priority } ?? messages.count
        messages.insert(message, at: index)
        byteCount += data.count
    }

    func nextFragment(maximumValueBytes: Int) -> BLEFragment.Encoded? {
        guard let message = messages.first else { return nil }
        return BLEFragment.encode(message, maximumValueBytes: maximumValueBytes)
    }

    /// Returns a single retry signal when a completed stream relieves queue pressure.
    @discardableResult mutating func consume(payloadBytes: Int) -> Bool {
        guard !messages.isEmpty else { return false }
        messages[0].offset += payloadBytes
        if messages[0].offset == messages[0].data.count {
            byteCount -= messages.removeFirst().data.count
            let notify = waitingForCapacity
            waitingForCapacity = false
            return notify
        }
        return false
    }
}

struct BLEReassembler {
    private var messageID: UInt32?
    private var totalBytes = 0
    private var bytes = Data()
    private var lastUpdate: TimeInterval = 0

    enum Failure: Error { case malformed, tooLarge, sequence }

    mutating func append(_ value: Data) throws -> Data? {
        guard value.count >= BLEFragment.headerBytes else { throw Failure.malformed }
        let header = Array(value.prefix(BLEFragment.headerBytes))
        guard header[0] == 0x50, header[1] == 0x50, header[2] == 2, header[3] == 0 else {
            throw Failure.malformed
        }
        let id = UInt32(header[4]) << 24 | UInt32(header[5]) << 16
            | UInt32(header[6]) << 8 | UInt32(header[7])
        let total = Int(header[8]) << 8 | Int(header[9])
        let offset = Int(header[10]) << 8 | Int(header[11])
        let payload = value.dropFirst(BLEFragment.headerBytes)
        guard total <= BLEFragment.maximumMessageBytes else { throw Failure.tooLarge }
        guard id != 0, offset <= total, payload.count <= total - offset,
              total == 0 ? (offset == 0 && payload.isEmpty) : !payload.isEmpty else { throw Failure.malformed }
        if offset == 0 {
            // New messages recover from an abandoned partial notification; app
            // IDs/receipts decide whether the previous message needs retrying.
            messageID = id
            totalBytes = total
            bytes = Data()
            bytes.reserveCapacity(total)
        }
        guard messageID == id, totalBytes == total, bytes.count == offset else { throw Failure.sequence }
        bytes.append(contentsOf: payload)
        lastUpdate = Date().timeIntervalSinceReferenceDate
        guard bytes.count == total else { return nil }
        let complete = bytes
        self = BLEReassembler()
        return complete
    }

    mutating func discardIfInactive(before cutoff: TimeInterval) -> Bool {
        guard messageID != nil, lastUpdate < cutoff else { return false }
        self = BLEReassembler()
        return true
    }
}
