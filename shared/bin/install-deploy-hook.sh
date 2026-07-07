#!/usr/bin/env bash
# install-deploy-hook.sh — e4c8 builder_fix：在目標 repo 裝 reference-transaction
# git hook，讓「裸 git merge 繞過 fatq-deploy-gate.sh」這件事在 git 層面就做不到
# ——不只是「大家都用那支腳本」的君子協定。
#
# 為什麼是 reference-transaction 而不是 pre-merge-commit：本團隊的合併風格全
# 部是 --ff-only（見 mvp/ 既有慣例），fast-forward 不會產生合併提交，
# pre-merge-commit 這類 hook 對 ff merge 根本不會觸發。reference-transaction
# （git 2.28+）在任何 ref 真的被改寫時都會觸發，包含 ff merge、reset、甚至
# 直接改 packed-refs，覆蓋面才夠。
#
# Usage: install-deploy-hook.sh <repo_dir> [guarded_branch=master]
set -uo pipefail

REPO_DIR="${1:-}"
GUARDED_BRANCH="${2:-master}"
if [[ -z "$REPO_DIR" ]]; then
  echo "usage: install-deploy-hook.sh <repo_dir> [guarded_branch=master]" >&2
  exit 1
fi

GIT_COMMON_DIR=$(git -C "$REPO_DIR" rev-parse --git-common-dir 2>/dev/null) || {
  echo "FATAL: $REPO_DIR 不是 git repo" >&2; exit 1; }
[[ "$GIT_COMMON_DIR" != /* ]] && GIT_COMMON_DIR="$REPO_DIR/$GIT_COMMON_DIR"

HOOK_FILE="$GIT_COMMON_DIR/hooks/reference-transaction"
mkdir -p "$GIT_COMMON_DIR/hooks"

cat > "$HOOK_FILE" <<HOOKEOF
#!/usr/bin/env bash
# reference-transaction hook（由 install-deploy-hook.sh 生成，e4c8 builder_fix）
# guarded_branch=$GUARDED_BRANCH — 對這條 ref 的任何更新都要求先有
# fatq-deploy-gate.sh 留下的一次性 token（DEPLOY_APPROVED），且 token 內記錄
# 的 commit 必須恰好等於本次更新的 new-value；否則 prepared 階段回非 0 讓
# git 直接中止這次 ref 更新（merge/reset/whatever 全部擋，不只擋 merge）。
set -uo pipefail
PHASE="\${1:-}"
# 裝在 install 當下就固定死這個絕對路徑，不靠執行期 git rev-parse/pwd 猜——
# hook 執行時的 cwd 依 git 版本/worktree 情境不保證等於 repo 根目錄，猜錯會
# 讓 token 永遠對不上、把每一次合法部署都誤擋（比擋不住裸 merge 更糟）。
GIT_COMMON_DIR="$GIT_COMMON_DIR"
TOKEN_FILE="\$GIT_COMMON_DIR/DEPLOY_APPROVED"

VIOLATION=0
SAW_GUARDED_REF=0
while read -r old_oid new_oid refname; do
  [[ "\$refname" == "refs/heads/$GUARDED_BRANCH" ]] || continue
  [[ "\$old_oid" == "\$new_oid" ]] && continue   # 無實際變更（例如唯讀查詢觸發）
  SAW_GUARDED_REF=1

  if [[ "\$PHASE" == "prepared" ]]; then
    if [[ ! -f "\$TOKEN_FILE" ]]; then
      echo "[deploy-gate hook] 拒絕：refs/heads/$GUARDED_BRANCH 更新沒有 deploy token，必須經 fatq-deploy-gate.sh 走 FATQ 審查放行（禁裸 git merge/reset 直接改 $GUARDED_BRANCH）。" >&2
      VIOLATION=1
      continue
    fi
    token_commit=\$(jq -r '.commit // empty' "\$TOKEN_FILE" 2>/dev/null)
    if [[ "\$token_commit" != "\$new_oid" ]]; then
      echo "[deploy-gate hook] 拒絕：deploy token 記錄的 commit(\$token_commit) 與本次更新目標(\$new_oid) 不符——token 是給別的部署用的，不能借用。" >&2
      VIOLATION=1
      continue
    fi
    task_id=\$(jq -r '.task_id // empty' "\$TOKEN_FILE" 2>/dev/null)
    echo "[deploy-gate hook] OK：refs/heads/$GUARDED_BRANCH -> \$new_oid 已由 task=\$task_id 的 deploy token 核准。" >&2
  fi
done

# 單一 git 操作常觸發不只一次 reference-transaction（例如 ORIG_HEAD 之類的內部
# ref 各自一次交易），只在「這次交易真的動到被保護的 ref」時才消耗 token——
# 否則不相干的交易先跑完 committed，會在真正的 ref 更新輪到之前就把 token
# 清掉，讓合法部署也被誤擋（本 hook 開發時 fixture 實測踩到這個坑）。
if [[ "\$SAW_GUARDED_REF" == "1" ]] && [[ "\$PHASE" == "committed" || "\$PHASE" == "aborted" ]]; then
  rm -f "\$TOKEN_FILE"   # 單次使用
fi

[[ "\$VIOLATION" == "1" ]] && exit 1
exit 0
HOOKEOF
chmod +x "$HOOK_FILE"
echo "已安裝 reference-transaction hook：$HOOK_FILE（guarded_branch=$GUARDED_BRANCH）"
