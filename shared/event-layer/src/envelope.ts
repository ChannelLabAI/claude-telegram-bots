import { z } from "zod";

const ulidPattern = /^[0-9A-HJKMNP-TV-Z]{26}$/;
const namespacedVerbPattern = /^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+$/;
const opaqueIdentityPattern = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;

export const jsonValueSchema: z.ZodType<unknown> = z.lazy(() =>
  z.union([
    z.string(),
    z.number().finite(),
    z.boolean(),
    z.null(),
    z.array(jsonValueSchema),
    z.record(z.string(), jsonValueSchema),
  ]),
);

export const externalRefSchema = z
  .object({
    provider: z.string().min(1),
    tenant_id: z.string().min(1),
    object_type: z.string().min(1),
    object_id: z.string().min(1),
  })
  .strict();

export const typedReferenceSchema = z
  .object({
    kind: z.string().min(1),
    id: z.string().min(1),
    relation: z.string().min(1),
  })
  .strict();

export const eventEnvelopeSchema = z
  .object({
    global_seq: z.number().int().positive(),
    stream_seq: z.number().int().positive(),
    batch_position: z.number().int().nonnegative(),
    event_id: z.string().regex(ulidPattern, "event_id must be a ULID identity"),
    workspace_id: z.string().regex(opaqueIdentityPattern, "invalid workspace identity"),
    stream_id: z.string().regex(opaqueIdentityPattern, "invalid opaque stream identity"),
    stream_kind: z.enum(["channel", "dm", "system", "knowledge"]),
    event_type: z.string().regex(namespacedVerbPattern, "event_type must be a namespaced verb"),
    schema_version: z.number().int().positive(),
    actor_id: z.string().regex(opaqueIdentityPattern, "invalid actor identity"),
    actor_kind: z.enum(["human", "bot", "system"]),
    origin: z.enum(["native", "telegram", "lark", "mattermost", "migration"]),
    external_ref: externalRefSchema.optional(),
    correlation_id: z.string().min(1),
    causation_id: z.string().min(1).optional(),
    occurred_at: z.iso.datetime({ offset: true }),
    ingested_at: z.iso.datetime({ offset: true }),
    payload: jsonValueSchema,
    refs: z.array(typedReferenceSchema),
  })
  .strict();

export type EventEnvelope = z.infer<typeof eventEnvelopeSchema>;

export function createEventEnvelopeSchema<TPayload extends z.ZodType>(
  payloadSchema: TPayload,
) {
  return eventEnvelopeSchema.extend({ payload: payloadSchema }).strict();
}
