// Development-only CoreBluetooth API double for Linux adapter state-machine tests.
// This module implements no radio, permissions, OS scheduling or real restoration.
// The shipping SwiftPM package never imports this file as a target.
import Foundation
import Dispatch

public let CBAdvertisementDataLocalNameKey = "CBAdvertisementDataLocalNameKey"
public let CBAdvertisementDataServiceUUIDsKey = "CBAdvertisementDataServiceUUIDsKey"
public let CBCentralManagerOptionRestoreIdentifierKey = "CBCentralManagerOptionRestoreIdentifierKey"
public let CBPeripheralManagerOptionRestoreIdentifierKey = "CBPeripheralManagerOptionRestoreIdentifierKey"
public let CBCentralManagerRestoredStatePeripheralsKey = "CBCentralManagerRestoredStatePeripheralsKey"
public let CBCentralManagerRestoredStateScanServicesKey = "CBCentralManagerRestoredStateScanServicesKey"
public let CBCentralManagerRestoredStateScanOptionsKey = "CBCentralManagerRestoredStateScanOptionsKey"
public let CBPeripheralManagerRestoredStateServicesKey = "CBPeripheralManagerRestoredStateServicesKey"
public let CBPeripheralManagerRestoredStateAdvertisementDataKey = "CBPeripheralManagerRestoredStateAdvertisementDataKey"

public enum CBManagerState: Int, Equatable, Sendable { case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn }
public enum CBPeripheralState: Int, Equatable, Sendable { case disconnected, connecting, connected, disconnecting }
public enum CBCharacteristicWriteType: Int, Equatable, Sendable { case withResponse, withoutResponse }
public enum CBATTError {
    public enum Code: Int, Equatable, Sendable {
        case success = 0, invalidHandle, readNotPermitted, writeNotPermitted, invalidPdu
        case insufficientAuthentication, requestNotSupported, invalidOffset, insufficientAuthorization
        case prepareQueueFull, attributeNotFound, attributeNotLong, insufficientEncryptionKeySize
        case invalidAttributeValueLength, unlikelyError, insufficientEncryption, unsupportedGroupType, insufficientResources
    }
}

public struct CBCharacteristicProperties: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let broadcast = Self(rawValue: 1 << 0)
    public static let read = Self(rawValue: 1 << 1)
    public static let writeWithoutResponse = Self(rawValue: 1 << 2)
    public static let write = Self(rawValue: 1 << 3)
    public static let notify = Self(rawValue: 1 << 4)
    public static let indicate = Self(rawValue: 1 << 5)
    public static let authenticatedSignedWrites = Self(rawValue: 1 << 6)
    public static let extendedProperties = Self(rawValue: 1 << 7)
    public static let notifyEncryptionRequired = Self(rawValue: 1 << 8)
    public static let indicateEncryptionRequired = Self(rawValue: 1 << 9)
}

public struct CBAttributePermissions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let readable = Self(rawValue: 1 << 0)
    public static let writeable = Self(rawValue: 1 << 1)
    public static let readEncryptionRequired = Self(rawValue: 1 << 2)
    public static let writeEncryptionRequired = Self(rawValue: 1 << 3)
}

public final class CBUUID: NSObject {
    public let uuidString: String
    public init(string: String) { uuidString = string.uppercased(); super.init() }
    public override func isEqual(_ object: Any?) -> Bool {
        (object as? CBUUID)?.uuidString == uuidString
    }
    public override var hash: Int { uuidString.hashValue }
}

open class CBService: NSObject {
    public let uuid: CBUUID
    public let isPrimary: Bool
    public var characteristics: [CBCharacteristic]?
    public init(type: CBUUID, primary: Bool) { uuid = type; isPrimary = primary; super.init() }
}
public final class CBMutableService: CBService {}

