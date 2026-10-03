#if canImport(CoreBluetooth)
import Foundation
import GosibCore
@preconcurrency import CoreBluetooth

/// Foreground multi-neighbor BLE transport. The caller owns authentication, retries,
/// persistence and end-to-end receipts; an ATT write response is not an application receipt.
@MainActor
public final class BLEPacketLink: NSObject, PacketLink {
    public var onState: ((String) -> Void)?
    public var onPeers: (([LinkPeer]) -> Void)?
    public var onMessage: ((Data, String) -> Void)?
    public var onLinkReady: ((String) -> Void)?
    public var onDisconnected: ((String) -> Void)?

    // One discovery service across rooms. A name or this UUID never grants trust.
    private static let serviceUUID = CBUUID(string: "C0675190-2099-471E-BAA6-DA93CD12451B")
    private static let messageUUID = CBUUID(string: "C0675191-2099-471E-BAA6-DA93CD12451B")
    private static let maximumPeers = 4
    private static let maximumQueuedMessages = 32
    private static let maximumQueuedBytes = 128 * 1024
    private static let connectionTimeout: TimeInterval = 20
    private static let fragmentTimeout: TimeInterval = 20

    private var running = false
    private var serviceName = ""
    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var clients: [UUID: ClientLink] = [:]
    private var subscribers: [UUID: SubscriberLink] = [:]
    private var messageCharacteristic: CBMutableCharacteristic?
    private var serviceAdded = false
    private var addingService = false
    private var advertisingRequested = false
    private var notificationBlocked = false
    private var pumpingNotifications = false
    private var notificationCursor = 0
    private var nextMessageID = UInt32.random(in: 1...UInt32.max)
    private var maintenanceTask: Task<Void, Never>?
    private var reportedPeerLimit = false
    private var startupWaitBegan: Date?
    private var reportedStartupWait = false

    private final class ClientLink {
        let peripheral: CBPeripheral
        var name: String
        var characteristic: CBCharacteristic?
        var ready = false
        var closing = false
        var attemptStarted: Date?
        var retryAfter = Date.distantPast
        var attempts = 0
        var lastSeen = Date()
        var inFlightPayloadBytes: Int?
        var writeStarted: Date?
        var outbox = BLEOutbox()
        var inbound = BLEReassembler()

        init(peripheral: CBPeripheral, name: String) {
            self.peripheral = peripheral
            self.name = name
        }
    }

    private final class SubscriberLink {
        let central: CBCentral
        var outbox = BLEOutbox()
        var inbound = BLEReassembler()

        init(central: CBCentral) { self.central = central }
    }

    public override init() { super.init() }

