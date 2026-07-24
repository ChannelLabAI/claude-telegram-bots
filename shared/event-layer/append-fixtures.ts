#!/usr/bin/env bun
import { Database } from "bun:sqlite";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { EventWriterClient } from "./src/append-client.ts";
import { AppendError, type AppendCommand, type AppendResult } from "./src/append-types.ts";

const writerScript = join(import.meta.dir, "src", "writer-process.ts");

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(`fixture assertion failed: ${message}`);
}

function command(
  ordinal: number,
  overrides: Partial<AppendCommand> = {},
): AppendCommand {
  return {
    workspace_id: "workspace-fixture",
    stream_id: "stream-shared",
    stream_kind: "channel",
    event_type: "message.posted",
    schema_version: 2,
    actor_id: "actor-fixture",
    actor_kind: "human",
    origin: "native",
    correlation_id: `correlation-${ordinal}`,
    occurred_at: new Date(1_720_000_000_000 + ordinal * 1_000).toISOString(),
    payload: { body: `fixture ${ordinal}`, ordinal },
    refs: [],
    client_id: "fixture-client",
    idempotency_key: `request-${ordinal}`,
    ...overrides,
  };
}

async function childClientMode(): Promise<void> {
  const socketPath = process.argv[3];
  const encoded = process.argv[4];
  if (!socketPath || !encoded) throw new Error("client mode requires socket and command");
  const result = await new EventWriterClient(socketPath).append(
    JSON.parse(encoded) as AppendCommand,
  );
  process.stdout.write(JSON.stringify(result));
}

type ServerProcess = ReturnType<typeof Bun.spawn>;

async function waitForHealth(endpointPath: string, processHandle: ServerProcess): Promise<void> {
  const client = new EventWriterClient(endpointPath);
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (processHandle.exitCode !== null) {
      const stderr =
        processHandle.stderr instanceof ReadableStream
          ? await new Response(processHandle.stderr).text()
          : "";
      throw new Error(`writer exited during startup (${processHandle.exitCode}): ${stderr}`);
    }
    try {
      const health = await client.health();
      if (health.status === "ok") return;
    } catch {
      await Bun.sleep(20);
    }
  }
  throw new Error("writer health timeout");
}

async function startServer(
  databasePath: string,
  endpointPath: string,
  environment: Record<string, string> = {},
): Promise<ServerProcess> {
  const processHandle = Bun.spawn(
    ["bun", "run", writerScript, "--db", databasePath, "--endpoint", endpointPath],
    {
      cwd: import.meta.dir,
      env: { ...process.env, ...environment },
      stdout: "pipe",
      stderr: "pipe",
    },
  );
  await waitForHealth(endpointPath, processHandle);
  return processHandle;
}

async function stopServer(processHandle: ServerProcess): Promise<void> {
  if (processHandle.exitCode !== null) return;
  processHandle.kill("SIGTERM");
  await processHandle.exited;
  assert(processHandle.exitCode === 0, "writer should stop cleanly");
}

async function appendFromProcess(
  endpointPath: string,
  appendCommand: AppendCommand,
): Promise<AppendResult> {
  const child = Bun.spawn(
    ["bun", "run", import.meta.path, "client", endpointPath, JSON.stringify(appendCommand)],
    { cwd: import.meta.dir, stdout: "pipe", stderr: "pipe" },
  );
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  if (exitCode !== 0) throw new Error(`append child failed (${exitCode}): ${stderr}`);
  return JSON.parse(stdout) as AppendResult;
}

function inspect(databasePath: string): Database {
  return new Database(databasePath, { readonly: true });
}

