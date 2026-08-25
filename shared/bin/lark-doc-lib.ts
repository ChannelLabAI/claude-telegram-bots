import {
  closeSync,
  constants as fsConstants,
  existsSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
  writeSync,
} from "node:fs";
import { basename, dirname, join } from "node:path";
import { randomBytes, createHash, timingSafeEqual } from "node:crypto";

export const APPROVED_SCOPES = Object.freeze([
  "auth:user.id:read",
  "bitable:app:readonly",
  "docx:document:readonly",
  "offline_access",
  "sheets:spreadsheet:readonly",
  "wiki:wiki:readonly",
]);

export const DEFAULT_ROOT = "/home/oldrabbit/.claude-bots";
export const TOKEN_PATH = `${DEFAULT_ROOT}/bots/anya/runtime/lark-doc/oauth-token.json`;
export const PENDING_PATH = `${DEFAULT_ROOT}/bots/anya/runtime/lark-doc/oauth-pending.json`;
export const AUDIT_PATH = `${DEFAULT_ROOT}/bots/anya/logs/lark-doc-read-audit.jsonl`;
export const LOCK_PATH = `${DEFAULT_ROOT}/bots/anya/runtime/lark-doc/refresh.lock`;
export const CALLER = "anya-session";
export const REDIRECT_URI = "http://127.0.0.1:8765/lark-doc/oauth/callback";
export const AUTHORIZE_ENDPOINT = "https://accounts.larksuite.com/open-apis/authen/v1/authorize";
export const API_ROOT = "https://open.larksuite.com/open-apis";
export const TOKEN_ENDPOINT = `${API_ROOT}/authen/v2/oauth/token`;
export const USER_INFO_ENDPOINT = `${API_ROOT}/authen/v1/user_info`;
export const LARK_SECRET_NAMES = Object.freeze([
  "lark-app-id-anya",
  "lark-app-secret-anya",
  "lark-owner-user-id-anya",
] as const);

export type FetchLike = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;
export type AuditResult =
  | "started" | "success" | "truncated" | "invalid_url" | "unsupported"
  | "permission_denied" | "not_found" | "rate_limited" | "network_error"
  | "auth_failed" | "auth_bootstrap_unverified" | "malformed_response"
  | "audit_failed" | "internal_error";

export class LarkDocError extends Error {
  constructor(
    public readonly kind: AuditResult,
    message: string,
    public readonly exitCode = 1,
  ) {
    super(message);
    this.name = "LarkDocError";
  }
}

export interface Paths {
  token: string;
  pending: string;
  lock: string;
  audit: string;
}

export const DEFAULT_PATHS: Paths = {
  token: TOKEN_PATH,
  pending: PENDING_PATH,
  lock: LOCK_PATH,
  audit: AUDIT_PATH,
};

export interface ParsedLarkUrl {
  kind: "docx" | "wiki" | "sheet" | "bitable";
  token: string;
  sheetId?: string;
  tableId?: string;
  viewId?: string;
  normalizedUrl: string;
}

export interface TokenRecord {
  version: 1;
  access_token: string;
  refresh_token: string;
  token_type: "Bearer";
  scope: string[];
  verified_user_id: string;
  access_expires_at: string;
  refresh_expires_at: string;
}

export interface PendingRecord {
  version: 1;
  state_hash: string;
  verifier: string;
  redirect_uri: string;
  scope: string[];
  expires_at: string;
}

export interface AuditRecord {
  ts: string;
  request_id: string;
  url: string;
  doc_id: string | null;
  caller: typeof CALLER;
  bytes: number;
  result: AuditResult;
  auth_user_id?: string;
  owner_verified?: boolean;
}

export interface DoctorItem {
  status: "OK" | "MISSING";
  name: string;
}

export interface LarkCredentials {
  appId: string;
  appSecret: string;
  expectedUserId: string;
}

export async function readLarkSecret(
  name: string,
  allowExplicitNotFound = false,
): Promise<string | undefined> {
  const proc = Bun.spawn(
    ["gcloud", "secrets", "versions", "access", "latest", `--secret=${name}`, "--project=channellab-prod"],
    { stdout: "pipe", stderr: "pipe", env: { PATH: process.env.PATH ?? "/usr/bin:/bin" } },
  );
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  const value = stdout.trim();
  if (exitCode === 0 && value) return value;
  const explicitNotFound = /^ERROR:\s+\(gcloud\.secrets\.versions\.access\)\s+NOT_FOUND:/m.test(stderr);
  if (allowExplicitNotFound && exitCode !== 0 && explicitNotFound) return undefined;
  throw new LarkDocError("auth_failed", "無法載入 Lark 授權設定");
}

export async function loadLarkCredentials(): Promise<LarkCredentials> {
  const values = await Promise.all(LARK_SECRET_NAMES.map((name) => readLarkSecret(name)));
  if (values.some((value) => !value)) {
    throw new LarkDocError("auth_failed", "無法載入 Lark 授權設定");
  }
  const [appId, appSecret, expectedUserId] = values as [string, string, string];
  return { appId, appSecret, expectedUserId };
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", `'"'"'`)}'`;
}

export function bootstrapInstructions(userId: string): string[] {
  return [
    `LARK_AUTHORIZED_USER_ID=${userId}`,
    `printf '%s' ${shellQuote(userId)} | gcloud secrets create ${LARK_SECRET_NAMES[2]} --project=channellab-prod --replication-policy=automatic --data-file=-`,
  ];
}

