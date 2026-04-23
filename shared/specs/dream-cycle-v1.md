# Dream Cycle v2 — MemOcean 夜間知識整合

## 功能概述

每日凌晨自動掃描當天所有對話與新增資料，執行實體擷取、Entity 正規化、KG 三元組補強、Closet 骨架更新、跨文件引用修補，讓 agent 隔天醒來時的知識庫比睡前更完整、更連貫。

## 背景與動機

目前 MemOcean 的知識寫入依賴即時觸發（on-stop hooks、手動 `/graphify`、CLSC ingest）。這導致：

1. **知識碎片化** — 同一場對話提到的多個實體，只有被明確處理的才進 KG，其餘遺漏
2. **引用斷裂** — Closet 骨架之間缺乏 wikilink 交叉引用，Pearl card 的「連結」欄位經常為空
3. **時效性落差** — 今天的對話可能更新了昨天 Closet 記錄的事實（如角色變動、價格更新），但舊記錄沒被修正
4. **on-stop hooks 的局限** — 只在 session 結束時觸發，且跑在 shell 環境裡，不適合做深度語意分析

GBrain 的 Dream Cycle 概念證明了「睡眠時間整合」是 agent 記憶系統的關鍵環節。我們已有 FTS5（全文搜尋）、CLSC（骨架萃取）、KG（知識圖譜）三套基礎設施，缺的是把它們串起來的夜間批次流程。

## 設計原則

1. **增量不覆蓋（Additive-Only）** — 永遠不刪除、不覆蓋現有 Closet/KG 記錄。更新時先 diff，確認有淨增益才寫入。KG 使用 `invalidate()` 標記過期事實，不修改原始 triple。
2. **可回溯（Auditable）** — 每次 Dream Cycle 執行產生一份結構化 run log（JSON），包含所有變更的 before/after diff，出問題可溯源。
3. **冪等安全（Idempotent）** — 同一天的資料跑兩次結果相同。透過 `source_hash` 去重，避免重複處理。
4. **預設 dry-run** — 第一次部署預設只輸出報告不寫 DB，確認無誤後切到 live mode。
5. **低成本** — 盡可能用 Haiku 處理批量任務，只在需要複雜判斷時升級 Sonnet。

## 功能範圍

### In Scope

| 模組 | 說明 | Phase |
|------|------|-------|
| **Entity Extraction** | 從當天 messages 擷取人物、專案、工具、概念等實體，補入 KG | Phase 1 |
| **Entity Normalization** | 透過 alias_table.yaml 正規化實體名稱，合併同義詞 | Phase 1 |
| **Triple Enrichment** | 從對話上下文推導實體間的關係三元組，補入 KG | Phase 1 |
| **Closet Refresh** | 掃描現有 Closet 骨架，用當天新資訊更新過時的事實描述 | Phase 1 |
| **Reference Stitching** | 跨 Closet entry 建立 wikilink 引用，增加連結密度 | Phase 1 |
| **Pearl Draft** | 延伸現有 `pearl_draft_generator.py`，改為 Dream Cycle 的子步驟 | Phase 2 |
| **Run Report** | 生成執行摘要：新增/更新數量、發現的衝突、處理時間 | Phase 1 |

### Out of Scope

- 外部資料源抓取（RSS、網頁爬蟲）— 那是另一個功能
- 跨日回溯整合（只處理「昨天到現在」的增量，不重整歷史全量）
- 自動部署/CD — 手動 cron 安裝
- Obsidian vault 直接寫入 — Dream Cycle 產出存 DB，Obsidian 同步由既有機制處理
- 多語言 NER — Phase 1 僅處理繁中/簡中/英文混合文本

## 技術設計

### 觸發機制

```
# crontab (system-level, 不是 session-level)
# 每日 03:00 UTC+8 (19:00 UTC) 執行
SHELL=/bin/bash
PYTHONPATH=/home/oldrabbit/.claude-bots/shared
0 19 * * * /home/oldrabbit/.claude-bots/shared/venv/bin/python /home/oldrabbit/.claude-bots/shared/scripts/dream_cycle.py --mode=live >> /home/oldrabbit/.claude-bots/logs/dream-cycle.log 2>&1
```

