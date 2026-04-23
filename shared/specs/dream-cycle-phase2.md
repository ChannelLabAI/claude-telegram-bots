# Dream Cycle Phase 2 — Pearl Generation 整合

## 功能概述

在 Dream Cycle Phase 1 的 Step 5 (Reference Stitching) 之後，新增 Step 5.5: Pearl Generation，將每日洞見萃取從 on-stop hook 遷移至 Dream Cycle pipeline。Pearl 是「觀點層」（可演化的當前最佳理解），與 Closet/CLSC 的「歷史記憶」（append-only 事實記錄）定位不同。引入 Compiled Truth 機制：每張 Pearl card 分為「當前最佳理解」（可覆寫）和「演化記錄」（append-only），讓知識既能迭代又能溯源。

## 前置條件

| 條件 | 說明 | 狀態 |
|------|------|------|
| **Phase 1 穩定運行 7 天** | Dream Cycle v1 的 Step 1-6 在 live mode 連續 7 天 exit code 0，無 unresolved error | 待確認 |
| **_drafts dedup 完成** | `Ocean/珍珠卡/_drafts/` 現有 ~64 個重複 draft 需先清理，避免 Dream Cycle 把重複 draft 誤當有效知識引用。這是獨立任務，由 Anna 執行 dedup 腳本（按標題相似度 + content hash 合併/刪除）| 待指派 |
| **pearl_fts 表建立** | 在 memory.db 建立 `pearl_fts` FTS5 虛擬表，並確認寫入 pipeline 正常運作（見下方 Schema） | 待開發 |

### _drafts dedup 任務規格（Anna 執行）

```
目標：將 ~64 個 draft 去重為不重複的 unique drafts
策略：
1. 讀取所有 _drafts/*.md 的標題（# 開頭第一行）
2. 按標題做 fuzzy match（Levenshtein distance < 5 或 cosine similarity > 0.85）
3. 同主題的多個 draft，保留最新的一個、刪除其餘
4. 產出 dedup report：刪了幾個、保留幾個、合併了哪些
5. Report 存到 ~/.claude-bots/logs/pearl-dedup-report.json
```

## Phase 2 新增步驟

### Step 5.5: Pearl Generation

位於 Step 5 (Reference Stitching) 之後、Step 6 (Report) 之前。

```
┌──────────────────────────────────────────────────────────────┐
│                   Dream Cycle Pipeline (Phase 2)             │
│                                                              │
│  1. Collect  → 2. Extract → 2.5. Normalize                   │
│  3. Diff     → 4. Write   → 5. Stitch                        │
│  → 5.5. Pearl Generation → 6. Report                         │
└──────────────────────────────────────────────────────────────┘
```

#### 輸入

- Step 1 收集的 conversation blocks（原始對話素材）
- Step 2 擷取的 entities + triples（提供 context）

#### 執行流程

