# SwiftPM distribution and privacy resources

PechPech ships source-based SwiftPM products for iOS 16+ and macOS 13+ using Swift 6.1 or later. `PechPechCore` contains the protocol, cryptography and SQLite persistence; `PechPechApple` adds native links and secure identity storage. There are no external SwiftPM dependencies. The optional demo and Node interoperability checker are development tools.

## Installation and verification

Add the public repository URL and a reviewed version range in Xcode or your package manifest, then select the library products your host needs. For stable 1.x releases, use `.upToNextMajor(from: "1.0.0")`. Commit the host's `Package.resolved` when reproducible app builds are required.

The checked-in [independent consumer](../Examples/PackageConsumer/Package.swift) depends on the package as a separate client and compiles native construction, callback and delivery APIs. It starts no radios and uses no real Keychain or runtime database. Verify products and resources locally with:

```sh
swift build -c release
python3 scripts/check-package-resources.py
swift build --package-path Examples/PackageConsumer -c release
```

The resource checker parses the source and built property lists and verifies that both library bundles contain the exact complete MIT notice. CI repeats this for SwiftPM macOS products and generic iOS Simulator products. Before publishing, also build a clean consumer of the public URL and exact new Git tag; local path resolution does not prove the remote release exists.

Annotated version-tag pushes run the full CI matrix and `python3 scripts/check-release-consumer.py vMAJOR.MINOR.PATCH`. The latter builds a temporary consumer against the public repository with an exact version, checks the resolved revision against the reviewed checkout and peeled remote tag, and validates both compiled library resource bundles. Publish the matching GitHub release only after that tagged run passes; stable releases are not marked as prereleases.

## SDK privacy declarations

Each library explicitly packages `PrivacyInfo.xcprivacy` and `PechPech-LICENSE.txt` as target resources. SwiftPM/Xcode creates a resource bundle for each library; consumers must retain those bundles when distributing an app. A source package does not need a separate binary framework signature. PechPech does not distribute an XCFramework.

The SDK has no analytics service, tracking domains, advertising integration or developer-operated payload collector. Its manifests declare no SDK tracking or collected-data categories. Message bytes are supplied by the host and exchanged with host-selected endpoints and opaque relays; the application owns consent, endpoint use and its accurate App Store data disclosures. The empty SDK declaration does not assert that every host app collects no data.

The reviewed implementation does not directly use Apple's required-reason API categories such as file timestamps, disk space, system boot time or UserDefaults. It uses ordinary wall-clock dates, Swift's `ContinuousClock` for elapsed-time scheduling and the operating system's SQLite implementation. The manifests therefore have an empty accessed-API array rather than invented reasons. Re-review actual source and linked third-party implementations whenever dependencies or API use change.

Apple describes [privacy manifests and SwiftPM resource placement](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk), [required-reason API declarations](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api) and [third-party SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/). These declarations do not bypass host permission prompts or guarantee App Review acceptance.

## Licenses and releases

The source archive and library resources retain the [MIT license](../LICENSE). See [third-party notices](../THIRD_PARTY_NOTICES.md) for the linked platform components and tooling. Follow the [release checklist](releasing.md), preserve historical tags and attach exact-commit evidence to published versions.

There is no certification that the package satisfies every possible open-source policy. The repository supplies a recognized license, contribution and conduct policies, private security reporting, documented compatibility boundaries and reproducible package checks so adopters can assess their own requirements.
