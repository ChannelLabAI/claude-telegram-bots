---
source: task-learnings-flow
task_id: "20260408-122518-aa3f-m0-task-learnings-hook"
task_title: "M0 — task → learnings 回流 hook (post-AOT-002)"
completed_at: "2026-04-11T02:57:00Z"
assigned_to: "sancai"
created_at: "2026-04-11T02:58:48Z"
---

# Learnings: M0 — task → learnings 回流 hook (post-AOT-002)

## 來源任務

- **Task ID**: `20260408-122518-aa3f-m0-task-learnings-hook`
- **完成時間**: 2026-04-11T02:57:00Z
- **執行者**: sancai
- **原始檔案**: `tasks/done/20260408-122518-aa3f-m0-task-learnings-hook.json`

## Learnings

- bash read 無法正確處理多行字串，跨行資料改用 Python 直接寫檔避免截斷
- backfill 逐檔呼叫 python3（72 個 fork）很慢，批次用單一 Python 進程掃 glob 秒完
- inotifywait -m 的 moved_to/create 事件只給檔名不給路徑，要自己拼 $DIR/$filename