為什麼用 system crontab 而非 session-level cron：
- Dream Cycle 需要在所有 bot session 都靜止時跑（凌晨 3 點）
- Session cron 依賴 bot 活著，但 bot 可能在凌晨被停掉
- System crontab 獨立於任何 bot session

為什麼用 venv python：
- 系統 python 可能缺少 `anthropic`、`sqlite-vec` 等 dependencies
- `/home/oldrabbit/.claude-bots/shared/venv/bin/python` 保證所有套件已安裝
- `PYTHONPATH` 設定讓 `from clsc.closet import store_skeleton` 等 import 正常運作

### 執行流程

```
┌──────────────────────────────────────────────────────────────┐
│                   Dream Cycle Pipeline                       │
│                                                              │
│  1. Collect    ──→  2. Extract   ──→  2.5. Normalize         │
│  (FTS5 query)      (Haiku NER)       (alias_table.yaml)      │
│                                                              │
│  3. Diff       ──→  4. Write     ──→  5. Stitch   ──→ 6. Report │
│  (compare)         (KG + Closet)     (wikilinks)     (log+TG)│
└──────────────────────────────────────────────────────────────┘
```

#### Step 1: Collect — 收集當日素材

```python
# 查詢 messages 表：取得過去 24 小時的所有對話
SELECT bot_name, ts, user, text, chat_id
FROM messages
WHERE ts >= datetime('now', '-24 hours')
ORDER BY ts ASC
```

- 按 `chat_id` 分群，每群組成一個 conversation block
- 過濾掉純 bot 指令（以 `/` 開頭的短訊息）
- 計算 `content_hash = sha256(sorted_texts)` 用於冪等檢查

#### Step 2: Extract — 實體與關係擷取

使用 Haiku 做批量 NER + 關係擷取：

```
Prompt (per conversation block, max 3000 chars):
---
以下是一段對話記錄。請擷取：
1. 實體（人名、專案名、工具名、公司名、概念名）— 標注類型
2. 關係三元組（subject, predicate, object）— 標注 confidence (0-1)
3. 事實更新（如果對話中提到某事實已改變，標注 old → new）

輸出 JSON：
{
  "entities": [{"name": "...", "type": "person|project|tool|company|concept"}],
  "triples": [{"s": "...", "p": "...", "o": "...", "confidence": 0.9}],
  "fact_updates": [{"entity": "...", "field": "...", "old": "...", "new": "...", "evidence": "..."}]
}
---
```

- 每個 conversation block 獨立呼叫一次 Haiku（控制 context window）
- 批量上限：單次 Dream Cycle 最多處理 50 個 conversation block（超過則取最近的 50 個）
- 每個 block 的 token 預算：input ~800 tokens, output ~400 tokens
- 預估單次 Dream Cycle 的 Haiku 成本：50 blocks * 1200 tokens * $0.0008/1K = ~$0.05

#### Step 2.5: Normalize — Entity 正規化

在 Extract 之後、Diff 之前，對所有擷取出的 entity name 做正規化，將別名統一為 canonical name。

**Phase 1：Exact Match（alias_table.yaml）**

```yaml
# 路徑：/home/oldrabbit/.claude-bots/shared/config/alias_table.yaml
# 手動維護，初始約 20-30 條常用 alias
entities:
  - canonical: OldRabbit
    aliases: [老兔, 兔哥, oldrabbit_eth, 老兔子]
    type: person
  - canonical: ChannelLab
    aliases: [CHL, channellab, Channel Lab]
    type: company
  - canonical: Anya
    aliases: [安雅, Anyachl_bot]
    type: bot
  - canonical: Anna
    aliases: [安娜, annadesu_bot]
    type: bot
  - canonical: Bella
    aliases: [貝拉, Bellalovechl_Bot]
    type: bot
  # 更多...
```

正規化邏輯（pseudocode）：

