import { z } from "zod";
import {
  createEventEnvelopeSchema,
  eventEnvelopeSchema,
  type EventEnvelope,
} from "./envelope.ts";

export type VersionRange = Readonly<{ min: number; max: number }>;
export type Upcaster = (payload: unknown) => unknown;

export type SchemaDefinition = Readonly<{
  eventType: string;
  currentVersion: number;
  supportedVersions: VersionRange;
  payloadSchemas: ReadonlyMap<number, z.ZodType>;
  upcasters: ReadonlyMap<number, Upcaster>;
  deprecatedVersions?: ReadonlyMap<
    number,
    Readonly<{ announcedAt: string; removeAfter: string }>
  >;
}>;

export type ConsumerRegistration = Readonly<{
  consumerId: string;
  eventType: string;
  supportedVersions: VersionRange;
}>;

export class ContractError extends Error {
  constructor(
    readonly code:
      | "DUPLICATE_SCHEMA"
      | "INVALID_REGISTRY"
      | "UNSUPPORTED_VERSION"
      | "INVALID_ENVELOPE"
      | "INVALID_PAYLOAD"
      | "OLD_VERSION_WRITE"
      | "MISSING_UPCASTER"
      | "DEPRECATION_BLOCKED",
    message: string,
    readonly cause?: unknown,
  ) {
    super(message);
    this.name = "ContractError";
  }
}

function isPositiveInteger(value: number): boolean {
  return Number.isInteger(value) && value > 0;
}

function assertRange(range: VersionRange, label: string): void {
  if (
    !isPositiveInteger(range.min) ||
    !isPositiveInteger(range.max) ||
    range.min > range.max
  ) {
    throw new ContractError("INVALID_REGISTRY", `${label} is not a positive version range`);
  }
}

function parseInstant(value: string, label: string): number {
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) {
    throw new ContractError("INVALID_REGISTRY", `${label} must be an ISO timestamp`);
  }
  return parsed;
}

export class EventSchemaRegistry {
  readonly #definitions = new Map<string, SchemaDefinition>();
  readonly #schemaKeys = new Set<string>();
  readonly #consumers = new Map<string, ConsumerRegistration>();
  readonly #eventDeprecations = new Map<
    string,
    Readonly<{
      announcedAt: string;
      removeAfter: string;
      replayVerifiedConsumers: ReadonlySet<string>;
    }>
  >();

  register(definition: SchemaDefinition): void {
    if (this.#definitions.has(definition.eventType)) {
      throw new ContractError(
        "DUPLICATE_SCHEMA",
        `event type ${definition.eventType} is already registered`,
      );
    }
    assertRange(definition.supportedVersions, `${definition.eventType} supportedVersions`);
    if (
      definition.currentVersion < definition.supportedVersions.min ||
      definition.currentVersion > definition.supportedVersions.max
    ) {
      throw new ContractError(
        "INVALID_REGISTRY",
        `${definition.eventType} currentVersion is outside its supported range`,
      );
    }

    for (
      let version = definition.supportedVersions.min;
      version <= definition.supportedVersions.max;
      version += 1
    ) {
      const key = `${definition.eventType}@${version}`;
      if (this.#schemaKeys.has(key)) {
        throw new ContractError("DUPLICATE_SCHEMA", `duplicate registry key ${key}`);
      }
      if (!definition.payloadSchemas.has(version)) {
        throw new ContractError("INVALID_REGISTRY", `missing payload schema ${key}`);
      }
      if (version < definition.currentVersion && !definition.upcasters.has(version)) {
        throw new ContractError("MISSING_UPCASTER", `missing upcaster ${key} -> ${version + 1}`);
      }
    }

    for (const [version, policy] of definition.deprecatedVersions ?? []) {
      if (
        version < definition.supportedVersions.min ||
        version > definition.supportedVersions.max
      ) {
        throw new ContractError(
          "INVALID_REGISTRY",
          `deprecated version ${definition.eventType}@${version} is outside supported range`,
        );
      }
      if (parseInstant(policy.removeAfter, "removeAfter") <= parseInstant(policy.announcedAt, "announcedAt")) {
        throw new ContractError(
          "INVALID_REGISTRY",
          `deprecation window for ${definition.eventType}@${version} must be positive`,
        );
      }
    }

    this.#definitions.set(definition.eventType, definition);
    for (const version of definition.payloadSchemas.keys()) {
      this.#schemaKeys.add(`${definition.eventType}@${version}`);
    }
  }

  registerConsumer(registration: ConsumerRegistration): void {
    assertRange(registration.supportedVersions, `${registration.consumerId} supportedVersions`);
    const key = `${registration.consumerId}:${registration.eventType}`;
    if (this.#consumers.has(key)) {
      throw new ContractError("INVALID_REGISTRY", `consumer registration ${key} already exists`);
    }
    this.#consumers.set(key, registration);
  }

