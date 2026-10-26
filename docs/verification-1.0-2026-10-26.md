# PechPech 1.0 verification — 26 October 2026

PechPech 1.0 establishes the stable production API while retaining generic wire version 2, opaque control version 1, discovery identifiers and the existing database schema. The compiler requirement is now Swift 6.1 or later, using Swift 5 language mode. [The upgrade guide](migration-1.0.md) describes adoption without discarding identities or records.

## Software checks and publication gate

Development used Linux with an isolated Swift 6.1.2 toolchain. The earlier [Linux record](verification-linux-2026-10-26.md) is historical; 1.0 adds Bluetooth manager restoration and power/reset recovery. Native Apple debug/optimized tests, release builds, consumer compilation, vectors, privacy/license resources, generic iOS Simulator compilation and the injected-link demo are verified by the macOS CI matrix. Separate pinned-container Linux jobs execute portable and mock-Bluetooth tests and process/storage-failure probes in debug and optimized configurations.

The final source candidate's completed run and test counts are recorded below before publication. An annotated-tag run additionally verifies clean consumers resolving the exact public version to the reviewed commit and retaining both library resource bundles. The GitHub release links that qualifying exact-tag run.

## Verification scope

- Byte-preserving immutable messages, authenticated endpoint receipts, independent relay storage and explicit retry intent.
- Crash recovery after committed outbox, sender receipt and inbox/return writes, and rollback before inbox commit. Kill barriers verify SQLite remains open.
- Real scoped ENOSPC → SQLite FULL failures at outbox, inbox and receipt write boundaries, with atomic rollback, retry and process reopen.
- Seeded loss, duplication, reordering and route changes, followed by alternate-route completion and immutable/deduplicated storage checks.
- Event-driven scheduling and queue-capacity recovery without repeating admitted sends or reviving paused originals.
- Bounded opaque admission proof through retry/read races, immutable hash conflicts, capacity and acknowledgment retirement.
- Actual BLE adapter delegate execution against a Linux API double: queue limits, ATT batch atomicity, stale managers/services, restoration quarantine, fresh connection requests, power/reset recovery and fresh service identity.

## Operating limits

The Bluetooth mock does not implement Apple's radio, permissions, OS scheduling or actual state restoration. Native compilation is separate from mock execution. No physical-device/background matrix, real Keychain entitlement test, independent security audit, range/latency measurement or UI responsiveness qualification was performed for this release. Failure injection does not simulate every power-loss/storage-hardware condition.

Background recovery is subject to OS wake opportunities and host configuration. Local cancellation does not guarantee physical disconnection if another app shares the link. A remote peer must observe service invalidation, resubscription or reconnection before fresh challenge authentication can complete. Continuous TCP, force-quit delivery and uninterrupted arbitrary-hop routes are not guarantees. See [the operating contract](production-readiness.md) and [qualification matrix](qualification.md).
