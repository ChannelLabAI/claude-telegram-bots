#!/usr/bin/env bash
# task-learnings-flow.sh — ADR v0.4 Fill 段：task done 時把 learnings 寫回知識庫
#
# 行為：
#   1. 啟動時 backfill：掃所有 tasks/done/*.json，逐一處理
#   2. 之後 inotifywait 監聽 tasks/done/ 的新檔案（moved_to / create）
#   3. 有 learnings field → 寫 _drafts/from-task-{task_id}.md
#   4. 沒有 learnings field → soft warn 到 missing-learnings.log
#
# Usage:
#   task-learnings-flow.sh              # backfill + watch（daemon 模式）
#   task-learnings-flow.sh --backfill   # 只跑 backfill，不 watch
#   task-learnings-flow.sh <file.json>  # 處理單一檔案

set -euo pipefail

DONE_DIR="$HOME/.claude-bots/tasks/done"
DRAFTS_DIR="$HOME/.claude-bots/shared/learned-skills/_drafts"
LOG_DIR="$HOME/.claude-bots/logs"
MISSING_LOG="$LOG_DIR/missing-learnings.log"
FLOW_LOG="$LOG_DIR/task-learnings-flow.log"

mkdir -p "$DRAFTS_DIR" "$LOG_DIR"

stamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log() { echo "[$(stamp)] $*" >> "$FLOW_LOG"; }
log_missing() { echo "[$(stamp)] $*" >> "$MISSING_LOG"; }

# ── 處理單一 task JSON ──────────────────────────────────────────
process_task() {
    local file="$1"
    local basename
    basename="$(basename "$file")"

    # 只處理 .json
    [[ "$basename" == *.json ]] || return 0

    # Python 直接寫 draft 或 log，避免多行 body 經 bash 截斷
    python3 - "$file" "$DRAFTS_DIR" "$MISSING_LOG" "$FLOW_LOG" "$basename" <<'PYEOF'
import json, sys, os
from datetime import datetime, timezone

task_path = sys.argv[1]
drafts_dir = sys.argv[2]
missing_log = sys.argv[3]
flow_log = sys.argv[4]
basename = sys.argv[5]

stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def flog(path, msg):
    with open(path, "a", encoding="utf-8") as f:
        f.write(f"[{stamp}] {msg}\n")

try:
    with open(task_path, encoding="utf-8") as f:
        d = json.load(f)
except Exception as e:
    flog(flow_log, f"PARSE_ERROR {basename}: {e}")
    sys.exit(0)

task_id = d.get("id", os.path.splitext(basename)[0])
title = d.get("title", "(untitled)")
completed_at = d.get("completed_at", "")
assigned_to = d.get("assigned_to", "")
learnings = d.get("learnings")

if learnings is None or (isinstance(learnings, (str, list)) and not learnings):
    flog(missing_log, f'WARN no-learnings task={task_id} title="{title}" file={basename}')
    flog(flow_log, f"SKIP no-learnings {basename}")
    sys.exit(0)

# learnings 可以是 string 或 list
if isinstance(learnings, list):
    body = "\n".join(f"- {item}" for item in learnings)
elif isinstance(learnings, str):
    body = learnings
else:
    body = str(learnings)

if not body.strip():
    flog(missing_log, f'WARN empty-learnings task={task_id} title="{title}" file={basename}')
    flog(flow_log, f"SKIP empty-learnings {basename}")
    sys.exit(0)

draft_file = os.path.join(drafts_dir, f"from-task-{task_id}.md")

# 冪等：已存在就跳過
if os.path.exists(draft_file):
    flog(flow_log, f"SKIP exists {draft_file}")
    sys.exit(0)

content = f"""---
source: task-learnings-flow
task_id: "{task_id}"
task_title: "{title}"
completed_at: "{completed_at}"
assigned_to: "{assigned_to}"
created_at: "{stamp}"
---

# Learnings: {title}

## 來源任務

- **Task ID**: `{task_id}`
- **完成時間**: {completed_at or 'unknown'}
- **執行者**: {assigned_to or 'unknown'}
- **原始檔案**: `tasks/done/{basename}`

## Learnings

{body}
"""

with open(draft_file, "w", encoding="utf-8") as f:
    f.write(content)

flog(flow_log, f"CREATED {draft_file} from {basename}")
print(f"[task-learnings-flow] Created draft: from-task-{task_id}.md")
PYEOF
}

