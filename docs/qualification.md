# Verification and qualification

PechPech 0.3 is experimental. The repository separates deterministic software checks from deployment claims that require real devices.

[The current 0.3 record](verification-0.3-2026-10-04.md) separates SDK and packaging checks from host deployment qualification. [The 4 October 0.2 record](verification-2026-10-04.md) retains the earlier source and version-2 interoperability results. [The historical 3 October record](verification-2026-10-03.md) applies to the prior 0.1 revision; it does not qualify current names or wire bytes. See [compatibility and migration](migration-0.2.md) before an upgrade.

## Software checks

Run `swift test`, `swift build -c release` and `swift run pechpech-demo` on macOS. Also run the independent crypto-vector checker, external consumer compile and resource validation described in [packaging](packaging.md). The public CI workflow runs these software checks on both Apple Silicon and Intel macOS runners and compiles the native library for a generic iOS Simulator destination with the iOS 16 deployment target. It needs no operational credentials. Tests and the demo use synthetic identities, temporary stores and injected links; they do not start a physical Bluetooth mesh.

The test suite should establish the specific behaviors covered by its assertions: immutable identity/content matching, encryption and tampering rejection, persist-before-send, duplicate handling, inbox/receipt transactions, relay capacity and recovery, and receipt routing. Consult the current test sources and CI result for the exact release coverage. A test that simulates a failed write establishes that code path, not the durability of every device's storage hardware.

Keychain helper tests cover argument validation and its local private-record codec without touching the real Keychain. Those checks do not qualify signed-host Keychain permissions, device lock/unlock or identity restoration. Test those separately in the actual host app.

Compile checks verify API compatibility for the build configuration used. They do not establish that every advertised minimum OS release or every device model has been exercised physically.

## Physical evidence required

Before depending on a deployment, record at least these scenarios using the exact app, package revision and device models:

| Scenario | Observe |
| --- | --- |
| Two nearby devices, no router or internet | Discovery, permissions, message arrival and authenticated endpoint receipt |
| Devices on different Wi-Fi networks | Which link actually carries traffic, disconnects and recovery |
| Forced two-hop path | Prevent the direct path; verify intermediary storage and forwarding |
| Alternate return path | Remove the outbound chain before receipt return; verify the original message resolves once |
| Lost receipt and duplicate messages | Pending-state truth, retry behavior and no duplicated inbox or application effect |
| Full relay spool and transient transport queue | Visible backpressure, bounded storage and preserved owned messages |
| Process/store restart and storage failure | Recoverable immutable messages, receipt state and no false success |
| Lock, background, force-quit and powered-off intermediary | Route loss and truthful recovery when foreground operation resumes |
| Four neighbors and radio interference | Queue fairness, resource use and responsive host UI |

Use synthetic payloads. Remove private keys, device identifiers and personal information from shared evidence. Report message size, topology, sample count, failed attempts and measurement method with any latency figures.

Measure durable endpoint receipt latency separately from application processing and UI appearance. There is no arbitrary-hop latency, range or coverage guarantee. A long timeout cannot prove that a recipient never stored a message.

## Platform limits

The BLE adapter concurrently scans and advertises through CoreBluetooth while the host is active. Native permissions and powered radios are necessary. The system can suspend or terminate mobile processes; a moving or closed intermediary may break the path.

Apple offers additional background capabilities, including certain Live Activity privileges on iOS 26 and later, but PechPech does not implement or qualify a background deployment model. See [Apple's current CoreBluetooth documentation](https://developer.apple.com/documentation/corebluetooth) and its [background processing guidance](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html).

TCP/Bonjour can use an available local path. Enabling [Network framework peer-to-peer links](https://developer.apple.com/documentation/network/nwparameters/includepeertopeer) permits eligible links; it does not force a particular Wi-Fi route or guarantee connectivity across different networks.

PechPech is an application-level store-and-forward protocol carried over BLE or TCP. It is not Bluetooth SIG Mesh. Discovery does not launch arbitrary apps, enroll a user or prove identity. Future Android and browser support require separate implementations and interoperability evidence.
