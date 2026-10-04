import Foundation

/// Stream framing. Retained decoder storage is at most a 4-byte header plus one 16-KiB body.
/// Callers must bound network read chunks and consume completed frames promptly.
public struct LengthFramer: Sendable {
    public static let maximumPayloadBytes = 16_384
    private var prefix = Data()
    private var expectedLength: Int?
    private var payload = Data()

    public init() {}

    public static func frame(_ data: Data) throws -> Data {
        guard data.count <= maximumPayloadBytes else { throw PechPechError.frameTooLarge(data.count) }
        let length = UInt32(data.count)
        return Data([
            UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff), UInt8(length & 0xff)
        ]) + data
    }

    public mutating func append(_ bytes: Data) throws -> [Data] {
        var frames: [Data] = []
        var offset = bytes.startIndex
        do {
            while offset < bytes.endIndex {
                if expectedLength == nil {
                    let count = Swift.min(4 - prefix.count, bytes.endIndex - offset)
                    prefix.append(bytes[offset ..< offset + count])
                    offset += count
                    guard prefix.count == 4 else { break }
                    let length = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    guard length <= UInt32(Self.maximumPayloadBytes) else {
                        throw PechPechError.frameTooLarge(Int(length))
                    }
                    prefix.removeAll(keepingCapacity: true)
                    expectedLength = Int(length)
                    if length == 0 {
                        frames.append(Data())
                        expectedLength = nil
                        continue
                    }
                }
                if let length = expectedLength {
                    let count = Swift.min(length - payload.count, bytes.endIndex - offset)
                    payload.append(bytes[offset ..< offset + count])
                    offset += count
                    if payload.count == length {
                        frames.append(payload)
                        payload = Data()
                        expectedLength = nil
                    }
                }
            }
            return frames
        } catch {
            prefix = Data()
            payload = Data()
            expectedLength = nil
            throw error
        }
    }

    var bufferedByteCount: Int { prefix.count + payload.count }
}
