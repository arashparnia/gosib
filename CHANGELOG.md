# Changelog

## 0.3.0 — 4 October 2026

- Add `OpaquePacketRouter` for an application's existing encrypted envelope and durable stores, with profile-isolated challenge authentication, route hints, bounded retries, priority scheduling and next-hop acknowledgments. The generic node retains wire version 2; host business receipts remain separate.
- Bound concurrent packet/acknowledgment work, authenticate acknowledgments against actually queued hashes, prevent callbacks from obsolete sessions from sending, and reject duplicate adapter instances before attaching callbacks.
- Make `MeshNode.enqueue(id:)` reuse the saved timestamp, immutable contents and delivered state; reject changed recipient, payload, channel or priority.
- Reject unexpected database schema objects and incompatible table definitions before changing journal mode or creating tables; create new tables transactionally and preserve incompatible records for reviewed recovery.
- Add an independently generated opaque-control-v1 fixture verified by Swift/CryptoKit and Node/OpenSSL, alongside the existing generic encryption vector.
- Package each library's privacy manifest and complete MIT notice as SwiftPM resources, with source and compiled-resource checks.
- Add an independent package-consumer build and Node/OpenSSL crypto-vector verification to the existing macOS/iOS CI matrix.
- Publish a code of conduct, support and governance procedures, third-party notices, and a versioned release checklist.

## 0.2.0 — 4 October 2026

- Establish the PechPech package, library products, demo, documentation, GitHub repository and discovery namespaces.
- Introduce wire version 2, independent signing/HKDF/control domains, `PP` version-2 BLE fragments and `_pechpech._tcp` discovery.
- Reject a foreign SQLite table namespace before changing its journal configuration or creating current tables. This is an explicit breaking upgrade; see the [migration guide](docs/migration-0.2.md).
- Publish an independently generated version-2 synthetic cryptographic fixture. Verification included 41 tests, the two-hop injected-link demo, release and iOS compilation, and Apple Silicon/Intel CI.

## 0.1.0 — 3 October 2026

- Publish the initial independent, experimental messaging SDK snapshot with encrypted endpoint payloads, durable deduplication and receipts, bounded relays, BLE/TCP adapters and an injected-link demo.
- Retain this historical snapshot and its evidence. Its wire/storage namespace is incompatible with 0.2; it is not separately maintained.