```python
import yaml

def load_alias_table(path="shared/config/alias_table.yaml"):
    """載入 alias 表，建立 alias → canonical 的 lookup dict"""
    with open(path) as f:
        data = yaml.safe_load(f)
    lookup = {}
    for entry in data["entities"]:
        canonical = entry["canonical"]
        for alias in entry.get("aliases", []):
            lookup[alias.lower()] = canonical
        lookup[canonical.lower()] = canonical  # canonical 自身也加入
    return lookup

def normalize_entities(entities: list[dict], lookup: dict) -> list[dict]:
    """
    掃描 extracted entities，命中 alias 則替換成 canonical name。
    同時去重：正規化後相同的 entity 合併為一條。
    """
    seen = set()
    normalized = []
    for ent in entities:
        name = ent["name"]
        canonical = lookup.get(name.lower(), name)  # 查不到就保留原名
        ent["name"] = canonical
        if canonical not in seen:
            seen.add(canonical)
            normalized.append(ent)
    return normalized

def normalize_triples(triples: list[dict], lookup: dict) -> list[dict]:
    """對 triples 的 subject 和 object 也做正規化"""
    for t in triples:
        t["s"] = lookup.get(t["s"].lower(), t["s"])
        t["o"] = lookup.get(t["o"].lower(), t["o"])
    return triples
```

- 正規化在每個 conversation block 的 Extract 產出上逐一執行
- Exact match（case-insensitive），不需要 LLM 呼叫，零額外成本
- 新的未知 alias 記入 report 的 `unknown_aliases[]` 欄位，供手動維護時參考

**Phase 2 規劃（不在 Phase 1 實作）：**
- 用 Haiku embedding 做 fuzzy entity linking：對查不到 exact match 的 entity，計算與所有 canonical name 的 embedding 相似度，超過門檻（cosine > 0.85）則自動歸併
- 自動建議新 alias：累積超過 3 次出現的未知 entity，推薦加入 alias_table.yaml

#### Step 3: Diff — 比對現有資料

對 Step 2.5 正規化後的產出，與現有 KG/Closet 比對：

**KG Diff：**
```python
for triple in extracted_triples:
    existing = kg_query(triple.subject)
    if same_triple_exists(existing, triple):
        skip  # 已存在，不重複寫
    elif contradicts(existing, triple):
        mark_for_review  # 矛盾，記入 conflict log
    else:
        mark_for_insert  # 新事實，準備寫入
```

**Closet Diff：**
```python
from closet_search import closet_search

for entity in extracted_entities:
    existing_results = closet_search(entity.name, limit=3)
    if existing_results:
        # existing_results[0] 是 dict: {slug, clsc, tokens, drawer_path}
        existing_slug = existing_results[0]["slug"]
        existing_clsc = existing_results[0]["clsc"]
        # 比對新舊骨架：逐行比對 existing_clsc 與 new_context，
        # 只保留 existing_clsc 中沒有的新資訊片段。
        # 如果 new_context 的所有關鍵資訊都已存在於 existing_clsc，則跳過。
        new_info = extract_new_info(existing_clsc, new_context)
        if new_info:
            mark_for_update(slug=existing_slug, patch=new_info)
    else:
        # 全新實體，建立新 Closet entry
        mark_for_create(entity)
```

**安全閥：**
- Closet 更新前計算 `source_hash`，如果 hash 相同代表內容沒變，跳過
- 更新 Closet 時保留原始骨架，只在尾部 append 新資訊（不改寫已有描述）
- 單次 Dream Cycle 的 Closet 更新上限：30 條（超過則按 confidence 排序取前 30）

#### Step 4: Write — 寫入 KG + Closet