open class CBCharacteristic: NSObject {
    public let uuid: CBUUID
    public let properties: CBCharacteristicProperties
    public var value: Data?
    public var isNotifying = false
    public init(type: CBUUID, properties: CBCharacteristicProperties, value: Data?) {
        uuid = type; self.properties = properties; self.value = value; super.init()
    }
}
public final class CBMutableCharacteristic: CBCharacteristic {
    public let permissions: CBAttributePermissions
    public var subscribedCentrals: [CBCentral]?
    public init(type: CBUUID, properties: CBCharacteristicProperties, value: Data?, permissions: CBAttributePermissions) {
        self.permissions = permissions
        super.init(type: type, properties: properties, value: value)
    }
}

public final class CBCentral: NSObject {
    public let identifier: UUID
    public var maximumUpdateValueLength: Int
    public init(identifier: UUID = UUID(), maximumUpdateValueLength: Int = 20) {
        self.identifier = identifier; self.maximumUpdateValueLength = maximumUpdateValueLength; super.init()
    }
}

public final class CBATTRequest: NSObject {
    public let central: CBCentral
    public let characteristic: CBCharacteristic
    public let offset: Int
    public var value: Data?
    public init(central: CBCentral, characteristic: CBCharacteristic, offset: Int = 0, value: Data?) {
        self.central = central; self.characteristic = characteristic; self.offset = offset; self.value = value; super.init()
    }
}

public protocol CBCentralManagerDelegate: AnyObject {
    func centralManagerDidUpdateState(_ central: CBCentralManager)
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any])
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber)
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral)
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?)
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?)
}
public extension CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {}
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {}
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {}
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {}
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {}
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {}
}

public protocol CBPeripheralDelegate: AnyObject {
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral)
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService])
}
public extension CBPeripheralDelegate {
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {}
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {}
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {}
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {}
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {}
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {}
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {}
}

public protocol CBPeripheralManagerDelegate: AnyObject {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager)
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any])
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?)
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?)
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic)
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic)
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager)
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest])
}
public extension CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {}
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {}
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {}
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {}
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {}
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {}
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {}
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {}
}

public final class CBPeripheral: NSObject {
    public struct MockWrite {
        public let data: Data
        public let characteristic: CBCharacteristic
        public let type: CBCharacteristicWriteType
    }
    public let identifier: UUID
    public var name: String?
    public var state: CBPeripheralState = .disconnected
    public weak var delegate: (any CBPeripheralDelegate)?
    public var services: [CBService]?
    public var canSendWriteWithoutResponse = true
    public var mockMaximumWriteValueLength = 20
    public private(set) var mockServiceDiscoveries: [[CBUUID]?] = []
    public private(set) var mockCharacteristicDiscoveries: [(uuids: [CBUUID]?, service: CBService)] = []
    public private(set) var mockNotifyRequests: [(enabled: Bool, characteristic: CBCharacteristic)] = []
    public private(set) var mockWrites: [MockWrite] = []
    public var mockOnWrite: ((Data, CBCharacteristic, CBCharacteristicWriteType) -> Void)?
    public init(identifier: UUID = UUID(), name: String? = nil) { self.identifier = identifier; self.name = name; super.init() }
    public func discoverServices(_ serviceUUIDs: [CBUUID]?) { mockServiceDiscoveries.append(serviceUUIDs) }
    public func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService) {
        mockCharacteristicDiscoveries.append((characteristicUUIDs, service))
    }
    public func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) { mockNotifyRequests.append((enabled, characteristic)) }
    public func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { mockMaximumWriteValueLength }
    public func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        mockWrites.append(MockWrite(data: data, characteristic: characteristic, type: type))
        mockOnWrite?(data, characteristic, type)
    }
    public func mockDidDiscoverServices(error: Error? = nil) { delegate?.peripheral(self, didDiscoverServices: error) }
    public func mockDidDiscoverCharacteristics(_ service: CBService, error: Error? = nil) {
        delegate?.peripheral(self, didDiscoverCharacteristicsFor: service, error: error)
    }
    public func mockNotificationState(_ characteristic: CBCharacteristic, isNotifying: Bool, error: Error? = nil) {
        characteristic.isNotifying = isNotifying
        delegate?.peripheral(self, didUpdateNotificationStateFor: characteristic, error: error)
    }
    public func mockDidWrite(_ characteristic: CBCharacteristic, error: Error? = nil) {
        delegate?.peripheral(self, didWriteValueFor: characteristic, error: error)
    }
    public func mockDidUpdateValue(_ characteristic: CBCharacteristic, value: Data?, error: Error? = nil) {
        characteristic.value = value
        delegate?.peripheral(self, didUpdateValueFor: characteristic, error: error)
    }
    public func mockReadyToWriteWithoutResponse() { delegate?.peripheralIsReady(toSendWriteWithoutResponse: self) }
}

