import { Database } from "bun:sqlite";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import { createHash, randomBytes } from "node:crypto";
import { eventEnvelopeSchema, type EventEnvelope } from "./envelope.ts";
import {
  AppendError,
  type AppendCommand,
  type AppendResult,
} from "./append-types.ts";

const ULID_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const DEFAULT_RETENTION_MS = 30 * 24 * 60 * 60 * 1_000;

type StreamHead = Readonly<{ stream_seq: number }>;
type DedupRow = Readonly<{
  request_hash: string;
  result_event_ids: string;
}>;
export type StoredEventRow = Readonly<{
  global_seq: number;
  stream_seq: number;
  event_id: string;
  workspace_id: string;
  stream_id: string;
  stream_kind: EventEnvelope["stream_kind"];
  event_type: string;
  schema_version: number;
  actor_id: string;
  actor_kind: EventEnvelope["actor_kind"];
  origin: EventEnvelope["origin"];
  external_ref_json: string | null;
  correlation_id: string;
  causation_id: string | null;
  occurred_at: string;
  ingested_at: string;
  payload_json: string;
  refs_json: string;
}>;

export type AppendAuthorizationContext = Readonly<{
  db: Database;
  command: AppendCommand;
  current_stream_seq: number;
}>;

export type AppendAuthorizationHook = (
  context: AppendAuthorizationContext,
) => void;

type StoreOptions = Readonly<{
  authorizationHook?: AppendAuthorizationHook;
  dedupRetentionMs?: number;
}>;

function encodeBase32(value: bigint, length: number): string {
  let result = "";
  for (let index = 0; index < length; index += 1) {
    result = ULID_ALPHABET[Number(value & 31n)] + result;
    value >>= 5n;
  }
  return result;
}

function generateUlid(now = Date.now()): string {
  const timestamp = encodeBase32(BigInt(now), 10);
  const randomness = randomBytes(10);
  let randomValue = 0n;
  for (const byte of randomness) randomValue = (randomValue << 8n) | BigInt(byte);
  return timestamp + encodeBase32(randomValue, 16);
}

function canonicalize(value: unknown): string {
  if (value === null || typeof value !== "object") {
    const encoded = JSON.stringify(value);
    if (encoded === undefined) {
      throw new AppendError("INVALID_COMMAND", "request contains a non-JSON value");
    }
    return encoded;
  }
  if (Array.isArray(value)) {
    return `[${value.map(canonicalize).join(",")}]`;
  }
  const entries = Object.entries(value as Record<string, unknown>)
    .filter(([, entry]) => entry !== undefined)
    .sort(([left], [right]) => left.localeCompare(right));
  return `{${entries
    .map(([key, entry]) => `${JSON.stringify(key)}:${canonicalize(entry)}`)
    .join(",")}}`;
}

export function canonicalRequestHash(command: AppendCommand): string {
  const {
    client_id: _clientId,
    idempotency_key: _idempotencyKey,
    ...semanticRequest
  } = command;
  return createHash("sha256").update(canonicalize(semanticRequest)).digest("hex");
}

