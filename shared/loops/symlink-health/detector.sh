#!/usr/bin/env bash
# shared/loops/symlink-health/detector.sh
# Symlink Health Closed-Loop MVP — SENSE → DECIDE → [ACT] → VERIFY → [ROLLBACK] → LEARN
# Zero-LLM: test / md5sum / realpath / generate-manifest.py only
# auto_fix_enabled=0 by default (HARDLINE: dry-run only)

set -uo pipefail

LOOP_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$LOOP_DIR/config"
AUDIT_LOG="${SYMLINK_HEALTH_AUDIT_LOG:-$LOOP_DIR/symlink-health.audit.jsonl}"
STATE_DIR="${SYMLINK_HEALTH_STATE_DIR:-$LOOP_DIR/state}"
CIRCUIT_STATE="${SYMLINK_HEALTH_CIRCUIT_STATE:-$LOOP_DIR/.circuit-breaker-count}"
ESCALATION_DEDUPE_DIR="$STATE_DIR/escalation-dedupe"
ESCALATION_DEDUPE_WINDOW_SECONDS="${SYMLINK_HEALTH_DEDUPE_WINDOW_SECONDS:-86400}"
FINDINGS_TMP="$(mktemp /tmp/symlink-findings-XXXXXX.json)"
trap 'rm -f "$FINDINGS_TMP"' EXIT

BASE_DIR="${SYMLINK_HEALTH_BASE_DIR:-$(cd "$LOOP_DIR/../../.." && pwd)}"
BOTS_DIR="${SYMLINK_HEALTH_BOTS_DIR:-$BASE_DIR/bots}"
SHARED_BLOCKS="${SYMLINK_HEALTH_SHARED_BLOCKS:-$BASE_DIR/shared/blocks}"
GENERATE_MANIFEST="${SYMLINK_HEALTH_GENERATE_MANIFEST:-$BASE_DIR/shared/lib/generate-manifest.py}"
RELAY_DIR="${SYMLINK_HEALTH_RELAY_DIR:-$BASE_DIR/relay}"

# ── Config ────────────────────────────────────────────────────────────────────

load_config() {
    loop_enabled=1
    auto_fix_enabled=0
    circuit_breaker_limit=3
    topology_threshold_pct=25
    chronic_fix_threshold=3
    chronic_window_days=7
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
}

# ── Canonical allowlist (6 registered names) ──────────────────────────────────

is_canonical_name() {
    case "$1" in
        block-agent-routing-shared.md|block-comms-architecture.md|\
        block-diana-query.md|block-section11.md|\
        block-section12.md|block-task-queue.md) return 0 ;;
        *) return 1 ;;
    esac
}

# Deny-list: never touch, even if somehow matched
is_denied() {
    case "$1" in
        *.mcp.json|*start.sh|*.env*|*session.json|*.pre-symlink*) return 0 ;;
        *) return 1 ;;
    esac
}

# ── Helpers ───────────────────────────────────────────────────────────────────

ts_now() { TZ=Asia/Taipei date '+%Y-%m-%dT%H:%M:%S+08:00'; }
run_id() { date '+%Y%m%d%H%M%S%3N'; }

md5_of() {
    command -v md5sum &>/dev/null && md5sum "$1" | awk '{print $1}' || md5 -q "$1"
}

ensure_state_dir() { mkdir -p "$STATE_DIR"; }

circuit_count() { [ -f "$CIRCUIT_STATE" ] && cat "$CIRCUIT_STATE" || echo 0; }
circuit_reset()  { ensure_state_dir; echo 0 > "$CIRCUIT_STATE"; }
circuit_bump()   { ensure_state_dir; echo $(( $(circuit_count) + 1 )) > "$CIRCUIT_STATE"; }

add_finding() {
    # Append one JSON object to FINDINGS_TMP as a JSON array element
    python3 -c "
import json, sys
f = open('$FINDINGS_TMP', 'a')
args = sys.argv[1:]
obj = {}
for a in args:
    k, _, v = a.partition('=')
    obj[k] = v
f.write(json.dumps(obj, ensure_ascii=False) + '\n')
" "$@"
}

