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
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join, relative, resolve, sep } from "node:path";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import {
  API_ROOT,
  LarkDocError,
  readDocument,
  type FetchLike,
  type ParsedLarkUrl,
} from "./lark-doc-lib.ts";

export const MIRROR_SCOPES = Object.freeze([
  "auth:user.id:read",
  "docx:document:readonly",
  "drive:drive.metadata:readonly",
  "offline_access",
  "sheets:spreadsheet:readonly",
  "wiki:wiki:readonly",
]);
export const MIRROR_REDIRECT_URI = "http://localhost:8788/lark/callback";
export const AUTHORIZE_ENDPOINT = "https://accounts.larksuite.com/open-apis/authen/v1/authorize";
export const TOKEN_ENDPOINT = `${API_ROOT}/authen/v2/oauth/token`;
export const TENANT_TOKEN_ENDPOINT = `${API_ROOT}/auth/v3/tenant_access_token/internal`;
export const USER_INFO_ENDPOINT = `${API_ROOT}/authen/v1/user_info`;
export const DEFAULT_REFRESH_SECRET = "lark-user-refresh-anya";
export const DEFAULT_PENDING_PATH =
  "/home/oldrabbit/.claude-bots/bots/anya/runtime/lark-mirror/oauth-pending.json";
export const DEFAULT_CONFIG_PATH =
  "/home/oldrabbit/.claude-bots/bots/anya/config/lark-mirror.json";
export const DEFAULT_STATE_PATH =
  "/home/oldrabbit/.claude-bots/bots/anya/runtime/lark-mirror/state.json";
export const DEFAULT_REFRESH_LOCK =
  "/home/oldrabbit/.claude-bots/bots/anya/runtime/lark-mirror/refresh.lock";
export const DEFAULT_VAULT_DIR =
  "/home/oldrabbit/Ocean/業務流/NOXCAT/lark-mirror";
export const APPROVED_WIKI_SPACES = Object.freeze([
  "7588969620657147413",
  "7589941241228332563",
  "7596207127715122709",
]);
export const REQUIRED_EXCLUDED_NODE_TOKENS = Object.freeze([
  "HvnGwj20bioK5vkqRPdjPOUlpgd",
  "JtSOwDNvHignubkb7QajDKJqpMf",
  "XAKMw3CSKiMl9okThDljorSnpqe",
  "W2vKwO475iy5Aqk3qy0jDbenp2g",
  "DND5w9X7siwJ8XkLoBvjoVOdpxb",
  "Ah58w7eKGiJ76CkfqIQj7ra4pMf",
  "LwHHwVAk0iG94fkx6F5jnoZipgc",
  "QNx0wXPVqi6M9rkELYTjv2xCp7d",
  "J8qWw63cJiBNpOkaNM0jMkappDF",
  "Lp4gwcdPliWKHPkcE2kjfbRCpqc",
]);

export interface SecretEnvelope {
  version: 1;
  access_token: string;
  access_expires_at: string;
  refresh_token: string;
  refresh_expires_at: string;
  verified_user_id: string;
  scope: string[];
  generation: number;
}

export interface OAuthPending {
  version: 1;
  state_hash: string;
  verifier: string;
  redirect_uri: typeof MIRROR_REDIRECT_URI;
  scope: string[];
  expires_at: string;
}

export interface SecretStore {
  access(name: string): Promise<string>;
  addVersion(name: string, value: string): Promise<void>;
}

export interface AccessTokenProvider {
  readonly kind: "tenant" | "user";
  accessToken(): Promise<string>;
}

export interface MirrorTransportProvider {
  readonly kind: "user-cli";
  readonly fetch: FetchLike;
}

