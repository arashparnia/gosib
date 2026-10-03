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
