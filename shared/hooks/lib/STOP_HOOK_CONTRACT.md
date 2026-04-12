# Stop Hook Contract

**Status**: Simulated harness verified 2026-04-08. Live Claude Code verification needed.

---

## What is a Stop Hook?

Claude Code fires Stop hooks when the AI stops running (end of task, user interrupt, or `/stop`). Each configured hook script is spawned as an independent subprocess with:
- **stdin**: JSON payload from Claude Code
- **stdout**: JSON response (`{}` = allow, `{"decision":"block","reason":"..."}` = block and re-prompt)
- **env**: inherits Claude Code's process environment

Multiple Stop hooks configured in `settings.json` are called **sibling processes** — independent subprocesses with no parent/child relationship to each other.

---

## Verified Behavior (simulated harness, 2026-04-08)

### Q1: stdin delivery

**Finding**: Each hook process receives its own stdin pipe with the **same JSON content**. Stdin is NOT shared or consumed between siblings.

```json
// Claude Code sends this JSON to EVERY configured Stop hook:
{
  "session_id": "abc123",
  "stop_hook_active": false,
  "transcript_path": "/path/to/transcript.jsonl"
}
```

Key fields:
- `stop_hook_active: false` — normal stop (first stop in cycle)
- `stop_hook_active: true` — Claude is re-stopping after a block cycle (dead-loop prevention signal)

**Implication**: All siblings see the same `stop_hook_active` value. If hookA blocked and Claude re-stopped, hookB will also see `stop_hook_active: true`.

**Confidence**: HIGH for simulated harness. Live behavior expected to be identical since Claude Code uses the same fork+exec+pipe pattern.

---

### Q2: STOP_HOOK_ACTIVE env var propagation

**Finding**: `STOP_HOOK_ACTIVE` set inside hook process A does **NOT** propagate to sibling hook process B.

**Why**: Hook processes are independent subprocesses. Environment variable changes are private to the process that set them. Process B is spawned by Claude Code (not by process A), so it inherits Claude Code's environment, not A's modified environment.

**Critical implication**: Using only `STOP_HOOK_ACTIVE=1` as a guard is **insufficient** for sibling protection:
- hookA sets `STOP_HOOK_ACTIVE=1` before calling Claude
- hookB is spawned independently by Claude Code — it never sees hookA's env modification
- hookB can therefore proceed and also trigger a Claude call
- Result: both hooks fire simultaneously → potential race condition on `session.json`

**This is why `guard_stop_hook_file_marker()` exists** — it provides cross-process mutual exclusion via atomic filesystem operations, which ARE visible across sibling processes (Q3).

---

### Q3: File marker visibility between siblings

**Finding**: File system markers written by hookA **ARE** visible to hookB. The shared filesystem provides the communication channel that env vars cannot.

**Test result (5 runs)**: hookA wrote marker → hookB found it in 5/5 runs.

**Atomicity**: Use `mkdir` (not `touch` or `echo >`) for the marker creation. POSIX guarantees `mkdir` is atomic on local filesystems — exactly one caller wins the race; all others receive `EEXIST`.

```bash
# SAFE — atomic, exactly one winner
if mkdir "$LOCK_DIR" 2>/dev/null; then
    # won the lock
fi

# UNSAFE — race between test-and-create
if [[ ! -d "$LOCK_DIR" ]]; then
    mkdir "$LOCK_DIR"  # two processes can both pass the test before either creates
fi
```

---

### Q4: Race window between sibling invocations

**Finding**: In simulated sequential invocation, hookB is spawned after hookA completes — the "race window" is effectively zero (sequential, not concurrent).

**However**: Claude Code's actual invocation order is not officially documented. Two scenarios:

| Scenario | Race window | Guard needed |
|----------|-------------|--------------|
| Sequential (A completes before B spawns) | ~0ms | Env var guard sufficient |
| Parallel (A and B spawned simultaneously) | Real, milliseconds | **Atomic mkdir required** |

**Conservative recommendation**: Always use `guard_stop_hook_file_marker()` regardless of assumed ordering. The cost of the extra `mkdir` syscall is negligible (~1ms); the cost of a race condition is data corruption.

