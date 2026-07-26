import type { Database } from "bun:sqlite";
import { AppendError, type AppendCommand } from "./append-types.ts";

type PrincipalRow = Readonly<{
  actor_id: string;
  authz_version: number;
  disabled: number;
}>;

// This guard deliberately reads only strong rows in the writer transaction. It
// has no dependency on a UI/search/message projection or client-supplied role.
export function authorizeAppend(db: Database, command: AppendCommand): void {
  const authorization = command.authorization;
  if (!authorization || !Number.isSafeInteger(authorization.authz_version)) {
    throw new AppendError("AUTHORIZATION_DENIED", "missing or invalid command authorization");
  }
  const principal = db.query(`
    SELECT actor_id, authz_version, disabled
    FROM authorization_principals
    WHERE workspace_id = ? AND principal_id = ?
  `).get(command.workspace_id, authorization.principal_id) as PrincipalRow | null;
  if (!principal || principal.disabled !== 0) {
    throw new AppendError("AUTHORIZATION_DENIED", "principal is absent or disabled");
  }
  if (principal.actor_id !== command.actor_id) {
    throw new AppendError("AUTHORIZATION_DENIED", "actor is not bound to principal");
  }
  if (principal.authz_version !== authorization.authz_version) {
    throw new AppendError("AUTHORIZATION_DENIED", "stale authorization version");
  }
  const capability = db.query(`
    SELECT 1 FROM authorization_capabilities
    WHERE workspace_id = ? AND principal_id = ? AND capability = ?
  `).get(command.workspace_id, authorization.principal_id, authorization.capability);
  if (!capability) {
    throw new AppendError("AUTHORIZATION_DENIED", "principal lacks command capability");
  }
  const membership = db.query(`
    SELECT 1 FROM strong_stream_memberships
    WHERE workspace_id = ? AND principal_id = ? AND active = 1
      AND (stream_id = ? OR stream_id = '*')
  `).get(command.workspace_id, authorization.principal_id, command.stream_id);
  if (!membership) {
    throw new AppendError("AUTHORIZATION_DENIED", "principal is not an active stream member");
  }
}

export function applyMembershipMutation(db: Database, command: AppendCommand): void {
  const mutation = command.membership_mutation;
  if (!mutation) return;
  if (command.authorization.capability !== "membership.manage") {
    throw new AppendError("AUTHORIZATION_DENIED", "membership changes require membership.manage");
  }
  const target = db.query(`
    SELECT authz_version FROM authorization_principals
    WHERE workspace_id = ? AND principal_id = ?
  `).get(command.workspace_id, mutation.principal_id) as { authz_version: number } | null;
  if (!target) throw new AppendError("AUTHORIZATION_DENIED", "membership target is unknown");
  db.query(`
    INSERT INTO strong_stream_memberships(workspace_id, stream_id, principal_id, active)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(workspace_id, stream_id, principal_id)
    DO UPDATE SET active = excluded.active
  `).run(command.workspace_id, mutation.stream_id, mutation.principal_id, mutation.active ? 1 : 0);
  db.query(`
    UPDATE authorization_principals SET authz_version = authz_version + 1
    WHERE workspace_id = ? AND principal_id = ?
  `).run(command.workspace_id, mutation.principal_id);
}