```python
if mode == "dry-run":
    write_report_only(changes)
    return

# KG writes
for triple in approved_triples:
    kg_add(
        subject=triple.s,
        predicate=triple.p,
        obj=triple.o,
        source="dream-cycle-v1",
        confidence=triple.confidence,
    )

# KG invalidations (fact updates)
for update in fact_updates:
    kg_invalidate(update.entity, update.field, update.old)
    kg_add(update.entity, update.field, update.new,
           source="dream-cycle-v1")

# Closet writes
# 注意：store_skeleton() 已修改為同時寫入 seabed 檔案和 memory.db closet 表
# 簽名：store_skeleton(group: str, slug: str, skeleton: str) -> None
# 內部邏輯：
#   1. 寫入 seabed/wiki-{group}.clsc.md（原有行為）
#   2. UPSERT memory.db closet 表（新增行為）：
#      INSERT OR REPLACE INTO closet (slug, clsc, tokens, drawer_path)
#      VALUES (?, ?, ?, ?)
from clsc.v0_7.closet import store_skeleton

for change in closet_changes:
    if change.type == "create":
        store_skeleton(change.group, change.slug, change.skeleton)
    elif change.type == "update":
        # Append-only: 讀取現有骨架，在尾部追加新資訊
        existing_results = closet_search(change.slug, limit=1)
        if existing_results:
            existing_clsc = existing_results[0]["clsc"]
            updated = existing_clsc + " | " + change.patch
        else:
            updated = change.patch
        store_skeleton(change.group, change.slug, updated)
```

**並發保護：**
- 使用 SQLite WAL mode（KG 和 memory.db 都已啟用）
- Dream Cycle 開始前取得 advisory lock file (`/tmp/dream-cycle.lock`)
- Lock 超時 30 分鐘自動釋放（防死鎖）
- 如果 lock 取不到，記入 log 並退出（不排隊等待）

#### Step 5: Stitch — 引用修補

掃描所有在 Step 4 中新增或更新的 Closet entry，為它們建立交叉引用：

```python
from closet_search import closet_search
from clsc.v0_7.closet import store_skeleton

for slug in changed_slugs:
    # 取得當前骨架內容
    current = closet_search(slug, limit=1)
    if not current:
        continue
    skeleton = current[0]["clsc"]

    # 在所有其他 Closet entry 中搜尋相關項目
    related = closet_search(slug, limit=5)
    for r in related:
        if r["slug"] != slug and f"[[{slug}]]" not in r["clsc"]:
            # 在 r 的骨架尾部追加 wikilink 引用
            # 透過 store_skeleton() 同時更新檔案和 DB
            updated_clsc = r["clsc"] + f" [[{slug}]]"
            group = infer_group(r["slug"])  # 從 slug 推斷 group
            store_skeleton(group, r["slug"], updated_clsc)
```

- 只為當次 Dream Cycle 變更的 entry 做 stitching（不全量掃描）
- 連結密度目標：每個 Closet entry 至少有 2 個 wikilink 引用

#### Step 6: Report — 執行報告

```python
report = {
    "run_id": f"dream-{date.today().isoformat()}",
    "started_at": start_ts,
    "finished_at": end_ts,
    "duration_seconds": elapsed,
    "mode": "dry-run" | "live",
    "input": {
        "messages_scanned": msg_count,
        "conversation_blocks": block_count,
        "content_hash": content_hash,
    },
    "output": {
        "entities_extracted": entity_count,
        "entities_normalized": normalized_count,  # 被 alias 正規化的數量
        "unknown_aliases": unknown_alias_list,     # 未命中 alias 的 entity 列表
        "triples_added": triple_add_count,
        "triples_skipped_duplicate": dup_count,
        "triples_conflict": conflict_count,
        "closet_created": closet_create_count,
        "closet_updated": closet_update_count,
        "closet_skipped_no_change": skip_count,
        "references_stitched": stitch_count,
    },
    "conflicts": [...],  # 矛盾事實列表（需人工審核）
    "errors": [...],
    "cost_estimate_usd": haiku_cost,
}

# --- TG 通知 ---
import requests

TG_CHAT_ID = 1050312492  # 老兔私訊
TG_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")

if report["mode"] == "live":
    tg_text = (
        f"🌙 Dream Cycle 完成\n"
        f"entities: {report['output']['entities_extracted']} 個\n"
        f"triples: {report['output']['triples_added']} 條\n"
        f"closet 新增: {report['output']['closet_created']}, "
        f"更新: {report['output']['closet_updated']}\n"
        f"耗時: {report['duration_seconds']}s"
    )
elif report["mode"] == "dry-run":
    tg_text = (
        f"🌙 Dream Cycle (dry-run) 完成\n"
        f"待確認：entities {report['output']['entities_extracted']} 個、"
        f"triples {report['output']['triples_added']} 條\n"
        f"切換 --mode=live 以實際寫入"
    )

if report.get("errors"):
    tg_text = (
        f"⚠️ Dream Cycle 執行有錯誤\n"
        f"error type: {report['errors'][0].get('type', 'unknown')}\n"
        f"共 {len(report['errors'])} 個錯誤，詳見 log"
    )

if TG_BOT_TOKEN:
    requests.post(
        f"https://api.telegram.org/bot{TG_BOT_TOKEN}/sendMessage",
        json={"chat_id": TG_CHAT_ID, "text": tg_text},
        timeout=10,
    )
```

