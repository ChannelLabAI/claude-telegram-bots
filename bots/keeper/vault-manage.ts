#!/usr/bin/env bun
// vault-manage.ts — Diana vault management entry point
// Triggered via: relay signal diana:vault-manage → relay-listener → this script
// Manual: bun run /home/oldrabbit/.claude-bots/bots/keeper/vault-manage.ts

import { existsSync } from "node:fs";
import { isAbsolute } from "node:path";
import { runCodeGrapher } from "./vault-code-grapher.ts";
import { runOrphanScanner } from "./vault-orphan-scanner.ts";

const VAULT_ROOT =
  process.env.VAULT_ROOT ??
  "/home/oldrabbit/Documents/Obsidian Vault/Ocean/";

async function main(): Promise<void> {
  console.error("[vault-manage] starting");
  console.error(`[vault-manage] VAULT_ROOT: ${VAULT_ROOT}`);

  if (!isAbsolute(VAULT_ROOT)) {
    console.error(`[vault-manage] FATAL: VAULT_ROOT must be an absolute path: ${VAULT_ROOT}`);
    process.exit(1);
  }

  if (!existsSync(VAULT_ROOT)) {
    console.error(`[vault-manage] FATAL: VAULT_ROOT not found: ${VAULT_ROOT}`);
    process.exit(1);
  }

  // Grapher first: builds _index.md so Scanner can link CODE orphans
  // Scans entire vault for .ts/.py/.sh files
  console.error("[vault-manage] step 1/2: running code grapher");
  const grapherResult = await runCodeGrapher(VAULT_ROOT);
  console.error(
    `[vault-manage] grapher done: ${grapherResult.indexesCreated} created, ${grapherResult.indexesUpdated} updated`
  );

  // Scanner second: uses _index.md built by grapher for CODE orphan linking
  console.error("[vault-manage] step 2/2: running orphan scanner");
  const scannerResult = await runOrphanScanner(VAULT_ROOT);
  console.error(
    `[vault-manage] scanner done: ${scannerResult.orphanCount} orphans, ${scannerResult.stagedFiles.length} staged`
  );

  console.error("[vault-manage] done");
}

main().catch((err) => {
  console.error("[vault-manage] FATAL:", String(err));
  process.exit(1);
});
