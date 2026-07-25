import type { EventEnvelope } from "./envelope.ts";

export type ProjectionDefinition<State> = Readonly<{
  id: string;
  initial: () => State;
  reduce: (state: State, event: EventEnvelope) => State;
}>;

export type ProjectionResults = ReadonlyMap<string, unknown>;

/**
 * Registry and runner for deterministic event-derived state.  Definitions receive
 * an event and prior state only: persistence, network calls, clocks, and effects
 * belong outside this boundary.
 */
export class ProjectionRegistry {
  readonly #definitions = new Map<string, ProjectionDefinition<unknown>>();

  register<State>(definition: ProjectionDefinition<State>): void {
    if (this.#definitions.has(definition.id)) {
      throw new Error(`projection ${definition.id} is already registered`);
    }
    this.#definitions.set(definition.id, definition as ProjectionDefinition<unknown>);
  }

  rebuild(events: readonly EventEnvelope[]): ProjectionResults {
    const results = new Map<string, unknown>();
    for (const [id, definition] of this.#definitions) {
      let state = definition.initial();
      for (const event of events) state = definition.reduce(state, event);
      results.set(id, state);
    }
    return results;
  }
}

export type KnowledgeLifecycleState =
  | "draft"
  | "proposed"
  | "verified"
  | "superseded"
  | "revoked";

export type KnowledgeLifecycleEventPayload = Readonly<{
  knowledge_id: string;
  transition: KnowledgeLifecycleState;
  target_revision: number;
  source_event_ids: readonly string[];
  content_hash: string;
  content_schema_version: number;
  scope: readonly string[];
  valid_from: string;
  valid_until?: string;
  reason_code: string;
  origin_actor: Readonly<{ id: string; kind: "human" | "bot" | "system" }>;
  producer_model?: string;
  reviewer_actor_id?: string;
  successor_knowledge_id?: string;
  source_restricted?: boolean;
}>;

export type KnowledgeRecord = Readonly<{
  knowledge_id: string;
  revision: number;
  lifecycle: KnowledgeLifecycleState;
  provenance: KnowledgeLifecycleEventPayload;
  source_restricted: boolean;
}>;

export type KnowledgeProjectionState = Readonly<{
  applied_event_ids: readonly string[];
  records: Readonly<Record<string, KnowledgeRecord>>;
}>;

const legalNextStates: Readonly<Record<KnowledgeLifecycleState, readonly KnowledgeLifecycleState[]>> = {
  draft: ["proposed", "revoked"],
  proposed: ["verified", "revoked"],
  verified: ["superseded", "revoked"],
  superseded: ["revoked"],
  revoked: [],
};

function lifecyclePayload(event: EventEnvelope): KnowledgeLifecycleEventPayload | undefined {
  if (event.event_type !== "knowledge.lifecycle") return undefined;
  const payload = event.payload as Partial<KnowledgeLifecycleEventPayload>;
  if (
    !payload ||
    typeof payload.knowledge_id !== "string" ||
    !Object.hasOwn(legalNextStates, payload.transition ?? "") ||
    !Number.isInteger(payload.target_revision) ||
    payload.target_revision! < 1 ||
    !Array.isArray(payload.source_event_ids) ||
    payload.source_event_ids.some((id) => typeof id !== "string" || id.length === 0) ||
    typeof payload.content_hash !== "string" ||
    typeof payload.content_schema_version !== "number" ||
    !Array.isArray(payload.scope) ||
    typeof payload.valid_from !== "string" ||
    typeof payload.reason_code !== "string" ||
    !payload.origin_actor ||
    typeof payload.origin_actor.id !== "string" ||
    !["human", "bot", "system"].includes(payload.origin_actor.kind ?? "")
  ) {
    throw new Error(`invalid knowledge.lifecycle payload for ${event.event_id}`);
  }
  return payload as KnowledgeLifecycleEventPayload;
}

function validateTransition(
  previous: KnowledgeRecord | undefined,
  payload: KnowledgeLifecycleEventPayload,
): void {
  if (!previous) {
    if (payload.transition !== "draft" && payload.transition !== "proposed") {
      throw new Error(`knowledge ${payload.knowledge_id} must start as draft or proposed`);
    }
  } else if (!legalNextStates[previous.lifecycle].includes(payload.transition)) {
    throw new Error(`illegal knowledge lifecycle transition ${previous.lifecycle} -> ${payload.transition}`);
  }
  if (payload.transition === "verified") {
    if (!payload.reviewer_actor_id || payload.source_event_ids.length === 0) {
      throw new Error("verified knowledge requires a reviewer and source events");
    }
    if (
      payload.origin_actor.kind === "bot" &&
      payload.reviewer_actor_id === payload.origin_actor.id
    ) {
      throw new Error("a bot cannot verify its own knowledge proposal");
    }
  }
  if (payload.transition === "superseded" && !payload.successor_knowledge_id) {
    throw new Error("superseded knowledge requires successor_knowledge_id");
  }
  if (previous && payload.target_revision <= previous.revision) {
    throw new Error(`knowledge ${payload.knowledge_id} revision must increase`);
  }
}

export const knowledgeLifecycleProjection: ProjectionDefinition<KnowledgeProjectionState> = {
  id: "knowledge-lifecycle",
  initial: () => ({ applied_event_ids: [], records: {} }),
  reduce: (state, event) => {
    const payload = lifecyclePayload(event);
    if (!payload || state.applied_event_ids.includes(event.event_id)) return state;
    const previous = state.records[payload.knowledge_id];
    validateTransition(previous, payload);
    const record: KnowledgeRecord = {
      knowledge_id: payload.knowledge_id,
      revision: payload.target_revision,
      lifecycle: payload.transition,
      provenance: payload,
      source_restricted: payload.source_restricted === true,
    };
    return {
      applied_event_ids: [...state.applied_event_ids, event.event_id],
      records: { ...state.records, [payload.knowledge_id]: record },
    };
  },
};

export type ProjectionReadAuthorization = (
  record: KnowledgeRecord,
) => boolean;

/** Returns no metadata when the current strong authorization decision denies access. */
export function readAuthorizedKnowledge(
  state: KnowledgeProjectionState,
  authorize: ProjectionReadAuthorization,
): readonly KnowledgeRecord[] {
  return Object.values(state.records).filter(
    (record) => !record.source_restricted && authorize(record),
  );
}