```python
def step_5_5_pearl_generation(conversation_blocks, extracted_data, mode):
    """
    從當天對話萃取洞見，產出 Pearl card（最多 3 張）。
    
    流程：
    1. 呼叫 Haiku 從對話中找出洞見候選
    2. 對每個候選做去重檢查（pearl_fts 表搜尋現有 Pearl）
    3. 判斷：skip / update 現有 / create 新 draft
    4. 寫入 Ocean/珍珠卡/_drafts/（新建或演化）
    
    ⚠️ 安全邊界：EVOLVE 只動 _drafts/，不動正式 card（見下方規則）
    """
    
    # ── 0. 冪等檢查：跳過已處理的 conversation blocks ──
    processed_hashes = get_processed_block_hashes(run_date=today)
    new_blocks = [b for b in conversation_blocks if b["content_hash"] not in processed_hashes]
    if not new_blocks:
        return {"pearls_created": 0, "pearls_updated": 0, "pearls_skipped": 0}
    
    # ── 1. 萃取洞見候選 ──
    # 將新的 conversation blocks 合併（截取最近 5000 chars）
    blob = merge_conversation_blocks(new_blocks, max_chars=5000)
    
    candidates = call_haiku_extract_insights(blob)
    # Haiku prompt 要求：
    # - 找出「判斷/洞見/模式/原則」（排除純事實、操作步驟、待辦）
    # - 每個候選包含：title, insight_text, source_quote
    # - 最多回傳 5 個候選（後續去重後保留 ≤3）
    
    if not candidates:
        record_processed_blocks(new_blocks)
        return {"pearls_created": 0, "pearls_updated": 0, "pearls_skipped": 0}
    
    created, updated, skipped = 0, 0, 0
    
    for candidate in candidates[:5]:  # 硬上限 5 個候選
        if created + updated >= 3:    # 產出上限 3 個
            break
        
        # ── 2. FTS5 去重搜尋（兩層） ──
        # 第一層：搜 _drafts（EVOLVE 候選）
        draft_matches = fts5_search_pearl(candidate["title"], scope="drafts", limit=3)
        # 第二層：搜正式 card（只用於判斷 SKIP，不 EVOLVE）
        published_matches = fts5_search_pearl(candidate["title"], scope="published", limit=3)
        
        all_matches = draft_matches + published_matches
        
        if all_matches:
            # ── 3a. 判斷是否為演化 ──
            best_match = all_matches[0]
            evolution_decision = call_haiku_judge_evolution(
                existing_card=best_match["content"],
                new_insight=candidate["insight_text"]
            )
            # Haiku 回傳：EVOLVE | SKIP | NEW
            
            if evolution_decision == "EVOLVE":
                # ⚠️ 安全邊界：只 EVOLVE _drafts/ 裡的 card
                if best_match["scope"] == "drafts":
                    update_existing_pearl(best_match["path"], candidate)
                    updated += 1
                else:
                    # 正式 card 被判定 EVOLVE → 降級為 CREATE
                    # 建新 draft，frontmatter 標注來源
                    create_pearl_draft(candidate, evolves_from=best_match["slug"])
                    created += 1
            elif evolution_decision == "NEW":
                create_pearl_draft(candidate)
                created += 1
            else:  # SKIP
                skipped += 1
        else:
            # ── 3b. 全新主題 ──
            create_pearl_draft(candidate)
            created += 1
    
    # 記錄已處理的 block hashes
    record_processed_blocks(new_blocks)
    
    return {
        "pearls_created": created,
        "pearls_updated": updated,
        "pearls_skipped": skipped,
    }
```

#### Haiku Prompts

**洞見萃取 prompt：**
```
以下是今天的對話記錄。找出含有「判斷/洞見/模式/原則」的段落
（排除純事實、操作步驟、待辦事項、單純的技術 debug）。

對每個洞見，輸出 JSON：
{
  "insights": [
    {
      "title": "一句話標題",
      "insight_text": "核心想法，2-5 句話，< 300 字",
      "source_quote": "原文中最能支撐此洞見的一段話（≤100 字）"
    }
  ]
}

如果沒有值得記錄的洞見，回覆：{"insights": []}

對話記錄：
{blob}
```

**演化判斷 prompt：**
```
以下是一張現有的 Pearl card 和一個新洞見。判斷新洞見與現有 card 的關係：

現有 card：
{existing_card_content}

新洞見：
{new_insight_text}

回覆一個 JSON：
{
  "decision": "EVOLVE" | "SKIP" | "NEW",
  "reason": "一句話解釋"
}

判斷標準：
- EVOLVE：新洞見深化、更新、或推翻了現有觀點（要改寫 card）
- SKIP：新洞見跟現有 card 說的是同一件事，沒有新資訊
- NEW：主題相關但切角不同，值得獨立成一張新 card
```

#### 產出上限與品質控制

- 每次 Dream Cycle **最多產出 3 個 Pearl**（避免品質稀釋）
- 候選上限 5 個（Haiku 回傳），經去重後取前 3
- 單張 Pearl body ≤ 300 字
- 每張 Pearl 至少 2 個 `[[wikilinks]]`（用 `closet_search` 找相關 slug）

## Pearl 演化機制（Compiled Truth）

### 概念

借鑑 GBrain 的 Compiled Truth 設計：知識既要可更新（不讓舊觀點污染回答），又要可溯源（知道為什麼這樣認為）。兩層分開就同時解決。

### Card 格式

```markdown
---
type: card
source_chat: 1050312492
source_bot: anya
created: 2026-04-05
updated: 2026-04-11
source: Dream Cycle
status: draft
---

# 卡片標題

（當前最佳理解 — 可被新洞見覆寫）

核心觀點 2-5 句話。這一區塊永遠反映最新的理解。

---
連結：
- [[相關概念A]]
- [[相關概念B]]

---
演化記錄：
- 2026-04-11：因 [老兔與 Bella 關於 Pearl 定位的討論] 更新，舊觀點：Pearl 只是筆記摘要 → 新觀點：Pearl 是可演化的觀點層
- 2026-04-05：初始建立，來源：Dream Cycle 對話萃取
```

