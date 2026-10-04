# Host-managed encrypted protocol profiles

`OpaquePacketRouter` is an alternative to `MeshNode` for an application that already owns an encrypted packet format, identity keys and durable message/result stores. The SDK owns native links, challenge-authenticated neighbors, signed route hints, forwarding priority and next-hop acknowledgments. The host owns its original wire bytes, cryptographic validation, persistence, replay protection, authorization and business receipts.

This feature does not wrap a host packet in the generic `EndpointEnvelope` or insert it into `MeshStore`. The generic `MeshNode` remains on wire version 2. A host profile is not automatically interoperable with another host profile or with a generic node.

## Assemble a profile

Choose a stable, versioned profile identifier, 1–128 UTF-8 bytes. All participating hosts must implement the same profile and codecs. Attach native `BLEPacketLink` and `TCPPacketLink` instances, or an independent `PacketLink` adapter. The router owns their callbacks; do not attach the same instances to another node/router.

Supply these host hooks:

| Hook | Host responsibility |
| --- | --- |
| `decode(Data)` | Validate host packet bytes, routing bounds and immutable hash consistency; verify any public authentication that its format supports and return an `OpaquePacket` descriptor |
| `forwarded(OpaquePacket)` | Produce exact host bytes with one fewer remaining hop, preserving every immutable field and its hash |
| `loadPending()` | Load already-durable, eligible packets for relay/return retries; enforce the host's retention and capacity policy |
| `persistRelay(OpaquePacket)` | Durably admit a foreign packet before acknowledgment; reject conflicting IDs/content and report storage/backpressure failures |
| `removeRelay(UUID)` | Retire only the foreign relay record after an authenticated next-hop acknowledgment; never mark an owned command delivered |
| `receiveEndpoint(OpaquePacket)` | Authenticate/decrypt, validate permission and complete the host's phase-specific processing; durably commit an applicable business result before issuing the host's business receipt |

Persistence and endpoint hooks are asynchronous. An error means no successful hop acknowledgment for that operation. The endpoint hook may intentionally handle a transient negotiation phase without a durable business result; that success must not be shown as completed business delivery. Throw `PechPechError.spoolFull` to expose relay backpressure through `onEvent`. Preserve independent owned-command and application-result records; a relay's bounded storage must not consume or discard them.

The descriptor records a UUID, 64-character lowercase hexadecimal destination/origin identity addresses, 0–8 remaining hops, priority 0–3, expiry, complete bytes and a 32-byte immutable hash. Bytes must be nonempty and at most 16 KiB. Expiry must be in the future and no more than one day ahead at validation time. The host defines and validates the immutable hash over its actual signed packet fields; exclude only intentionally mutable forwarding data, such as the hop counter.

Router metadata validation does not establish that arbitrary host bytes are encrypted or authentic. Verify public authentication in the codec where the format supports it, and enforce endpoint authentication and authorization in `receiveEndpoint`. A relay cannot verify a signature that is inside ciphertext addressed to another endpoint. A signed neighbor proves possession of its key; discovery, proximity and route hints never grant application permission.

## Sending, acknowledgments and lifecycle

Persist an immutable owned command through the host's original outbox before `await router.sendOrigin(packet)`. This method is one explicit attempt: it does not persist the origin in a relay spool or resume it later. The host retains its own IDs, creation times, retry intent, handoff screen and business-result reconciliation.

`start()` begins foreground links and a one-second retry/hello pass for packets supplied by `loadPending`. A received foreign packet spends one hop before durable admission. Retrying that saved copy does not spend another hop. Higher priority and earlier expiry are scheduled first; direct destinations and advertised shorter routes are preferred, with other authenticated opportunities still available.

