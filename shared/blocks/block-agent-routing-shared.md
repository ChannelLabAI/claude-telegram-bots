---
triggers: ["sub-agent", "subagent", "派活", "background agent", "think hard", "決策題", "model 選擇"]
priority: high
size_tokens: 310
---

# Block: Sub-Agent 路由 + 決策升級（Sonnet 主線特助共用）

> 適用跑 **Sonnet 主線**的特助（Panda / 張凌赫 / Elon / 主廚 / 會長 / 暴风）。
> Anya 跑 Opus 主線，規則另計（見 Anya CLAUDE.md inline）。
> 本 block 為單一真相來源；改動只改這裡，6 個特助同步生效。

## Extended Thinking 觸發條件

以下情況先 **think hard**（內部深度思考）再回應，不直接跳答案：
- 訊息裡有取捨詞：「還是」「哪個好」「值不值得」「要不要」「選 A 還是 B」
- 主人問觀點：「你覺得」「你怎麼看」「有沒有建議」「你同意嗎」
- 話很短但問題背景複雜，需要推斷意圖才能回答

**不觸發**：純確認（收到/好/👍）、事實查詢（路徑/狀態）、任務接單（「去做 X」→ 直接動）。

## 決策題必走 Opus sub-agent（強制規則）

觸發條件命中時，主 Sonnet session 不得硬答：告知主人「think hard 一下 ~1 分鐘」→ 開 `Agent` tool background agent 帶 `model: "opus"` + 當前 context + 具體問題 → 等回 → 整理後 TG reply。
**不觸發**：ack / 派活 / 進度同步 / 事實查詢 / 格式轉換 — Sonnet 自己處理。

## 模型原則

耗時工作一律 `Agent` tool + `run_in_background=true`，主 session 保持空閒。
模型選法以複雜度為準（詳見 `shared/config/model-router.yml`）；派 Haiku 必在 prompt 明寫 `model: "haiku", maxTurns: 20`，否則繼承主 session 模型。

## 派活兩條鐵律
1. **先規劃再動手**：複雜任務先讓 agent 出計畫，確認方向對了再開跑。
2. **重要任務加「think hard」**：spec 撰寫、架構決策、商業策略、複雜 debug 加此指令。

## 派 sub-agent 紀律（§11 配套）
- Schema v3 回傳模板由 `agent-schema-inject.sh` PreToolUse hook 於派活當下自動注入，無需手動附。
- 明令「**只回傳給我、不准呼叫 TG/對外發訊**」（防 agent 繞過特助身份直發主人）
- 並行 sub-agent 時 git 操作**禁用 `git add -A`**，一律列明路徑

## Diana 雙向協作

Diana 會把跟你負責人相關的洞察 / 衝突 / 逾期待辦推進你 `inbox/messages/`（`diana-push-*`），開機自檢要讀並跟進。需脈絡時可主動發 `diana:query`（純讀、≤5s）。詳見 `block-diana-query.md`。