### parse_pearl_sections() 定義

```python
def parse_pearl_sections(content: str) -> tuple[str, str, str, str]:
    """
    解析 Pearl card 為四個區塊：frontmatter, current_understanding, links, evolution_log。
    
    規則：
    - 舊格式（無演化記錄區塊）：全文（frontmatter 以下）視為「當前最佳理解」，
      自動在最後加 `---\n演化記錄：\n`
    - 新格式：最後一個 `---` + `演化記錄：` 以上是「當前最佳理解」，以下是「演化記錄」
    - Edge case：frontmatter 缺 fields → 補預設值，不 crash
    
    Returns:
        (frontmatter, current_understanding, links, evolution_log)
    """
    # 1. 提取 frontmatter（--- 到 --- 之間）
    fm_match = re.match(r'^---\n(.*?\n)---\n', content, re.DOTALL)
    if fm_match:
        frontmatter = f"---\n{fm_match.group(1)}---\n"
        body = content[fm_match.end():]
    else:
        # 缺 frontmatter → 補預設
        frontmatter = (
            "---\n"
            "type: card\n"
            f"source_bot: unknown\n"
            f"created: {datetime.now().strftime('%Y-%m-%d')}\n"
            "source: Dream Cycle\n"
            "status: draft\n"
            "---\n"
        )
        body = content
    
    # 2. 確保必要 fields 存在
    required_fields = {
        "type": "card",
        "status": "draft",
        "source": "Dream Cycle",
    }
    for field, default in required_fields.items():
        if f"{field}:" not in frontmatter:
            # 插入到 closing --- 之前
            frontmatter = frontmatter.replace("---\n", f"{field}: {default}\n---\n", 1)
            # 只替換最後一個 ---（closing）
            # 簡化：直接在倒數第二行插入
    
    # 3. 分離演化記錄
    evolution_marker = re.search(r'\n---\n演化記錄：\n', body)
    if evolution_marker:
        main_body = body[:evolution_marker.start()]
        evolution_log = body[evolution_marker.end() - len("演化記錄：\n"):]
    else:
        # 舊格式：無演化記錄 → 整個 body 都是 current understanding
        main_body = body
        evolution_log = ""
    
    # 4. 分離連結區塊
    links_marker = re.search(r'\n---\n連結：\n', main_body)
    if links_marker:
        current_understanding = main_body[:links_marker.start()]
        links = main_body[links_marker.end() - len("連結：\n"):]
    else:
        current_understanding = main_body
        links = ""
    
    return frontmatter, current_understanding.strip(), links.strip(), evolution_log.strip()
```

### 兩個區塊

| 區塊 | 位置 | 特性 | 操作 |
|------|------|------|------|
| **當前最佳理解** | frontmatter 下方，`演化記錄` 分隔線上方 | 可覆寫 | EVOLVE 時：Haiku 重寫此區塊，同時更新 `updated` frontmatter |
| **演化記錄** | 最下方，`演化記錄：` 標記之後 | append-only | EVOLVE 時：追加一條 `YYYY-MM-DD：因 [來源] 更新，舊觀點：... → 新觀點：...` |

### 演化寫入邏輯

> ### ⚠️ 安全邊界：EVOLVE 只動 `_drafts/`
>
> Phase 2 初期，`update_existing_pearl()` **硬限只能操作 `_drafts/` 目錄下的 card**。
> 如果正式 card（`Ocean/珍珠卡/` 根目錄）被 Haiku 判定為 EVOLVE，**降級為 CREATE**：
> 建一張新 draft 到 `_drafts/`，frontmatter 加 `evolves_from: [[正式card-slug]]`，
> 由人工確認後再手動合併到正式 card。