const TOKEN_RE = /^[A-Za-z0-9_-]{8,128}$/;
const ID_RE = /^[A-Za-z0-9_-]{2,128}$/;
const SHEET_RE = /^[A-Za-z0-9_-]{1,128}$/;
const TABLE_RE = /^[A-Za-z0-9_-]{1,128}$/;
const VIEW_RE = /^[A-Za-z0-9_-]{1,128}$/;
const ALLOWED_TRACKING = new Set(["from", "source", "track_id", "tracking"]);
const REDACT_PATTERNS = [
  /Bearer\s+[^\s"'\\]+/gi,
  /(?:access|refresh)[_-]?token["'\s:=]+[^\s"',}]+/gi,
  /(?:client|app)[_-]?secret["'\s:=]+[^\s"',}]+/gi,
  /(?:code|state|verifier)["'\s:=]+[^\s"',}&]+/gi,
];
const REDACT_LIMIT = 500;
const TRUNCATION_MARKER = "\n...[truncated]...\n";

function stableScope(value: unknown): string[] {
  const raw = Array.isArray(value)
    ? value
    : typeof value === "string" ? value.split(/[\s,]+/) : [];
  return raw.filter((x): x is string => typeof x === "string" && x.length > 0).sort();
}

export function assertExactScopes(value: unknown): string[] {
  const scopes = stableScope(value);
  if (
    scopes.length !== APPROVED_SCOPES.length
    || new Set(scopes).size !== scopes.length
    || scopes.some((x, i) => x !== APPROVED_SCOPES[i])
  ) {
    throw new LarkDocError("auth_failed", "Lark 授權 scope 不符合唯讀最小集合，請老兔重新授權");
  }
  return scopes;
}

export function redact(value: unknown): string {
  let out: string;
  if (value instanceof Error) {
    const name = value.name || "Error";
    const identity = `${name}: ${value.message}`;
    const stack = typeof value.stack === "string" ? value.stack.trim() : "";
    out = stack.includes(identity) ? stack : [identity, stack].filter(Boolean).join("\n");
  } else if (typeof value === "string") {
    out = value;
  } else {
    try {
      out = JSON.stringify(value) ?? String(value);
    } catch {
      out = String(value);
    }
  }
  for (const pattern of REDACT_PATTERNS) out = out.replace(pattern, "[REDACTED]");
  const characters = [...out];
  if (characters.length <= REDACT_LIMIT) return out;
  const markerLength = [...TRUNCATION_MARKER].length;
  const remaining = REDACT_LIMIT - markerLength;
  const headLength = Math.floor(remaining / 2);
  const tailLength = remaining - headLength;
  return [
    ...characters.slice(0, headLength),
    ...TRUNCATION_MARKER,
    ...characters.slice(-tailLength),
  ].join("");
}

export function parseLarkUrl(input: string): ParsedLarkUrl {
  let url: URL;
  try {
    url = new URL(input);
  } catch {
    throw new LarkDocError("invalid_url", "不是支援的 Lark docx/wiki/sheets/base 連結");
  }
  if (
    url.protocol !== "https:"
    || url.username || url.password || url.port
    || !/^(?:[a-z0-9][a-z0-9-]{0,62}\.)+larksuite\.com$/i.test(url.hostname)
  ) {
    throw new LarkDocError("invalid_url", "不是支援的 Lark docx/wiki/sheets/base 連結");
  }
  const parts = url.pathname.split("/").filter(Boolean);
  if (parts.length !== 2 || !TOKEN_RE.test(parts[1] ?? "")) {
    throw new LarkDocError("invalid_url", "不是支援的 Lark docx/wiki/sheets/base 連結");
  }
  const [type, token] = parts as [string, string];
  if (type === "docs") {
    throw new LarkDocError("unsupported", "這是舊版 Lark 文件，請先轉存為新版 docx");
  }
  const kind = type === "docx" ? "docx" : type === "wiki" ? "wiki"
    : type === "sheets" ? "sheet" : type === "base" ? "bitable" : null;
  if (!kind) throw new LarkDocError("invalid_url", "不是支援的 Lark docx/wiki/sheets/base 連結");

  for (const key of url.searchParams.keys()) {
    if (!["sheet", "table", "view"].includes(key) && !ALLOWED_TRACKING.has(key)) {
      throw new LarkDocError("invalid_url", "不是支援的 Lark docx/wiki/sheets/base 連結");
    }
  }
  const sheetValues = url.searchParams.getAll("sheet");
  const tableValues = url.searchParams.getAll("table");
  const viewValues = url.searchParams.getAll("view");
  if (
    sheetValues.length > 1 || tableValues.length > 1 || viewValues.length > 1
    || (sheetValues[0] && (!SHEET_RE.test(sheetValues[0]) || kind !== "sheet"))
    || (tableValues[0] && (!TABLE_RE.test(tableValues[0]) || !["wiki", "bitable"].includes(kind)))
    || (viewValues[0] && (!VIEW_RE.test(viewValues[0]) || !["wiki", "bitable"].includes(kind)))
    || (viewValues[0] && !tableValues[0])
  ) {
    throw new LarkDocError("invalid_url", "不是支援的 Lark docx/wiki/sheets/base 連結");
  }
  const normalized = new URL(`https://${url.hostname.toLowerCase()}/${type}/${token}`);
  if (kind === "sheet" && sheetValues[0]) normalized.searchParams.set("sheet", sheetValues[0]);
  if (["wiki", "bitable"].includes(kind) && tableValues[0]) normalized.searchParams.set("table", tableValues[0]);
  if (["wiki", "bitable"].includes(kind) && viewValues[0]) normalized.searchParams.set("view", viewValues[0]);
  return {
    kind,
    token,
    ...(sheetValues[0] ? { sheetId: sheetValues[0] } : {}),
    ...(tableValues[0] ? { tableId: tableValues[0] } : {}),
    ...(viewValues[0] ? { viewId: viewValues[0] } : {}),
    normalizedUrl: normalized.toString(),
  };
}

function assertSecureParent(path: string): void {
  const parent = dirname(path);
  mkdirSync(parent, { recursive: true, mode: 0o700 });
  const st = lstatSync(parent);
  if (!st.isDirectory() || st.isSymbolicLink() || st.uid !== process.getuid!() || (st.mode & 0o077) !== 0) {
    throw new LarkDocError("auth_failed", "Lark 授權檔案目錄權限不安全");
  }
}

function assertSecureFile(path: string): void {
  const st = lstatSync(path);
  if (!st.isFile() || st.isSymbolicLink() || st.uid !== process.getuid!() || (st.mode & 0o077) !== 0) {
    throw new LarkDocError("auth_failed", "Lark 授權檔案權限不安全");
  }
}

export function atomicWriteSecure(path: string, value: unknown): void {
  assertSecureParent(path);
  if (existsSync(path)) assertSecureFile(path);
  const tmp = join(dirname(path), `.${basename(path)}.${process.pid}.${randomBytes(6).toString("hex")}.tmp`);
  let fd = -1;
  try {
    fd = openSync(tmp, fsConstants.O_WRONLY | fsConstants.O_CREAT | fsConstants.O_EXCL | fsConstants.O_NOFOLLOW, 0o600);
    writeFileSync(fd, `${JSON.stringify(value, null, 2)}\n`, "utf8");
    fsyncSync(fd);
    closeSync(fd);
    fd = -1;
    renameSync(tmp, path);
    const dirfd = openSync(dirname(path), fsConstants.O_RDONLY | fsConstants.O_DIRECTORY);
    try { fsyncSync(dirfd); } finally { closeSync(dirfd); }
  } finally {
    if (fd >= 0) closeSync(fd);
    if (existsSync(tmp)) unlinkSync(tmp);
  }
}

export function readSecureJson<T>(path: string): T {
  try {
    assertSecureFile(path);
    return JSON.parse(readFileSync(path, "utf8")) as T;
  } catch (error) {
    if (error instanceof LarkDocError) throw error;
    throw new LarkDocError("auth_failed", "Lark 授權檔案格式異常，請老兔重新授權");
  }
}

export function validateToken(record: TokenRecord, expectedUserId: string): TokenRecord {
  if (
    record.version !== 1 || record.token_type !== "Bearer"
    || typeof record.access_token !== "string" || !record.access_token
    || typeof record.refresh_token !== "string" || !record.refresh_token
    || typeof record.verified_user_id !== "string" || !record.verified_user_id
    || record.verified_user_id !== expectedUserId
  ) throw new LarkDocError("auth_failed", "Lark 授權已失效，請老兔重新授權");
  assertExactScopes(record.scope);
  const access = Date.parse(record.access_expires_at);
  const refresh = Date.parse(record.refresh_expires_at);
  if (!Number.isFinite(access) || !Number.isFinite(refresh) || refresh <= Date.now()) {
    throw new LarkDocError("auth_failed", "Lark 授權已失效，請老兔重新授權");
  }
  return record;
}

export function appendAudit(path: string, record: AuditRecord): void {
  try {
    assertSecureParent(path);
    if (existsSync(path)) assertSecureFile(path);
    const fd = openSync(
      path,
      fsConstants.O_WRONLY | fsConstants.O_APPEND | fsConstants.O_CREAT | fsConstants.O_NOFOLLOW,
      0o600,
    );
    try {
      writeSync(fd, `${JSON.stringify(record)}\n`, undefined, "utf8");
      fsyncSync(fd);
    } finally {
      closeSync(fd);
    }
  } catch {
    throw new LarkDocError("audit_failed", "審計記錄不可用，已停止讀取");
  }
}

export function auditRecord(
  requestId: string,
  url: string,
  docId: string | null,
  bytes: number,
  result: AuditResult,
): AuditRecord {
  return {
    ts: new Date().toISOString(),
    request_id: requestId,
    url,
    doc_id: docId,
    caller: CALLER,
    bytes,
    result,
  };
}

function sha256url(value: string): string {
  return createHash("sha256").update(value).digest("base64url");
}

export function createAuthorization(
  appId: string,
  paths: Paths = DEFAULT_PATHS,
  now = Date.now(),
): { url: string; pending: PendingRecord } {
  const state = randomBytes(32).toString("base64url");
  const verifier = randomBytes(32).toString("base64url");
  const pending: PendingRecord = {
    version: 1,
    state_hash: sha256url(state),
    verifier,
    redirect_uri: REDIRECT_URI,
    scope: [...APPROVED_SCOPES],
    expires_at: new Date(now + 5 * 60_000).toISOString(),
  };
  atomicWriteSecure(paths.pending, pending);
  const url = new URL(AUTHORIZE_ENDPOINT);
  url.searchParams.set("client_id", appId);
  url.searchParams.set("redirect_uri", REDIRECT_URI);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("scope", APPROVED_SCOPES.join(" "));
  url.searchParams.set("state", state);
  url.searchParams.set("code_challenge", sha256url(verifier));
  url.searchParams.set("code_challenge_method", "S256");
  return { url: url.toString(), pending };
}

function parseCallback(input: string): { code: string; state: string } {
  let url: URL;
  try { url = new URL(input.trim()); } catch {
    throw new LarkDocError("auth_failed", "OAuth callback URL 格式錯誤");
  }
  const expected = new URL(REDIRECT_URI);
  if (
    url.protocol !== expected.protocol || url.hostname !== expected.hostname
    || url.port !== expected.port || url.pathname !== expected.pathname
    || url.username || url.password || url.hash
    || url.searchParams.has("error")
    || url.searchParams.getAll("code").length !== 1
    || url.searchParams.getAll("state").length !== 1
  ) throw new LarkDocError("auth_failed", "OAuth callback URL 驗證失敗");
  const code = url.searchParams.get("code") ?? "";
  const state = url.searchParams.get("state") ?? "";
  if (!code || !state) throw new LarkDocError("auth_failed", "OAuth callback 缺少 code 或 state");
  return { code, state };
}

function consumePending(path: string): PendingRecord {
  const pending = readSecureJson<PendingRecord>(path);
  const consumed = `${path}.consumed.${process.pid}.${randomBytes(4).toString("hex")}`;
  renameSync(path, consumed);
  try {
    if (
      pending.version !== 1 || pending.redirect_uri !== REDIRECT_URI
      || Date.parse(pending.expires_at) <= Date.now()
    ) throw new LarkDocError("auth_failed", "OAuth 授權請求已過期，請重新開始");
    assertExactScopes(pending.scope);
    return pending;
  } finally {
    if (existsSync(consumed)) unlinkSync(consumed);
  }
}

function constantEqual(a: string, b: string): boolean {
  const aa = Buffer.from(a);
  const bb = Buffer.from(b);
  return aa.length === bb.length && timingSafeEqual(aa, bb);
}

function unwrap(payload: unknown): Record<string, any> {
  if (!payload || typeof payload !== "object") throw new LarkDocError("malformed_response", "Lark 回傳格式異常");
  const p = payload as Record<string, any>;
  if (p.code !== undefined && p.code !== 0) throw classifyApiError(400, p.code);
  return p.data && typeof p.data === "object" ? p.data : p;
}

export async function finishAuthorization(args: {
  callbackUrl: string;
  appId: string;
  appSecret: string;
  expectedUserId?: string;
  bootstrap?: boolean;
  fetch?: FetchLike;
  paths?: Paths;
}): Promise<TokenRecord> {
  const fetcher = args.fetch ?? fetch;
  const paths = args.paths ?? DEFAULT_PATHS;
  if (!args.expectedUserId && args.bootstrap !== true) {
    throw new LarkDocError("auth_failed", "無法載入 Lark 授權設定");
  }
  const { code, state } = parseCallback(args.callbackUrl);
  const pending = consumePending(paths.pending);
  if (!constantEqual(sha256url(state), pending.state_hash)) {
    throw new LarkDocError("auth_failed", "OAuth state 驗證失敗，請重新授權");
  }
  const response = await fetcher(TOKEN_ENDPOINT, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      grant_type: "authorization_code",
      client_id: args.appId,
      client_secret: args.appSecret,
      code,
      redirect_uri: REDIRECT_URI,
      code_verifier: pending.verifier,
      scope: APPROVED_SCOPES.join(" "),
    }),
  });
  const tokenData = unwrap(await safeJson(response));
  if (!response.ok) throw classifyApiError(response.status, tokenData.code);
  const scopes = assertExactScopes(tokenData.scope);
  const userResponse = await fetcher(USER_INFO_ENDPOINT, {
    headers: { authorization: `Bearer ${String(tokenData.access_token ?? "")}` },
  });
  const userData = unwrap(await safeJson(userResponse));
  if (!userResponse.ok) throw classifyApiError(userResponse.status, userData.code);
  const userId = String(userData.user_id ?? userData.open_id ?? "");
  if (!userId || (args.expectedUserId && userId !== args.expectedUserId)) {
    throw new LarkDocError("auth_failed", "授權帳號不是設定的老兔 Lark 帳號，已拒絕保存");
  }
  const now = Date.now();
  const record: TokenRecord = {
    version: 1,
    access_token: String(tokenData.access_token ?? ""),
    refresh_token: String(tokenData.refresh_token ?? ""),
    token_type: "Bearer",
    scope: scopes,
    verified_user_id: userId,
    access_expires_at: new Date(now + positiveSeconds(tokenData.expires_in) * 1000).toISOString(),
    refresh_expires_at: new Date(now + positiveSeconds(tokenData.refresh_expires_in ?? tokenData.refresh_token_expires_in) * 1000).toISOString(),
  };
  validateToken(record, args.expectedUserId ?? userId);
  if (!args.expectedUserId) {
    appendAudit(paths.audit, {
      ts: new Date().toISOString(),
      request_id: randomBytes(16).toString("hex"),
      url: REDIRECT_URI,
      doc_id: null,
      caller: CALLER,
      bytes: 0,
      result: "auth_bootstrap_unverified",
      auth_user_id: userId,
      owner_verified: false,
    });
  }
  atomicWriteSecure(paths.token, record);
  return record;
}

export async function doctor(args: {
  secret: (name: string) => Promise<string>;
  secretNames?: readonly string[];
  tokenPath?: string;
}): Promise<{ ok: boolean; items: DoctorItem[] }> {
  const items: DoctorItem[] = [];
  for (const name of args.secretNames ?? LARK_SECRET_NAMES) {
    try {
      const value = await args.secret(name);
      if (!value) throw new Error("empty secret");
      items.push({ status: "OK", name });
    } catch {
      items.push({ status: "MISSING", name });
    }
  }
  try {
    const token = readSecureJson<TokenRecord>(args.tokenPath ?? TOKEN_PATH);
    validateToken(token, token.verified_user_id);
    items.push({ status: "OK", name: "oauth-token" });
  } catch {
    items.push({ status: "MISSING", name: "oauth-token" });
  }
  return { ok: items.every((item) => item.status === "OK"), items };
}

function positiveSeconds(value: unknown): number {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) throw new LarkDocError("malformed_response", "Lark 回傳格式異常");
  return n;
}

