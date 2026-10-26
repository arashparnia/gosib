# PechPech 1.0 verification — 26 October 2026

PechPech 1.0 establishes the stable production API while retaining generic wire version 2, opaque control version 1, discovery identifiers and the existing database schema. The compiler requirement is now Swift 6.1 or later, using Swift 5 language mode. [The upgrade guide](migration-1.0.md) describes adoption without discarding identities or records.

## Software checks and publication gate

Development used Linux with an isolated Swift 6.1.2 toolchain. The earlier [Linux record](verification-linux-2026-10-26.md) is historical; 1.0 adds Bluetooth manager restoration and power/reset recovery. Native Apple debug/optimized tests, release builds, consumer compilation, vectors, privacy/license resources, generic iOS Simulator compilation and the injected-link demo are verified by the macOS CI matrix. Separate pinned-container Linux jobs execute portable and mock-Bluetooth tests and process/storage-failure probes in debug and optimized configurations.

The [final source candidate run](https://github.com/arashparnia/pechpech/actions/runs/40400463387) qualifies commit `30137b3fe0042901d35cdcc8a9fea3bfe920fd9d`. The matrix uses Apple Swift 6.1.2 on Apple Silicon and Intel macOS, and official Swift 6.1.2 in the pinned Linux container. All four jobs passed:

| Check | Result |
| --- | --- |
| Native debug and optimized unit suites, both architectures | PASS — 114 tests in each configuration: 86 Core and 28 Apple, zero failures |
| Linux portable and BLE mock suites, debug and optimized | PASS — 124 tests in each configuration, zero failures |
| Linux process/storage-failure probes, each configuration | PASS — four SIGKILL barriers and three scoped ENOSPC/SQLITE_FULL cases |
| Independent Node/OpenSSL vectors, both native jobs | PASS — generic encryption, exact UTF-8 encodings/hashes and opaque controls |
| Native optimized build and independent library consumer, both architectures | PASS |
| Source and compiled privacy/license resources, both architectures | PASS |
| Generic iOS Simulator compile and resources, both native jobs | PASS |
| Injected-link two-hop delivery and duplicate suppression, both native jobs | PASS |

Local Linux checks also passed all 124 tests and seven failure probes in both configurations, plus the optimized demo, vectors and compiled resources. Copied SDK/test sources matched the candidate. Development-only dependencies resolved to Swift Crypto 3.15.1 (`95ba0316a9b733e92bb6b071255ff46263bbe7dc`) and Swift ASN.1 1.3.0 (`7faebca1ea4f9aaf0cda1cef7c43aecd2311ddf6`); neither is a shipping package dependency.

Only verification/changelog documentation follows that source candidate. Publication remains gated on the annotated tag's full matrix, which additionally verifies clean consumers resolving the exact public version to the reviewed commit and retaining both library resource bundles. The [1.0 release](https://github.com/arashparnia/pechpech/releases/tag/v1.0.0) links that qualifying exact-tag run.

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
