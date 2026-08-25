import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { extractOntology } from "./keeper-batch";
import type { BatchAction } from "./keeper-batch";

const fixtureDirs: string[] = [];
const NOW = new Date("2026-08-26T01:00:00+08:00");

afterEach(async () => {
  await Promise.all(fixtureDirs.splice(0).map(path =>
    rm(path, { recursive: true, force: true })
  ));
});

async function fixture(records: Array<{ slug: string; content: string }>) {
  const root = await mkdtemp(join(tmpdir(), "keeper-record-selection-"));
  fixtureDirs.push(root);
  const seabedPath = join(root, "seabed", "chats.clsc.md");
  const oceanChatsRoot = join(root, "ocean", "chats");
  await mkdir(join(root, "seabed"), { recursive: true });
  await mkdir(oceanChatsRoot, { recursive: true });
  await writeFile(
    seabedPath,
    records.map(record =>
      `[${record.slug}|fixture|decision|"${record.content}"|5|neutral|tg]`
    ).join("\n") + "\n",
    "utf8",
  );
  return { seabedPath, oceanChatsRoot };
}

function itemFor(slug: string) {
  return {
    tag: "decision",
    text: `fixture extracted ${slug}`,
    source_slug: slug,
    ts: "2026-08-25",
  };
}

