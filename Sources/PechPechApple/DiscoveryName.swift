import Foundation
#if canImport(CryptoKit)
import CryptoKit

/// Truncated public identifier only; this name does not authenticate a peer.
enum DiscoveryName {
    static func make(from nodeName: String) -> String {
        "PP-" + SHA256.hash(data: Data(nodeName.utf8)).prefix(10)
            .map { String(format: "%02x", $0) }.joined()
    }
}
#endif
