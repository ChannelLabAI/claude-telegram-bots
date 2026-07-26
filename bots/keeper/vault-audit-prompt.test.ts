import { describe, expect, test } from "bun:test";

import {
  AUDIT_PROMPT_TOKEN_BUDGET,
  buildAuditPrompt,
  estimatePromptTokens,
} from "./vault-audit-prompt";

const SYSTEM = "只從共用清單選擇節點，逐行輸出 FILE 與 wikilinks。";

function countOccurrences(text: string, needle: string): number {
  return text.split(needle).length - 1;
}

function fixtureBlocks(count = 20): string[] {
  return Array.from({ length: count }, (_, index) =>
    `=== 業務流/fixture-${index}.md ===\n摘要：${"測試摘要 ".repeat(30)}${index}`,
  );
}

describe("Step 9b prompt assembly", () => {
  test("shared hub list appears once and output blocks remain unchanged", () => {
    const hubs = ["Alpha-node", "Beta-node", "Gamma-node"];
    const blocks = fixtureBlocks();
    const plan = buildAuditPrompt(SYSTEM, hubs, blocks);

    expect(plan.hubNodesIncluded).toBe(hubs.length);
    expect(plan.inputBlocksIncluded).toBe(blocks.length);
    expect(plan.warnings).toEqual([]);
    expect(countOccurrences(plan.userContent, "本批共用可用節點清單")).toBe(1);
    for (const hub of hubs) expect(countOccurrences(plan.userContent, hub)).toBe(1);
    for (const block of blocks) expect(plan.userContent).toContain(block);
  });

  test(">5k large hubs with 20 files stays below 150k without dropping files", () => {
    const hubs = Array.from({ length: 5_500 }, (_, index) =>
      `hub-${index.toString().padStart(5, "0")}-${"long-node-name-".repeat(12)}`,
    );
    const blocks = fixtureBlocks(20);
    const unguarded = `${SYSTEM}\n\n${hubs.join(" | ")}\n\n${blocks.join("\n\n")}`;
    expect(estimatePromptTokens(unguarded)).toBeGreaterThan(AUDIT_PROMPT_TOKEN_BUDGET);

    const plan = buildAuditPrompt(SYSTEM, hubs, blocks);

    expect(plan.estimatedTokens).toBeLessThan(AUDIT_PROMPT_TOKEN_BUDGET);
    expect(plan.inputBlocksIncluded).toBe(20);
    expect(plan.hubNodesIncluded).toBeGreaterThan(0);
    expect(plan.hubNodesIncluded).toBeLessThan(hubs.length);
    expect(countOccurrences(plan.userContent, hubs[0])).toBe(1);
    expect(plan.warnings.join("\n")).toContain("hub list truncated");
    expect(plan.warnings.join("\n")).toContain("20 files retained");
  });

  test("fixed-content overflow defers files explicitly instead of silently losing them", () => {
    const blocks = Array.from({ length: 20 }, (_, index) =>
      `=== huge-${index}.md ===\n摘要：${"x".repeat(900)}`,
    );
    const plan = buildAuditPrompt(SYSTEM, ["only-hub"], blocks, 1_000);

    expect(plan.estimatedTokens).toBeLessThan(1_000);
    expect(plan.inputBlocksIncluded).toBeLessThan(blocks.length);
    expect(plan.inputBlocksIncluded).toBeGreaterThan(0);
    expect(plan.hubNodesIncluded).toBe(1);
    expect(plan.warnings.join("\n")).toContain("deferred");
    expect(plan.warnings.join("\n")).toContain("no files marked audited or dropped");
  });
});
