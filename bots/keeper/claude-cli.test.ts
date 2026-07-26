import { afterEach, describe, expect, test } from "bun:test";
import {
  chmod,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { spawnClaudePrint } from "./claude-cli";

const fixtureDirs: string[] = [];

afterEach(async () => {
  await Promise.all(fixtureDirs.splice(0).map(path =>
    rm(path, { recursive: true, force: true })
  ));
});

async function runFixture(prompt: string) {
  const fixtureDir = await mkdtemp(join(tmpdir(), "keeper-claude-stdin-"));
  fixtureDirs.push(fixtureDir);

  const expectedPath = join(fixtureDir, "expected-prompt.txt");
  const receivedPath = join(fixtureDir, "received-prompt.txt");
  const argvPath = join(fixtureDir, "argv.json");
  const fakeClaudePath = join(fixtureDir, "fake-claude");

  await writeFile(expectedPath, prompt, "utf8");
  await writeFile(fakeClaudePath, `#!/usr/bin/env bun
import { readFileSync, writeFileSync } from "node:fs";
const input = readFileSync(0);
writeFileSync(process.env.FIXTURE_RECEIVED_PATH!, input);
writeFileSync(process.env.FIXTURE_ARGV_PATH!, JSON.stringify(process.argv.slice(2)));
const expected = readFileSync(process.env.FIXTURE_EXPECTED_PATH!);
if (!input.equals(expected)) {
  process.stderr.write("stdin prompt mismatch");
  process.exit(41);
}
process.stdout.write(JSON.stringify({ result: "fixture-ok" }));
`, "utf8");
  await chmod(fakeClaudePath, 0o755);

  const result = spawnClaudePrint({
    bin: fakeClaudePath,
    prompt,
    model: "fixture-model",
    cwd: fixtureDir,
    env: {
      ...process.env,
      FIXTURE_EXPECTED_PATH: expectedPath,
      FIXTURE_RECEIVED_PATH: receivedPath,
      FIXTURE_ARGV_PATH: argvPath,
    },
    timeoutMs: 30_000,
  });

  return {
    result,
    expected: await readFile(expectedPath),
    received: await readFile(receivedPath),
    argv: JSON.parse(await readFile(argvPath, "utf8")) as string[],
  };
}

describe("spawnClaudePrint stdin transport", () => {
  test("normal prompt is byte-exact and absent from argv", async () => {
    const prompt = "system\n\n使用者內容\ntrailing newline\n";
    const fixture = await runFixture(prompt);

    expect(fixture.result.status).toBe(0);
    expect(fixture.result.error).toBeUndefined();
    expect(fixture.result.stdout).toBe('{"result":"fixture-ok"}');
    expect(fixture.received.equals(fixture.expected)).toBe(true);
    expect(fixture.argv).toEqual([
      "-p",
      "--output-format", "json",
      "--model", "fixture-model",
      "--dangerously-skip-permissions",
    ]);
    expect(fixture.argv).not.toContain(prompt);
  });

  test("oversized UTF-8 prompt (>256 KiB) succeeds without argv transport", async () => {
    const prompt = `system\n\n${"孤兒 patch line 🧪\n".repeat(20_000)}`;
    expect(Buffer.byteLength(prompt, "utf8")).toBeGreaterThan(256 * 1024);

    const fixture = await runFixture(prompt);

    expect(fixture.result.status).toBe(0);
    expect(fixture.result.error).toBeUndefined();
    expect(fixture.received.equals(fixture.expected)).toBe(true);
    expect(fixture.argv.every(arg => !arg.includes("孤兒 patch line"))).toBe(true);
  });
});
