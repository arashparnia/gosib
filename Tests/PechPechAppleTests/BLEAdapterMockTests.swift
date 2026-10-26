#if PECHPECH_MOCK_BLUETOOTH
import Foundation
import XCTest
import CoreBluetooth
@testable import PechPechApple

/// Runs the real BLEPacketLink callbacks against a Linux API double. These tests
/// establish adapter state-machine behavior, not Apple SDK or radio behavior.
final class BLEAdapterMockTests: XCTestCase {
    private let serviceUUID = CBUUID(string: "89B515C0-7D3F-4BD9-AC0B-6EC466823C62")
    private let messageUUID = CBUUID(string: "89B515C1-7D3F-4BD9-AC0B-6EC466823C62")

    override func setUp() {
        super.setUp()
        CBCentralManager.mockReset(); CBPeripheralManager.mockReset()
    }

    @MainActor private func start(_ link: BLEPacketLink) throws -> (CBCentralManager, CBPeripheralManager) {
        link.start(nodeName: "synthetic-mock-host")
        return (try XCTUnwrap(CBCentralManager.mockInstances.last), try XCTUnwrap(CBPeripheralManager.mockInstances.last))
    }

    @MainActor private func publish(_ manager: CBPeripheralManager) throws -> (CBMutableService, CBMutableCharacteristic) {
        manager.mockSetState(.poweredOn)
        let service = try XCTUnwrap(manager.mockAddedServices.last)
        let characteristic = try XCTUnwrap(service.characteristics?.first as? CBMutableCharacteristic)
        manager.mockDidAdd(service); manager.mockDidStartAdvertising()
        return (service, characteristic)
    }

    @MainActor private func connect(_ manager: CBCentralManager) throws -> (CBPeripheral, CBMutableCharacteristic, String) {
        manager.mockSetState(.poweredOn)
        let peripheral = CBPeripheral(name: "synthetic-neighbor")
        manager.mockDiscover(peripheral, advertisementData: [CBAdvertisementDataLocalNameKey: "synthetic-neighbor"])
        XCTAssertTrue(manager.mockConnections.contains { $0 === peripheral })
        manager.mockDidConnect(peripheral)
        let service = CBMutableService(type: serviceUUID, primary: true)
        let characteristic = CBMutableCharacteristic(type: messageUUID, properties: [.write, .notify],
                                                       value: nil, permissions: [.writeable])
        service.characteristics = [characteristic]; peripheral.services = [service]
        peripheral.mockDidDiscoverServices(); peripheral.mockDidDiscoverCharacteristics(service)
        XCTAssertTrue(peripheral.mockNotifyRequests.contains { $0.enabled && $0.characteristic === characteristic })
        peripheral.mockNotificationState(characteristic, isNotifying: true)
        return (peripheral, characteristic, "c:" + peripheral.identifier.uuidString)
    }

    private func fragment(_ payload: Data, id: UInt32) throws -> Data {
        try XCTUnwrap(BLEFragment.encode(BLEOutboundMessage(id: id, data: payload, priority: 1), maximumValueBytes: 20)).data
    }

    @MainActor func testPowerCallbacksStartScanningAndPublishOneFreshService() async throws {
        let link = BLEPacketLink()
        defer { link.stop() }
        let (central, peripheral) = try start(link)
        XCTAssertTrue(link.hasRadioManagers)
        XCTAssertTrue(central.mockScans.isEmpty); XCTAssertTrue(peripheral.mockAddedServices.isEmpty)
        central.mockSetState(.poweredOn)
        XCTAssertEqual(central.mockScans.count, 1)
        XCTAssertEqual(central.mockScans.first?.services, [serviceUUID])
        let (service, characteristic) = try publish(peripheral)
        XCTAssertEqual(service.uuid, serviceUUID); XCTAssertEqual(characteristic.uuid, messageUUID)
        XCTAssertEqual(peripheral.mockAddedServices.count, 1)
        XCTAssertEqual(peripheral.mockAdvertisingCalls.count, 1)
        central.mockSetState(.poweredOn); peripheral.mockSetState(.poweredOn)
        XCTAssertEqual(central.mockScans.count, 1)
        XCTAssertEqual(peripheral.mockAddedServices.count, 1)
        XCTAssertEqual(peripheral.mockAdvertisingCalls.count, 1)
    }