async function safeJson(response: Response): Promise<unknown> {
  try { return await response.json(); } catch {
    throw new LarkDocError("malformed_response", "Lark 回傳格式異常");
  }
}

function classifyApiError(status: number, code: unknown): LarkDocError {
  const c = Number(code);
  if (status === 401 || [99991661, 99991663, 99991668, 99991671, 99991677].includes(c)) {
    return new LarkDocError("auth_failed", "Lark 授權已失效，請老兔重新授權");
  }
  if (status === 403 || [230027, 1770032, 131006, 1310213, 99991672, 99991676, 99991679].includes(c)) {
    return new LarkDocError("permission_denied", "老兔的 Lark 帳號目前無權讀取此文件");
  }
  if (status === 404 || [1770002, 131005].includes(c)) {
    return new LarkDocError("not_found", "連結無效，或文件已刪除");
  }
  if (status === 429 || c === 99991400) {
    return new LarkDocError("rate_limited", "Lark API 忙碌，請稍後再試");
  }
  return new LarkDocError("malformed_response", "Lark 回傳格式異常");
}

async function acquireLock(path: string, timeoutMs = 5_000): Promise<() => void> {
  assertSecureParent(path);
  const start = Date.now();
  while (true) {
    try {
      const fd = openSync(path, fsConstants.O_WRONLY | fsConstants.O_CREAT | fsConstants.O_EXCL | fsConstants.O_NOFOLLOW, 0o600);
      writeFileSync(fd, `${process.pid}\n`);
      closeSync(fd);
      return () => { if (existsSync(path)) unlinkSync(path); };
    } catch (error: any) {
      if (error?.code !== "EEXIST") throw error;
      if (Date.now() - start >= timeoutMs) {
        throw new LarkDocError("auth_failed", "Lark token refresh 忙碌，請稍後重試");
      }
      await Bun.sleep(30);
    }
  }
}