報告存放路徑：`~/.claude-bots/logs/dream-cycle/YYYY-MM-DD.json`

### 輸入/輸出定義

| 項目 | 路徑 / 來源 | 格式 |
|------|-------------|------|
| **輸入：對話** | `memory.db` messages 表 | FTS5 virtual table |
| **輸入：現有 KG** | `kg.db` triples + entities 表 | SQLite |
| **輸入：現有 Closet** | `memory.db` closet 表 + `seabed/` 檔案 | SQLite + .clsc.md |
| **輸入：Alias 表** | `shared/config/alias_table.yaml` | YAML |
| **輸出：KG 寫入** | `kg.db` | `kg_helper.kg_add()` / `kg_invalidate()` |
| **輸出：Closet 寫入** | `memory.db` closet 表 + `seabed/` | `store_skeleton()`（同時寫檔案和 DB） |
| **輸出：Run report** | `~/.claude-bots/logs/dream-cycle/YYYY-MM-DD.json` | JSON |
| **輸出：TG 通知** | 老兔私訊 (chat_id: 1050312492) | Telegram message |
| **輸出：Lock file** | `/tmp/dream-cycle.lock` | PID file |

### 使用的 AI 模型

| 步驟 | 模型 | 理由 |
|------|------|------|
| Entity extraction (Step 2) | **Haiku** | 批量 NER 是結構化任務，Haiku 足夠且成本低 |
| Entity normalization (Step 2.5) | **不需要 LLM** | Phase 1 用 alias_table.yaml exact match，零成本 |
| Conflict resolution (Step 3) | **不需要 LLM** | 用規則比對（exact match + predicate match） |
| Closet skeleton 生成 (Step 4) | **Haiku** | 沿用 CLSC encoder 的既有模式 |
| Reference stitching (Step 5) | **不需要 LLM** | 用 `closet_search()` 做關鍵字/語意匹配 |
| Pearl draft (Phase 2) | **Haiku** | 沿用 `pearl_draft_generator.py` 的既有模式 |

預估每日 API 成本：$0.03 ~ $0.08（取決於當天對話量）

### 錯誤處理

| 錯誤情境 | 處理策略 |
|----------|---------|
| `ANTHROPIC_API_KEY` 未設定 | 跳過需要 LLM 的步驟（Step 2, 4 的 skeleton 生成），其餘步驟正常執行，report 標記 `degraded: true` |
| Haiku API 呼叫失敗 | 單次 retry（delay 5s），仍失敗則記入 `errors[]` 並跳過該 block |
| SQLite lock timeout | 等待 10 秒 retry 一次，仍 locked 則退出並記入 log |
| Memory.db 不存在 | 直接退出，exit code 1 |
| KG.db 不存在 | 跳過 KG 相關步驟，只做 Closet |
| Dream Cycle lock 已存在 | 檢查 PID 是否還活著：活著 → 退出；死了 → 清理 stale lock 繼續跑 |
| 單次產出超過安全閥 | 截斷到上限（triples: 200, closet: 30），report 標記 `truncated: true` |
| Haiku 回傳非法 JSON | 嘗試寬鬆 parse（`json.loads` + regex fallback），失敗則跳過該 block |
| alias_table.yaml 不存在 | 跳過 Step 2.5 正規化，report 標記 `normalization_skipped: true`，不中斷 pipeline |
| 進程中途 crash | 下次啟動時偵測 `dream_cycle_runs` 中 status 為 `running_step*` 的未完成 run，從 checkpoint 對應的 step 繼續執行（跳過已完成的 steps） |

