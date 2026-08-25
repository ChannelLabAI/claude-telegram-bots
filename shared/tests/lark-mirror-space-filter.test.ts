import { describe, expect, test } from "bun:test";
import {
  REQUIRED_EXCLUDED_NODE_TOKENS,
  listVisibleWikiSpaces,
  summarizeSpaceFilter,
  validateConfig,
} from "../bin/lark-mirror-lib.ts";

const configuredSpaces = [
  "7588969620657147413",
  "7589941241228332563",
  "7596207127715122709",
];
const newlyConfigurableSpace = "7588585813969997332";

function fixtureConfig() {
  return {
    version: 1 as const,
    vault_dir: "/tmp/lark-mirror-space-filter-test",
    wiki_spaces: [...configuredSpaces],
    drive_folders: [],
    excluded_node_tokens: [...REQUIRED_EXCLUDED_NODE_TOKENS],
    lark_host: "ajp9g1jn00cg.jp.larksuite.com",
  };
}

describe("lark-mirror configurable and visible space filter", () => {
  test("configuration can add a space outside the former hard-coded upper limit", () => {
    const input = fixtureConfig();
    input.wiki_spaces.push(newlyConfigurableSpace);
    const loaded = validateConfig(input);
    expect(loaded.wiki_spaces).toContain(newlyConfigurableSpace);
    console.log("upper_limit_fixture:", JSON.stringify({
      loaded: true,
      wiki_spaces: loaded.wiki_spaces,
      newly_configurable_space: newlyConfigurableSpace,
    }));
  });

  test("configuration still fails when a required privacy exclusion is missing", () => {
    const input = fixtureConfig();
    const removed = input.excluded_node_tokens.pop();
    let completeError = "";
    try {
      validateConfig(input);
    } catch (error) {
      completeError = `${error instanceof Error ? error.name : typeof error}: ${
        error instanceof Error ? error.message : String(error)
      }`;
    }
    console.log("missing_required_exclusion_error:", completeError);
    expect(removed).toBe(REQUIRED_EXCLUDED_NODE_TOKENS.at(-1));
    expect(completeError).toBe("LarkDocError: Lark mirror 白名單設定無效");
  });

  test("visible API spaces produce an auditable filter summary with names", async () => {
    const visible = await listVisibleWikiSpaces({
      accessToken: "test-token",
      fetch: async (input) => {
        expect(String(input)).toContain("/open-apis/wiki/v2/spaces?page_size=50");
        return new Response(JSON.stringify({
          code: 0,
          data: {
            items: [
              { space_id: configuredSpaces[0], name: "NOXCAT" },
              { space_id: configuredSpaces[1], name: "老兔工作區" },
              { space_id: configuredSpaces[2], name: "AI 員工" },
              { space_id: newlyConfigurableSpace, name: "人事行政" },
              { space_id: "7666890650964463131", name: "test" },
            ],
            has_more: false,
          },
        }), { status: 200 });
      },
    });
    const summary = summarizeSpaceFilter(visible, configuredSpaces);
    expect(summary).toEqual({
      api_total: 5,
      allowed_total: 3,
      filtered: [
        { space_id: newlyConfigurableSpace, name: "人事行政" },
        { space_id: "7666890650964463131", name: "test" },
      ],
    });
    console.log("space_filter_fixture:", JSON.stringify(summary));
  });
});