export async function getAccessToken(args: {
  appId: string;
  appSecret: string;
  expectedUserId: string;
  fetch?: FetchLike;
  paths?: Paths;
}): Promise<string> {
  const paths = args.paths ?? DEFAULT_PATHS;
  let current = validateToken(readSecureJson<TokenRecord>(paths.token), args.expectedUserId);
  if (Date.parse(current.access_expires_at) > Date.now() + 5 * 60_000) return current.access_token;
  const release = await acquireLock(paths.lock);
  try {
    current = validateToken(readSecureJson<TokenRecord>(paths.token), args.expectedUserId);
    if (Date.parse(current.access_expires_at) > Date.now() + 5 * 60_000) return current.access_token;
    let response: Response;
    try {
      response = await (args.fetch ?? fetch)(TOKEN_ENDPOINT, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          grant_type: "refresh_token",
          client_id: args.appId,
          client_secret: args.appSecret,
          refresh_token: current.refresh_token,
          scope: APPROVED_SCOPES.join(" "),
        }),
      });
    } catch {
      throw new LarkDocError("auth_failed", "Lark refresh 結果不明，為保護一次性 token，請老兔重新授權");
    }
    const data = unwrap(await safeJson(response));
    if (!response.ok) throw new LarkDocError("auth_failed", "Lark 授權已失效，請老兔重新授權");
    const now = Date.now();
    const rotated: TokenRecord = {
      version: 1,
      access_token: String(data.access_token ?? ""),
      refresh_token: String(data.refresh_token ?? ""),
      token_type: "Bearer",
      scope: assertExactScopes(data.scope),
      verified_user_id: current.verified_user_id,
      access_expires_at: new Date(now + positiveSeconds(data.expires_in) * 1000).toISOString(),
      refresh_expires_at: new Date(now + positiveSeconds(data.refresh_expires_in ?? data.refresh_token_expires_in) * 1000).toISOString(),
    };
    validateToken(rotated, args.expectedUserId);
    atomicWriteSecure(paths.token, rotated);
    return rotated.access_token;
  } finally {
    release();
  }
}

