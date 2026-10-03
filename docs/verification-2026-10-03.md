# Initial source verification — 3 October 2026

This record covers the frozen initial Gosib 0.1.0 implementation. All runtime identities, payloads and databases used by these checks were synthetic. No operational secrets, Apple account configuration or GARVI runtime data were copied into the public package.

Local verification used an Apple Silicon Mac with Xcode 27.0 and Apple Swift 6.4 in the package's Swift 5 language mode. The declared Swift 5.9 / iOS 16 / macOS 13 minima are package targets; this is not physical runtime evidence on those minimum OS versions.

| Check | Result | What it establishes |
| --- | --- | --- |
| `swift test` | Passed: 38 tests, comprising 30 core and eight Apple-adapter/helper tests | The asserted protocol, persistence, routing, framing and local-codec behavior on the test host |
| `swift build -c release` | Passed | Optimized package/library/demo compilation on the local host |
| `swift run gosib-demo` | Passed without diagnostic errors | Real core encryption and durable delivery through injected sender → relay → receiver links, followed by duplicate replay without another inbox entry |
| Generic iOS Simulator `GosibApple` build, deployment target iOS 16, signing disabled | Passed | Integrated core/native-source compilation for that destination |
| Independent Node 22 / OpenSSL canonical-vector check | Passed | Static interoperability of the published synthetic crypto vector with another crypto implementation |

The core tests cover endpoint encryption/tampering, recipient isolation, timestamp and payload bounds, canonical encoding, fragmented stream framing, identity binding, immutable outbox recovery, atomic inbox/result/receipt writes, matching receipt and return retirement, injected storage failures, bounded relay admission, expiry, transactional eviction rollback, two-hop delivery, lost receipts, alternate return paths, interrupted intent, authorization, sender/address spoofing, handshake recovery, and relay acknowledgment isolation.

The eight Apple tests cover BLE fragmentation/queue rules, TCP frame bounds, discovery-name uniqueness, and the Keychain helper's argument validation and local private-record codec. They do not call a real Keychain or start Bluetooth. BLE checks include 60 boundary round trips, multiple negotiated fragment sizes, malformed sequences, priority changes, unchanged fragments under backpressure and independent neighbor buffers.

The independent vector check verified Ed25519 signatures over exact header/envelope bytes; X25519 agreement using documented synthetic receiver material; Gosib's HKDF-SHA256 derivation; authenticated AES-256-GCM decryption; the decrypted embedded signature/envelope; the canonical message SHA-256 hash; and the concatenated-public-key address. It used [the committed fixture](../Tests/GosibCoreTests/Fixtures/canonical-v1.json) without changing it. The independently implemented [checker](../scripts/check-interop-vector.cjs) is committed and uses Node's built-in modules only. Run it with Node 22 or later:

```sh
node scripts/check-interop-vector.cjs
```

This verifies a static vector, not a working Android or browser implementation. It requires no provider credentials, runtime stores or radios.

The final iOS compile used:

```sh
xcodebuild -scheme GosibApple \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ios-simulator \
  CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=16.0 \
  build -quiet
```

No physical BLE/TCP topology, no-router/different-network service, radio range, interference, mobile sleep/background receiving, UI responsiveness, latency distribution, or signed-host Keychain access/migration was qualified by these checks. SQLite failure injection does not establish the durability of every physical storage device. The required next deployment checks remain in [qualification](qualification.md).