**Stale lock handling**: Always check for and clean up stale locks (PID dead or age > 30s) to prevent permanent lockout from a crashed hook process.

---

### Q5: Recommended idiom for safe multi-hook setups

#### Option A: Single orchestrator hook (preferred)

Instead of multiple sibling hooks, use ONE orchestrator hook that internally calls all actions:

```bash
# anya-stop-orchestrator.sh — the ONE Stop hook
source "$(dirname "$0")/../lib/stop_hook_lib.sh"

guard_stop_hook_active        # dead-loop prevention via stdin JSON field
# guard_stop_hook_file_marker "anya"  # add if orchestrator itself can be re-entered

# Call all sub-actions in sequence (no race, no sibling issues)
save_session_if_needed || emit_block_reason "Save session.json before stopping."
flush_learnings_if_needed || emit_block_reason "Flush learnings before stopping."

echo "{}"
```

**Advantages**: No cross-process coordination needed. One stdin read. One lock lifecycle.

#### Option B: Multiple sibling hooks with atomic lock (current approach)

Each hook uses `guard_stop_hook_file_marker()`:

```bash
# hook-save-session.sh
source "$(dirname "$0")/../lib/stop_hook_lib.sh"
guard_stop_hook_active

# Check if we are the "winner" — only one sibling should write session.json
if ! guard_stop_hook_file_marker "anya"; then
    # Another sibling is already handling this stop cycle
    echo "{}"
    exit 0
fi

# ... save session.json ...
```

**Guard semantics**:
1. `guard_stop_hook_active` — checks stdin `stop_hook_active` field + `STOP_HOOK_ACTIVE` env var
2. `guard_stop_hook_file_marker` — atomic mkdir for cross-process mutual exclusion

**Advantages**: Modular — each concern in its own file. Easy to add/remove hooks.

**Disadvantages**: Requires both guards in each hook. One hook "wins" and others silently skip — they don't get to do their own work if the lock is held.

---

## Contract Summary Table

| Property | Behavior | Confidence |
|----------|----------|------------|
| stdin delivery | Each sibling receives IDENTICAL JSON independently | HIGH (simulated + design) |
| stop_hook_active field | Both siblings see same value (true/false) | HIGH |
| STOP_HOOK_ACTIVE env var | Does NOT propagate between siblings | HIGH (OS process model) |
| File markers | Visible across siblings via shared filesystem | HIGH (verified 5/5 runs) |
| mkdir atomicity | Exactly one winner on local filesystem | HIGH (POSIX guarantee) |
| Invocation order | Sequential vs parallel: UNKNOWN | LOW — **needs live verification** |

---

## Live Verification Required

The simulated harness cannot answer:
1. Are Claude Code Stop hooks invoked **sequentially** or **in parallel**?
2. What is the actual **timing** between sibling spawns in production?
3. Does Claude Code set any additional env vars in hook processes?

### How to run the live test

1. Add both probe hooks to your bot's `settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "PROBE_ID=hookA PROBE_LOG=~/.claude-bots/logs/contract-test/live-stdin.log bash ~/.claude-bots/shared/hooks/tests/probes/probe-stdin.sh"
          },
          {
            "type": "command",
            "command": "PROBE_ID=hookB PROBE_LOG=~/.claude-bots/logs/contract-test/live-stdin.log bash ~/.claude-bots/shared/hooks/tests/probes/probe-stdin.sh"
          }
        ]
      }
    ]
  }
}
```

2. Start a Claude Code session and stop it: `/stop` or Ctrl+C

3. Read the log:
```bash
cat ~/.claude-bots/logs/contract-test/live-stdin.log | python3 -m json.tool
```

4. Compare `pid`, `ppid`, and timestamps to determine sequential vs parallel invocation.

---

## Related files

- `shared/hooks/lib/stop_hook_lib.sh` — guard functions implementation
- `shared/hooks/tests/test_stop_hook_contract.sh` — this contract's test harness
- `shared/hooks/tests/probes/` — probe hook scripts
- `shared/hooks/anya-stop-orchestrator.sh` — orchestrator pattern example
- `shared/mistakes.md` — past lessons learned