  parse(
    input: unknown,
    consumerRange?: VersionRange,
  ): { envelope: EventEnvelope; currentPayload: unknown; originalVersion: number } {
    const envelopeResult = eventEnvelopeSchema.safeParse(input);
    if (!envelopeResult.success) {
      throw new ContractError(
        "INVALID_ENVELOPE",
        "event envelope validation failed",
        envelopeResult.error,
      );
    }
    const envelope = envelopeResult.data;
    const definition = this.#definitions.get(envelope.event_type);
    if (!definition) {
      throw new ContractError(
        "UNSUPPORTED_VERSION",
        `unregistered event type ${envelope.event_type}`,
      );
    }
    const version = envelope.schema_version;
    if (
      version < definition.supportedVersions.min ||
      version > definition.supportedVersions.max
    ) {
      throw new ContractError(
        "UNSUPPORTED_VERSION",
        `${envelope.event_type}@${version} is outside registry support`,
      );
    }
    if (
      consumerRange &&
      (version < consumerRange.min || version > consumerRange.max)
    ) {
      throw new ContractError(
        "UNSUPPORTED_VERSION",
        `${envelope.event_type}@${version} is outside consumer support`,
      );
    }

    let payload: unknown = this.#parsePayload(definition, version, envelope.payload);
    for (let cursor = version; cursor < definition.currentVersion; cursor += 1) {
      const upcaster = definition.upcasters.get(cursor);
      if (!upcaster) {
        throw new ContractError(
          "MISSING_UPCASTER",
          `missing upcaster ${definition.eventType}@${cursor} -> ${cursor + 1}`,
        );
      }
      payload = this.#parsePayload(definition, cursor + 1, upcaster(payload));
    }
    return { envelope, currentPayload: payload, originalVersion: version };
  }

  validateForWrite(input: unknown): EventEnvelope {
    const baseResult = eventEnvelopeSchema.safeParse(input);
    if (!baseResult.success) {
      throw new ContractError(
        "INVALID_ENVELOPE",
        "event envelope validation failed",
        baseResult.error,
      );
    }
    const definition = this.#definitions.get(baseResult.data.event_type);
    if (!definition) {
      throw new ContractError(
        "UNSUPPORTED_VERSION",
        `unregistered event type ${baseResult.data.event_type}`,
      );
    }
    if (baseResult.data.schema_version !== definition.currentVersion) {
      throw new ContractError(
        "OLD_VERSION_WRITE",
        `producers must write current ${definition.eventType}@${definition.currentVersion}`,
      );
    }
    const schema = createEventEnvelopeSchema(
      definition.payloadSchemas.get(definition.currentVersion)!,
    );
    const result = schema.safeParse(input);
    if (!result.success) {
      throw new ContractError("INVALID_PAYLOAD", "current payload validation failed", result.error);
    }
    return result.data;
  }

  deprecateEventType(
    eventType: string,
    policy: Readonly<{
      announcedAt: string;
      removeAfter: string;
      replayVerifiedConsumers: ReadonlySet<string>;
    }>,
  ): void {
    if (!this.#definitions.has(eventType)) {
      throw new ContractError("INVALID_REGISTRY", `unknown event type ${eventType}`);
    }
    if (parseInstant(policy.removeAfter, "removeAfter") <= parseInstant(policy.announcedAt, "announcedAt")) {
      throw new ContractError("INVALID_REGISTRY", "event removal requires a positive deprecation window");
    }
    this.#eventDeprecations.set(eventType, policy);
  }

  assertEventTypeRemovable(eventType: string, now: string): void {
    const policy = this.#eventDeprecations.get(eventType);
    if (!policy || parseInstant(now, "now") < parseInstant(policy.removeAfter, "removeAfter")) {
      throw new ContractError("DEPRECATION_BLOCKED", `${eventType} deprecation window is open`);
    }
    const missing = [...this.#consumers.values()]
      .filter((consumer) => consumer.eventType === eventType)
      .map((consumer) => consumer.consumerId)
      .filter((consumerId) => !policy.replayVerifiedConsumers.has(consumerId));
    if (missing.length > 0) {
      throw new ContractError(
        "DEPRECATION_BLOCKED",
        `${eventType} compatibility replay missing: ${missing.join(", ")}`,
      );
    }
  }

  #parsePayload(
    definition: SchemaDefinition,
    version: number,
    payload: unknown,
  ): unknown {
    const result = definition.payloadSchemas.get(version)!.safeParse(payload);
    if (!result.success) {
      throw new ContractError(
        "INVALID_PAYLOAD",
        `${definition.eventType}@${version} payload validation failed`,
        result.error,
      );
    }
    return result.data;
  }
}