class ApiClient {
  requests = 0;
  constructor(
    private readonly token: string,
    private readonly fetcher: FetchLike,
    private readonly deadline: number,
    private readonly maxRequests = 6,
  ) {}

  async json(url: string): Promise<Record<string, any>> {
    if (!url.startsWith(`${API_ROOT}/`)) throw new LarkDocError("internal_error", "拒絕非 Lark API 目的地");
    if (++this.requests > this.maxRequests || Date.now() >= this.deadline) {
      throw new LarkDocError("network_error", "Lark 網路連線失敗，請稍後再試");
    }
    let attempts = 0;
    while (true) {
      const remaining = Math.min(15_000, this.deadline - Date.now());
      if (remaining <= 0) throw new LarkDocError("network_error", "Lark 網路連線失敗，請稍後再試");
      try {
        const response = await this.fetcher(url, {
          headers: { authorization: `Bearer ${this.token}` },
          signal: AbortSignal.timeout(remaining),
        });
        const raw = await safeJson(response);
        if (!response.ok || ((raw as any)?.code !== undefined && (raw as any).code !== 0)) {
          const err = classifyApiError(response.status, (raw as any)?.code);
          if (err.kind === "rate_limited" && attempts++ < 2 && this.requests < this.maxRequests) {
            await Bun.sleep(Math.min(100 * 2 ** attempts * Math.random(), Math.max(0, this.deadline - Date.now())));
            this.requests++;
            continue;
          }
          throw err;
        }
        return unwrap(raw);
      } catch (error) {
        if (error instanceof LarkDocError) throw error;
        throw new LarkDocError("network_error", "Lark 網路連線失敗，請稍後再試");
      }
    }
  }
}

function wikiSpaceMarkdown(
  name: string,
  host: string,
  nodes: Array<{ title: string; type: string; token: string; level: number }>,
): string {
  const rows = nodes.map((node) => {
    const title = escapeCell(node.title || node.token);
    const type = escapeCell(node.type || "unknown");
    const url = `https://${host}/wiki/${encodeURIComponent(node.token)}`;
    return `| ${node.level} | ${title} | ${type} | ${url} |`;
  });
  return [
    `# ${name}`,
    "",
    `知識庫空間，共 ${nodes.length} 個節點。`,
    "",
    "| 層級 | 標題 | 型別 | 可直讀 URL |",
    "| ---: | --- | --- | --- |",
    ...rows,
  ].join("\n");
}

async function readWikiSpace(
  api: ApiClient,
  spaceId: string,
  host: string,
): Promise<{ markdown: string; truncated: boolean }> {
  const spaceData = await api.json(`${API_ROOT}/wiki/v2/spaces/${encodeURIComponent(spaceId)}`);
  const name = String(spaceData.space?.name ?? spaceData.name ?? "Lark Wiki");
  const nodes: Array<{ title: string; type: string; token: string; level: number }> = [];
  const queue: Array<{ parent: string; level: number }> = [{ parent: "", level: 0 }];
  const expanded = new Set<string>();
  let clipped = false;
  while (queue.length && nodes.length < 2000) {
    const current = queue.shift()!;
    if (expanded.has(current.parent)) continue;
    expanded.add(current.parent);
    let pageToken = "";
    do {
      const query = new URLSearchParams({ page_size: "50" });
      if (current.parent) query.set("parent_node_token", current.parent);
      if (pageToken) query.set("page_token", pageToken);
      const page = await api.json(
        `${API_ROOT}/wiki/v2/spaces/${encodeURIComponent(spaceId)}/nodes?${query}`,
      );
      const items = Array.isArray(page.items) ? page.items : [];
      for (const item of items) {
        const token = String(item.node_token ?? "");
        if (!TOKEN_RE.test(token)) continue;
        nodes.push({
          title: String(item.title ?? token),
          type: String(item.obj_type ?? item.node_type ?? "unknown"),
          token,
          level: current.level,
        });
        if (item.has_child === true) queue.push({ parent: token, level: current.level + 1 });
        if (nodes.length >= 2000) {
          clipped = true;
          break;
        }
      }
      if (nodes.length >= 2000) break;
      pageToken = page.has_more ? String(page.page_token ?? "") : "";
      if (page.has_more && !pageToken) {
        throw new LarkDocError("malformed_response", "Lark 回傳格式異常");
      }
    } while (pageToken);
  }
  if (queue.length) clipped = true;
  const markdown = wikiSpaceMarkdown(name, host, nodes)
    + (clipped ? "\n\n> ⚠️ 內容已截斷（2000 nodes）" : "");
  return { markdown, truncated: clipped };
}

function textRuns(value: any): string {
  const runs = value?.elements ?? value?.text?.elements ?? [];
  if (!Array.isArray(runs)) return "";
  return runs.map((element: any) => {
    const raw = String(element?.text_run?.content ?? element?.mention_user?.user_id ?? "");
    if (!element?.text_run) {
      const type = Object.keys(element ?? {})[0] ?? "unknown";
      return `<!-- unsupported Lark inline type=${escapeHtml(type)} -->`;
    }
    const style = element.text_run.text_element_style ?? {};
    let out = raw.replace(/\\/g, "\\\\").replace(/\*/g, "\\*");
    if (style.inline_code) out = `\`${out.replace(/`/g, "\\`")}\``;
    if (style.bold) out = `**${out}**`;
    if (style.italic) out = `*${out}*`;
    if (style.strikethrough) out = `~~${out}~~`;
    if (style.link?.url && /^(https?:|mailto:)/i.test(style.link.url)) out = `[${out}](${String(style.link.url).replace(/[()]/g, "\\$&")})`;
    return out;
  }).join("");
}

