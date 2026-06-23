---
triggers: ["FATQ", "task queue", "任務建立", "pending", "in_progress", "review", "rejected", "done", "建立任務", "create task", "claim task", "task file", "tasks/", "4hex", "slug", "ESCALATION", "REJECT 超過", "inotify"]
description: "Load when creating, monitoring, or managing FATQ (File-Atomic Task Queue) files and state transitions"
---

# Block: FATQ（File-Atomic Task Queue）

> 全隊單一共用源（`shared/blocks/`），各 bot blocks/ 內為 symlink。改規則只改這裡，16 bot 同步生效、不再漂移。

## 任務建立
1. 建立 JSON 檔（格式：`{YYYYMMDD-HHmmss}-{4hex}-{slug}.json`）
2. 放入 `~/.claude-bots/tasks/pending/`
3. TG 群組通知 assigned bot：任務檔路徑

## Spec 格式（完整欄位）

| 欄位 | 必填 | 說明 |
|---|---|---|
| goal | ✅ | 一句話描述任務目標 |
| background | ✅ | 背景與前置條件 |
| context | ✅ NEW | **決策脈絡**：老兔/Anya 的對話背景、為什麼現在做、隱性期望、關鍵決策 |
| deliverables | ✅ | 具體交付物清單 |
| acceptance_criteria | ✅ | 可量化的完成條件 |
| out_of_scope | ✅ | 明確排除的範圍 |
| review_focus | ✅ NEW | **審核焦點**：告訴 Bella 最容易出問題的地方、哪些 AC 最重要、關注點 |
| tech_notes | ⚪ | 技術備注（選填） |
| fast_track | ⚪ NEW | boolean，true = 跳過 spec_review/design_review，Bella 只做最終 review |
| verify_commands | ⚪ LOOP | 機器可判斷的 AC gate（array of `{cmd, expect_exit, desc?}`），供 `fatq-verify.sh` 執行 |
| last_run_summary | ⚪ LOOP | Builder 暫停或 mv 前寫入的當前進度，供下次 resume 快速定位 |
| lessons_learned | ⚪ LOOP | 進行中遇到的坑/決策記錄，供 resume 時讀取。**≠ learnings**：`learnings` 是 done 後寫給 Ocean 知識萃取（由 task-learnings-flow.sh 讀），`lessons_learned` 是 in-progress builder 自己的 resume 提示，兩者不同時機、不同用途 |

## 狀態轉換（原子操作）
改 JSON → 寫 .tmp → mv .tmp 覆蓋 → mv 到目標目錄

- pending → in_progress：只有 assigned bot
- in_progress → review：只有 assigned bot
- review → done：只有 Bella
- review → rejected：只有 Bella
- rejected → in_progress：只有 assigned bot
- 任何 → pending：只有 Anya

## 監控
- 啟動時掃全部 tasks/ 目錄，確認各任務狀態正常
- REJECT 超過 3 次 → [ESCALATION] 給老兔
- inotify daemon (`channellab-inotify-watch.service`) 自動推通知，不需建立輪詢 cron

## Anya 派活流程
1. 讀 pool 中各 bot 的 session.json `in_flight`，選最閒的
2. 建任務 JSON → 放 pending/
3. TG @-mention assigned bot 通知

## Loop-Native 欄位 SOP（2026-06-24）

### verify_commands — 機器可判斷的 AC gate

`cmd` 必須是 **string array**（等同 subprocess `shell=False`），每個元素是獨立 token，不可用帶 shell 語法的字串：
```json
"verify_commands": [
  {"cmd": ["python3", "script.py", "--stats"], "expect_exit": 0, "desc": "stats 可正常跑"},
  {"cmd": ["/usr/bin/time", "-v", "python3", "script.py"], "expect_exit": 0}
]
```

執行方式：`shared/bin/fatq-verify.sh <task.json>`
- 全 pass → exit 0 + 摘要
- 任一 fail → exit 1 + 明確指出哪條失敗
- 無 verify_commands → exit 0（N/A，跳過）

**Reviewer SOP**（強制，2026-06-24 老兔拍板）：task 若有 verify_commands，QA **第一步必須**先跑 `fatq-verify.sh`，全 pass 才進人工審；任一 fail 直接 REJECT，不進人工審。

**Builder/Anya SOP**（強制，2026-06-24 老兔拍板）：建 spec 時，凡**可機器判斷**的 AC **必須**寫成 verify_commands；確實無法機器判斷者可不寫，但需在 tech_notes 或 review_focus 中說明原因。

### last_run_summary + lessons_learned — Resume 欄位

**欄位區分（重要）：**
| 欄位 | 時機 | 讀取者 | 用途 |
|---|---|---|---|
| `learnings` | done 後寫 | task-learnings-flow.sh / fts5-ingest | Ocean 知識萃取，進知識圖譜 |
| `lessons_learned` | in-progress 中寫 | Builder 自己 resume 時讀 | 進行中的坑/決策，不進 Ocean |
| `last_run_summary` | 暫停/mv 前寫 | Builder 接手時讀 | 當前進度快照 |

**Builder SOP**：
1. 接手/重啟長任務：先讀 `last_run_summary` + `lessons_learned` 再動手
2. mv 到其他狀態（如暫停、REJECT 修復前）先更新 `last_run_summary`
3. 遇到重要決策或踩坑時寫入 `lessons_learned`

## 審查流程：風險決定深度（2026-06-13 老兔拍板簡化，取代「8 步缺一不可」）

**靠判斷不靠分類表。一個輕量預設 + risky 才升級：**

- **預設＝1 道關**：Anya 建任務 → Builder 開發 → **Bella QA 一次** → done。多數任務（修 bug、infra、小工具、一般功能）都走這條。
- **只有「改了會大範圍出事」才多加一道 spec gate**（orchestrator 當下判斷，不查表）：架構決策 / 改 daemon / 改 schema / 涉資安·資金·用戶資料 / 跨 bot 影響。→ Anya 建 spec → **Bella 審規格** → 開發 → Bella QA → done。
- **完整 gstack**（plan-ceo / plan-design / 星星人設計 / plan-eng / ship / document-release 那一長串）**只留給真正對外的產品功能**，不套在內部修補上。
- **小問題用 NB（non-blocker）直接套用**，不走 REJECT→重審循環；只有真 blocker 才 REJECT。

> `fast_track: true` ＝預設的 1 道關（純修/無架構決策）。`requires_designer` / 完整 gstack 只在產品功能才開。
> 原則：**預設一道關，risky 才加一道，產品功能才上全套。**
