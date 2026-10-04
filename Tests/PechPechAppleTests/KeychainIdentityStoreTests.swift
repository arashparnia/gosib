#if canImport(Security) && canImport(CryptoKit)
import CryptoKit
import Foundation
import PechPechCore
import Security
import XCTest
@testable import PechPechApple

/// Pure codec/argument tests: no actual host Keychain data is read or created.
final class KeychainIdentityStoreTests: XCTestCase {
    func testIdentityRecordPreservesBothKeysWithoutComparingPrivateBytesInFailures() throws {
        let original = Identity()
        let encoded = try IdentityRecordCodec.encode(original)
        XCTAssertEqual(encoded.count, IdentityRecordCodec.encodedByteCount)
        let restored = try IdentityRecordCodec.decode(encoded)
        XCTAssertEqual(restored.publicIdentity, original.publicIdentity)
        let probe = Data("identity-codec-roundtrip".utf8)
        let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: original.publicIdentity.signingKey)
        XCTAssertTrue(verifier.isValidSignature(try restored.sign(probe), for: probe))

        // Decoding a nonzero-start-index Data slice must use relative byte ranges.
        let padded = Data([99, 99]) + encoded + Data([99])
        let sliced = padded[2..<(2 + encoded.count)]
        XCTAssertEqual(try IdentityRecordCodec.decode(sliced).publicIdentity, original.publicIdentity)
    }

    func testInvalidLengthsAndUnknownRecordVersionsRejectWithoutReplacement() {
        for count in [0, 1, 31, 32, 63, 64, 66, 128] {
            XCTAssertThrowsError(try IdentityRecordCodec.decode(Data(repeating: 1, count: count))) {
                XCTAssertEqual($0 as? KeychainIdentityStore.Failure, .invalidSavedIdentity)
            }
        }
        for version: UInt8 in [0, 2, 255] {
            let bytes = Data([version]) + Data(repeating: 0, count: 64)
            XCTAssertThrowsError(try IdentityRecordCodec.decode(bytes)) {
                XCTAssertEqual($0 as? KeychainIdentityStore.Failure, .invalidSavedIdentity)
            }
        }
    }

    func testNamespaceValidationDoesNotTouchTheKeychain() {
        for value in ["", " \n\t", "com.example\0identity", String(repeating: "x", count: 1_025)] {
            XCTAssertFalse(KeychainIdentityStore.validNamespace(value))
            XCTAssertThrowsError(try KeychainIdentityStore.loadOrCreate(service: value)) {
                XCTAssertEqual($0 as? KeychainIdentityStore.Failure, .invalidNamespace)
            }
        }
        XCTAssertTrue(KeychainIdentityStore.validNamespace("com.example.myapp.pechpech.identity"))
        XCTAssertTrue(KeychainIdentityStore.validNamespace("endpoint"))
        XCTAssertThrowsError(try KeychainIdentityStore.loadOrCreate(service: "com.example.synthetic", account: "")) {
            XCTAssertEqual($0 as? KeychainIdentityStore.Failure, .invalidNamespace)
        }
    }

    func testErrorsContainOnlyFixedDescriptionsAndStatusCodes() {
        let error = KeychainIdentityStore.Failure.secureStorageUnavailable(errSecMissingEntitlement)
        XCTAssertEqual(error.errorDescription,
            "Secure identity storage is unavailable (OSStatus -34018). Check the host application's signing and Keychain access.")
    }
}
#endif
