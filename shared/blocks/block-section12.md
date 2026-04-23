---
triggers: ["compact", "壓縮", "200k", "proactive compact", "context rot", "transcript", "AGENT_MEMO", "must-keep", "backup", "section12", "precompact"]
priority: medium
size_tokens: 730
description: §12 Proactive Compact（7 特助適用）— 觸發條件、Must-Keep 6 條、備份注入流程、失敗處理
---

## 12. Proactive Compact（7 特助適用）

目標：防止 Context Rot（模型在 300-400k 後表現下降），主動在 200k 觸發壓縮。

### 12.0 適用範圍

**只套 7 特助**：Anya / Panda（ron-assistant）/ Zhang Linghe（nicky-zhanglinghe）/ Elon Musk（chltao）/ 主廚（caijie-zhuchu）/ 風風（lilai-fengfeng）/ Wes_buddy

**不套**其他 bot——Builder/Reviewer 被 maxTurns 天然限制，不會破 200k。

### 12.1 觸發（Pivoted 2026-04-17：備份+注入 取代 hook 改寫）

> ⚠️ **設計 Pivot 紀錄**：原設計為「Stop hook 讀 transcript → Haiku 重寫 → 寫回」，但 Stop hook **只能讀 transcript、不能寫回**。改採雙管：
> (a) **依賴 Claude Code 原生 auto-compact**（設 `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=0.85`，170k 觸發）
> (b) **外部備份 + 注入**：Stop hook 於 transcript >500KB 時快照 Must-Keep 6 到 `~/.claude-bots/state/_compact_backup/{bot}/{session}.json`；SessionStart hook 於 24h 內讀回並透過 `additionalContext` 注入主 agent

觸發條件（`section12-precompact-backup.sh`）：
- Bot L2 CLAUDE.md 帶 `§12 ✅ 適用` 標記
- transcript JSONL 檔 >500KB（對應 ~100-150k tokens）

### 12.2 Must-Keep 6 條（備份目標 ≤8k）

Compact 時以下內容**必須**完整保留：

1. **任務總狀態**：FATQ 進度（已派 / in_flight / pending 清單，附 task_id）*（由主 agent 於 Post-Compact 自行從 FATQ 確認）*
2. **Subagent 產物索引**：§11 產出的 seabed_slug 與 `_raw_if_needed.path`（hook regex 從 tool_result 抽出）
3. **`${owner}` 最後一次指令**（變數，由各 bot L2 定義 owner；原文保留最多 3000 字）
4. **近期對話脈絡**：與 owner 最近 5 組往返（每則 800 字）
5. **Session 內部半成品**：最後一則帶 tool_use 的 assistant 訊息（1500 字）
6. **主 agent 自我狀態**：transcript 中最後一個 `<!-- AGENT_MEMO -->...<!-- /AGENT_MEMO -->` 區塊（2000 字）

### 12.3 執行流程

**Stage 1 — Pre-Compact 備份**（`section12-precompact-backup.sh`，Stop hook）
- 讀 transcript_path（JSONL），python3 heuristic 抽 Must-Keep 6 條
- 寫 `~/.claude-bots/state/_compact_backup/{bot}/{session_id}.json`
- 寫 `~/.claude-bots/logs/section12/backups.jsonl`
- 每次 Stop 都覆寫同 session 的備份（保最新）

**Stage 2 — Claude Code 原生 Auto-Compact 執行**
- 由 Claude Code 處理實際壓縮；不由我們接手

**Stage 3 — Post-Compact 注入**（`section12-inject.sh`，SessionStart hook）
- 找該 bot 最近 24h 內最新備份
- 組成 `additionalContext` 文本注入主 agent
- 備份移至 `consumed/`（保 7 天供稽核）

### 12.4 驗證（deterministic，主 agent 輔助）

**Layer 1 — Hook 備份完整性**（自動）
- backup JSON 存在、must_keep 6 項至少 3 項非空、檔案 size >500 bytes

**Layer 2 — 注入成功確認**（自動）
- SessionStart hook 的 injects.jsonl 記錄 event="inject" → 證明 additionalContext 已送出

**Layer 3 — 主 agent 自檢**（prompt 要求）
- 主 agent 收到 `📦 §12 Compact 後恢復` 開頭的 additionalContext 時，下一輪自檢 6 條 must-keep，任何缺失寫 `<!-- COMPACT_ANOMALY: reason -->` 標記

### 12.5 失敗處理（γ 兩階段）

**輕微 anomaly（備份缺 1-2 條 / AGENT_MEMO 漏）**
→ 主 agent **靜默** `memocean_radar_search` 補脈絡，繼續工作

**嚴重 anomaly（6 條缺 3+ / Layer 2 無注入紀錄 / 不知道在幹嘛）**
→ 主 agent **主動報告 `${owner}`**（TG），請求補資訊
→ 同時 ops 警報（log 連續 3 次嚴重失敗 → TG @ oldrabbit）

### 12.6 量測（Tier 2）

兩份 log：

- `~/.claude-bots/logs/section12/backups.jsonl`：每次快照（含 transcript_bytes, session）
- `~/.claude-bots/logs/section12/injects.jsonl`：每次注入（含 source=startup/resume/compact）

週度統計：
- 備份覆蓋率 = backups / Stop 次數中 transcript>500KB 的比例（目標 ≥95%）
- 注入成功率 = injects / 24h 內有備份的新 session（目標 ≥90%）
- 嚴重 anomaly 率（目標 <5%，由主 agent 自回報 `COMPACT_ANOMALY` 標記統計）