export function createLarkCliFetch(
  execute: (argv: string[]) => Promise<string>,
  sleep: (milliseconds: number) => Promise<void> = Bun.sleep,
  clock: () => number = Date.now,
): FetchLike {
  let nextAllowedAt = 0;
  return async (input, init) => {
    const url = new URL(String(input));
    if (
      (init?.method ?? "GET") !== "GET"
      || url.origin !== "https://open.larksuite.com"
      || !url.pathname.startsWith("/open-apis/")
    ) {
      throw new LarkDocError("internal_error", "拒絕非唯讀 Lark CLI 請求");
    }
    const waitMs = nextAllowedAt - clock();
    if (waitMs > 0) await sleep(waitMs);
    const interval = url.pathname.includes("/wiki/v2/spaces/")
      && url.pathname.endsWith("/nodes") ? 750
      : url.pathname.includes("/docx/v1/documents/") ? 250
      : 100;
    nextAllowedAt = clock() + interval;
    try {
      const output = await execute([
        "lark-cli", "api", "GET", url.pathname,
        ...(url.searchParams.size
          ? ["--params", JSON.stringify(Object.fromEntries(url.searchParams.entries()))]
          : []),
        "--as", "user",
      ]);
      const jsonStart = output.indexOf("{");
      if (jsonStart < 0) throw new Error("missing JSON");
      const result = JSON.parse(output.slice(jsonStart));
      if (result?.ok !== true) {
        const code = Number(result?.error?.code ?? result?.code ?? 1);
        return new Response(JSON.stringify({ code }), {
          status: code === 99991400 ? 429 : 400,
          headers: { "content-type": "application/json" },
        });
      }
      return new Response(JSON.stringify({ code: 0, data: result.data ?? {} }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    } catch {
      throw new LarkDocError(
        "auth_failed",
        "Lark CLI user session 無法讀取或續期；鏡射已停止並告警",
      );
    }
  };
}

export interface AlertSink {
  send(kind: "refresh_failed" | "refresh_expiring" | "sync_failed", message: string): Promise<void>;
}

export interface LarkMirrorConfig {
  version: 1;
  vault_dir: string;
  wiki_spaces: string[];
  drive_folders: string[];
  excluded_node_tokens: string[];
  lark_host: string;
}

export interface MirrorSource {
  kind: "docx" | "sheet" | "mindnote" | "file";
  token: string;
  node_token?: string;
  space_id?: string;
  title: string;
  source_url: string;
  last_edit_time: string;
  relative_path?: string;
}

export interface RadarCleanupRecord {
  path: string;
  kept_rowid: number;
  kept_slug_before_upsert: string;
  kept_slug_after_upsert: string;
  removed_rowid: number;
  removed_slug: string;
}

export interface RadarIngestResult {
  radar_action: "inserted" | "updated";
  radar_duplicates_removed: RadarCleanupRecord[];
}

export interface WikiDiscoveryStats {
  space_id: string;
  space_name: string;
  parent_expansions: number;
  unique_parent_tokens: number;
  duplicate_parent_skips: number;
  nodes: number;
  unique_nodes: number;
  duplicate_nodes: number;
  docx: number;
  shortcuts: number;
  shortcut_children_skipped: number;
  excluded: number;
  elapsed_ms: number;
  repeated_parent_tokens: Array<{ node_token: string; attempts: number }>;
}

export interface WikiDiscoveryProgress extends WikiDiscoveryStats {
  status: "running" | "complete";
  queued_parents: number;
}

export interface DiscoveryAccounting {
  wiki_nodes: number;
  mirror_sources: number;
  excluded: number;
  unsupported: number;
  duplicate_nodes: number;
  deduplicated_sources: number;
}

export interface UnmirroredNode {
  space_id: string;
  node_token: string;
  title: string;
  reason:
    | "configured_exclusion"
    | "unsupported_obj_type"
    | "invalid_obj_token"
    | "duplicate_object_source";
  obj_type: string;
}

export interface MirrorState {
  version: 1;
  documents: Record<string, {
    last_edit_time: string;
    output_path: string;
    content_sha256: string;
    ingested_at: string;
  }>;
  quarantined?: Record<string, {
    title: string;
    source_url: string;
    reasons: string[];
    detected_at: string;
  }>;
}

const TOKEN_RE = /^[A-Za-z0-9_-]{8,128}$/;
const ID_RE = /^[A-Za-z0-9_-]{2,128}$/;
const SAFE_SEGMENT_RE = /[^\p{L}\p{N}._ -]+/gu;

function exactScopes(value: unknown): string[] {
  const scopes = (Array.isArray(value) ? value : String(value ?? "").split(/[\s,]+/))
    .filter((item): item is string => typeof item === "string" && item.length > 0)
    .sort();
  const expected = [...MIRROR_SCOPES];
  if (
    scopes.length !== expected.length
    || new Set(scopes).size !== scopes.length
    || scopes.some((scope, index) => scope !== expected[index])
  ) throw new LarkDocError("auth_failed", "Lark 授權 scope 不是核准的唯讀集合");
  return scopes;
}

function positiveSeconds(value: unknown): number {
  const result = Number(value);
  if (!Number.isFinite(result) || result <= 0) {
    throw new LarkDocError("malformed_response", "Lark token 回傳格式異常");
  }
  return result;
}

function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function sha256url(value: string): string {
  return createHash("sha256").update(value).digest("base64url");
}

function constantEqual(left: string, right: string): boolean {
  const a = Buffer.from(left);
  const b = Buffer.from(right);
  return a.length === b.length && timingSafeEqual(a, b);
}

function secureParent(path: string): void {
  const parent = dirname(path);
  mkdirSync(parent, { recursive: true, mode: 0o700 });
  const stat = lstatSync(parent);
  if (
    !stat.isDirectory() || stat.isSymbolicLink() || (stat.mode & 0o077) !== 0
    || (process.getuid && stat.uid !== process.getuid())
  ) {
    throw new LarkDocError("auth_failed", "Lark mirror runtime 目錄權限不安全");
  }
}

export function atomicWriteJson(path: string, value: unknown, mode = 0o600): void {
  secureParent(path);
  if (existsSync(path)) {
    const stat = lstatSync(path);
    if (
      !stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o077) !== 0
      || (process.getuid && stat.uid !== process.getuid())
    ) throw new LarkDocError("auth_failed", "Lark mirror runtime 檔案權限不安全");
  }
  const temp = join(dirname(path), `.${basename(path)}.${process.pid}.${randomBytes(6).toString("hex")}.tmp`);
  let fd = -1;
  try {
    fd = openSync(
      temp,
      fsConstants.O_WRONLY | fsConstants.O_CREAT | fsConstants.O_EXCL | fsConstants.O_NOFOLLOW,
      mode,
    );
    writeFileSync(fd, `${JSON.stringify(value, null, 2)}\n`, "utf8");
    fsyncSync(fd);
    closeSync(fd);
    fd = -1;
    renameSync(temp, path);
    const dirfd = openSync(dirname(path), fsConstants.O_RDONLY | fsConstants.O_DIRECTORY);
    try { fsyncSync(dirfd); } finally { closeSync(dirfd); }
  } finally {
    if (fd >= 0) closeSync(fd);
    if (existsSync(temp)) unlinkSync(temp);
  }
}

function readRuntimeJson<T>(path: string): T {
  try {
    const stat = lstatSync(path);
    if (
      !stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o077) !== 0
      || (process.getuid && stat.uid !== process.getuid())
    ) throw new Error("mode");
    return JSON.parse(readFileSync(path, "utf8")) as T;
  } catch {
    throw new LarkDocError("auth_failed", "Lark mirror runtime 狀態不存在或不安全");
  }
}

const HOST_LABEL_RE = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

function isLarkSuiteHost(host: string): boolean {
  if (host.length > 253) return false;
  const labels = host.split(".");
  if (
    labels.length < 3
    || labels.at(-2)?.toLowerCase() !== "larksuite"
    || labels.at(-1)?.toLowerCase() !== "com"
  ) {
    return false;
  }
  return labels.slice(0, -2).every((label) => HOST_LABEL_RE.test(label.toLowerCase()));
}

