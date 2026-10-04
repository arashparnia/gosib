# PechPech 0.3 verification — 4 October 2026

This record separates current SDK/packaging checks from [the prior 0.2 record](verification-2026-10-04.md). The generic `MeshNode` retains wire version 2 and its existing storage namespace. Identities and test records are synthetic; package-consumer checks do not start radios or access the real Keychain.

Local checks used an Apple Silicon Mac, Xcode 27.0 and Apple Swift 6.4 in Swift 5 language mode. Declared Swift 5.9 / iOS 16 / macOS 13 minima are source/deployment targets, not physical minimum-OS qualification.

## SDK checks

| Check | Result |
| --- | --- |
| Full `swift test` suite | PASS — 59 tests, 51 Core and eight Apple, zero failures |
| Opaque routing suite | PASS — 14 cases covering profile/challenge authentication, durable foreign acknowledgment, host failures, backpressure, routing/retries, lifecycle and the independent control fixture |
| Schema/retry hardening | PASS — incompatible namespaces/objects/table definitions rejected with original schema, records and journal preserved; stable-ID retry uses saved timestamp and delivered state |
| Release build | PASS — `swift build -c release` |
| Independent vectors | PASS — Node/OpenSSL regenerates/verifies generic-v2 encryption and opaque-control-v1 claims, frame bytes and signatures; Swift/CryptoKit validates the published controls |
| Native iOS compile | PASS — generic iOS Simulator compile with iOS 16 deployment target and signing disabled |
| Injected-link demo | PASS — two-hop encrypted delivery, durable endpoint receipt and duplicate suppression |

## Packaging checks

| Check | Evidence |
| --- | --- |
| SwiftPM manifest | `swift package dump-package` succeeds and explicitly declares both library resource directories |
| Library privacy property lists | `plutil -lint` succeeds for both source manifests |
| Source and compiled resources | `python3 scripts/check-package-resources.py` verifies exact privacy declarations and complete MIT notices in both release library bundles |
| Independent consumer | `swift build --package-path Examples/PackageConsumer -c release` succeeds; public Core/Apple imports, generic node APIs and all opaque-router asynchronous hooks compile outside the test module |
| Compiled iOS resources | PASS — the generic iOS Simulator products contain both privacy manifests and exact complete MIT notices |
| Source redistribution | Repository MIT license, bundled notices, contribution/conduct/security/support policies and dependency notices are present |

The [public CI workflow](../.github/workflows/ci.yml) repeats the vectors, full test suite, release build, external consumer, iOS Simulator compile/resource checks and injected-link demo on Apple Silicon and Intel macOS. The [Actions results](https://github.com/arashparnia/pechpech/actions/workflows/ci.yml) and release notes identify the published commit's run; the local results above are separate from that exact-commit CI evidence.

## Scope

The generic endpoint protocol and an application-owned opaque protocol profile are distinct. Their authorization, durable storage and receipt semantics must be assessed in the intended host. Package resources and unit tests do not establish a GARVI migration, physical radio connectivity, background operation, UI responsiveness, latency, independent security audit or App Store qualification.

Physical deployment still requires the matrix in [qualification](qualification.md). See [packaging](packaging.md) for the reviewed SDK privacy scope and the app's separate obligations.

## Repository security and community

The public GitHub repository recognizes the MIT license, enables issues/discussions and private vulnerability reporting, and has secret scanning with push protection enabled. On 4 October, repository vulnerability alerts and automated security-fix pull requests were enabled. Actions use read-only repository contents access, disabled checkout credential persistence, full commit pins and reviewed Dependabot updates. The repository publishes explicit contribution, conduct, support, governance and release procedures.

These practices follow [GitHub's community-profile guidance](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/about-community-profiles-for-public-repositories) and [secure Actions guidance](https://docs.github.com/en/actions/reference/security/secure-use). They are observable configuration and documentation, not independent certification or a promise of universal open-source compliance.
