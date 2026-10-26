# Integrating PechPech

The first package supports native iOS 16+ and macOS 13+ applications using Swift 5.9+. It has no external package dependencies. Add `PechPechCore` for protocol and storage, and `PechPechApple` for the native BLE/TCP adapters. The root [README](../README.md) and `pechpech-demo` provide a runnable core example.

Both library products include SwiftPM resource bundles with a privacy manifest and full MIT notice. Retain them in the distributed host and review the app's own data disclosures; see [packaging and privacy](packaging.md).

These generic-node instructions target PechPech 0.3.1 and wire version 2, with the same storage namespace as 0.2. The prior 0.1 release is incompatible. Choose a dedicated current-release database or complete a reviewed migration using [the upgrade guide](migration-0.2.md); preserve unresolved records and private identities.

If the host already owns an encrypted envelope, persistent keys and durable message/business ledgers, consider the separate [opaque profile integration](opaque-profiles.md). `OpaquePacketRouter` shares native transport and neighbor authentication while preserving host-owned bytes and persistence; it does not automatically convert data to the generic `MeshStore` or receipt model.

## Trust and application behavior

Persist a stable `Identity` in the platform's secure storage. Pin the intended `PublicIdentity` using an application-owned enrollment procedure. Require an explicit sender authorization policy when creating the node. A permissive demo policy is appropriate only for synthetic test data, never a production default.

Native hosts can use `KeychainIdentityStore.loadOrCreate(service:account:)` from `PechPechApple`. Choose a unique, stable service in your own bundle namespace and keep the account stable; its default is `"endpoint"`. The helper uses Apple's [data-protection Keychain](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain), disables synchronization and stores keys with [AfterFirstUnlockThisDeviceOnly](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly) accessibility. Keys become available after the first unlock following restart and do not migrate to a different device through backup restoration.

The helper's local private-record encoding remains version 1, independently of wire version 2. A wire upgrade is not permission to replace a stored identity or change the host's Keychain service/account silently.

Existing invalid or inaccessible records are errors, not overwritten identities. A concurrent creation reads back the winning saved identity. The helper has no plaintext or legacy-Keychain fallback and chooses no team or access group for you. A signed host needs a valid Keychain context; an unsigned SwiftPM CLI may fail with `errSecMissingEntitlement`. Resolve access or restore the original trusted identity instead of creating a replacement to hide an error. Key rotation and migration remain explicit application work.

For example, after the host restores `identity`, chooses `databaseURL` and obtains an authenticated `permittedSenderIDs` allowlist, assemble a node on the main actor:

```swift
import Foundation
import PechPechCore
import PechPechApple

let node = try MeshNode(
    identity: identity,
    store: MeshStore(url: databaseURL),
    links: [BLEPacketLink(), TCPPacketLink(includePeerToPeer: true)],
    authorize: { message, sender in
        permittedSenderIDs.contains(sender.id)
            && message.channel == "example.v1"
    }
)
```

The host supplies those variables; discovery must not populate the allowlist automatically. A relay-only node can return `false` from the authorization closure and still forward packets for other endpoints. The closure authorizes inbox storage, not an arbitrary business action.

Prefer `MeshNode` over directly manipulating low-level receipt APIs. A direct `MeshStore` user must call `bindIdentity(_:)` first, authenticate and authorize the sender itself, and supply a trusted receipt-sealing factory to `accept`. The store is a persistence boundary, not a replacement for endpoint cryptographic verification.

Messages carry immutable bytes, not an application transaction. Define a versioned payload schema and channel, validate bounds and authenticate the permitted sender before performing an action. A `DeliveryReceipt` establishes durable inbox storage; process business actions through an application-owned idempotent transaction and return a separate authenticated business result.

Restore pending outgoing messages, inbox processing state and receipts after restart. Do not regenerate a message ID for a retry or show a local send/relay acknowledgment as endpoint success. Expose missing routes, backpressure, denied permissions and storage errors in the host UI. A pending message can remain uncertain after an app closes.

`enqueue(to:channel:payload:id:priority:startSending:)` validates and persists a new immutable message, then starts its transmission if requested and the node is running. In 0.3, repeating a caller-supplied ID with the same recipient, channel, payload and priority reuses the saved creation time and delivered state; conflicting fields fail. For an already saved message, prefer explicit `resume(messageID)` rather than constructing a new `Message` with the old ID and a different creation time. `pause(messageID)` stops new origin attempts; already transmitted packets cannot be recalled. `stop()` closes links and pauses owned work. `start()` resumes foreign relaying and receipt retries while restored outgoing messages stay paused until explicit `resume`.

`onMessage` reports newly stored messages and `onDelivery` reports a newly saved matching endpoint receipt. Callbacks are not a durable business-processing queue. After restart, read `store.inbox()` and your application processing ledger to recover unfinished actions, and query saved receipts to restore delivery state.

## Native links

`BLEPacketLink()` scans and advertises concurrently. `TCPPacketLink(includePeerToPeer: true)` uses Network framework TCP and Bonjour, permitting Apple's eligible peer-to-peer paths alongside available LAN paths. Passing `false` disables that peer-to-peer option; neither setting forces a particular radio path.

Both conform to the `@MainActor` `PacketLink` interface. Keep adapters and the node alive for the active session. The node owns their message/peer callbacks; avoid replacing callbacks after attachment.

