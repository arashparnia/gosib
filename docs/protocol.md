# PechPech wire protocol

This document describes the generic `MeshNode` version-2 wire format, introduced in PechPech 0.2 and retained in 0.3. PechPech (پچ‌پچ) means whispering. The package version and wire version are separate. This is an experimental application protocol over BLE or TCP, not Bluetooth SIG Mesh or a host's existing business protocol.

The 0.2 release changes modules, discovery, cryptographic domains and storage namespaces. It does not interoperate with the prior 0.1 release. See [compatibility and migration](migration-0.2.md) before upgrading an existing host.

PechPech 0.3 also provides [opaque host profiles](opaque-profiles.md) with separate challenge/acknowledgment domains. Those profiles reuse native framing while retaining host-owned endpoint bytes and storage. Their packets and receipts are not the generic envelopes specified here.

The 0.x API may evolve. A wire-breaking change requires an explicit version/domain change, revised interoperability vectors and documented old-peer behavior. Peers reject unsupported protocol/version and unknown envelope/frame kinds rather than guessing their meaning.

## Identities and trust

`Identity` contains separate Ed25519 signing and X25519 agreement private keys. `PublicIdentity` carries their 32-byte public representations. The endpoint address is lowercase hexadecimal SHA-256 of `signingKey || agreementKey`, yielding 64 characters.

The host securely persists its private keys and pins the intended recipient identity through its own enrollment or trust procedure. A self-signed identity proves possession of a key, not a person's identity or permission to act. Relaying an opaque packet never requires business membership at the destination; accepting an application message requires the host's authorization policy.

## Encoding

`WireCoding` emits UTF-8 JSON with lexicographically sorted object keys and unescaped forward slashes. Binary `Data` fields use standard base64. UUIDs use uppercase canonical hyphenated strings. Time values are integer Unix milliseconds. Strings use standard JSON escaping without Unicode normalization. The protocol models contain no floating-point values.

Other implementations must reproduce these bytes when computing a message hash or authenticated header. The signature covers the exact encoded envelope bytes carried inside the ciphertext. [The canonical interoperability fixture](../Tests/PechPechCoreTests/Fixtures/canonical-v2.json) includes synthetic addresses, message/header encodings, a message hash, signature input/result and an encrypted packet. Its repeated-byte private keys are test material, never operational identities. The release includes a Swift reference implementation; Android and other language implementations remain future work.

An optional independently implemented Node/OpenSSL [vector checker](../scripts/check-interop-vector.cjs) verifies the fixture's exact encodings, identities, signatures, key agreement, derivation and authenticated decryption. It uses Node 22+ built-in modules with no provider credentials or external dependencies:

```sh
node scripts/check-interop-vector.cjs
```

Passing a static vector is a useful interoperability check, not proof of a complete cross-platform radio implementation.

`Message` contains `id`, `senderID`, `destinationID`, `channel`, `payload` and `createdAt`. Its body hash is SHA-256 of the complete canonical message encoding, including its immutable identity, addresses, channel and creation time. A channel is 1–128 UTF-8 bytes; payload is at most 4,096 bytes. The host defines payload semantics.

`EndpointEnvelope` has an explicit `kind` discriminator:

| Kind | Fields | Meaning |
| --- | --- | --- |
| `message` | `message` | Immutable application bytes |
| `receipt` | `receipt` | Recipient's durable inbox result |
| `receiptStored` | `messageID`, `bodyHash` | Sender durably saved the matching receipt |

`DeliveryReceipt` contains `messageID`, `bodyHash`, `senderID`, `receiverID` and `acceptedAt`. The name `acceptedAt` refers to inbox storage time; it does not establish business approval.

## Endpoint encryption

`PacketHeader` contains `protocolName="pechpech"`, `version=2`, `packetID`, `destinationID`, `sender`, `ephemeralKey`, `priority`, `expiresAt` and `hopLimit`.

For each newly sealed endpoint envelope:

1. Generate a fresh ephemeral X25519 agreement key and encode the header.
2. Agree that ephemeral key with the intended recipient's persistent X25519 public key.
3. Derive a 32-byte key with HKDF-SHA256. Salt is UTF-8 `PECHPECH-2-X25519-HKDF-SHA256-AES256GCM-Ed25519`; shared information is the encoded header.
4. Encode the endpoint envelope. Ed25519 signs `headerBytes || envelopeBytes`.
5. Encode `{payload: base64(envelopeBytes), signature: base64(signature)}` and encrypt it using AES-256-GCM with the header bytes as associated data and a fresh random nonce.
6. Carry `nonce || ciphertext || tag` in the relay packet's `encrypted` field.