function escapeHtml(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

export function blocksToMarkdown(blocks: any[]): { markdown: string; unsupported: number } {
  const byParent = new Map<string, any[]>();
  for (const b of blocks) {
    const parent = String(b.parent_id ?? "");
    const arr = byParent.get(parent) ?? [];
    arr.push(b);
    byParent.set(parent, arr);
  }
  let unsupported = 0;
  const render = (b: any, depth = 0): string => {
    const id = String(b.block_id ?? "unknown");
    const type = Number(b.block_type);
    const content = b.page ?? b.text ?? b.heading1 ?? b.heading2 ?? b.heading3
      ?? b.heading4 ?? b.heading5 ?? b.heading6 ?? b.heading7 ?? b.heading8 ?? b.heading9
      ?? b.bullet ?? b.ordered ?? b.quote ?? b.todo ?? b.code ?? b.callout;
    const text = textRuns(content);
    let line: string;
    if (type === 1) line = text ? `# ${text}` : "";
    else if (type === 2) line = text;
    else if (type >= 3 && type <= 11) line = `${"#".repeat(type - 1)} ${text}`;
    else if (type === 12) line = `${"  ".repeat(depth)}- ${text}`;
    else if (type === 13) line = `${"  ".repeat(depth)}1. ${text}`;
    else if (type === 14) line = `\`\`\`${String(content?.language ?? "").replace(/[^A-Za-z0-9_+-]/g, "")}\n${text.replace(/```/g, "``\\`")}\n\`\`\``;
    else if (type === 15) line = `> ${text}`;
    else if (type === 17) line = `${"  ".repeat(depth)}- [${content?.done ? "x" : " "}] ${text}`;
    else if (type === 19) line = `> **Callout:** ${text}`;
    else if (type === 22) line = "---";
    else if (type === 27) line = `![Lark image: ${id}]`;
    else if (type === 31) {
      const rows = Math.max(0, Number(b.table?.property?.row_size ?? 0));
      const columns = Math.max(0, Number(b.table?.property?.column_size ?? 0));
      const cellIds = Array.isArray(b.table?.cells) ? b.table.cells.map(String) : [];
      if (!rows || !columns || cellIds.length !== rows * columns) {
        unsupported++;
        return `<!-- unsupported Lark block type=31 id=${escapeHtml(id)} -->`;
      }
      const cells = cellIds.map((cellId: string) => {
        const content = (byParent.get(cellId) ?? []).map((child) => render(child, depth + 1))
          .join("<br>").replace(/\|/g, "\\|").replace(/\n/g, "<br>");
        return content;
      });
      const matrix = Array.from({ length: rows }, (_, row) =>
        cells.slice(row * columns, (row + 1) * columns));
      const header = matrix[0] ?? Array.from({ length: columns }, () => "");
      const body = matrix.slice(1);
      return [
        `| ${header.join(" | ")} |`,
        `| ${header.map(() => "---").join(" | ")} |`,
        ...body.map((row) => `| ${row.join(" | ")} |`),
      ].join("\n");
    }
    else if (type === 32) line = "";
    else {
      unsupported++;
      line = `<!-- unsupported Lark block type=${Number.isFinite(type) ? type : "unknown"} id=${escapeHtml(id)} -->`;
    }
    const children = type === 31
      ? ""
      : (byParent.get(id) ?? []).map((child) => render(child, depth + 1)).join("\n");
    return [line, children].filter(Boolean).join("\n");
  };
  const roots = blocks.filter((b) => !b.parent_id || !blocks.some((x) => x.block_id === b.parent_id));
  let markdown = roots.map((b) => render(b)).filter(Boolean).join("\n\n");
  unsupported += markdown.match(/<!-- unsupported Lark inline type=/g)?.length ?? 0;
  if (unsupported) markdown += `\n\n> 未支援的 Lark block/element：${unsupported} 個，已在原位置標注。`;
  return { markdown, unsupported };
}

function truncateOutput(markdown: string, reason?: string): { markdown: string; truncated: boolean } {
  const marker = `\n\n> ⚠️ 內容已截斷（${reason ?? "60000 chars"}）`;
  const chars = [...markdown];
  if (chars.length <= 60_000 && !reason) return { markdown, truncated: false };
  const room = Math.max(0, 60_000 - [...marker].length);
  return { markdown: chars.slice(0, room).join("") + marker, truncated: true };
}

function escapeCell(value: unknown): string {
  return String(value ?? "").replace(/\|/g, "\\|").replace(/\r?\n/g, "<br>");
}

export function sheetToMarkdown(title: string, sheetTitle: string, values: unknown[][], clipped: boolean): string {
  const rows = values.slice(0, 300).map((r) => r.slice(0, 26));
  const width = Math.max(1, ...rows.map((r) => r.length));
  const normalized = rows.map((r) => Array.from({ length: width }, (_, i) => escapeCell(r[i])));
  const header = normalized.shift() ?? Array.from({ length: width }, () => "");
  let out = `# ${title}\n\n工作表：${sheetTitle}（A1:Z300）\n\n`;
  out += `| ${header.join(" | ")} |\n| ${header.map(() => "---").join(" | ")} |`;
  for (const row of normalized) out += `\n| ${row.join(" | ")} |`;
  if (clipped || values.length > 300 || values.some((r) => r.length > 26)) out += "\n\n> ⚠️ 內容已截斷（300x26 cells）";
  return out;
}

interface BitableTableOutput {
  table_id: string;
  name: string;
  fields: Array<{
    field_id: string;
    field_name: string;
    type: number | string | null;
    is_primary: boolean;
    property: unknown;
    property_truncated?: boolean;
  }>;
  records: Array<{ record_id: string; fields: Record<string, unknown> }>;
  records_total: number;
  records_returned: number;
  records_omitted: number;
  records_truncated: boolean;
}

