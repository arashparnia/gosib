import Foundation

/// Opt-in Core Bluetooth manager restoration under stable, host-selected identifiers.
/// The host owns background capabilities and whether a restored session may start.
/// Recreating transport managers does not resume any owned outbox message.
public struct BLERestorationConfiguration: Equatable, Sendable {
    public let centralIdentifier: String
    public let peripheralIdentifier: String

    public enum Failure: Error, Equatable, LocalizedError, Sendable {
        case invalidIdentifier
        case duplicateIdentifier

        public var errorDescription: String? {
            switch self {
            case .invalidIdentifier:
                return "Bluetooth restoration requires nonempty host-selected identifiers of at most 1,024 UTF-8 bytes, without null characters."
            case .duplicateIdentifier:
                return "Central and peripheral restoration identifiers must be distinct."
            }
        }
    }

    public init(centralIdentifier: String, peripheralIdentifier: String) throws {
        guard Self.valid(centralIdentifier), Self.valid(peripheralIdentifier) else { throw Failure.invalidIdentifier }
        guard centralIdentifier != peripheralIdentifier else { throw Failure.duplicateIdentifier }
        self.centralIdentifier = centralIdentifier
        self.peripheralIdentifier = peripheralIdentifier
    }

    private static func valid(_ identifier: String) -> Bool {
        !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && identifier.utf8.count <= 1_024 && !identifier.utf8.contains(0)
    }
}

/// No challenge-pinned peer session may inherit a restored connection as ready.
struct BLERestoredConnectionRecovery: Equatable {
    enum State: Equatable { case disconnected, connecting, connected, disconnecting }
    enum Phase: Equatable { case needsCancellation, waitingForDisconnect, reconnectAllowed, connectionRequested }
    private(set) var phase: Phase

    init(state: State) {
        phase = state == .disconnected ? .reconnectAllowed : .needsCancellation
    }
    var canReconnect: Bool { phase == .reconnectAllowed }
    var freshConnectionRequested: Bool { phase == .connectionRequested }
    var needsSessionReset: Bool { phase == .needsCancellation || phase == .waitingForDisconnect }

    mutating func reconcile(state: State) {
        if phase == .reconnectAllowed, state != .disconnected { phase = .needsCancellation }
    }
    mutating func requestFreshConnection() -> Bool {
        guard phase == .reconnectAllowed else { return false }
        phase = .connectionRequested
        return true
    }

    mutating func requestCancellation() -> Bool {
        guard phase == .needsCancellation else { return false }
        // Mark before calling the native API, whose callbacks may be reentrant in adapters.
        phase = .waitingForDisconnect
        return true
    }
    mutating func didDisconnect() { phase = .reconnectAllowed }
}

/// Defers destructive service reset until the restored manager can accept GATT operations.
struct BLEPeripheralRestorationRecovery {
    private(set) var needsReset = false
    mutating func restored() { needsReset = true }
    mutating func beginReset(poweredOn: Bool) -> Bool {
        guard needsReset, poweredOn else { return false }
        needsReset = false
        return true
    }
}

enum BLERestorationSelection {
    static func peers(_ identifiers: [UUID], capacity: Int) -> [UUID] {
        var seen = Set<UUID>()
        return Array(identifiers.filter { seen.insert($0).inserted }.prefix(max(0, capacity)))
    }
}