describe("keeper ontology record selection", () => {
  test("known unprocessed seabed records are selected and extracted", async () => {
    const slugs = [
      "tg-20260825-1050312492-21110",
      "tg-20260825-1050312492-21115",
      "tg-20260825-1050312492-21122",
    ];
    const paths = await fixture(slugs.map(slug => ({ slug, content: `decision ${slug}` })));
    const actions: BatchAction[] = [];

    const result = await extractOntology(
      paths.seabedPath,
      paths.oceanChatsRoot,
      new Set(),
      actions,
      undefined,
      {
        now: NOW,
        callModel: async () => JSON.stringify(slugs.map(itemFor)),
      },
    );

    expect(result.items.map(item => item.source_slug)).toEqual(slugs);
    expect(result.newSlugs).toEqual(slugs);
    expect(actions).toContainEqual({
      action: "ontology_record_selection",
      result: "ok",
      detail: "recent=3 processed_filtered=0 selected=3",
    });
    expect(actions).toContainEqual({
      action: "ontology_extract",
      result: "ok",
      detail: "3 items from 3 records",
    });
  });

  test("processed records and a genuinely empty date window have distinct logs", async () => {
    const processedSlug = "tg-20260825-1050312492-30001";
    const processedPaths = await fixture([
      { slug: processedSlug, content: "already extracted" },
    ]);
    const processedActions: BatchAction[] = [];
    const processed = await extractOntology(
      processedPaths.seabedPath,
      processedPaths.oceanChatsRoot,
      new Set([processedSlug]),
      processedActions,
      undefined,
      { now: NOW, callModel: async () => { throw new Error("must not be called"); } },
    );

    expect(processed.items).toEqual([]);
    expect(processedActions).toContainEqual({
      action: "ontology_record_selection",
      result: "all_processed",
      detail: "recent=1 processed_filtered=1 selected=0",
    });
    expect(processedActions).toContainEqual({
      action: "ontology_extract",
      result: "skip",
      detail: "all recent records already processed; recent=1 processed_filtered=1 selected=0",
    });

    const emptyPaths = await fixture([
      { slug: "tg-20260701-1050312492-30002", content: "outside the seven-day window" },
    ]);
    const emptyActions: BatchAction[] = [];
    await extractOntology(
      emptyPaths.seabedPath,
      emptyPaths.oceanChatsRoot,
      new Set(),
      emptyActions,
      undefined,
      { now: NOW, callModel: async () => { throw new Error("must not be called"); } },
    );

    expect(emptyActions).toContainEqual({
      action: "ontology_record_selection",
      result: "empty",
      detail: "recent=0 processed_filtered=0 selected=0",
    });
    expect(emptyActions).toContainEqual({
      action: "ontology_extract",
      result: "skip",
      detail: "no recent records; recent=0 processed_filtered=0 selected=0",
    });
  });

  test("isolated full batch keeps processed records skipped and reports its action summary", async () => {
    const root = await mkdtemp(join(tmpdir(), "keeper-full-batch-"));
    fixtureDirs.push(root);
    const agentHome = join(root, "bots", "keeper");
    const vaultDir = join(root, "vault");
    const inboxDir = join(root, "state", "anya", "inbox", "messages");
    const relayDir = join(root, "relay");
    const slug = "tg-20260825-1050312492-40001";
    const seabedPath = join(root, "seabed", "chats.clsc.md");
    const manifestPath = join(agentHome, "AGENT_MANIFEST.json");

    await Promise.all([
      mkdir(join(agentHome, "logs"), { recursive: true }),
      mkdir(join(agentHome, "memory"), { recursive: true }),
      mkdir(join(root, "seabed"), { recursive: true }),
      mkdir(inboxDir, { recursive: true }),
      mkdir(relayDir, { recursive: true }),
      ...["珍珠卡", "技術海圖", "企劃", "_drafts", "業務流", "_index", "Reports"]
        .map(dir => mkdir(join(vaultDir, dir), { recursive: true })),
    ]);
    await writeFile(
      manifestPath,
      JSON.stringify({
        AGENT_HOME: agentHome,
        VAULT_DIR: vaultDir,
        USER_INBOX_DIR: join(root, "state"),
      }),
      "utf8",
    );
    await writeFile(
      seabedPath,
      `[${slug}|fixture|decision|"already extracted"|5|neutral|tg]\n`,
      "utf8",
    );
    await writeFile(
      join(agentHome, "memory", "processed-slugs.json"),
      JSON.stringify([slug]),
      "utf8",
    );
    const seabedBefore = await readFile(seabedPath, "utf8");

    const run = spawnSync("bun", [
      join(import.meta.dir, "keeper-batch.ts"),
      "--manifest", manifestPath,
      "--ingest-trigger",
    ], {
      cwd: join(import.meta.dir, "..", ".."),
      encoding: "utf8",
      timeout: 60_000,
      env: {
        ...process.env,
        KEEPER_NOW_ISO: NOW.toISOString(),
        DIANA_LLM_FORCE_FAIL: "1",
        DIANA_LLM_FAILURE_STATE: join(agentHome, "memory", "llm-failures.json"),
        FATQ_RELAY_DIR: relayDir,
      },
    });

    expect(run.status).toBe(0);
    expect(run.stderr).toContain("Step 1: found 0 inbox items");
    expect(run.stderr).toContain("Step 4:");
    expect(run.stderr).toContain("=== Batch complete ===");
    expect(await readFile(seabedPath, "utf8")).toBe(seabedBefore);

    const logName = (await readdir(join(agentHome, "logs")))
      .find(name => name.endsWith("-batch.json"));
    expect(logName).toBeDefined();
    const batch = JSON.parse(await readFile(join(agentHome, "logs", logName!), "utf8")) as {
      inbox_scanned: number;
      items_processed: number;
      conflicts_detected: number;
      ontology_items: number;
      ontology_failed_records: number;
      actions: BatchAction[];
    };
    const actionSummary = batch.actions.map(({ action, result, detail }) => ({ action, result, detail }));
    console.log("FULL_BATCH_ACTIONS", JSON.stringify(actionSummary));

    expect(batch).toMatchObject({
      inbox_scanned: 0,
      items_processed: 0,
      ontology_items: 0,
      ontology_failed_records: 0,
    });
    expect(actionSummary).toContainEqual({
      action: "ontology_record_selection",
      result: "all_processed",
      detail: "recent=1 processed_filtered=1 selected=0",
    });
    expect(actionSummary).toContainEqual({
      action: "ontology_extract",
      result: "skip",
      detail: "all recent records already processed; recent=1 processed_filtered=1 selected=0",
    });
  });
});