```python
def update_existing_pearl(card_path: str, candidate: dict):
    """
    更新現有 Pearl card：覆寫上方「當前最佳理解」，追加下方「演化記錄」。
    
    ⚠️ 安全檢查：只允許更新 _drafts/ 目錄下的 card。
    """
    # 安全邊界：硬限 _drafts/
    if "/_drafts/" not in card_path:
        raise ValueError(
            f"EVOLVE 安全邊界：不允許直接更新正式 card: {card_path}。"
            "請改用 create_pearl_draft(evolves_from=...) 降級為 CREATE。"
        )
    
    content = Path(card_path).read_text(encoding="utf-8")
    today = datetime.now().strftime("%Y-%m-%d")
    
    # 解析三個區塊
    frontmatter, current_understanding, links, evolution_log = parse_pearl_sections(content)
    
    # 備份舊觀點（取前 80 字作摘要）
    old_summary = current_understanding.strip()[:80]
    
    # 用 Haiku 重寫「當前最佳理解」
    new_understanding = call_haiku_rewrite_understanding(
        old_understanding=current_understanding,
        new_insight=candidate["insight_text"]
    )
    
    # 找 wikilinks（保留現有 + 嘗試新增）
    existing_links = re.findall(r'\[\[(.+?)\]\]', links)
    new_links = find_related_wikilinks(new_understanding, limit=3)
    all_links = list(dict.fromkeys(existing_links + [l.strip('[]') for l in new_links]))  # 去重保序
    
    # 追加演化記錄
    source_desc = candidate.get("source_quote", "Dream Cycle 對話萃取")[:60]
    evolution_entry = f"- {today}：因 [{source_desc}] 更新，舊觀點：{old_summary}"
    
    # 更新 frontmatter 的 updated 欄位
    frontmatter = re.sub(r'updated: .+', f'updated: {today}', frontmatter)
    if 'updated:' not in frontmatter:
        frontmatter = frontmatter.rstrip('\n') + f'\nupdated: {today}\n'
    
    # 組裝
    links_section = "\n---\n連結：\n" + "\n".join(f"- [[{l}]]" for l in all_links[:5])
    
    if evolution_log:
        evolution_section = evolution_log.rstrip('\n') + "\n" + evolution_entry
    else:
        evolution_section = "演化記錄：\n" + evolution_entry
    
    final_content = (
        f"{frontmatter}\n"
        f"{new_understanding}\n"
        f"{links_section}\n\n"
        f"---\n{evolution_section}\n"
    )
    
    Path(card_path).write_text(final_content, encoding="utf-8")
    
    # 同步更新 pearl_fts 索引
    slug = Path(card_path).stem
    update_pearl_fts_index(slug, candidate["title"], new_understanding)
```

### 演化規則

1. **只有 EVOLVE 判定才觸發覆寫** — SKIP 不動、NEW 建新卡
2. **舊觀點永遠保留在演化記錄** — 不怕丟失歷史判斷
3. **每次演化只改一張卡** — 不連鎖更新相關卡片（避免 cascade 風險）
4. **演化記錄不設上限** — append-only，自然增長
5. **frontmatter `updated` 欄位** — 記錄最後演化日期，方便排序和篩選
6. **⚠️ EVOLVE 只動 `_drafts/`** — 正式 card 被判 EVOLVE 時降級為 CREATE，人工確認後才合併

## on-stop hook 切換 SOP

### 背景

現行 `anya-on-stop-pearl-draft.sh` 在每次 Anya session 結束時呼叫 `pearl_draft_generator.py`，存在以下問題：
- 每次 stop 都跑，同一天多次 stop 產生重複 draft（_drafts 累積 64 個的主因）
- 跑在 shell 環境裡，沒有去重機制
- 無法跟 Dream Cycle 的 Entity/KG 資料聯動

Phase 2 是 on-stop hook 的替代方案：每日跑一次，天然去重，且能利用 Dream Cycle 前面步驟的 context。

### 切換條件

**同時滿足以下三個條件才切換：**
1. Dream Cycle Phase 2 code 已合併且 Step 5.5 在 dry-run 模式驗證通過
2. Phase 2 首次 live mode 成功產出 Pearl（至少 1 個 create 或 update）
3. 產出的 Pearl 品質經老兔或 Anya 人工確認 OK

### 切換步驟

```bash
# 1. 確認 Phase 2 已成功產出 Pearl
cat ~/.claude-bots/logs/dream-cycle/$(date +%Y-%m-%d).json | jq '.output.pearls_created, .output.pearls_updated'
# 應至少有一個 > 0

# 2. 人工確認 Pearl 品質
ls ~/Documents/Obsidian\ Vault/Ocean/珍珠卡/_drafts/
# 檢查最新的 draft 內容是否合理

# 3. 從 Anya 的 settings.json 移除 on-stop hook
# 檔案路徑：~/.claude/projects/-home-oldrabbit--claude-bots-bots-anya/.claude/settings.json
# 找到 hooks.on_stop 陣列，移除 "anya-on-stop-pearl-draft.sh" 條目

# 4. 備份舊腳本（不刪除，以防需要回滾）
# anya-on-stop-pearl-draft.sh 保留在 shared/hooks/ 不動

# 5. 驗證：下次 Anya stop 時確認 pearl-draft.log 沒有新產出
tail -1 ~/.claude-bots/logs/pearl-draft.log
# 時間戳應該停在切換前的最後一次
```

