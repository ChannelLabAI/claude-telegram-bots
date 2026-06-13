---
triggers: ["sub-agent", "subagent", "派活", "background agent", "think hard", "決策題", "model 選擇"]
priority: high
size_tokens: 1050
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

**上方 Extended Thinking 觸發條件命中時，主 Sonnet session 不得硬答**，必須開 Opus background sub-agent 處理：

1. **觸發**：取捨詞 / 觀點題 / 話短背景複雜 / 跨職能戰略判斷 / [ESCALATION] 情境
2. **流程**：Sonnet 辨識 → TG 跟主人說「我 think hard 一下，~1 分鐘」→ 用 `Agent` tool 開 background agent 帶 `model: "opus"` + 當前 context + 具體問題 → 等 Opus 回 → Sonnet 整理後 TG reply
3. **不觸發**：群組 ack / 派活 / 進度同步 / 事實查詢 / 任務接單 / 格式轉換 — Sonnet 自己處理
4. **成本考量**：Opus 比 Sonnet 貴約 5x，所以 Sonnet 能答的不走 Opus；但戰略判斷不省這筆

老兔 msg 12977/12981（2026-04-19）全員強制規則：執行層 Sonnet 做 I/O，Opus 只在決策時上場。相關：[[Bot-Team-Architecture]]

## Sub-Agent 模型選擇

耗時工作一律用 `Agent` tool + `run_in_background=true` 開 background sub-agent，主 session 保持空閒接訊息。模型依任務性質選：

| 模型 | 適用場景 |
|---|---|
| **Opus** | 商業策略、方向性建議（「值不值得做」）、意圖不明、複雜 spec / 提案、[ESCALATION]、重大金額或資安決策 |
| **Sonnet** | 研究、整理、多步驟分析、開發任務、需用工具的中等複雜工作 |
| **Haiku** | 批量處理、格式轉換、分類、簡單摘要、大量重複性輕量任務 |

> 📌 **模型別名與 full ID 的權威定義在 `shared/config/model-router.yml`**（bot_defaults + models 區段）。本表只說「任務→別名」對應，不重複 full ID——消費端認別名，full ID 在 yml 單一維護。
> ⚠️ **派 Haiku 任務必須在 Agent tool prompt 明寫 `model: "haiku", maxTurns: 20`**，否則繼承主 session 模型。

### 派活兩條鐵律
1. **先規劃再動手**：複雜任務先讓 agent 出計畫，確認方向對了再開跑。
2. **重要任務加「think hard」**：spec 撰寫、架構決策、商業策略、複雜 debug 加此指令。

### 派 sub-agent 紀律（§11 配套）
- prompt 必附 **Schema v3** 回傳模板（否則觸發 §11 L3 violations）
- 明令「**只回傳給我、不准呼叫 TG/對外發訊**」（防 agent 用特助身份繞過綜合直接發主人）
- 並行 sub-agent 時 git 操作**禁用 `git add -A`**，一律列明路徑

---

## Diana 雙向協作（2026-06-13 全隊上線）

Diana = 公司 AI 核心。你跟 Diana 現在是**雙向**的，今後這樣用：

1. **你的 inbox 會收到 Diana 推的東西**：Diana 消化全公司對話後，會把跟**你負責人相關**的洞察 / 衝突 / 逾期待辦推進你的 `inbox/messages/`（檔名 `diana-push-*`）。**開機自檢時要讀、判斷要不要跟進**——這是主動情報，不是雜訊。處理完它會自然去重不重推。

2. **你可以主動問 Diana**（`diana:query`）：談判前、寫 spec 前、做決策前，先問 Diana「這個客戶/主題之前談過什麼？有沒有相關衝突或承諾？」。純讀、≤5s、無 LLM 成本。用法見你 CLAUDE.md 的 `shared/blocks/block-diana-query.md` 載入行。**養成查 Diana 的習慣，別重複踩前人踩過的、別漏掉已有承諾。**

3. **餵料是自動的**：你對話結束時 Stop hook 自動餵 slug 給 Diana，不用手動做什麼。

> 一句話：**Diana 會主動餵你情報、你也該主動問它**。這是讓全團隊不製造資訊孤島的核心機制。詳見 [[ChannelLab-AI-系統架構-2026-06]]、[[project_diana_company_agent]]。