async function main(): Promise<void> {
  const fixtureRoot = mkdtempSync(join(tmpdir(), "event-writer-fixture-"));
  const databasePath = join(fixtureRoot, "events.db");
  const endpointPath = join(fixtureRoot, "writer-endpoint");
  let server: ServerProcess | undefined;
  try {
    server = await startServer(databasePath, endpointPath);
    const client = new EventWriterClient(endpointPath);

    const duplicateWriter = Bun.spawn(
      [
        "bun",
        "run",
        writerScript,
        "--db",
        databasePath,
        "--endpoint",
        join(fixtureRoot, "writer-duplicate"),
      ],
      { cwd: import.meta.dir, stdout: "pipe", stderr: "pipe" },
    );
    const duplicateExit = await duplicateWriter.exited;
    assert(duplicateExit !== 0, "a second application writer must be rejected");

    const concurrentCount = 24;
    const concurrentResults = await Promise.all(
      Array.from({ length: concurrentCount }, (_, index) =>
        appendFromProcess(endpointPath, command(index + 1)),
      ),
    );
    const concurrentStreamSeqs = concurrentResults
      .map((result) => result.event.stream_seq)
      .sort((left, right) => left - right);
    assert(
      concurrentStreamSeqs.every((value, index) => value === index + 1),
      "true concurrent same-stream appends must allocate gap-free stream_seq",
    );
    assert(
      new Set(concurrentResults.map((result) => result.event.global_seq)).size ===
        concurrentCount,
      "true concurrent appends must allocate unique global_seq",
    );
    console.log(`  concurrent: ${concurrentCount} child processes, gap-free stream_seq PASS`);

    const replayCommand = command(10_000, {
      stream_id: "stream-dedup",
      idempotency_key: "same-request-N-times",
    });
    const replayResults = await Promise.all(
      Array.from({ length: 16 }, () => appendFromProcess(endpointPath, replayCommand)),
    );
    assert(
      new Set(replayResults.map((result) => result.event.event_id)).size === 1,
      "same dedup key and hash must return one event_id",
    );
    assert(
      replayResults.filter((result) => !result.replayed).length === 1,
      "exactly one repeated request may be newly committed",
    );
    let collision = false;
    try {
      await client.append({
        ...replayCommand,
        payload: { body: "different semantic request" },
      });
    } catch (error) {
      collision =
        error instanceof AppendError && error.code === "IDEMPOTENCY_CONFLICT";
    }
    assert(collision, "dedup key reuse with another request hash must conflict");
    const scopeVariants = await Promise.all([
      client.append({
        ...replayCommand,
        actor_id: "actor-other",
        correlation_id: "scope-actor",
      }),
      client.append({
        ...replayCommand,
        client_id: "client-other",
        correlation_id: "scope-client",
      }),
      client.append({
        ...replayCommand,
        workspace_id: "workspace-other",
        correlation_id: "scope-workspace",
      }),
    ]);
    assert(
      new Set([
        replayResults[0]!.event.event_id,
        ...scopeVariants.map((result) => result.event.event_id),
      ]).size === 4,
      "workspace, actor and client must each participate in dedup scope",
    );
    console.log(
      "  idempotency: 16-process replay + hash collision + workspace/actor/client scope PASS",
    );

    const propertyWrites = 120;
    const expectedPerStream = new Map<string, number>([["stream-shared", concurrentCount]]);
    for (let index = 0; index < propertyWrites; index += 1) {
      const streamId = `property-stream-${(index * 17 + 3) % 9}`;
      const result = await client.append(
        command(20_000 + index, {
          stream_id: streamId,
          idempotency_key: `property-${index}`,
          payload: {
            ordinal: index,
            nested: { z: index % 5, a: [index, null, true] },
          },
        }),
      );
      const expected = (expectedPerStream.get(streamId) ?? 0) + 1;
      expectedPerStream.set(streamId, expected);
      assert(result.event.stream_seq === expected, "property stream sequence mismatch");
    }
    const reader = inspect(databasePath);
    const eventRows = reader
      .query("SELECT global_seq, workspace_id, stream_id, stream_seq FROM events ORDER BY global_seq")
      .all() as Array<{
      global_seq: number;
      workspace_id: string;
      stream_id: string;
      stream_seq: number;
    }>;
    assert(
      eventRows.every((row, index) => row.global_seq === index + 1),
      "committed global_seq values must be monotonic and consecutive",
    );
    for (const [streamId, expected] of expectedPerStream) {
      const sequence = eventRows
        .filter((row) => row.stream_id === streamId)
        .map((row) => row.stream_seq);
      assert(
        sequence.length === expected &&
          sequence.every((value, index) => value === index + 1),
        `property sequence mismatch for ${streamId}`,
      );
    }
    const committedBeforeCrash = eventRows.length;
    reader.close();
    console.log(`  property: ${propertyWrites} generated appends across 9 streams PASS`);

    let expectedConflict = false;
    try {
      await client.append(
        command(30_000, {
          stream_id: "stream-shared",
          expected_stream_seq: 0,
        }),
      );
    } catch (error) {
      expectedConflict =
        error instanceof AppendError &&
        error.code === "EXPECTED_STREAM_SEQ_CONFLICT";
    }
    assert(expectedConflict, "stale expected_stream_seq must fail closed");

    await stopServer(server);
    server = undefined;

    const crashSignal = join(fixtureRoot, "crash-reached");
    const crashCommand = command(40_000, {
      stream_id: "stream-crash",
      idempotency_key: "crash-window",
      payload: { crash_marker: true },
    });
    const crashingServer = await startServer(databasePath, endpointPath, {
      EVENT_WRITER_TEST_CRASH_POINT: "after-insert-before-commit",
      EVENT_WRITER_TEST_CRASH_SIGNAL: crashSignal,
    });
    let crashRequestFailed = false;
    try {
      await new EventWriterClient(endpointPath, 1_000).append(crashCommand);
    } catch {
      crashRequestFailed = true;
    }
    await crashingServer.exited;
    assert(crashRequestFailed, "killed pre-commit append must not acknowledge");
    assert(
      crashingServer.exitCode === 137 || crashingServer.signalCode === "SIGKILL",
      "fixture must terminate the writer with real SIGKILL",
    );
    assert(
      existsSync(crashSignal) &&
        readFileSync(crashSignal, "utf8").includes("after-insert-before-commit"),
      "crash fixture must prove the kill point was reached",
    );

    server = await startServer(databasePath, endpointPath);
    const recovered = inspect(databasePath);
    const integrity = recovered.query("PRAGMA integrity_check").get() as {
      integrity_check: string;
    };
    const recoveredCount = (
      recovered.query("SELECT COUNT(*) AS count FROM events").get() as { count: number }
    ).count;
    const crashEventCount = (
      recovered
        .query(
          "SELECT COUNT(*) AS count FROM events WHERE json_extract(payload_json, '$.crash_marker') = 1",
        )
        .get() as { count: number }
    ).count;
    const crashDedupCount = (
      recovered
        .query(
          "SELECT COUNT(*) AS count FROM command_dedup WHERE idempotency_key = 'crash-window'",
        )
        .get() as { count: number }
    ).count;
    const crashHeadCount = (
      recovered
        .query(
          "SELECT COUNT(*) AS count FROM stream_heads WHERE stream_id = 'stream-crash'",
        )
        .get() as { count: number }
    ).count;
    recovered.close();
    assert(integrity.integrity_check === "ok", "WAL recovery integrity_check must pass");
    assert(recoveredCount === committedBeforeCrash, "acknowledged writes must survive restart");
    assert(crashEventCount === 0, "pre-commit killed event must not be visible");
    assert(crashDedupCount === 0, "pre-commit killed dedup row must roll back");
    assert(crashHeadCount === 0, "pre-commit killed stream head must roll back");

    const retried = await new EventWriterClient(endpointPath).append(crashCommand);
    assert(!retried.replayed, "unacknowledged rolled-back command must append on retry");
    assert(retried.event.stream_seq === 1, "crash rollback must leave no stream_seq gap");
    assert(
      retried.event.global_seq === committedBeforeCrash + 1,
      "crash rollback must leave the next committed global sequence contiguous",
    );
    console.log("  crash: real SIGKILL before COMMIT + WAL restart recovery PASS");

    await stopServer(server);
    server = undefined;
    const finalReader = inspect(databasePath);
    const finalIntegrity = finalReader.query("PRAGMA integrity_check").get() as {
      integrity_check: string;
    };
    const journalMode = finalReader.query("PRAGMA journal_mode").get() as {
      journal_mode: string;
    };
    finalReader.close();
    assert(finalIntegrity.integrity_check === "ok", "final integrity_check must pass");
    assert(journalMode.journal_mode.toLowerCase() === "wal", "journal mode must remain WAL");
    console.log("append transaction fixtures: PASS");
  } finally {
    if (server && server.exitCode === null) await stopServer(server);
    rmSync(fixtureRoot, { recursive: true, force: true });
  }
}

if (process.argv[2] === "client") {
  await childClientMode();
} else {
  await main();
}
