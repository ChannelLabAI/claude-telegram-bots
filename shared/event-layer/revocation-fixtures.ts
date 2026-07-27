#!/usr/bin/env bun
import { Database } from "bun:sqlite";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EventWriterClient } from "./src/append-client.ts";
import { IdentityRevocationStore, RevocationSynchronizer } from "./src/revocation.ts";

function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

const writerScript = join(import.meta.dir, "src/writer-process.ts");
const boundaryWorker = join(import.meta.dir, "revocation-boundary-worker.ts");

type Server = Readonly<{
  child: ReturnType<typeof Bun.spawn>;
  client: EventWriterClient;
}>;

async function start(
  databasePath: string,
  endpointPath: string,
  identityPath?: string,
  crashPoint?: string,
  crashSignal?: string,
): Promise<Server> {
  const command = ["bun", "run", writerScript, "--db", databasePath, "--endpoint", endpointPath];
  if (identityPath) command.push("--identity-db", identityPath);
  const child = Bun.spawn(command, {
    cwd: import.meta.dir,
    stdout: "pipe",
    stderr: "pipe",
    env: {
      ...process.env,
      ...(crashPoint ? { EVENT_WRITER_TEST_CRASH_POINT: crashPoint } : {}),
      ...(crashSignal ? { EVENT_WRITER_TEST_CRASH_SIGNAL: crashSignal } : {}),
    },
  });
  const client = new EventWriterClient(endpointPath);
  for (let attempt = 0; attempt < 150; attempt++) {
    try {
      await client.health();
      return { child, client };
    } catch {
      if (child.exitCode !== null) break;
      await Bun.sleep(10);
    }
  }
  throw new Error(`writer health timeout: ${await new Response(child.stderr).text()}`);
}

async function stop(server: Server | undefined): Promise<void> {
  if (server?.child.exitCode === null) {
    server.child.kill("SIGTERM");
    await server.child.exited;
  }
}

function seedPrincipal(databasePath: string, principalId: string, actorId: string, epoch: number): void {
  const database = new Database(databasePath);
  database.query(`
    INSERT INTO authorization_principals(
      workspace_id, principal_id, actor_id, authz_version
    ) VALUES ('w', ?, ?, ?)
  `).run(principalId, actorId, epoch);
  database.query(`
    INSERT INTO authorization_capabilities(workspace_id, principal_id, capability)
    VALUES ('w', ?, 'event.append')
  `).run(principalId);
  database.query(`
    INSERT INTO strong_stream_memberships(workspace_id, stream_id, principal_id, active)
    VALUES ('w', '*', ?, 1)
  `).run(principalId);
  database.close();
}

function seedIdentityPrincipal(databasePath: string, principalId: string, epoch: number): void {
  const database = new Database(databasePath);
  database.query(`
    INSERT INTO identity_principals(
      principal_id, auth_epoch, disabled, pending_revocation_watermark
    ) VALUES (?, ?, 0, 0)
  `).run(principalId, epoch);
  database.close();
}

function mutateIdentitySchema(databasePath: string, sql: string): void {
  const database = new Database(databasePath);
  database.exec(sql);
  database.close();
}

function seedOrphanIntent(databasePath: string, principalId: string, revocationId: string): void {
  const database = new Database(databasePath);
  database.query(`
    INSERT INTO revocation_intents(
      revocation_id, principal_id, target_auth_epoch, status, created_at
    ) VALUES (?, ?, 2, 'pending', ?)
  `).run(revocationId, principalId, new Date().toISOString());
  database.close();
}

function appendCommand(principalId: string, actorId: string, epoch: number, key: string) {
  return {
    workspace_id: "w",
    stream_id: "s",
    stream_kind: "channel" as const,
    event_type: "fixture.append",
    schema_version: 1,
    actor_id: actorId,
    actor_kind: "human" as const,
    origin: "native" as const,
    correlation_id: key,
    occurred_at: new Date().toISOString(),
    payload: { key },
    refs: [],
    client_id: "fixture",
    idempotency_key: key,
    authorization: {
      principal_id: principalId,
      authz_version: epoch,
      capability: "event.append",
    },
  };
}

