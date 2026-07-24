import { afterEach, describe, expect, test } from "bun:test";
import {
  APPROVED_SCOPES,
  LarkDocError,
  REDIRECT_URI,
  appendAudit,
  assertExactScopes,
  atomicWriteSecure,
  blocksToMarkdown,
  createAuthorization,
  finishAuthorization,
  getAccessToken,
  parseLarkUrl,
  readDocument,
  readSecureJson,
  redact,
  safeAuditUrl,
  sheetToMarkdown,
  type Paths,
  type TokenRecord,
} from "../bin/lark-doc-lib.ts";
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function paths(): Paths {
  const root = mkdtempSync(join(tmpdir(), "lark-doc-test-"));
  roots.push(root);
  const runtime = join(root, "runtime");
  const logs = join(root, "logs");
  mkdirSync(runtime, { mode: 0o700 });
  mkdirSync(logs, { mode: 0o700 });
  return {
    token: join(runtime, "token.json"),
    pending: join(runtime, "pending.json"),
    lock: join(runtime, "refresh.lock"),
    audit: join(logs, "audit.jsonl"),
  };
}

function response(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
}

function tokenRecord(overrides: Partial<TokenRecord> = {}): TokenRecord {
  return {
    version: 1,
    access_token: "access-old",
    refresh_token: "refresh-old",
    token_type: "Bearer",
    scope: [...APPROVED_SCOPES],
    verified_user_id: "rabbit-user",
    access_expires_at: new Date(Date.now() + 60_000).toISOString(),
    refresh_expires_at: new Date(Date.now() + 86_400_000).toISOString(),
    ...overrides,
  };
}

describe("URL parser", () => {
  test("direct docx normalizes tracking parameters", () => {
    expect(parseLarkUrl("https://acme.larksuite.com/docx/Abcdefgh_123?from=copy").normalizedUrl)
      .toBe("https://acme.larksuite.com/docx/Abcdefgh_123");
  });
  test("wiki and sheet selection parse", () => {
    expect(parseLarkUrl("https://a.larksuite.com/wiki/WikiToken9").kind).toBe("wiki");
    expect(parseLarkUrl("https://a.larksuite.com/sheets/SheetToken9?sheet=tab_1").sheetId).toBe("tab_1");
  });
  test.each([
    "http://a.larksuite.com/docx/Abcdefgh",
    "https://evil.example/docx/Abcdefgh",
    "https://u:p@a.larksuite.com/docx/Abcdefgh",
    "https://a.larksuite.com:444/docx/Abcdefgh",
    "https://a.larksuite.com/docx/Abcdefgh/extra",
    "https://a.larksuite.com/docx/short",
    "https://a.larksuite.com/docx/Abcdefgh?redirect=https://evil.example",
  ])("rejects hostile shape %s", (url) => expect(() => parseLarkUrl(url)).toThrow(LarkDocError));
  test("legacy and bitable have human rejection", () => {
    expect(() => parseLarkUrl("https://a.larksuite.com/docs/Legacy123")).toThrow("舊版 Lark 文件");
    expect(() => parseLarkUrl("https://a.larksuite.com/base/Bitable99")).toThrow("多維表格");
  });
});

