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

    func testKnownDiscoveriesFillFreedSlotsWithoutAnotherDiscoveryEvent() {
        let known: Set<String> = ["peer-a", "peer-b", "peer-c", "peer-d", "peer-e", "peer-f"]
        var connected: Set<String> = ["peer-a", "peer-b", "peer-c", "incoming-1"]
        XCTAssertTrue(TCPConnectionCandidates.select(known: known, connected: connected, retrying: []).isEmpty)

        // An incoming connection ends without changing the Bonjour result set.
        connected.remove("incoming-1")
        XCTAssertEqual(TCPConnectionCandidates.select(known: known, connected: connected, retrying: []), ["peer-d"])

        // A failed outgoing peer waits for its backoff; another known peer can fill its slot.
        connected.remove("peer-a")
        XCTAssertEqual(TCPConnectionCandidates.select(known: known, connected: connected, retrying: ["peer-a"]),
                       ["peer-d", "peer-e"])
    }

    func testRetryThatExpiresWhileFullRemainsEligibleForLaterSlot() {
        let known: Set<String> = ["peer-a", "peer-b", "peer-c", "peer-d", "peer-e"]
        var connected: Set<String> = ["peer-b", "peer-c", "peer-d", "peer-e"]
        XCTAssertTrue(TCPConnectionCandidates.select(known: known, connected: connected, retrying: ["peer-a"]).isEmpty)
        // Removing the expired backoff does not create a fifth connection.
        XCTAssertTrue(TCPConnectionCandidates.select(known: known, connected: connected, retrying: []).isEmpty)
        connected.remove("peer-e")
        XCTAssertEqual(TCPConnectionCandidates.select(known: known, connected: connected, retrying: []), ["peer-a"])
    }

    #if canImport(Network)
    @MainActor func testStopFromInitialPeerNotificationCancelsStartBeforeNativeLinks() {
        let link = TCPPacketLink()
        defer { link.onPeers = nil; link.stop() }
        var notifications = 0
        link.onPeers = { _ in
            notifications += 1
            link.stop()
        }
        link.start(nodeName: "synthetic-lifecycle-test")
        XCTAssertEqual(notifications, 1)
        XCTAssertFalse(link.running, "An explicit stop during startup must prevent the listener and browser from starting.")
        link.stop()
        XCTAssertEqual(notifications, 1, "An already stopped adapter must not recursively announce another stop.")
    }
    #endif

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
