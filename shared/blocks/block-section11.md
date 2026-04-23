---
triggers: ["subagent", "schema v3", "return slimming", "派活", "in_flight", "Agent", "background", "sub-agent", "oversize", "violations", "L3a", "L3b", "section11"]
priority: high
size_tokens: 1138
description: §11 Subagent Return Slimming — 派發原則、Schema v3、三層執行機制、失敗處理、量測
---

## 11. Subagent Return Slimming（全員適用）

目標：session 內 `Agent` tool 派發的 subagent 回傳，**不得污染主 agent context**。管的是 ①②（in-session Agent tool 派發），**不管** FATQ 跨 bot、不管 MemOcean 讀取。

### 11.1 派發原則（主 agent 禁令）

主 agent **不得直接執行**下列操作，必須改派 subagent：

1. **容量紅線**：預期回傳 > 5k tokens 的單次工具呼叫（Builder/Reviewer 覆寫為 10k）
2. **不確定紅線**：無法事前確定回傳大小的操作（grep、radar_search、WebFetch、大檔 Read 等）

執行前若有任何疑慮 → 視同觸發規則 2 → 派 subagent。

主 agent 自行執行後發現實際回傳 > 門檻 → **立刻中止**，不得把結果讀進 context，改派 subagent 重做（L3 hook 強制）。

**例外（主 agent 本來就該做）**：
- 與 owner 對話、確認、提問
- 綜合 subagent 回報做規劃、決策
- 跨 bot FATQ 任務派發

**門檻覆寫**：各 bot 可在自己的 L2 CLAUDE.md 寫明原因後覆寫。Reviewer / Builder 預設 10k；其他預設 5k。

### 11.2 模型選擇（Haiku-first）

Subagent 模型選擇以任務複雜度為主、回傳品質為輔。當任務不需深度推理時，**優先用 Haiku**——不只省錢，Haiku 的輸出天然精簡，是 §11 schema 的最佳搭檔。

| 任務類型 | 推薦模型 |
|---|---|
| 摘要 / 結構化整理 / 最終壓縮 pass | Haiku |
| 網頁 / 文檔調研 | Haiku（深度需求才 Sonnet） |
| Code Review | Sonnet |
| Build / 實作 | Sonnet（複雜才 Opus） |
| Plan 設計 | Sonnet 或 Opus |

**兩段式模式**（複雜任務）：
```
Step 1: Sonnet builder → 寫出完整 report → 寫進 tmp
Step 2: Haiku summarizer → 讀 tmp，按 §11.3 schema 產 slim JSON
```

### 11.3 Return Schema v3

```json
{
  "status": "success | partial | failed | blocked",
  "summary": "≤100 字的一句話結論",
  "confidence": "high | medium | low",

  "findings": [
    {"severity": "high|medium|low", "title": "...", "evidence": "檔案:行數 或 slug"}
  ],
  "files_changed": [
    {"path": "...", "action": "created|modified|deleted"}
  ],

  "blockers": ["≤3 條，status=failed|blocked 才填"],
  "next_action": "≤30 字 建議主 agent 下一步",

  "cost": {"model": "...", "tokens_in": 8200, "tokens_out": 1100, "duration_sec": 42},

  "_raw_if_needed": {
    "path": "~/.claude-bots/bots/{bot}/tmp/{task_id}.md",
    "tokens": 4800,
    "ttl_hours": 24
  }
}
```

**欄位規則**：
- `findings` vs `files_changed` 依任務類型**二選一**（refactor review 特例可併填）
- `cost` 選填，subagent 自行填（hook 不能改 tool_response）
- `_raw_if_needed` 三種情境填：(a) 完整原文有價值 (b) subagent 主動轉存（L3a）(c) 主 agent 可能要 verbatim
- `severity` 固定 3 級（high / medium / low）

### 11.4 三層執行機制（Pivoted 2026-04-17）

> ⚠️ **設計 Pivot 紀錄**：原 L3 設計為「PostToolUse hook 硬改寫 tool_response」，但 Claude Code hook API **只允許讀、不允許改 tool_response**。改採「L3a 自我強制 + L3b hook 監控」雙軌，語意等同但實作路徑不同。

