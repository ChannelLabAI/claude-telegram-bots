---
triggers: ["subagent", "schema v3", "return slimming", "派活", "in_flight", "Agent", "background", "sub-agent", "oversize", "violations", "L3a", "L3b", "section11"]
priority: high
size_tokens: 130
description: §11 Subagent Return Slimming — 派發原則（開機版）。Schema v3 / 三層機制 / 失敗 / 量測完整 SOP 見 /section11-sop skill
---

## 11. Subagent Return Slimming（全員適用 · 原則）

目標：session 內 `Agent` tool 派發的 subagent 回傳，**不得污染主 agent context**。管 in-session Agent tool 派發，**不管** FATQ 跨 bot、MemOcean 讀取。

### 11.1 派發紅線（主 agent 禁令）

主 agent **不得直接執行**下列操作，必須改派 subagent：

1. **容量紅線**：預期回傳 > 5k tokens 的單次工具呼叫（Builder/Reviewer 覆寫為 10k）
2. **不確定紅線**：無法事前確定回傳大小的操作（grep、radar_search、WebFetch、大檔 Read 等）

執行前有任何疑慮 → 視同觸發規則 2 → 派 subagent。
自行執行後發現超限 → **立刻中止**，不讀進 context，改派重做。

**例外**：與 owner 對話 / 規劃決策 / FATQ 跨 bot 派發。
**門檻覆寫**：各 bot 可在 L2 CLAUDE.md 寫明原因後覆寫（Reviewer/Builder 預設 10k）。

### 11.2 模型原則

Subagent **能用 Haiku 就用 Haiku**（省錢 + 輸出天然精簡）；複雜推理才升 Sonnet/Opus。
派 Haiku 時 Agent prompt 必寫 `model: "haiku", maxTurns: 20`，否則繼承主 session 模型（費用 ×12）。

> Schema v3 回傳模板由 `agent-schema-inject.sh` PreToolUse hook 於派活當下自動注入，無需手動附。
> 三層機制 / 超限處理 / 失敗矩陣 / 量測 SOP → 需要時調用 `/section11-sop` skill。

---
