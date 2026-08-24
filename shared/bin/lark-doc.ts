#!/usr/bin/env bun
import { randomBytes } from "node:crypto";
import {
  AUDIT_PATH,
  DEFAULT_PATHS,
  LARK_SECRET_NAMES,
  LarkDocError,
  appendAudit,
  auditRecord,
  bootstrapInstructions,
  createAuthorization,
  doctor,
  finishAuthorization,
  getAccessToken,
  loadLarkCredentials,
  parseLarkUrl,
  readLarkSecret,
  readDocument,
  redact,
  safeAuditUrl,
} from "./lark-doc-lib.ts";

async function secret(name: string): Promise<string> {
  const value = await readLarkSecret(name, false);
  if (value === undefined) throw new LarkDocError("auth_failed", "無法載入 Lark 授權設定");
  return value;
}

async function authorizationCredentials(bootstrap: boolean): Promise<{
  appId: string;
  appSecret: string;
  expectedUserId?: string;
}> {
  const [appId, appSecret, expectedUserId] = await Promise.all([
    secret(LARK_SECRET_NAMES[0]),
    secret(LARK_SECRET_NAMES[1]),
    bootstrap
      ? readLarkSecret(LARK_SECRET_NAMES[2], true)
      : secret(LARK_SECRET_NAMES[2]),
  ]);
  return { appId, appSecret, expectedUserId };
}

const HELP = `用法：
  lark-doc auth start
  lark-doc auth finish [--bootstrap]  （callback URL 從 stdin）
  lark-doc doctor
  lark-doc read <url>

首次授權：先執行 auth start 並在瀏覽器授權，再把 callback URL 傳給
auth finish --bootstrap。依 stdout 印出的 gcloud 指令建立 owner secret，
最後執行 doctor；所有項目皆為 OK 才算完成。`;

function usage(): never {
  throw new LarkDocError("internal_error", HELP, 2);
}

async function main(): Promise<void> {
  const [command, subcommand, positional, ...extra] = Bun.argv.slice(2);
  if ((command === "help" || command === "--help") && !subcommand) {
    console.log(HELP);
    return;
  }
  if (command === "auth" && subcommand === "start" && !positional && !extra.length) {
    const appId = await secret("lark-app-id-anya");
    console.log(createAuthorization(appId).url);
    return;
  }
  const bootstrap = command === "auth" && subcommand === "finish"
    && positional === "--bootstrap" && !extra.length;
  if (command === "auth" && subcommand === "finish"
      && ((!positional && !extra.length) || bootstrap)) {
    const input = await Bun.stdin.text();
    const creds = await authorizationCredentials(bootstrap);
    const record = await finishAuthorization({ callbackUrl: input, bootstrap, ...creds });
    if (!creds.expectedUserId) {
      for (const line of bootstrapInstructions(record.verified_user_id)) console.log(line);
    }
    console.error("Lark 唯讀授權已安全保存。");
    return;
  }
  if (command === "doctor" && !subcommand && !positional && !extra.length) {
    const result = await doctor({ secret });
    for (const item of result.items) console.log(`${item.status} ${item.name}`);
    if (!result.ok) process.exitCode = 1;
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
    const creds = await loadLarkCredentials();
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