describe("OAuth and secure persistence", () => {
  test("scope set is exact, sorted, and duplicate-free", () => {
    expect(assertExactScopes(APPROVED_SCOPES.join(" "))).toEqual([...APPROVED_SCOPES]);
    expect(() => assertExactScopes([...APPROVED_SCOPES, "drive:drive:readonly"])).toThrow("唯讀最小集合");
    expect(() => assertExactScopes([...APPROVED_SCOPES, APPROVED_SCOPES[0]])).toThrow();
  });
  test("auth start uses S256, random state, exact scopes, and 0600 pending", () => {
    const p = paths();
    const first = createAuthorization("app-id", p);
    const url = new URL(first.url);
    expect(url.searchParams.get("code_challenge_method")).toBe("S256");
    expect(url.searchParams.get("scope")?.split(" ").sort()).toEqual([...APPROVED_SCOPES]);
    expect(Bun.file(p.pending).size).toBeGreaterThan(0);
    expect((Bun.file(p.pending) as any).name).toBe(p.pending);
    expect((require("node:fs").statSync(p.pending).mode & 0o777)).toBe(0o600);
  });
  test("secure JSON rejects loose mode and symlink", () => {
    const p = paths();
    atomicWriteSecure(p.token, tokenRecord());
    chmodSync(p.token, 0o640);
    expect(() => readSecureJson(p.token)).toThrow("權限不安全");
    const target = join(roots[roots.length - 1]!, "target");
    Bun.write(target, "{}");
    symlinkSync(target, p.pending);
    expect(() => readSecureJson(p.pending)).toThrow("權限不安全");
  });
  test("finish validates callback, user, scopes and consumes pending", async () => {
    const p = paths();
    const start = createAuthorization("app-id", p);
    const state = new URL(start.url).searchParams.get("state")!;
    let calls = 0;
    const mock = (async () => {
      calls++;
      return calls === 1
        ? response({ access_token: "access-new", refresh_token: "refresh-new", token_type: "Bearer", scope: APPROVED_SCOPES.join(" "), expires_in: 3600, refresh_expires_in: 7200 })
        : response({ data: { user_id: "rabbit-user" } });
    });
    const record = await finishAuthorization({
      callbackUrl: `${REDIRECT_URI}?code=secret-code&state=${state}`,
      appId: "app-id",
      appSecret: "app-secret",
      expectedUserId: "rabbit-user",
      fetch: mock,
      paths: p,
    });
    expect(record.refresh_token).toBe("refresh-new");
    expect(readSecureJson<TokenRecord>(p.token).verified_user_id).toBe("rabbit-user");
    expect(Bun.file(p.pending).size).toBe(0);
  });
  test("finish rejects mismatch and callback reuse", async () => {
    const p = paths();
    createAuthorization("app-id", p);
    await expect(finishAuthorization({
      callbackUrl: `${REDIRECT_URI}?code=c&state=wrong`,
      appId: "id", appSecret: "secret", expectedUserId: "rabbit-user",
      fetch: async () => response({}), paths: p,
    })).rejects.toThrow("state");
    expect(() => readSecureJson(p.pending)).toThrow();
  });
  test("wrong user is never persisted", async () => {
    const p = paths();
    const start = createAuthorization("app-id", p);
    const state = new URL(start.url).searchParams.get("state")!;
    let calls = 0;
    const mock = (async () => ++calls === 1
      ? response({ access_token: "a", refresh_token: "r", scope: APPROVED_SCOPES, expires_in: 1, refresh_expires_in: 2 })
      : response({ data: { user_id: "intruder" } }));
    await expect(finishAuthorization({
      callbackUrl: `${REDIRECT_URI}?code=c&state=${state}`,
      appId: "id", appSecret: "secret", expectedUserId: "rabbit-user", fetch: mock, paths: p,
    })).rejects.toThrow("不是設定的老兔");
    expect(Bun.file(p.token).size).toBe(0);
  });
  test("concurrent refresh rotates once", async () => {
    const p = paths();
    atomicWriteSecure(p.token, tokenRecord());
    let refreshes = 0;
    const mock = (async () => {
      refreshes++;
      await Bun.sleep(20);
      return response({
        access_token: "access-rotated", refresh_token: "refresh-rotated",
        scope: APPROVED_SCOPES, expires_in: 3600, refresh_expires_in: 7200,
      });
    });
    const args = { appId: "id", appSecret: "secret", expectedUserId: "rabbit-user", fetch: mock, paths: p };
    expect(await Promise.all([getAccessToken(args), getAccessToken(args)]))
      .toEqual(["access-rotated", "access-rotated"]);
    expect(refreshes).toBe(1);
    expect(readSecureJson<TokenRecord>(p.token).refresh_token).toBe("refresh-rotated");
  });
  test("indeterminate refresh does not retry", async () => {
    const p = paths();
    atomicWriteSecure(p.token, tokenRecord());
    let calls = 0;
    await expect(getAccessToken({
      appId: "id", appSecret: "secret", expectedUserId: "rabbit-user", paths: p,
      fetch: async () => { calls++; throw new Error("network refresh-old"); },
    })).rejects.toThrow("結果不明");
    expect(calls).toBe(1);
    expect(readSecureJson<TokenRecord>(p.token).refresh_token).toBe("refresh-old");
  });
});