export function validateConfig(raw: unknown): LarkMirrorConfig {
  const value = raw as Partial<LarkMirrorConfig> | null;
  if (
    !value || value.version !== 1
    || !Array.isArray(value.wiki_spaces) || !Array.isArray(value.drive_folders)
    || !Array.isArray(value.excluded_node_tokens)
    || typeof value.vault_dir !== "string" || !value.vault_dir
    || typeof value.lark_host !== "string"
    || !isLarkSuiteHost(value.lark_host)
    || value.wiki_spaces.some((id) => typeof id !== "string" || !ID_RE.test(id))
    || value.drive_folders.some((id) => typeof id !== "string" || !ID_RE.test(id))
    || value.excluded_node_tokens.some((id) => typeof id !== "string" || !ID_RE.test(id))
    || new Set(value.wiki_spaces).size !== value.wiki_spaces.length
    || new Set(value.drive_folders).size !== value.drive_folders.length
    || new Set(value.excluded_node_tokens).size !== value.excluded_node_tokens.length
    || value.wiki_spaces.some((id) => !APPROVED_WIKI_SPACES.includes(id))
    || REQUIRED_EXCLUDED_NODE_TOKENS.some((id) => !value.excluded_node_tokens.includes(id))
  ) throw new LarkDocError("internal_error", "Lark mirror 白名單設定無效");
  if (!value.wiki_spaces.length && !value.drive_folders.length) {
    throw new LarkDocError("permission_denied", "Lark mirror 白名單為空；已 fail-closed，不會全域抓取");
  }
  return value as LarkMirrorConfig;
}

export function loadConfig(path = DEFAULT_CONFIG_PATH): LarkMirrorConfig {
  try {
    return validateConfig(JSON.parse(readFileSync(path, "utf8")));
  } catch (error) {
    if (error instanceof LarkDocError) throw error;
    throw new LarkDocError("permission_denied", "缺少 Lark mirror 白名單設定；已 fail-closed");
  }
}

export function createMirrorAuthorization(
  appId: string,
  pendingPath = DEFAULT_PENDING_PATH,
  now = Date.now(),
): string {
  const state = randomBytes(32).toString("base64url");
  const verifier = randomBytes(48).toString("base64url");
  const pending: OAuthPending = {
    version: 1,
    state_hash: sha256url(state),
    verifier,
    redirect_uri: MIRROR_REDIRECT_URI,
    scope: [...MIRROR_SCOPES],
    expires_at: new Date(now + 5 * 60_000).toISOString(),
  };
  atomicWriteJson(pendingPath, pending);
  const url = new URL(AUTHORIZE_ENDPOINT);
  url.searchParams.set("client_id", appId);
  url.searchParams.set("redirect_uri", MIRROR_REDIRECT_URI);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("scope", MIRROR_SCOPES.join(" "));
  url.searchParams.set("state", state);
  url.searchParams.set("code_challenge", sha256url(verifier));
  url.searchParams.set("code_challenge_method", "S256");
  return url.toString();
}

function parseCallback(input: string): { code: string; state: string } {
  let url: URL;
  try { url = new URL(input.trim()); } catch {
    throw new LarkDocError("auth_failed", "請貼上瀏覽器網址列中的完整 callback URL");
  }
  const expected = new URL(MIRROR_REDIRECT_URI);
  if (
    url.protocol !== expected.protocol || url.hostname !== expected.hostname
    || url.port !== expected.port || url.pathname !== expected.pathname
    || url.username || url.password || url.hash || url.searchParams.has("error")
    || url.searchParams.getAll("code").length !== 1
    || url.searchParams.getAll("state").length !== 1
  ) throw new LarkDocError("auth_failed", "OAuth callback URL 驗證失敗");
  const code = url.searchParams.get("code") ?? "";
  const state = url.searchParams.get("state") ?? "";
  if (!code || !state) throw new LarkDocError("auth_failed", "OAuth callback 缺 code/state");
  return { code, state };
}

async function responseJson(response: Response): Promise<Record<string, any>> {
  let payload: any;
  try { payload = await response.json(); } catch {
    throw new LarkDocError("malformed_response", "Lark 回傳格式異常");
  }
  if (!response.ok || (payload?.code !== undefined && payload.code !== 0)) {
    const code = Number(payload?.code);
    if (response.status === 401 || [99991668, 99991669].includes(code)) {
      throw new LarkDocError("auth_failed", "Lark 憑證已失效或無權存取");
    }
    if (code === 131006) {
      throw new LarkDocError(
        "permission_denied",
        "Lark Wiki 權限不足（131006）；請確認 Anya-bot 已加入該知識庫並具有讀取權限",
      );
    }
    if (response.status === 429 || code === 99991400) {
      throw new LarkDocError("rate_limited", "Lark API rate limit");
    }
    throw new LarkDocError("malformed_response", "Lark API 回傳失敗");
  }
  return payload?.data && typeof payload.data === "object" ? payload.data : payload;
}

function envelopeFromToken(payload: Record<string, any>, userId: string, generation: number): SecretEnvelope {
  const now = Date.now();
  const result: SecretEnvelope = {
    version: 1,
    access_token: String(payload.access_token ?? ""),
    access_expires_at: new Date(
      now + positiveSeconds(payload.expires_in) * 1000,
    ).toISOString(),
    refresh_token: String(payload.refresh_token ?? ""),
    refresh_expires_at: new Date(
      now + positiveSeconds(payload.refresh_token_expires_in ?? payload.refresh_expires_in) * 1000,
    ).toISOString(),
    verified_user_id: userId,
    scope: exactScopes(payload.scope),
    generation,
  };
  if (!result.access_token || !result.refresh_token || !userId) {
    throw new LarkDocError("malformed_response", "Lark token 回傳缺少 access/refresh token 或 user");
  }
  return result;
}

export async function tenantAccessToken(args: {
  appId: string;
  appSecret: string;
  fetch?: FetchLike;
}): Promise<string> {
  // Secret Manager values may contain a trailing newline. Keep this defensive
  // trim even after the stored value is repaired.
  const appId = args.appId.trim();
  const appSecret = args.appSecret.trim();
  if (!appId || !appSecret) {
    throw new LarkDocError("auth_failed", "Lark 應用設定為空");
  }
  const payload = await responseJson(await (args.fetch ?? fetch)(TENANT_TOKEN_ENDPOINT, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      app_id: appId,
      app_secret: appSecret,
    }),
    signal: AbortSignal.timeout(20_000),
  }));
  const token = String(payload.tenant_access_token ?? "");
  positiveSeconds(payload.expire ?? payload.expires_in);
  if (!token) throw new LarkDocError("malformed_response", "Lark tenant token 回傳格式異常");
  return token;
}

