# Prior 0.1 source verification — 3 October 2026

This is a retained historical record for the prior 0.1 implementation and wire version 1. The document uses the current PechPech branding, but the checks below ran against that release's then-current modules, commands, namespaces and fixture. Changing document names does not revalidate the 0.2 API, wire format or database schema. See [migration](migration-0.2.md) and [current qualification](qualification.md).

All test identities, payloads and databases were synthetic. No operational secrets, Apple account configuration or GARVI runtime data were copied into the public SDK. Local verification used an Apple Silicon Mac with Xcode 27.0 and Apple Swift 6.4 in Swift 5 language mode; it did not exercise the declared minimum OS versions physically.

| Prior-release check | Result on 3 October | What it established for that revision |
| --- | --- | --- |
| Swift package tests | Passed: 38 tests, comprising 30 core and eight adapter/helper tests | The asserted protocol, persistence, routing, framing and local-codec behavior |
| Optimized package build | Passed | Library/demo compilation on the local host |
| Injected-link demo | Passed without diagnostic errors | Encrypted durable two-hop delivery and duplicate replay without another inbox entry |
| Generic iOS Simulator library build, deployment target iOS 16, signing disabled | Passed | Then-current integrated core/native-source compilation |
| Independent Node 22 / OpenSSL static-vector check | Passed | Then-current canonical encoding, identity hashes, Ed25519, X25519, HKDF-SHA256 and authenticated AES-GCM fixture compatibility |

The core tests covered tampering, recipient isolation, timestamp/payload bounds, stream framing, identity binding, immutable outbox recovery, atomic inbox/result/receipt writes, injected storage failures, relay bounds, eviction rollback, expiry, two-hop and alternate-return delivery, lost receipts, paused/restarted intent, sender authorization and identity/acknowledgment isolation. Adapter checks covered BLE/TCP framing, discovery-name uniqueness and Keychain helper argument/local-codec behavior without accessing a real Keychain or starting Bluetooth.

This record establishes no physical radio topology, no-router/different-network service, range, interference, background receiving, UI responsiveness, latency distribution, or signed-host Keychain/migration behavior. It is historical software evidence; it is not an independent security audit or current-release acceptance result.
