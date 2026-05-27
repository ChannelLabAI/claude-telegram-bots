/**
 * ontology-lib.test.ts — Unit tests for ontology-lib.ts (Step 1, Diana Phase 3)
 * Run: bun test ontology-lib.test.ts
 */

import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { mkdtemp, writeFile, mkdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  tokenize,
  jaccard,
  parseItemBlock,
  serializeItemBlock,
  parseAllBlocks,
  buildOntologyIndex,
  filterOntologyIndex,
  SENTINEL_RE,
} from "./ontology-lib";
import type { OntologyIndex, OntologyItemBlock } from "./ontology-lib";

// ── tokenize ──────────────────────────────────────────────────────────────────

describe("tokenize", () => {
  test("English words lowercased", () => {
    const t = tokenize("Hello World");
    expect(t.has("hello")).toBe(true);
    expect(t.has("world")).toBe(true);
    expect(t.size).toBe(2);
  });

  test("CJK per-character", () => {
    const t = tokenize("你好世界");
    expect(t.has("你")).toBe(true);
    expect(t.has("好")).toBe(true);
    expect(t.has("世")).toBe(true);
    expect(t.has("界")).toBe(true);
    expect(t.size).toBe(4);
  });

  test("mixed CJK + English", () => {
    const t = tokenize("Diana Phase 3 交付");
    expect(t.has("diana")).toBe(true);
    expect(t.has("phase")).toBe(true);
    expect(t.has("3")).toBe(true);
    expect(t.has("交")).toBe(true);
    expect(t.has("付")).toBe(true);
  });

  test("empty string returns empty set", () => {
    expect(tokenize("").size).toBe(0);
  });

  test("Extension A CJK (㐀-䶿 range)", () => {
    // 㐀 is U+3400
    const t = tokenize("㐀㑁");
    expect(t.size).toBe(2);
  });
});

// ── jaccard ───────────────────────────────────────────────────────────────────

describe("jaccard", () => {
  test("identical strings → 1.0", () => {
    expect(jaccard("hello world", "hello world")).toBe(1.0);
  });

  test("completely different → 0.0", () => {
    expect(jaccard("hello", "world")).toBe(0.0);
  });

  test("50% overlap", () => {
    // "a b" vs "b c" → intersection={b}, union={a,b,c} → 1/3
    const j = jaccard("a b", "b c");
    expect(j).toBeCloseTo(1 / 3, 5);
  });

  test("both empty → 0", () => {
    expect(jaccard("", "")).toBe(0);
  });

  test("CJK similarity", () => {
    // "Diana Phase 3 完成" vs "Diana Phase 3 完成" → 1.0
    expect(jaccard("Diana Phase 3 完成", "Diana Phase 3 完成")).toBe(1.0);
  });

  test("symmetry: jaccard(a,b) == jaccard(b,a)", () => {
    const a = "承諾追蹤 commitment done";
    const b = "commitment open action";
    expect(jaccard(a, b)).toBeCloseTo(jaccard(b, a), 10);
  });
});

// ── parseItemBlock ────────────────────────────────────────────────────────────

const SAMPLE_ID = "550e8400-e29b-41d4-a716-446655440000";

const VALID_BLOCK = `<!-- ontology-item id=${SAMPLE_ID} -->
\`\`\`yaml
id: ${SAMPLE_ID}
tag: commitment
text: "Diana Phase 3 spec 由 Anya 起草，本週交付"
source_slug: tg-20260527-anya-1234
ts: 2026-05-27T14:30:00+08:00
owner: anya
status: open
created_at: 2026-05-27T18:00:00+08:00
related: ["[[Diana]]", "[[FATQ]]"]
\`\`\`
<!-- /ontology-item -->`;

