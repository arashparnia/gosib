# PechPech 0.3.1 verification — 26 October 2026

This patch preserves the generic version-2 wire encoding, opaque profile control domains, public APIs and database schema. It tightens immutable-byte and complete-frame validation and fixes lifecycle/reconnection failures found during source review. The [initial 0.3 record](verification-0.3-2026-10-04.md) remains historical evidence.

## Checks and release gate

Local review used Linux with Node 26 and Python 3; this host has no Swift/Xcode toolchain. The independent Node/OpenSSL vectors, Python syntax and whitespace checks passed locally. Apple checks ran remotely on the project's Apple Silicon and Intel macOS CI runners.

The [final source candidate run](https://github.com/arashparnia/pechpech/actions/runs/40319525103) qualifies commit `55574723a3fd36623e1872e942080a33352cec95`. Both macOS jobs passed:

| Check | Result on both architectures |
| --- | --- |
| Full unit suite | PASS — 84 tests: 70 Core, 14 Apple, zero failures |
| Independent vectors | PASS — generic encryption, opaque controls and exact UTF-8 encodings/hashes |
| Optimized SwiftPM build | PASS |
| Source and compiled privacy/license resources | PASS |
| Independent local-path library consumer | PASS |
| Generic iOS Simulator compile and resources | PASS |
| Injected-link two-hop delivery and duplicate suppression | PASS |

Only verification/changelog documentation follows that source candidate. Publication remains gated on the exact annotated tag's full matrix, which additionally builds a clean consumer of the public exact version and verifies its resolved commit and compiled resource bundles. See the [CI workflow](../.github/workflows/ci.yml); the [v0.3.1 release](https://github.com/arashparnia/pechpech/releases/tag/v0.3.1) links the qualifying tagged run.

## Regression scope

- Byte-distinct Unicode channels cannot replace a saved message under the same ID, including after store reopening; Swift and Node verify the published canonical bytes and hashes.
- Byte-distinct Unicode opaque profiles cannot authenticate each other's signed hellos or acknowledgments.
- A complete 16,384-byte frame is admitted; a bare packet that fits while its required frame exceeds the limit is rejected before relay persistence.
- Pause during a send prevents attempts to later neighbors. Stop/restart during forwarding, inbox callbacks and host codecs cannot start obsolete sends or durable hooks.
- Repeated stop callbacks terminate; all adapters close before a requested restart, and a later stop cancels that request.
- Custom generic adapters cannot allocate more than four tracked handles; opaque decoding cannot replace input bytes.
- Known TCP candidates can fill freed slots without another discovery event, including when backoff expired while all slots were occupied.
- BLE startup callbacks can stop or replace startup without creating native radio managers. Repeated stop notifications terminate; stale client/subscriber work cannot continue into a replacement session.

These checks use synthetic identities, data, stores and injected links. They do not qualify physical Bluetooth/TCP connectivity, range, background operation, latency, real host Keychain permissions, UI responsiveness, application business semantics or an independent security audit. The deployment matrix in [qualification](qualification.md) remains required. Synchronous core work on the main actor, unbounded owned-message history, host at-rest protection and the absence of forward secrecy against recipient-key compromise remain documented design limits.
