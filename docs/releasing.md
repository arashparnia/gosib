# Publishing a PechPech release

PechPech is distributed as source through SwiftPM. `PechPechCore` and `PechPechApple` are library products; `pechpech-demo` is a development example. There is no separately distributed signed XCFramework, CocoaPods pod, Android adapter or browser package in this release.

The maintainer performs these steps for the exact commit intended for publication:

1. Review public API, wire and storage changes. A patch must preserve the current minor series' protocol/storage namespaces. Document tightened validation and host behavior changes in the changelog. Breaking changes require an appropriate version and reviewed migration.
2. Run the full unit suite, release build, independent crypto-vector checker, external consumer-product check, and resource/privacy validation. Compile for the generic iOS Simulator target. Inspect CI for both Apple Silicon and Intel macOS; local checks alone do not replace that record.
3. Confirm that the source tree, resources and Git archive contain the MIT license and community/security documentation, and contain no credentials, runtime databases, operational messages, private keys or generated build products. Synthetic fixture seeds must be clearly identified as test material.
4. Update release notes and verification evidence with the actual checks and remaining limits. Do not turn compile/injected-link results into physical radio, performance, background or App Store qualification claims.
5. Create an annotated version tag at the reviewed, passing commit, push it and publish matching GitHub release notes. Preserve older tags and snapshots. Mark experimental releases as prereleases in GitHub.
6. Resolve the public URL and exact new tag from a clean external SwiftPM consumer, build it, and inspect the library resource bundles. Confirm the tag resolves to the commit qualified by CI.

Host applications must also verify that Xcode copies the package resource bundles into their app archive and combines the SDK privacy declarations correctly. Apps own their permission strings, entitlements, data disclosures, at-rest protection, business authorization and store submission. Release publication does not assert that a host is ready for App Review.

Community files follow [GitHub's community-profile guidance](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/about-community-profiles-for-public-repositories). CI uses the [least-privilege and action-pinning guidance](https://docs.github.com/en/actions/reference/security/secure-use). These are concrete practices, not certification that every possible open-source guideline has been satisfied.