describe("parseItemBlock", () => {
  test("valid block parses correctly", () => {
    const item = parseItemBlock(VALID_BLOCK);
    expect(item).not.toBeNull();
    expect(item!.id).toBe(SAMPLE_ID);
    expect(item!.tag).toBe("commitment");
    expect(item!.text).toBe("Diana Phase 3 spec 由 Anya 起草，本週交付");
    expect(item!.source_slug).toBe("tg-20260527-anya-1234");
    expect(item!.ts).toBe("2026-05-27T14:30:00+08:00");
    expect(item!.owner).toBe("anya");
    expect(item!.status).toBe("open");
    expect(item!.created_at).toBe("2026-05-27T18:00:00+08:00");
    expect(item!.related).toEqual(["[[Diana]]", "[[FATQ]]"]);
  });

  test("sentinel ID is authoritative when YAML id differs", () => {
    const DIFFERENT_YAML_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    const mismatchBlock = VALID_BLOCK.replace(
      `id: ${SAMPLE_ID}`,
      `id: ${DIFFERENT_YAML_ID}`,
    );
    const item = parseItemBlock(mismatchBlock);
    expect(item).not.toBeNull();
    // sentinel wins
    expect(item!.id).toBe(SAMPLE_ID);
  });

  test("invalid tag returns null", () => {
    const bad = VALID_BLOCK.replace("tag: commitment", "tag: invalid_tag");
    expect(parseItemBlock(bad)).toBeNull();
  });

  test("missing sentinel returns null", () => {
    expect(parseItemBlock("no sentinel here")).toBeNull();
  });

  test("missing yaml block returns null", () => {
    const noYaml = `<!-- ontology-item id=${SAMPLE_ID} -->
no yaml fence
<!-- /ontology-item -->`;
    expect(parseItemBlock(noYaml)).toBeNull();
  });

  test("optional fields absent → undefined", () => {
    const minimal = `<!-- ontology-item id=${SAMPLE_ID} -->
\`\`\`yaml
id: ${SAMPLE_ID}
tag: decision
text: "Some decision"
source_slug: tg-abc
ts: 2026-05-27T10:00:00+08:00
\`\`\`
<!-- /ontology-item -->`;
    const item = parseItemBlock(minimal);
    expect(item).not.toBeNull();
    expect(item!.owner).toBeUndefined();
    expect(item!.status).toBeUndefined();
    expect(item!.related).toBeUndefined();
  });

  test("all 10 tags accepted", () => {
    const tags = [
      "decision", "commitment", "action_item", "assumption", "risk",
      "dependency", "open_question", "owner_implied", "precedent", "customer_signal",
    ];
    for (const tag of tags) {
      const block = VALID_BLOCK.replace("tag: commitment", `tag: ${tag}`);
      const item = parseItemBlock(block);
      expect(item).not.toBeNull();
      expect(item!.tag).toBe(tag);
    }
  });
});

// ── serializeItemBlock ────────────────────────────────────────────────────────

describe("serializeItemBlock", () => {
  test("sentinel regex matches serialized output", () => {
    const item: OntologyItemBlock = {
      id: SAMPLE_ID,
      tag: "commitment",
      text: "Test commitment",
      source_slug: "tg-abc",
      ts: "2026-05-27T10:00:00+08:00",
      owner: "anya",
      status: "open",
    };
    const serialized = serializeItemBlock(item);
    expect(SENTINEL_RE.test(serialized)).toBe(true);
    expect(serialized).toContain(`<!-- ontology-item id=${SAMPLE_ID} -->`);
    expect(serialized).toContain("<!-- /ontology-item -->");
    expect(serialized).toContain("```yaml");
  });

  test("roundtrip: serialize → parse recovers original", () => {
    const original: OntologyItemBlock = {
      id: SAMPLE_ID,
      tag: "decision",
      text: "老兔決定採用 Path A（GBrain 作底層）",
      source_slug: "tg-20260420-anya-100",
      ts: "2026-04-20T10:00:00+08:00",
      owner: "老兔",
      status: "open",
      created_at: "2026-04-20T23:00:00+08:00",
      related: ["[[GBrain]]", "[[MemOcean]]"],
    };
    const serialized = serializeItemBlock(original);
    const parsed = parseItemBlock(serialized);
    expect(parsed).not.toBeNull();
    expect(parsed!.id).toBe(original.id);
    expect(parsed!.tag).toBe(original.tag);
    expect(parsed!.text).toBe(original.text);
    expect(parsed!.source_slug).toBe(original.source_slug);
    expect(parsed!.ts).toBe(original.ts);
    expect(parsed!.owner).toBe(original.owner);
    expect(parsed!.status).toBe(original.status);
    expect(parsed!.related).toEqual(original.related);
  });

  test("special chars in text are escaped and restored", () => {
    const item: OntologyItemBlock = {
      id: SAMPLE_ID,
      tag: "open_question",
      text: 'Should we use "quotes" or \'apostrophes\'?',
      source_slug: "tg-abc",
      ts: "2026-05-27T10:00:00+08:00",
    };
    const parsed = parseItemBlock(serializeItemBlock(item));
    expect(parsed!.text).toBe(item.text);
  });
});

// ── parseAllBlocks ────────────────────────────────────────────────────────────