export async function finishMirrorAuthorization(args: {
  callbackUrl: string;
  appId: string;
  appSecret: string;
  expectedUserId: string;
  secrets: SecretStore;
  secretName?: string;
  pendingPath?: string;
  fetch?: FetchLike;
}): Promise<void> {
  const path = args.pendingPath ?? DEFAULT_PENDING_PATH;
  const pending = readRuntimeJson<OAuthPending>(path);
  unlinkSync(path);
  const { code, state } = parseCallback(args.callbackUrl);
  if (
    pending.version !== 1 || pending.redirect_uri !== MIRROR_REDIRECT_URI
    || Date.parse(pending.expires_at) <= Date.now()
    || !constantEqual(sha256url(state), pending.state_hash)
  ) throw new LarkDocError("auth_failed", "OAuth 授權狀態不符或已過期");
  exactScopes(pending.scope);
  const fetcher = args.fetch ?? fetch;
  const token = await responseJson(await fetcher(TOKEN_ENDPOINT, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      grant_type: "authorization_code",
      client_id: args.appId,
      client_secret: args.appSecret,
      code,
      redirect_uri: MIRROR_REDIRECT_URI,
      code_verifier: pending.verifier,
      scope: MIRROR_SCOPES.join(" "),
    }),
  }));
  const user = await responseJson(await fetcher(USER_INFO_ENDPOINT, {
    headers: { authorization: `Bearer ${String(token.access_token ?? "")}` },
  }));
  const userId = String(user.user_id ?? user.open_id ?? "");
  if (!userId || userId !== args.expectedUserId) {
    throw new LarkDocError("auth_failed", "授權者不是設定的老兔 Lark 帳號；未保存 token");
  }
  const envelope = envelopeFromToken(token, userId, 1);
  await args.secrets.addVersion(args.secretName ?? DEFAULT_REFRESH_SECRET, JSON.stringify(envelope));
}

export function parseEnvelope(raw: string, expectedUserId: string): SecretEnvelope {
  let value: SecretEnvelope;
  try { value = JSON.parse(raw); } catch {
    throw new LarkDocError("auth_failed", "GCP 中的 Lark refresh secret 格式錯誤");
  }
  if (
    value.version !== 1 || !value.access_token || !value.refresh_token
    || value.verified_user_id !== expectedUserId
    || !Number.isInteger(value.generation) || value.generation < 1
    || !Number.isFinite(Date.parse(value.access_expires_at))
    || Date.parse(value.refresh_expires_at) <= Date.now()
  ) throw new LarkDocError("auth_failed", "GCP 中的 Lark refresh secret 已失效");
  exactScopes(value.scope);
  return value;
}

export async function refreshAccessToken(args: {
  appId: string;
  appSecret: string;
  expectedUserId: string;
  secrets: SecretStore;
  alerts: AlertSink;
  secretName?: string;
  lockPath?: string;
  fetch?: FetchLike;
}): Promise<{ accessToken: string; envelope: SecretEnvelope }> {
  const release = await acquireRefreshLock(args.lockPath ?? DEFAULT_REFRESH_LOCK);
  try {
  const secretName = args.secretName ?? DEFAULT_REFRESH_SECRET;
  let current: SecretEnvelope;
  try {
    current = parseEnvelope(await args.secrets.access(secretName), args.expectedUserId);
  } catch (error) {
    await args.alerts.send("refresh_failed", "Lark refresh secret 無法讀取或已過期，請重新授權");
    throw error;
  }
  if (Date.parse(current.refresh_expires_at) < Date.now() + 7 * 86_400_000) {
    await args.alerts.send("refresh_expiring", "Lark 使用者授權將於 7 天內到期，請安排重新授權");
  }
  if (Date.parse(current.access_expires_at) > Date.now() + 5 * 60_000) {
    return { accessToken: current.access_token, envelope: current };
  }
  let token: Record<string, any>;
  try {
    token = await responseJson(await (args.fetch ?? fetch)(TOKEN_ENDPOINT, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        grant_type: "refresh_token",
        client_id: args.appId,
        client_secret: args.appSecret,
        refresh_token: current.refresh_token,
        scope: MIRROR_SCOPES.join(" "),
      }),
    }));
  } catch (error) {
    await args.alerts.send("refresh_failed", "Lark refresh 失敗，鏡射已停止；可能需要重新授權");
    throw error;
  }
  const rotated = envelopeFromToken(token, current.verified_user_id, current.generation + 1);
  try {
    // Secret Manager versions are immutable: a valid old version is never
    // overwritten with malformed data. The new access token is not returned
    // until the rotated refresh token is durably added.
    await args.secrets.addVersion(secretName, JSON.stringify(rotated));
  } catch {
    await args.alerts.send(
      "refresh_failed",
      "Lark refresh 已成功但新 refresh token 回存 GCP 失敗；鏡射已停止，請立即重新授權",
    );
    throw new LarkDocError("auth_failed", "Lark refresh token 輪替未能持久化");
  }
  return { accessToken: String(token.access_token ?? ""), envelope: rotated };
  } finally {
    release();
  }
}

async function acquireRefreshLock(path: string, timeoutMs = 10_000): Promise<() => void> {
  secureParent(path);
  const nonce = randomBytes(16).toString("hex");
  const started = Date.now();
  while (true) {
    try {
      const fd = openSync(
        path,
        fsConstants.O_WRONLY | fsConstants.O_CREAT | fsConstants.O_EXCL | fsConstants.O_NOFOLLOW,
        0o600,
      );
      try { writeFileSync(fd, `${process.pid}:${nonce}\n`); } finally { closeSync(fd); }
      return () => {
        try {
          if (readFileSync(path, "utf8").trim() === `${process.pid}:${nonce}`) unlinkSync(path);
        } catch {
          // A missing/replaced lock is safer than deleting another process's lock.
        }
      };
    } catch (error: any) {
      if (error?.code !== "EEXIST") throw error;
      if (Date.now() - started >= timeoutMs) {
        throw new LarkDocError("auth_failed", "Lark refresh lock 忙碌；本輪已停止");
      }
      await Bun.sleep(40);
    }
  }
}

