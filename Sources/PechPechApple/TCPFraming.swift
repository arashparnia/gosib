import Foundation

/// Four-byte big-endian length prefix. No cryptographic or receipt semantics.
enum LengthPrefixedFrame {
    static let maximumPayloadBytes = 16_384
    static func encode(_ payload: Data) -> Data? {
        guard !payload.isEmpty, payload.count <= maximumPayloadBytes else { return nil }
        let length = UInt32(payload.count)
        var frame = Data([
            UInt8((length >> 24) & 255), UInt8((length >> 16) & 255),
            UInt8((length >> 8) & 255), UInt8(length & 255)
        ])
        frame.append(payload)
        return frame
    }
    static func payloadLength(_ header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= UInt32(maximumPayloadBytes) else { return nil }
        return Int(length)
    }
}

/// Known discoveries remain eligible when a connection slot becomes available.
/// Incoming connections occupy slots too, even though they have no discovery entry.
enum TCPConnectionCandidates {
    static func select(known: Set<String>, connected: Set<String>, retrying: Set<String>,
                       maximumConnections: Int = 4) -> [String] {
        let available = max(0, maximumConnections - connected.count)
        return Array(known.subtracting(connected).subtracting(retrying).sorted().prefix(available))
    }
}

/// Notify once when enough capacity returns for a previously refused complete frame.
struct TCPWriteBackpressure {
    private var smallestRefusedFrame: Int?

    mutating func refused(frameBytes: Int) {
        smallestRefusedFrame = min(smallestRefusedFrame ?? frameBytes, frameBytes)
    }

    mutating func didDrain(queuedBytes: Int, maximumQueuedBytes: Int) -> Bool {
        guard let frameBytes = smallestRefusedFrame,
              queuedBytes <= maximumQueuedBytes - frameBytes else { return false }
        smallestRefusedFrame = nil
        return true
    }
}

/// Failed listeners are replaced with one bounded-backoff attempt at a time.
struct TCPListenerBackoff {
    private var attempt = 0
    mutating func nextDelay() -> TimeInterval {
        attempt = min(attempt + 1, 6)
        return Double(min(1 << (attempt - 1), 30))
    }
    mutating func reset() { attempt = 0 }
}