    @MainActor func testWriteResponseQueueBackpressureSignalsOneRetryAndPreservesFragments() async throws {
        let link = BLEPacketLink()
        defer { link.onWorkAvailable = nil; link.stop() }
        let (central, _) = try start(link)
        let (remote, characteristic, peerID) = try connect(central)
        for index in 0..<32 { XCTAssertTrue(link.send(Data([UInt8(index)]), to: peerID)) }
        XCTAssertEqual(remote.mockWrites.count, 1, "With-response writes must wait for the current fragment's response.")
        XCTAssertFalse(link.send(Data([99]), to: peerID))
        var opportunities = 0
        link.onWorkAvailable = {
            opportunities += 1
            XCTAssertTrue(link.send(Data([99]), to: peerID), "A completed queued message must expose its freed slot.")
        }
        remote.mockDidWrite(characteristic)
        XCTAssertEqual(opportunities, 1)
        for _ in 0..<32 { remote.mockDidWrite(characteristic) }
        XCTAssertEqual(opportunities, 1)
        XCTAssertEqual(remote.mockWrites.count, 33)
        var reassembler = BLEReassembler(), received: [Data] = []
        for write in remote.mockWrites {
            XCTAssertEqual(write.type, .withResponse)
            if let value = try reassembler.append(write.data) { received.append(value) }
        }
        XCTAssertEqual(received, (0..<32).map { Data([UInt8($0)]) } + [Data([99])])
    }

    @MainActor func testInvalidWriteBatchDoesNotPartiallyDeliverOrAdvanceReassembly() async throws {
        let link = BLEPacketLink()
        defer { link.stop() }
        let (_, peripheral) = try start(link)
        let (_, characteristic) = try publish(peripheral)
        let central = CBCentral()
        peripheral.mockSubscribe(central, to: characteristic)
        let payload = Data([4, 5, 6]), bytes = try fragment(payload, id: 1)
        let valid = CBATTRequest(central: central, characteristic: characteristic, value: bytes)
        let foreign = CBMutableCharacteristic(type: CBUUID(string: "00000000-0000-0000-0000-000000000001"),
                                               properties: [.write], value: nil, permissions: [.writeable])
        let invalid = CBATTRequest(central: central, characteristic: foreign, value: bytes)
        var received: [Data] = []
        link.onMessage = { bytes, _ in received.append(bytes) }
        peripheral.mockReceiveWrite([valid, invalid])
        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(peripheral.mockResponses.count, 1)
        XCTAssertTrue(peripheral.mockResponses.first?.request === valid)
        XCTAssertEqual(peripheral.mockResponses.first?.result, .requestNotSupported)
        peripheral.mockReceiveWrite([valid])
        XCTAssertEqual(received, [payload])
        XCTAssertEqual(peripheral.mockResponses.count, 2)
        XCTAssertEqual(peripheral.mockResponses.last?.result, .success)
    }

    @MainActor func testCallbacksFromReplacedManagersCannotCreatePeersInNewSession() async throws {
        let link = BLEPacketLink()
        defer { link.stop() }
        let (oldCentral, oldPeripheral) = try start(link)
        let (_, oldCharacteristic) = try publish(oldPeripheral)
        link.stop()
        let (currentCentral, currentPeripheral) = try start(link)
        var ready: [String] = []
        link.onLinkReady = { ready.append($0) }
        let restored = CBPeripheral(name: "stale-neighbor")
        link.centralManager(oldCentral, didDiscover: restored, advertisementData: [:], rssi: -40)
        link.centralManager(oldCentral, didConnect: restored)
        link.peripheralManager(oldPeripheral, central: CBCentral(), didSubscribeTo: oldCharacteristic)
        XCTAssertTrue(ready.isEmpty)
        XCTAssertTrue(currentCentral.mockConnections.isEmpty)
        XCTAssertTrue(currentPeripheral.mockAddedServices.isEmpty)
        XCTAssertFalse(link.send(Data([1]), to: "c:" + restored.identifier.uuidString))
    }

