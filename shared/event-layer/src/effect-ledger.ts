/**
 * Pure W1 effect-ledger contract.  This module deliberately has no event
 * consumer, transport, or projection dependency: it models only durable
 * decisions that a later external-effect runner must honour.
 */
export type EffectLedgerState =
  | "pending"
  | "succeeded"
  | "failed"
  | "delivery_unknown"
  | "dead";

export type RecoveryClass =
  | "destination_idempotency"
  | "query_reconcile"
  | "non_queryable";

export type EffectLedgerKey = Readonly<{
  consumer_id: string;
  event_id: string;
  effect_kind: string;
  destination: string;
}>;

export type EffectLedgerRecord = Readonly<{
  key: EffectLedgerKey;
  state: EffectLedgerState;
  attempts: number;
}>;

export type DlqDisposition = "retry" | "skip-with-reason" | "compensate";

export type DlqEntry = Readonly<{
  event_id: string;
  diagnostics: string;
  disposition?: Readonly<{
    operator_id: string;
    action: DlqDisposition;
    reason: string;
  }>;
}>;

export class EffectLedgerError extends Error {
  constructor(
    readonly code:
      | "UNKNOWN_DESTINATION"
      | "DUPLICATE_DESTINATION"
      | "INVALID_TRANSITION"
      | "RETRY_REJECTED"
      | "RECONCILIATION_REQUIRED"
      | "OPERATOR_AUDIT_REQUIRED"
      | "INVALID_DISPOSITION",
    message: string,
  ) {
    super(message);
    this.name = "EffectLedgerError";
  }
}

function keyId(key: EffectLedgerKey): string {
  // A structured encoding avoids delimiter collisions between key fields.
  return JSON.stringify([key.consumer_id, key.event_id, key.effect_kind, key.destination]);
}

function copy(record: EffectLedgerRecord): EffectLedgerRecord {
  return { key: { ...record.key }, state: record.state, attempts: record.attempts };
}

function requireReason(operatorId: string, reason: string): void {
  if (operatorId.trim().length === 0 || reason.trim().length === 0) {
    throw new EffectLedgerError(
      "OPERATOR_AUDIT_REQUIRED",
      "operator_id and non-empty audit reason are required",
    );
  }
}

/** Redacts common credential-shaped values before any diagnostic is retained. */
export function redactDiagnostics(diagnostics: string): string {
  return diagnostics
    .replace(/(authorization\s*[:=]\s*bearer\s+)[^\s,;]+/gi, "$1[REDACTED]")
    .replace(/\b(sk-[A-Za-z0-9_-]{8,})\b/g, "[REDACTED]")
    .replace(/\b(password|secret|token|api[_-]?key)\s*[:=]\s*[^\s,;]+/gi, "$1=[REDACTED]");
}

/**
 * In-memory contract model used by fixtures. Persistence is intentionally a
 * later concern; callers can map these immutable records to their durable store.
 */
export class EffectLedger {
  readonly #destinations = new Map<string, RecoveryClass>();
  readonly #records = new Map<string, EffectLedgerRecord>();
  readonly #dlq: DlqEntry[] = [];

  registerDestination(destination: string, recovery: RecoveryClass): void {
    if (destination.trim().length === 0) throw new Error("destination is required");
    if (this.#destinations.has(destination)) {
      throw new EffectLedgerError(
        "DUPLICATE_DESTINATION",
        `destination ${destination} is already registered`,
      );
    }
    this.#destinations.set(destination, recovery);
  }

  recoveryFor(destination: string): RecoveryClass {
    const recovery = this.#destinations.get(destination);
    if (!recovery) {
      throw new EffectLedgerError("UNKNOWN_DESTINATION", `destination ${destination} is unregistered`);
    }
    return recovery;
  }

  begin(key: EffectLedgerKey): EffectLedgerRecord {
    this.recoveryFor(key.destination);
    const id = keyId(key);
    const existing = this.#records.get(id);
    if (existing) return copy(existing);
    const record: EffectLedgerRecord = { key: { ...key }, state: "pending", attempts: 0 };
    this.#records.set(id, record);
    return copy(record);
  }

  get(key: EffectLedgerKey): EffectLedgerRecord | undefined {
    const record = this.#records.get(keyId(key));
    return record ? copy(record) : undefined;
  }

  get writeCount(): number {
    return this.#records.size;
  }

  /** Records the required crash/timeout window after dispatch but before success is durable. */
  dispatchInterrupted(key: EffectLedgerKey): EffectLedgerRecord {
    return this.#transition(key, ["pending"], "delivery_unknown");
  }

