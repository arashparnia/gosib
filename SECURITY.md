# Security policy

PechPech 0.2 is experimental. It has no independent cryptographic audit or production security certification. Security fixes target the latest published 0.2 release and the current `main` branch; older snapshots are not maintained separately. The prior 0.1 release is incompatible with the current wire and storage namespaces; see [migration](docs/migration-0.2.md).

## Report a vulnerability privately

Use this repository's **Security → Report a vulnerability** button. See [GitHub's private reporting instructions](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/report-privately). Include affected versions, a minimal reproduction using synthetic data, expected behavior and the security impact. Do not submit real private keys, customer data or unredacted device logs.

If private reporting is unavailable, open an issue asking for a private reporting channel without including exploit details or sensitive material. Maintainers will coordinate the next step. No response-time or bounty commitment is implied.

## Security boundaries

PechPech authenticates cryptographic senders and encrypts endpoint payloads. Applications must establish trust in the intended recipient identity and decide which authenticated senders are authorized. Discovery, radio distance and relay participation do not grant access to application actions.

An endpoint receipt confirms that the recipient stored the payload bytes durably. It does not confirm a transaction, human approval or other business result. Applications need their own authorization, idempotency and durable business-result protocol.

Relays see routing identifiers, priorities, expiry, lengths and timing. They can drop, delay, replay or withhold packets. Resource limits constrain storage under honest operation; they do not prevent Sybil traffic, denial of service or hostile hop-budget resets. PechPech does not provide anonymity, physical-location proof or a distance-based security boundary.

Encryption with an ephemeral sender agreement key and the recipient's persistent agreement key does not provide forward secrecy against a later compromise of that recipient key. The host application owns secure identity storage and rotation. Protect runtime databases using the platform's appropriate file protection and access controls; SQLite records are not encrypted at rest by this package.

See [protocol and threat model](docs/protocol.md) and [qualification limits](docs/qualification.md) before deployment.