### Crash-Recovery Checkpoint 機制

Dream Cycle 使用 `dream_cycle_runs` 表的 `status` 欄位作為 checkpoint：

```python
# 每進入一個 step，更新 status
def update_checkpoint(run_id: str, step: str):
    """step 值: 'running_step1' | 'running_step2' | 'running_step2.5' |
       'running_step3' | 'running_step4' | 'running_step5' | 'running_step6' |
       'completed' | 'failed'"""
    conn.execute(
        "UPDATE dream_cycle_runs SET status = ? WHERE run_id = ?",
        (step, run_id)
    )
    conn.commit()

# 啟動時檢查是否有未完成的 run
def check_incomplete_run() -> tuple[str, str] | None:
    """回傳 (run_id, last_step) 或 None"""
    row = conn.execute(
        "SELECT run_id, status FROM dream_cycle_runs "
        "WHERE status LIKE 'running_%' ORDER BY started_at DESC LIMIT 1"
    ).fetchone()
    if row:
        return (row[0], row[1])
    return None

# 主程式入口
incomplete = check_incomplete_run()
if incomplete:
    run_id, last_step = incomplete
    step_num = parse_step_number(last_step)  # e.g. 'running_step3' → 3
    logger.info(f"Resuming incomplete run {run_id} from step {step_num}")
    # 從 last_step 對應的 step 重新執行（該 step 可能只完成一半，重跑是安全的因為冪等）
    resume_from_step(run_id, step_num)
else:
    start_new_run()
```

### 效能考量

- **批次處理**：conversation blocks 按 chat_id 分群後，相同群組的 blocks 合併送 Haiku（在 token 上限內），減少 API 呼叫次數
- **早期剪枝**：先用 `content_hash` 檢查是否已處理過相同內容，避免重複跑
- **SQLite WAL**：所有 DB 操作都在 WAL mode 下，讀寫不互斥
- **記憶體**：逐 block 處理，不一次載入全部對話到記憶體
- **超時保護**：整個 Dream Cycle 設 hard timeout 30 分鐘（kill -9），防止 Haiku 卡死導致進程掛起

## 資料模型

### 新增的 DB Schema

```sql
-- 加入 memory.db：Dream Cycle 執行記錄（用於冪等檢查 + checkpoint）
CREATE TABLE IF NOT EXISTS dream_cycle_runs (
    run_id TEXT PRIMARY KEY,          -- 'dream-2026-04-11'
    started_at TEXT NOT NULL,
    finished_at TEXT,
    mode TEXT NOT NULL,               -- 'dry-run' | 'live'
    content_hash TEXT,                -- 當天訊息的 SHA256
    status TEXT DEFAULT 'running_step1',
    -- checkpoint 值: 'running_step1' | 'running_step2' | 'running_step2.5' |
    --               'running_step3' | 'running_step4' | 'running_step5' |
    --               'running_step6' | 'completed' | 'failed'
    report_json TEXT,                 -- 完整 report JSON
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

-- 加入 memory.db：Dream Cycle 變更明細（可回溯）
CREATE TABLE IF NOT EXISTS dream_cycle_changes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL,
    change_type TEXT NOT NULL,         -- 'kg_add' | 'kg_invalidate' | 'closet_create' | 'closet_update' | 'reference_stitch'
    target_id TEXT NOT NULL,           -- triple ID 或 closet slug
    before_value TEXT,                 -- 變更前的值（JSON）
    after_value TEXT,                  -- 變更後的值（JSON）
    confidence REAL,
    source_block TEXT,                 -- 來源 conversation block 的 chat_id + ts range
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (run_id) REFERENCES dream_cycle_runs(run_id)
);

CREATE INDEX IF NOT EXISTS idx_dc_changes_run ON dream_cycle_changes(run_id);
CREATE INDEX IF NOT EXISTS idx_dc_changes_target ON dream_cycle_changes(target_id);
```

### 現有 Schema 修改

