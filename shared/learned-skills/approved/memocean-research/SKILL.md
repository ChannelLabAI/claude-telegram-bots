# Skill: /memocean-research — Vault-First 研究流程

## 是什麼

統一的知識研究流程，強制「Vault 優先」：先查 MemOcean / Ocean，再視情況補外部搜尋，最後寫 Pearl 草稿回存知識庫。讓 5 特助都走同一套，避免重複研究、孤立產出。

## 三步驟流程

### Step 1 — Vault 搜尋（必做）

呼叫 `memocean_search` MCP tool，查詢關鍵字 / 問題。

```
memocean_search(query="<研究主題>", limit=10)
```

同時呼叫 `memocean_radar_search` 查 CLSC skeleton：

```
memocean_radar_search(query="<研究主題>", limit=5)
```

**判斷門檻**：若 `memocean_search` 命中 **≥ 3 個高相關結果**（relevance > 0.7 或有直接回答），**跳過 Step 2**（節省 WebSearch API 成本）。

### Step 2 — 外部補充（條件觸發）

僅當 Step 1 命中 < 3 個高相關結果時執行。

使用 WebSearch MCP tool（Brave 瀏覽器）：

```
WebSearch(query="<研究主題>")
```

搜尋結果整合進研究摘要，附上來源 URL。

### Step 3 — 寫 Pearl 草稿（必做）

研究完成後，在 `~/Documents/Obsidian Vault/Ocean/_drafts/` 寫入 Pearl 草稿：

```
obsidian_write(path="Ocean/_drafts/<slug>-draft.md", content=<draft_content>)
```

**草稿格式**：

```markdown
---
draft: true
sources: ["url1", "url2"]  # 外部來源；若純 Vault 來源則留空
created: YYYY-MM-DD
tags: [pearl, draft]
---

# <研究主題>

## 核心發現

<3-5 bullet points>

## 背景 / 脈絡

<段落>

## 相關 Ocean 節點

- [[相關頁面1]]
- [[相關頁面2]]
```

## 什麼時候用這個 skill

每次特助（Anya / Anna / Panda / 張凌赫 / 桃桃 / 主廚）執行以下任一動作前：
- 老兔要求「研究 X」「了解 X」「整理 X 的資料」
- 要寫一份需要知識底蘊的報告 / 提案
- 要建立新的 Pearl card
- 要回答需要查資料才能答的問題

→ **先跑 /memocean-research**，不要直接 WebSearch 或憑記憶回答。

## 為什麼存在

2026-05-07 老兔觀察：各特助各自研究同一主題，Vault 裡已有的 Pearl 被無視，重複 WebSearch 浪費成本，產出的 note 沒有 wikilink 成為孤立節點。此 skill 把 CLAUDE.md 的「CLSC 先查（Step 0）」規則標準化為可呼叫的 /memocean-research 指令。

## 邊界（out of scope）

- 不處理 YouTube 字幕擷取
- 不整合 Grok / Perplexity（本版只用 memocean_search + WebSearch）
- 草稿不自動升格為正式 Pearl（需老兔或 Anya 人工審核後移出 _drafts/）
- 不修改 memocean_search 工具行為
