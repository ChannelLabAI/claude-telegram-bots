#!/usr/bin/env bun
import { randomBytes } from "node:crypto";
import {
  AUDIT_PATH,
  DEFAULT_PATHS,
  LarkDocError,
  appendAudit,
  auditRecord,
  createAuthorization,
  finishAuthorization,
  getAccessToken,
  parseLarkUrl,
  readDocument,
  redact,
  safeAuditUrl,
} from "./lark-doc-lib.ts";

async function secret(name: string): Promise<string> {
  const proc = Bun.spawn(
    ["gcloud", "secrets", "versions", "access", "latest", `--secret=${name}`, "--project=channellab-prod"],
    { stdout: "pipe", stderr: "ignore", env: { PATH: process.env.PATH ?? "/usr/bin:/bin" } },
  );
  const value = (await new Response(proc.stdout).text()).trim();
  if (await proc.exited || !value) throw new LarkDocError("auth_failed", "無法載入 Lark 授權設定");
  return value;
}

async function credentials(): Promise<{ appId: string; appSecret: string; expectedUserId: string }> {
  const [appId, appSecret, expectedUserId] = await Promise.all([
    secret("lark-app-id-anya"),
    secret("lark-app-secret-anya"),
    secret("lark-owner-user-id-anya"),
  ]);
  return { appId, appSecret, expectedUserId };
}

function usage(): never {
  throw new LarkDocError("internal_error", "用法：lark-doc auth start | lark-doc auth finish（callback URL 從 stdin）| lark-doc read <url>", 2);
}

async function main(): Promise<void> {
  const [command, subcommand, positional, ...extra] = Bun.argv.slice(2);
  if (command === "auth" && subcommand === "start" && !positional && !extra.length) {
    const appId = await secret("lark-app-id-anya");
    console.log(createAuthorization(appId).url);
    return;
  }
  if (command === "auth" && subcommand === "finish" && !positional && !extra.length) {
    const input = await Bun.stdin.text();
    const creds = await credentials();
    await finishAuthorization({ callbackUrl: input, ...creds });
    console.error("Lark 唯讀授權已安全保存。");
    return;
  }
  if (command !== "read" || !subcommand || positional || extra.length) usage();

  const requestId = randomBytes(16).toString("hex");
  let auditUrl = safeAuditUrl(subcommand);
  let docId: string | null = null;
  let started = false;
  try {
    appendAudit(AUDIT_PATH, auditRecord(requestId, auditUrl, null, 0, "started"));
    started = true;
    const parsed = parseLarkUrl(subcommand);
    auditUrl = parsed.normalizedUrl;
    docId = parsed.token;
    const creds = await credentials();
    const accessToken = await getAccessToken({ ...creds, paths: DEFAULT_PATHS });
    const result = await readDocument({ parsed, accessToken });
    const bytes = Buffer.byteLength(result.markdown, "utf8");
    appendAudit(AUDIT_PATH, auditRecord(requestId, auditUrl, docId, bytes, result.truncated ? "truncated" : "success"));
    process.stdout.write(result.markdown);
  } catch (error) {
    const known = error instanceof LarkDocError
      ? error
      : new LarkDocError("internal_error", "lark-doc 發生內部錯誤");
    if (started) {
      try { appendAudit(AUDIT_PATH, auditRecord(requestId, auditUrl, docId, 0, known.kind)); }
      catch { throw new LarkDocError("audit_failed", `審計記錄不可用，已停止讀取（request_id=${requestId}）`); }
    }
    throw known;
  }
}

main().catch((error) => {
  const known = error instanceof LarkDocError ? error : new LarkDocError("internal_error", "lark-doc 發生內部錯誤");
  console.error(redact(known.message));
  process.exit(known.exitCode);
});
