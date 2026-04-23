#!/usr/bin/env bash
# measure-bot-startup.sh BOT_NAME [LABEL] [--method ping|audit]
#
# Two measurement methods:
#
# METHOD=ping (Phase 1, default for backward compat):
#   A = tmux new-session epoch
#   P = ping relay file written (T = A + WARMUP_SECONDS)
#   C = first audit.log entry with tool=mcp__plugin_telegram_telegram__reply
#        AND chat_id=-1003634255226 AFTER ping timestamp
#   Fields: boot_to_ping (P-A, fixed), ping_to_reply (C-P, variable), total (C-A)
#
# METHOD=audit (Phase 2):
#   A = tmux new-session epoch
#   C = first audit.log entry for this bot with ts >= A (any tool call)
#   No warmup, no ping — measures boot → first Claude tool activity directly.
#   Fields: boot_to_first_audit (C-A), c_ts, c_tool
#
# Rationale for Phase 2 audit method: Phase 1 ping method uses fixed 30s warmup,
# which absorbs cat-segment removal / context-size reduction benefits. audit
# method measures the true cold-start latency to first tool call, capturing
# context-load improvements in the metric.
#
# Emits one JSON object on stdout. Exit codes: 0 ok · 2 timeout · 3 no start.sh
#
# Env vars:
#   WARMUP_SECONDS (default 30)  — ping method only
#   MAX_WAIT_REPLY (default 360) — ping method timeout
#   MAX_WAIT_AUDIT (default 360) — audit method timeout (first entry)

set -uo pipefail

BOT_NAME=""
LABEL="unlabeled"
METHOD="ping"

# Parse args: BOT_NAME and LABEL are positional, --method is flag
POS_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --method)
      METHOD="$2"
      shift 2
      ;;
    --method=*)
      METHOD="${1#--method=}"
      shift
      ;;
    *)
      POS_ARGS+=("$1")
      shift
      ;;
  esac
done

BOT_NAME="${POS_ARGS[0]:-}"
LABEL="${POS_ARGS[1]:-unlabeled}"

if [ -z "$BOT_NAME" ]; then
  echo "usage: $0 BOT_NAME [LABEL] [--method ping|audit]" >&2
  exit 1
fi

if [ "$METHOD" != "ping" ] && [ "$METHOD" != "audit" ] && [ "$METHOD" != "tokens" ]; then
  echo "invalid --method $METHOD (expected ping|audit|tokens)" >&2
  exit 1
fi

STATE_DIR="$HOME/.claude-bots/bots/$BOT_NAME"
AUDIT_LOG="$STATE_DIR/audit.log"
START_SH="$STATE_DIR/start.sh"
RELAY_DIR="$HOME/.claude-bots/relay"
POOL_CHAT="-1003634255226"

if [ ! -f "$START_SH" ]; then
  echo "no start.sh for $BOT_NAME ($START_SH)" >&2
  exit 3
fi

WARMUP_SECONDS="${WARMUP_SECONDS:-30}"
MAX_WAIT_REPLY="${MAX_WAIT_REPLY:-360}"
MAX_WAIT_AUDIT="${MAX_WAIT_AUDIT:-360}"

# Map bot directory name → Telegram bot_username for relay file (from USER.md lookup)
case "$BOT_NAME" in
  anna) TG_USER="annadesu_bot" ;;
  Bella) TG_USER="Bellalovechl_Bot" ;;
  yitang) TG_USER="onesoup_bot" ;;
  ron-builder) TG_USER="Ron0002_bot" ;;
  ron-reviewer) TG_USER="Ron0003_bot" ;;
  sancai) TG_USER="threedishes_bot" ;;
  caijie-zhuchu) TG_USER="CarrotAAA_bot" ;;
  nicky-builder) TG_USER="NickyBuilder_bot" ;;
  nicky-zhanglinghe) TG_USER="ZhangLingheAI_bot" ;;
  chltao) TG_USER="chltao_bot" ;;
  anya) TG_USER="Anyachl_bot" ;;
  *) echo "unknown bot_username mapping for $BOT_NAME" >&2; exit 1 ;;
esac

# Capture audit.log line count before kill — audit method uses this as the
# "new entries appear after this offset" marker. More reliable than timestamp
# comparison because audit ts has 1-second precision.
if [ -f "$AUDIT_LOG" ]; then
  AUDIT_OFFSET=$(wc -l < "$AUDIT_LOG")