`PacketLink.send(_:to:priority:)` returns `true` for local queue admission only. `onLinkReady` establishes a transport handle, not authenticated application trust. `confirmPeer(_:)` is called only after the protocol authenticates that neighbor; for TCP it removes the initial setup timeout. Do not call it merely because Bonjour found a service or a BLE connection opened.

Each adapter is capped at four neighbors. BLE peer queues hold at most 32 messages / 128 KiB. TCP peer queues hold at most 256 KiB including framing. BLE selects higher priorities between complete message streams; TCP retains socket ordering rather than preempting already queued bytes. Applications should keep bulk traffic paced and avoid flooding transport queues.

The unreleased `PacketLink.onWorkAvailable` callback reports that previously refused local admission may fit again. Nodes coalesce that event and retry eligible work without treating queue drain as delivery. Existing custom adapters can keep using host retry scheduling through the default no-op callback implementation.

The node additionally caps ready neighbors at four distinct endpoint identities across its links. Its `waitingForRoute` event means there are no authenticated neighbors; `transmitting` means there is a local forwarding opportunity. Neither event proves final-recipient reachability. Use authenticated delivery receipts for completion and application-specific uncertainty feedback while waiting.

The initial node schedules synchronous storage and cryptographic work on the main actor. Keep callbacks brief and qualify responsiveness under your workload, especially with saturated spools or large history. No UI frame-time or latency guarantee is established by the package's injected-link tests. Moving scheduling work off the UI actor while preserving storage and callback ordering is a future improvement.

## Permissions and capabilities

Add human-readable purpose strings and the declared service to the host app's `Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Connect with nearby devices to exchange messages.</string>
<key>NSLocalNetworkUsageDescription</key>
<string>Find nearby devices and exchange messages on the local network.</string>
<key>NSBonjourServices</key>
<array>
    <string>_pechpech._tcp</string>
</array>
```

Use purpose text that accurately describes your product. Bluetooth and local-network permission prompts are controlled by the OS; PechPech cannot bypass them. Handle denied access and a later Settings change. Apple's [local-network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) explains these keys and the permission lifecycle.

For a sandboxed native Mac host using TCP, enable both outgoing client and incoming server network access. The adapter listens and connects. See Apple's [server entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server). Configure appropriate Bluetooth access for the host's sandbox and distribution configuration.

This package does not create an App Clip, request background modes, provision signing or configure store releases. Reduced host environments need their own capability review and qualification.

## Lifecycle

Start the nearby session while the host is foreground and stop it when the intended session ends. Stop new attempts when user intent or host lifecycle requires it. Durable outgoing state remains recoverable independently of transient transport queues.

A foreground receiver is the initial scope. Suspension, locking, force-quit or an out-of-range intermediary may break a path. New Apple background facilities are separate deployment work; adding a background entitlement does not prove continuous receiving. See [qualification](qualification.md).

### Event-driven background integration (unreleased)

`MeshNode` and `OpaquePacketRouter` add `setRetryScheduling(.eventDriven)` to stop polling while retaining current links and caller-authorized work. Change back to `.periodic` when the host wants periodic retries; that also requests an immediate retry pass. Explicit `tick()` remains available. Changing scheduling is distinct from `stop()`, which closes links and cancels current outgoing intent. A reconstructed generic node still requires explicit resumption of original outgoing messages.

A host that uses iOS Bluetooth background events must declare the applicable `UIBackgroundModes` values, `bluetooth-central` and `bluetooth-peripheral`, and retain/recreate its node according to its own lifecycle policy. The OS controls wake opportunities and changes discovery/advertising behavior in the background. TCP is not a continuous background transport. See [Apple's background guidance](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html).

Opt in to manager restoration with identifiers that remain stable across authorized launches:

```swift
let restoration = try BLERestorationConfiguration(
    centralIdentifier: "com.example.host.pechpech.central",
    peripheralIdentifier: "com.example.host.pechpech.peripheral"
)
let ble = BLEPacketLink(restoration: restoration)
```

Pass `ble` to the node/router, then select `.eventDriven` when the host wants transport-event scheduling. `BLEPacketLink()` remains opt-out. Identifiers must be nonempty, distinct, at most 1,024 UTF-8 bytes and contain no null characters. The host recreates the same identifiers only when its persisted session policy authorizes a nearby session; it must handle its app/scene restoration lifecycle rather than relying solely on nonnil launch options. Host background capabilities and permission prompts remain outside the adapter.

Restored connections are not authenticated peers. The adapter resets inherited sessions, waits for local disconnection before requesting a fresh connection, republishes fresh GATT services and requires fresh subscription/authentication. Local cancellation does not guarantee immediate underlying physical disconnection; a surviving remote peer may need service invalidation or reconnection before a fresh handshake succeeds. Restored outbox messages still require explicit resume. This is OS-permitted background recovery, without a continuous-delivery, force-quit, coverage or latency guarantee. See [Apple's relaunch rules](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules) and [production readiness](production-readiness.md).

## Adding another transport or platform

Implement `PacketLink` with bounded complete-packet reads and queues, clear connection state, honest queue-admission return values, and independent neighbor buffers. Preserve endpoint encryption, message identity, durable relay acknowledgment and endpoint receipt semantics. The generic `LengthFramer` helper can round-trip empty frames; native adapters reject empty packet bytes, and an empty frame is not a valid endpoint packet.

An Android implementation must reproduce the [wire protocol](protocol.md) and crypto test vectors, implement native radio discovery/permissions, and pass interoperability and physical-device tests. A browser client needs an available supported transport or a native bridge; this release supplies neither. Do not advertise full browser/Android interoperability based on JSON compatibility alone.