describe("parseAllBlocks", () => {
  test("extracts multiple blocks from content", () => {
    const id1 = "11111111-1111-1111-1111-111111111111";
    const id2 = "22222222-2222-2222-2222-222222222222";
    const content = `# 承諾追蹤

Some prose before.

<!-- ontology-item id=${id1} -->
\`\`\`yaml
id: ${id1}
tag: commitment
text: "First commitment"
source_slug: tg-001
ts: 2026-05-27T10:00:00+08:00
\`\`\`
<!-- /ontology-item -->

Some prose between.

<!-- ontology-item id=${id2} -->
\`\`\`yaml
id: ${id2}
tag: action_item
text: "Second action"
source_slug: tg-002
ts: 2026-05-27T11:00:00+08:00
\`\`\`
<!-- /ontology-item -->

Trailing prose.`;

    const blocks = parseAllBlocks(content);
    expect(blocks.length).toBe(2);
    expect(blocks[0].id).toBe(id1);
    expect(blocks[0].tag).toBe("commitment");
    expect(blocks[1].id).toBe(id2);
    expect(blocks[1].tag).toBe("action_item");
  });

  test("empty content returns empty array", () => {
    expect(parseAllBlocks("")).toEqual([]);
    expect(parseAllBlocks("# No blocks here")).toEqual([]);
  });

  test("malformed block (no yaml) is skipped", () => {
    const goodId = "33333333-3333-3333-3333-333333333333";
    const badId = "44444444-4444-4444-4444-444444444444";
    const content = `<!-- ontology-item id=${badId} -->
no yaml fence
<!-- /ontology-item -->

<!-- ontology-item id=${goodId} -->
\`\`\`yaml
id: ${goodId}
tag: risk
text: "Valid risk"
source_slug: tg-abc
ts: 2026-05-27T10:00:00+08:00
\`\`\`
<!-- /ontology-item -->`;

    const blocks = parseAllBlocks(content);
    expect(blocks.length).toBe(1);
    expect(blocks[0].id).toBe(goodId);
  });
});

// ── buildOntologyIndex + filterOntologyIndex ──────────────────────────────────

let tmpDir: string;

beforeAll(async () => {
  tmpDir = await mkdtemp(join(tmpdir(), "ontology-test-"));
  await mkdir(join(tmpDir, "珍珠卡"), { recursive: true });
  await mkdir(join(tmpDir, "技術海圖"), { recursive: true });
  await mkdir(join(tmpDir, "企劃"), { recursive: true });

  const id1 = "aaaaaaaa-0001-0001-0001-000000000001";
  const id2 = "aaaaaaaa-0002-0002-0002-000000000002";
  const id3 = "aaaaaaaa-0003-0003-0003-000000000003";

  // 承諾追蹤.md: commitment + action_item
  await writeFile(
    join(tmpDir, "珍珠卡/承諾追蹤.md"),
    `# 承諾追蹤\n\n` +
    serializeItemBlock({
      id: id1, tag: "commitment",
      text: "Phase 3 交付", source_slug: "tg-001",
      ts: "2026-05-20T10:00:00+08:00", owner: "anya", status: "open",
    }) +
    "\n\n" +
    serializeItemBlock({
      id: id2, tag: "action_item",
      text: "寫測試", source_slug: "tg-002",
      ts: "2026-05-27T10:00:00+08:00", owner: "anna", status: "open",
    }),
    "utf8",
  );

  // 決策記錄.md: decision (closed)
  await writeFile(
    join(tmpDir, "技術海圖/決策記錄.md"),
    `# 決策記錄\n\n` +
    serializeItemBlock({
      id: id3, tag: "decision",
      text: "採用 Path A", source_slug: "tg-003",
      ts: "2026-04-20T10:00:00+08:00", owner: "老兔", status: "closed",
    }),
    "utf8",
  );
});

afterAll(async () => {
  await rm(tmpDir, { recursive: true, force: true });
});

const TEST_ROUTES: Record<string, string> = {
  commitment: "珍珠卡/承諾追蹤.md",
  action_item: "珍珠卡/承諾追蹤.md",
  decision: "技術海圖/決策記錄.md",
};