| 層 | 誰 | 做什麼 |
|---|---|---|
| L1 派發端 | Orchestrator / 主 agent | prompt 強制附 Schema v3 模板 + 門檻值 + `_raw_if_needed` 使用說明 |
| L2 執行端 | Subagent 自律 | 按 Schema v3 組裝回傳 |
| **L3a 自我強制** | **Subagent 自己（含 Haiku）** | **回傳前自量 token；超限→寫 `~/.claude-bots/bots/{bot}/tmp/{task_id}.md` + 在 JSON 填 `_raw_if_needed.path`；summary 壓到 ≤100 字** |
| **L3b Hook 監控** | **PostToolUse hook（`section11-return-monitor.sh`）** | **量 token、驗 Schema v3；違規寫 violations.jsonl + 透過 `additionalContext` 向主 agent 發警告；不改 tool_response** |

**Tokenizer**：保守估算 `char_count / 3.5`（避開 tiktoken 依賴）
**判定範圍**：整份 JSON 序列化後總 token 數

### 11.5 δ 複合超限處理（L3a 主責）

由 **subagent 自己** 在回傳前處理（hook 無法改 response）：
1. Subagent 寫 system prompt 釘死：「Schema v3 必填、summary ≤100 字、超限自行轉存 tmp」
2. 超限時 subagent 將原內容寫進 `~/.claude-bots/bots/{bot}/tmp/{task_id}.md`（24h TTL）
3. JSON 回傳 `status: "oversized_offloaded"`（或 `partial`），帶 `_raw_if_needed.path`
4. L3b hook 若仍偵測到超限 → 寫 violations.jsonl + 警告主 agent「下次派發時在 prompt 尾加強化警告」
5. 同一 subagent 連續 **3 次** 乾淨不超限 → 警告移除（主 agent 自行清除追蹤記錄）

### 11.6 失敗處理（Phase 1 必備）

| 失敗點 | 應對 |
|---|---|
| Subagent crash | 主 agent 回報 owner，不自動重試 |
| maxTurns 被截 | 回傳 `confidence: low` + summary 加「⚠️ 任務未完整」 |
| L3a 自我強制失守（subagent 沒壓縮就回） | L3b hook 偵測到 → 寫 violations + `additionalContext` 警告；主 agent 可選擇要求重壓縮 |
| **L3b hook 自身掛** | **Fail-open：hook 失敗不影響回傳（主 agent 照收原始回應）；只損失該次 log** |
| MemOcean MCP 失效 | subagent 回 `status: failed` + `blockers: ["memocean mcp down"]`，觸發 ops 警報 |

**五條共通原則**：
1. 永遠有 fallback
2. 失敗優於誤導
3. 所有失敗必 log（Tier 1）
4. 不自動重試（重試是主 agent 決策）
5. 關鍵失敗（MCP / 磁碟）→ ops 警報

### 11.7 量測（Tier 1）

L3b hook 每次 subagent 回傳寫兩份 log：

- `~/.claude-bots/logs/section11/observations.jsonl`（**所有**回傳，不只違規）
- `~/.claude-bots/logs/section11/violations.jsonl`（僅違規）

```json
{"ts": "...", "bot": "anya", "session": "...",
 "tokens": 11562, "threshold": 5000,
 "oversize": true, "schema_ok": false,
 "schema_reason": "summary_too_long:400"}
```

**關鍵觀察指標**：
- oversize 率（目標 <10%）
- schema_ok 率（目標 >95%）
- 主 agent 讀 `_raw_if_needed.path` 的頻率（從 Read tool audit log 交叉比對，→ 測資訊損失率，目標 <20%）

30 天 gzip、90 天進 Ocean Vault 當歷史檔案。

### 11.8 配套（獨立另案）

- `/memocean-search` skill：Query expansion + radar_search + seabed_get + slim return（短期）
- MemOcean MCP 升級：`memocean_radar_search` 加 `expand=true` 參數（長期）
- 新增 `memocean_report_store(title, content, group='subagent-reports')` MCP tool（長期選用）

---