The recipient validates the addressed identity, supported protocol/version, bounds and expiry before opening the authenticated ciphertext. It verifies the sender signature over the exact envelope bytes and then applies its application authorization policy. Relays cannot decrypt, modify or mint a valid endpoint receipt.

Retaining and retransmitting the same authenticated ciphertext is permitted. Never reuse a nonce to encrypt changed plaintext. Re-sealing a retry must use new ephemeral key material and a fresh nonce while preserving the immutable message identity and contents.

## Relay packets and limits

`RelayPacket` contains `header`, `encrypted` and `hopsRemaining`. Packet identity, destination, origin, priority and expiry derive from the header. Only `hopsRemaining` changes during honest forwarding. The authenticated `hopLimit` is 1–8; remaining hops must be 0–`hopLimit`.

| Bound | Initial value |
| --- | --- |
| Application payload | 4,096 bytes |
| Encoded relay packet | 16,384 bytes |
| Packet lifetime | At most 600,000 milliseconds |
| Initial hop limit | Eight |
| Durable relay spool | 512 packets / 8 MiB |
| Claimed-origin spool allowance | 128 packets |
| Authenticated endpoint neighbors in `MeshNode` | Four distinct identities |
| Native adapter neighbor limit | Four per adapter |

`PacketPriority` is integer `0=bulk`, `1=normal`, `2=urgent`, `3=receipt`. Resource priority does not prove that a packet is legitimate or grant sender authorization. Expiry uses wall-clock Unix time and therefore depends on device clock accuracy.

`EndpointCrypto.seal` defaults to a 60,000-millisecond packet lifetime. Validation requires a positive remaining lifetime no greater than 600,000 milliseconds at the receiving device's clock. Clock skew can therefore reject otherwise authentic packets; account for this in offline deployment testing.

The original message's durability is separate from packet lifetime. An expired transport packet does not erase an owned message; recovery can create a fresh packet for the same immutable message.

The relay spool admits packets transactionally. It prunes expired traffic and may evict strictly lower-priority copies to admit higher-priority work. Equal/higher-priority copies are not victims. The same rule applies within the claimed-origin allowance. Failed admission rolls back every candidate eviction. A duplicate packet ID requires identical header/ciphertext, and its persisted remaining-hop count may only decrease. Spool priority and origin addresses are untrusted resource hints at a relay, not authenticated application authorization.

The mutable remaining-hop count bounds honest forwarding. A hostile relay can reset it within the accepted limit, so it does not cryptographically confine traffic to eight physical hops or a geographic area.

## Neighbor control frames

The packet bytes delivered by a `PacketLink` encode a `MeshFrame`, not a bare relay packet. Its explicit `kind` is `hello` (field `hello`), `packet` (field `packet`) or `stored` (field `ack`). The complete encoded frame must also fit 16,384 bytes.

`SignedHello` carries `claims` and `signature`. Claims contain `protocolName="pechpech-link-2"`, the public `identity`, a random link-local `challenge`, and optional `echo`. The signature is Ed25519 over canonical claims. Each side echoes the other's challenge in its signed hello; a node marks the neighbor ready only after verifying a response to its fresh local challenge. The identity and remote challenge stay bound to that link handle until disconnection. A replayed advertisement or self-signature alone does not complete this handshake.

`SignedRelayAck` likewise carries signed claims: `protocolName="pechpech-relay-ack-2"`, `senderID`, `packetID`, `packetHash` and `echo`. The packet hash is SHA-256 of `canonicalHeaderBytes || encryptedBytes`, excluding mutable remaining hops. The echo binds the acknowledgment to the current neighbor challenge. The node also checks that it actually sent that immutable packet to the authenticated neighbor before removing an opaque relay copy.

A `stored` acknowledgment follows durable relay admission or endpoint persistence. It retires only a relay copy. It cannot erase an owned outbox message or recipient return record, and it cannot resolve endpoint delivery. The independent encrypted endpoint receipt does that.

`MeshNode` uses bounded opportunistic forwarding: prefer a directly connected destination, then try other authenticated neighbors, avoiding the immediate source and original sender. It decrements the hop budget when forwarding foreign packets. There is no topology consensus or proof that a visible neighbor can reach the final recipient.

