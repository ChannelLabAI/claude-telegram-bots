import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";

export const ONTOLOGY_SYSTEM = `You are an interaction ontology extractor for a team knowledge system.
Analyze conversation records and identify structured patterns.

**保守原則**：只萃取明確可識別的項目；不確定時寧可不萃取，不要猜測或外推。

For each identifiable item, output a JSON array with objects:
{ "tag": "<tag>", "text": "<verbatim or closely paraphrased>", "source_slug": "<slug>", "ts": "<ISO timestamp if available>" }

Tags and examples:
- decision: "老兔拍板採用 GBrain Path A 作為檢索底層"
- commitment: "Anya 承諾本週完成 Phase 3 spec"
- action_item: "Anna 需要在週五前補齊單元測試"
- assumption: "假設用戶流量不超過 1000 QPS"
- risk: "GBrain 索引若超過 50GB 可能影響啟動速度"
- dependency: "Phase 3 依賴 Phase 1 的 extractOntology() 基礎"
- open_question: "Ocean vault 是否需要支援多語言全文搜尋？"
- owner_implied: "菜姐隱性負責財務報告整合，從對話上下文推斷"
- precedent: "2026-04 GBrain benchmark 確立 Hit@5 90.9% 為門檻先例"
- customer_signal: "客戶反映搜尋延遲超過 2 秒體驗差"

Output ONLY a valid JSON array, no explanation.`;

export interface IndexedRecord {
  slug: string;
  content: string;
}

export type RecordContentSource = "ocean_original" | "index_fallback";

export interface HydratedRecord extends IndexedRecord {
  contentSource: RecordContentSource;
  fallbackReason?: string;
}

export interface HydrationCounts {
  oceanOriginal: number;
  indexFallback: number;
  fallbackReasons: Record<string, number>;
}

export interface HydrationResult {
  records: HydratedRecord[];
  counts: HydrationCounts;
}

interface TelegramSlug {
  date: string;
  month: string;
  chatIdAbs: string;
  messageId: string;
}

function parseTelegramSlug(slug: string): TelegramSlug | null {
  const match = slug.match(/^tg-(\d{4})(\d{2})(\d{2})-(\d+)-(.+)$/);
  if (!match) return null;
  return {
    date: `${match[1]}-${match[2]}-${match[3]}`,
    month: `${match[1]}-${match[2]}`,
    chatIdAbs: match[4],
    messageId: match[5],
  };
}

function frontmatterChatId(content: string): string | null {
  const frontmatter = content.match(/^---\n([\s\S]*?)\n---(?:\n|$)/)?.[1] ?? "";
  return frontmatter.match(/^chat_id:\s*["']?([^"'\s]+)["']?\s*$/m)?.[1] ?? null;
}

function originalMessageText(content: string, messageId: string): string | null {
  const anchor = `<!-- mid:${messageId} -->`;
  const line = content.split("\n").find(candidate => candidate.includes(anchor));
  if (!line) return null;
  const withoutAnchor = line.slice(0, line.indexOf(anchor)).trimEnd();
  return withoutAnchor.replace(/^-\s+\S+\s+\[[^\]]*\]\s*/, "").trim();
}

async function loadOriginalContent(
  slug: string,
  oceanChatsRoot: string,
): Promise<{ content?: string; reason?: string }> {
  const parsed = parseTelegramSlug(slug);
  if (!parsed) return { reason: "invalid_slug" };

  const monthDir = join(oceanChatsRoot, parsed.month);
  let candidates: string[];
  try {
    candidates = (await readdir(monthDir))
      .filter(name => name.startsWith(`${parsed.date}-`) && name.endsWith(".md"));
  } catch {
    return { reason: "month_or_date_missing" };
  }

  let matchedChat = false;
  for (const name of candidates) {
    let fileContent: string;
    try {
      fileContent = await readFile(join(monthDir, name), "utf8");
    } catch {
      continue;
    }
    const chatId = frontmatterChatId(fileContent);
    if (!chatId || chatId.replace(/^-/, "") !== parsed.chatIdAbs) continue;
    matchedChat = true;
    const content = originalMessageText(fileContent, parsed.messageId);
    if (content !== null) return { content };
  }
  return { reason: matchedChat ? "message_anchor_missing" : "chat_file_missing" };
}

export async function hydrateRecordsFromOcean(
  records: IndexedRecord[],
  oceanChatsRoot: string,
): Promise<HydrationResult> {
  const counts: HydrationCounts = {
    oceanOriginal: 0,
    indexFallback: 0,
    fallbackReasons: {},
  };
  const hydrated: HydratedRecord[] = [];

  for (const record of records) {
    const result = await loadOriginalContent(record.slug, oceanChatsRoot);
    if (result.content !== undefined) {
      counts.oceanOriginal += 1;
      hydrated.push({ ...record, content: result.content, contentSource: "ocean_original" });
      continue;
    }

    const reason = result.reason ?? "unknown";
    counts.indexFallback += 1;
    counts.fallbackReasons[reason] = (counts.fallbackReasons[reason] ?? 0) + 1;
    hydrated.push({
      ...record,
      contentSource: "index_fallback",
      fallbackReason: reason,
    });
  }

  return { records: hydrated, counts };
}

export interface OntologyAttempt<T> {
  ok: boolean;
  items: T[];
  newSlugs: string[];
  failedRecords: number;
  error?: string;
}

export async function attemptOntologyBatch<T>(
  records: IndexedRecord[],
  callModel: (content: string) => Promise<string>,
  parseItems: (raw: string) => T[],
): Promise<OntologyAttempt<T>> {
  const userContent = records.map(record => `--- ${record.slug} ---\n${record.content}`).join("\n\n");
  try {
    const raw = await callModel(userContent);
    return {
      ok: true,
      items: parseItems(raw),
      newSlugs: records.map(record => record.slug),
      failedRecords: 0,
    };
  } catch (error) {
    return {
      ok: false,
      items: [],
      newSlugs: [],
      failedRecords: records.length,
      error: String(error),
    };
  }
}

export function runLogPaths(logsDir: string, date: string, runId: string) {
  const safeRunId = runId.replace(/[^0-9A-Za-z._-]/g, "-");
  return {
    batch: join(logsDir, `${date}-${safeRunId}-batch.json`),
    ontology: join(logsDir, `${date}-${safeRunId}-ontology.json`),
  };
}
