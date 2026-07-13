#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
HELPER="$ROOT/shared/lib/pod-start-guard.sh"
BOOT_HELPER="$ROOT/shared/lib/boot-relay.sh"
START_TEMPLATE="$ROOT/shared/templates/start.sh"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

export HOME="$FIX/home"
export POD_START_GUARD_REPO_ROOT="$FIX/repo"
export POD_START_GUARD_PROC_DIR="$FIX/proc"
export POD_START_GUARD_PARENT_PID=100

mkdir -p "$HOME/.claude-bots/shared/lib" "$POD_START_GUARD_REPO_ROOT/gateway-builder/pods"
cp "$HELPER" "$HOME/.claude-bots/shared/lib/pod-start-guard.sh"
cp "$BOOT_HELPER" "$HOME/.claude-bots/shared/lib/boot-relay.sh"
cat > "$HOME/.claude-bots/shared/lib/bot-crons-prompt.sh" <<'EOF'
#!/usr/bin/env bash
printf '\nCRON_INIT_FIXTURE\n'
EOF
chmod +x "$HOME/.claude-bots/shared/lib/bot-crons-prompt.sh"

cat > "$POD_START_GUARD_REPO_ROOT/gateway-builder/pods/assist-anya.json" <<'EOF'
{"bots":[{"name":"anya"}]}
EOF

fake_proc() {
  local pid="$1" comm="$2" ppid="$3"
  mkdir -p "$POD_START_GUARD_PROC_DIR/$pid"
  printf '%s\n' "$comm" > "$POD_START_GUARD_PROC_DIR/$pid/comm"
  printf 'Name:\t%s\nPPid:\t%s\n' "$comm" "$ppid" > "$POD_START_GUARD_PROC_DIR/$pid/status"
}

fake_proc 100 bash 200
fake_proc 200 'tmux: server' 1
fake_proc 1 systemd 0

source "$HOME/.claude-bots/shared/lib/pod-start-guard.sh"

if enforce_pod_start_guard anya >/tmp/pod-start-guard.out 2>/tmp/pod-start-guard.err; then
  echo "expected pod-managed anya under tmux to be blocked" >&2
  exit 1
fi

grep -q 'systemctl --user restart gateway@assist-anya' /tmp/pod-start-guard.err

enforce_pod_start_guard non-pod-bot >/tmp/pod-start-guard.out 2>/tmp/pod-start-guard.err

rm -rf "$POD_START_GUARD_PROC_DIR"
mkdir -p "$POD_START_GUARD_PROC_DIR"
fake_proc 100 bash 1
fake_proc 1 systemd 0
enforce_pod_start_guard anya >/tmp/pod-start-guard.out 2>/tmp/pod-start-guard.err

cat > "$FIX/start-callsite-fixture.sh" <<'EOF'
#!/usr/bin/env bash
BOT_NAME="anya"
source "$HOME/.claude-bots/shared/lib/pod-start-guard.sh"
enforce_pod_start_guard "$BOT_NAME" || exit 1
echo "SESSION_CLEANUP_MARKER"
EOF
chmod +x "$FIX/start-callsite-fixture.sh"

rm -rf "$POD_START_GUARD_PROC_DIR"
mkdir -p "$POD_START_GUARD_PROC_DIR"
fake_proc 100 bash 200
fake_proc 200 'tmux: server' 1
fake_proc 1 systemd 0

if "$FIX/start-callsite-fixture.sh" >/tmp/pod-start-callsite.out 2>/tmp/pod-start-callsite.err; then
  echo "expected start.sh callsite to exit non-zero for pod-managed anya under tmux" >&2
  exit 1
fi

grep -q 'systemctl --user restart gateway@assist-anya' /tmp/pod-start-callsite.err
if grep -q 'SESSION_CLEANUP_MARKER' /tmp/pod-start-callsite.out; then
  echo "start.sh callsite continued past pod guard into session cleanup marker" >&2
  exit 1
fi

render_start() {
  local bot_name="$1"
  local bot_username="$2"
  local out="$3"
  sed \
    -e "s/{{BOT_NAME}}/$bot_name/g" \
    -e "s/{{BOT_USERNAME}}/$bot_username/g" \
    "$START_TEMPLATE" > "$out"
  chmod +x "$out"
}

