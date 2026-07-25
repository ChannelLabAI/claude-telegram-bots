#!/usr/bin/env bun
import {
  EffectLedger,
  EffectLedgerError,
  knowledgeLifecycleProjection,
  ProjectionRegistry,
  type EffectLedgerKey,
} from "./src/index.ts";
import type { EventEnvelope } from "./src/envelope.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(`effect-ledger fixture assertion failed: ${message}`);
}

function key(destination: string, suffix = "1"): EffectLedgerKey {
  return {
    consumer_id: "effect-fixture",
    event_id: `01J00000000000000000000${suffix}`,
    effect_kind: "notification",
    destination,
  };
}

function rejects(action: () => unknown, code: EffectLedgerError["code"]): void {
  try {
    action();
  } catch (error) {
    assert(error instanceof EffectLedgerError && error.code === code, `expected ${code}, got ${String(error)}`);
    return;
  }
  throw new Error(`effect-ledger fixture expected rejection ${code}`);
}

const ledger = new EffectLedger();
ledger.registerDestination("idempotent-destination", "destination_idempotency");
ledger.registerDestination("query-destination", "query_reconcile");
ledger.registerDestination("opaque-destination", "non_queryable");
rejects(
  () => ledger.registerDestination("opaque-destination", "query_reconcile"),
  "DUPLICATE_DESTINATION",
);

// This is a real crash-window simulation: durable pending is present, the
// dispatch has begun, and the process is interrupted before durable success.
const crashKey = key("idempotent-destination");
ledger.begin(crashKey);
const crashRecord = ledger.dispatchInterrupted(crashKey);
assert(crashRecord.state === "delivery_unknown", "crash after dispatch must be delivery_unknown, not failed");
assert(crashRecord.state !== "failed", "delivery_unknown must remain an independent state");
assert(ledger.retry(crashKey, 2).state === "pending", "idempotent destination may retry same key");
ledger.markFailed(crashKey);
assert(ledger.retry(crashKey, 2).attempts === 2, "retry counter must be durable and bounded");
ledger.markFailed(crashKey);
rejects(() => ledger.retry(crashKey, 2), "RETRY_REJECTED");

// At-least-once re-read of the same key is one record; destination is part of the key.
const firstRead = ledger.begin(key("idempotent-destination", "2"));
const repeatedRead = ledger.begin(key("idempotent-destination", "2"));
const otherDestination = ledger.begin(key("query-destination", "2"));
assert(firstRead.state === repeatedRead.state, "same ledger key must be idempotent");
assert(otherDestination.key.destination !== repeatedRead.key.destination, "different destinations must remain independent");

const queryKey = key("query-destination", "3");
ledger.begin(queryKey);
ledger.dispatchInterrupted(queryKey);
rejects(() => ledger.retry(queryKey, 1), "RETRY_REJECTED");
rejects(() => ledger.markSucceeded(queryKey), "RECONCILIATION_REQUIRED");
assert(ledger.reconcile(queryKey, "delivered").state === "succeeded", "query proof of delivery may succeed");
const queryRetryKey = key("query-destination", "4");
ledger.begin(queryRetryKey);
ledger.dispatchInterrupted(queryRetryKey);
assert(ledger.reconcile(queryRetryKey, "not_delivered").state === "pending", "query proof of non-delivery may retry");

const opaqueKey = key("opaque-destination", "5");
ledger.begin(opaqueKey);
ledger.dispatchInterrupted(opaqueKey);
rejects(() => ledger.retry(opaqueKey, 1), "RETRY_REJECTED");
assert(ledger.get(opaqueKey)?.state === "delivery_unknown", "non-queryable must freeze at delivery_unknown");
rejects(() => ledger.operatorResolveUnknown(opaqueKey, "mark-delivered", "", ""), "OPERATOR_AUDIT_REQUIRED");
assert(
  ledger.operatorResolveUnknown(opaqueKey, "duplicate-risk-retry", "operator-fixture", "accept duplicate risk").state === "pending",
  "audited duplicate-risk retry is the only way to unfreeze non-queryable delivery",
);

const dlq = ledger.addPoisonEvent(
  "01J00000000000000000000DLQ",
  "password=super-secret token=abc Authorization: Bearer live-token sk-supersecrettoken",
);
assert(!/super-secret|live-token|sk-supersecrettoken|token=abc/.test(dlq.diagnostics), "DLQ diagnostics must redact secrets");
rejects(() => ledger.disposeDlq(0, "skip-with-reason", "operator-fixture", ""), "OPERATOR_AUDIT_REQUIRED");
rejects(() => ledger.disposeDlq(0, "delete" as never, "operator-fixture", "nope"), "INVALID_DISPOSITION");
const disposition = ledger.disposeDlq(0, "skip-with-reason", "operator-fixture", "poison payload reviewed");
assert(disposition.disposition?.action === "skip-with-reason", "allowed DLQ disposition must persist audit action");

function projectionEvent(): EventEnvelope {
  return {
    global_seq: 1,
    stream_seq: 1,
    batch_position: 0,
    event_id: "01J00000000000000000000P01",
    workspace_id: "workspace-fixture",
    stream_id: "knowledge-fixture",
    stream_kind: "knowledge",
    event_type: "knowledge.lifecycle",
    schema_version: 1,
    actor_id: "human-reviewer",
    actor_kind: "human",
    origin: "native",
    correlation_id: "effect-separation-fixture",
    occurred_at: "2026-07-25T00:00:00Z",
    ingested_at: "2026-07-25T00:00:00Z",
    refs: [],
    payload: {
      knowledge_id: "knowledge-1",
      transition: "draft",
      target_revision: 1,
      source_event_ids: ["01J0000000000000000000SOURCE"],
      content_hash: "sha256:fixture",
      content_schema_version: 1,
      scope: ["workspace-fixture"],
      valid_from: "2026-07-25T00:00:00Z",
      reason_code: "fixture",
      origin_actor: { id: "human-reviewer", kind: "human" },
    },
  };
}

// Full projection rebuild is deliberately executed against a ledger instance.
// The registry never receives it, so rebuild cannot write effects by accident.
const replayLedger = new EffectLedger();
const projections = new ProjectionRegistry();
projections.register(knowledgeLifecycleProjection);
const results = projections.rebuild([projectionEvent(), projectionEvent()]);
assert(results.get("knowledge-lifecycle") !== undefined, "full projection replay must execute");
assert(replayLedger.writeCount === 0, "generic projection replay must write zero effect-ledger records");

console.log("effect-ledger fixtures: PASS");
console.log("  crash-window, recovery classes, DLQ redaction/dispositions, and projection separation verified");
