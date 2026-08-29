#!/usr/bin/env bash
# fatq-deploy-gate.sh — e4c8 builder_fix：唯一合法的「merge 進生產 main」入口
#
# 事故背景（2026-07-07 22:39）：Bella 22:35 REJECT c9d2（POST /api/chat/:t 越權
# BLOCKER）後，該分支仍被裸 `git merge` 進 mvp/ 的 production main（22:39:46），
# 幸運是 daemon 當時跑的是舊安全版沒中招，Anya git reset --hard 止血。根因：
# merge-to-prod-main 沒有任何機制檢查對應的 FATQ 審查任務是否真的過了審查——
# 裸 git merge 誰都能下，跟 FATQ 狀態機完全脫鉤。
#
# 本腳本 = 唯一合法入口：檢查 task_id 真的在 tasks/done/ 且有 verdict_approve
# 記錄，才放行 merge；REPO 端另裝 reference-transaction git hook（見
# install-deploy-hook.sh）在 ref 真正更新時再驗一次 token，讓裸 git merge
# 繞過本腳本時會被 hook 擋下——單靠「大家都用這支腳本」的君子協定不算數。
#
# Usage: fatq-deploy-gate.sh <task_id> <repo_dir> <branch>
# Exit:  0=merge 成功；1=usage 錯誤；2=gate 拒絕（task 未 done/未 approve）；
#        3=repo/branch 狀態錯誤（非 ff-able 等）；4=merge 本身失敗

set -uo pipefail

FATQ_ROOT="${FATQ_ROOT:-/home/oldrabbit/.claude-bots/tasks}"
LOG_FILE="${FATQ_DEPLOY_LOG:-/home/oldrabbit/.claude-bots/logs/fatq-deploy.log}"

log() { echo "[fatq-deploy-gate] $*" | tee -a "$LOG_FILE" >&2; }

TASK_ID="${1:-}"; REPO_DIR="${2:-}"; BRANCH="${3:-}"
if [[ -z "$TASK_ID" || -z "$REPO_DIR" || -z "$BRANCH" ]]; then
  echo "usage: fatq-deploy-gate.sh <task_id> <repo_dir> <branch>" >&2
  exit 1
fi
if [[ ! -d "$REPO_DIR/.git" ]] && ! git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  log "REFUSED task=$TASK_ID: $REPO_DIR 不是 git repo"
  exit 3
fi

# Production deployments are only valid against the five canonical repos. A
# fixture FATQ_ROOT remains unrestricted so isolated tests can use throwaway
# repositories without weakening the production boundary.
if [[ "$(readlink -f -- "$FATQ_ROOT")" == "/home/oldrabbit/.claude-bots/tasks" ]]; then
  REPO_REAL=$(readlink -f -- "$REPO_DIR")
  case "$REPO_REAL" in
    /home/oldrabbit/.claude-bots|\
    /home/oldrabbit/.claude-bots/infra|\
    /home/oldrabbit/.claude-bots/pod-system|\
    /home/oldrabbit/.claude-bots/shared/memocean-mcp|\
    /home/oldrabbit/.claude-bots/mvp) ;;
    *)
      log "REFUSED task=$TASK_ID: repo=$REPO_REAL 不在 production canonical repo allowlist（尚未寫 deploy token）"
      exit 3
      ;;
  esac
fi

# ── ①task 必須真的躺在 tasks/done/，且有 verdict_approve 記錄 ──────────────
TASK_FILE="$FATQ_ROOT/done/${TASK_ID}.json"
if [[ ! -f "$TASK_FILE" ]]; then
  log "REFUSED task=$TASK_ID: 不在 tasks/done/（找不到 $TASK_FILE）——部署只放行已審核通過的任務，禁裸 merge 繞過審查"
  exit 2
fi
if ! jq -e '[.history // [] | .[] | select(.action=="verdict_approve")] | length > 0' "$TASK_FILE" >/dev/null 2>&1; then
  log "REFUSED task=$TASK_ID: tasks/done/ 有檔但 history 內找不到 verdict_approve 記錄（檔案可能被異常搬動，非正常審查路徑產生）"
  exit 2
fi
APPROVED_BY=$(jq -r '[.history // [] | .[] | select(.action=="verdict_approve")] | last | .by // "?"' "$TASK_FILE")

# ── ②branch 必須能 fast-forward 到 repo 現在的 HEAD，不接受非線性歷史 ──────
if ! git -C "$REPO_DIR" rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  log "REFUSED task=$TASK_ID: branch $BRANCH 在 $REPO_DIR 不存在"
  exit 3
fi
TARGET_COMMIT=$(git -C "$REPO_DIR" rev-parse "$BRANCH")
CURRENT_HEAD=$(git -C "$REPO_DIR" rev-parse HEAD)
if ! git -C "$REPO_DIR" merge-base --is-ancestor "$CURRENT_HEAD" "$TARGET_COMMIT" 2>/dev/null; then
  log "REFUSED task=$TASK_ID: $BRANCH($TARGET_COMMIT) 不是目前 HEAD($CURRENT_HEAD) 的 fast-forward 後裔，先 rebase"
  exit 3
fi

# ── ③寫一次性 deploy token，repo 端的 reference-transaction hook 會核對 ────
GIT_COMMON_DIR=$(git -C "$REPO_DIR" rev-parse --git-common-dir)
[[ "$GIT_COMMON_DIR" != /* ]] && GIT_COMMON_DIR="$REPO_DIR/$GIT_COMMON_DIR"
TOKEN_FILE="$GIT_COMMON_DIR/DEPLOY_APPROVED"
jq -n --arg task_id "$TASK_ID" --arg commit "$TARGET_COMMIT" --arg approved_by "$APPROVED_BY" \
      --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  '{task_id: $task_id, commit: $commit, approved_by: $approved_by, ts: $ts}' > "$TOKEN_FILE"

log "GATE PASS task=$TASK_ID approved_by=$APPROVED_BY target=$TARGET_COMMIT — merging into $REPO_DIR"

# ── ④真的 merge（--ff-only：本團隊 mvp/ 的既定合併風格，不接受合併提交）────
# 用 PIPESTATUS 抓 git 自己的 exit code，不要用 `set -o pipefail` 下整條管線的
# 聚合狀態——tee 本身若失敗（磁碟滿/權限問題），pipefail 會誤報 merge 失敗，
# 但實際上 merge 早就成功了，讓呼叫端誤以為沒部署、重跑反而危險（Bella Pass A note）。
git -C "$REPO_DIR" merge --ff-only "$BRANCH" 2>&1 | tee -a "$LOG_FILE"
merge_rc="${PIPESTATUS[0]}"
if [[ "$merge_rc" -ne 0 ]]; then
  rm -f "$TOKEN_FILE"
  log "MERGE FAILED task=$TASK_ID — token 已清除，未部署"
  exit 4
fi

ACTUAL_HEAD=$(git -C "$REPO_DIR" rev-parse HEAD)
if [[ "$ACTUAL_HEAD" == "$CURRENT_HEAD" ]]; then
  # No ref transaction occurred, so the hook had no opportunity to consume
  # this invocation's token. Remove it explicitly to prevent replay residue.
  rm -f "$TOKEN_FILE"
  log "NO-OP task=$TASK_ID target=$TARGET_COMMIT reason=already-up-to-date repo=$REPO_DIR"
  exit 0
fi

log "DEPLOYED task=$TASK_ID commit=$ACTUAL_HEAD approved_by=$APPROVED_BY repo=$REPO_DIR"
exit 0
