# Project governance and releases

Arash Parnia is the initial maintainer and release publisher. Contributors are welcome through issues, discussions and pull requests. The maintainer reviews changes and compatibility decisions; public discussion should explain their reasoning. The project currently has no separate steering committee, paid support commitment or independent security certification.

## Decisions and contributions

Routine fixes can arrive as focused pull requests. Changes to cryptography, wire bytes, durable storage, identity semantics or public APIs need an issue explaining the proposal, migration and failure cases before implementation. Follow [CONTRIBUTING.md](CONTRIBUTING.md) and the [code of conduct](CODE_OF_CONDUCT.md).

Contributions use the existing MIT license. There is no additional contributor license agreement. Contributors must have the right to contribute their code, documentation and assets; third-party material requires compatible licensing and retained notices.

## Version policy

SwiftPM consumes versioned Git tags. Before 1.0, a minor release may intentionally break public API, storage or protocol compatibility and must document the migration. Patch releases in a minor series preserve its wire and storage namespace; they may tighten rejection of invalid or unauthorized input and fix documented behavior. Application payload/channel versions are independent.

Release notes identify compatibility effects and link the checks for the exact release commit. Tags and published historical snapshots are preserved. A GitHub prerelease marks experimental deployment status; a numeric SwiftPM tag alone is not a production qualification claim.

The latest published release and current `main` receive fixes. Earlier snapshots are not maintained as separate branches. Never silently discard unresolved stores or rotate identities to make an upgrade appear successful.

See the [release checklist](docs/releasing.md) and [changelog](CHANGELOG.md).