### 回滾方案

如果 Phase 2 的 Pearl 品質不如預期，把 hook 加回去：
```bash
# 在 settings.json 的 hooks.on_stop 重新加入 "anya-on-stop-pearl-draft.sh"
```

## 技術設計

### memory.db Schema：pearl_fts 表

```sql
-- Pearl FTS5 全文搜尋索引（trigram tokenizer 支援中文子字串匹配）
CREATE VIRTUAL TABLE IF NOT EXISTS pearl_fts USING fts5(
    slug,
    title,
    content,
    tokenize='trigram'
);
```

Pearl 寫入時同步索引：
```python
def update_pearl_fts_index(slug: str, title: str, content: str):
    """寫入或更新 pearl_fts 索引。在 create/update Pearl 時同步呼叫。"""
    conn = sqlite3.connect(MEMORY_DB_PATH)
    # 先刪再插（upsert 語意）
    conn.execute("DELETE FROM pearl_fts WHERE slug = ?", (slug,))
    conn.execute(
        "INSERT INTO pearl_fts(slug, title, content) VALUES (?, ?, ?)",
        (slug, title, content)
    )
    conn.commit()
    conn.close()
```

### FTS5 搜尋策略（Pearl 去重）

```python
def fts5_search_pearl(query: str, scope: str = "all", limit: int = 3) -> list[dict]:
    """
    搜尋 pearl_fts 表中的現有 Pearl card。
    
    Args:
        query: 搜尋關鍵字（通常是候選 Pearl 的標題）
        scope: 搜尋範圍
            - "drafts": 只搜 _drafts/（EVOLVE 候選）
            - "published": 只搜正式 card（用於判斷 SKIP，不 EVOLVE）
            - "all": 搜全部
        limit: 回傳上限
    
    Returns:
        [{slug, title, content, scope, path}]
    """
    conn = sqlite3.connect(MEMORY_DB_PATH)
    
    # FTS5 MATCH 搜尋
    rows = conn.execute(
        "SELECT slug, title, content FROM pearl_fts WHERE pearl_fts MATCH ? LIMIT ?",
        (query, limit * 2)  # 多取一些，後面按 scope 過濾
    ).fetchall()
    conn.close()
    
    results = []
    for slug, title, content in rows:
        # 判斷 scope：slug 以日期開頭的通常是 draft
        pearl_dir = Path.home() / "Documents" / "Obsidian Vault" / "Ocean" / "Pearl"
        draft_path = pearl_dir / "_drafts" / f"{slug}.md"
        published_path = pearl_dir / f"{slug}.md"
        
        if draft_path.exists():
            item_scope = "drafts"
            path = str(draft_path)
        elif published_path.exists():
            item_scope = "published"
            path = str(published_path)
        else:
            continue  # 索引中有但檔案已刪
        
        if scope != "all" and item_scope != scope:
            continue
        
        results.append({
            "slug": slug,
            "title": title,
            "content": content[:500],
            "scope": item_scope,
            "path": path,
        })
        
        if len(results) >= limit:
            break
    
    return results
```

### 去重演算法

```
對每個 Haiku 產出的洞見候選：
1. 用候選標題做 FTS5 搜尋（兩層）：
   a. 先搜 _drafts/（scope="drafts"）→ EVOLVE 候選
   b. 再搜正式 card（scope="published"）→ 只用於 SKIP 判斷
2. 如果兩層搜尋結果都為空 → CREATE（新主題）
3. 如果搜尋結果非空：
   a. 取 top-1 結果
   b. 呼叫 Haiku 做 EVOLVE/SKIP/NEW 判斷
   c. EVOLVE + best_match 在 _drafts/ → 更新現有 draft（覆寫上方 + 追加演化記錄）
   d. EVOLVE + best_match 是正式 card → ⚠️ 降級為 CREATE（建新 draft，加 evolves_from）
   e. SKIP → 跳過
   f. NEW → 建新 draft
4. 總產出上限 3 個（create + update 合計）
```

### content_hash 冪等機制

每次 Dream Cycle 記錄已處理的 conversation block hash，重跑時自動跳過。

