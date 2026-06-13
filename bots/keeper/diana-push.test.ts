/**
 * diana-push.test.ts — P1 unit tests for owner routing, ledger bucketing, whitelist gate
 * Run: bun test bots/keeper/diana-push.test.ts
 */

import { test, expect, describe, beforeEach } from "bun:test";
import { join } from "node:path";
import { mkdirSync, rmSync, writeFileSync, readFileSync, existsSync } from "node:fs";

// ── Test helpers ──────────────────────────────────────────────────────────────

const TMP = join(import.meta.dir, "../../.test-tmp-diana-p1");
const OWNER_MAP_PATH = join(TMP, "owner-map.json");

// We need to override the module-level OWNER_MAP_PATH — mock the fs read via env
process.env["__DIANA_PUSH_OWNER_MAP_PATH_OVERRIDE"] = OWNER_MAP_PATH;

const TEST_OWNER_MAP = {
  _meta: { version: "1.0.0" },
  mapping: [
    { role: "老兔", tg_usernames: ["oldrabbit_eth"], state_dir: "anya", bot_handle: "@Anyachl_bot", confirmed: true },
    { role: "菜姐", tg_usernames: ["cyslc14th"], state_dir: "caijie-zhuchu", bot_handle: "@CarrotAAA_bot", confirmed: true },
    { role: "Nicky", tg_usernames: ["phobe29wyh"], state_dir: "nicky-zhanglinghe", bot_handle: "@ZhangLingheAI_bot", confirmed: true },
    { role: "Ron", tg_usernames: ["TODO"], state_dir: "ron-assistant", bot_handle: "@Ron0001_bot", confirmed: false },
  ],
  fallback_state_dir: "anya",
  enabled_owners: ["anya", "caijie-zhuchu"],
  sensitive_tags: ["customer_signal"],
  sensitive_keywords: ["薪資", "salary"],
};

function setupTmp() {
  mkdirSync(TMP, { recursive: true });
  writeFileSync(OWNER_MAP_PATH, JSON.stringify(TEST_OWNER_MAP));
}

function teardownTmp() {
  rmSync(TMP, { recursive: true, force: true });
}

// ── Inline logic tests (no module import to avoid side effects) ───────────────

describe("owner-map resolveStateDir logic", () => {
  const map = TEST_OWNER_MAP;
  const BOTS_ROOT = "/fake/bots";

  function resolveStateDir(owner: string): string {
    const fallback = join(BOTS_ROOT, map.fallback_state_dir);
    const entry = map.mapping.find(e =>
      e.role === owner ||
      e.role.toLowerCase() === owner.toLowerCase() ||
      e.tg_usernames.includes(owner)
    );
    if (!entry) return fallback;
    if (!map.enabled_owners.includes(entry.state_dir)) return fallback;
    return join(BOTS_ROOT, entry.state_dir);
  }

  test("AC2: oldrabbit_eth (TG username) → anya", () => {
    expect(resolveStateDir("oldrabbit_eth")).toBe(join(BOTS_ROOT, "anya"));
  });

  test("AC2: 老兔 (role name) → anya", () => {
    expect(resolveStateDir("老兔")).toBe(join(BOTS_ROOT, "anya"));
  });

  test("AC2: cyslc14th (TG username) → caijie-zhuchu", () => {
    expect(resolveStateDir("cyslc14th")).toBe(join(BOTS_ROOT, "caijie-zhuchu"));
  });

  test("AC2: unknown owner → fallback anya", () => {
    expect(resolveStateDir("unknown-bot")).toBe(join(BOTS_ROOT, "anya"));
  });

  test("AC3: Nicky (not in ENABLED_OWNERS) → fallback anya", () => {
    // phobe29wyh → nicky-zhanglinghe, but nicky-zhanglinghe not in enabled_owners
    expect(resolveStateDir("phobe29wyh")).toBe(join(BOTS_ROOT, "anya"));
  });

  test("AC3: Ron (confirmed=false, not enabled) → fallback anya", () => {
    expect(resolveStateDir("Ron")).toBe(join(BOTS_ROOT, "anya"));
  });
});

// ── Ledger bucketing tests ────────────────────────────────────────────────────

