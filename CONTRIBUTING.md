# Contributing to PechPech

PechPech is an experimental, application-independent nearby messaging framework. Contributions should make its behavior easier to verify and its limits easier to understand.

## Develop locally

Use Swift 5.9 or later on macOS 13 or later with Xcode installed. The first implementation uses Apple's CryptoKit, CoreBluetooth and Network frameworks, plus the system SQLite library. Android, Linux and browser implementations are future work.

```sh
swift test
swift build -c release
swift run pechpech-demo
```

An independent crypto-vector check uses Node 22 or later and built-in modules only:

```sh
node scripts/check-interop-vector.cjs
```

This verifies the committed synthetic [generic encryption fixture](Tests/PechPechCoreTests/Fixtures/canonical-v2.json) and [opaque control fixture](Tests/PechPechCoreTests/Fixtures/opaque-control-v1.json) with Node/OpenSSL. CI runs it using Node 22. It is not an Android/browser adapter or a physical-radio test, and Node is not a dependency of the distributed Swift package.

Also check the shipped resources and public products outside the test target:

```sh
swift build -c release
python3 scripts/check-package-resources.py
swift build --package-path Examples/PackageConsumer -c release
```

See [packaging](docs/packaging.md) for privacy declarations and [release procedures](docs/releasing.md) for publishing. New APIs and dependencies must keep the manifests, notices and external consumer current.

The demo uses synthetic data and injected links. It does not establish Bluetooth range, background receiving or physical mesh performance. See [qualification](docs/qualification.md).

## Make a focused change

Open an issue for a substantial wire-format, cryptography, routing or persistence change before building it. Explain the concrete behavior you want and how peers using an older version should behave. Small fixes can go directly to a pull request.

The current experimental release is 0.3.0. The generic `MeshNode` protocol retains wire version 2 and the 0.2 storage namespace. Those namespaces are incompatible with 0.1. Read [the migration guide](docs/migration-0.2.md) before adapting an existing host, database or interoperability implementation. Host-managed encrypted protocol profiles are a separate integration boundary; do not treat their link authentication as application authorization.

Keep transport adapters independent of application models. Examples may illustrate a use case; core code must not assume restaurants, orders, chat rooms, purchases or a particular business authority.

Preserve these boundaries:

- Persist an immutable outgoing message before its first transmission.
- A relay acknowledgment means durable next-hop storage only.
- An endpoint receipt means authenticated, durable inbox bytes. The application separately decides whether those bytes authorize an action and whether that action succeeded.
- Retries preserve message identity and content. Duplicate delivery must not create another inbox message.
- Owned outbox, inbox and receipt records are independent of the bounded spool for relaying other devices' packets.
- Missing paths and storage failures must remain observable. A timeout does not establish that the endpoint never received a message.
- Discovery, proximity and a valid signing key do not establish application permission.

Add tests for meaningful failure cases: duplicates, restarts, lost receipts, expiry, tampering, full spools, storage errors and alternate paths. A radio change also needs physical-device evidence; unit tests alone cannot qualify it.

Update the relevant protocol or integration documentation when behavior changes. Mark proposals as proposals. Do not turn an aspiration into a measured performance claim.

## Pull requests

Describe the problem, resulting behavior, compatibility impact and checks performed. Include only synthetic or redacted evidence. Keep credentials, private keys, device identifiers, runtime databases, personal information and generated builds out of commits and issue attachments.

For radio reports, include device models, OS versions, app lifecycle, enabled radios, router/network conditions and the exact topology. Report endpoint receipt latency separately from application processing or UI appearance.

Contributions are accepted under the repository's [MIT license](LICENSE). Submit only code and assets you are entitled to contribute, retain required third-party notices and record new dependencies in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Follow the [code of conduct](CODE_OF_CONDUCT.md), treat other contributors respectfully and explain disagreements with evidence.

Security-sensitive findings belong in [private vulnerability reports](SECURITY.md), not public issues.