describe("conversion, routing, limits, audit", () => {
  test("checked-in remote fixtures stay parseable and contain no real payloads", () => {
    const fixtureRoot = join(import.meta.dir, "lark-doc-fixtures");
    const rich = JSON.parse(readFileSync(join(fixtureRoot, "rich-blocks.json"), "utf8"));
    const sheet = JSON.parse(readFileSync(join(fixtureRoot, "sheet-values.json"), "utf8"));
    const oauth = JSON.parse(readFileSync(join(fixtureRoot, "oauth-response.json"), "utf8"));
    expect(rich.items).toBeArray();
    expect(sheet.sheet.row_count).toBe(301);
    expect(oauth.access_token).toStartWith("fixture-");
  });
  test("rich blocks preserve supported content and mark unknown", () => {
    const result = blocksToMarkdown([
      { block_id: "root", block_type: 1, page: { elements: [{ text_run: { content: "Title" } }] } },
      { block_id: "p", parent_id: "root", block_type: 2, text: { elements: [{ text_run: { content: "bold", text_element_style: { bold: true } } }] } },
      { block_id: "img", parent_id: "root", block_type: 27 },
      { block_id: "future", parent_id: "root", block_type: 999 },
    ]);
    expect(result.markdown).toContain("**bold**");
    expect(result.markdown).toContain("![Lark image: img]");
    expect(result.markdown).toContain("unsupported Lark block type=999 id=future");
    expect(result.unsupported).toBe(1);
  });
  test("todo, divider, callout and table use official block IDs", () => {
    const result = blocksToMarkdown([
      { block_id: "todo", block_type: 17, todo: { done: true, elements: [{ text_run: { content: "done" } }] } },
      { block_id: "divider", block_type: 22 },
      { block_id: "callout", block_type: 19, callout: { elements: [{ text_run: { content: "note" } }] } },
      { block_id: "table", block_type: 31, table: { property: { row_size: 2, column_size: 2 }, cells: ["c1", "c2", "c3", "c4"] } },
      { block_id: "c1", parent_id: "table", block_type: 32 },
      { block_id: "c2", parent_id: "table", block_type: 32 },
      { block_id: "c3", parent_id: "table", block_type: 32 },
      { block_id: "c4", parent_id: "table", block_type: 32 },
      { block_id: "v1", parent_id: "c1", block_type: 2, text: { elements: [{ text_run: { content: "H1" } }] } },
      { block_id: "v2", parent_id: "c2", block_type: 2, text: { elements: [{ text_run: { content: "H2" } }] } },
      { block_id: "v3", parent_id: "c3", block_type: 2, text: { elements: [{ text_run: { content: "A" } }] } },
      { block_id: "v4", parent_id: "c4", block_type: 2, text: { elements: [{ text_run: { content: "B" } }] } },
    ]);
    expect(result.markdown).toContain("- [x] done");
    expect(result.markdown).toContain("> **Callout:** note");
    expect(result.markdown).toContain("| H1 | H2 |");
    expect(result.markdown).toContain("| A | B |");
  });
  test("sheet escapes pipes, newlines, empties and marks clipping", () => {
    const md = sheetToMarkdown("Book", "Tab", [["a|b", "x\ny", ""], ["", 2]], true);
    expect(md).toContain("a\\|b");
    expect(md).toContain("x<br>y");
    expect(md).toContain("300x26 cells");
  });
  test("direct docx paginates and emits unsupported markers", async () => {
    let calls = 0;
    const mock = (async (url: string | URL | Request) => {
      calls++;
      if (String(url).endsWith("/DocToken9")) return response({ data: { document: { title: "Doc" } } });
      return response({ data: { items: [{ block_id: "b", block_type: 999 }], has_more: false } });
    });
    const result = await readDocument({
      parsed: parseLarkUrl("https://a.larksuite.com/docx/DocToken9"),
      accessToken: "access", fetch: mock,
    });
    expect(result.markdown).toContain("# Doc");
    expect(result.markdown).toContain("unsupported");
    expect(calls).toBe(2);
  });
  test("docx stops at 2000 blocks within the six-request cap and marks truncation", async () => {
    let calls = 0;
    const mock = async (url: RequestInfo | URL) => {
      calls++;
      if (String(url).endsWith("/DocToken9")) return response({ data: { document: { title: "Doc" } } });
      const page = calls - 1;
      return response({ data: {
        items: Array.from({ length: 500 }, (_, i) => ({
          block_id: `b-${page}-${i}`,
          block_type: 2,
          text: { elements: [{ text_run: { content: "x" } }] },
        })),
        has_more: true,
        page_token: `page-${page + 1}`,
      } });
    };
    const result = await readDocument({
      parsed: parseLarkUrl("https://a.larksuite.com/docx/DocToken9"),
      accessToken: "access", fetch: mock,
    });
    expect(result.markdown).toContain("2000 blocks");
    expect(result.truncated).toBeTrue();
    expect(result.requests).toBe(5);
    expect(calls).toBe(5);
  });
  test("wiki routes only docx/sheet and rejects unknown object", async () => {
    const mock = async () => response({ data: { node: { obj_type: "bitable", obj_token: "Bitable99" } } });
    await expect(readDocument({
      parsed: parseLarkUrl("https://a.larksuite.com/wiki/WikiToken9"),
      accessToken: "access", fetch: mock,
    })).rejects.toThrow("不是支援");
  });
  test("direct sheet uses official metainfo and values endpoints", async () => {
    const urls: string[] = [];
    const mock = async (url: RequestInfo | URL) => {
      urls.push(String(url));
      if (String(url).endsWith("/metainfo")) {
        return response({ data: {
          properties: { title: "Book" },
          sheets: [{ sheetId: "tab1", title: "Tab", index: 0, rowCount: 301, columnCount: 27 }],
        } });
      }
      return response({ data: { valueRange: { values: [["H"], ["V"]] } } });
    };
    const result = await readDocument({
      parsed: parseLarkUrl("https://a.larksuite.com/sheets/SheetToken9"),
      accessToken: "access", fetch: mock,
    });
    expect(urls[0]).toEndWith("/sheets/v2/spreadsheets/SheetToken9/metainfo");
    expect(urls[1]).toContain("/values/tab1!A1%3AZ300");
    expect(result.markdown).toContain("第一個可見工作表");
    expect(result.markdown).toContain("300x26 cells");
    expect(result.truncated).toBeTrue();
  });
  test("60k output is Unicode-safe and explicitly truncated", async () => {
    const huge = "😀".repeat(65_000);
    const mock = (async (url: string | URL | Request) => String(url).endsWith("/DocToken9")
      ? response({ data: { document: { title: "Doc" } } })
      : response({ data: { items: [{ block_id: "b", block_type: 2, text: { elements: [{ text_run: { content: huge } }] } }], has_more: false } }));
    const result = await readDocument({
      parsed: parseLarkUrl("https://a.larksuite.com/docx/DocToken9"),
      accessToken: "access", fetch: mock,
    });
    expect([...result.markdown].length).toBeLessThanOrEqual(60_000);
    expect(result.markdown).toContain("60000 chars");
    expect(result.markdown).not.toContain("�");
  });
  test("HTTP failures map to human errors without raw bodies", async () => {
    const mock = async () => response({ code: 1770032, msg: "access_token=leak" }, 403);
    await expect(readDocument({
      parsed: parseLarkUrl("https://a.larksuite.com/docx/DocToken9"),
      accessToken: "secret", fetch: mock,
    })).rejects.toThrow("目前無權");
  });
  test("404, rate limit, network and malformed JSON have bounded human errors", async () => {
    const parsed = parseLarkUrl("https://a.larksuite.com/docx/DocToken9");
    await expect(readDocument({
      parsed, accessToken: "secret", fetch: async () => response({ code: 131005 }, 400),
    })).rejects.toThrow("連結無效");
    await expect(readDocument({
      parsed, accessToken: "secret", fetch: async () => response({ code: 99991400 }, 400),
    })).rejects.toThrow("API 忙碌");
    await expect(readDocument({
      parsed, accessToken: "secret", fetch: async () => { throw new Error("DNS token=leak"); },
    })).rejects.toThrow("網路連線失敗");
    await expect(readDocument({
      parsed, accessToken: "secret", fetch: async () => new Response("not-json"),
    })).rejects.toThrow("回傳格式異常");
  });
  test("audit is append-only 0600 and rejects symlink/loose mode", () => {
    const p = paths();
    appendAudit(p.audit, { ts: new Date().toISOString(), request_id: "a", url: "u", doc_id: null, caller: "anya-session", bytes: 0, result: "started" });
    appendAudit(p.audit, { ts: new Date().toISOString(), request_id: "a", url: "u", doc_id: "d", caller: "anya-session", bytes: 3, result: "success" });
    expect(readFileSync(p.audit, "utf8").trim().split("\n")).toHaveLength(2);
    expect((require("node:fs").statSync(p.audit).mode & 0o777)).toBe(0o600);
    chmodSync(p.audit, 0o644);
    expect(() => appendAudit(p.audit, { ts: "", request_id: "", url: "", doc_id: null, caller: "anya-session", bytes: 0, result: "started" })).toThrow("審計記錄不可用");
  });
  test("redaction and invalid audit URL are bounded", () => {
    const out = redact("Bearer abc access_token=xyz state=q code=z app_secret=s");
    expect(out).not.toContain("abc");
    expect(out).not.toContain("xyz");
    expect(out).not.toContain("app_secret=s");
    expect(safeAuditUrl("not a URL")).toBe("[invalid-url]");
    expect(safeAuditUrl("https://a.larksuite.com/docx/Abcdefgh?code=secret")).not.toContain("secret");
  });
});
