# Production operating contract

PechPech 1.0 is the stable production SDK release. Its API, delivery semantics and operating conditions are documented here; software verification and physical operating coverage remain separate facts.

## Runtime contract

- Explicit periodic/event-driven retry scheduling, retaining links and caller intent while node retry polling is disabled.
- Coalesced native queue-capacity signals and event-driven retries of refused work.
- Bounded, retained opaque queue-admission proof across asynchronous storage reads.
- Indexed active-message lookups and transactional pruning of expired transport return copies without deleting inbox results.
- Failed TCP listener recovery with bounded backoff.
- Opt-in Bluetooth manager restoration with stable host-selected identifiers, inherited-session quarantine, fresh service publication and fresh link authentication.
- Portable Linux tests using development-only Swift Crypto/SQLite shims, seeded loss/duplication/reordering, process-kill recovery and real scoped ENOSPC/SQLITE_FULL failures.

The shipping package uses Apple's CryptoKit and system frameworks. Linux qualification copies the unmodified SDK/test sources to an ignored workspace and supplies module shims there. With `--mock-bluetooth`, it executes actual BLE adapter code against a development-only CoreBluetooth double. It does not establish native Apple framework or radio behavior.

The [1.0 verification record](verification-1.0-2026-10-26.md) reports current Linux and native Apple checks. The [earlier Linux record](verification-linux-2026-10-26.md) retains the pre-restoration results and their exact source commit.

## Reproduce software qualification on Linux

Install Swift 6.1 or later, SQLite headers, a C compiler, Python 3 and Node 22 or later. Use a reviewed Swift toolchain and verify its upstream signature. Then run:

```sh
python3 scripts/check-linux-core.py --mock-bluetooth --configuration debug
python3 scripts/check-linux-core.py --mock-bluetooth --configuration release
node scripts/check-interop-vector.cjs
```

`--swift /absolute/path/to/swift` selects an isolated toolchain. Tests use synthetic identities and temporary stores. The qualification driver prints exact development dependency revisions. Its crash probe kills separate processes after committed outbox, sender receipt and inbox/return writes and before an inbox transaction commits. Its scoped write interceptor forces actual SQLite disk-full errors for queue, inbox and receipt commits, checks rollback, retries and reopens the results.

## Background delivery boundaries

Event-driven scheduling can process work during execution opportunities the OS provides. iOS hosts own background-mode declarations, permissions and lifecycle integration. `BLEPacketLink(restoration:)` opts in to manager restoration under explicit host identifiers. Inherited central connections are quarantined until local disconnection and a fresh SDK connection request; peripheral services are rebuilt and require fresh subscription and authentication. No old peer challenges, partial frames or queued bytes are adopted, and pending originals remain paused after process reconstruction.

Restoration is a recovery attempt. Local Core Bluetooth cancellation does not guarantee immediate physical disconnection when another app shares the link. A surviving remote peer must observe service invalidation, resubscription or reconnection before a fresh challenge-pinned session can complete. The SDK fails closed if a fresh authenticated session cannot be established. Linux tests execute these adapter transitions using a development-only CoreBluetooth double; that is not native OS behavior or measured radio evidence.

Continuous TCP execution, delivery after force-quit and uninterrupted arbitrary-hop background routes are not established capabilities. Supported background states and recovery behavior need an explicit host contract and native implementation/verification before claiming those behaviors.

## Deployment evidence

Linux mocks do not compile against or execute Apple's native frameworks. Native Apple compilation is an independent CI check; real-device coverage is listed in [qualification](qualification.md). No independent security audit was performed. Key protection, at-rest file protection, host business transactions and an explicit history-retention policy remain host responsibilities.

Production release notes must state the actual supported operating conditions, exact-commit verification and known limits. Historical tags and verification records stay immutable. Do not convert the Linux test results into physical radio, background, latency or universal correctness claims.
