# Usage: /memocean-research

## 觸發條件

下列情境 **立即觸發** /memocean-research，不要先 WebSearch：

| 情境 | 觸發詞範例 |
|---|---|
| 老兔要求研究 | 「研究 X」「了解 X」「幫我找 X 的資料」 |
| 要建立新 Pearl | 「整理成 pearl card」「記到 vault」 |
| 要寫需要知識底蘊的提案 | 「寫一份關於 X 的提案」「分析 X 市場」 |
| 回答需查資料的問題 | 「X 是什麼」「X 跟 Y 有什麼差別」（答案不確定時）|

**不觸發** 的情境：
- 簡單問候 / 任務分派
- 已明確知道答案且在 Vault 有記錄
- 技術實作（不需研究，需用 /plan-eng-review）

---

## 執行 Checklist

```
[ ] Step 1: memocean_search(query, limit=10)
[ ] Step 1: memocean_radar_search(query, limit=5)
[ ]   → 命中 >= 3 高相關？ → 跳到 Step 3
[ ]   → 命中 < 3 高相關？  → 執行 Step 2
[ ] Step 2: WebSearch(query)（僅在 Step 1 不足時）
[ ] Step 3: 寫 Pearl 草稿到 Ocean/_drafts/<slug>-draft.md
```

---

## 範例 Invocation

### 情境 A：老兔說「研究 AIGC 版權現況」

```
1. memocean_search("AIGC 版權 copyright AI generated content")
   → 命中 2 個（不足）
2. WebSearch("AIGC 版權 2026 台灣 中國")
   → 找到 3 篇文章
3. 整合寫入 Ocean/_drafts/aigc-copyright-draft.md
```

### 情境 B：老兔說「你知道 GEO 現況嗎」

```
1. memocean_search("GEO generative engine optimization")
   → 命中 5 個（足夠，跳過 WebSearch）
2. 整合 Vault 資料寫入 Ocean/_drafts/geo-status-draft.md
```

---

## Pearl 草稿命名規則

- 路徑：`~/Documents/Obsidian Vault/Ocean/_drafts/<slug>-draft.md`
- slug：用研究主題的英文 kebab-case，例如 `aigc-copyright`、`geo-market-2026`
- 若研究是對話萃取（無外部來源）：`sources: []`
- 若有外部來源：`sources: ["url1", "url2"]`

---

## 預期輸出格式

完成後回報：

```
✅ /memocean-research 完成

Vault 命中：X 個
外部搜尋：有/無
草稿：Ocean/_drafts/<slug>-draft.md

核心發現（3 點）：
1. ...
2. ...
3. ...
```

---

## 常見錯誤

| 錯誤 | 正確做法 |
|---|---|
| 直接 WebSearch 跳過 Vault | 永遠先跑 Step 1 |
| 草稿沒有 wikilink | 每份草稿至少 2 個 [[相關頁面]] |
| draft: true 沒設 | 草稿必須帶 `draft: true` frontmatter |
| 沒呼叫 skill 就寫 Pearl | 一定要跑完 3 步驟再存 |
