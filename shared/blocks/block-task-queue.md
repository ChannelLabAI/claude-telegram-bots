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
| graduated_invariant | ⚪ LOOP | 完成後仍需每日重驗的 invariant，格式同 `verify_commands`；Goal Graduation loop 只讀重跑，失敗只告警/開 regression 單，不自動修生產 |
| skills | ⚪ LOOP | 顯式技能標籤 string array，由 Anya/建單者標注；信任帳本只讀此欄位做 per-(bot×skill) 累積，禁止用文字子字串猜 skill |
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
- 完成後 invariant 可用同一 runner：`shared/bin/fatq-verify.sh --field graduated_invariant <task.json>`

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
0. **【強制】先查再做（in_progress 第一步，2026-07-05 老兔拍板）**：claim 任務、動手前，先用 task slug + 關鍵詞跑 `memocean_radar_search` 查有無相關 pearl/learnings。有命中 → 把重點寫進該任務的 `last_run_summary` 再開工；無命中 → 在 `last_run_summary` 標注「已查、無相關」。**跳過此步視同流程違規**，Bella QA 可據此 NB/REJECT。
   範例：`memocean_radar_search(query="loop-worktree-isolation git worktree fatq")` — query 用 slug 加 1-2 個關鍵詞即可，不用長句。
1. 接手/重啟長任務：先讀 `last_run_summary` + `lessons_learned` 再動手
2. mv 到其他狀態（如暫停、REJECT 修復前）先更新 `last_run_summary`
3. 遇到重要決策或踩坑時寫入 `lessons_learned`

## 審查流程：風險決定深度（2026-06-13 老兔拍板簡化，取代「8 步缺一不可」）

**靠判斷不靠分類表。一個輕量預設 + risky 才升級：**

- **預設＝1 道關**：Anya 建任務 → Builder 開發 → **Bella QA 一次** → done。多數任務（修 bug、infra、小工具、一般功能）都走這條。
- **只有「改了會大範圍出事」才多加一道 spec gate**（orchestrator 當下判斷，不查表）：架構決策 / 改 daemon / 改 schema / 涉資安·資金·用戶資料 / 跨 bot 影響。→ Anya 建 spec → **Bella 審規格** → 開發 → Bella QA → done。
- **完整 gstack**（plan-ceo / plan-design / 星星人設計 / plan-eng / ship / document-release 那一長串）**只留給真正對外的產品功能**，不套在內部修補上。
- **小問題用 NB（non-blocker）直接套用**，不走 REJECT→重審循環；只有真 blocker 才 REJECT。

### 信任帳本 advisory 軸（2026-07-09）

Trust Ledger 只從 FATQ verdict history 衍生 per-builder / builder×category / builder×skill 成功率，產出審查密度建議；它不代任何角色移動 task、不自動 approve/reject、不省 `review→done` 的 reviewer verdict。

| | L1 低信任 | L2 預設 | L3 高信任 |
|---|---|---|---|
| 普通任務 | 建議加 spec gate + QA | 一道 QA | 一道 QA |
| risky 任務 | spec gate + QA | spec gate + QA | 建議可免 spec gate，但仍需 QA |
| 對外產品功能 | 全 gstack | 全 gstack | 全 gstack |

紅線：
- 無 L4 auto-ship。
- QA gate 永不省。
- v1 全部 advisory-only，實際是否調整 gate 由 Anya/老兔/Bella 拍板。
- `verdict reject` 應帶 `--issue_type execution_error|spec_conflict|escalate_strategist|...`；信任帳本只把 `execution_error` 計為 builder fail，缺失則保守計 fail 並 audit warn。
- Reviewer verdict 禁止手寫 `jq`/`mv` 或手寫 `ts`。`review→done/rejected` 一律走 `shared/bin/fatq-cli.sh verdict approve|reject ... --as <reviewer>`；verdict 時戳只能由 CLI 取系統 `date` 生成。

### Goal Graduation

`graduated_invariant` 適合放「完成後仍應長期成立」的 verify 子集。Goal Graduation loop 每日重跑它；失敗時只 audit/告警，若 `GRAD_AUTO_OPEN=1` 才開一張新的 regression FATQ task，且 `verify_commands` 等於原 invariant。它永不修改已 done 任務，也永不自動改生產。

> `fast_track: true` ＝預設的 1 道關（純修/無架構決策）。`requires_designer` / 完整 gstack 只在產品功能才開。
> 原則：**預設一道關，risky 才加一道，產品功能才上全套。**

## 何時要 Worktree 隔離（2026-07-05，Loop Engineering gap #2）

多 Builder 並行時，改 shared 基建靠「列明路徑、禁 `git add -A`」人工規避，沒有系統保證。**高衝突風險**類任務改走 git worktree + feature branch 硬隔離；其餘任務維持現有路徑，**不強制、不一刀切**。

### 觸發條件（符合任一即算高衝突風險）

- 改 `shared/` 底下任何檔案（block、bin、scripts、lib 等）
- 改 daemon / 常駐 process 代碼（gateway.ts、inotify-watch.sh 等）
- 改 schema（task JSON 欄位定義、狀態機規則）
- 跨 bot 影響（多隻 bot 的 CLAUDE.md 或共用設定同批修改）

**不符合以上任一者維持現有路徑**（Builder 直接在主 checkout 改、列明路徑、禁 `git add -A`），不要為了小任務多開一層 worktree 增加開銷。

### 高衝突風險任務的流程

1. **開 worktree**：`shared/bin/fatq-worktree.sh create <task_id>`，印出 worktree 路徑，branch 自動命名 `fatq/<task_id>`
2. **在 worktree 裡開發**：`cd` 進印出的路徑改代碼、commit（該 worktree 是獨立 checkout，不影響主 checkout 或其他並行 Builder）
3. **review→Bella QA**：跟現有流程一樣，task JSON 狀態轉移不變，只是 Builder 的實體工作目錄在 worktree 裡
4. **merge**：QA 通過後，回到主 checkout `git merge fatq/<task_id>`（或依專案慣例走 PR）
5. **清理**：`shared/bin/fatq-worktree.sh cleanup <task_id>`，移除 worktree + 刪除 branch（冪等，重複呼叫不報錯）

### 部署疊序鐵律（2026-07-11，c3d4 stale-base REJECT 教訓）

- **同檔並行的多張單：先落地者定基底，後落地者部署前必 rebase 到當前 main 重驗**。worktree/patch 建在舊基底上直接硬 copy/apply 部署，會把中間落地的功能整層抹掉（c3d4 差點抹掉 b2c3 硬執法）。
- 交付 patch 的單，部署人（Anya）套用前必跑 `git apply --check`；不過就退回 builder rebase，不得手工揉合。
- 動 fatq-core（fatq-cli.sh / fatq-cli-test.sh / fatq-dispatch.sh）的單，完工測試數不得低於當前 main 的測試總數（防止 rebase 掉別人的 fixture）。

### 備註

- `fatq-worktree.sh` 用完整 task_id 消毒後當 worktree 目錄名/branch 名（`.worktrees/<task_id 消毒版>`、`fatq/<task_id 消毒版>`），不用內容抓字（同 `fatq-dispatch.sh` 的 `task_hex_id()` 慣例，避免撞名）。
- `.worktrees/` 已加進 `.gitignore`，不會被主 checkout 誤 commit。
- 本任務（loop-worktree-isolation）自己就是 shared/ 基建改動，是這條規則的首個 dogfood 案例。
