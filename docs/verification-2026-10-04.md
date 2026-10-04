# PechPech 0.2 source verification — 4 October 2026

This record covers fresh validation of the PechPech 0.2.0 names, wire version 2 and storage namespace. It is separate from [the retained prior 0.1 record](verification-2026-10-03.md). All identities, payloads and databases used here were synthetic; no operational keys, provider credentials or GARVI runtime data were involved.

Local checks used an Apple Silicon Mac with Xcode 27.0 and Apple Swift 6.4 in the package's Swift 5 language mode. Declared Swift 5.9 / iOS 16 / macOS 13 minima remain source targets; no physical runtime qualification on those minimum OS versions is implied.

| Current-release check | Result | What it establishes |
| --- | --- | --- |
| `swift test` | Passed: 41 tests, comprising 33 core and eight adapter/helper tests, zero failures | Current protocol, persistence, routing, framing, namespace rejection and local-codec assertions |
| `swift build -c release` | Passed | Optimized current package/library/demo compilation |
| `swift run pechpech-demo` | Passed without diagnostic errors | Current encrypted durable two-hop delivery and duplicate replay through injected links |
| `node scripts/check-interop-vector.cjs` | Passed with Node 22 / OpenSSL | Independent static verification of the newly generated version-2 canonical crypto fixture |
| Actual Apple adapter/helper source typechecks for macOS 13 and iOS 16, warnings as errors | Passed | Native source/API compilation for those deployment targets; not runtime or permission qualification |
| Generic iOS Simulator `PechPechApple` package build, deployment target iOS 16, signing disabled | Passed | Integrated current core/native-source compilation, producing both library object files and arm64/x86_64 Swift modules |

The version-2 fixture was independently generated using Node/OpenSSL with explicitly synthetic repeated-byte keys and a fixed test nonce. It has a version-2 header, the new `PECHPECH-2` domain, and fresh signatures/ciphertext. It is not prior ciphertext with edited names. Swift/CryptoKit tests verify exact canonical encodings and authenticate/decrypt this independent fixture.

The Node checker verifies canonical message/header/envelope/packet bytes, derived public identities and address hashes, Ed25519 signatures, bidirectional X25519 agreement, HKDF-SHA256 derivation and authenticated AES-256-GCM plaintext. Run the committed [checker](../scripts/check-interop-vector.cjs) with Node 22 or later; it uses built-in modules, no runtime stores, credentials or radios.

New negative tests reject prior/foreign endpoint and control namespaces and BLE version-1 framing. The foreign-schema test preserves the preexisting table/row, creates no current SDK tables and leaves its journal mode unchanged; valid current stores reopen. These checks protect existing records from silent namespace replacement. They do not implement a production migration tool.

Core tests also cover immutable outbox/inbox recovery, authenticated receipts, atomic storage failure/rollback, relay capacity/expiry/eviction, duplicate delivery, alternate receipt paths, interrupted intent and handshake recovery. Adapter/helper tests use pure framing, discovery-name, argument and private-record codecs. They do not start Bluetooth or access a real Keychain.

The integrated iOS compile used:

```sh
xcodebuild -scheme PechPechApple \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ios-simulator \
  CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=16.0 \
  build -quiet
```

This is source-level software and static-vector evidence. It establishes no physical-radio topology, Android/browser implementation, background receiving, latency/range guarantee, UI responsiveness, signed-host Keychain permissions or real-device migration. Deployment gates remain in [qualification](qualification.md), and existing hosts need [reviewed upgrade behavior](migration-0.2.md).