# ── Backfill：單一 Python 進程批次掃所有歷史 done task ────────────
backfill() {
    log "BACKFILL start — scanning $DONE_DIR"
    python3 - "$DONE_DIR" "$DRAFTS_DIR" "$MISSING_LOG" "$FLOW_LOG" <<'BFEOF'
import json, os, sys, glob
from datetime import datetime, timezone

done_dir = sys.argv[1]
drafts_dir = sys.argv[2]
missing_log = sys.argv[3]
flow_log = sys.argv[4]

stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
total = created = skipped = 0

def flog(path, msg):
    with open(path, "a", encoding="utf-8") as f:
        f.write(f"[{stamp}] {msg}\n")

for fpath in sorted(glob.glob(os.path.join(done_dir, "*.json"))):
    total += 1
    basename = os.path.basename(fpath)
    try:
        with open(fpath, encoding="utf-8") as f:
            d = json.load(f)
    except Exception as e:
        flog(flow_log, f"PARSE_ERROR {basename}: {e}")
        continue

    task_id = d.get("id", os.path.splitext(basename)[0])
    title = d.get("title", "(untitled)")
    completed_at = d.get("completed_at", "")
    assigned_to = d.get("assigned_to", "")
    learnings = d.get("learnings")

    if learnings is None or (isinstance(learnings, (str, list)) and not learnings):
        flog(missing_log, f'WARN no-learnings task={task_id} title="{title}" file={basename}')
        flog(flow_log, f"SKIP no-learnings {basename}")
        skipped += 1
        continue

    if isinstance(learnings, list):
        body = "\n".join(f"- {item}" for item in learnings)
    elif isinstance(learnings, str):
        body = learnings
    else:
        body = str(learnings)

    if not body.strip():
        flog(missing_log, f'WARN empty-learnings task={task_id} title="{title}" file={basename}')
        flog(flow_log, f"SKIP empty-learnings {basename}")
        skipped += 1
        continue

    draft_file = os.path.join(drafts_dir, f"from-task-{task_id}.md")
    if os.path.exists(draft_file):
        flog(flow_log, f"SKIP exists {draft_file}")
        continue

    content = f"""---
source: task-learnings-flow
task_id: "{task_id}"
task_title: "{title}"
completed_at: "{completed_at}"
assigned_to: "{assigned_to}"
created_at: "{stamp}"
---

# Learnings: {title}

## 來源任務

- **Task ID**: `{task_id}`
- **完成時間**: {completed_at or 'unknown'}
- **執行者**: {assigned_to or 'unknown'}
- **原始檔案**: `tasks/done/{basename}`

## Learnings

{body}
"""
    with open(draft_file, "w", encoding="utf-8") as f:
        f.write(content)
    flog(flow_log, f"CREATED {draft_file} from {basename}")
    created += 1
    print(f"[task-learnings-flow] Created draft: from-task-{task_id}.md")

flog(flow_log, f"BACKFILL done — total={total} created={created} skipped={skipped}")
BFEOF
    log "BACKFILL complete"
}

# ── Watch：inotifywait 監聽新檔案 ──────────────────────────────
watch_done() {
    log "WATCH start — monitoring $DONE_DIR"
    inotifywait -m -e moved_to -e create --format '%f' "$DONE_DIR" | while read -r filename; do
        local filepath="$DONE_DIR/$filename"
        [[ -f "$filepath" ]] || continue
        # 等一下讓檔案寫完
        sleep 0.5
        log "WATCH event: $filename"
        process_task "$filepath"
    done
}

# ── Main ────────────────────────────────────────────────────────
main() {
    log "=== task-learnings-flow.sh started ==="

    case "${1:-}" in
        --backfill)
            backfill
            ;;
        *.json)
            # 單一檔案模式
            if [[ -f "$1" ]]; then
                process_task "$1"
            else
                echo "File not found: $1" >&2
                exit 1
            fi
            ;;
        *)
            # 預設：backfill + watch
            backfill
            watch_done
            ;;
    esac
}

main "$@"