    /// Use a stable, unique node identity. Discovery names select topology, never trust.
    public func start(nodeName: String = UUID().uuidString) {
        stop()
        running = true
        self.serviceName = DiscoveryName.make(from: nodeName)
        reportedPeerLimit = false
        startupWaitBegan = Date()
        reportedStartupWait = false
        onState?("BLE waiting for Bluetooth permission and power")
        centralManager = CBCentralManager(delegate: self, queue: .main)
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
                guard !Task.isCancelled else { return }
                self?.maintainLinks()
            }
        }
    }

    public func stop() {
        running = false
        maintenanceTask?.cancel()
        maintenanceTask = nil
        let disconnected = clients.values.filter(\.ready).map { "c:" + $0.peripheral.identifier.uuidString }
            + subscribers.keys.map { "p:" + $0.uuidString }
        if let manager = centralManager {
            manager.stopScan()
            for link in clients.values {
                link.peripheral.delegate = nil
                if link.peripheral.state != .disconnected {
                    manager.cancelPeripheralConnection(link.peripheral)
                }
            }
            manager.delegate = nil
        }
        if let manager = peripheralManager {
            manager.stopAdvertising()
            if manager.state == .poweredOn { manager.removeAllServices() }
            manager.delegate = nil
        }
        centralManager = nil
        peripheralManager = nil
        clients.removeAll()
        subscribers.removeAll()
        messageCharacteristic = nil
        serviceAdded = false
        addingService = false
        advertisingRequested = false
        notificationBlocked = false
        pumpingNotifications = false
        notificationCursor = 0
        startupWaitBegan = nil
        reportedStartupWait = false
        onPeers?([])
        for peer in disconnected { onDisconnected?(peer) }
    }

    deinit { maintenanceTask?.cancel() }

    /// This adapter grants no application permission. Discovery continues.
    public func confirmPeer(_ peerID: String) {}

    /// True means local queue admission only, never delivery or application receipt.
    @discardableResult public func send(_ data: Data, to peerID: String, priority: Int = 1) -> Bool {
        guard !data.isEmpty, data.count <= BLEFragment.maximumMessageBytes else {
            onState?("BLE send rejected: payload must contain 1...16,384 bytes")
            return false
        }
        guard running, peerID.count > 2, let id = UUID(uuidString: String(peerID.dropFirst(2))) else {
            onState?("BLE link unavailable; caller retains responsibility for retry")
            return false
        }
        let messageID = nextMessageID
        nextMessageID &+= 1
        if nextMessageID == 0 { nextMessageID = 1 }
        if peerID.hasPrefix("c:"), let link = clients[id], link.ready, link.characteristic != nil {
            guard enqueue(data, id: messageID, priority: priority, into: &link.outbox,
                          protectCurrent: link.inFlightPayloadBytes != nil) else { return false }
            pumpWrites(link)
            return true
        } else if peerID.hasPrefix("p:"), let link = subscribers[id] {
            guard enqueue(data, id: messageID, priority: priority, into: &link.outbox) else { return false }
            pumpNotifications()
            return true
        }
        onState?("BLE link unavailable; caller retains responsibility for retry")
        return false
    }

    private func enqueue(_ data: Data, id: UInt32, priority: Int, into outbox: inout BLEOutbox,
                         protectCurrent: Bool = false) -> Bool {
        guard outbox.messages.count < Self.maximumQueuedMessages,
              outbox.byteCount + data.count <= Self.maximumQueuedBytes else {
            onState?("BLE local queue full; caller retains responsibility for retry")
            return false
        }
        outbox.enqueue(data, id: id, priority: priority, protectCurrent: protectCurrent)
        return true
    }

    private func publishPeers() {
        let outgoing = clients.values.map { LinkPeer(id: "c:" + $0.peripheral.identifier.uuidString, name: $0.name) }
        let incoming = subscribers.values.map { LinkPeer(id: "p:" + $0.central.identifier.uuidString, name: "Nearby Gosib") }
        onPeers?((outgoing + incoming).sorted { $0.id < $1.id })
    }

    private func describe(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "Bluetooth on"
        case .poweredOff: return "Bluetooth off; turn it on to use BLE"
        case .unauthorized: return "Bluetooth permission denied; enable it in system settings"
        case .unsupported: return "BLE unavailable on this device"
        case .resetting: return "Bluetooth resetting"
        case .unknown: return "Bluetooth state unknown"
        @unknown default: return "Bluetooth state unavailable"
        }
    }

    private func ensureScanning() {
        guard running, let manager = centralManager, manager.state == .poweredOn else { return }

        if !manager.isScanning {
            manager.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
            onState?("BLE discovering Gosib peers; up to \(Self.maximumPeers) nearby peers")
        }
    }

    private func connectIfDue(_ link: ClientLink) {
        guard running, let manager = centralManager, manager.state == .poweredOn,
              !link.ready, !link.closing, link.attemptStarted == nil,
              link.peripheral.state == .disconnected, Date() >= link.retryAfter else { return }
        link.attemptStarted = Date()
        link.peripheral.delegate = self
        manager.connect(link.peripheral, options: nil)
    }

    private func retryDelay(_ link: ClientLink) {
        link.attempts = min(link.attempts + 1, 6)
        let delay = min(pow(2, Double(link.attempts - 1)), 30)
        link.retryAfter = Date().addingTimeInterval(delay)
        link.attemptStarted = nil
    }

    private func clearClientChannel(_ link: ClientLink) {
        let wasReady = link.ready
        let hadQueuedMessages = !link.outbox.messages.isEmpty
        link.ready = false
        link.characteristic = nil
        link.inFlightPayloadBytes = nil
        link.writeStarted = nil
        link.inbound = BLEReassembler()
        link.outbox = BLEOutbox()
        if hadQueuedMessages {
            onState?("BLE link interrupted; transport queue discarded; application must retry unconfirmed messages")
        }
        if wasReady { onDisconnected?("c:" + link.peripheral.identifier.uuidString) }
    }

    private func failClient(_ link: ClientLink, reason: String) {
        onState?("BLE \(link.name): \(reason)")
        clearClientChannel(link)
        retryDelay(link)
        if link.peripheral.state != .disconnected {
            link.closing = true
            centralManager?.cancelPeripheralConnection(link.peripheral)
        } else {
            link.closing = false
        }
    }

    private func ensureAdvertising() {
        guard running, let manager = peripheralManager, manager.state == .poweredOn else { return }
        if !serviceAdded {
            guard !addingService else { return }
            manager.removeAllServices()
            let characteristic = CBMutableCharacteristic(
                type: Self.messageUUID,
                properties: [.write, .writeWithoutResponse, .notify],
                value: nil,
                permissions: [.writeable]
            )
            let service = CBMutableService(type: Self.serviceUUID, primary: true)
            service.characteristics = [characteristic]
            messageCharacteristic = characteristic
            addingService = true
            manager.add(service)
        } else if !manager.isAdvertising && !advertisingRequested {
            advertisingRequested = true
            manager.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
                CBAdvertisementDataLocalNameKey: serviceName
            ])
        }
    }

    private func clearSubscribers() {
        let peers = subscribers.keys.map { "p:" + $0.uuidString }
        if subscribers.values.contains(where: { !$0.outbox.messages.isEmpty }) {
            onState?("BLE notifications interrupted; application must retry unconfirmed messages")
        }
        subscribers.removeAll()
        notificationBlocked = false
        publishPeers()
        for peer in peers { onDisconnected?(peer) }
    }

    private func maintainLinks() {
        guard running else { return }
        let now = Date()
        let managerState = centralManager?.state
        if managerState == .unknown, !reportedStartupWait,
           let began = startupWaitBegan, now.timeIntervalSince(began) >= 10 {
            reportedStartupWait = true
            onState?("BLE still waiting for Bluetooth authorization or system initialization. Keep Gosib foreground; if no prompt appears, check its Bluetooth permission in system privacy settings and confirm Bluetooth is on.")
        }
        ensureScanning()
        ensureAdvertising()
        do {
            for link in Array(clients.values) {
                if !link.ready, link.peripheral.state == .disconnected, now.timeIntervalSince(link.lastSeen) > 30 {
                    clients.removeValue(forKey: link.peripheral.identifier)
                    link.peripheral.delegate = nil
                    publishPeers()
                    continue
                }
                if link.closing && link.peripheral.state == .disconnected {
                    link.closing = false
                }
                if let began = link.attemptStarted,
                   now.timeIntervalSince(began) > Self.connectionTimeout {
                    failClient(link, reason: "connection setup timed out; retrying")
                } else if let began = link.writeStarted,
                          now.timeIntervalSince(began) > Self.fragmentTimeout {
                    failClient(link, reason: "write response timed out; retrying")
                }
                if link.inbound.discardIfInactive(before: now.timeIntervalSinceReferenceDate - Self.fragmentTimeout) {
                    onState?("BLE discarded an incomplete incoming message after inactivity")
                }
                connectIfDue(link)
            }
        }
        do {
            for link in subscribers.values {
                if link.inbound.discardIfInactive(before: now.timeIntervalSinceReferenceDate - Self.fragmentTimeout) {
                    onState?("BLE discarded an incomplete incoming message after inactivity")
                }
            }
        }
    }

    private func pumpWrites(_ link: ClientLink) {
        guard running, link.ready, link.inFlightPayloadBytes == nil,
              link.peripheral.state == .connected, let characteristic = link.characteristic,
              !link.outbox.messages.isEmpty else { return }
        if characteristic.properties.contains(.writeWithoutResponse) {
            let maximum = link.peripheral.maximumWriteValueLength(for: .withoutResponse)
            while link.peripheral.canSendWriteWithoutResponse && !link.outbox.messages.isEmpty {
                guard let fragment = link.outbox.nextFragment(maximumValueBytes: maximum) else { failClient(link, reason: "BLE framing unavailable"); return }
                link.peripheral.writeValue(fragment.data, for: characteristic, type: .withoutResponse)
                link.outbox.consume(payloadBytes: fragment.payloadBytes)
            }
        } else {
            let maximum = link.peripheral.maximumWriteValueLength(for: .withResponse)
            guard let fragment = link.outbox.nextFragment(maximumValueBytes: maximum) else { failClient(link, reason: "BLE framing unavailable"); return }
            link.inFlightPayloadBytes = fragment.payloadBytes; link.writeStarted = Date()
            link.peripheral.writeValue(fragment.data, for: characteristic, type: .withResponse)
        }
    }

    private func pumpNotifications() {
        guard running, !notificationBlocked, !pumpingNotifications,
              let manager = peripheralManager, manager.state == .poweredOn,
              let characteristic = messageCharacteristic else { return }
        pumpingNotifications = true
        defer { pumpingNotifications = false }
        // One fragment per peer per pass keeps large messages from monopolizing
        // the shared notification queue. A false update must be retried unchanged.
        while true {
            let ids = subscribers.keys.sorted { $0.uuidString < $1.uuidString }
            guard !ids.isEmpty else { return }
            let start = notificationCursor % ids.count
            var madeProgress = false
            for index in 0..<ids.count {
                let position = (start + index) % ids.count
                guard let link = subscribers[ids[position]], !link.outbox.messages.isEmpty else { continue }
                guard let fragment = link.outbox.nextFragment(maximumValueBytes: link.central.maximumUpdateValueLength) else {
                    link.outbox = BLEOutbox()
                    onState?("BLE send failed: peer's notification value is too small for framing")
                    continue
                }
                guard manager.updateValue(fragment.data, for: characteristic, onSubscribedCentrals: [link.central]) else {
                    notificationBlocked = true
                    notificationCursor = position
                    return
                }
                link.outbox.consume(payloadBytes: fragment.payloadBytes)
                notificationCursor = (position + 1) % ids.count
                madeProgress = true
            }
            if !madeProgress { return }
        }
    }
}