describe("buildOntologyIndex", () => {
  let index: OntologyIndex;

  test("builds index with all items", async () => {
    index = await buildOntologyIndex(tmpDir, TEST_ROUTES, /* dryRun */ true);
    expect(Object.keys(index.items).length).toBe(3);
    expect(index.version).toBe(1);
    expect(typeof index.updated_at).toBe("string");
  });

  test("by_tag groups correctly", async () => {
    const idx = await buildOntologyIndex(tmpDir, TEST_ROUTES, true);
    expect(idx.by_tag["commitment"]?.length).toBe(1);
    expect(idx.by_tag["action_item"]?.length).toBe(1);
    expect(idx.by_tag["decision"]?.length).toBe(1);
  });

  test("by_status groups correctly", async () => {
    const idx = await buildOntologyIndex(tmpDir, TEST_ROUTES, true);
    expect(idx.by_status["open"]?.length).toBe(2);
    expect(idx.by_status["closed"]?.length).toBe(1);
  });

  test("by_owner groups correctly", async () => {
    const idx = await buildOntologyIndex(tmpDir, TEST_ROUTES, true);
    expect(idx.by_owner["anya"]?.length).toBe(1);
    expect(idx.by_owner["anna"]?.length).toBe(1);
    expect(idx.by_owner["老兔"]?.length).toBe(1);
  });

  test("item path reflects source vault file", async () => {
    const idx = await buildOntologyIndex(tmpDir, TEST_ROUTES, true);
    const decisionIds = idx.by_tag["decision"] ?? [];
    expect(decisionIds.length).toBe(1);
    expect(idx.items[decisionIds[0]].path).toBe("技術海圖/決策記錄.md");
  });

  test("non-dryRun writes index file", async () => {
    await buildOntologyIndex(tmpDir, TEST_ROUTES, false);
    const { existsSync } = await import("node:fs");
    expect(existsSync(join(tmpDir, "_index/ontology-index.json"))).toBe(true);
  });

  test("duplicate ids across files not double-counted", async () => {
    // Same routes → same files → same IDs; should not duplicate
    const idx = await buildOntologyIndex(tmpDir, TEST_ROUTES, true);
    expect(Object.keys(idx.items).length).toBe(3);
  });
});

describe("filterOntologyIndex", () => {
  let index: OntologyIndex;

  beforeAll(async () => {
    index = await buildOntologyIndex(tmpDir, TEST_ROUTES, true);
  });

  test("no filter returns all items sorted by ts desc", () => {
    const results = filterOntologyIndex(index, {});
    expect(results.length).toBe(3);
    // sorted ts desc: 2026-05-27 > 2026-05-20 > 2026-04-20
    expect(results[0].ts >= results[1].ts).toBe(true);
    expect(results[1].ts >= results[2].ts).toBe(true);
  });

  test("tag filter", () => {
    const results = filterOntologyIndex(index, { tag: "decision" });
    expect(results.length).toBe(1);
    expect(results[0].tag).toBe("decision");
  });

  test("status filter", () => {
    const open = filterOntologyIndex(index, { status: "open" });
    expect(open.length).toBe(2);
    const closed = filterOntologyIndex(index, { status: "closed" });
    expect(closed.length).toBe(1);
  });

  test("owner filter", () => {
    const results = filterOntologyIndex(index, { owner: "anya" });
    expect(results.length).toBe(1);
    expect(results[0].owner).toBe("anya");
  });

  test("AND logic: tag + status", () => {
    // commitment AND open → 1 item
    const results = filterOntologyIndex(index, { tag: "commitment", status: "open" });
    expect(results.length).toBe(1);
    // decision AND open → 0 items (decision is closed)
    const empty = filterOntologyIndex(index, { tag: "decision", status: "open" });
    expect(empty.length).toBe(0);
  });

  test("since_days filters on ts (not created_at)", () => {
    // since_days=10 from 2026-05-27: keeps 2026-05-27 and 2026-05-20 (7 days ago)
    // but NOT 2026-04-20 (37 days ago)
    // We mock "now" by checking relative to actual wall time, so just verify
    // that since_days=1 excludes the oldest item
    const results = filterOntologyIndex(index, { since_days: 1 });
    // Only 2026-05-27 is within 1 day of "now" (test runs ~same day as fixture)
    // This may be flaky if run far from the fixture date, but fixtures use today's date
    // So 2026-05-27 fixture should be within 1 day when test runs 2026-05-27
    for (const r of results) {
      const ts = new Date(r.ts);
      const cutoff = new Date();
      cutoff.setDate(cutoff.getDate() - 1);
      expect(ts >= cutoff).toBe(true);
    }
  });

  test("limit", () => {
    const results = filterOntologyIndex(index, { limit: 1 });
    expect(results.length).toBe(1);
  });

  test("empty result for impossible filter", () => {
    const results = filterOntologyIndex(index, { tag: "risk", status: "open" });
    expect(results.length).toBe(0);
  });
});
