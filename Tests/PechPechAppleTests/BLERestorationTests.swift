import Foundation
import XCTest
@testable import PechPechApple

/// Portable recovery policy checks. These do not instantiate native Bluetooth managers.
final class BLERestorationTests: XCTestCase {
    func testIdentifiersAreExplicitDistinctAndPreserved() throws {
        let configuration = try BLERestorationConfiguration(
            centralIdentifier: "com.example.host.pechpech.central",
            peripheralIdentifier: "com.example.host.pechpech.peripheral")
        XCTAssertEqual(configuration.centralIdentifier, "com.example.host.pechpech.central")
        XCTAssertEqual(configuration.peripheralIdentifier, "com.example.host.pechpech.peripheral")
        XCTAssertThrowsError(try BLERestorationConfiguration(centralIdentifier: "same", peripheralIdentifier: "same")) {
            XCTAssertEqual($0 as? BLERestorationConfiguration.Failure, .duplicateIdentifier)
        }
    }

    func testInvalidIdentifierValidationPrecedesNativeManagerCreation() {
        for identifier in ["", " \n\t", "com.example\0central", String(repeating: "a", count: 1_025),
                           String(repeating: "é", count: 513)] {
            XCTAssertThrowsError(try BLERestorationConfiguration(centralIdentifier: identifier, peripheralIdentifier: "host.peripheral")) {
                XCTAssertEqual($0 as? BLERestorationConfiguration.Failure, .invalidIdentifier)
            }
            XCTAssertThrowsError(try BLERestorationConfiguration(centralIdentifier: "host.central", peripheralIdentifier: identifier)) {
                XCTAssertEqual($0 as? BLERestorationConfiguration.Failure, .invalidIdentifier)
            }
        }
    }

    func testRestoredActiveAndPendingConnectionsWaitForObservedDisconnect() {
        for state: BLERestoredConnectionRecovery.State in [.connecting, .connected, .disconnecting] {
            var recovery = BLERestoredConnectionRecovery(state: state)
            XCTAssertFalse(recovery.canReconnect)
            XCTAssertTrue(recovery.requestCancellation())
            XCTAssertEqual(recovery.phase, .waitingForDisconnect)
            XCTAssertFalse(recovery.canReconnect, "Requesting cancellation does not establish a fresh transport session.")
            XCTAssertFalse(recovery.requestCancellation(), "Repeated wake events must not repeat the cancellation request.")
            recovery.didDisconnect()
            XCTAssertTrue(recovery.canReconnect)
            XCTAssertFalse(recovery.requestCancellation())
            XCTAssertFalse(recovery.freshConnectionRequested)
            XCTAssertTrue(recovery.requestFreshConnection())
            XCTAssertTrue(recovery.freshConnectionRequested)
            XCTAssertFalse(recovery.requestFreshConnection(), "An OS-managed request must not be duplicated.")
        }
    }

    func testAlreadyDisconnectedRestorationCanQueueFreshConnectionImmediately() {
        var recovery = BLERestoredConnectionRecovery(state: .disconnected)
        XCTAssertTrue(recovery.canReconnect)
        XCTAssertFalse(recovery.requestCancellation(), "There is no old connection whose callback must be awaited.")
        XCTAssertFalse(recovery.freshConnectionRequested)
        XCTAssertTrue(recovery.requestFreshConnection())
        XCTAssertTrue(recovery.freshConnectionRequested)
    }

    func testRestoredDisconnectedHandleBecomingActiveBeforeFreshRequestIsQuarantinedAgain() {
        for state: BLERestoredConnectionRecovery.State in [.connecting, .connected, .disconnecting] {
            var recovery = BLERestoredConnectionRecovery(state: .disconnected)
            recovery.reconcile(state: state)
            XCTAssertFalse(recovery.canReconnect)
            XCTAssertFalse(recovery.freshConnectionRequested)
            XCTAssertFalse(recovery.requestFreshConnection())
            XCTAssertTrue(recovery.requestCancellation())
            recovery.didDisconnect()
            XCTAssertTrue(recovery.requestFreshConnection())
            recovery.reconcile(state: .connecting)
            XCTAssertTrue(recovery.freshConnectionRequested, "The SDK's own fresh request may progress normally.")
        }
    }

    func testRestoredPeerSelectionDeduplicatesAndRespectsRemainingCapacity() throws {
        let ids = (1...6).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
        XCTAssertEqual(BLERestorationSelection.peers([ids[0], ids[0]] + Array(ids.dropFirst()), capacity: 4), Array(ids.prefix(4)))
        XCTAssertEqual(BLERestorationSelection.peers(ids, capacity: 1), [ids[0]])
        XCTAssertTrue(BLERestorationSelection.peers(ids, capacity: 0).isEmpty)
        XCTAssertTrue(BLERestorationSelection.peers(ids, capacity: -1).isEmpty)
    }

    func testServiceResetWaitsForPowerAndIsConsumedBeforeFreshPublication() {
        var recovery = BLEPeripheralRestorationRecovery()
        XCTAssertFalse(recovery.beginReset(poweredOn: true))
        recovery.restored()
        XCTAssertFalse(recovery.beginReset(poweredOn: false))
        XCTAssertTrue(recovery.needsReset)
        XCTAssertTrue(recovery.beginReset(poweredOn: true))
        XCTAssertFalse(recovery.needsReset)
        XCTAssertFalse(recovery.beginReset(poweredOn: true), "Later state callbacks must not repeatedly destroy the fresh service.")
    }

    func testInitialUnknownMayPreserveRestorationButLaterUnknownInvalidatesHandles() {
        var power = BLECentralRestorationPowerPolicy()
        XCTAssertEqual(power.transition(to: .unknown), .preserveInitialRestoration)
        XCTAssertEqual(power.transition(to: .unknown), .preserveInitialRestoration)
        XCTAssertEqual(power.transition(to: .poweredOn), .poweredOn)
        XCTAssertEqual(power.transition(to: .unknown), .discardInvalidHandles)
    }

    func testPowerOffProvidesDisconnectBoundaryWithoutInventingADelegateCallback() {
        var power = BLECentralRestorationPowerPolicy()
        XCTAssertEqual(power.transition(to: .poweredOn), .poweredOn)
        XCTAssertEqual(power.transition(to: .poweredOff), .disconnected)
        XCTAssertEqual(power.transition(to: .poweredOn), .poweredOn)
        // A subsequent service reset must discard the old objects, not wait for a timer.
        XCTAssertEqual(power.transition(to: .invalidating), .discardInvalidHandles)
    }

    func testExplicitInvalidationEndsInitialUnknownException() {
        var power = BLECentralRestorationPowerPolicy()
        XCTAssertEqual(power.transition(to: .invalidating), .discardInvalidHandles)
        XCTAssertEqual(power.transition(to: .unknown), .discardInvalidHandles)
        XCTAssertEqual(power.transition(to: .poweredOn), .poweredOn)
    }

    #if canImport(CoreBluetooth)
    @MainActor func testOptInConstructionDoesNotStartManagers() async throws {
        let configuration = try BLERestorationConfiguration(centralIdentifier: "host.central", peripheralIdentifier: "host.peripheral")
        let link = BLEPacketLink(restoration: configuration)
        XCTAssertFalse(link.running)
        XCTAssertFalse(link.hasRadioManagers)
    }
    #endif
}
