import { z } from "zod";
import {
  ContractError,
  EventSchemaRegistry,
  eventEnvelopeSchema,
  type SchemaDefinition,
} from "./src/index.ts";

const fixtureRoot = `${import.meta.dir}/golden/message.posted`;

async function fixture(path: string): Promise<unknown> {
  return Bun.file(`${fixtureRoot}/${path}`).json();
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function expectContractError(
  label: string,
  code: ContractError["code"],
  operation: () => unknown,
): void {
  try {
    operation();
  } catch (error) {
    assert(error instanceof ContractError, `${label}: expected ContractError`);
    assert(error.code === code, `${label}: expected ${code}, got ${error.code}`);
    return;
  }
  throw new Error(`${label}: expected rejection ${code}`);
}

const payloadV1 = z
  .object({
    message_id: z.string().min(1),
    body: z.string(),
  })
  .strict();

const payloadV2 = z
  .object({
    message_id: z.string().min(1),
    text: z.string(),
    format: z.enum(["plain", "markdown"]),
  })
  .strict();

const definition: SchemaDefinition = {
  eventType: "message.posted",
  currentVersion: 2,
  supportedVersions: { min: 1, max: 2 },
  payloadSchemas: new Map<number, z.ZodType>([
    [1, payloadV1],
    [2, payloadV2],
  ]),
  upcasters: new Map([
    [
      1,
      (payload) => {
        const old = payloadV1.parse(payload);
        return { message_id: old.message_id, text: old.body, format: "plain" };
      },
    ],
  ]),
  deprecatedVersions: new Map([
    [
      1,
      {
        announcedAt: "2026-07-01T00:00:00Z",
        removeAfter: "2026-10-01T00:00:00Z",
      },
    ],
  ]),
};

const registry = new EventSchemaRegistry();
registry.register(definition);
registry.registerConsumer({
  consumerId: "message-projection",
  eventType: "message.posted",
  supportedVersions: { min: 1, max: 2 },
});

const validV1 = await fixture("v1/valid.json");
const validV2 = await fixture("v2/valid.json");
const missingVersion = await fixture("v1/missing-schema-version.json");
const invalidStream = await fixture("v1/invalid-stream-identity.json");
const commandDedupFields = await fixture("v2/unknown-command-dedup-fields.json");

const v1Result = registry.parse(validV1);
assert(v1Result.originalVersion === 1, "v1 original version was not preserved");
assert(
  JSON.stringify(v1Result.currentPayload) ===
    JSON.stringify({ message_id: "message:001", text: "hello", format: "plain" }),
  "v1 -> v2 upcaster produced unexpected payload",
);

const upgradedEnvelope = {
  ...(validV1 as Record<string, unknown>),
  schema_version: 2,
  payload: v1Result.currentPayload,
};
registry.validateForWrite(upgradedEnvelope);
registry.validateForWrite(validV2);

expectContractError("missing schema_version", "INVALID_ENVELOPE", () =>
  registry.parse(missingVersion),
);
expectContractError("invalid stream identity", "INVALID_ENVELOPE", () =>
  registry.parse(invalidStream),
);
expectContractError("command dedup fields are outside B1 envelope", "INVALID_ENVELOPE", () =>
  registry.parse(commandDedupFields),
);
expectContractError("old-version producer write", "OLD_VERSION_WRITE", () =>
  registry.validateForWrite(validV1),
);
expectContractError("unsupported consumer range", "UNSUPPORTED_VERSION", () =>
  registry.parse(validV1, { min: 2, max: 2 }),
);
expectContractError("duplicate registry identity", "DUPLICATE_SCHEMA", () =>
  registry.register(definition),
);

registry.deprecateEventType("message.posted", {
  announcedAt: "2026-07-01T00:00:00Z",
  removeAfter: "2026-10-01T00:00:00Z",
  replayVerifiedConsumers: new Set(),
});
expectContractError("open deprecation window", "DEPRECATION_BLOCKED", () =>
  registry.assertEventTypeRemovable("message.posted", "2026-09-01T00:00:00Z"),
);
expectContractError("consumer replay not verified", "DEPRECATION_BLOCKED", () =>
  registry.assertEventTypeRemovable("message.posted", "2026-11-01T00:00:00Z"),
);

const removableRegistry = new EventSchemaRegistry();
removableRegistry.register(definition);
removableRegistry.registerConsumer({
  consumerId: "message-projection",
  eventType: "message.posted",
  supportedVersions: { min: 1, max: 2 },
});
removableRegistry.deprecateEventType("message.posted", {
  announcedAt: "2026-07-01T00:00:00Z",
  removeAfter: "2026-10-01T00:00:00Z",
  replayVerifiedConsumers: new Set(["message-projection"]),
});
removableRegistry.assertEventTypeRemovable(
  "message.posted",
  "2026-11-01T00:00:00Z",
);

const requiredEnvelopeFields = [
  "global_seq",
  "stream_seq",
  "batch_position",
  "event_id",
  "workspace_id",
  "stream_id",
  "stream_kind",
  "event_type",
  "schema_version",
  "actor_id",
  "actor_kind",
  "origin",
  "correlation_id",
  "occurred_at",
  "ingested_at",
  "payload",
  "refs",
] as const;

for (const field of requiredEnvelopeFields) {
  const withoutField = { ...(validV2 as Record<string, unknown>) };
  delete withoutField[field];
  assert(
    !eventEnvelopeSchema.safeParse(withoutField).success,
    `required envelope field ${field} is not enforced`,
  );
}
for (const optionalField of ["external_ref", "causation_id"] as const) {
  assert(
    optionalField in (validV2 as Record<string, unknown>),
    `golden corpus does not cover optional envelope field ${optionalField}`,
  );
}

console.log("event-contract lint: PASS");
console.log("  envelope fields: ADR-003 §§1–2 covered");
console.log("  schema versions: v1/v2 positive + negative corpus covered");
console.log("  upcaster: v1 -> v2 round-trip covered");
console.log("  registry: ranges, current-write, duplicate key, consumer fail-closed covered");
console.log("  deprecation: window + registered-consumer replay gate covered");