class ReadonlyApi {
  private requests = 0;
  constructor(private token: string, private fetcher: FetchLike) {}

  async get(path: string, params: Record<string, string> = {}): Promise<Record<string, any>> {
    if (
      !/^\/(?:wiki\/v2\/spaces\/[A-Za-z0-9_-]+(?:\/nodes)?|drive\/v1\/files)$/.test(path)
      || ++this.requests > 5000
    ) throw new LarkDocError("internal_error", "拒絕非白名單 Lark GET endpoint");
    const url = new URL(`${API_ROOT}${path}`);
    for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);
    for (let attempt = 0; ; attempt++) {
      try {
        return await responseJson(await this.fetcher(url, {
          method: "GET",
          headers: { authorization: `Bearer ${this.token}` },
          signal: AbortSignal.timeout(20_000),
        }));
      } catch (error) {
        if (
          error instanceof LarkDocError && error.kind === "rate_limited"
          && attempt < 4
        ) {
          await Bun.sleep(250 * (2 ** attempt) + Math.floor(Math.random() * 100));
          continue;
        }
        throw error;
      }
    }
  }
}

async function paged(
  api: ReadonlyApi,
  path: string,
  params: Record<string, string>,
): Promise<any[]> {
  const output: any[] = [];
  let pageToken = "";
  do {
    const page = await api.get(path, { ...params, page_size: "50", ...(pageToken ? { page_token: pageToken } : {}) });
    const candidates = page.items ?? page.files ?? page.nodes ?? page.spaces;
    const items = Array.isArray(candidates) ? candidates : [];
    output.push(...items);
    pageToken = page.has_more ? String(page.page_token ?? page.next_page_token ?? "") : "";
    if (page.has_more && !pageToken) throw new LarkDocError("malformed_response", "Lark 分頁缺 page_token");
  } while (pageToken);
  return output;
}

function isoTime(value: unknown): string {
  const raw = String(value ?? "");
  const numeric = Number(raw);
  const millis = Number.isFinite(numeric) && numeric > 0
    ? numeric * (numeric > 10_000_000_000 ? 1 : 1000)
    : Date.parse(raw);
  return Number.isFinite(millis) ? new Date(millis).toISOString() : "1970-01-01T00:00:00.000Z";
}