// Core Bluetooth invokes these delegates on the explicitly selected main queue.
// @preconcurrency bridges its Objective-C delegate requirements in Swift 5 mode.
extension BLEPacketLink: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === centralManager, running else { return }
        onState?("BLE: \(describe(central.state))")
        if central.state == .poweredOn {
            ensureScanning()
        } else {
            for link in clients.values {
                link.peripheral.delegate = nil
                clearClientChannel(link)
            }
            clients.removeAll()
            publishPeers()
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === centralManager, running else { return }

        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? peripheral.name ?? "Nearby Gosib"
        guard name != serviceName else { return }
        // One duplex BLE connection per pair; the lower advertised identity initiates.
        // A discovery name selects topology only. Authenticated protocol messages establish identities; discovery names are untrusted.
        if name.hasPrefix("GSP-"), name.count >= 16, String(serviceName.prefix(name.count)) >= name { return }
        if let link = clients[peripheral.identifier] {
            link.lastSeen = Date()
            if link.name != name { link.name = name; publishPeers() }
            connectIfDue(link)
            return
        }
        guard clients.count + subscribers.count < Self.maximumPeers else {
            if !reportedPeerLimit {
                reportedPeerLimit = true
                onState?("BLE peer limit reached (\(Self.maximumPeers)); additional advertisements ignored")
            }
            return
        }
        let link = ClientLink(peripheral: peripheral, name: name)
        clients[peripheral.identifier] = link
        publishPeers()
        connectIfDue(link)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === centralManager, running,
              let link = clients[peripheral.identifier], !link.closing else { return }
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === centralManager, running, let link = clients[peripheral.identifier] else { return }
        clearClientChannel(link)
        link.closing = false
        retryDelay(link)
        onState?("BLE connection failed: \(error?.localizedDescription ?? "unknown cause"); retrying")
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === centralManager, running, let link = clients[peripheral.identifier] else { return }
        let hadRequestedClose = link.closing
        clearClientChannel(link)
        link.closing = false
        if !hadRequestedClose { retryDelay(link) }
        onState?("BLE disconnected from \(link.name); discovery and reconnect remain active")
    }
}

