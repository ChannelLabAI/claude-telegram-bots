import type { EventEnvelope } from "./envelope.ts";

export type CommandAuthorization = Readonly<{
  // Immutable collaboration principal, never a display name or external handle.
  principal_id: string;
  // The guard compares this exact epoch to the strong principal row on every append.
  authz_version: number;
  // Named capability required for this command; broad presentation roles are not used.
  capability: string;
}>;

export type MembershipMutation = Readonly<{
  principal_id: string;
  stream_id: string;
  active: boolean;
}>;

export type AppendCommand = Readonly<{
  workspace_id: string;
  stream_id: string;
  stream_kind: EventEnvelope["stream_kind"];
  event_type: string;
  schema_version: number;
  actor_id: string;
  actor_kind: EventEnvelope["actor_kind"];
  origin: EventEnvelope["origin"];
  external_ref?: EventEnvelope["external_ref"];
  correlation_id: string;
  causation_id?: string;
  occurred_at: string;
  payload: unknown;
  refs: EventEnvelope["refs"];
  client_id: string;
  idempotency_key: string;
  expected_stream_seq?: number;
  authorization: CommandAuthorization;
  // Membership changes are part of the same writer transaction as their audit event.
  membership_mutation?: MembershipMutation;
}>;

export type AppendResult = Readonly<{
  event: EventEnvelope;
  replayed: boolean;
  request_hash: string;
}>;

export type WriterRequest =
  | Readonly<{ request_id: string; operation: "health" }>
  | Readonly<{ request_id: string; operation: "append"; command: AppendCommand }>;

export type WriterResponse =
  | Readonly<{ request_id: string; ok: true; result: unknown }>
  | Readonly<{
      request_id: string;
      ok: false;
      error: Readonly<{ code: string; message: string }>;
    }>;

export class AppendError extends Error {
  constructor(
    readonly code:
      | "INVALID_COMMAND"
      | "IDEMPOTENCY_CONFLICT"
      | "EXPECTED_STREAM_SEQ_CONFLICT"
      | "AUTHORIZATION_DENIED"
      | "WRITER_ALREADY_RUNNING"
      | "UNAVAILABLE",
    message: string,
    readonly cause?: unknown,
  ) {
    super(message);
    this.name = "AppendError";
  }
}
