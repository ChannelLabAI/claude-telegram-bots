import { Database } from "bun:sqlite";
import { writeFileSync } from "node:fs";
import { EventWriterClient } from "./append-client.ts";
import { AppendError } from "./append-types.ts";

const MAX_HEALTH_LEASE_MS = 5_000;
const REVOCATION_SLA_MS = 30_000;

export type RevocationIntent = Readonly<{
  principal_id: string;
  revocation_id: string;
  target_auth_epoch: number;
  status: "pending" | "acknowledged";
  created_at: string;
}>;

export type RevocationOutcome = Readonly<{
  status: "success" | "pending" | "unavailable";
  revocation_id: string;
}>;

export type IdentityRevocationState = Readonly<{
  principal_id: string;
  auth_epoch: number;
  disabled: number;
  pending_revocation_watermark: number;
  intent_status: "pending" | "acknowledged";
}>;

type RevocationGuardState =
  | Readonly<{ kind: "no_revocation_state"; disabled: number; pending_watermark: number }>
  | Readonly<{
      kind: "revocation_state_present";
      disabled: number;
      pending_watermark: number;
      has_pending_intent: boolean;
      lease_watermark: number | null;
      lease_expires_at_ms: number | null;
      lease_healthy: number | null;
    }>
  | Readonly<{ kind: "revocation_state_unreadable" }>;

function crashAt(point: string): void {
  if (process.env.REVOCATION_TEST_CRASH_POINT !== point) return;
  const signalPath = process.env.EVENT_WRITER_TEST_CRASH_SIGNAL;
  if (signalPath) writeFileSync(signalPath, `${point}\n`);
  process.kill(process.pid, "SIGKILL");
}

export class IdentityRevocationStore {
  readonly #db: Database;