else
  AUDIT_OFFSET=0
fi

# Snapshot existing JSONL files BEFORE tmux kill — tokens method uses this
# to identify the new session's file (sessionId == filename).
JSONL_DIR="$HOME/.claude/projects/-home-oldrabbit--claude-bots-bots-$BOT_NAME"
PRE_FILES=$(ls "$JSONL_DIR"/*.jsonl 2>/dev/null | sort -u | tr '\n' '|')

# Kill existing tmux session
tmux kill-session -t "$BOT_NAME" 2>/dev/null || true
for _ in $(seq 1 10); do
  tmux has-session -t "$BOT_NAME" 2>/dev/null || break
  sleep 0.3
done

# A = new-session timestamp
A_EPOCH=$(date +%s.%N)
A_ISO=$(date -u -d "@$A_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')
tmux new-session -d -s "$BOT_NAME" "cd '$STATE_DIR' && bash '$START_SH'"

# === AUDIT METHOD — wait for plugin-ready, inject ping, poll first audit ===
#
# Note: Phase 1 discovery — bots do NOT auto-execute §7 on pure boot. The
# internal boot-trigger (chat_id:"self") is consumed silently. We need a
# real pool-chat ping.
#
# Key constraint: the telegram plugin's relay watcher only processes files
# created AFTER it starts. If we drop the ping at A_EPOCH (pre-claude), the
# plugin likely ignores it on initial dir scan. Fix: poll tmux pane for the
# "Listening for channel messages" banner → that's the plugin-ready signal.
# Then write ping. P = plugin-ready epoch. C = first new audit entry.
#
# boot_to_plugin_ready = P - A  (bash + claude + MCP boot — captures ctx load)
# plugin_ready_to_first_audit = C - P  (ping round-trip)
# boot_to_first_audit = C - A  (total)
#
# Phase 2 hypothesis: mistakes.md lazy-load cuts `boot_to_plugin_ready` by
# eliminating 13KB prompt load during claude init.
if [ "$METHOD" = "audit" ]; then
  # Wait for telegram plugin to signal "Listening for channel messages"
  plugin_ready=0
  waited_plugin=0
  PLUGIN_WAIT_MAX="${PLUGIN_WAIT_MAX:-120}"
  while [ "$waited_plugin" -lt "$((PLUGIN_WAIT_MAX * 2))" ]; do
    if tmux capture-pane -t "$BOT_NAME" -p 2>/dev/null | grep -q "Listening for channel messages"; then
      plugin_ready=1
      break
    fi
    sleep 0.5
    waited_plugin=$((waited_plugin + 1))
  done

  if [ "$plugin_ready" -eq 0 ]; then
    jq -nc --arg bot "$BOT_NAME" --arg run_label "$LABEL" \
      --arg method "$METHOD" --arg a_epoch "$A_EPOCH" \
      '{error:"timeout_plugin_ready", bot:$bot, "label":$run_label, method:$method, a_epoch:$a_epoch}'
    exit 2
  fi

  # Buffer between banner appearing and plugin fully subscribing to relay inotify.
  # Empirically: banner-only pings are silently dropped; 5s buffer reliably ensures
  # the plugin's relay watcher is live. This buffer is constant across runs so it
  # doesn't contaminate before/after delta comparisons.
  PLUGIN_BUFFER_SECONDS="${PLUGIN_BUFFER_SECONDS:-5}"
  sleep "$PLUGIN_BUFFER_SECONDS"

  P_EPOCH=$(date +%s.%N)
  A_ISO_MS=$(date -u -d "@$P_EPOCH" '+%Y-%m-%dT%H:%M:%S.%3NZ')
  PING_FILE="$RELAY_DIR/measure-ping-$BOT_NAME-$$-$(date +%s).json"
  cat > "${PING_FILE}.tmp" <<EOF
{"from_bot":"sancai-measure","chat_id":"$POOL_CHAT","text":"@$TG_USER audit ping [$LABEL] — 請執行 §7 啟動自檢，完成後在此群組 reply「audit ready [$LABEL]」。","message_id":0,"ts":"$A_ISO_MS"}
EOF
  mv "${PING_FILE}.tmp" "$PING_FILE"

  waited=0
  C_LINE=""
  while [ "$waited" -lt "$((MAX_WAIT_AUDIT * 2))" ]; do
    if [ -f "$AUDIT_LOG" ]; then
      CURRENT_LINES=$(wc -l < "$AUDIT_LOG")
      if [ "$CURRENT_LINES" -gt "$AUDIT_OFFSET" ]; then
        C_LINE=$(tail -n +$((AUDIT_OFFSET + 1)) "$AUDIT_LOG" | head -1)
        if [ -n "$C_LINE" ]; then
          break
        fi
      fi
    fi
    sleep 0.5
    waited=$((waited + 1))
  done

  # Clean up ping file
  rm -f "$PING_FILE" "${PING_FILE}.read-by-"* 2>/dev/null

  if [ -z "$C_LINE" ]; then
    jq -nc --arg bot "$BOT_NAME" --arg run_label "$LABEL" \
      --arg method "$METHOD" --arg a_epoch "$A_EPOCH" \
      --argjson offset "$AUDIT_OFFSET" \
      '{error:"timeout_audit", bot:$bot, "label":$run_label, method:$method, a_epoch:$a_epoch, audit_offset:$offset}'
    exit 2
  fi

  C_TS=$(echo "$C_LINE" | jq -r '.ts')
  C_TOOL=$(echo "$C_LINE" | jq -r '.tool // "unknown"')
  C_EPOCH=$(date -u -d "$C_TS" +%s.%N)
  BOOT_TO_PLUGIN_READY=$(awk "BEGIN{printf \"%.3f\", $P_EPOCH - $A_EPOCH}")
  PLUGIN_TO_FIRST_AUDIT=$(awk "BEGIN{printf \"%.3f\", $C_EPOCH - $P_EPOCH}")
  BOOT_TO_FIRST_AUDIT=$(awk "BEGIN{printf \"%.3f\", $C_EPOCH - $A_EPOCH}")

  jq -nc \
    --arg bot "$BOT_NAME" \
    --arg run_label "$LABEL" \
    --arg method "$METHOD" \
    --arg a_epoch "$A_EPOCH" \
    --arg p_epoch "$P_EPOCH" \
    --arg c_epoch "$C_EPOCH" \
    --arg c_ts "$C_TS" \
    --arg c_tool "$C_TOOL" \
    --argjson boot_to_plugin_ready "$BOOT_TO_PLUGIN_READY" \
    --argjson plugin_to_first_audit "$PLUGIN_TO_FIRST_AUDIT" \
    --argjson boot_to_first_audit "$BOOT_TO_FIRST_AUDIT" \
    '{bot:$bot, "label":$run_label, method:$method,
      a_epoch:$a_epoch, p_epoch:$p_epoch, c_epoch:$c_epoch, c_ts:$c_ts, c_tool:$c_tool,
      boot_to_plugin_ready:$boot_to_plugin_ready,
      plugin_to_first_audit:$plugin_to_first_audit,
      boot_to_first_audit:$boot_to_first_audit}'
  exit 0
fi
# === END AUDIT METHOD ===

# === TOKENS METHOD — read first assistant turn's usage from session JSONL ===
#
# Phase 3 measures input-token context size, which is a cleaner signal than
# wall-clock when the intervention targets prompt size (e.g. MEMORY.md shrink).
# No ping needed: bot's §7 self-check fires assistant turns on its own.
#
# Fields:
#   input_tokens:              fresh (non-cached) tokens, typically just user turn
#   cache_creation_input_tokens: tokens written to cache this turn
#   cache_read_input_tokens:   tokens read from existing cache
#   input_tokens_bootstrap:    sum of the three = total prompt context
#
# spec tech_note says use first user turn's input_tokens, but user-type entries
# have no usage field in Claude Code JSONL. We report the first assistant turn
# fields + the sum. Primary Phase 3 AC metric is input_tokens_bootstrap (sum).
if [ "$METHOD" = "tokens" ]; then
  # Step 1: wait for plugin-ready banner (same as audit method).
  plugin_ready=0
  waited_plugin=0
  PLUGIN_WAIT_MAX="${PLUGIN_WAIT_MAX:-120}"
  while [ "$waited_plugin" -lt "$((PLUGIN_WAIT_MAX * 2))" ]; do
    if tmux capture-pane -t "$BOT_NAME" -p 2>/dev/null | grep -q "Listening for channel messages"; then
      plugin_ready=1
      break
    fi
    sleep 0.5
    waited_plugin=$((waited_plugin + 1))
  done
  if [ "$plugin_ready" -eq 0 ]; then
    jq -nc --arg bot "$BOT_NAME" --arg run_label "$LABEL" \
      --arg method "$METHOD" --arg a_epoch "$A_EPOCH" \
      '{error:"timeout_plugin_ready", bot:$bot, "label":$run_label, method:$method, a_epoch:$a_epoch}'
    exit 2
  fi

  # Step 2: 5s buffer, then ping to trigger first assistant turn.
  PLUGIN_BUFFER_SECONDS="${PLUGIN_BUFFER_SECONDS:-5}"
  sleep "$PLUGIN_BUFFER_SECONDS"

  P_ISO=$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')
  PING_FILE="$RELAY_DIR/measure-ping-$BOT_NAME-$$-$(date +%s).json"
  cat > "${PING_FILE}.tmp" <<EOF
{"from_bot":"sancai-measure","chat_id":"$POOL_CHAT","text":"@$TG_USER tokens ping [$LABEL] — 請執行 §7 啟動自檢，完成後在此群組 reply「tokens ready [$LABEL]」。","message_id":0,"ts":"$P_ISO"}
EOF
  mv "${PING_FILE}.tmp" "$PING_FILE"

  # Step 3: poll for new JSONL with type=assistant having usage.input_tokens.
  MAX_WAIT_TOKENS="${MAX_WAIT_TOKENS:-180}"
  waited=0
  TARGET_JSONL=""
  FIRST_ASSIST_LINE=""
  while [ "$waited" -lt "$((MAX_WAIT_TOKENS * 2))" ]; do
    for f in $(ls -t "$JSONL_DIR"/*.jsonl 2>/dev/null); do
      base="$f"
      if echo "$PRE_FILES" | grep -qF "$base|"; then
        continue  # pre-existing file
      fi
      LINE=$(grep -m1 '"type":"assistant"' "$f" 2>/dev/null | head -1 || true)
      if [ -n "$LINE" ]; then
        HAS_USAGE=$(echo "$LINE" | jq -r 'try .message.usage.input_tokens // empty' 2>/dev/null)
        if [ -n "$HAS_USAGE" ]; then
          TARGET_JSONL="$f"
          FIRST_ASSIST_LINE="$LINE"
          break 2
        fi
      fi
    done
    sleep 0.5
    waited=$((waited + 1))
  done

  rm -f "$PING_FILE" "${PING_FILE}.read-by-"* 2>/dev/null

  if [ -z "$FIRST_ASSIST_LINE" ]; then
    jq -nc --arg bot "$BOT_NAME" --arg run_label "$LABEL" \
      --arg method "$METHOD" --arg a_epoch "$A_EPOCH" \
      '{error:"timeout_tokens", bot:$bot, "label":$run_label, method:$method, a_epoch:$a_epoch}'
    exit 2
  fi

  INPUT_T=$(echo "$FIRST_ASSIST_LINE" | jq -r '.message.usage.input_tokens // 0')
  CACHE_CREATE=$(echo "$FIRST_ASSIST_LINE" | jq -r '.message.usage.cache_creation_input_tokens // 0')
  CACHE_READ=$(echo "$FIRST_ASSIST_LINE" | jq -r '.message.usage.cache_read_input_tokens // 0')
  BOOTSTRAP=$((INPUT_T + CACHE_CREATE + CACHE_READ))

  jq -nc \
    --arg bot "$BOT_NAME" \
    --arg run_label "$LABEL" \
    --arg method "$METHOD" \
    --arg a_epoch "$A_EPOCH" \
    --arg jsonl "$TARGET_JSONL" \
    --argjson input_tokens "$INPUT_T" \
    --argjson cache_creation_input_tokens "$CACHE_CREATE" \
    --argjson cache_read_input_tokens "$CACHE_READ" \
    --argjson input_tokens_bootstrap "$BOOTSTRAP" \
    '{bot:$bot, "label":$run_label, method:$method, a_epoch:$a_epoch,
      jsonl:$jsonl,
      input_tokens:$input_tokens,
      cache_creation_input_tokens:$cache_creation_input_tokens,
      cache_read_input_tokens:$cache_read_input_tokens,
      input_tokens_bootstrap:$input_tokens_bootstrap}'
  exit 0
fi
# === END TOKENS METHOD ===

# Warmup: wait for claude process to fully spin up (MCP, plugins, CLAUDE.md load).
# Sleeping in the driver side — do NOT replace this with a quicker poll, since
# we want a deterministic pre-ping window so before/after delays are comparable.
sleep "$WARMUP_SECONDS"

# P = ping timestamp. Write a relay file to inject a pool-chat mention.
P_EPOCH=$(date +%s.%N)
P_ISO=$(date -u -d "@$P_EPOCH" '+%Y-%m-%dT%H:%M:%S.%3NZ')
PING_FILE="$RELAY_DIR/measure-ping-$BOT_NAME-$$-$(date +%s).json"
cat > "${PING_FILE}.tmp" <<EOF
{"from_bot":"sancai-measure","chat_id":"$POOL_CHAT","text":"@$TG_USER baseline ping [$LABEL] — 請執行 §7 啟動自檢：並行讀 team-l0.md + MEMORY.md + session.json + mistakes.md，然後在此群組 reply「baseline ready [$LABEL]」。","message_id":0,"ts":"$P_ISO"}
EOF
mv "${PING_FILE}.tmp" "$PING_FILE"

# Wait for first audit.log entry with tool=mcp__plugin_telegram_telegram__reply
# AND chat_id matches pool, AND ts >= P_ISO
waited=0
C_LINE=""
while [ "$waited" -lt "$((MAX_WAIT_REPLY * 2))" ]; do
  if [ -s "$AUDIT_LOG" ]; then
    C_LINE=$(awk -v since="$P_ISO" '
      match($0, /"ts":"[^"]*"/) {
        ts = substr($0, RSTART+6, RLENGTH-7);
        if (ts >= since) print $0
      }' "$AUDIT_LOG" | grep 'mcp__plugin_telegram_telegram__reply' | grep -F "\"chat_id\":\"$POOL_CHAT\"" | head -1 || true)
    if [ -n "$C_LINE" ]; then
      break
    fi
  fi
  sleep 0.5
  waited=$((waited + 1))
done

# Clean up ping file (read-by-* may or may not exist)
rm -f "$PING_FILE" "${PING_FILE}.read-by-"* 2>/dev/null

if [ -z "$C_LINE" ]; then
  jq -nc --arg bot "$BOT_NAME" --arg run_label "$LABEL" \
    --arg a_epoch "$A_EPOCH" --arg p_epoch "$P_EPOCH" \
    '{error:"timeout_reply", bot:$bot, "label":$run_label, a_epoch:$a_epoch, p_epoch:$p_epoch}'
  exit 2
fi

C_TS=$(echo "$C_LINE" | jq -r '.ts')
C_EPOCH=$(date -u -d "$C_TS" +%s.%N)

BOOT_TO_PING=$(awk "BEGIN{printf \"%.3f\", $P_EPOCH - $A_EPOCH}")
PING_TO_REPLY=$(awk "BEGIN{printf \"%.3f\", $C_EPOCH - $P_EPOCH}")
TOTAL=$(awk "BEGIN{printf \"%.3f\", $C_EPOCH - $A_EPOCH}")

jq -nc \
  --arg bot "$BOT_NAME" \
  --arg run_label "$LABEL" \
  --arg method "$METHOD" \
  --arg a_epoch "$A_EPOCH" \
  --arg p_epoch "$P_EPOCH" \
  --arg c_epoch "$C_EPOCH" \
  --arg c_ts "$C_TS" \
  --argjson warmup "$WARMUP_SECONDS" \
  --argjson boot_to_ping "$BOOT_TO_PING" \
  --argjson ping_to_reply "$PING_TO_REPLY" \
  --argjson total "$TOTAL" \
  '{bot:$bot, "label":$run_label, method:$method,
    a_epoch:$a_epoch, p_epoch:$p_epoch, c_epoch:$c_epoch,
    c_ts:$c_ts, warmup_seconds:$warmup,
    boot_to_ping:$boot_to_ping, ping_to_reply:$ping_to_reply, total:$total}'