count_boot_files() {
  local relay_dir="$1"
  find "$relay_dir" -maxdepth 1 -type f -name 'boot-*.json' 2>/dev/null | wc -l
}

mkdir -p "$FIX/bin"
cat > "$FIX/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'FAKE_CLAUDE_STARTED\n'
sleep 2
EOF
chmod +x "$FIX/bin/claude"

mkdir -p "$HOME/.claude-bots/bots/anya" "$HOME/.claude-bots/bots/sandbox"

# End-to-end production-path fixture: render the real start.sh template and run
# it as a pod-managed bot under a fake tmux ancestor. It must terminate before
# session cleanup, Claude startup, or boot relay file creation.
BLOCKED_DIR="$FIX/full-start-blocked"
mkdir -p "$BLOCKED_DIR"
render_start "anya" "anya_bot" "$BLOCKED_DIR/start.sh"

rm -rf "$POD_START_GUARD_PROC_DIR"
mkdir -p "$POD_START_GUARD_PROC_DIR" "$HOME/.claude-bots/relay"
fake_proc 100 bash 200
fake_proc 200 'tmux: server' 1
fake_proc 1 systemd 0
rm -f "$HOME/.claude-bots/relay"/boot-*.json

if env PATH="$FIX/bin:$PATH" "$BLOCKED_DIR/start.sh" \
    >/tmp/pod-start-full-blocked.out 2>/tmp/pod-start-full-blocked.err; then
  echo "expected full start.sh to exit non-zero for pod-managed anya under tmux" >&2
  exit 1
fi

grep -q 'systemctl --user restart gateway@assist-anya' /tmp/pod-start-full-blocked.err
if grep -q 'Cleared yesterday' /tmp/pod-start-full-blocked.out ||
    grep -q 'FAKE_CLAUDE_STARTED' /tmp/pod-start-full-blocked.out; then
  echo "full start.sh continued past pod guard into production startup path" >&2
  exit 1
fi
if [[ "$(count_boot_files "$HOME/.claude-bots/relay")" != "0" ]]; then
  echo "blocked full start.sh produced boot relay files" >&2
  exit 1
fi
echo "EVIDENCE blocked_full_start rc=nonzero boot_files=0 fake_claude_started=0"

# Control: a non-pod bot launched through the same full start.sh path is allowed
# to reach fake Claude startup and produce a boot relay file in the disposable
# relay directory.
CONTROL_DIR="$FIX/full-start-control"
mkdir -p "$CONTROL_DIR"
render_start "sandbox" "sandbox_bot" "$CONTROL_DIR/start.sh"
rm -f "$HOME/.claude-bots/relay"/boot-*.json
rm -rf "$POD_START_GUARD_PROC_DIR"
mkdir -p "$POD_START_GUARD_PROC_DIR"
fake_proc 100 bash 200
fake_proc 200 'tmux: server' 1
fake_proc 1 systemd 0

set +e
timeout 3s env PATH="$FIX/bin:$PATH" BOOT_WAIT=0 BOOT_RELAY_KEEP_FILES=1 \
  "$CONTROL_DIR/start.sh" >/tmp/pod-start-full-control.out 2>/tmp/pod-start-full-control.err
control_rc=$?
set -e

if [[ "$control_rc" != "124" && "$control_rc" != "0" ]]; then
  echo "non-pod full start.sh control failed unexpectedly with rc=$control_rc" >&2
  cat /tmp/pod-start-full-control.err >&2
  exit 1
fi
grep -q 'FAKE_CLAUDE_STARTED' /tmp/pod-start-full-control.out
if [[ "$(count_boot_files "$HOME/.claude-bots/relay")" == "0" ]]; then
  echo "non-pod full start.sh control did not produce a boot relay file" >&2
  exit 1
fi
echo "EVIDENCE control_full_start rc=$control_rc boot_files=$(count_boot_files "$HOME/.claude-bots/relay") fake_claude_started=1"

echo "PASS pod-start-guard-fixture"