async function listBitableItems(
  api: ApiClient,
  endpoint: string,
  pageSize: number,
  maximum: number,
  extra: Record<string, string> = {},
): Promise<{ items: any[]; truncated: boolean; total: number | null }> {
  const items: any[] = [];
  let pageToken = "";
  let truncated = false;
  let reportedTotal: number | null = null;
  do {
    const query = new URLSearchParams({ page_size: String(pageSize), ...extra });
    if (pageToken) query.set("page_token", pageToken);
    const page = await api.json(`${endpoint}?${query}`);
    if (!Array.isArray(page.items)) {
      throw new LarkDocError("malformed_response", "Lark 回傳格式異常");
    }
    if (page.total !== undefined && page.total !== null) {
      if (!Number.isSafeInteger(page.total) || page.total < 0) {
        throw new LarkDocError("malformed_response", "Lark 回傳格式異常");
      }
      if (reportedTotal !== null && reportedTotal !== page.total) {
        throw new LarkDocError("malformed_response", "Lark 回傳格式異常");
      }
      reportedTotal = page.total;
    }
    const remaining = maximum - items.length;
    items.push(...page.items.slice(0, remaining));
    const hasMore = page.has_more === true;
    if (page.items.length > remaining || (items.length >= maximum && hasMore)) {
      truncated = true;
      break;
    }
    if (!hasMore) break;
    pageToken = String(page.page_token ?? "");
    if (!pageToken) throw new LarkDocError("malformed_response", "Lark 回傳格式異常");
  } while (items.length < maximum);
  if (reportedTotal !== null && reportedTotal < items.length) {
    throw new LarkDocError("malformed_response", "Lark 回傳格式異常");
  }
  return {
    items,
    truncated,
    total: reportedTotal ?? (truncated ? null : items.length),
  };
}

function serializeBitableOutput(value: {
  format: "lark-bitable-read-v1";
  source_url: string;
  app_token: string;
  tables: BitableTableOutput[];
  truncated: boolean;
}): { text: string; truncated: boolean } {
  const limit = 60_000;
  const refreshRecordAudit = () => {
    for (const table of value.tables) {
      table.records_returned = table.records.length;
      table.records_omitted = Math.max(0, table.records_total - table.records_returned);
      table.records_truncated ||= table.records_omitted > 0;
    }
  };
  const render = () => {
    refreshRecordAudit();
    const tableAudit = value.tables.map((table) => ({
      table_id: table.table_id,
      name: table.name,
      records_total: table.records_total,
      records_returned: table.records_returned,
      records_omitted: table.records_omitted,
      records_truncated: table.records_truncated,
      fields_truncated: table.fields.some((field) => field.property_truncated === true),
    }));
    const recordsTotal = tableAudit.reduce((sum, table) => sum + table.records_total, 0);
    const recordsReturned = tableAudit.reduce((sum, table) => sum + table.records_returned, 0);
    return JSON.stringify({
      format: value.format,
      source_url: value.source_url,
      app_token: value.app_token,
      truncated: value.truncated,
      truncation: value.truncated ? {
        output_limit_chars: limit,
        records_total: recordsTotal,
        records_returned: recordsReturned,
        records_omitted: recordsTotal - recordsReturned,
        tables: tableAudit,
      } : null,
      tables: value.tables,
    }, null, 2);
  };
  let text = render();
  while ([...text].length > limit) {
    const tableWithRecord = value.tables
      .filter((table) => table.records.length > 0)
      .sort((left, right) => {
        const leftRetained = left.records.length / Math.max(1, left.records_total);
        const rightRetained = right.records.length / Math.max(1, right.records_total);
        return rightRetained - leftRetained || left.table_id.localeCompare(right.table_id);
      })[0];
    if (tableWithRecord) {
      tableWithRecord.records.pop();
      tableWithRecord.records_truncated = true;
      value.truncated = true;
      text = render();
      continue;
    }
    const fieldWithProperty = [...value.tables]
      .sort((left, right) => left.table_id.localeCompare(right.table_id))
      .flatMap((table) => [...table.fields].sort((left, right) => left.field_id.localeCompare(right.field_id)))
      .find((field) => field.property !== null);
    if (fieldWithProperty) {
      fieldWithProperty.property = null;
      fieldWithProperty.property_truncated = true;
      value.truncated = true;
      text = render();
      continue;
    }
    throw new LarkDocError("malformed_response", "Bitable 欄位結構超過安全輸出上限");
  }
  return { text, truncated: value.truncated };
}

async function readBitable(
  api: ApiClient,
  parsed: ParsedLarkUrl,
  appToken: string,
): Promise<{ text: string; truncated: boolean }> {
  const appPath = `${API_ROOT}/bitable/v1/apps/${encodeURIComponent(appToken)}`;
  const tablePage = await listBitableItems(api, `${appPath}/tables`, 100, 500);
  const allTables = tablePage.items.map((table) => ({
    table_id: String(table.table_id ?? ""),
    name: String(table.name ?? table.table_name ?? table.table_id ?? ""),
  })).filter((table) => TABLE_RE.test(table.table_id));
  if (tablePage.items.length > 0 && allTables.length !== tablePage.items.length) {
    throw new LarkDocError("malformed_response", "Lark 回傳格式異常");
  }
  const selected = parsed.tableId
    ? allTables.filter((table) => table.table_id === parsed.tableId)
    : allTables.slice(0, 20);
  if (parsed.tableId && selected.length === 0) {
    if (tablePage.truncated) {
      throw new LarkDocError("network_error", "Bitable 資料表清單超過安全讀取上限，無法確認指定資料表");
    }
    throw new LarkDocError("not_found", "指定的 Bitable 資料表不存在");
  }
  let truncated = tablePage.truncated || (!parsed.tableId && allTables.length > selected.length);
  const tables: BitableTableOutput[] = [];
  let remainingRecords = 500;
  for (const [tableIndex, table] of selected.entries()) {
    const tablePath = `${appPath}/tables/${encodeURIComponent(table.table_id)}`;
    const [fieldPage, recordPage] = await Promise.all([
      listBitableItems(api, `${tablePath}/fields`, 100, 500),
      listBitableItems(
        api,
        `${tablePath}/records`,
        Math.max(1, Math.min(200, remainingRecords)),
        Math.max(1, remainingRecords),
        parsed.viewId ? { view_id: parsed.viewId } : {},
      ),
    ]);
    const fields = fieldPage.items.map((field) => {
      const fieldId = String(field.field_id ?? "");
      const fieldName = String(field.field_name ?? field.name ?? "");
      if (!ID_RE.test(fieldId) || !fieldName) {
        throw new LarkDocError("malformed_response", "Lark 回傳格式異常");
      }
      return {
        field_id: fieldId,
        field_name: fieldName,
        type: typeof field.type === "number" || typeof field.type === "string" ? field.type : null,
        is_primary: field.is_primary === true,
        property: field.property ?? null,
      };
    });
    const records = recordPage.items.map((record) => {
      const recordId = String(record.record_id ?? "");
      if (!ID_RE.test(recordId) || !record.fields || typeof record.fields !== "object" || Array.isArray(record.fields)) {
        throw new LarkDocError("malformed_response", "Lark 回傳格式異常");
      }
      return { record_id: recordId, fields: record.fields as Record<string, unknown> };
    });
    if (recordPage.truncated && recordPage.total === null) {
      throw new LarkDocError("malformed_response", "Bitable 資料列遭截斷，但 Lark 未回傳可稽核的總列數");
    }
    const recordsTotal = recordPage.total ?? records.length;
    if (recordsTotal < records.length) {
      throw new LarkDocError("malformed_response", "Lark 回傳格式異常");
    }
    remainingRecords = Math.max(0, remainingRecords - records.length);
    const omittedTables = remainingRecords === 0 && tableIndex < selected.length - 1;
    const recordsTruncated = recordPage.truncated;
    truncated ||= fieldPage.truncated || recordsTruncated || omittedTables;
    tables.push({
      table_id: table.table_id,
      name: table.name,
      fields,
      records,
      records_total: recordsTotal,
      records_returned: records.length,
      records_omitted: Math.max(0, recordsTotal - records.length),
      records_truncated: recordsTruncated,
    });
    if (remainingRecords === 0) break;
  }
  return serializeBitableOutput({
    format: "lark-bitable-read-v1",
    source_url: parsed.normalizedUrl,
    app_token: appToken,
    tables,
    truncated,
  });
}

