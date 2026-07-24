# `@channel-lab/event-contract`

Pure W1-B1 event contract package for shared producer/consumer imports.

It implements ADR-003 §§1–3 only:

- strict, versioned event envelopes;
- payload schema registration and supported version ranges;
- current-version-only producer validation;
- deterministic read-time upcaster chains;
- consumer fail-closed checks and deprecation/replay gates;
- golden positive and negative compatibility fixtures.

Command deduplication (`client_id`, `idempotency_key`, request hashes and stored
results) belongs to W1-B2 / ADR-003 §4 and is intentionally absent. The strict
envelope rejects those command-only fields.

Run:

```sh
bun run shared/event-layer/contract-lint.ts
```
