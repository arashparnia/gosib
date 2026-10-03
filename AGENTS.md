# Working on Gosib

Gosib is an experimental application-independent, foreground nearby messaging SDK.

- Read README.md and docs/protocol.md before changing public APIs or wire bytes.
- Keep application permissions, business acceptance and authority selection outside transport adapters.
- Persist original messages before sending. Only a verified endpoint receipt after durable inbox persistence resolves an outbox message; link queueing and relay storage acknowledgments do not.
- Keep original outbox/inbox/receipt records independent of bounded foreign relay storage.
- Keep immutable IDs and contents stable across retries/restarts. Reject changed contents for an existing ID.
- Preserve explicit caller intent: stop pauses new sends; restored pending messages require explicit resumption.
- Use an independent versioned Gosib namespace. Do not silently change deployed GARVI wire identifiers or databases.
- Describe physical radio, background, latency and platform qualification only with actual evidence.
- Never commit runtime messages, databases, private keys, signing material or generated builds.
- Add meaningful regressions for security, durability and protocol changes and update the wire spec/vectors.