```python
def get_processed_block_hashes(run_date: str) -> set[str]:
    """取得今天已處理的 conversation block hashes。"""
    conn = sqlite3.connect(MEMORY_DB_PATH)
    row = conn.execute(
        "SELECT pearl_blocks_processed FROM dream_cycle_runs WHERE run_date = ?",
        (run_date,)
    ).fetchone()
    conn.close()
    if row and row[0]:
        return set(json.loads(row[0]))
    return set()

def record_processed_blocks(blocks: list[dict]):
    """將已處理的 block hashes 記錄到 dream_cycle_runs。"""
    today = datetime.now().strftime("%Y-%m-%d")
    new_hashes = [b["content_hash"] for b in blocks]
    
    conn = sqlite3.connect(MEMORY_DB_PATH)
    existing = get_processed_block_hashes(today)
    merged = list(existing | set(new_hashes))
    
    conn.execute(
        """UPDATE dream_cycle_runs 
           SET pearl_blocks_processed = ? 
           WHERE run_date = ?""",
        (json.dumps(merged), today)
    )
    conn.commit()
    conn.close()
```

`dream_cycle_runs` 表新增欄位：
```sql
ALTER TABLE dream_cycle_runs ADD COLUMN pearl_blocks_processed TEXT DEFAULT '[]';
-- JSON array of content hashes，用於 Step 5.5 冪等檢查
```

### Haiku 呼叫預算（Step 5.5）

| 呼叫 | 次數 | Input tokens | Output tokens | 單價 |
|------|------|-------------|---------------|------|
| 洞見萃取 | 1 | ~1500 | ~500 | ~$0.002 |
| 演化判斷 | 0-5 | ~400/次 | ~100/次 | ~$0.002 |
| 理解重寫 | 0-3 | ~600/次 | ~300/次 | ~$0.003 |
| **Step 5.5 合計** | | | | **~$0.01** |

加上 Phase 1 的 ~$0.05，**Phase 2 每日總成本 ~$0.06**。

### Pearl Draft 寫入

```python
def create_pearl_draft(candidate: dict, evolves_from: str = None):
    """
    建立新 Pearl draft 到 Ocean/珍珠卡/_drafts/
    
    Args:
        candidate: Haiku 萃取的洞見候選
        evolves_from: 若為正式 card 降級 CREATE，填入正式 card 的 slug
    """
    today = datetime.now().strftime("%Y-%m-%d")
    slug = slugify(candidate["title"])
    
    # 找相關 wikilinks
    wikilinks = find_related_wikilinks(candidate["insight_text"], limit=3)
    if len(wikilinks) < 2:
        # 不夠 2 個 wikilink，用標題再搜一次
        extra = find_related_wikilinks(candidate["title"], limit=2)
        wikilinks = list(dict.fromkeys(wikilinks + extra))[:3]
    
    links_section = "\n---\n連結：\n" + "\n".join(f"- {l}" for l in wikilinks)
    
    # 動態 author 標注
    source_chat = candidate.get("source_chat", "")
    source_bot = candidate.get("source_bot", "anya")
    
    # frontmatter
    fm_lines = [
        "---",
        "type: card",
        f"source_chat: {source_chat}" if source_chat else None,
        f"source_bot: {source_bot}",
        f"created: {today}",
        "source: Dream Cycle",
        "status: draft",
        f"evolves_from: [[{evolves_from}]]" if evolves_from else None,
        "---",
    ]
    fm = "\n".join(line for line in fm_lines if line is not None)
    
    creation_note = f"- {today}：初始建立，來源：Dream Cycle 對話萃取"
    if evolves_from:
        creation_note += f"（演化自正式 card [[{evolves_from}]]）"
    
    content = (
        f"{fm}\n\n"
        f"# {candidate['title']}\n\n"
        f"{candidate['insight_text']}\n"
        f"{links_section}\n\n"
        f"---\n"
        f"演化記錄：\n"
        f"{creation_note}\n"
    )
    
    drafts_path = Path(DRAFTS_DIR)
    drafts_path.mkdir(parents=True, exist_ok=True)
    
    filename = f"{today}-{slug}.md"
    filepath = drafts_path / filename
    
    counter = 1
    while filepath.exists():
        filepath = drafts_path / f"{today}-{slug}-{counter}.md"
        counter += 1
    
    filepath.write_text(content, encoding="utf-8")
    
    # 同步寫入 pearl_fts 索引
    update_pearl_fts_index(slug, candidate["title"], candidate["insight_text"])
    
    return str(filepath)
```

## 資料模型

### Obsidian 路徑