extension BLEPacketLink: @preconcurrency CBPeripheralDelegate {
    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if let link = clients[peripheral.identifier] { pumpWrites(link) }
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard running, let link = clients[peripheral.identifier], !link.closing else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            failClient(link, reason: "Gosib service discovery failed")
            return
        }
        peripheral.discoverCharacteristics([Self.messageUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard running, let link = clients[peripheral.identifier], !link.closing,
              service.uuid == Self.serviceUUID else { return }
        guard error == nil,
              let characteristic = service.characteristics?.first(where: { $0.uuid == Self.messageUUID }),
              characteristic.properties.contains(.write), characteristic.properties.contains(.notify) else {
            failClient(link, reason: "Gosib message characteristic unavailable")
            return
        }
        link.characteristic = characteristic
        peripheral.setNotifyValue(true, for: characteristic)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard running, let link = clients[peripheral.identifier], !link.closing,
              characteristic === link.characteristic else { return }
        guard error == nil, characteristic.isNotifying else {
            failClient(link, reason: "notification subscription failed")
            return
        }
        guard !link.ready else { return }
        link.ready = true
        link.attemptStarted = nil
        link.attempts = 0
        onState?("BLE link ready: \(link.name)")
        onLinkReady?("c:" + peripheral.identifier.uuidString)
        pumpWrites(link)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard running, let link = clients[peripheral.identifier], link.ready,
              characteristic === link.characteristic, let payloadBytes = link.inFlightPayloadBytes else { return }
        guard error == nil else {
            failClient(link, reason: "fragment write failed: \(error!.localizedDescription)")
            return
        }
        link.outbox.consume(payloadBytes: payloadBytes)
        link.inFlightPayloadBytes = nil
        link.writeStarted = nil
        pumpWrites(link)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard running, let link = clients[peripheral.identifier], link.ready,
              characteristic === link.characteristic else { return }
        guard error == nil, let value = characteristic.value else {
            failClient(link, reason: "incoming notification failed")
            return
        }
        do {
            if let message = try link.inbound.append(value) {
                onMessage?(message, "c:" + peripheral.identifier.uuidString)
            }
        } catch {
            link.inbound = BLEReassembler()
            onState?("BLE discarded invalid or out-of-order notification fragments")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard running, invalidatedServices.contains(where: { $0.uuid == Self.serviceUUID }),
              let link = clients[peripheral.identifier] else { return }
        failClient(link, reason: "Gosib service changed; reconnecting")
    }
}

extension BLEPacketLink: @preconcurrency CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral === peripheralManager, running else { return }
        onState?("BLE: \(describe(peripheral.state))")
        if peripheral.state == .poweredOn {
            ensureAdvertising()
        } else {
            clearSubscribers()
            serviceAdded = false
            addingService = false
            advertisingRequested = false
            messageCharacteristic = nil
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard peripheral === peripheralManager, running, service.uuid == Self.serviceUUID else { return }
        addingService = false
        if let error {
            messageCharacteristic = nil
            onState?("BLE service registration failed: \(error.localizedDescription); retrying")
            return
        }
        serviceAdded = true
        ensureAdvertising()
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard peripheral === peripheralManager, running else { return }
        advertisingRequested = false
        if let error {
            onState?("BLE advertising failed: \(error.localizedDescription); retrying")
        } else {
            onState?("BLE scanning and advertising nearby Gosib; no router required")
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        guard peripheral === peripheralManager, running,
              characteristic.uuid == Self.messageUUID, subscribers[central.identifier] == nil else { return }
        guard clients.count + subscribers.count < Self.maximumPeers else {
            onState?("BLE subscriber limit reached (\(Self.maximumPeers)); extra client cannot exchange messages")
            return
        }
        subscribers[central.identifier] = SubscriberLink(central: central)
        publishPeers()
        onState?("BLE client subscribed: \(central.identifier.uuidString.prefix(8))")
        onLinkReady?("p:" + central.identifier.uuidString)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard peripheral === peripheralManager, running,
              characteristic.uuid == Self.messageUUID,
              let link = subscribers.removeValue(forKey: central.identifier) else { return }
        if !link.outbox.messages.isEmpty {
            onState?("BLE client unsubscribed with queued messages; application must retry")
        }
        publishPeers()
        onDisconnected?("p:" + central.identifier.uuidString)
        notificationBlocked = false
        pumpNotifications()
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard peripheral === peripheralManager, running else { return }
        notificationBlocked = false
        pumpNotifications()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard peripheral === peripheralManager, running, let first = requests.first else { return }
        // Apple requires one ATT response per batch and atomic application of all
        // requests. Validate/reassemble value copies before changing live buffers.
        var staged: [UUID: BLEReassembler] = [:]
        var complete: [(Data, String)] = []
        for request in requests {
            guard request.characteristic.uuid == Self.messageUUID else {
                peripheral.respond(to: first, withResult: .requestNotSupported)
                return
            }
            guard request.offset == 0 else {
                peripheral.respond(to: first, withResult: .invalidOffset)
                return
            }
            guard let link = subscribers[request.central.identifier] else {
                peripheral.respond(to: first, withResult: .insufficientAuthorization)
                return
            }
            guard let value = request.value else {
                peripheral.respond(to: first, withResult: .invalidAttributeValueLength)
                return
            }
            let id = request.central.identifier
            var reassembler = staged[id] ?? link.inbound
            do {
                if let message = try reassembler.append(value) { complete.append((message, "p:" + id.uuidString)) }
                staged[id] = reassembler
            } catch {
                peripheral.respond(to: first, withResult: .invalidPdu)
                onState?("BLE rejected malformed or out-of-order incoming fragments")
                return
            }
        }
        for (id, reassembler) in staged { subscribers[id]?.inbound = reassembler }
        peripheral.respond(to: first, withResult: .success)
        for (message, peerID) in complete { onMessage?(message, peerID) }
    }
}
#endif
