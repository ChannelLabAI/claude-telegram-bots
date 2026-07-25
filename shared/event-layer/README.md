# `@channel-lab/event-contract`

Pure W1-B1 event contract package for shared producer/consumer imports.

It implements ADR-003 §§1–3 only:

- strict, versioned event envelopes;
- payload schema registration and supported version ranges;
- current-version-only producer validation;
- deterministic read-time upcaster chains;
- consumer fail-closed checks and deprecation/replay gates;
- golden positive and negative compatibility fixtures.

W1-B2 adds a dedicated single-writer process and local append API:

- SQLite-generated `global_seq` and transaction-locked per-stream `stream_seq`;
- collision-safe command deduplication on
  `(workspace_id, actor_id, client_id, idempotency_key)`;
- canonical request hashes and replay of the original committed event;
- WAL, `synchronous=FULL`, foreign keys and bounded lock waits;
- a synchronous in-transaction authorization hook reserved for W1-B3.

The strict envelope still rejects command-only fields. They live only on
`AppendCommand` and in the writer's dedup table.

Run:

```sh
bun run shared/event-layer/contract-lint.ts
```

Start a writer and use the exported client:

```sh
bun run shared/event-layer/src/writer-process.ts \
  --db /persistent/event-store.db \
  --endpoint /run/channel-lab/event-writer
```

The endpoint is an atomic local request/response spool. It is command IPC only,
not an event copy or legacy write authority. The process publishes a successful
append response only after SQLite commit.

W1-B7 adds the operational boundary around that writer:

- startup validation of durability settings, schema, free-space reserve, clean
  checkpoint, and the weekly machine roster;
- read-only degraded mode with fail-closed writes and authorized reads only from
  a checksummed verified projection carrying its staleness timestamp;
- event-layer SLO samples and threshold evaluation;
- AES-256-GCM encrypted, checksummed SQLite verified snapshots with manifests;
- disposable restore, integrity verification, and deterministic projection
  replay;
- hourly/daily/monthly retention pruning plus owned alerts and runbooks.

Run the failure and restore drills with:

```sh
bun run shared/event-layer/operations-fixtures.ts
```

Set `EVENT_LAYER_EVIDENCE_DIR` to retain the encrypted manifest and disposable
restore evidence outside the temporary fixture directory.