| 路徑 | 用途 |
|------|------|
| `~/Documents/Obsidian Vault/Ocean/珍珠卡/` | 正式 Pearl card（人工升級後） |
| `~/Documents/Obsidian Vault/Ocean/珍珠卡/_drafts/` | Dream Cycle 產出的 draft（待人工確認） |

### Pearl Card Schema（Obsidian frontmatter）

```yaml
type: card              # 固定值
source_chat: 1050312492 # 來源對話 chat_id（動態）
source_bot: anya        # 產出 bot 名稱（動態，不再硬寫 anya）
created: YYYY-MM-DD     # 初始建立日期
updated: YYYY-MM-DD     # 最後演化日期（可選，演化後才有）
source: Dream Cycle     # 來源標記（區別於舊的 "對話"）
status: draft           # draft | published
evolves_from: [[slug]]  # 可選，正式 card 降級 CREATE 時標注來源
```

### dream_cycle_runs 表擴充（Phase 2）

在 Phase 1 的 `report_json` 中新增 Pearl 相關欄位：

```json
{
  "output": {
    "...existing Phase 1 fields...",
    "pearls_created": 2,
    "pearls_updated": 1,
    "pearls_skipped": 2,
    "pearl_details": [
      {
        "action": "create",
        "title": "卡片標題",
        "path": "Ocean/珍珠卡/_drafts/2026-04-11-xxx.md"
      },
      {
        "action": "update",
        "title": "被更新的卡片",
        "path": "Ocean/珍珠卡/_drafts/existing-draft.md",
        "old_summary": "舊觀點前 80 字..."
      }
    ]
  }
}
```

新增欄位：
```sql
ALTER TABLE dream_cycle_runs ADD COLUMN pearl_blocks_processed TEXT DEFAULT '[]';
-- JSON array of content hashes，用於 Step 5.5 冪等檢查
```

### dream_cycle_changes 表（Phase 2 新增 change_type）

| change_type | 說明 |
|------------|------|
| `pearl_create` | 新建 Pearl draft |
| `pearl_update` | 更新現有 Pearl draft（演化） |

沿用 Phase 1 的 `before_value` / `after_value` 欄位記錄 diff。

## 實作計劃

### 前置任務（Phase 2 開發前）

| 任務 | 負責 | 產出 |
|------|------|------|
| _drafts dedup 清理 | Anna | `pearl-dedup-report.json` + 清理後的 _drafts 目錄 |
| 建立 pearl_fts 表並驗證索引 pipeline | Anna | memory.db 新增 pearl_fts 表 + 初始索引匯入 |
| Phase 1 穩定性確認 | Anya | 連續 7 天 run log 無 error |

### Phase 2 開發任務

| # | 任務 | 產出 | 預估 |
|---|------|------|------|
| 1 | 建立 `pearl_fts` 表並在 Dream Cycle 寫 Pearl 時同步索引 | memory.db schema + `update_pearl_fts_index()` | 0.5 天 |
| 2 | 實作 `fts5_search_pearl()` 搜尋函式（兩層 scope） | `dream_cycle.py` 新增函式 | 0.5 天 |
| 3 | 實作 `parse_pearl_sections()` parser | 支援新舊格式 + edge case 處理 | 0.5 天 |
| 4 | 實作 `step_5_5_pearl_generation()` 主流程 | 洞見萃取 + 去重 + 分流 + 冪等 | 1 天 |
| 5 | 實作 Pearl 演化寫入（`update_existing_pearl`，含安全邊界） | Compiled Truth 格式寫入 + _drafts 硬限 | 0.5 天 |
| 6 | 實作 `create_pearl_draft()`（含 evolves_from 降級） | frontmatter 動態標注 + wikilinks + 演化記錄 | 0.5 天 |
| 7 | Haiku prompt 調優（萃取 + 判斷 + 重寫） | 3 個 prompt template | 0.5 天 |
| 8 | 整合進 Dream Cycle pipeline + checkpoint | Step 5.5 checkpoint 邏輯 | 0.5 天 |
| 9 | Report 擴充（Pearl 欄位 + TG 通知） | report_json 新增 pearl_* 欄位 | 0.5 天 |
| 10 | content_hash 冪等機制 | `pearl_blocks_processed` 欄位 + get/record 函式 | 0.5 天 |
| 11 | Dry-run 測試 + 品質驗證 | 跑 3 天 dry-run，人工審核 Pearl 品質 | 3 天 |
| 12 | 切換 on-stop hook（品質確認後） | settings.json 更新 | 0.5 天 |

**總計：~9 天**（含 3 天 dry-run 驗證期）