An authenticated next-hop acknowledgment can retire a foreign relay copy only after that peer's host hook succeeds. For a foreign relay, the hook must durably store the exact packet. For an endpoint, it confirms successful phase-specific handling in the current session; a preparation or grant phase may remain intentionally volatile. It says nothing about final kitchen acceptance or other business completion. Only the host's independently authenticated receipt for a durable business result can resolve that action. Lost acknowledgments or callbacks remain compatible with idempotent host retries.

`stop()` closes links and gates late async continuations from sending on an obsolete session. An already-running durable host write or endpoint action cannot be recalled. Keep host processing transactional and idempotent, and do not accept unattended old actions merely because networking later returns.

Callbacks expose authenticated neighbor identities, signed route hints and link/storage events. Route hints are reachability estimates and can be dishonest, stale or interrupted; completion requires the host's receipt. Locking, suspension or leaving range may remove a path. Foreground operation is the initial qualified design scope.

## Bounds and security limits

The router allows four distinct authenticated neighbor identities and four transport handles per adapter. Advertised routes are capped at 32 entries with distance 0–7. Inbound handling uses a 64-frame burst with 32 frames/second replenishment per handle, at most 64 concurrent packet IDs, at most 64 concurrent acknowledgment-retirement IDs, and bounded sent/source caches. A retry pass considers at most 1,024 host-loaded packets. The host must bound its durable spool and the work required to load it; a processing cap is not a database-capacity policy.

These limits constrain ordinary resource use. They do not prove denial-of-service resistance, prevent Sybil peers, establish physical distance or guarantee a route/latency. Synchronous codec work and callback ordering remain on the main actor; asynchronous persistence must preserve the host's transaction order.

## Control-frame wire format

Each `PacketLink` carries complete JSON frames encoded with `WireCoding`: sorted keys, unescaped slashes, UTF-8, Base64-encoded `Data`, and the existing Swift UUID string representation. Host data packets are sent as the original host bytes. BLE/TCP framing is the same as the [native transport specification](protocol.md); opaque controls do not use `MeshFrame`'s generic packet wrapper.

`SignedOpaqueHello` has `kind = "pechpech-opaque-hello"`, `claims` and a 64-byte Ed25519 `signature`. The signature covers the exact canonical `claims` bytes. Claims contain:

- `protocolName = "pechpech-opaque-link-1"`, the exact host `profile`, `identity`, and a fresh session `challenge`.
- An optional `echo` of the peer's challenge; absent values are omitted by Codable.
- `routes`, a destination-address to distance dictionary with the bounds above.

The claimed `PublicIdentity` is validated, then its signing key verifies the signature. A neighbor becomes ready only after it echoes this router's challenge. Identity/challenge changes within a handle are rejected. Periodic hellos recover a dropped echo; a ready peer's hint expires after 15 seconds without a valid hello.

`SignedOpaqueAck` has `kind = "pechpech-opaque-stored"`, `claims` and a 64-byte Ed25519 signature over canonical claims. Claims contain `protocolName = "pechpech-opaque-ack-1"`, the exact `profile`, authenticated `senderID`, `packetID`, 32-byte `immutableHash`, and `echo` of this router's current challenge. The router requires the authenticated neighbor's signature, exact challenge/profile, and a matching hash for a packet actually queued to that neighbor before asking the host to retire the foreign relay record.

Opaque control domains are distinct from generic wire-version-2 controls. A profile upgrade that changes host bytes or semantics requires its own compatibility and migration review. Tests of one host codec do not qualify arbitrary profiles or later Android/browser implementations.

The independently generated [opaque-control-v1 fixture](../Tests/PechPechCoreTests/Fixtures/opaque-control-v1.json) publishes exact claims/frame bytes and Ed25519 signatures for hellos with and without an echo and an acknowledgment. Fixed repeated-byte seeds are explicitly synthetic. The [Node/OpenSSL checker](../scripts/check-interop-vector.cjs) regenerates and verifies these bytes/signatures independently of CryptoKit, alongside the generic version-2 encryption vector. A passing static vector does not qualify a radio adapter or host business protocol.