While running, one-second ticks retry outstanding work and send signed hello/echo frames even on locally ready links. This lets the other side recover a lost final echo without replacing the link's challenges. Failed local queue admission does not advance the node's echoed-challenge marker. Unchanged owned packets reuse their current packet identity/ciphertext; a fresh packet is sealed near expiry. The `transmitting` event means attempts can use a local neighbor, not that a usable end-to-end route or receipt exists. `waitingForRoute` means no authenticated neighbor is currently available.

## Receipt boundaries

The intended recipient authorizes and stores message bytes before creating an endpoint receipt. It records the durable result and outgoing receipt in one transaction. Identical replay recovers a prior result; a conflicting message ID/body is rejected.

The sender validates the authenticated recipient identity, original message and body hash, then durably saves the receipt. Only this boundary can resolve framework delivery. An authenticated `receiptStored` from the original sender retires the recipient's active return packet; durable inbox and result records remain available for replay recovery.

Owned outbox/inbox records are retained independently of relay expiry and capacity. Successfully delivered outgoing messages leave the pending query, but their immutable snapshots and receipts remain. There is no automatic deduplication-history compaction in the current generic store. When an outgoing receipt packet expires, retrying the original immutable message can regenerate it from the durable inbox result.

Link queue admission, completed BLE/TCP writes and next-hop storage acknowledgments are earlier boundaries. None proves durable endpoint storage. A lost receipt leaves delivery uncertain; a timeout cannot prove the recipient never received it. Receipts may return through a different relay chain.

Business execution belongs to the application. Applications need their own idempotent command/result protocol and durable transaction for any side effect. PechPech does not implement leader election, automatic authority replacement, order grants or replicated business-state merging.

## Native framing

TCP/Bonjour advertises `_pechpech._tcp`. Each nonempty frame has a four-byte unsigned big-endian length followed by 1–16,384 bytes. The framing layer provides message boundaries only; endpoint encryption provides payload confidentiality and authentication.

BLE uses service UUID `89B515C0-7D3F-4BD9-AC0B-6EC466823C62` and message characteristic UUID `89B515C1-7D3F-4BD9-AC0B-6EC466823C62`. Its 12-byte fragment header is:

| Bytes | Field |
| --- | --- |
| 0–1 | Magic `0x50 0x50` (`PP`) |
| 2 | Version `2` |
| 3 | Reserved `0` |
| 4–7 | Nonzero unsigned 32-bit message ID, big-endian |
| 8–9 | Unsigned 16-bit total message bytes, big-endian |
| 10–11 | Unsigned 16-bit fragment offset, big-endian |
| 12 onward | Fragment payload, bounded by the negotiated ATT value size |

Per-neighbor reassembly checks message ID, total length and contiguous offsets. A new zero-offset fragment replaces an abandoned partial stream. Packet/message identity and durable receipts recover any lost prior message. BLE transmission finishes an already-started stream before selecting a higher-priority message.

Discovery names use `PP-` followed by the first ten bytes of SHA-256 of the node name rendered as twenty hexadecimal characters. They select topology rather than authenticate identities. PechPech's service, framing magic and key-derivation domain are distinct from the prior 0.1 release and deployed GARVI peers; connecting the protocols requires a reviewed adapter rather than renaming a service.

## Threat model and non-guarantees

Payloads are confidential and sender-authenticated between endpoints with uncompromised keys. Routing addresses, priorities, expiry, payload lengths and traffic timing remain visible. Native TCP is not TLS-encrypted by this adapter; encrypted endpoint payloads remain protected, while control and routing metadata do not become anonymous.

An untrusted relay may drop, delay, replay, reorder or withhold traffic. Claimed-origin limits can be bypassed with new identities, and forged priorities can consume resources. Bounds mitigate resource growth; they do not guarantee availability under malicious participation.

The static recipient agreement key means recorded traffic can become decryptable after later compromise of that key: the protocol does not provide forward secrecy against that compromise. Host key storage, at-rest data protection, rotation, trust revocation and business authorization remain application responsibilities.

There is no distance-based security proof, unattended background delivery guarantee, arbitrary-hop latency target, anonymity or physical coverage guarantee. See [integration](integration.md), [security policy](../SECURITY.md) and [qualification](qualification.md).