public final class CBCentralManager: NSObject {
    public static private(set) var mockInstances: [CBCentralManager] = []
    public static func mockReset() { mockInstances.removeAll() }
    public weak var delegate: (any CBCentralManagerDelegate)?
    public private(set) var state: CBManagerState = .unknown
    public private(set) var isScanning = false
    public let mockOptions: [String: Any]?
    public private(set) var mockScans: [(services: [CBUUID]?, options: [String: Any]?)] = []
    public private(set) var mockConnections: [CBPeripheral] = []
    public private(set) var mockCancellations: [CBPeripheral] = []
    public private(set) var mockStopScanCalls = 0
    public init(delegate: (any CBCentralManagerDelegate)?, queue: DispatchQueue?, options: [String: Any]? = nil) {
        self.delegate = delegate; mockOptions = options; super.init(); Self.mockInstances.append(self)
    }
    public func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]? = nil) {
        isScanning = true; mockScans.append((serviceUUIDs, options))
    }
    public func stopScan() { isScanning = false; mockStopScanCalls += 1 }
    public func connect(_ peripheral: CBPeripheral, options: [String: Any]? = nil) {
        mockConnections.append(peripheral)
        if peripheral.state == .disconnected { peripheral.state = .connecting }
    }
    public func cancelPeripheralConnection(_ peripheral: CBPeripheral) {
        mockCancellations.append(peripheral)
        if peripheral.state != .disconnected { peripheral.state = .disconnecting }
    }
    public func mockSetState(_ state: CBManagerState) {
        mockSetStateWithoutCallback(state)
        delegate?.centralManagerDidUpdateState(self)
    }
    public func mockSetStateWithoutCallback(_ state: CBManagerState) {
        self.state = state
        if state != .poweredOn { isScanning = false }
    }
    public func mockRestore(_ dict: [String: Any]) { delegate?.centralManager(self, willRestoreState: dict) }
    public func mockDiscover(_ peripheral: CBPeripheral, advertisementData: [String: Any] = [:], rssi: NSNumber = -40) {
        delegate?.centralManager(self, didDiscover: peripheral, advertisementData: advertisementData, rssi: rssi)
    }
    public func mockDidConnect(_ peripheral: CBPeripheral) {
        peripheral.state = .connected; delegate?.centralManager(self, didConnect: peripheral)
    }
    public func mockDidFailToConnect(_ peripheral: CBPeripheral, error: Error? = nil) {
        peripheral.state = .disconnected; delegate?.centralManager(self, didFailToConnect: peripheral, error: error)
    }
    public func mockDidDisconnect(_ peripheral: CBPeripheral, error: Error? = nil) {
        peripheral.state = .disconnected; delegate?.centralManager(self, didDisconnectPeripheral: peripheral, error: error)
    }
}