export async function discoverSources(args: {
  config: LarkMirrorConfig;
  accessToken: string;
  fetch?: FetchLike;
  onProgress?: (progress: WikiDiscoveryProgress) => void;
}): Promise<{
  spaces: Array<{ id: string; name: string }>;
  sources: MirrorSource[];
  excluded: number;
  wiki_stats: WikiDiscoveryStats[];
  accounting: DiscoveryAccounting;
  unmirrored_nodes: UnmirroredNode[];
}> {
  const api = new ReadonlyApi(args.accessToken, args.fetch ?? fetch);
  const spaces: Array<{ id: string; name: string }> = [];
  const sources: MirrorSource[] = [];
  const wikiStats: WikiDiscoveryStats[] = [];
  const unmirroredNodes: UnmirroredNode[] = [];
  const excluded = new Set(args.config.excluded_node_tokens);
  let excludedCount = 0;
  let unsupportedCount = 0;
  let uniqueWikiNodes = 0;
  let duplicateWikiNodes = 0;
  for (const spaceId of args.config.wiki_spaces) {
    // GET /wiki/v2/spaces/:space_id returns data.space, unlike the collection
    // endpoints consumed by paged(), whose items live directly below data.
    const spaceResponse = await api.get(`/wiki/v2/spaces/${spaceId}`);
    const space = spaceResponse.space;
    if (!space || typeof space !== "object" || String(space.space_id ?? "") !== spaceId) {
      throw new LarkDocError("permission_denied", `白名單 Wiki space 不可見：${spaceId}`);
    }
    const spaceName = String(space.name ?? "").trim();
    if (!spaceName) throw new LarkDocError("permission_denied", `白名單 Wiki space 名稱為空：${spaceId}`);
    spaces.push({ id: spaceId, name: spaceName });
    const queue: Array<{ parent?: string; path: string }> = [{ path: spaceName }];
    const expandedParents = new Set<string>();
    const seenNodeTokens = new Set<string>();
    const parentAttempts = new Map<string, number>();
    const startedAt = Date.now();
    let lastProgressAt = startedAt;
    let parentExpansions = 0;
    let duplicateParentSkips = 0;
    let spaceNodeCount = 0;
    let spaceUniqueNodeCount = 0;
    let spaceDuplicateNodeCount = 0;
    let spaceDocxCount = 0;
    let shortcutCount = 0;
    let shortcutChildrenSkipped = 0;
    let spaceExcludedCount = 0;

    const stats = (status: "running" | "complete"): WikiDiscoveryProgress => ({
      status,
      space_id: spaceId,
      space_name: spaceName,
      parent_expansions: parentExpansions,
      unique_parent_tokens: expandedParents.size - (expandedParents.has("<root>") ? 1 : 0),
      duplicate_parent_skips: duplicateParentSkips,
      nodes: spaceNodeCount,
      unique_nodes: spaceUniqueNodeCount,
      duplicate_nodes: spaceDuplicateNodeCount,
      docx: spaceDocxCount,
      shortcuts: shortcutCount,
      shortcut_children_skipped: shortcutChildrenSkipped,
      excluded: spaceExcludedCount,
      elapsed_ms: Date.now() - startedAt,
      queued_parents: queue.length,
      repeated_parent_tokens: [...parentAttempts.entries()]
        .filter(([, attempts]) => attempts > 1)
        .sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0]))
        .slice(0, 10)
        .map(([node_token, attempts]) => ({ node_token, attempts })),
    });

    while (queue.length) {
      const current = queue.shift()!;
      const parentKey = current.parent ?? "<root>";
      parentAttempts.set(parentKey, (parentAttempts.get(parentKey) ?? 0) + 1);
      if (expandedParents.has(parentKey)) {
        duplicateParentSkips++;
        continue;
      }
      expandedParents.add(parentKey);
      const nodes = await paged(api, `/wiki/v2/spaces/${spaceId}/nodes`, {
        ...(current.parent ? { parent_node_token: current.parent } : {}),
      });
      parentExpansions++;
      spaceNodeCount += nodes.length;
      for (const node of nodes) {
        const nodeToken = String(node.node_token ?? "");
        const title = String(node.title ?? nodeToken);
        const path = `${current.path}/${title}`;
        const duplicateNode = ID_RE.test(nodeToken) && seenNodeTokens.has(nodeToken);
        if (duplicateNode) {
          duplicateWikiNodes++;
          spaceDuplicateNodeCount++;
        } else {
          if (ID_RE.test(nodeToken)) seenNodeTokens.add(nodeToken);
          uniqueWikiNodes++;
          spaceUniqueNodeCount++;
        }
        const nodeType = String(node.node_type ?? "");
        const isShortcut = nodeType === "shortcut";
        if (!duplicateNode && isShortcut) shortcutCount++;
        if (duplicateNode && node.has_child && ID_RE.test(nodeToken) && !isShortcut) {
          // Retain duplicate queue attempts so the parent visited guard and
          // its diagnostics still prove repeated expansion was suppressed.
          queue.push({ parent: nodeToken, path });
        }
        if (duplicateNode) continue;
        if (excluded.has(nodeToken)) {
          excludedCount++;
          spaceExcludedCount++;
          unmirroredNodes.push({
            space_id: spaceId,
            node_token: nodeToken,
            title,
            reason: "configured_exclusion",
            obj_type: String(node.obj_type ?? ""),
          });
          continue;
        }
        if (node.has_child && ID_RE.test(nodeToken)) {
          if (isShortcut) {
            shortcutChildrenSkipped++;
          } else {
            queue.push({ parent: nodeToken, path });
          }
        }
        const type = String(node.obj_type ?? "");
        const token = String(node.obj_token ?? "");
        if (type === "docx" && TOKEN_RE.test(token)) {
          spaceDocxCount++;
          sources.push({
            kind: "docx",
            token,
            node_token: nodeToken,
            space_id: spaceId,
            title,
            source_url: `https://${args.config.lark_host}/wiki/${nodeToken}`,
            last_edit_time: isoTime(node.obj_edit_time ?? node.node_edit_time),
            relative_path: path,
          });
        } else if (type === "mindnote" && TOKEN_RE.test(token)) {
          sources.push({
            kind: "mindnote",
            token,
            node_token: nodeToken,
            space_id: spaceId,
            title,
            source_url: `https://${args.config.lark_host}/wiki/${nodeToken}`,
            last_edit_time: isoTime(node.obj_edit_time ?? node.node_edit_time),
            relative_path: path,
          });
        } else if (type === "file" && TOKEN_RE.test(token)) {
          sources.push({
            kind: "file",
            token,
            node_token: nodeToken,
            space_id: spaceId,
            title,
            source_url: `https://${args.config.lark_host}/wiki/${nodeToken}`,
            last_edit_time: isoTime(node.obj_edit_time ?? node.node_edit_time),
            relative_path: path,
          });
        } else if (type === "sheet" && TOKEN_RE.test(token)) {
          sources.push({
            kind: "sheet",
            token,
            node_token: nodeToken,
            space_id: spaceId,
            title,
            source_url: `https://${args.config.lark_host}/wiki/${nodeToken}`,
            last_edit_time: isoTime(node.obj_edit_time ?? node.node_edit_time),
            relative_path: path,
          });
        } else {
          unsupportedCount++;
          unmirroredNodes.push({
            space_id: spaceId,
            node_token: nodeToken,
            title,
            reason: ["docx", "mindnote", "file", "sheet"].includes(type)
              ? "invalid_obj_token"
              : "unsupported_obj_type",
            obj_type: type,
          });
        }
      }
      const now = Date.now();
      if (
        parentExpansions === 1
        || parentExpansions % 10 === 0
        || now - lastProgressAt >= 10_000
      ) {
        args.onProgress?.(stats("running"));
        lastProgressAt = now;
      }
    }
    if (spaceNodeCount === 0) {
      throw new LarkDocError(
        "permission_denied",
        `白名單 Wiki space 回傳 code=0 空節點清單，視為權限異常：${spaceId}`,
      );
    }
    const complete = stats("complete");
    const { status: _status, queued_parents: _queued, ...finalStats } = complete;
    wikiStats.push(finalStats);
    args.onProgress?.(complete);
  }
  for (const folderToken of args.config.drive_folders) {
    const queue: Array<{ token: string; path: string }> = [{ token: folderToken, path: `drive-${folderToken}` }];
    while (queue.length) {
      const folder = queue.shift()!;
      const files = await paged(api, "/drive/v1/files", { folder_token: folder.token });
      for (const file of files) {
        const type = String(file.type ?? "");
        const token = String(file.token ?? file.file_token ?? "");
        const title = String(file.name ?? file.title ?? token);
        const path = `${folder.path}/${title}`;
        if (type === "folder" && ID_RE.test(token)) {
          queue.push({ token, path });
        } else if (["docx", "sheet", "file"].includes(type) && TOKEN_RE.test(token)) {
          sources.push({
            kind: type as MirrorSource["kind"],
            token,
            title,
            source_url: String(file.url ?? `https://${args.config.lark_host}/${type}/${token}`),
            last_edit_time: isoTime(file.modified_time ?? file.edit_time),
            relative_path: path,
          });
        }
      }
    }
  }
  // Keep one physical mirror per underlying object, but make every additional
  // Wiki node that aliases that object explicit in unmirrored_nodes instead of
  // silently dropping it or overwriting the first node's correct path.
  const unique = new Map<string, MirrorSource>();
  let deduplicatedSources = 0;
  let wikiDeduplicatedSources = 0;
  for (const source of sources) {
    const key = `${source.kind}:${source.token}`;
    if (unique.has(key)) {
      deduplicatedSources++;
      if (source.node_token) {
        wikiDeduplicatedSources++;
        unmirroredNodes.push({
          space_id: source.space_id ?? "",
          node_token: source.node_token,
          title: source.title,
          reason: "duplicate_object_source",
          obj_type: source.kind,
        });
      }
      continue;
    }
    unique.set(key, source);
  }
  const mirrorSources = [...unique.values()];
  if (uniqueWikiNodes !== mirrorSources.filter((source) => source.node_token).length
    + excludedCount + unsupportedCount + wikiDeduplicatedSources) {
    throw new LarkDocError(
      "internal_error",
      "Lark Wiki discovery 完整性不符：節點未全部歸類，已停止鏡射",
    );
  }
  return {
    spaces,
    sources: mirrorSources,
    excluded: excludedCount,
    wiki_stats: wikiStats,
    accounting: {
      wiki_nodes: uniqueWikiNodes,
      mirror_sources: mirrorSources.length,
      excluded: excludedCount,
      unsupported: unsupportedCount,
      duplicate_nodes: duplicateWikiNodes,
      deduplicated_sources: deduplicatedSources,
    },
    unmirrored_nodes: unmirroredNodes,
  };
}

