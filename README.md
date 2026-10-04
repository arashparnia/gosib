# PechPech

**Nearby messages, carried together.**

**PechPech (پچ‌پچ)** means whispering in Persian. The name draws on the [whispering game](https://www.beytoote.com/fun/native-games/local5-games-iran.html), where a message passes from one person to the next.

PechPech is an open-source Swift SDK for encrypted, offline, store-and-forward messaging. Nearby devices can carry opaque packets toward a recipient and return its authenticated receipt through another path. It needs no cloud service on the message path.

Developed from GARVI's restaurant communication work, PechPech separates the reusable mechanism from restaurant orders, menus, accounts, and screens. You can build your own payloads and application rules on top of it.

**Status: experimental 0.2.0.** Native iPhone, iPad, and Mac hosts are supported at the source level. Physical radio deployment, latency, and background operation remain unqualified. A usable radio path and OS permissions are required. Android and browser implementations are future work.

## What is included

| Component | Provides |
| --- | --- |
| `PechPechCore` | Endpoint identities, authenticated encryption, immutable durable outbox, deduplicated inbox, endpoint receipts, and relay scheduling |
| `PechPechApple` | Concurrent BLE scanning/advertising, multiple neighbors, TCP/Bonjour links, bounded transport queues, and host-scoped Keychain identity storage |
| `pechpech-demo` | A runnable two-hop example using injected links and temporary databases; no radios or credentials |

Default bounds are four authenticated neighbor identities, eight forwarding hops, 16 KiB complete wire frames, 4 KiB application payloads, and a relay spool of 512 packets / 8 MiB. Orders, sensor readings, collaborative tools, event operations, and other small-message applications can define their own versioned channels.

A **delivery receipt means the intended endpoint durably stored the exact message bytes**. Local queue admission and relay acknowledgments do not mean delivery. A receipt does not establish that a business action succeeded; that requires your application's authorization and idempotent transaction.

## Try it

Requires macOS 13+, Xcode's Swift toolchain, and Swift 5.9 or later. The libraries also target iOS 16+.

```sh
git clone https://github.com/arashparnia/pechpech.git
cd pechpech
swift test
swift run pechpech-demo
```

The demo creates sender → relay → receiver, saves a message before transmission, verifies its durable endpoint receipt, and replays it without creating a duplicate inbox entry. This exercises the real core protocol and persistence through a deterministic adapter; it does not measure physical Bluetooth performance.

With Node 22+, `node scripts/check-interop-vector.cjs` independently verifies the published synthetic crypto vector using Node/OpenSSL. No additional packages are required.

## Add to an Apple app

Add the package in Xcode or in your package manifest:

```swift
.package(url: "https://github.com/arashparnia/pechpech.git", .upToNextMinor(from: "0.2.0"))
```

Depend on `.product(name: "PechPechCore", package: "pechpech")` and, for native links, `.product(name: "PechPechApple", package: "pechpech")`.

Assemble and retain the node on the main actor. Your app supplies a persistent database URL, an authenticated recipient identity, and a sender allowlist; discovery must not create trust automatically.

```swift
import Foundation
import PechPechCore
import PechPechApple

// Host-selected namespace; use your own identifier and valid signed Keychain context.
let identity = try KeychainIdentityStore.loadOrCreate(
    service: "com.example.nearby.identity"
)
let node = try MeshNode(
    identity: identity,
    store: MeshStore(url: databaseURL),
    links: [BLEPacketLink(), TCPPacketLink(includePeerToPeer: true)],
    authorize: { message, sender in
        permittedSenderIDs.contains(sender.id) && message.channel == "notes.v1"
    }
)
node.onMessage = { received in
    // Inbox bytes are already saved. Process through your own durable action ledger.
    print("Stored message", received.message.id)
}
node.onDelivery = { message, _ in
    print("Recipient durably stored", message.id)
}
node.start()

let message = try node.enqueue(
    to: enrolledRecipient,
    channel: "notes.v1",
    payload: Data("Station A is ready.".utf8)
)
```

The snippet belongs inside a `@MainActor` host context. Keep `node` alive and expose route, permission, storage, and backpressure events in your UI. Configure the Bluetooth/local-network purpose strings, Bonjour service, and platform capabilities described in [integration](docs/integration.md).

For a relay-only participant, return `false` from `authorize`; it can still carry other endpoints' encrypted packets. Each recipient independently decides which senders and channels may enter its inbox.

Retries use the saved immutable record: `try node.resume(message.id)`. `node.pause(message.id)` stops new origin attempts. `node.stop()` closes links and pauses owned messages; after restart, pending outgoing records require explicit resume. Already transmitted packets cannot be recalled. Recover unfinished business processing from `store.inbox()` and your own processing ledger, rather than depending on callbacks to repeat after restart.

## Protocol and qualification

- [Architecture](docs/architecture.md): layers, persistence, routing, and application boundaries.
- [Wire protocol](docs/protocol.md): versioned encoding, cryptography, control frames, framing, and synthetic interoperability vectors.
- [Integration](docs/integration.md): identity storage, enrollment, lifecycle, permissions, and custom transports.
- [Qualification](docs/qualification.md): software evidence and the physical-device matrix still required.
- [Current verification record](docs/verification-2026-10-04.md): checks completed for this release and their limits.
- [Upgrade guide](docs/migration-0.2.md): module, wire, storage, and version boundaries.

Endpoint encryption uses X25519, HKDF-SHA256, AES-256-GCM, and Ed25519. Relays can see routing metadata and traffic timing, but not message contents. This initial design does not provide forward secrecy against later compromise of the recipient's long-term agreement key. Hosts own secure key storage, at-rest protection, trust revocation, and business permissions. See the [security policy](SECURITY.md).

This is an application protocol over BLE/TCP, not Bluetooth SIG Mesh. Apple's peer-to-peer option permits eligible paths; it does not force a radio path or guarantee reachability. Tests do not establish a background delivery or arbitrary-hop latency guarantee. The initial deployment scope is foreground native apps.

PechPech has fresh Git history, its own discovery identifiers, cryptographic domain, and storage namespace. Existing GARVI installations and their deployed protocol are unchanged; adopting this SDK there requires a reviewed migration.

## Contribute

Issues, documentation, interoperability work, and small, tested pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md). CI runs tests, a release build, an iOS simulator library compile, and the injected-link demo on Apple Silicon and Intel macOS.

Useful next contributions include qualified physical-device evidence, scheduling work off the UI actor, reviewed retention policies, and independent Android interoperability. Report vulnerabilities through [SECURITY.md](SECURITY.md), without posting private keys or application data.

## License

[MIT](LICENSE). Copyright © 2026 Arash Parnia.
