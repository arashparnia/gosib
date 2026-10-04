# Upgrading to PechPech 0.2

PechPech (پچ‌پچ) means whispering. Release 0.2.0 applies the new name to the public SDK and introduces wire version 2 with distinct discovery, cryptographic and storage namespaces. This is a breaking release, not a cosmetic substitution on an established network.

## Compatibility

| Boundary | Current 0.2 value | Upgrade effect |
| --- | --- | --- |
| Swift package | `PechPech` | Update the dependency and package identity |
| Library modules/products | `PechPechCore`, `PechPechApple` | Update imports and product dependencies |
| Demo | `pechpech-demo` | Update local commands |
| Endpoint protocol | `pechpech`, wire version `2` | Prior 0.1 packets are rejected |
| HKDF domain | `PECHPECH-2-X25519-HKDF-SHA256-AES256GCM-Ed25519` | Old ciphertext cannot be relabeled as a current packet |
| Neighbor controls | `pechpech-link-2`, `pechpech-relay-ack-2` | Prior handshakes/acknowledgments do not establish a current link |
| TCP discovery | `_pechpech._tcp` | Prior peers are not discovered as current peers |
| BLE | New service/characteristic UUIDs and `PP` / version `2` framing | Prior radio frames are incompatible |
| Durable tables | `pechpech_` namespace | No automatic prior-database conversion |

The canonical version-2 fixture and its independent checker define the current byte-level interoperability target. The [wire protocol](protocol.md) lists exact fields, UUIDs, bounds and crypto operations.

The versioned host payload/channel schema is separate from the transport wire version. Update it only when its own semantics change. Likewise, the optional Keychain helper's local private-record format stays version 1; the wire upgrade does not require silently replacing endpoint keys.

## New deployments

Use current modules with a new, dedicated SDK database and an explicitly chosen stable Keychain namespace. Enroll/pin the intended endpoint and authorize senders through the application. Do not use a broad 0.x dependency range that permits unreviewed breaking upgrades; the README uses `.upToNextMinor(from: "0.2.0")`.

All participants on a usable path need the current protocol. A prior-release intermediary cannot forward current frames merely because it is nearby. There is no mixed-version relay bridge in 0.2.

## Existing deployments

Preserve the existing database and secure identity before changing the host. A file containing unrecognized user tables is rejected before current tables or WAL configuration are created; that rejection protects records and requires an explicit next step. Never clear the error by deleting the database, resetting keys, rewriting table prefixes or bulk resubmitting pending messages with fresh IDs.

A safe application migration must account for both ends of each message and their business processing:

1. Stop new application submissions while reviewing outstanding work. Already transmitted packets cannot be recalled; a missing receipt is uncertainty, not proof of non-delivery.
2. Prefer reconciling outstanding messages using the compatible prior-release deployment before switching the network. Keep the old stores and keys available until delivery state is understood.
3. For a migration tool, retain exact immutable message IDs/contents, pinned recipient identities, saved inbox/dedup results, endpoint receipts and application action ledgers. Sender and recipient history must agree; copying only a sender's pending outbox to an empty recipient store can replay an action already executed.
4. Re-seal supported messages for the new wire format using fresh cryptographic material. Do not alter an old encrypted header or carry incompatible return/relay packets into the new spool.
5. Coordinate the relevant endpoint/relay upgrade, verify authorization and identity continuity, and test duplicates, lost receipts, restart and paused intent before resuming application work.

There is no production migration or bridge utility in this release. A host without reviewed migration code can start a separate deployment for new traffic while retaining the earlier deployment for its unresolved history. Starting a new database does not establish that old pending work is safe to replay or discard.

Existing GARVI installations are unaffected. They retain their own production wire protocol and stores; adopting this SDK requires a separate reviewed application adapter and migration.

## Evidence

The [3 October record](verification-2026-10-03.md) concerns the prior 0.1 implementation. Its presence and current document branding do not qualify 0.2 names, wire bytes or schemas. Current-release checks belong in [qualification](qualification.md), with their date and actual results. Physical radio, background, latency and real Keychain deployment limits continue to apply.