const SENSITIVE_PATTERNS: ReadonlyArray<{ reason: string; pattern: RegExp }> = [
  { reason: "private_key", pattern: /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/i },
  { reason: "private_key", pattern: /\b0x[a-f0-9]{64}\b/i },
  { reason: "wallet_address", pattern: /\b0x[a-f0-9]{40}\b/i },
  { reason: "api_key", pattern: /\b(?:AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{20,})\b/ },
  {
    reason: "credential",
    pattern: /\b(?:api[_ -]?key|client[_ -]?secret|password|passwd|密碼|密码|私鑰|私钥)\b\s*[:=：]\s*\S+/i,
  },
  {
    reason: "financial_amount",
    pattern: /(?:[$¥€£]\s*\d[\d,.]*|\b\d[\d,.]*\s*(?:USD|USDT|USDC|BTC|ETH|TWD|CNY|RMB)\b)/i,
  },
];

export function scanSensitiveContent(content: string): string[] {
  return [...new Set(SENSITIVE_PATTERNS
    .filter(({ pattern }) => pattern.test(content))
    .map(({ reason }) => reason))];
}

function safeSegment(value: string): string {
  const safe = value.normalize("NFKC").replace(SAFE_SEGMENT_RE, "-").replace(/\s+/g, " ").trim();
  return (safe || "untitled").slice(0, 100);
}

function yaml(value: string): string {
  return JSON.stringify(value);
}

export function renderMirrorMarkdown(source: MirrorSource, body: string, fetched: string): string {
  const withImages = body.replace(
    /!\[Lark image: ([^\]]+)\]/g,
    (_match, id) => `[Lark image](${source.source_url}#block-${encodeURIComponent(String(id))})`,
  );
  return [
    "---",
    `source: ${yaml(source.source_url)}`,
    `lark_doc_id: ${yaml(source.token)}`,
    `lark_type: ${yaml(source.kind)}`,
    `last_edit_time: ${yaml(source.last_edit_time)}`,
    `fetched: ${yaml(fetched)}`,
    "---",
    "",
    withImages,
    "",
  ].join("\n");
}

function outputPath(config: LarkMirrorConfig, source: MirrorSource): string {
  const segments = (source.relative_path ?? source.title).split("/").map(safeSegment);
  const stem = `${segments.pop() ?? safeSegment(source.title)}--${source.token.slice(-8)}.md`;
  const root = resolve(config.vault_dir);
  const path = resolve(root, ...segments, stem);
  if (!path.startsWith(`${root}/`)) throw new LarkDocError("internal_error", "鏡射輸出路徑越界");
  return path;
}

function ensureVaultParent(rootValue: string, path: string): void {
  const root = resolve(rootValue);
  mkdirSync(root, { recursive: true });
  const rel = relative(root, dirname(path));
  if (rel.startsWith("..") || rel.split(sep).includes("..")) {
    throw new LarkDocError("internal_error", "鏡射輸出路徑越界");
  }
  let current = root;
  for (const segment of rel.split(sep).filter(Boolean)) {
    const stat = lstatSync(current);
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      throw new LarkDocError("internal_error", "鏡射 vault 路徑含不安全 symlink");
    }
    current = join(current, segment);
    if (!existsSync(current)) mkdirSync(current);
  }
  const parent = lstatSync(current);
  if (!parent.isDirectory() || parent.isSymbolicLink()) {
    throw new LarkDocError("internal_error", "鏡射 vault 路徑含不安全 symlink");
  }
  if (existsSync(path) && lstatSync(path).isSymbolicLink()) {
    throw new LarkDocError("internal_error", "鏡射輸出檔是 symlink，已拒絕覆寫");
  }
}

function loadState(path: string): MirrorState {
  if (!existsSync(path)) return { version: 1, documents: {}, quarantined: {} };
  const state = readRuntimeJson<MirrorState>(path);
  if (state.version !== 1 || !state.documents || typeof state.documents !== "object") {
    throw new LarkDocError("internal_error", "Lark mirror state 格式錯誤");
  }
  return state;
}