function count(
  databasePath: string,
  table: "events" | "revocation_receipts" | "reenabling_receipts",
  where = "",
  value?: string,
): number {
  const database = new Database(databasePath, { readonly: true });
  const row = database.query(`
    SELECT COUNT(*) AS count FROM ${table} ${where}
  `).get(...(value === undefined ? [] : [value])) as { count: number };
  database.close();
  return row.count;
}

async function expectKilled(
  child: ReturnType<typeof Bun.spawn>,
  signalPath: string,
  point: string,
): Promise<void> {
  await child.exited;
  assert(
    child.exitCode === 137 || child.signalCode === "SIGKILL",
    `${point} must use real SIGKILL`,
  );
  assert(
    existsSync(signalPath) && readFileSync(signalPath, "utf8").includes(point),
    `${point} signal must prove the boundary was reached`,
  );
}

function spawnIdentityBoundary(
  root: string,
  action: "create" | "reconcile",
  identityPath: string,
  principalId: string,
  revocationId: string,
  epoch: number,
  point: string,
  signalPath: string,
  endpointPath?: string,
) {
  const command = [
    "bun",
    "run",
    boundaryWorker,
    "--action",
    action,
    "--identity-db",
    identityPath,
    "--principal",
    principalId,
    "--revocation",
    revocationId,
    "--epoch",
    String(epoch),
  ];
  if (endpointPath) command.push("--endpoint", endpointPath, "--workspace", "w");
  return Bun.spawn(command, {
    cwd: root,
    stdout: "pipe",
    stderr: "pipe",
    env: {
      ...process.env,
      REVOCATION_TEST_CRASH_POINT: point,
      EVENT_WRITER_TEST_CRASH_SIGNAL: signalPath,
    },
  });
}

const root = mkdtempSync(join(tmpdir(), "revocation-fixtures-"));
const eventDb = join(root, "events.db");
const identityDb = join(root, "users.db");
const endpoint = join(root, "endpoint");
let server: Server | undefined;