- **`store_skeleton()` 加入 DB upsert**：修改 `clsc/v0.7/closet.py` 的 `store_skeleton(group, slug, skeleton)` 函式，在寫入 seabed 檔案後，同時 upsert `memory.db` 的 closet 表：
  ```python
  # 在 store_skeleton() 的 path.write_text() 之後新增：
  import sqlite3
  db_path = Path.home() / ".claude-bots" / "memory.db"
  conn = sqlite3.connect(str(db_path))
  tokens = len(skeleton) // 4  # 粗估 token 數
  drawer_path = str(path)
  conn.execute(
      "INSERT OR REPLACE INTO closet (slug, clsc, tokens, drawer_path) "
      "VALUES (?, ?, ?, ?)",
      (slug, skeleton, tokens, drawer_path)
  )
  conn.commit()
  conn.close()
  ```
- `messages` 表（FTS5）：只讀取，不修改
- `kg.db` triples/entities：透過既有的 `kg_add()` / `kg_invalidate()` 操作，不改 schema

## 實作計劃

### Phase 1（MVP）— 預估 2-3 天

**目標：** 端到端跑通 Dream Cycle，dry-run 模式穩定運行一週

| 任務 | 產出 |
|------|------|
| **修改 `store_skeleton()` 加入 DB upsert 邏輯** | `clsc/v0.7/closet.py` 同時寫 seabed 檔案和 memory.db closet 表 |
| 建立 `dream_cycle.py` 主程式骨架 | Step 1 (Collect) + Step 6 (Report) |
| 實作 Entity Extraction (Step 2) | Haiku NER prompt + JSON parser |
| 建立 `alias_table.yaml` + Entity 正規化 (Step 2.5) | exact match 解析 + normalize 函式 |
| 實作 KG Diff + Write (Step 3-4) | `kg_helper` 整合 + 冪等檢查 |
| 建立 `dream_cycle_runs` / `dream_cycle_changes` 表 | Schema migration |
| 加入 lock file 機制 | 並發保護 |
| 加入 crash-recovery checkpoint | status 欄位 checkpoint + 重啟續跑 |
| 加入 dry-run / live 模式切換 | CLI flag `--mode=dry-run|live` |
| 加入 TG 通知 | 完成/dry-run/失敗 三種通知 |
| System crontab 安裝腳本 | `install_cron.sh`（使用 venv python） |

**MVP 驗收標準：**
- dry-run 跑完產出 report JSON，內容正確
- 手動切 live mode，KG 新增的 triple 可用 `kg_query()` 查到
- 同一天跑兩次，第二次 report 顯示 0 新增（冪等）
- `store_skeleton()` 寫入後，`closet_search()` 能從 DB 查到該條目
- Entity 正規化：「老兔」「OldRabbit」「兔哥」在 report 中歸為同一 entity
- 成功完成：發 TG 私訊給老兔（chat_id: 1050312492）含簡短報告（entities X 個、triples X 條）
- dry-run 完成：發 TG 說明是 dry-run 模式、有多少條等待確認
- 失敗：發 TG 錯誤摘要（含 error type）
- crash-recovery：模擬中途中斷，重跑時從 checkpoint 繼續

### Phase 2（優化）— Phase 1 穩定後

| 任務 | 說明 |
|------|------|
| Pearl Draft 整合 | 取代現有 `anya-on-stop-pearl-draft.sh`，改由 Dream Cycle 統一處理 |
| Fuzzy Entity Linking | 用 Haiku embedding 做模糊 entity 正規化（cosine > 0.85 自動歸併） |
| Conflict Dashboard | 矛盾事實的 TG 通知（發到 L2 群） |
| 多 bot 支援 | 每個 bot 的對話分開處理，避免 context 混淆 |
| 成本追蹤 | 接入 `clsc-usage.jsonl` 的 logging 格式，追蹤 API 花費 |

## 驗收標準

