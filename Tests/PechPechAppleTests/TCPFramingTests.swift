import Foundation
import XCTest
@testable import PechPechApple

final class TCPFramingTests: XCTestCase {
    func testBigEndianLengthAndPayloadBoundaries() throws {
        for count in [1, 255, 256, 1024, 16_383, 16_384] {
            let payload = Data((0..<count).map { UInt8($0 % 251) })
            let frame = try XCTUnwrap(LengthPrefixedFrame.encode(payload))
            XCTAssertEqual(LengthPrefixedFrame.payloadLength(Data(frame.prefix(4))), count)
            XCTAssertEqual(Data(frame.dropFirst(4)), payload)
        }
        XCTAssertEqual(LengthPrefixedFrame.encode(Data(repeating: 1, count: 256))?.prefix(4), Data([0, 0, 1, 0]))
    }

    func testMalformedAndOversizedLengthRejection() {
        XCTAssertNil(LengthPrefixedFrame.encode(Data()))
        XCTAssertNil(LengthPrefixedFrame.encode(Data(repeating: 0, count: 16_385)))
        for header in [Data(), Data([0, 0, 1]), Data([0, 0, 0, 0]), Data([0, 0, 64, 1]),
                       Data([255, 255, 255, 255]), Data([0, 0, 0, 1, 0])] {
            XCTAssertNil(LengthPrefixedFrame.payloadLength(header))
        }
    }

    #if canImport(CryptoKit)
    func testDiscoveryNamesAreBoundedDeterministicAndDoNotCollapseCommonPrefixes() {
        let first = DiscoveryName.make(from: "my-app-instance-alpha")
        let second = DiscoveryName.make(from: "my-app-instance-beta")
        XCTAssertEqual(first.utf8.count, 23)
        XCTAssertTrue(first.hasPrefix("PP-"))
        XCTAssertEqual(DiscoveryName.make(from: "my-app-instance-alpha"), first)
        XCTAssertNotEqual(first, second)
    }
    #endif
}
