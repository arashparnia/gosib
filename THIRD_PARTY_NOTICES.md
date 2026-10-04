# Dependencies and notices

PechPech's own code and documentation use the [MIT license](LICENSE). Keep its copyright and license notice when distributing copies or substantial portions. The library resource bundles include the complete PechPech license for hosts that distribute the SwiftPM products.

The package currently has **no third-party SwiftPM dependencies and no vendored third-party source or binary libraries**. Its Apple implementation links the platform-provided CryptoKit, Foundation, CoreBluetooth, Network and Security frameworks and the system SQLite library. These platform components are supplied by the operating system; PechPech does not redistribute their implementations. SQLite's upstream licensing is described at [sqlite.org](https://www.sqlite.org/copyright.html).

The synthetic cryptographic fixture is generated from documented test seeds. Its optional Node/OpenSSL checker uses the installed Node runtime and built-in modules, rather than bundling either runtime into PechPech or an app.

GitHub Actions dependencies are CI tooling, separate from the distributed SDK. The workflow pins actions to immutable commit identifiers and Dependabot proposes updates for review. If a new dependency, copied asset or binary is introduced, record its source, exact version, license and redistribution notices here before releasing it.