escalate_to_anya() {
    local subject="$1" body="$2"
    mkdir -p "$RELAY_DIR"
    local payload
    payload=$(python3 -c "
import json, sys
subject, body, ts = sys.argv[1:]
text = '@Anyachl_bot [symlink-health] ' + subject + '\n\n' + body
print(json.dumps({'from_bot':'symlink-health-loop','recipient':'anya',
  'text':text,'subject':subject,'body':body,'ts':ts},ensure_ascii=False))
" "$subject" "$body" "$(ts_now)")
    echo "$payload" > "$RELAY_DIR/escalate-symlink-$(run_id).json"
    echo "[escalate] $subject" >&2
}

dedupe_key_for() {
    local target="$1" file_md5="$2"
    printf '%s|%s' "$target" "$file_md5" | md5sum | awk '{print $1}'
}

should_escalate_drift() {
    local target="$1" file_md5="$2"
    mkdir -p "$ESCALATION_DEDUPE_DIR"
    local key state_file now last
    key=$(dedupe_key_for "$target" "$file_md5")
    state_file="$ESCALATION_DEDUPE_DIR/$key"
    now=$(date +%s)
    last=$(cat "$state_file" 2>/dev/null || echo 0)
    if [ $((now - last)) -lt "$ESCALATION_DEDUPE_WINDOW_SECONDS" ]; then
        return 1
    fi
    echo "$now" > "$state_file"
    return 0
}

# ── F2: Chronic drift detection ───────────────────────────────────────────────

check_chronic_drift() {
    local target="$1"
    [ ! -f "$AUDIT_LOG" ] && return
    local count
    count=$(python3 - "$AUDIT_LOG" "$target" "$chronic_fix_threshold" "$chronic_window_days" << 'PYEOF'
import json, sys
from datetime import datetime, timedelta, timezone
log_p, target, thr, days = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).strftime('%Y-%m-%dT')
n = 0
for line in open(log_p):
    try:
        e = json.loads(line)
        if e.get('ts', '') < cutoff: continue
        for f in e.get('findings', []):
            if f.get('target') == target and f.get('action') in ('fixed','dry_run_proposed','converted_to_symlink'):
                n += 1
    except: pass
print(n)
PYEOF
)
    if [ "${count:-0}" -gt "$chronic_fix_threshold" ]; then
        escalate_to_anya \
            "[chronic-drift] $target: ${count} fixes in ${chronic_window_days}d — investigate root cause" \
            "Target $(basename "$target") in $(basename "$(dirname "$(dirname "$target")")")/blocks/ has been auto-proposed/fixed ${count} times in ${chronic_window_days} days. This suggests a recurring source writing broken symlinks. Please fix the root cause (e.g. a start.sh or setup script that overwrites the symlink)."
    fi
}

# ── VERIFY (3 checks) ─────────────────────────────────────────────────────────

