# Changelog

## 1.0.0 — 26 October 2026

- Publish the stable production API and semantic-versioning contract. Generic wire version 2, opaque control version 1, discovery namespaces, identities and database schema remain compatible with 0.3.1.
- Require Swift 6.1 or later in the package manifest while retaining Swift 5 language mode; this makes the native adapter's compiler requirement explicit.
- Add opt-in Bluetooth manager restoration with explicit host-scoped identifiers, cancellation/quarantine of inherited connections, fresh service publication and fresh protocol authentication. Never adopt old subscribers, transient queues or authenticated readiness.
- Add explicit periodic/event-driven retry scheduling. Event-driven mode keeps links and current caller intent while servicing transport events without the node's one-second retry polling task; it does not grant OS background execution or resume restored outgoing intent.
- Retry refused BLE/TCP queue admission when capacity returns, with coalesced scheduler work and no repeated sends of already-admitted packets. Recover failed TCP listeners with bounded backoff.
- Retain bounded authenticated queue-admission proof across opaque retry passes and suspended host reads, reject changed hashes for retained IDs, and report proof-capacity backpressure.
- Query active originals by indexed ID instead of scanning retained outbox history. Prune expired return packets transactionally while preserving immutable inbox receipts and replay recovery.
- Add Linux-only portable qualification, optimized-mode tests, seeded routing faults, process-kill recovery and scoped real ENOSPC/SQLITE_FULL probes. Apple native compilation and physical background behavior are separate checks.
- Exercise the actual BLE adapter's delegate paths against a development-only Linux CoreBluetooth mock, including stale services, restoration races, queue limits and transactional ATT batches. CI runs debug and optimized Linux suites plus native Apple builds; mock results remain distinct from radio qualification.
- Recover restoration gates after power-off without a disconnect callback and discard invalid peripheral objects after manager reset. Fresh GATT object identity prevents old same-UUID service callbacks from reviving a stale channel.
- Verify 114 native tests in debug and optimized builds on Apple Silicon and Intel, and 124 portable/mock tests plus seven process/storage-failure probes per Linux configuration. See the [1.0 verification record](docs/verification-1.0-2026-10-26.md) for exact-commit evidence and limits.

## 0.3.1 — 26 October 2026

- Compare immutable messages, retry channels and opaque profile identifiers by exact UTF-8, rejecting changed Unicode encodings under an existing ID and keeping byte-distinct profiles isolated. Add a synthetic cross-language encoding/hash vector without changing wire version 2.
- Preserve pause/stop intent across synchronous host and adapter callbacks. Obsolete forwarding and handshake work cannot continue through a replacement session, repeated stops are idempotent, and requested restarts wait for all adapters to close. A later stop cancels a requested restart.
- Bound generic custom-adapter handles to four per adapter and reject opaque decoders that replace original packet bytes before durable hooks run.
- Enforce the 16 KiB limit on complete generic packet frames before relay admission, including the JSON wrapper.
- Refill available TCP connection slots from known Bonjour discoveries after disconnect/backoff, and gate connection callbacks against obsolete sessions.
- Honor stop/restart callbacks during BLE startup and teardown before creating radio managers; prevent old client, subscriber and maintenance callbacks from continuing in replacement sessions.
- Add 25 regressions, bringing the suite to 84 tests, and verify annotated public tags through clean, exact-version SwiftPM consumers in both macOS CI jobs. Wire identifiers, cryptographic domains, APIs and database schemas are unchanged.

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