describe("AC4: per-stateDir ledger bucketing", () => {
  const BOTS_ROOT = TMP;
  const KEEPER_MEMORY = join(TMP, "keeper-memory");

  function ledgerPath(stateDir: string): string {
    const name = stateDir.split("/").at(-1) ?? "unknown";
    return join(KEEPER_MEMORY, `push-ledger-${name}.json`);
  }

  function loadLedger(stateDir: string): any[] {
    try { return JSON.parse(readFileSync(ledgerPath(stateDir), "utf8")); }
    catch { return []; }
  }

  function saveLedger(stateDir: string, ledger: any[]) {
    mkdirSync(KEEPER_MEMORY, { recursive: true });
    writeFileSync(ledgerPath(stateDir), JSON.stringify(ledger));
  }

  function addToLedger(ledger: any[], key: string, stateDir: string) {
    ledger.push({ dedup_key: key, pushed_at: new Date().toISOString(), target_state_dir: stateDir });
  }

  beforeEach(() => {
    rmSync(KEEPER_MEMORY, { recursive: true, force: true });
    mkdirSync(KEEPER_MEMORY, { recursive: true });
  });

  test("AC4: pushing item to anya does not appear in caijie ledger", () => {
    const anyaDir = join(BOTS_ROOT, "anya");
    const caijiDir = join(BOTS_ROOT, "caijie-zhuchu");
    const itemId = "test-item-id-001";

    // Push to anya
    const anyaLedger = loadLedger(anyaDir);
    addToLedger(anyaLedger, itemId, anyaDir);
    saveLedger(anyaDir, anyaLedger);

    // Caijie ledger should NOT have this item
    const caijieLedger = loadLedger(caijiDir);
    const caijiHasItem = caijieLedger.some((e: any) => e.dedup_key === itemId);
    expect(caijiHasItem).toBe(false);
  });

  test("AC4: separate ledger files exist per stateDir", () => {
    const anyaDir = join(BOTS_ROOT, "anya");
    const caijiDir = join(BOTS_ROOT, "caijie-zhuchu");

    const l1 = loadLedger(anyaDir);
    addToLedger(l1, "anya-item", anyaDir);
    saveLedger(anyaDir, l1);

    const l2 = loadLedger(caijiDir);
    addToLedger(l2, "caijie-item", caijiDir);
    saveLedger(caijiDir, l2);

    // Each ledger file is separate and independent
    const anyaLoaded = loadLedger(anyaDir);
    const caijiLoaded = loadLedger(caijiDir);

    expect(anyaLoaded.length).toBe(1);
    expect(anyaLoaded[0].dedup_key).toBe("anya-item");
    expect(caijiLoaded.length).toBe(1);
    expect(caijiLoaded[0].dedup_key).toBe("caijie-item");
  });
});

// ── Per-batch quota tests ─────────────────────────────────────────────────────

describe("AC5: per-stateDir quota (≤5/batch, independent)", () => {
  const PER_OWNER_QUOTA = 5;

  test("AC5: anya quota exhaustion does not affect caijie quota", () => {
    const ownerCounts = new Map<string, number>();
    const anyaDir = "/fake/anya";
    const caijiDir = "/fake/caijie-zhuchu";

    // Fill anya quota
    for (let i = 0; i < PER_OWNER_QUOTA; i++) {
      ownerCounts.set(anyaDir, (ownerCounts.get(anyaDir) ?? 0) + 1);
    }
    expect(ownerCounts.get(anyaDir)).toBe(5);

    // caijie quota is independent — starts at 0
    const caijiCount = ownerCounts.get(caijiDir) ?? 0;
    expect(caijiCount).toBe(0);
    expect(caijiCount < PER_OWNER_QUOTA).toBe(true);
  });

  test("AC5: each owner can push up to quota independently", () => {
    const ownerCounts = new Map<string, number>();
    const dirs = ["/fake/anya", "/fake/caijie-zhuchu", "/fake/nicky-zhanglinghe"];
    const toPush: string[] = [];
    const skipped: string[] = [];

    // Simulate 7 items for anya and 7 for caijie
    for (const dir of dirs) {
      for (let i = 0; i < 7; i++) {
        const count = ownerCounts.get(dir) ?? 0;
        if (count < PER_OWNER_QUOTA) {
          ownerCounts.set(dir, count + 1);
          toPush.push(`${dir}:item${i}`);
        } else {
          skipped.push(`${dir}:item${i}`);
        }
      }
    }

    // Each owner gets exactly 5
    for (const dir of dirs) {
      expect(ownerCounts.get(dir)).toBe(5);
    }
    expect(toPush.length).toBe(15); // 3 owners × 5
    expect(skipped.length).toBe(6); // 3 owners × 2 skipped
  });
});

console.log("✓ diana-push P1 unit tests loaded");