verify_symlink() {
    local target="$1"
    local fname; fname=$(basename "$target")
    local canonical="$SHARED_BLOCKS/$fname"

    # V1: symlink resolves and realpath == canonical realpath
    local resolved; resolved=$(realpath "$target" 2>/dev/null) || { echo "V1_RESOLVE_FAIL"; return 1; }
    local canon_real; canon_real=$(realpath "$canonical" 2>/dev/null) || { echo "V1_CANON_MISSING"; return 1; }
    [ "$resolved" = "$canon_real" ] || { echo "V1_MISMATCH"; return 1; }

    # V2: md5 matches
    local m1; m1=$(md5_of "$target")
    local m2; m2=$(md5_of "$canonical")
    [ "$m1" = "$m2" ] || { echo "V2_MD5_MISMATCH"; return 1; }

    # V3: block appears in manifest (via generate-manifest.py --stdout)
    local bot_blocks; bot_blocks=$(dirname "$target")
    local priority
    priority=$(python3 "$GENERATE_MANIFEST" "$bot_blocks" --stdout 2>/dev/null | python3 -c "
import json, sys
m = json.load(sys.stdin)
for b in m:
    if b['name'] == '$fname':
        print(b.get('priority','?'))
        exit(0)
print('NOT_FOUND')
exit(1)
" 2>/dev/null) || { echo "V3_MANIFEST_FAIL"; return 1; }
    [ "$priority" = "NOT_FOUND" ] && { echo "V3_NOT_IN_MANIFEST"; return 1; }

    echo "PASS(priority=$priority)"
    return 0
}

# ── ACT (only when auto_fix_enabled=1) ───────────────────────────────────────

do_fix_symlink() {
    local target="$1"
    local fname; fname=$(basename "$target")
    local ts_stamp; ts_stamp=$(date '+%Y%m%d%H%M%S')
    local canonical_rel="../../../shared/blocks/$fname"

    # Save rollback info
    if [ -L "$target" ]; then
        readlink "$target" > "${target}.pre-symlink-${ts_stamp}.readlink" 2>/dev/null || true
        rm -f "$target"
    elif [ -f "$target" ]; then
        cp "$target" "${target}.pre-symlink-${ts_stamp}"
    fi

    ln -sf "$canonical_rel" "$target"
}

do_rollback_symlink() {
    local target="$1"
    # Prefer regular-file backup
    local backup; backup=$(ls -1t "${target}.pre-symlink-"*.pre-symlink-* 2>/dev/null | grep -v ".readlink" | head -1 || true)
    if [ -n "$backup" ]; then
        rm -f "$target"
        mv "$backup" "$target"
        echo "restored_from_backup"
        return
    fi
    # Symlink backup
    local rl_backup; rl_backup=$(ls -1t "${target}.pre-symlink-"*.readlink 2>/dev/null | head -1 || true)
    if [ -n "$rl_backup" ]; then
        local orig_target; orig_target=$(cat "$rl_backup")
        ln -sf "$orig_target" "$target"
        rm -f "$rl_backup"
        echo "restored_symlink_target"
        return
    fi
    echo "no_backup_found"
}

# ── SENSE ─────────────────────────────────────────────────────────────────────

do_sense() {
    broken_count=0; drift_safe_count=0; drift_conflict_count=0
    BROKEN_LIST=(); DRIFT_SAFE_LIST=(); DRIFT_CONFLICT_LIST=()

    while IFS= read -r -d '' f; do
        local fname; fname=$(basename "$f")
        is_denied "$f" && continue
        is_canonical_name "$fname" || continue

        if [ -L "$f" ]; then
            if [ ! -e "$f" ]; then
                BROKEN_LIST+=("$f"); broken_count=$((broken_count+1))
            fi
        elif [ -f "$f" ]; then
            local canonical="$SHARED_BLOCKS/$fname"
            [ -f "$canonical" ] || continue
            if [ "$(md5_of "$f")" = "$(md5_of "$canonical")" ]; then
                DRIFT_SAFE_LIST+=("$f"); drift_safe_count=$((drift_safe_count+1))
            else
                DRIFT_CONFLICT_LIST+=("$f"); drift_conflict_count=$((drift_conflict_count+1))
            fi
        fi
    done < <(find "$BOTS_DIR" \
        \( -path "$BOTS_DIR/*/work/*" -o -path "*/.worktrees/*" -o -path "*/bak*/*" \) -prune \
        -o -path "*/blocks/block-*.md" -print0 2>/dev/null)

    total_anomalies=$((broken_count + drift_safe_count + drift_conflict_count))
}

# ── MAIN ──────────────────────────────────────────────────────────────────────

main() {
    load_config

    if [ "$loop_enabled" != "1" ]; then
        echo "[symlink-health] loop_enabled=0, exiting." >&2
        exit 0
    fi

    local RUN_ID; RUN_ID=$(run_id)
    local TS; TS=$(ts_now)
    local run_status="healthy"
    echo -n > "$FINDINGS_TMP"  # clear findings tmp

    do_sense

    local known_symlinks=48
    local threshold_count=$(( known_symlinks * topology_threshold_pct / 100 ))

    # Topology anomaly guard
    if [ "$total_anomalies" -gt "$threshold_count" ]; then
        escalate_to_anya \
            "[circuit-breaker] Topology anomaly: ${total_anomalies} issues (>${topology_threshold_pct}% of ${known_symlinks})" \
            "Halting loop. Possible in-progress refactor or mass breakage. Human review required."
        write_audit_entry "$RUN_ID" "$TS" "circuit_break_topology" 0 "$total_anomalies" 0 0
        exit 0
    fi

    # Process broken symlinks
    for target in "${BROKEN_LIST[@]+"${BROKEN_LIST[@]}"}"; do
        is_denied "$target" && continue
        local fname; fname=$(basename "$target")
        is_canonical_name "$fname" || { escalate_to_anya "[unknown-canonical] $target" "Broken symlink to non-registered canonical: $fname"; continue; }
        local canonical_rel="../../../shared/blocks/$fname"

        if [ "$auto_fix_enabled" = "1" ]; then
            do_fix_symlink "$target"
            local v; v=$(verify_symlink "$target")
            if [[ "$v" == PASS* ]]; then
                add_finding "target=$target" "type=broken" "action=fixed" "verify=$v"
                run_status="fixed"; check_chronic_drift "$target"
                circuit_reset
            else
                local rb; rb=$(do_rollback_symlink "$target")
                circuit_bump
                add_finding "target=$target" "type=broken" "action=rollback" "verify=$v" "rollback=$rb"
                run_status="rollback"
                escalate_to_anya "[rollback] $target: verify failed ($v)" "Rollback: $rb. Circuit count: $(circuit_count)/$circuit_breaker_limit"
                if [ "$(circuit_count)" -ge "$circuit_breaker_limit" ]; then
                    escalate_to_anya "[circuit-breaker] Loop halted after $(circuit_count) consecutive failures" "Manual intervention required."
                    circuit_reset
                    write_audit_entry "$RUN_ID" "$TS" "circuit_break_consecutive" 0 0 0 0
                    exit 0
                fi
            fi
        else
            # DRY-RUN: human-readable proposal
            local proposal="WOULD: ln -sf $canonical_rel $target  ← broken symlink, canonical exists and is readable"
            add_finding "target=$target" "type=broken" "action=dry_run_proposed" "proposal=$proposal"
            run_status="dry_run"
        fi
    done

    # Process safe drift (md5-identical regular files → safe to convert to symlink)
    for target in "${DRIFT_SAFE_LIST[@]+"${DRIFT_SAFE_LIST[@]}"}"; do
        is_denied "$target" && continue
        local fname; fname=$(basename "$target")
        is_canonical_name "$fname" || continue
        local canonical_rel="../../../shared/blocks/$fname"

        if [ "$auto_fix_enabled" = "1" ]; then
            do_fix_symlink "$target"
            local v; v=$(verify_symlink "$target")
            if [[ "$v" == PASS* ]]; then
                add_finding "target=$target" "type=drift_safe" "action=converted_to_symlink" "verify=$v"
                run_status="fixed"; check_chronic_drift "$target"
            else
                do_rollback_symlink "$target" >/dev/null
                circuit_bump
                add_finding "target=$target" "type=drift_safe" "action=rollback" "verify=$v"
                run_status="rollback"
            fi
        else
            local proposal="WOULD: cp $target $target.pre-symlink-<TS> && ln -sf $canonical_rel $target  ← regular file, content == canonical (safe dedup)"
            add_finding "target=$target" "type=drift_safe" "action=dry_run_proposed" "proposal=$proposal"
            run_status="dry_run"
        fi
    done

    # Drift conflicts: escalate once per (file, md5) per window, never auto-fix
    for target in "${DRIFT_CONFLICT_LIST[@]+"${DRIFT_CONFLICT_LIST[@]}"}"; do
        local fname; fname=$(basename "$target")
        local m1; m1=$(md5_of "$target"); local m2; m2=$(md5_of "$SHARED_BLOCKS/$fname")
        if should_escalate_drift "$target" "$m1"; then
            add_finding "target=$target" "type=drift_conflict" "action=escalated" "detail=content_differs_from_canonical(file=$m1,canonical=$m2)"
            escalate_to_anya \
                "[drift-conflict] $(basename "$(dirname "$(dirname "$target")")")/blocks/$fname content differs from canonical" \
                "File $target has different content from $SHARED_BLOCKS/$fname. Human decision required: which is authoritative? md5 file=$m1 canonical=$m2"
            run_status="escalated"
        else
            add_finding "target=$target" "type=drift_conflict" "action=deduped" "detail=content_differs_from_canonical(file=$m1,canonical=$m2)"
        fi
    done

    # Reset circuit if fully healthy
    [ "$total_anomalies" -eq 0 ] && circuit_reset

    write_audit_entry "$RUN_ID" "$TS" "$run_status" \
        "$((known_symlinks - total_anomalies))" "$broken_count" "$drift_safe_count" "$drift_conflict_count"

    echo "[$(ts_now)] run=$RUN_ID status=$run_status healthy=$((known_symlinks-total_anomalies)) broken=$broken_count drift_safe=$drift_safe_count drift_conflict=$drift_conflict_count mode=$( [ "$auto_fix_enabled" = "1" ] && echo auto_fix || echo dry_run)" >&2
}

write_audit_entry() {
    local run_id="$1" ts="$2" status="$3" healthy="$4" broken="$5" drift_safe="$6" drift_conflict="$7"
    python3 - "$AUDIT_LOG" "$FINDINGS_TMP" "$run_id" "$ts" "$status" "$healthy" "$broken" "$drift_safe" "$drift_conflict" "$auto_fix_enabled" << 'PYEOF'
import json, sys
log_path, findings_path, run_id, ts, status, healthy, broken, drift_safe, drift_conflict, mode = sys.argv[1:]

findings = []
try:
    for line in open(findings_path):
        line = line.strip()
        if line: findings.append(json.loads(line))
except: pass

# fix_count_per_target for this run
fix_counts = {}
for f in findings:
    if f.get('action') in ('fixed','converted_to_symlink','dry_run_proposed'):
        t = f.get('target','')
        fix_counts[t] = fix_counts.get(t, 0) + 1

entry = {
    "ts": ts,
    "run_id": run_id,
    "status": status,
    "loop_mode": "auto_fix" if mode == "1" else "dry_run",
    "summary": {
        "healthy": int(healthy),
        "broken": int(broken),
        "drift_safe": int(drift_safe),
        "drift_conflict": int(drift_conflict),
    },
    "fix_count_per_target": fix_counts,
    "findings": findings,
}
with open(log_path, 'a') as f:
    f.write(json.dumps(entry, ensure_ascii=False) + '\n')
PYEOF
}

main "$@"
