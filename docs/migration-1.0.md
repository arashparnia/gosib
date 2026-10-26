# Upgrading to PechPech 1.0

PechPech 1.0 establishes the stable public API contract. It retains generic wire version 2, opaque control version 1, discovery identifiers, cryptographic domains and the 0.2/0.3 database schema. Upgrading from 0.3.1 does not require a message-store or identity migration. Existing IDs, pending originals, saved receipts and Keychain service/account selections must remain unchanged.

## Toolchain

Use Swift 6.1 or later, with iOS 16/macOS 13 deployment targets. The package retains Swift 5 language mode. The earlier Swift 5.9 claim did not cover the native adapter's Swift 6 `@preconcurrency` conformances; the manifest now declares the supported compiler requirement explicitly. Xcode must provide that Swift toolchain.

Use a stable major-version dependency range:

```swift
.package(url: "https://github.com/arashparnia/pechpech.git", .upToNextMajor(from: "1.0.0"))
```

## Lifecycle and storage

Existing `start`, `stop`, `pause`, `resume` and receipt boundaries remain. A process restart does not authorize resuming original outgoing messages. Queue admission and relay acknowledgments still cannot resolve delivery. The store now prunes expired return-packet copies while retaining immutable inbox/result receipts; original-message replay can regenerate the return packet.

Custom adapters may implement `PacketLink.onWorkAvailable` to retry refused queue admission when capacity returns. The default callback implementation preserves existing conformers. Opaque routing retains bounded admission proof across retry passes and suspended host reads; backpressure is reported instead of overwriting authentication evidence.

## Optional background integration

`BLEPacketLink()` keeps restoration disabled. Opt in using stable host-selected `BLERestorationConfiguration` identifiers and declare the required host background modes. Choose `setRetryScheduling(.eventDriven)` to service transport wake opportunities without a node polling task; return to `.periodic` for one-second retries.

Restoration resets inherited connections and GATT services before fresh neighbor authentication. It does not adopt old authenticated readiness or resume original outgoing intent. The host recreates a node only under its own authorized app/scene lifecycle policy. OS wake availability, permissions, key/database accessibility and physical radio coverage remain host deployment conditions; continuous TCP or force-quit delivery is not promised.

Hosts upgrading from 0.1 must first follow [the incompatible namespace migration](migration-0.2.md). Existing application-managed opaque profiles retain their own wire, persistence and business-result migration obligations.
