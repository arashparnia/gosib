import Foundation
import XCTest
@testable import GosibCore

final class FramingTests: XCTestCase {
    func testFragmentedConcatenatedFramesAtBoundarySizes() throws {
        let messages = [Data(), Data([0]), Data((0..<257).map { UInt8($0 % 251) }), Data(repeating: 7, count: 16_384)]
        let stream = try messages.reduce(into: Data()) { $0.append(try LengthFramer.frame($1)) }
        for chunkSize in [1, 2, 3, 4, 7, 31, 255, 512, 16_384] {
            var decoder = LengthFramer(), decoded: [Data] = []
            var offset = 0
            while offset < stream.count {
                decoded += try decoder.append(Data(stream[offset..<min(offset + chunkSize, stream.count)]))
                XCTAssertLessThanOrEqual(decoder.bufferedByteCount, 16_388)
                offset += chunkSize
            }
            XCTAssertEqual(decoded, messages)
            XCTAssertEqual(decoder.bufferedByteCount, 0)
        }
    }

    func testSlicedDataWithNonzeroIndexAndResetAfterMalformedLength() throws {
        let payload = Data((0..<100).map(UInt8.init))[10..<90]
        let framed = try LengthFramer.frame(payload)
        var prefix = Data([8, 8, 8]); prefix.append(framed)
        var decoder = LengthFramer()
        XCTAssertEqual(try decoder.append(prefix[3..<prefix.count]), [Data(payload)])
        XCTAssertThrowsError(try decoder.append(Data([0, 0, 0x40, 1])))
        XCTAssertEqual(decoder.bufferedByteCount, 0)
        XCTAssertEqual(try decoder.append(framed), [Data(payload)])
        XCTAssertThrowsError(try decoder.append(Data([255, 255, 255, 255])))
        XCTAssertEqual(decoder.bufferedByteCount, 0)
        XCTAssertThrowsError(try LengthFramer.frame(Data(repeating: 1, count: 16_385)))
    }
}