    @MainActor func testRestoredConnectedClientWaitsForActualDisconnectAndFreshNotificationChannel() async throws {
        let configuration = try BLERestorationConfiguration(centralIdentifier: "tests.mock.central",
                                                             peripheralIdentifier: "tests.mock.peripheral")
        let link = BLEPacketLink(restoration: configuration)
        defer { link.stop() }
        let (central, peripheralManager) = try start(link)
        XCTAssertEqual(central.mockOptions?[CBCentralManagerOptionRestoreIdentifierKey] as? String, configuration.centralIdentifier)
        XCTAssertEqual(peripheralManager.mockOptions?[CBPeripheralManagerOptionRestoreIdentifierKey] as? String,
                       configuration.peripheralIdentifier)
        let restored = CBPeripheral(name: "restored-synthetic-neighbor")
        restored.state = .connected
        let oldCharacteristic = CBMutableCharacteristic(type: messageUUID, properties: [.write, .notify],
                                                          value: nil, permissions: [.writeable])
        oldCharacteristic.isNotifying = true
        let oldService = CBMutableService(type: serviceUUID, primary: true)
        oldService.characteristics = [oldCharacteristic]
        var ready: [String] = []
        link.onLinkReady = { ready.append($0) }
        central.mockRestore([CBCentralManagerRestoredStatePeripheralsKey: [restored]])
        central.mockSetState(.unknown)
        XCTAssertTrue(central.mockCancellations.isEmpty); XCTAssertTrue(central.mockConnections.isEmpty)
        central.mockSetState(.poweredOn)
        XCTAssertEqual(central.mockCancellations.count, 1)
        central.mockDidConnect(restored) // A late old connection callback is not a fresh session.
        restored.mockNotificationState(oldCharacteristic, isNotifying: true)
        central.mockSetState(.poweredOn)
        XCTAssertTrue(ready.isEmpty)
        XCTAssertTrue(restored.mockServiceDiscoveries.isEmpty)
        XCTAssertTrue(central.mockConnections.isEmpty)
        XCTAssertEqual(central.mockCancellations.count, 1)
        XCTAssertFalse(link.send(Data([1]), to: "c:" + restored.identifier.uuidString))
        central.mockDidDisconnect(restored)
        XCTAssertEqual(central.mockConnections.count, 1, "The disconnect callback must schedule reconnection without a timer.")
        central.mockDidConnect(restored)
        XCTAssertEqual(restored.mockServiceDiscoveries.count, 1)
        let freshService = CBMutableService(type: serviceUUID, primary: true)
        let freshCharacteristic = CBMutableCharacteristic(type: messageUUID, properties: [.write, .notify],
                                                            value: nil, permissions: [.writeable])
        freshService.characteristics = [freshCharacteristic]; restored.services = [freshService]
        restored.mockDidDiscoverServices()
        restored.mockDidDiscoverCharacteristics(oldService)
        restored.mockNotificationState(oldCharacteristic, isNotifying: true)
        XCTAssertTrue(ready.isEmpty, "A stale same-UUID service callback must not replace the selected fresh service.")
        restored.mockDidDiscoverCharacteristics(freshService)
        restored.mockNotificationState(oldCharacteristic, isNotifying: true)
        XCTAssertTrue(ready.isEmpty, "An old characteristic with the same UUID must not establish the new channel.")
        restored.mockNotificationState(freshCharacteristic, isNotifying: true)
        XCTAssertEqual(ready, ["c:" + restored.identifier.uuidString])
        XCTAssertTrue(link.send(Data([2]), to: ready[0]))
    }

