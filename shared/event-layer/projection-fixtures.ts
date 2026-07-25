#!/usr/bin/env bun
import {
  knowledgeLifecycleProjection,
  ProjectionRegistry,
  readAuthorizedKnowledge,
  type KnowledgeLifecycleEventPayload,
} from "./src/index.ts";
import type { EventEnvelope } from "./src/envelope.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(`projection fixture assertion failed: ${message}`);
}

function event(
  ordinal: number,
  payload: Partial<KnowledgeLifecycleEventPayload>,
): EventEnvelope {
  return {
    global_seq: ordinal,
    stream_seq: ordinal,
    batch_position: 0,
    event_id: `01J000000000000000000000${String(ordinal).padStart(2, "0")}`,
    workspace_id: "workspace-fixture",
    stream_id: "knowledge-fixture",
    stream_kind: "knowledge",
    event_type: "knowledge.lifecycle",
    schema_version: 1,
    actor_id: "human-reviewer",
    actor_kind: "human",
    origin: "native",
    correlation_id: `projection-${ordinal}`,
    occurred_at: `2026-07-24T00:00:${String(ordinal).padStart(2, "0")}Z`,
    ingested_at: `2026-07-24T00:00:${String(ordinal).padStart(2, "0")}Z`,
    refs: [],
    payload: {
      knowledge_id: "knowledge-1",
      transition: "draft",
      target_revision: 1,
      source_event_ids: ["01J0000000000000000000SOURCE"],
      content_hash: "sha256:fixture",
      content_schema_version: 1,
      scope: ["workspace-fixture"],
      valid_from: "2026-07-24T00:00:00Z",
      reason_code: "fixture",
      origin_actor: { id: "bot-producer", kind: "bot" },
      ...payload,
    },
  };
}

function stateFor(events: readonly EventEnvelope[]) {
  const registry = new ProjectionRegistry();
  registry.register(knowledgeLifecycleProjection);
  return registry.rebuild(events).get("knowledge-lifecycle")!;
}

/**
 * Models an incremental projection worker recovering its persisted state between
 * events. This deliberately differs from the registry's empty-target rebuild
 * path, which owns a fresh state and replays the complete event stream at once.
 */
function checkpoint<State>(state: State): State {
  return JSON.parse(JSON.stringify(state)) as State;
}

function incrementalStateFor(events: readonly EventEnvelope[]) {
  let state = knowledgeLifecycleProjection.initial();
  for (const current of events) {
    state = checkpoint(knowledgeLifecycleProjection.reduce(state, current));
  }
  return state;
}

const stream = [
  event(1, { transition: "draft", target_revision: 1 }),
  event(2, { transition: "proposed", target_revision: 2 }),
  event(3, {
    transition: "verified",
    target_revision: 3,
    reviewer_actor_id: "human-reviewer",
  }),
  event(4, {
    transition: "superseded",
    target_revision: 4,
    successor_knowledge_id: "knowledge-2",
  }),
];

const incremental = incrementalStateFor(stream);
const rebuilt = stateFor(stream);
assert(
  JSON.stringify(incremental) === JSON.stringify(rebuilt),
  "empty-target full rebuild must equal checkpointed incremental projection",
);

for (let length = 0; length <= stream.length; length += 1) {
  const prefix = stream.slice(0, length);
  const once = stateFor(prefix);
  const twice = stateFor([...prefix, ...prefix]);
  assert(JSON.stringify(once) === JSON.stringify(twice), `idempotence failed for prefix ${length}`);
}

for (let seed = 1; seed <= 32; seed += 1) {
  const generated = Array.from({ length: 3 }, (_, claim) => [
    event(claim * 4 + 1, { knowledge_id: `knowledge-${claim}`, transition: "draft" }),
    event(claim * 4 + 2, { knowledge_id: `knowledge-${claim}`, transition: "proposed", target_revision: 2 }),
    event(claim * 4 + 3, {
      knowledge_id: `knowledge-${claim}`,
      transition: "verified",
      target_revision: 3,
      reviewer_actor_id: "human-reviewer",
    }),
  ]);
  let random = seed;
  const interleaved: EventEnvelope[] = [];
  while (generated.some((events) => events.length > 0)) {
    random = (random * 1_103_515_245 + 12_345) & 0x7fff_ffff;
    const ready = generated
      .map((events, index) => ({ events, index }))
      .filter(({ events }) => events.length > 0);
    interleaved.push(ready[random % ready.length]!.events.shift()!);
  }
  const once = stateFor(interleaved);
  const replayed = stateFor([...interleaved, ...interleaved]);
  assert(
    JSON.stringify(once) === JSON.stringify(replayed),
    `generated idempotence failed for seed ${seed}`,
  );
}

const readable = readAuthorizedKnowledge(rebuilt as ReturnType<typeof knowledgeLifecycleProjection.initial>, () => true);
assert(readable.length === 1 && readable[0]!.lifecycle === "superseded", "authorized read missing record");
const hidden = readAuthorizedKnowledge(rebuilt as ReturnType<typeof knowledgeLifecycleProjection.initial>, () => false);
assert(hidden.length === 0, "unauthorized filtered read must return an empty result");

let selfVerificationRejected = false;
try {
  stateFor([
    event(1, { transition: "proposed" }),
    event(2, { transition: "verified", target_revision: 2, reviewer_actor_id: "bot-producer" }),
  ]);
} catch (error) {
  selfVerificationRejected = String(error).includes("cannot verify its own");
}
assert(selfVerificationRejected, "bot self-verification must be rejected");

let illegalTransitionRejected = false;
try {
  stateFor([event(1, { transition: "verified", reviewer_actor_id: "human-reviewer" })]);
} catch (error) {
  illegalTransitionRejected = String(error).includes("must start");
}
assert(illegalTransitionRejected, "invalid lifecycle start must be rejected");

console.log("event-projection fixtures: PASS");
console.log("  empty-target full rebuild equals checkpointed incremental state");
console.log("  prefix property: replaying any event sequence is idempotent");
console.log("  authorization-filtered reads return empty without metadata");
