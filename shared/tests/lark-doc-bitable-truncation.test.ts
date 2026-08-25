import { describe, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseLarkUrl, readDocument } from "../bin/lark-doc-lib.ts";

function response(data: unknown): Response {
  return new Response(JSON.stringify(data), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

interface FixtureOptions {
  tableIds: string[];
  recordsPerTable: number;
  payloadChars: number;
}

async function readFixture(options: FixtureOptions): Promise<string> {
  const fetch = async (input: RequestInfo | URL): Promise<Response> => {
    const url = new URL(String(input));
    const tableMatch = url.pathname.match(/\/tables\/([^/]+)\/(fields|records)$/);
    if (url.pathname.endsWith("/tables")) {
      return response({ data: {
        items: options.tableIds.map((tableId) => ({ table_id: tableId, name: `table-${tableId}` })),
        has_more: false,
        total: options.tableIds.length,
      } });
    }
    if (!tableMatch) throw new Error(`unexpected URL ${url}`);
    const [, tableId, kind] = tableMatch;
    if (kind === "fields") {
      return response({ data: {
        items: [{
          field_id: `fld_${tableId}`,
          field_name: "memo",
          type: 1,
          is_primary: true,
          property: null,
        }],
        has_more: false,
        total: 1,
      } });
    }
    return response({ data: {
      items: Array.from({ length: options.recordsPerTable }, (_, index) => ({
        record_id: `rec_${tableId}_${String(index).padStart(3, "0")}`,
        fields: { memo: `${tableId}:${index}:` + "財".repeat(options.payloadChars) },
      })),
      has_more: false,
      total: options.recordsPerTable,
    } });
  };
  const result = await readDocument({
    parsed: parseLarkUrl("https://a.larksuite.com/base/BaseObject99"),
    accessToken: "fixture-token",
    fetch,
  });
  return result.markdown;
}

function maybeWriteEvidence(filename: string, text: string): void {
  const outputDir = process.env.F30C_OUTPUT_DIR;
  if (!outputDir) return;
  mkdirSync(outputDir, { recursive: true });
  writeFileSync(join(outputDir, filename), text + "\n", "utf8");
}

describe("Bitable serialization truncation audit", () => {
  test("over-limit multi-table output identifies every affected table and is order-independent", async () => {
    const tableIds = ["tblGamma99", "tblAlpha99", "tblBeta99"];
    const text = await readFixture({ tableIds, recordsPerTable: 36, payloadChars: 900 });
    maybeWriteEvidence("negative-over-60000-output.json", text);
    const output = JSON.parse(text);

    expect([...text].length).toBeLessThanOrEqual(60_000);
    expect(output.truncated).toBeTrue();
    expect(output.truncation.output_limit_chars).toBe(60_000);
    expect(output.truncation.records_total).toBe(108);
    expect(output.truncation.records_returned).toBeLessThan(108);
    expect(output.truncation.records_omitted)
      .toBe(output.truncation.records_total - output.truncation.records_returned);
    expect(output.truncation.tables).toHaveLength(3);

    for (const table of output.tables) {
      expect(table.records_total).toBe(36);
      expect(table.records_returned).toBe(table.records.length);
      expect(table.records_omitted).toBe(36 - table.records.length);
      expect(table.records_truncated).toBe(table.records_omitted > 0);
    }
    expect(output.tables.every((table: any) => table.records_truncated)).toBeTrue();

    const reorderedText = await readFixture({
      tableIds: [...tableIds].reverse(),
      recordsPerTable: 36,
      payloadChars: 900,
    });
    const returnedById = Object.fromEntries(
      output.tables.map((table: any) => [table.table_id, table.records_returned]),
    );
    const reorderedById = Object.fromEntries(
      JSON.parse(reorderedText).tables.map((table: any) => [table.table_id, table.records_returned]),
    );
    expect(reorderedById).toEqual(returnedById);
  });

  test("under-limit output remains parseable and reports complete counts", async () => {
    const text = await readFixture({
      tableIds: ["tblAlpha99", "tblBeta99"],
      recordsPerTable: 2,
      payloadChars: 12,
    });
    maybeWriteEvidence("positive-under-60000-output.json", text);
    const output = JSON.parse(text);

    expect(output.format).toBe("lark-bitable-read-v1");
    expect(output.truncated).toBeFalse();
    expect(output.truncation).toBeNull();
    expect(output.tables).toHaveLength(2);
    expect(output.tables.every((table: any) => (
      table.records_total === 2
      && table.records_returned === 2
      && table.records_omitted === 0
      && table.records_truncated === false
      && table.records.length === 2
    ))).toBeTrue();
  });
});