### Phase 1
- [ ] `dream_cycle.py --mode=dry-run` 正常執行，exit code 0
- [ ] 產出 `~/.claude-bots/logs/dream-cycle/YYYY-MM-DD.json` 報告
- [ ] 報告包含 entities_extracted, triples_added, conflicts 等完整欄位
- [ ] `--mode=live` 成功寫入 KG，可用 `kg_query()` 驗證
- [ ] `store_skeleton()` 同時寫入 seabed 檔案和 memory.db closet 表
- [ ] `closet_search()` 能查到 Dream Cycle 新增的 Closet entry
- [ ] Entity 正規化：alias_table.yaml 的別名正確歸併為 canonical name
- [ ] 冪等：同一天跑兩次，第二次 triples_added = 0
- [ ] Lock file 防止並發執行（手動測試：同時啟動兩個 instance）
- [ ] `ANTHROPIC_API_KEY` 未設定時 graceful degradation（不 crash）
- [ ] Haiku API 失敗時單 block retry，不中斷整個 pipeline
- [ ] `dream_cycle_runs` 表正確記錄每次執行（含 checkpoint status）
- [ ] `dream_cycle_changes` 表記錄所有 KG 變更的 before/after
- [ ] Crash-recovery：未完成的 run 能從 checkpoint 繼續
- [ ] TG 通知：成功/dry-run/失敗 三種情境都發私訊給老兔

### Phase 2
- [ ] Pearl draft 品質不低於現有 `pearl_draft_generator.py`
- [ ] Fuzzy entity linking 正確率 > 90%
- [ ] 矛盾事實透過 TG 通知到 L2 群
- [ ] 每日 API 成本 < $0.10

## 注意事項 / 風險

1. **Lossy 覆寫風險（高）** — 這是最大的設計考量。Closet 更新必須 append-only，絕不改寫已有描述。KG 使用 `invalidate()` 而非 `DELETE`。Dream Cycle changes 表記錄完整 diff，出問題可回滾。

2. **多 bot 並發寫入（中）** — 凌晨 3 點大多數 bot 不活躍，但無法保證。WAL mode + advisory lock 應足夠。如果未來 bot 跑 24/7，需考慮更強的 locking 機制（如 SQLite `BEGIN IMMEDIATE`）。

3. **Haiku 幻覺（中）** — NER 可能擷取不存在的實體或推導錯誤的關係。對策：confidence 門檻（< 0.7 不寫入）、矛盾偵測（與現有 KG 衝突時標記 conflict 不自動寫入）。

4. **Entity 正規化漏網（中）** — Phase 1 的 exact match 無法處理拼寫錯誤或全新別名。對策：report 中列出 unknown_aliases，定期手動補充 alias_table.yaml。Phase 2 的 fuzzy linking 會大幅改善。

5. **成本爬升（低）** — 如果對話量暴增（如多 bot 全天活躍），API 成本可能超預期。對策：batch 數上限（50 blocks/run）、token 預算硬上限。

6. **Schema Migration（低）** — 新增兩張表到 `memory.db`。使用 `CREATE TABLE IF NOT EXISTS`，不影響既有表。但要確保 FTS5 virtual table 的 schema 不被意外修改。

7. **Cron 可靠性（低）** — System crontab 在 VPS 重啟後自動恢復，比 session cron 穩定。加入 heartbeat：如果 report JSON 超過 48 小時未更新，on-start hook 發 TG 警報。

## 變更日誌

### v1 → v2 變更摘要
1. **store_skeleton() DB upsert** — 修改 store_skeleton() 同時寫 seabed 檔案和 memory.db closet 表，解決 closet_search() 查不到 Dream Cycle 產出的問題
2. **Step 2.5 Entity 正規化** — 新增 alias_table.yaml + exact match 正規化層，解決 Haiku NER 把同一人/公司當多個 entity 的問題
3. **Pearl Draft 移至 Phase 2** — In Scope 表格中 Pearl Draft 標記為 Phase 2 only
4. **TG 通知** — Phase 1 加入成功/dry-run/失敗三種 TG 通知
5. **Crash-recovery checkpoint** — dream_cycle_runs.status 記錄 step-level checkpoint，重啟續跑
6. **Cron 環境設定** — 使用 venv python + PYTHONPATH 環境變數
7. **Pseudocode 修正** — 移除不存在的函式（read_closet_entry, diff_skeleton, append_reference），改用實際 API