    @MainActor func testRestoredServerRepublishesFreshObjectsBeforeAcceptingSubscriptionsOrWrites() async throws {
        let configuration = try BLERestorationConfiguration(centralIdentifier: "tests.mock.server.central",
                                                             peripheralIdentifier: "tests.mock.server.peripheral")
        let link = BLEPacketLink(restoration: configuration)
        defer { link.stop() }
        let (_, manager) = try start(link)
        let oldService = CBMutableService(type: serviceUUID, primary: true)
        let oldCharacteristic = CBMutableCharacteristic(type: messageUUID, properties: [.write, .notify],
                                                          value: nil, permissions: [.writeable])
        let subscriber = CBCentral()
        oldCharacteristic.subscribedCentrals = [subscriber]; oldService.characteristics = [oldCharacteristic]
        manager.mockRestore([CBPeripheralManagerRestoredStateServicesKey: [oldService]])
        manager.mockSetState(.unknown)
        XCTAssertEqual(manager.mockRemoveAllServicesCalls, 0, "GATT reset must wait until the manager is powered on.")
        manager.mockSetState(.poweredOn)
        let freshService = try XCTUnwrap(manager.mockAddedServices.last)
        let freshCharacteristic = try XCTUnwrap(freshService.characteristics?.first as? CBMutableCharacteristic)
        XCTAssertFalse(freshService === oldService); XCTAssertFalse(freshCharacteristic === oldCharacteristic)
        XCTAssertEqual(manager.mockRemoveAllServicesCalls, 1)
        var ready: [String] = [], disconnected: [String] = [], received: [Data] = []
        link.onLinkReady = { ready.append($0) }; link.onDisconnected = { disconnected.append($0) }
        link.onMessage = { bytes, _ in received.append(bytes) }
        manager.mockSubscribe(subscriber, to: freshCharacteristic)
        XCTAssertTrue(ready.isEmpty, "A pending service registration cannot admit a subscriber.")
        link.peripheralManager(manager, didAdd: oldService, error: nil)
        XCTAssertTrue(manager.mockAdvertisingCalls.isEmpty)
        manager.mockDidAdd(freshService); manager.mockDidStartAdvertising()
        manager.mockSubscribe(subscriber, to: oldCharacteristic)
        XCTAssertTrue(ready.isEmpty)
        let payload = Data([8, 9]), bytes = try fragment(payload, id: 7)
        manager.mockReceiveWrite([CBATTRequest(central: subscriber, characteristic: oldCharacteristic, value: bytes)])
        XCTAssertEqual(manager.mockResponses.last?.result, .requestNotSupported)
        XCTAssertTrue(received.isEmpty)
        manager.mockSubscribe(subscriber, to: freshCharacteristic)
        XCTAssertEqual(ready, ["p:" + subscriber.identifier.uuidString])
        manager.mockUnsubscribe(subscriber, from: oldCharacteristic)
        XCTAssertTrue(disconnected.isEmpty)
        manager.mockReceiveWrite([CBATTRequest(central: subscriber, characteristic: freshCharacteristic, value: bytes)])
        XCTAssertEqual(received, [payload]); XCTAssertEqual(manager.mockResponses.last?.result, .success)
        XCTAssertTrue(link.send(Data([3]), to: ready[0]))
        XCTAssertTrue(manager.mockUpdates.last?.characteristic === freshCharacteristic)
    }

    @MainActor func testRestoredOverflowIsHiddenAndCanceledWhenPowerBecomesAvailable() async throws {
        let configuration = try BLERestorationConfiguration(centralIdentifier: "tests.mock.limit.central",
                                                             peripheralIdentifier: "tests.mock.limit.peripheral")
        let link = BLEPacketLink(restoration: configuration)
        defer { link.stop() }
        let (manager, _) = try start(link)
        let restored = (0..<5).map { CBPeripheral(name: "restored-overflow-\($0)") }
        restored.forEach { $0.state = .connected }
        var peers: [String] = [], ready: [String] = []
        link.onPeers = { peers = $0.map(\.id) }; link.onLinkReady = { ready.append($0) }
        manager.mockRestore([CBCentralManagerRestoredStatePeripheralsKey: restored])
        XCTAssertEqual(Set(peers), Set(restored.prefix(4).map { "c:" + $0.identifier.uuidString }))
        XCTAssertTrue(manager.mockCancellations.isEmpty)
        manager.mockSetState(.poweredOn)
        XCTAssertEqual(Set(manager.mockCancellations.map(\.identifier)), Set(restored.map(\.identifier)))
        XCTAssertTrue(manager.mockConnections.isEmpty); XCTAssertTrue(ready.isEmpty)
        manager.mockDidDisconnect(try XCTUnwrap(restored.last))
        XCTAssertTrue(manager.mockConnections.isEmpty, "Overflow handles exist only for cleanup and must not become routing candidates.")
        for retained in restored.prefix(4) { manager.mockDidDisconnect(retained) }
        XCTAssertEqual(Set(manager.mockConnections.map(\.identifier)), Set(restored.prefix(4).map(\.identifier)))
    }

    @MainActor func testInitiallyDisconnectedRestoredClientCanReconnectWithoutCancellationOrTimer() async throws {
        let configuration = try BLERestorationConfiguration(centralIdentifier: "tests.mock.idle.central",
                                                             peripheralIdentifier: "tests.mock.idle.peripheral")
        let link = BLEPacketLink(restoration: configuration)
        defer { link.stop() }
        let (manager, _) = try start(link)
        manager.mockSetState(.poweredOn)
        let restored = CBPeripheral(name: "already-disconnected")
        manager.mockRestore([CBCentralManagerRestoredStatePeripheralsKey: [restored]])
        XCTAssertEqual(manager.mockConnections.map(\.identifier), [restored.identifier])
        XCTAssertTrue(manager.mockCancellations.isEmpty)
        XCTAssertFalse(link.send(Data([1]), to: "c:" + restored.identifier.uuidString),
                       "Scheduling a fresh connection must not report the channel ready before service/notification discovery.")
    }

