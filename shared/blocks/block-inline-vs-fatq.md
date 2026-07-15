---
triggers: ["inline", "FATQ", "小任務", "不建單", "協調稅", "inline-work.jsonl", "切香腸", "降級", "block-inline-vs-fatq"]
description: "Load before deciding whether an assistant/orchestrator task can be completed inline instead of creating a FATQ task"
---

# Block: Inline vs FATQ 判準

> 目標：降低小型操作任務的固定協調成本，但不允許繞過 QA。這份判準只適用於特助/orchestrator 層的建單前決策；Builder 收到的工作仍來自 FATQ 單或主人直接指令。

## 白名單判準

以下 5 維度全部符合，才可 inline；任一不確定，建立 FATQ 單。

| # | 維度 | 門檻 |
|---|---|---|
| 1 | 預期 diff 規模 | 動手前估計 diff <= 30 行，且 <= 2 個檔案；實作中超過估計 2 倍即中止轉 FATQ。此為初值，2026-08 回顧。 |
| 2 | 風險類別 | 必須不符合 [block-task-queue.md「何時要 Worktree 隔離」](./block-task-queue.md#何時要-worktree-隔離2026-07-05loop-engineering-gap-2) 觸發條件任一項；以該節原文為準，本 block 不複寫清單。同時不得涉及資安、資金或用戶資料。 |
| 3 | 可自證 | 完工後有一條客觀驗證命令，例如測試、grep、curl、jq；或工作屬純文字/文檔改動。 |
| 4 | 非交付物 | 不是任何利害關係人驗收的成果本體，包括老兔、客戶端經 Nicky、菜姐 PMO 報告、其他特助委託；也不是已在跑的 FATQ 單或可辨識為同一較大 goal 的一部分。 |
| 5 | 可逆 | 可用 git revert 回復，或有一鍵回滾方式；刪檔、寫入 prod 資料等不可逆操作一律進 FATQ。 |

維度 4 是 Bella QA gate 的防線：任何要交給利害關係人驗收的交付物，不因規模小而 inline；至少一道 Bella QA gate不可省。

## 中止條款

inline 進行中發現下列任一情況，立即停手，將現狀寫入 FATQ 單 background，走正常流程：

- diff 超過事前估計 2 倍。
- 觸到風險類別或新增利害關係人驗收面。
- 同一問題第二次修不好。

禁止用「已經開始了」當作繼續 inline 的理由。

## 防切香腸 Guard

同一 bot 對同一 goal 於 7 天內累計 inline >= 2 次，或累計 diff 超過 30 行，視為同一大任務被拆分，必須補開一張 FATQ 單彙總留痕並走正常 QA。

Bella 抽查時用 `inline-work.jsonl` 的 `desc` 與 `files` 人工聚類判斷即可；v1 不建 daemon、不建 cron、不做自動化稽核。

## 留痕 Log

inline 完工後，執行者 append 一行 JSONL 到 `~/.claude-bots/logs/inline-work.jsonl`：

```json
{"ts":"ISO8601+08:00","bot":"anya","desc":"一句話","files":["絕對路徑"],"diff_lines":12,"risk_check":"pass","verify":"跑過的驗證命令或 n/a","result":"ok|reverted"}
```

欄位要求：

- `ts`: ISO8601，含時區。
- `bot`: 執行者 bot 目錄名。
- `desc`: 可聚類的一句話 goal。
- `files`: 受影響檔案的絕對路徑陣列。
- `diff_lines`: 數字，記錄實際 diff 行數。
- `risk_check`: 通常為 `pass`；若後續發現判斷錯誤，抽查者另記違規。
- `verify`: 實際跑過的命令，或 `n/a`。
- `result`: `ok` 或 `reverted`。

## 抽查 SOP

Bella 每週從 `~/.claude-bots/logs/inline-work.jsonl` 隨機抽 3 筆：

1. 驗 `risk_check` 是否符合本 block 的 5 維度。
2. 依 `desc` / `files` 聚類，檢查是否切香腸。
3. 發現本應進 FATQ 的工作被 inline，記 Mattermost `#agent-comms`，並將該 bot inline 權限降級為一律進 FATQ。
4. 同一 bot 連續兩週違規，升級老兔。

降級狀態記在 `~/.claude-bots/shared/state/inline-downgrade.json`：

```json
{"bot":"anya","reason":"inline risk misclassified","downgraded_at":"2026-07-15T00:00:00+08:00","expires_at":"2026-07-22T00:00:00+08:00"}
```

預設降級 7 天。Bella 每週抽查時順帶檢查到期項目：到期且該週無新違規，由 Bella 宣告解除，更新該 JSON 並在 Mattermost 記錄一行；未到期或再犯，續期並升級老兔。

## 決策流程

1. 這是 builder 層任務、主人直接交辦的交付物、或任何利害關係人要驗收的成果本體嗎？是 → 建 FATQ 或走指定 QA。
2. 5 維度是否全部明確通過？否 → 建 FATQ。
3. 是否疑似同 goal 7 天內重複 inline 或累計超規模？是 → 建 FATQ 彙總。
4. 可以 inline 時，完成後仍必須寫 `inline-work.jsonl`，並保留驗證命令或純文檔判斷依據。
