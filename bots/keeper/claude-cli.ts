import { spawnSync } from "node:child_process";

interface ClaudePrintOptions {
  bin: string;
  prompt: string;
  model: string;
  cwd: string;
  env: NodeJS.ProcessEnv;
  timeoutMs: number;
}

/**
 * Invoke Claude's print mode without placing the prompt in argv.
 *
 * `claude -p` reads the prompt from stdin when no positional prompt follows
 * the flag. Keeping the prompt in `input` avoids the OS execve argument-size
 * limit while preserving its UTF-8 content and newlines.
 */
export function spawnClaudePrint(options: ClaudePrintOptions) {
  return spawnSync(options.bin, [
    "-p",
    "--output-format", "json",
    "--model", options.model,
    "--dangerously-skip-permissions",
  ], {
    cwd: options.cwd,
    env: options.env,
    encoding: "utf8",
    input: options.prompt,
    timeout: options.timeoutMs,
  });
}