function isProcessAlive(pid: number): boolean {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

class WriterProcessLock {
  readonly path: string;
  #held = false;

  constructor(databasePath: string) {
    this.path = `${resolve(databasePath)}.writer-lock`;
  }

  acquire(): void {
    mkdirSync(dirname(this.path), { recursive: true });
    for (let attempt = 0; attempt < 4; attempt += 1) {
      try {
        mkdirSync(this.path);
        writeFileSync(
          `${this.path}/owner.json`,
          JSON.stringify({ pid: process.pid, acquired_at: new Date().toISOString() }),
          { flag: "wx" },
        );
        this.#held = true;
        return;
      } catch (error) {
        const code = (error as NodeJS.ErrnoException).code;
        if (code !== "EEXIST") throw error;
        let ownerPid = -1;
        try {
          ownerPid = JSON.parse(readFileSync(`${this.path}/owner.json`, "utf8")).pid;
        } catch {
          // Fail closed instead of stealing a lock from a creator that was
          // descheduled between mkdir and owner write.
          throw new AppendError(
            "WRITER_ALREADY_RUNNING",
            "event database writer lock is initializing or malformed",
          );
        }
        if (isProcessAlive(ownerPid)) {
          throw new AppendError(
            "WRITER_ALREADY_RUNNING",
            `event database already has writer process ${ownerPid}`,
          );
        }
        const stalePath = `${this.path}.stale-${process.pid}-${Date.now()}-${attempt}`;
        try {
          renameSync(this.path, stalePath);
          rmSync(stalePath, { recursive: true, force: true });
        } catch (recoveryError) {
          if ((recoveryError as NodeJS.ErrnoException).code !== "ENOENT") {
            throw recoveryError;
          }
        }
      }
    }
    throw new AppendError("UNAVAILABLE", "could not acquire event writer process lock");
  }

  release(): void {
    if (!this.#held) return;
    let ownerPid = -1;
    try {
      ownerPid = JSON.parse(readFileSync(`${this.path}/owner.json`, "utf8")).pid;
    } catch {
      return;
    }
    if (ownerPid === process.pid) {
      rmSync(this.path, { recursive: true, force: true });
    }
    this.#held = false;
  }
}

export function parseStoredEvent(row: StoredEventRow): EventEnvelope {
  return eventEnvelopeSchema.parse({
    global_seq: row.global_seq,
    stream_seq: row.stream_seq,
    batch_position: 0,
    event_id: row.event_id,
    workspace_id: row.workspace_id,
    stream_id: row.stream_id,
    stream_kind: row.stream_kind,
    event_type: row.event_type,
    schema_version: row.schema_version,
    actor_id: row.actor_id,
    actor_kind: row.actor_kind,
    origin: row.origin,
    ...(row.external_ref_json
      ? { external_ref: JSON.parse(row.external_ref_json) }
      : {}),
    correlation_id: row.correlation_id,
    ...(row.causation_id ? { causation_id: row.causation_id } : {}),
    occurred_at: row.occurred_at,
    ingested_at: row.ingested_at,
    payload: JSON.parse(row.payload_json),
    refs: JSON.parse(row.refs_json),
  });
}

export class AppendStore {
  readonly #db: Database;
  readonly #lock: WriterProcessLock;
  readonly #authorizationHook?: AppendAuthorizationHook;
  readonly #dedupRetentionMs: number;
  #closed = false;

  constructor(databasePath: string, options: StoreOptions = {}) {
    if (databasePath.startsWith("\\\\")) {
      throw new AppendError("UNAVAILABLE", "network filesystem database paths are forbidden");
    }
    const databaseExisted = existsSync(databasePath);
    mkdirSync(dirname(resolve(databasePath)), { recursive: true });
    this.#lock = new WriterProcessLock(databasePath);
    this.#lock.acquire();
    this.#authorizationHook = options.authorizationHook;
    this.#dedupRetentionMs = options.dedupRetentionMs ?? DEFAULT_RETENTION_MS;
    try {
      const database = new Database(databasePath, { create: true });
      this.#db = database;
      try {
        this.#configure();
        this.#migrate(databaseExisted);
      } catch (error) {
        database.close();
        throw error;
      }
    } catch (error) {
      this.#lock.release();
      throw error;
    }
  }

  #configure(): void {
    const journalMode = this.#db.query("PRAGMA journal_mode = WAL").get() as {
      journal_mode: string;
    };
    this.#db.exec("PRAGMA synchronous = FULL");
    this.#db.exec("PRAGMA foreign_keys = ON");
    this.#db.exec("PRAGMA busy_timeout = 2000");
    const synchronous = this.#db.query("PRAGMA synchronous").get() as {
      synchronous: number;
    };
    const foreignKeys = this.#db.query("PRAGMA foreign_keys").get() as {
      foreign_keys: number;
    };
    if (
      journalMode.journal_mode.toLowerCase() !== "wal" ||
      synchronous.synchronous !== 2 ||
      foreignKeys.foreign_keys !== 1
    ) {
      throw new AppendError(
        "UNAVAILABLE",
        "event database durability pragma validation failed",
      );
    }
  }

  #migrate(databaseExisted: boolean): void {
    this.#db.exec(`
      CREATE TABLE IF NOT EXISTS event_store_meta (
        schema_version INTEGER NOT NULL
      );
      INSERT INTO event_store_meta(schema_version)
        SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM event_store_meta);

      CREATE TABLE IF NOT EXISTS stream_heads (
        workspace_id TEXT NOT NULL,
        stream_id TEXT NOT NULL,
        stream_seq INTEGER NOT NULL CHECK(stream_seq >= 0),
        PRIMARY KEY(workspace_id, stream_id)
      ) WITHOUT ROWID;

      CREATE TABLE IF NOT EXISTS events (
        global_seq INTEGER PRIMARY KEY AUTOINCREMENT,
        stream_seq INTEGER NOT NULL CHECK(stream_seq > 0),
        event_id TEXT NOT NULL UNIQUE,
        workspace_id TEXT NOT NULL,
        stream_id TEXT NOT NULL,
        stream_kind TEXT NOT NULL,
        event_type TEXT NOT NULL,
        schema_version INTEGER NOT NULL CHECK(schema_version > 0),
        actor_id TEXT NOT NULL,
        actor_kind TEXT NOT NULL,
        origin TEXT NOT NULL,
        external_ref_json TEXT,
        correlation_id TEXT NOT NULL,
        causation_id TEXT,
        occurred_at TEXT NOT NULL,
        ingested_at TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        refs_json TEXT NOT NULL,
        UNIQUE(workspace_id, stream_id, stream_seq)
      );

      CREATE TABLE IF NOT EXISTS command_dedup (
        workspace_id TEXT NOT NULL,
        actor_id TEXT NOT NULL,
        client_id TEXT NOT NULL,
        idempotency_key TEXT NOT NULL,
        request_hash TEXT NOT NULL,
        result_event_ids TEXT NOT NULL,
        first_seen_at TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        PRIMARY KEY(workspace_id, actor_id, client_id, idempotency_key)
      ) WITHOUT ROWID;

      CREATE TABLE IF NOT EXISTS event_store_operations (
        singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
        last_clean_checkpoint_at TEXT,
        checkpoint_duration_ms INTEGER,
        checkpoint_result TEXT
      );
    `);
    const meta = this.#db.query(
      "SELECT schema_version FROM event_store_meta",
    ).get() as { schema_version: number } | null;
    if (meta?.schema_version !== 1) {
      throw new AppendError("UNAVAILABLE", "unsupported event store schema version");
    }
    if (!databaseExisted) this.checkpoint();
  }

  checkpoint(): number {
    if (this.#closed) throw new AppendError("UNAVAILABLE", "event writer is closed");
    const started = performance.now();
    const result = this.#db.query("PRAGMA wal_checkpoint(TRUNCATE)").get() as {
      busy: number;
      log: number;
      checkpointed: number;
    };
    const durationMs = Math.ceil(performance.now() - started);
    if (result.busy !== 0) {
      this.#db.query(`
        INSERT INTO event_store_operations(
          singleton, checkpoint_duration_ms, checkpoint_result
        ) VALUES (1, ?, 'busy')
        ON CONFLICT(singleton) DO UPDATE SET
          checkpoint_duration_ms = excluded.checkpoint_duration_ms,
          checkpoint_result = excluded.checkpoint_result
      `).run(durationMs);
      throw new AppendError("UNAVAILABLE", "WAL checkpoint could not obtain a clean boundary");
    }
    this.#db.query(`
      INSERT INTO event_store_operations(
        singleton, last_clean_checkpoint_at, checkpoint_duration_ms,
        checkpoint_result
      ) VALUES (1, ?, ?, 'ok')
      ON CONFLICT(singleton) DO UPDATE SET
        last_clean_checkpoint_at = excluded.last_clean_checkpoint_at,
        checkpoint_duration_ms = excluded.checkpoint_duration_ms,
        checkpoint_result = excluded.checkpoint_result
    `).run(new Date().toISOString(), durationMs);
    return durationMs;
  }

  append(command: AppendCommand): AppendResult {
    if (this.#closed) throw new AppendError("UNAVAILABLE", "event writer is closed");
    const requestHash = canonicalRequestHash(command);
    const transaction = this.#db.transaction((): AppendResult => {
      const existing = this.#db
        .query(`
          SELECT request_hash, result_event_ids
          FROM command_dedup
          WHERE workspace_id = ? AND actor_id = ?
            AND client_id = ? AND idempotency_key = ?
        `)
        .get(
          command.workspace_id,
          command.actor_id,
          command.client_id,
          command.idempotency_key,
        ) as DedupRow | null;
      if (existing) {
        if (existing.request_hash !== requestHash) {
          throw new AppendError(
            "IDEMPOTENCY_CONFLICT",
            "idempotency key was already used with a different request hash",
          );
        }
        const [eventId] = JSON.parse(existing.result_event_ids) as string[];
        const row = this.#db
          .query("SELECT * FROM events WHERE event_id = ?")
          .get(eventId) as StoredEventRow | null;
        if (!row) {
          throw new AppendError("UNAVAILABLE", "dedup result references a missing event");
        }
        return { event: parseStoredEvent(row), replayed: true, request_hash: requestHash };
      }

      const head = this.#db
        .query(`
          SELECT stream_seq FROM stream_heads
          WHERE workspace_id = ? AND stream_id = ?
        `)
        .get(command.workspace_id, command.stream_id) as StreamHead | null;
      const currentStreamSeq = head?.stream_seq ?? 0;
      if (
        command.expected_stream_seq !== undefined &&
        command.expected_stream_seq !== currentStreamSeq
      ) {
        throw new AppendError(
          "EXPECTED_STREAM_SEQ_CONFLICT",
          `expected stream sequence ${command.expected_stream_seq}, current is ${currentStreamSeq}`,
        );
      }
      this.#authorizationHook?.({
        db: this.#db,
        command,
        current_stream_seq: currentStreamSeq,
      });

      const nextStreamSeq = currentStreamSeq + 1;
      this.#db
        .query(`
          INSERT INTO stream_heads(workspace_id, stream_id, stream_seq)
          VALUES (?, ?, ?)
          ON CONFLICT(workspace_id, stream_id)
          DO UPDATE SET stream_seq = excluded.stream_seq
        `)
        .run(command.workspace_id, command.stream_id, nextStreamSeq);

      const ingestedAt = new Date().toISOString();
      const eventId = generateUlid();
      const generated = this.#db
        .query(`
          INSERT INTO events(
            stream_seq, event_id, workspace_id, stream_id, stream_kind,
            event_type, schema_version, actor_id, actor_kind, origin,
            external_ref_json, correlation_id, causation_id, occurred_at,
            ingested_at, payload_json, refs_json
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          RETURNING global_seq
        `)
        .get(
          nextStreamSeq,
          eventId,
          command.workspace_id,
          command.stream_id,
          command.stream_kind,
          command.event_type,
          command.schema_version,
          command.actor_id,
          command.actor_kind,
          command.origin,
          command.external_ref ? JSON.stringify(command.external_ref) : null,
          command.correlation_id,
          command.causation_id ?? null,
          command.occurred_at,
          ingestedAt,
          JSON.stringify(command.payload),
          JSON.stringify(command.refs),
        ) as { global_seq: number };

      const event = eventEnvelopeSchema.parse({
        global_seq: generated.global_seq,
        stream_seq: nextStreamSeq,
        batch_position: 0,
        event_id: eventId,
        workspace_id: command.workspace_id,
        stream_id: command.stream_id,
        stream_kind: command.stream_kind,
        event_type: command.event_type,
        schema_version: command.schema_version,
        actor_id: command.actor_id,
        actor_kind: command.actor_kind,
        origin: command.origin,
        ...(command.external_ref ? { external_ref: command.external_ref } : {}),
        correlation_id: command.correlation_id,
        ...(command.causation_id ? { causation_id: command.causation_id } : {}),
        occurred_at: command.occurred_at,
        ingested_at: ingestedAt,
        payload: command.payload,
        refs: command.refs,
      });

      const firstSeen = new Date();
      this.#db
        .query(`
          INSERT INTO command_dedup(
            workspace_id, actor_id, client_id, idempotency_key,
            request_hash, result_event_ids, first_seen_at, expires_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        `)
        .run(
          command.workspace_id,
          command.actor_id,
          command.client_id,
          command.idempotency_key,
          requestHash,
          JSON.stringify([eventId]),
          firstSeen.toISOString(),
          new Date(firstSeen.getTime() + this.#dedupRetentionMs).toISOString(),
        );

      if (
        process.env.EVENT_WRITER_TEST_CRASH_POINT === "after-insert-before-commit" &&
        (command.payload as Record<string, unknown> | null)?.crash_marker === true
      ) {
        const signalPath = process.env.EVENT_WRITER_TEST_CRASH_SIGNAL;
        if (signalPath) writeFileSync(signalPath, "after-insert-before-commit\n");
        process.kill(process.pid, "SIGKILL");
      }
      return { event, replayed: false, request_hash: requestHash };
    });

    try {
      // bun:sqlite transaction() issues COMMIT before this call returns. The IPC
      // layer serializes the success response only after this boundary.
      return transaction.immediate();
    } catch (error) {
      if (error instanceof AppendError) throw error;
      throw new AppendError("INVALID_COMMAND", "append transaction failed", error);
    }
  }

  close(recordCheckpoint = true): void {
    if (this.#closed) return;
    let checkpointError: unknown;
    try {
      if (recordCheckpoint) this.checkpoint();
    } catch (error) {
      checkpointError = error;
    }
    this.#closed = true;
    this.#db.close();
    this.#lock.release();
    if (checkpointError) throw checkpointError;
  }
}