  markSucceeded(key: EffectLedgerKey): EffectLedgerRecord {
    const record = this.#mustGet(key);
    if (
      record.state === "delivery_unknown" &&
      this.recoveryFor(key.destination) === "query_reconcile"
    ) {
      throw new EffectLedgerError(
        "RECONCILIATION_REQUIRED",
        "query-reconcile destinations require proof before success",
      );
    }
    return this.#transition(key, ["pending", "delivery_unknown"], "succeeded");
  }

  markFailed(key: EffectLedgerKey): EffectLedgerRecord {
    return this.#transition(key, ["pending"], "failed");
  }

  markDead(key: EffectLedgerKey): EffectLedgerRecord {
    return this.#transition(key, ["failed"], "dead");
  }

  retry(key: EffectLedgerKey, maxAttempts: number): EffectLedgerRecord {
    const record = this.#mustGet(key);
    if (!Number.isInteger(maxAttempts) || maxAttempts < 1 || record.attempts >= maxAttempts) {
      throw new EffectLedgerError("RETRY_REJECTED", "bounded retry limit reached");
    }
    if (this.recoveryFor(key.destination) !== "destination_idempotency") {
      throw new EffectLedgerError("RETRY_REJECTED", "automatic retry requires destination idempotency");
    }
    if (record.state !== "failed" && record.state !== "delivery_unknown") {
      throw new EffectLedgerError("INVALID_TRANSITION", `cannot retry from ${record.state}`);
    }
    return this.#replace({ ...record, state: "pending", attempts: record.attempts + 1 });
  }

  reconcile(key: EffectLedgerKey, outcome: "delivered" | "not_delivered"): EffectLedgerRecord {
    const record = this.#mustGet(key);
    if (this.recoveryFor(key.destination) !== "query_reconcile") {
      throw new EffectLedgerError("RECONCILIATION_REQUIRED", "destination does not use query reconciliation");
    }
    if (record.state !== "delivery_unknown") {
      throw new EffectLedgerError("INVALID_TRANSITION", `cannot reconcile from ${record.state}`);
    }
    return this.#replace({ ...record, state: outcome === "delivered" ? "succeeded" : "pending" });
  }

  operatorResolveUnknown(
    key: EffectLedgerKey,
    action: "mark-delivered" | "compensate" | "duplicate-risk-retry",
    operatorId: string,
    reason: string,
  ): EffectLedgerRecord {
    requireReason(operatorId, reason);
    const record = this.#mustGet(key);
    if (this.recoveryFor(key.destination) !== "non_queryable" || record.state !== "delivery_unknown") {
      throw new EffectLedgerError("OPERATOR_AUDIT_REQUIRED", "only unknown non-queryable effects need operator resolution");
    }
    const state: EffectLedgerState = action === "mark-delivered" ? "succeeded" : action === "compensate" ? "dead" : "pending";
    return this.#replace({ ...record, state, attempts: action === "duplicate-risk-retry" ? record.attempts + 1 : record.attempts });
  }

  addPoisonEvent(eventId: string, diagnostics: string): DlqEntry {
    const entry: DlqEntry = { event_id: eventId, diagnostics: redactDiagnostics(diagnostics) };
    this.#dlq.push(entry);
    return entry;
  }

  disposeDlq(index: number, action: DlqDisposition, operatorId: string, reason: string): DlqEntry {
    if (!(["retry", "skip-with-reason", "compensate"] as string[]).includes(action)) {
      throw new EffectLedgerError("INVALID_DISPOSITION", `unsupported DLQ disposition ${action}`);
    }
    requireReason(operatorId, reason);
    const existing = this.#dlq[index];
    if (!existing) throw new Error(`DLQ entry ${index} does not exist`);
    const entry: DlqEntry = { ...existing, disposition: { operator_id: operatorId, action, reason } };
    this.#dlq[index] = entry;
    return entry;
  }

  #mustGet(key: EffectLedgerKey): EffectLedgerRecord {
    const record = this.#records.get(keyId(key));
    if (!record) throw new Error("effect ledger record does not exist");
    return record;
  }

  #transition(key: EffectLedgerKey, from: readonly EffectLedgerState[], to: EffectLedgerState): EffectLedgerRecord {
    const record = this.#mustGet(key);
    if (!from.includes(record.state)) {
      throw new EffectLedgerError("INVALID_TRANSITION", `${record.state} cannot transition to ${to}`);
    }
    return this.#replace({ ...record, state: to });
  }

  #replace(record: EffectLedgerRecord): EffectLedgerRecord {
    this.#records.set(keyId(record.key), record);
    return copy(record);
  }
}
