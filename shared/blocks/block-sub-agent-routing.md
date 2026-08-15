---
triggers: ["sub-agent", "background agent", "派活", "background_run", "in_flight", "pool", "Builder pool", "Reviewer pool", "並行", "parallel", "三菜", "一湯", "Eric", "KKKK", "Anna 忙", "Bella 忙", "耗時", "吃 token", "dispatch"]
description: "Load when spawning sub-agents, routing tasks to pool members, or managing in-flight work"
priority: medium
size_tokens: 890
---

# Block: Sub-Agent Routing

> 職責邊界：本 block 只管「怎麼派」：適合與不適合的工作、操作模式、回傳瘦身與 in_flight 管理。「派給誰」一律以 `shared/config/bot-routing.yml` 為權威來源；Designer pod 詳表見 `shared/blocks/block-agent-routing-shared.md`，本檔不得重複維護人員池名單。

老兔 2026-04-08 親口指示：**所有耗時 / 吃 token 的工作，一律 background sub-agent 處理**，主 session 保持空閒接老闆訊息。

## 適合丟 sub-agent
- 讀大檔（PDF / 整個資料夾 / 大量檔案）
- 跑 LLM judge / 評測 / 批次處理
- 跨檔案搜尋 / lint / 格式化
- 寫長報告 / 文件
- 任何「預期 > 30 秒的事」或「會吃很多 token 的事」

## 不適合丟
- 即時對話回應 / 簡單 react / quick edit / 已有 context 的延伸動作

## 操作模式
1. 跟發任務的特助/老闆說「我用 sub-agent 跑，X 分鐘後回」
2. 平行開多隻獨立任務，不 sequential
3. 主 session 保持空閒，sub-agent 跑時繼續接其他訊息
4. sub-agent 回來再整理摘要 + 檔案路徑回報

## 回傳瘦身（Return Slimming）

**派任 prompt 結尾必須加上以下指令：**

```
回傳規則：
- 回傳上限：Haiku ≤500 / Sonnet ≤1500 / Opus ≤3000 tokens
- 格式：JSON { status, summary(≤50字), details(≤5條), files_changed, next_action }
- 禁止回傳：完整原始碼、整份 build log、原始網頁內容
- 超出上限：自行摘要，完整報告寫入檔案，附 full_report_path
```

**按任務類型調整：**
- Code Review → diff summary + pass/fail + issues，不回整份 code
- Build/Dev → pass/fail + error + files_changed，不回 build log
- Research → ≤5 bullet points + 結論，不回原文
- Design Review → 通過/不通過 + ≤3 修改建議

## 派給誰（權威來源）

派活前查 `shared/config/bot-routing.yml`；Designer pod（星星人使用 Claude、Sara 使用 Codex）詳表與 Codex bot 的 `AGENTS.md` 警語見 `shared/blocks/block-agent-routing-shared.md`。本檔不重複維護 Builder／Reviewer／Designer 名單或強項，避免多真相源漂移。

## in_flight 面板（session.json）
```json
"in_flight": [
  {"task_id": "de10", "agent_id": "agt-xxx", "started": "12:18", "eta": "12:24"},
  {"task_id": "aa01", "agent_id": "agt-yyy", "started": "12:20", "eta": "12:30"}
]
```

> 例外：zhuchu 保留本地 `block-sub-agent-routing.md`，僅以 pointer 指向既有的 `block-agent-routing-shared.md` 模型／maxTurns 單一真相來源；其原有模型觸發字與細節不納入本共用 block，避免灌入其他 bot。