    @MainActor func testRestoredDisconnectedHandleThatConnectsBeforePowerMustBeResetBeforeAdoption() async throws {
        let configuration = try BLERestorationConfiguration(centralIdentifier: "tests.mock.race.central",
                                                             peripheralIdentifier: "tests.mock.race.peripheral")
        let link = BLEPacketLink(restoration: configuration)
        defer { link.stop() }
        let (manager, _) = try start(link)
        let restored = CBPeripheral(name: "restored-state-race")
        manager.mockRestore([CBCentralManagerRestoredStatePeripheralsKey: [restored]])
        XCTAssertTrue(manager.mockConnections.isEmpty)
        restored.state = .connected // The OS advances the restored handle before its power callback.
        manager.mockSetState(.poweredOn)
        XCTAssertEqual(manager.mockCancellations.map(\.identifier), [restored.identifier])
        XCTAssertTrue(manager.mockConnections.isEmpty)
        manager.mockDidConnect(restored)
        XCTAssertTrue(restored.mockServiceDiscoveries.isEmpty, "An old OS connection must not be adopted as an SDK-requested fresh session.")
        XCTAssertFalse(link.send(Data([1]), to: "c:" + restored.identifier.uuidString))
        manager.mockDidDisconnect(restored)
        XCTAssertEqual(manager.mockConnections.map(\.identifier), [restored.identifier])
        manager.mockDidConnect(restored)
        XCTAssertEqual(restored.mockServiceDiscoveries.count, 1)
    }

    @MainActor func testRestoredFreshConnectInterruptedBeforeDidConnectCanRetryAfterBackoff() async throws {
        let configuration = try BLERestorationConfiguration(centralIdentifier: "tests.mock.interrupted.central",
                                                             peripheralIdentifier: "tests.mock.interrupted.peripheral")
        let link = BLEPacketLink(restoration: configuration)
        defer { link.stop() }
        let (manager, _) = try start(link)
        manager.mockSetState(.poweredOn)
        let restored = CBPeripheral(name: "interrupted-restored-connect")
        var ready: [String] = []
        link.onLinkReady = { ready.append($0) }
        manager.mockRestore([CBCentralManagerRestoredStatePeripheralsKey: [restored]])
        XCTAssertEqual(manager.mockConnections.count, 1)
        manager.mockDidDisconnect(restored)
        XCTAssertEqual(manager.mockConnections.count, 1, "A failed fresh attempt must observe bounded retry backoff.")
        try await Task.sleep(for: .milliseconds(1_100))
        manager.mockSetState(.poweredOn)
        XCTAssertGreaterThanOrEqual(manager.mockConnections.count, 2,
                                    "Disconnect before didConnect must release the restoration request phase for retry.")
        manager.mockDidConnect(restored)
        let service = CBMutableService(type: serviceUUID, primary: true)
        let characteristic = CBMutableCharacteristic(type: messageUUID, properties: [.write, .notify],
                                                       value: nil, permissions: [.writeable])
        service.characteristics = [characteristic]; restored.services = [service]
        restored.mockDidDiscoverServices(); restored.mockDidDiscoverCharacteristics(service)
        restored.mockNotificationState(characteristic, isNotifying: true)
        XCTAssertEqual(ready, ["c:" + restored.identifier.uuidString])
    }

    @MainActor func testStopFromRestorationCallbackCannotStartAReplacementConnection() async throws {
        let configuration = try BLERestorationConfiguration(centralIdentifier: "tests.mock.stop.central",
                                                             peripheralIdentifier: "tests.mock.stop.peripheral")
        let link = BLEPacketLink(restoration: configuration)
        defer { link.onState = nil; link.stop() }
        let (central, _) = try start(link)
        central.mockSetState(.poweredOn)
        let restored = CBPeripheral(name: "restored-stop-test")
        restored.state = .connected
        link.onState = { state in if state.contains("restoring bounded connections") { link.stop() } }
        central.mockRestore([CBCentralManagerRestoredStatePeripheralsKey: [restored]])
        XCTAssertFalse(link.running)
        XCTAssertFalse(link.hasRadioManagers)
        XCTAssertTrue(central.mockConnections.isEmpty)
    }
}
#endif
