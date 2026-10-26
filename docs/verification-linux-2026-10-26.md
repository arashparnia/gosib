# Linux software verification — 26 October 2026

This historical record covers production-readiness commit `42b69803960f04b873190ba5e499b3a7c7289184` after 0.3.1, before manager-restoration implementation. It does not classify a new published release or replace native Apple checks. Editing and execution stayed on Linux; no physical devices or macOS runners were used in this verification round.

## Environment

The host was x86-64 Linux (Omarchy/Arch family), using a task-local Swift 6.1.2 Ubuntu 24.04 toolchain. Its detached signature verified against the official Swift 6.x release signing key (`52BB 7E3D E28A 71BE 22EC 05FF EF80 A866 B47A 981F`). Required compatibility libraries were extracted into the ignored task workspace. The shipping SwiftPM manifest and Apple CryptoKit backend were unchanged.

The Linux driver copies the SDK/test sources without changing their contents, supplies development-only CryptoKit and SQLite module shims, and reports its exact dependency revisions:

| Development dependency | Version | Revision |
| --- | --- | --- |
| Apple Swift Crypto | 3.15.1 | `95ba0316a9b733e92bb6b071255ff46263bbe7dc` |
| Swift ASN.1 | 1.3.0 | `7faebca1ea4f9aaf0cda1cef7c43aecd2311ddf6` |

## Results

| Check | Result |
| --- | --- |
| Debug portable unit suite | PASS — 95 tests, zero failures |
| Optimized portable unit suite | PASS — 95 tests, zero failures |
| Committed outbox / sender receipt / inbox plus return receipt SIGKILL recovery | PASS in debug and optimized probes |
| SIGKILL before inbox transaction commit | PASS — rollback and identical retry recovery in both builds |
| Actual scoped ENOSPC → SQLite FULL for queue / inbox / receipt writes | PASS — rollback, retry and fresh-process reopen in both builds |
| Deterministic loss, duplication, reordering and route changes | PASS — four seeds, eight immutable messages each, reliable alternate-route completion and reopened-store invariants |
| Event-driven scheduling and one-slot backpressure recovery | PASS — links retained, polling disabled, refused work retried, successful sends suppressed, stop intent preserved |
| Optimized injected-link demo | PASS — two-hop encrypted delivery, durable receipt, duplicate suppression |
| Compiled library privacy/license resources | PASS in Linux optimized products |
| Independent Node/OpenSSL vectors | PASS — generic encryption, opaque controls, exact Unicode encodings and hashes |
| Whitespace and Python driver syntax | PASS |

Both source and test directories were compared byte-for-byte with the tested package copies after the final runs. All identities, messages and databases were synthetic. Runtime stores, downloaded dependencies, toolchains, fault libraries and builds remain outside tracked source files.

The process-kill driver also checked `/proc/<pid>/fd` at each kill barrier to confirm SQLite was still open, including in the optimized build. Both probe suites passed again with that check enabled.

## Limits

Linux excludes CoreBluetooth, Network and Keychain implementation branches. It executes common framing/queue policy tests; eight native-only tests are excluded. Native Apple compilation, real Keychain access and physical radio/background operation were not tested here. The process/storage probes inject specified failures; they do not simulate power loss or establish physical storage-device behavior.

Event-driven scheduling provides a software mechanism for OS-granted wake opportunities. Full Core Bluetooth manager restoration and safe neighbor-session reconciliation after process termination remain unimplemented. This record does not establish continuous background TCP, force-quit delivery, radio coverage, latency, UI responsiveness or independent security certification. See [production readiness](production-readiness.md) and [qualification](qualification.md).