public final class CBPeripheralManager: NSObject {
    public struct MockUpdate { public let data: Data; public let characteristic: CBMutableCharacteristic; public let centrals: [CBCentral]? }
    public struct MockResponse { public let request: CBATTRequest; public let result: CBATTError.Code }
    public static private(set) var mockInstances: [CBPeripheralManager] = []
    public static func mockReset() { mockInstances.removeAll() }
    public weak var delegate: (any CBPeripheralManagerDelegate)?
    public private(set) var state: CBManagerState = .unknown
    public private(set) var isAdvertising = false
    public let mockOptions: [String: Any]?
    public private(set) var mockAddedServices: [CBMutableService] = []
    public private(set) var mockServices: [CBMutableService] = []
    public private(set) var mockAdvertisingCalls: [[String: Any]?] = []
    public private(set) var mockUpdates: [MockUpdate] = []
    public private(set) var mockResponses: [MockResponse] = []
    public private(set) var mockRemoveAllServicesCalls = 0
    public private(set) var mockStopAdvertisingCalls = 0
    public var mockUpdateValueResult = true
    public var mockOnUpdateValue: ((Data, CBMutableCharacteristic, [CBCentral]?) -> Bool)?
    public init(delegate: (any CBPeripheralManagerDelegate)?, queue: DispatchQueue?, options: [String: Any]? = nil) {
        self.delegate = delegate; mockOptions = options; super.init(); Self.mockInstances.append(self)
    }
    public func add(_ service: CBMutableService) { mockAddedServices.append(service) }
    public func removeAllServices() { mockServices.removeAll(); mockRemoveAllServicesCalls += 1 }
    public func startAdvertising(_ advertisementData: [String: Any]?) { mockAdvertisingCalls.append(advertisementData) }
    public func stopAdvertising() { isAdvertising = false; mockStopAdvertisingCalls += 1 }
    public func updateValue(_ value: Data, for characteristic: CBMutableCharacteristic, onSubscribedCentrals centrals: [CBCentral]?) -> Bool {
        mockUpdates.append(MockUpdate(data: value, characteristic: characteristic, centrals: centrals))
        return mockOnUpdateValue?(value, characteristic, centrals) ?? mockUpdateValueResult
    }
    public func respond(to request: CBATTRequest, withResult result: CBATTError.Code) {
        mockResponses.append(MockResponse(request: request, result: result))
    }
    public func mockSetState(_ state: CBManagerState) {
        self.state = state
        if state != .poweredOn { isAdvertising = false }
        delegate?.peripheralManagerDidUpdateState(self)
    }
    public func mockRestore(_ dict: [String: Any]) {
        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] { mockServices = services }
        delegate?.peripheralManager(self, willRestoreState: dict)
    }
    public func mockDidAdd(_ service: CBMutableService, error: Error? = nil) {
        if error == nil { mockServices.append(service) }
        delegate?.peripheralManager(self, didAdd: service, error: error)
    }
    public func mockDidStartAdvertising(error: Error? = nil) {
        isAdvertising = error == nil; delegate?.peripheralManagerDidStartAdvertising(self, error: error)
    }
    public func mockSubscribe(_ central: CBCentral, to characteristic: CBCharacteristic) {
        if let mutable = characteristic as? CBMutableCharacteristic {
            mutable.subscribedCentrals = (mutable.subscribedCentrals ?? []) + [central]
        }
        delegate?.peripheralManager(self, central: central, didSubscribeTo: characteristic)
    }
    public func mockUnsubscribe(_ central: CBCentral, from characteristic: CBCharacteristic) {
        if let mutable = characteristic as? CBMutableCharacteristic {
            mutable.subscribedCentrals?.removeAll { $0 === central }
        }
        delegate?.peripheralManager(self, central: central, didUnsubscribeFrom: characteristic)
    }
    public func mockReadyToUpdate() { delegate?.peripheralManagerIsReady(toUpdateSubscribers: self) }
    public func mockReceiveWrite(_ requests: [CBATTRequest]) { delegate?.peripheralManager(self, didReceiveWrite: requests) }
}