try {
  // Initialize the collaboration schema before seeding strong authorization.
  server = await start(eventDb, endpoint);
  await stop(server);
  server = undefined;
  seedPrincipal(eventDb, "p", "actor-p", 1);

  // Boundary 1: crash before the identity transaction leaves no intent.
  const beforePendingSignal = join(root, "boundary-1");
  const beforePending = spawnIdentityBoundary(
    root,
    "create",
    identityDb,
    "p",
    "r-before",
    2,
    "identity-before-pending",
    beforePendingSignal,
  );
  await expectKilled(beforePending, beforePendingSignal, "identity-before-pending");
  let identity = new IdentityRevocationStore(identityDb);
  assert(identity.intent("r-before") === null, "pre-intent crash must leave no intent");
  identity.close();

  // A principal that exists in identity but has never entered a revocation
  // flow has no health lease. Wiring the identity guard must preserve this
  // normal append path; leases become mandatory only after revocation state
  // exists for that principal.
  seedPrincipal(eventDb, "normal-no-shadow-row", "actor-normal-no-shadow-row", 1);
  server = await start(eventDb, endpoint, identityDb);
  await server.client.append(
    appendCommand(
      "normal-no-shadow-row",
      "actor-normal-no-shadow-row",
      1,
      "normal-no-shadow-row",
    ),
  );
  assert(
    count(eventDb, "events", "WHERE correlation_id = ?", "normal-no-shadow-row") === 1,
    "never-revoked principal with no shadow row must pass the wired identity guard",
  );
  seedPrincipal(eventDb, "normal-known-identity", "actor-normal-known-identity", 1);
  seedIdentityPrincipal(identityDb, "normal-known-identity", 1);
  await server.client.append(
    appendCommand(
      "normal-known-identity",
      "actor-normal-known-identity",
      1,
      "normal-known-identity",
    ),
  );
  assert(
    count(eventDb, "events", "WHERE correlation_id = ?", "normal-known-identity") === 1,
    "known identity with no revocation state must pass the wired identity guard",
  );
  seedPrincipal(eventDb, "orphan-intent", "actor-orphan-intent", 1);
  seedOrphanIntent(identityDb, "orphan-intent", "r-orphan-intent");
  const beforeOrphanIntent = count(eventDb, "events");
  let orphanIntentDenied = false;
  try {
    await server.client.append(
      appendCommand("orphan-intent", "actor-orphan-intent", 1, "orphan-intent"),
    );
  } catch {
    orphanIntentDenied = true;
  }
  assert(
    orphanIntentDenied && count(eventDb, "events") === beforeOrphanIntent,
    "revocation artifact without its principal row must fail closed with zero writes",
  );
  await stop(server);
  server = undefined;

  // The happy-path branch is available only when absence is proven. An
  // unreadable revocation table must not be mistaken for no revocation state.
  seedPrincipal(eventDb, "intent-unreadable", "actor-intent-unreadable", 1);
  seedIdentityPrincipal(identityDb, "intent-unreadable", 1);
  server = await start(eventDb, endpoint, identityDb);
  mutateIdentitySchema(identityDb, "DROP TABLE revocation_intents");
  const beforeUnreadableIntent = count(eventDb, "events");
  let unreadableIntentDenied = false;
  try {
    await server.client.append(
      appendCommand("intent-unreadable", "actor-intent-unreadable", 1, "intent-unreadable"),
    );
  } catch {
    unreadableIntentDenied = true;
  }
  assert(
    unreadableIntentDenied && count(eventDb, "events") === beforeUnreadableIntent,
    "unreadable revocation intent state must fail closed with zero writes",
  );
  await stop(server);
  server = undefined;
  const restoreIntents = new IdentityRevocationStore(identityDb);
  restoreIntents.close();

  // A schema-level query failure is likewise the explicit unreadable state,
  // not the never-revoked state.
  seedPrincipal(eventDb, "lease-schema-broken", "actor-lease-schema-broken", 1);
  seedIdentityPrincipal(identityDb, "lease-schema-broken", 1);
  server = await start(eventDb, endpoint, identityDb);
  mutateIdentitySchema(identityDb, "ALTER TABLE revocation_health_leases DROP COLUMN healthy");
  const beforeBrokenLeaseSchema = count(eventDb, "events");
  let brokenLeaseSchemaDenied = false;
  try {
    await server.client.append(
      appendCommand(
        "lease-schema-broken",
        "actor-lease-schema-broken",
        1,
        "lease-schema-broken",
      ),
    );
  } catch {
    brokenLeaseSchemaDenied = true;
  }
  assert(
    brokenLeaseSchemaDenied && count(eventDb, "events") === beforeBrokenLeaseSchema,
    "missing lease schema column must fail closed with zero writes",
  );
  await stop(server);
  server = undefined;
  mutateIdentitySchema(identityDb, "DROP TABLE revocation_health_leases");
  const restoreLeases = new IdentityRevocationStore(identityDb);
  restoreLeases.close();

  // A thrown read from a closed store is the third unreadable-state oracle.
  const closedIdentity = new IdentityRevocationStore(join(root, "closed-users.db"));
  seedIdentityPrincipal(join(root, "closed-users.db"), "closed-store", 1);
  closedIdentity.close();
  assert(
    !closedIdentity.permits("closed-store", 1),
    "closed identity store read must fail closed",
  );

  // Boundary 2: crash after commit cannot acknowledge the caller, but the
  // pending intent and watermark must both be durable.
  const afterPendingSignal = join(root, "boundary-2");
  const afterPending = spawnIdentityBoundary(
    root,
    "create",
    identityDb,
    "p",
    "r-main",
    2,
    "identity-after-pending",
    afterPendingSignal,
  );
  await expectKilled(afterPending, afterPendingSignal, "identity-after-pending");
  identity = new IdentityRevocationStore(identityDb);
  const mainIntent = identity.intent("r-main");
  assert(
    mainIntent?.status === "pending" && identity.watermark("p") === 2,
    "post-intent crash must preserve pending intent and monotonic watermark",
  );

  // Boundary 3: writer death before its transaction returns pending, writes
  // nothing, and the genuine append IPC path rejects the old epoch.
  const beforeWriterSignal = join(root, "boundary-3");
  server = await start(
    eventDb,
    endpoint,
    identityDb,
    "revoke-before-transaction",
    beforeWriterSignal,
  );
  const beforeWriter = await new RevocationSynchronizer(
    identity,
    new EventWriterClient(endpoint, 250),
  ).reconcile("w", mainIntent!);
  await expectKilled(server.child, beforeWriterSignal, "revoke-before-transaction");
  server = undefined;
  assert(beforeWriter.status !== "success", "pre-writer-transaction crash must never return success");
  assert(
    count(eventDb, "revocation_receipts", "WHERE revocation_id = ?", "r-main") === 0 &&
      count(eventDb, "events", "WHERE correlation_id = ?", "r-main") === 0,
    "pre-writer-transaction crash must leave zero collaboration artifacts",
  );
  server = await start(eventDb, endpoint, identityDb);
  let denied = false;
  try {
    await server.client.append(appendCommand("p", "actor-p", 1, "pending-window"));
  } catch {
    denied = true;
  }
  assert(denied, "pending-window old epoch must be denied through authorizeAppend IPC");
  await stop(server);
  server = undefined;

  // Boundary 4: death after COMMIT but before IPC response leaves the caller
  // pending while all collaboration facts are durable and retryable.
  const afterWriterSignal = join(root, "boundary-4");
  server = await start(
    eventDb,
    endpoint,
    identityDb,
    "revoke-after-transaction",
    afterWriterSignal,
  );
  const afterWriter = await new RevocationSynchronizer(
    identity,
    new EventWriterClient(endpoint, 250),
  ).reconcile("w", mainIntent!);
  await expectKilled(server.child, afterWriterSignal, "revoke-after-transaction");
  server = undefined;
  assert(afterWriter.status !== "success", "post-writer-commit crash must never return success");
  assert(
    count(eventDb, "revocation_receipts", "WHERE revocation_id = ?", "r-main") === 1 &&
      count(eventDb, "events", "WHERE correlation_id = ?", "r-main") === 1 &&
      identity.intent("r-main")?.status === "pending",
    "post-writer-commit crash must preserve one receipt/event and pending identity",
  );

  server = await start(eventDb, endpoint, identityDb);

  // Boundaries 5 and 6: real process deaths immediately before and immediately
  // after the identity finalization transaction. Neither child can return
  // success; restart/retry observes the durable side of the boundary.
  const beforeFinalizeSignal = join(root, "boundary-5");
  const beforeFinalize = spawnIdentityBoundary(
    root,
    "reconcile",
    identityDb,
    "p",
    "r-main",
    2,
    "identity-before-finalization",
    beforeFinalizeSignal,
    endpoint,
  );
  await expectKilled(beforeFinalize, beforeFinalizeSignal, "identity-before-finalization");
  assert(
    identity.intent("r-main")?.status === "pending",
    "pre-finalization crash must leave identity pending",
  );

  const afterFinalizeSignal = join(root, "boundary-6");
  const afterFinalize = spawnIdentityBoundary(
    root,
    "reconcile",
    identityDb,
    "p",
    "r-main",
    2,
    "identity-after-finalization",
    afterFinalizeSignal,
    endpoint,
  );
  await expectKilled(afterFinalize, afterFinalizeSignal, "identity-after-finalization");
  const converged = identity.state("r-main");
  assert(
    converged.intent_status === "acknowledged" &&
      converged.disabled === 1 &&
      converged.auth_epoch === 2,
    "post-finalization crash must preserve restrictive acknowledged identity state",
  );
  const status = await server.client.revocationStatus({
    workspace_id: "w",
    principal_id: "p",
    revocation_id: "r-main",
  });
  assert(
    status.restrictive && status.has_event && status.has_receipt && status.authz_version === 2,
    "both durable reads must prove convergence after boundary recovery",
  );
  assert(
    (await new RevocationSynchronizer(identity, server.client).antiEntropy("w")).length === 0,
    "acknowledged revocation must not be implicitly replayed or re-enabled",
  );

  // Re-enablement is impossible by retry or same epoch. It requires a separate
  // identity authorization and writer audit event at a strictly newer epoch.
  let reenableDenied = false;
  try {
    await server.client.reenable({
      workspace_id: "w",
      principal_id: "p",
      reenabling_id: "enable-denied",
      target_auth_epoch: 2,
      scopes: ["event.append"],
    });
  } catch {
    reenableDenied = true;
  }
  assert(reenableDenied, "same-epoch or implicit re-enablement must be denied");
  identity.authorizeReenable("enable-1", "p", 3);
  assert(
    identity.publishHealthLease("p", 3, Date.now() + 5_000, Date.now()),
    "newer identity re-enablement must publish a healthy lease",
  );
  reenableDenied = false;
  try {
    await server.client.reenable({
      workspace_id: "w",
      principal_id: "p",
      reenabling_id: "enable-not-authorized",
      target_auth_epoch: 3,
      scopes: ["event.append"],
    });
  } catch {
    reenableDenied = true;
  }
  assert(reenableDenied, "writer must bind re-enablement to the exact identity authorization");
  const enabled = await server.client.reenable({
    workspace_id: "w",
    principal_id: "p",
    reenabling_id: "enable-1",
    target_auth_epoch: 3,
    scopes: ["event.append"],
  });
  const enabledReplay = await server.client.reenable({
    workspace_id: "w",
    principal_id: "p",
    reenabling_id: "enable-1",
    target_auth_epoch: 3,
    scopes: ["event.append"],
  });
  assert(
    !enabled.replayed &&
      enabledReplay.replayed &&
      count(eventDb, "reenabling_receipts", "WHERE reenabling_id = ?", "enable-1") === 1 &&
      count(eventDb, "events", "WHERE correlation_id = ?", "enable-1") === 1,
    "separate newer audited re-enablement must be exactly once",
  );
  const postEnableStatus = await server.client.revocationStatus({
    workspace_id: "w",
    principal_id: "p",
    revocation_id: "r-main",
  });
  assert(
    !postEnableStatus.restrictive && postEnableStatus.authz_version === 3,
    "only the separate newer audited command may clear collaboration disabled state",
  );
  await server.client.append(appendCommand("p", "actor-p", 3, "after-explicit-reenable"));

  // Lease regression invalidates the durable lease and causes the real append
  // path to fail closed with zero writes.
  const appendCountBeforeRegression = count(eventDb, "events");
  const regressionNow = Date.now();
  assert(
    !identity.publishHealthLease("p", 2, regressionNow + 5_000, regressionNow),
    "lease epoch regression must be rejected",
  );
  denied = false;
  try {
    await server.client.append(appendCommand("p", "actor-p", 3, "lease-regressed"));
  } catch {
    denied = true;
  }
  assert(
    denied && count(eventDb, "events") === appendCountBeforeRegression,
    "regressed lease must fail closed with zero append writes",
  );
  assert(
    identity.publishHealthLease("p", 3, Date.now() + 5_000, Date.now()),
    "same monotonic watermark must restore a healthy lease",
  );

  // Expired and oversized leases, explicit writer timeout, collaboration
  // unavailability, and identity-store unavailability all remain non-success.
  seedPrincipal(eventDb, "lease", "actor-lease", 1);
  const leaseIntent = identity.createIntent("lease", "r-lease", 2);
  const expiredNow = Date.now();
  const receiptBaseline = count(eventDb, "revocation_receipts");
  assert(
    (await new RevocationSynchronizer(
      identity,
      server.client,
      () => expiredNow,
      () => expiredNow,
    ).reconcile("w", leaseIntent)).status === "unavailable",
    "expired lease must fail closed",
  );
  assert(
    (await new RevocationSynchronizer(
      identity,
      server.client,
      () => expiredNow + 5_001,
      () => expiredNow,
    ).reconcile("w", leaseIntent)).status === "unavailable",
    "lease over five seconds must fail closed",
  );
  assert(
    count(eventDb, "revocation_receipts") === receiptBaseline,
    "invalid lease paths must perform zero collaboration writes",
  );

  seedPrincipal(eventDb, "timeout", "actor-timeout", 1);
  const timeoutIntent = identity.createIntent("timeout", "r-timeout", 2);
  const timeoutOutcome = await new RevocationSynchronizer(
    identity,
    new EventWriterClient(join(root, "missing-endpoint"), 30),
  ).reconcile("w", timeoutIntent);
  await Bun.sleep(40);
  assert(
    timeoutOutcome.status !== "success" &&
      identity.intent("r-timeout")?.status === "pending" &&
      count(eventDb, "revocation_receipts", "WHERE revocation_id = ?", "r-timeout") === 0,
    "timeout must remain pending/unavailable and must never become eventual success",
  );

  seedPrincipal(eventDb, "identity-down", "actor-down", 1);
  const unavailableIdentityPath = join(root, "unavailable-users.db");
  const unavailableIdentity = new IdentityRevocationStore(unavailableIdentityPath);
  const unavailableIntent = unavailableIdentity.createIntent("identity-down", "r-identity-down", 2);
  unavailableIdentity.close();
  const beforeIdentityDown = count(eventDb, "revocation_receipts");
  const identityDownOutcome = await new RevocationSynchronizer(
    unavailableIdentity,
    server.client,
  ).reconcile("w", unavailableIntent);
  assert(
    identityDownOutcome.status !== "success" &&
      count(eventDb, "revocation_receipts") === beforeIdentityDown,
    "unreadable identity store must fail closed with zero collaboration writes",
  );

  // A normal command with a lower target epoch is rejected, not silently
  // clamped. The anti-entropy exception is exercised separately below.
  seedPrincipal(eventDb, "rollback", "actor-rollback", 5);
  const rollbackIntent = identity.createIntent("rollback", "r-rollback", 4);
  const rollbackBefore = count(eventDb, "events");
  const rollbackOutcome = await new RevocationSynchronizer(
    identity,
    server.client,
  ).reconcile("w", rollbackIntent);
  assert(
    rollbackOutcome.status !== "success" &&
      count(eventDb, "events") === rollbackBefore &&
      count(eventDb, "revocation_receipts", "WHERE revocation_id = ?", "r-rollback") === 0,
    "epoch rollback must be rejected with zero writer artifacts",
  );

  // The 30-second hard SLA creates one durable operator-page trigger, leaves
  // the intent pending/fail-closed, and does not try a late writer success.
  seedPrincipal(eventDb, "sla", "actor-sla", 1);
  const slaIntent = identity.createIntent("sla", "r-sla", 2);
  const slaNow = Date.parse(slaIntent.created_at) + 30_001;
  const slaBefore = count(eventDb, "revocation_receipts");
  const slaSync = new RevocationSynchronizer(
    identity,
    server.client,
    () => slaNow + 5_000,
    () => slaNow,
  );
  assert((await slaSync.reconcile("w", slaIntent)).status === "pending", "SLA timeout must stay pending");
  assert((await slaSync.reconcile("w", slaIntent)).status === "pending", "SLA retry must stay pending");
  assert(
    identity.operatorEventCount("r-sla") === 1 &&
      count(eventDb, "revocation_receipts") === slaBefore,
    "SLA timeout must trigger exactly one operator event and zero late writes",
  );

  // Lost notifications and restart anti-entropy repair both kinds of missing
  // collaboration artifact exactly once, then leave no unfinished intent.
  seedPrincipal(eventDb, "repair", "actor-repair", 1);
  const repairOne = identity.createIntent("repair", "r-missing-receipt", 2);
  await server.client.revoke({
    workspace_id: "w",
    principal_id: "repair",
    revocation_id: repairOne.revocation_id,
    target_auth_epoch: repairOne.target_auth_epoch,
  });
  await stop(server);
  server = undefined;
  let corruptor = new Database(eventDb);
  corruptor.query("DELETE FROM revocation_receipts WHERE revocation_id = ?").run(repairOne.revocation_id);
  corruptor.close();
  server = await start(eventDb, endpoint, identityDb);
  const repairedReceipt = await new RevocationSynchronizer(identity, server.client).antiEntropy("w");
  assert(
    repairedReceipt.some((outcome) => outcome.revocation_id === repairOne.revocation_id && outcome.status === "success") &&
      count(eventDb, "revocation_receipts", "WHERE revocation_id = ?", repairOne.revocation_id) === 1 &&
      count(eventDb, "events", "WHERE correlation_id = ?", repairOne.revocation_id) === 1,
    "anti-entropy must recreate a missing receipt exactly once",
  );

  const repairTwo = identity.createIntent("repair", "r-missing-event", 3);
  const repairTwoReceipt = await server.client.revoke({
    workspace_id: "w",
    principal_id: "repair",
    revocation_id: repairTwo.revocation_id,
    target_auth_epoch: repairTwo.target_auth_epoch,
  });
  await stop(server);
  server = undefined;
  corruptor = new Database(eventDb);
  corruptor.query("DELETE FROM events WHERE event_id = ?").run(repairTwoReceipt.event_id);
  corruptor.close();
  server = await start(eventDb, endpoint, identityDb);
  const repairedEvent = await new RevocationSynchronizer(identity, server.client).antiEntropy("w");
  assert(
    repairedEvent.some((outcome) => outcome.revocation_id === repairTwo.revocation_id && outcome.status === "success") &&
      count(eventDb, "revocation_receipts", "WHERE revocation_id = ?", repairTwo.revocation_id) === 1 &&
      count(eventDb, "events", "WHERE correlation_id = ?", repairTwo.revocation_id) === 1,
    "anti-entropy must recreate a missing immutable event exactly once",
  );
  assert(
    (await new RevocationSynchronizer(identity, server.client).antiEntropy("w"))
      .every((outcome) => outcome.revocation_id !== repairTwo.revocation_id) &&
      count(eventDb, "events", "WHERE correlation_id = ?", repairTwo.revocation_id) === 1,
    "a second anti-entropy scan must not duplicate repaired artifacts",
  );

  // An older unfinished notification reconciles at the maximum collaboration
  // epoch only in anti-entropy mode; it can never decrement the epoch.
  const oldIntent = identity.createIntent("repair", "r-old-notification", 2);
  const oldRecovery = await new RevocationSynchronizer(identity, server.client).antiEntropy("w");
  const repairStatus = await server.client.revocationStatus({
    workspace_id: "w",
    principal_id: "repair",
    revocation_id: oldIntent.revocation_id,
  });
  assert(
    oldRecovery.some((outcome) => outcome.revocation_id === oldIntent.revocation_id && outcome.status === "success") &&
      repairStatus.authz_version === 3,
    "anti-entropy must retain the maximum epoch for an older unfinished intent",
  );

  identity.close();
  console.log(
    "revocation fixtures: normal identity-guard path, 6/6 SIGKILL boundaries, durable dual-read ack, lease/store fail-closed, timeout never-success, SLA page, artifact repair, anti-entropy, audited re-enable PASS",
  );
} finally {
  await stop(server);
  rmSync(root, { recursive: true, force: true });
}