  constructor(path: string) {
    this.#db = new Database(path, { create: true });
    this.#db.exec(`
      PRAGMA journal_mode=WAL;
      PRAGMA synchronous=FULL;
      CREATE TABLE IF NOT EXISTS identity_principals(
        principal_id TEXT PRIMARY KEY,
        auth_epoch INTEGER NOT NULL DEFAULT 0,
        disabled INTEGER NOT NULL DEFAULT 0 CHECK(disabled IN (0, 1)),
        pending_revocation_watermark INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS revocation_intents(
        revocation_id TEXT PRIMARY KEY,
        principal_id TEXT NOT NULL,
        target_auth_epoch INTEGER NOT NULL,
        status TEXT NOT NULL CHECK(status IN ('pending','acknowledged')),
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS revocation_health_leases(
        principal_id TEXT PRIMARY KEY,
        watermark INTEGER NOT NULL,
        expires_at_ms INTEGER NOT NULL,
        healthy INTEGER NOT NULL CHECK(healthy IN (0, 1)),
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS revocation_operator_events(
        revocation_id TEXT PRIMARY KEY,
        event_type TEXT NOT NULL,
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS identity_reenable_authorizations(
        reenabling_id TEXT PRIMARY KEY,
        principal_id TEXT NOT NULL,
        auth_epoch INTEGER NOT NULL,
        created_at TEXT NOT NULL
      );
    `);
    // Preserve compatibility with an identity fixture created by the first B4
    // revision while still making account finalization durable.
    const columns = this.#db.query("PRAGMA table_info(identity_principals)").all() as Array<{ name: string }>;
    if (!columns.some((column) => column.name === "auth_epoch")) {
      this.#db.exec("ALTER TABLE identity_principals ADD COLUMN auth_epoch INTEGER NOT NULL DEFAULT 0");
    }
    if (!columns.some((column) => column.name === "disabled")) {
      this.#db.exec("ALTER TABLE identity_principals ADD COLUMN disabled INTEGER NOT NULL DEFAULT 0");
    }
  }

  createIntent(principalId: string, revocationId: string, epoch: number): RevocationIntent {
    if (!principalId || !revocationId || !Number.isSafeInteger(epoch) || epoch < 0) {
      throw new AppendError("INVALID_COMMAND", "invalid revocation intent");
    }
    crashAt("identity-before-pending");
    const transaction = this.#db.transaction(() => {
      this.#db.query(`
        INSERT INTO identity_principals(principal_id)
        VALUES (?) ON CONFLICT(principal_id) DO NOTHING
      `).run(principalId);
      const prior = this.#db.query(`
        SELECT principal_id, revocation_id, target_auth_epoch, status, created_at
        FROM revocation_intents WHERE revocation_id = ?
      `).get(revocationId) as RevocationIntent | null;
      if (prior && (prior.principal_id !== principalId || prior.target_auth_epoch !== epoch)) {
        throw new AppendError("IDEMPOTENCY_CONFLICT", "revocation_id reused with different intent");
      }
      this.#db.query(`
        UPDATE identity_principals
        SET pending_revocation_watermark = MAX(pending_revocation_watermark, ?)
        WHERE principal_id = ?
      `).run(epoch, principalId);
      this.#db.query(`
        INSERT INTO revocation_intents(
          revocation_id, principal_id, target_auth_epoch, status, created_at
        ) VALUES (?, ?, ?, 'pending', ?)
        ON CONFLICT(revocation_id) DO NOTHING
      `).run(revocationId, principalId, epoch, new Date().toISOString());
      return this.#db.query(`
        SELECT principal_id, revocation_id, target_auth_epoch, status, created_at
        FROM revocation_intents WHERE revocation_id = ?
      `).get(revocationId) as RevocationIntent;
    });
    const intent = transaction.immediate();
    crashAt("identity-after-pending");
    return intent;
  }

  pending(): RevocationIntent[] {
    return this.#db.query(`
      SELECT principal_id, revocation_id, target_auth_epoch, status, created_at
      FROM revocation_intents WHERE status = 'pending' ORDER BY created_at, revocation_id
    `).all() as RevocationIntent[];
  }

  intent(revocationId: string): RevocationIntent | null {
    return this.#db.query(`
      SELECT principal_id, revocation_id, target_auth_epoch, status, created_at
      FROM revocation_intents WHERE revocation_id = ?
    `).get(revocationId) as RevocationIntent | null;
  }

  watermark(principalId: string): number {
    const row = this.#db.query(`
      SELECT pending_revocation_watermark FROM identity_principals WHERE principal_id = ?
    `).get(principalId) as { pending_revocation_watermark: number } | null;
    if (!row) throw new AppendError("UNAVAILABLE", "identity principal cannot be checked");
    return row.pending_revocation_watermark;
  }

  publishHealthLease(principalId: string, watermark: number, expiresAtMs: number, nowMs: number): boolean {
    if (
      !Number.isSafeInteger(watermark) ||
      expiresAtMs <= nowMs ||
      expiresAtMs - nowMs > MAX_HEALTH_LEASE_MS
    ) {
      const invalidatedWatermark = Number.isSafeInteger(watermark) ? Math.max(0, watermark) : 0;
      this.#db.query(`
        INSERT INTO revocation_health_leases(
          principal_id, watermark, expires_at_ms, healthy, updated_at
        ) VALUES (?, ?, ?, 0, ?)
        ON CONFLICT(principal_id) DO UPDATE SET
          watermark = MAX(revocation_health_leases.watermark, excluded.watermark),
          expires_at_ms = excluded.expires_at_ms,
          healthy = 0,
          updated_at = excluded.updated_at
      `).run(principalId, invalidatedWatermark, nowMs, new Date(nowMs).toISOString());
      return false;
    }
    const transaction = this.#db.transaction(() => {
      const prior = this.#db.query(`
        SELECT watermark FROM revocation_health_leases WHERE principal_id = ?
      `).get(principalId) as { watermark: number } | null;
      if (prior && watermark < prior.watermark) {
        this.#db.query(`
          UPDATE revocation_health_leases
          SET healthy = 0, expires_at_ms = ?, updated_at = ?
          WHERE principal_id = ?
        `).run(nowMs, new Date(nowMs).toISOString(), principalId);
        return false;
      }
      this.#db.query(`
        INSERT INTO revocation_health_leases(
          principal_id, watermark, expires_at_ms, healthy, updated_at
        ) VALUES (?, ?, ?, 1, ?)
        ON CONFLICT(principal_id) DO UPDATE SET
          watermark = excluded.watermark,
          expires_at_ms = excluded.expires_at_ms,
          healthy = 1,
          updated_at = excluded.updated_at
      `).run(principalId, watermark, expiresAtMs, new Date(nowMs).toISOString());
      return true;
    });
    return transaction.immediate();
  }

  #revocationGuardState(principalId: string): RevocationGuardState {
    try {
      const principal = this.#db.query(`
        SELECT disabled, pending_revocation_watermark
        FROM identity_principals WHERE principal_id = ?
      `).get(principalId) as {
        pending_revocation_watermark: number;
        disabled: number;
      } | null;
      const lease = this.#db.query(`
        SELECT watermark, expires_at_ms, healthy
        FROM revocation_health_leases WHERE principal_id = ?
      `).get(principalId) as {
        watermark: number | null;
        expires_at_ms: number | null;
        healthy: number | null;
      } | null;
      const pending = this.#db.query(`
        SELECT EXISTS(
          SELECT 1 FROM revocation_intents
          WHERE principal_id = ? AND status = 'pending'
        ) AS found
      `).get(principalId) as { found: number };
      if (!principal && (lease || pending.found === 1)) {
        return { kind: "revocation_state_unreadable" };
      }
      if (!principal) {
        return {
          kind: "no_revocation_state",
          disabled: 0,
          pending_watermark: 0,
        };
      }
      if (
        principal.disabled === 0 &&
        principal.pending_revocation_watermark === 0 &&
        !lease &&
        pending.found === 0
      ) {
        return {
          kind: "no_revocation_state",
          disabled: principal.disabled,
          pending_watermark: principal.pending_revocation_watermark,
        };
      }
      return {
        kind: "revocation_state_present",
        disabled: principal.disabled,
        pending_watermark: principal.pending_revocation_watermark,
        has_pending_intent: pending.found === 1,
        lease_watermark: lease?.watermark ?? null,
        lease_expires_at_ms: lease?.expires_at_ms ?? null,
        lease_healthy: lease?.healthy ?? null,
      };
    } catch {
      return { kind: "revocation_state_unreadable" };
    }
  }

  // This is the real authorization decision guard. Missing/unreadable identity
  // state, pending intents, expired leases, and regressed lease watermarks all
  // deny the command. A known principal with no revocation history has neither
  // a watermark nor a lease and remains on the normal authorization path.
  permits(principalId: string, commandEpoch: number, nowMs = Date.now()): boolean {
    const state = this.#revocationGuardState(principalId);
    if (state.kind === "revocation_state_unreadable") return false;
    if (state.disabled !== 0 || commandEpoch < state.pending_watermark) return false;
    if (state.kind === "no_revocation_state") return true;
    return (
      !state.has_pending_intent &&
      state.lease_healthy === 1 &&
      state.lease_expires_at_ms !== null &&
      state.lease_expires_at_ms > nowMs &&
      state.lease_watermark !== null &&
      state.lease_watermark >= state.pending_watermark
    );
  }

  finalize(revocationId: string, minimumEpoch: number): IdentityRevocationState {
    crashAt("identity-before-finalization");
    const transaction = this.#db.transaction(() => {
      const intent = this.intent(revocationId);
      if (!intent) throw new AppendError("UNAVAILABLE", "revocation intent cannot be checked");
      if (minimumEpoch < intent.target_auth_epoch) {
        throw new AppendError("AUTHORIZATION_DENIED", "identity finalization epoch is stale");
      }
      this.#db.query(`
        UPDATE identity_principals
        SET disabled = 1, auth_epoch = MAX(auth_epoch, ?),
            pending_revocation_watermark = MAX(pending_revocation_watermark, ?)
        WHERE principal_id = ?
      `).run(minimumEpoch, minimumEpoch, intent.principal_id);
      this.#db.query(`
        UPDATE revocation_intents SET status = 'acknowledged' WHERE revocation_id = ?
      `).run(revocationId);
      return this.state(revocationId);
    });
    const state = transaction.immediate();
    crashAt("identity-after-finalization");
    return state;
  }

  state(revocationId: string): IdentityRevocationState {
    const row = this.#db.query(`
      SELECT p.principal_id, p.auth_epoch, p.disabled,
             p.pending_revocation_watermark, i.status AS intent_status
      FROM revocation_intents i
      JOIN identity_principals p ON p.principal_id = i.principal_id
      WHERE i.revocation_id = ?
    `).get(revocationId) as IdentityRevocationState | null;
    if (!row) throw new AppendError("UNAVAILABLE", "identity revocation state cannot be checked");
    return row;
  }

  recordSlaBreach(revocationId: string): void {
    this.#db.query(`
      INSERT INTO revocation_operator_events(revocation_id, event_type, created_at)
      VALUES (?, 'revocation.sla_exceeded', ?)
      ON CONFLICT(revocation_id) DO NOTHING
    `).run(revocationId, new Date().toISOString());
  }

  operatorEventCount(revocationId: string): number {
    return (this.#db.query(`
      SELECT COUNT(*) AS count FROM revocation_operator_events WHERE revocation_id = ?
    `).get(revocationId) as { count: number }).count;
  }

  principals(): Array<Readonly<{ principal_id: string; watermark: number }>> {
    return this.#db.query(`
      SELECT principal_id, pending_revocation_watermark AS watermark
      FROM identity_principals ORDER BY principal_id
    `).all() as Array<Readonly<{ principal_id: string; watermark: number }>>;
  }

  // The product workflow is out of scope, but the protocol primitive is
  // explicit and durable: collaboration cannot re-enable until identity has
  // authorized the same strictly newer epoch under its own transaction.
  authorizeReenable(
    reenablingId: string,
    principalId: string,
    targetEpoch: number,
  ): void {
    const transaction = this.#db.transaction(() => {
      const prior = this.#db.query(`
        SELECT principal_id, auth_epoch FROM identity_reenable_authorizations
        WHERE reenabling_id = ?
      `).get(reenablingId) as { principal_id: string; auth_epoch: number } | null;
      if (prior) {
        if (prior.principal_id !== principalId || prior.auth_epoch !== targetEpoch) {
          throw new AppendError("IDEMPOTENCY_CONFLICT", "reenabling_id reused with different authorization");
        }
        return;
      }
      const principal = this.#db.query(`
        SELECT auth_epoch FROM identity_principals WHERE principal_id = ?
      `).get(principalId) as { auth_epoch: number } | null;
      const pending = this.#db.query(`
        SELECT 1 FROM revocation_intents
        WHERE principal_id = ? AND status = 'pending' LIMIT 1
      `).get(principalId);
      if (!principal || pending || targetEpoch <= principal.auth_epoch) {
        throw new AppendError(
          "AUTHORIZATION_DENIED",
          "identity re-enablement requires no pending revocation and a strictly newer epoch",
        );
      }
      this.#db.query(`
        UPDATE identity_principals
        SET disabled = 0, auth_epoch = ?,
            pending_revocation_watermark = MAX(pending_revocation_watermark, ?)
        WHERE principal_id = ?
      `).run(targetEpoch, targetEpoch, principalId);
      this.#db.query(`
        INSERT INTO identity_reenable_authorizations(
          reenabling_id, principal_id, auth_epoch, created_at
        ) VALUES (?, ?, ?, ?)
      `).run(reenablingId, principalId, targetEpoch, new Date().toISOString());
    });
    transaction.immediate();
  }

  permitsReenable(
    reenablingId: string,
    principalId: string,
    targetEpoch: number,
    nowMs = Date.now(),
  ): boolean {
    try {
      const authorization = this.#db.query(`
        SELECT 1 FROM identity_reenable_authorizations
        WHERE reenabling_id = ? AND principal_id = ? AND auth_epoch = ?
      `).get(reenablingId, principalId, targetEpoch);
      return authorization !== null && this.permits(principalId, targetEpoch, nowMs);
    } catch {
      return false;
    }
  }

  close(): void {
    this.#db.close();
  }
}

export class RevocationSynchronizer {
  constructor(
    private readonly identity: IdentityRevocationStore,
    private readonly writer: EventWriterClient,
    private readonly leaseExpiresAt: () => number = () => Date.now() + MAX_HEALTH_LEASE_MS,
    private readonly now: () => number = () => Date.now(),
  ) {}

  async reconcile(
    workspaceId: string,
    intent: RevocationIntent,
    options: Readonly<{ antiEntropy?: boolean }> = {},
  ): Promise<RevocationOutcome> {
    const pending = (status: "pending" | "unavailable"): RevocationOutcome => ({
      status,
      revocation_id: intent.revocation_id,
    });
    try {
      const now = this.now();
      const expiresAt = this.leaseExpiresAt();
      const watermark = this.identity.watermark(intent.principal_id);
      if (!this.identity.publishHealthLease(intent.principal_id, watermark, expiresAt, now)) {
        return pending("unavailable");
      }
      if (now - Date.parse(intent.created_at) >= REVOCATION_SLA_MS) {
        this.identity.recordSlaBreach(intent.revocation_id);
        return pending("pending");
      }
      await this.writer.revoke({
        workspace_id: workspaceId,
        principal_id: intent.principal_id,
        revocation_id: intent.revocation_id,
        target_auth_epoch: intent.target_auth_epoch,
        anti_entropy: options.antiEntropy === true,
      });
      const collaboration = await this.writer.revocationStatus({
        workspace_id: workspaceId,
        principal_id: intent.principal_id,
        revocation_id: intent.revocation_id,
      });
      if (
        !collaboration.restrictive ||
        !collaboration.has_event ||
        !collaboration.has_receipt ||
        collaboration.authz_version < intent.target_auth_epoch
      ) {
        return pending("pending");
      }
      this.identity.finalize(intent.revocation_id, collaboration.authz_version);
      const identity = this.identity.state(intent.revocation_id);
      if (
        identity.disabled !== 1 ||
        identity.auth_epoch < intent.target_auth_epoch ||
        identity.intent_status !== "acknowledged"
      ) {
        return pending("pending");
      }
      return pending("success");
    } catch (error) {
      if (error instanceof AppendError) return pending("pending");
      return pending("unavailable");
    }
  }

  async antiEntropy(workspaceId: string): Promise<RevocationOutcome[]> {
    const outcomes: RevocationOutcome[] = [];
    const now = this.now();
    const expiresAt = this.leaseExpiresAt();
    for (const principal of this.identity.principals()) {
      this.identity.publishHealthLease(principal.principal_id, principal.watermark, expiresAt, now);
    }
    // Sequential processing preserves per-principal epoch order and avoids a
    // lower unfinished intent racing a later, more restrictive intent.
    for (const intent of this.identity.pending()) {
      outcomes.push(await this.reconcile(workspaceId, intent, { antiEntropy: true }));
    }
    return outcomes;
  }
}