## 驗收標準

### 功能驗收

- [ ] `pearl_fts` 表已建立，寫入 Pearl 時同步索引
- [ ] Step 5.5 在 dry-run 模式正常執行，report 包含 `pearls_created/updated/skipped` 欄位
- [ ] live mode 成功建立 Pearl draft 到 `Ocean/珍珠卡/_drafts/`
- [ ] Pearl draft 格式正確：frontmatter 含 type/source_bot/created/source、body ≤ 300 字、≥ 2 個 wikilinks
- [ ] Pearl draft 包含「演化記錄」區塊（初始建立記錄）
- [ ] 演化機制：對已有相似主題的 card，正確判斷 EVOLVE/SKIP/NEW
- [ ] EVOLVE 操作（_drafts 內）：覆寫「當前最佳理解」+ 追加「演化記錄」+ 更新 `updated` frontmatter
- [ ] **⚠️ EVOLVE 安全邊界**：正式 card 判定 EVOLVE 時降級為 CREATE，frontmatter 含 `evolves_from`
- [ ] 每次 Dream Cycle 產出上限 3 個 Pearl（create + update 合計）
- [ ] 同一天跑兩次，第二次不產出重複 Pearl（冪等 — 透過 content_hash 檢查）

### 去重驗收

- [ ] FTS5 搜尋（pearl_fts 表）能正確找到現有 Pearl card
- [ ] 搜尋分兩層：_drafts 和正式 card 各自獨立搜尋
- [ ] 對已存在的洞見，SKIP 率 > 50%（避免重複產出）
- [ ] _drafts dedup 完成後，draft 數量從 ~64 降至合理範圍（< 20）

### 品質驗收

- [ ] Pearl 產出品質不低於現有 `pearl_draft_generator.py`
- [ ] Haiku 洞見萃取的 precision > 70%（人工抽檢：10 張 draft 中至少 7 張確實是洞見）
- [ ] 演化判斷的 accuracy > 80%（人工抽檢：EVOLVE/SKIP/NEW 判斷正確）
- [ ] `parse_pearl_sections()` 正確處理新舊格式 + 缺欄位 edge case

### 切換驗收

- [ ] on-stop hook 移除後，Pearl 只從 Dream Cycle 產出
- [ ] pearl-draft.log 不再有新產出（確認 hook 已停止）
- [ ] 連續 3 天 Dream Cycle 正常產出 Pearl，無回歸

### 成本驗收

- [ ] Step 5.5 每日 API 成本 < $0.02
- [ ] Phase 2 整體每日成本 < $0.10

## 注意事項 / 風險

1. **Pearl 品質稀釋（中）** — 自動萃取的品質可能不如人工判斷。對策：產出上限 3 個 + draft 機制（人工確認後才升為正式）+ dry-run 先行驗證。

2. **演化判斷誤判（中）** — Haiku 可能把不相關的 card 判定為 EVOLVE，覆寫掉有價值的觀點。對策：**Phase 2 硬限 EVOLVE 只動 `_drafts/`**，正式 card 降級為 CREATE + 演化記錄保留舊觀點全文（可回溯）。

3. **FTS5 搜尋品質（低）** — trigram tokenizer 支援中文子字串匹配，但可能漏掉語意相似但用詞不同的 card。對策：Phase 1 用標題 + 正文搜尋；未來可引入 embedding similarity。

4. **_drafts 再次膨脹（低）** — 即使有去重機制，長期運行仍可能累積大量 draft。對策：產出上限 3 個/天 + 定期人工清理 cron（每月提醒一次）。

5. **Obsidian 同步衝突（低）** — Dream Cycle 在凌晨 3 點寫入，此時 Obsidian 通常不在使用中。但若有 Obsidian Sync 啟用，需注意衝突解決。

## 變更日誌

- 2026-04-11 v2：解決 Bella 兩個 blocker + 三項 minor
  - **Blocker 1**：FTS5 搜尋改為 memory.db `pearl_fts` 表（trigram），移除 Obsidian MCP 依賴
  - **Blocker 2**：EVOLVE 硬限 `_drafts/`，正式 card 降級為 CREATE（加 `evolves_from`）
  - Minor 1：content_hash 冪等（`pearl_blocks_processed` 欄位）
  - Minor 2：`parse_pearl_sections()` parser 定義（新舊格式 + edge case）
  - Minor 3：author 改為動態 `source_chat` + `source_bot`
- 2026-04-11 v1：初始版本，基於老兔決策（Bella 轉達）
