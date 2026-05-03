#!/usr/bin/env bun
// trigger-batch.ts — Write diana:batch relay signal for cron to invoke.
// Called by crontab: 0 15 * * * bun run trigger-batch.ts
// relay-listener.ts picks up the signal and runs keeper-batch.ts.

import { writeFile, mkdir } from "node:fs/promises";
import { join } from "node:path";

const RELAY_DIR = join(import.meta.dir, "../../relay");

async function main(): Promise<void> {
  await mkdir(RELAY_DIR, { recursive: true });

  const signal = {
    from_bot: "system",
    chat_id: "diana",
    text: "diana:batch 夜間批次觸發",
    message_id: 0,
    ts: new Date().toISOString(),
  };

  const filename = `${Date.now()}-diana-nightly.json`;
  const destPath = join(RELAY_DIR, filename);

  await writeFile(destPath, JSON.stringify(signal, null, 2) + "\n", "utf8");
  process.stdout.write(`[trigger-batch ${signal.ts}] signal written: ${filename}\n`);
}

main().catch(err => {
  process.stderr.write(`FATAL: ${String(err)}\n`);
  process.exit(1);
});
