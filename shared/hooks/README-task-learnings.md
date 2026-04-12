# Task Learnings Hook — `task-learnings-flow.sh`

## 什麼是 `learnings` field？

在 task JSON 裡加一個 `learnings` 欄位，記錄這次任務學到的可重複使用知識。

task done 時，hook 會自動把 learnings 寫成草稿，進入 learned-skills 審核流程。

## 格式

```json
{
  "title": "...",
  "status": "done",
  "learnings": [
    "inotifywait -m 模式下 moved_to 事件不帶完整路徑，要自己拼",
    "Python subprocess.run 的 timeout 參數在 zombie process 時不生效，要 killpg"
  ]
}
```

### 支援的型態

| 型態 | 範例 |
|------|------|
| `list of strings`（推薦） | `["學到 A", "學到 B"]` |
| `string`（markdown） | `"## 關鍵發現\n- 發現 A\n- 發現 B"` |
| `null` 或不填 | hook 會 log warning，不阻擋 done flow |

### 什麼該寫進 learnings？

- 未來會再遇到的坑（不是 one-off typo）
- 工具或 API 的非顯而易見行為
- 效能優化的具體數字（「batch size 從 10 改 50，速度 3x」）
- debug 時發現的根因（不是症狀）

### 什麼不該寫？

- 「我修了一個 bug」（太模糊）
- 已經在 CLAUDE.md 或 mistakes.md 寫過的
- 只適用於這次、不會重現的情境

## Hook 行為

| 模式 | 指令 | 說明 |
|------|------|------|
| daemon | `task-learnings-flow.sh` | backfill + inotifywait 持續監聽 |
| backfill only | `task-learnings-flow.sh --backfill` | 掃一次歷史 done tasks 就結束 |
| 單檔 | `task-learnings-flow.sh path/to/task.json` | 處理指定檔案 |

## 輸出

- 有 learnings → `~/.claude-bots/shared/learned-skills/_drafts/from-task-{task_id}.md`
- 無 learnings → `~/.claude-bots/logs/missing-learnings.log`（soft warn）
- 執行日誌 → `~/.claude-bots/logs/task-learnings-flow.log`

## 冪等

同一個 task_id 的 draft 只會建立一次。重複跑 backfill 安全。