export async function mirrorSources(args: {
  config: LarkMirrorConfig;
  statePath?: string;
  sources: MirrorSource[];
  accessToken: string;
  fetch?: FetchLike;
  ingest: (
    path: string,
    relocatedFrom?: string,
    radarOnly?: boolean,
  ) => Promise<RadarIngestResult>;
  now?: string;
  expectedSourceCount?: number;
}): Promise<{
  written: number;
  skipped: number;
  skipped_by_reason: { unchanged: number };
  metadataOnly: number;
  quarantined: number;
  failed: number;
  processed: number;
  expected: number;
  relocated: number;
  radar_inserted: number;
  radar_updated: number;
  radar_deduplicated: number;
  radar_cleanup: RadarCleanupRecord[];
  paths: string[];
}> {
  const statePath = args.statePath ?? DEFAULT_STATE_PATH;
  const state = loadState(statePath);
  const now = args.now ?? new Date().toISOString();
  let written = 0;
  let skipped = 0;
  let metadataOnly = 0;
  let quarantined = 0;
  let relocated = 0;
  let radarInserted = 0;
  let radarUpdated = 0;
  const radarCleanup: RadarCleanupRecord[] = [];
  const paths: string[] = [];
  const expected = args.expectedSourceCount ?? args.sources.length;
  if (args.sources.length !== expected) {
    throw new LarkDocError(
      "internal_error",
      `Lark mirror 完整性不符：discovery=${expected}，交付寫入階段=${args.sources.length}`,
    );
  }
  const recordRadar = (result: RadarIngestResult): void => {
    if (result.radar_action === "inserted") radarInserted++;
    else radarUpdated++;
    radarCleanup.push(...result.radar_duplicates_removed);
  };
  for (const source of args.sources) {
    const key = `${source.kind}:${source.token}`;
    const desiredPath = outputPath(args.config, source);
    const previous = state.documents[key];
    const relocatedFrom = relocationCandidate(args.config.vault_dir, previous, desiredPath);
    if (
      previous?.last_edit_time === source.last_edit_time
      && previous.output_path === desiredPath
      && existsSync(desiredPath)
      && lstatSync(desiredPath).isFile()
      && !lstatSync(desiredPath).isSymbolicLink()
    ) {
      recordRadar(await args.ingest(desiredPath, undefined, true));
      skipped++;
      continue;
    }
    if (source.kind === "mindnote") {
      const content = renderMirrorMarkdown(
        source,
        `# ${source.title}\n\n[Lark MindNote source](${source.source_url})\n\n`
          + "> MindNote 沒有官方純文字讀取 API；本頁只保存標題與來源連結。",
        now,
      );
      const path = desiredPath;
      ensureVaultParent(args.config.vault_dir, path);
      const temporary = `${path}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`;
      writeFileSync(temporary, content, { encoding: "utf8", mode: 0o644, flag: "wx" });
      renameSync(temporary, path);
      recordRadar(await args.ingest(path, relocatedFrom));
      state.documents[key] = {
        last_edit_time: source.last_edit_time,
        output_path: path,
        content_sha256: sha256(content),
        ingested_at: now,
      };
      if (removeRelocatedOutput(args.config.vault_dir, previous, path)) relocated++;
      atomicWriteJson(statePath, state);
      written++;
      paths.push(path);
      continue;
    }
    // v1 intentionally inventories sheets but never reads their cell contents.
    // Keep this boundary here as well as in discovery so a future drive-folder
    // source cannot accidentally turn metadata inventory into full ingestion.
    if (source.kind === "file" || source.kind === "sheet") {
      metadataOnly++;
      continue;
    }
    const parsed: ParsedLarkUrl = {
      kind: source.kind,
      token: source.token,
      normalizedUrl: source.source_url,
    };
    const read = await readDocument({ parsed, accessToken: args.accessToken, fetch: args.fetch });
    const reasons = scanSensitiveContent(read.markdown);
    if (reasons.length) {
      state.quarantined ??= {};
      state.quarantined[key] = {
        title: source.title,
        source_url: source.source_url,
        reasons,
        detected_at: now,
      };
      atomicWriteJson(statePath, state);
      quarantined++;
      continue;
    }
    const content = renderMirrorMarkdown(source, read.markdown, now);
    const path = desiredPath;
    ensureVaultParent(args.config.vault_dir, path);
    const temporary = `${path}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`;
    writeFileSync(temporary, content, { encoding: "utf8", mode: 0o644, flag: "wx" });
    renameSync(temporary, path);
    recordRadar(await args.ingest(path, relocatedFrom));
    state.documents[key] = {
      last_edit_time: source.last_edit_time,
      output_path: path,
      content_sha256: sha256(content),
      ingested_at: now,
    };
    if (removeRelocatedOutput(args.config.vault_dir, previous, path)) relocated++;
    atomicWriteJson(statePath, state);
    written++;
    paths.push(path);
  }
  const processed = written + skipped + metadataOnly + quarantined;
  if (processed !== expected) {
    throw new LarkDocError(
      "internal_error",
      `Lark mirror 完整性不符：discovery=${expected}，已歸類=${processed}`,
    );
  }
  const radarProcessed = radarInserted + radarUpdated;
  if (radarProcessed !== written + skipped) {
    throw new LarkDocError(
      "internal_error",
      `Lark mirror Radar 對帳不符：應寫入或更新=${written + skipped}，實際=${radarProcessed}`,
    );
  }
  return {
    written,
    skipped,
    skipped_by_reason: { unchanged: skipped },
    metadataOnly,
    quarantined,
    failed: 0,
    processed,
    expected,
    relocated,
    radar_inserted: radarInserted,
    radar_updated: radarUpdated,
    radar_deduplicated: radarCleanup.length,
    radar_cleanup: radarCleanup,
    paths,
  };
}

function removeRelocatedOutput(
  vaultValue: string,
  previous: MirrorState["documents"][string] | undefined,
  replacement: string,
): boolean {
  const oldPath = relocationCandidate(vaultValue, previous, replacement);
  if (!oldPath) return false;
  unlinkSync(oldPath);
  return true;
}

function relocationCandidate(
  vaultValue: string,
  previous: MirrorState["documents"][string] | undefined,
  replacement: string,
): string | undefined {
  const oldPath = previous?.output_path;
  if (!oldPath || oldPath === replacement || !existsSync(oldPath)) return undefined;
  const root = resolve(vaultValue);
  const resolved = resolve(oldPath);
  if (!resolved.startsWith(`${root}${sep}`)) return undefined;
  const stat = lstatSync(resolved);
  if (!stat.isFile() || stat.isSymbolicLink()) return undefined;
  if (sha256(readFileSync(resolved, "utf8")) !== previous.content_sha256) return undefined;
  return resolved;
}