export async function readDocument(args: {
  parsed: ParsedLarkUrl;
  accessToken: string;
  fetch?: FetchLike;
}): Promise<{ markdown: string; truncated: boolean; requests: number }> {
  const api = new ApiClient(args.accessToken, args.fetch ?? fetch, Date.now() + 60_000);
  let kind = args.parsed.kind;
  let token = args.parsed.token;
  let sheetId = args.parsed.sheetId;
  if (kind === "wiki") {
    const node = await api.json(`${API_ROOT}/wiki/v2/spaces/get_node?token=${encodeURIComponent(token)}`);
    const info = node.node ?? node;
    const objType = String(info.obj_type ?? "");
    const spaceId = String(info.space_id ?? "");
    token = String(info.obj_token ?? "");
    if (!["docx", "sheet", "bitable"].includes(objType) && ID_RE.test(spaceId)) {
      const spaceApi = new ApiClient(
        args.accessToken,
        args.fetch ?? fetch,
        Date.now() + 60_000,
        5000,
      );
      const result = await readWikiSpace(
        spaceApi,
        spaceId,
        new URL(args.parsed.normalizedUrl).hostname,
      );
      return { ...result, requests: api.requests + spaceApi.requests };
    }
    if (!TOKEN_RE.test(token) || !["docx", "sheet", "bitable"].includes(objType)) {
      throw new LarkDocError("unsupported", "此 Wiki 節點不是支援的 docx、sheet 或 Bitable");
    }
    kind = objType as "docx" | "sheet" | "bitable";
  }
  if (kind === "bitable") {
    const bitableApi = new ApiClient(
      args.accessToken,
      args.fetch ?? fetch,
      Date.now() + 60_000,
      60,
    );
    const result = await readBitable(bitableApi, args.parsed, token);
    return { markdown: result.text, truncated: result.truncated, requests: api.requests + bitableApi.requests };
  }
  if (kind === "docx") {
    const meta = await api.json(`${API_ROOT}/docx/v1/documents/${encodeURIComponent(token)}`);
    const title = String(meta.document?.title ?? meta.title ?? "Lark document");
    const blocks: any[] = [];
    let pageToken = "";
    let hitBlockLimit = false;
    do {
      const query = new URLSearchParams({ page_size: "500" });
      if (pageToken) query.set("page_token", pageToken);
      const page = await api.json(`${API_ROOT}/docx/v1/documents/${encodeURIComponent(token)}/blocks?${query}`);
      const items = Array.isArray(page.items) ? page.items : [];
      const remaining = 2000 - blocks.length;
      blocks.push(...items.slice(0, remaining));
      if (items.length > remaining || (blocks.length === 2000 && page.has_more)) hitBlockLimit = true;
      pageToken = String(page.page_token ?? "");
      if (blocks.length >= 2000) break;
      if (!page.has_more) pageToken = "";
    } while (pageToken);
    const converted = blocksToMarkdown(blocks);
    const output = `# ${title}\n\n${converted.markdown}`;
    const truncated = truncateOutput(output, hitBlockLimit ? "2000 blocks" : undefined);
    return { ...truncated, requests: api.requests };
  }
  const meta = await api.json(`${API_ROOT}/sheets/v2/spreadsheets/${encodeURIComponent(token)}/metainfo`);
  const sheets = Array.isArray(meta.sheets) ? meta.sheets : [];
  const selected = sheetId
    ? sheets.find((s: any) => String(s.sheetId ?? s.sheet_id) === sheetId)
    : [...sheets].sort((a: any, b: any) => Number(a.index ?? 0) - Number(b.index ?? 0))
      .find((s: any) => s.hidden !== true);
  if (!selected) throw new LarkDocError("not_found", "指定的工作表不存在");
  sheetId = String(selected.sheetId ?? selected.sheet_id);
  const valueData = await api.json(
    `${API_ROOT}/sheets/v2/spreadsheets/${encodeURIComponent(token)}/values/${encodeURIComponent(`${sheetId}!A1:Z300`)}`,
  );
  const values = valueData.valueRange?.values ?? valueData.values;
  if (!Array.isArray(values)) throw new LarkDocError("malformed_response", "Lark 回傳格式異常");
  const clipped = Number(selected.rowCount ?? selected.row_count ?? 0) > 300
    || Number(selected.columnCount ?? selected.column_count ?? 0) > 26;
  const md = sheetToMarkdown(
    String(meta.properties?.title ?? meta.spreadsheet?.title ?? meta.title ?? "Lark spreadsheet"),
    `${String(selected.title ?? sheetId)}${args.parsed.sheetId ? "" : "（未指定 sheet，已選第一個可見工作表）"}`,
    values,
    clipped,
  );
  const truncated = truncateOutput(md);
  return {
    markdown: truncated.markdown,
    truncated: clipped || truncated.truncated,
    requests: api.requests,
  };
}

export function safeAuditUrl(input: string): string {
  try {
    const url = new URL(input);
    return `${url.protocol}//${url.hostname}${url.pathname}`.slice(0, 500);
  } catch {
    return "[invalid-url]";
  }
}
