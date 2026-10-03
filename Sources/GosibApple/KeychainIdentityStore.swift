#if canImport(Security) && canImport(CryptoKit)
import Foundation
import GosibCore
import Security

/// Host-scoped identity persistence in Apple's data-protection Keychain.
/// The host supplies its own unique service and valid signing/Keychain context.
/// Existing malformed or inaccessible records are never silently replaced.
public enum KeychainIdentityStore {
    public enum Failure: Error, Equatable, LocalizedError, Sendable {
        case invalidNamespace
        case invalidSavedIdentity
        case secureStorageUnavailable(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .invalidNamespace:
                return "Identity storage requires a nonempty host-selected service and account."
            case .invalidSavedIdentity:
                return "The saved secure identity is invalid. Restore its trusted identity before resuming delivery."
            case .secureStorageUnavailable(let status):
                return "Secure identity storage is unavailable (OSStatus \(status)). Check the host application's signing and Keychain access."
            }
        }
    }

    /// Returns the existing identity or atomically adds a new one. A concurrent
    /// creator winning the add race is read back; no existing record is updated.
    public static func loadOrCreate(service: String, account: String = "endpoint") throws -> Identity {
        guard validNamespace(service), validNamespace(account) else { throw Failure.invalidNamespace }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let identity = try read(query) { return identity }

        let identity = Identity()
        var attributes = query
        attributes[kSecValueData as String] = try IdentityRecordCodec.encode(identity)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return identity
        case errSecDuplicateItem:
            // Another caller/process may have created the record after our read.
            guard let winner = try read(query) else {
                throw Failure.secureStorageUnavailable(errSecItemNotFound)
            }
            return winner
        default:
            throw Failure.secureStorageUnavailable(status)
        }
    }

    static func validNamespace(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 1_024 && !value.utf8.contains(0)
    }

    private static func read(_ baseQuery: [String: Any]) throws -> Identity? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.secureStorageUnavailable(status) }
        guard let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let accessibility = item[kSecAttrAccessible as String] as? String,
              accessibility == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String) else {
            throw Failure.invalidSavedIdentity
        }
        return try IdentityRecordCodec.decode(data)
    }
}

/// Local versioned private-key encoding, never a network format or export API.
enum IdentityRecordCodec {
    static let encodedByteCount = 65

    static func encode(_ identity: Identity) throws -> Data {
        guard identity.signingPrivateKey.count == 32, identity.agreementPrivateKey.count == 32 else {
            throw KeychainIdentityStore.Failure.invalidSavedIdentity
        }
        return Data([1]) + identity.signingPrivateKey + identity.agreementPrivateKey
    }

    static func decode(_ bytes: Data) throws -> Identity {
        guard bytes.count == encodedByteCount, bytes.first == 1 else {
            throw KeychainIdentityStore.Failure.invalidSavedIdentity
        }
        let material = bytes.dropFirst()
        do {
            return try Identity(signingPrivateKey: Data(material.prefix(32)),
                                agreementPrivateKey: Data(material.suffix(32)))
        } catch {
            // Do not propagate CryptoKit internals or include key material in errors.
            throw KeychainIdentityStore.Failure.invalidSavedIdentity
        }
    }
}
#endif
