---
triggers: ["長任務", "long task", "setsid", "manifest", "長時間測試", "submit", "verify"]
description: "Long-task keepalive v1: detach from the caller session, publish a heartbeat manifest, and preserve the restart hard fuse"
---

# Block: Long-task keepalive v1

This is the stopgap layer for commands that must not die merely because a
headless worker turn, terminal, or process group ends. It does not implement
journal/resume, and it does not make work survive a host crash.

## When this is mandatory

Use the detached pattern below for either:

1. a submit/verify/clone/forensics operation whose result must outlive the
   initiating worker turn; or
2. any test, clone, build, or investigation expected to run longer than five
   minutes.

Ordinary quick commands should stay foregrounded. Detached work is not a way to
bypass FATQ ownership, review, verification, or the hard restart deadline.

## Three-part contract

Every detached long task must do all three:

1. start in a new session with `setsid`, with stdin disconnected and stdout plus
   stderr written to a durable log;
2. register a manifest before the real operation begins, and refresh
   `heartbeat_ts` periodically while it is healthy;
3. clear the manifest on every normal or trapped exit.

`setsid` separates the command from the caller's session and process group. It
does **not** move the process out of a systemd cgroup. The manifest is therefore
the companion signal that makes `a9e4-safe-restart.sh` defer a pod restart.
Neither mechanism survives a host crash; execution journal/resume remains W1.5.

## Safe template

Replace the uppercase values. Keep the wrapper itself inside `setsid` so
registration, heartbeat, cleanup, and the command share the detached lifetime.

```bash
setsid bash -c '
  set -uo pipefail
  helper=/home/oldrabbit/.claude-bots/shared/bin/long-task-manifest.sh
  task_id="$1"; owner="$2"; pod="$3"; expected="$4"; desc="$5"; shift 5
  cleanup() {
    [[ -n "${heartbeat_pid:-}" ]] && kill "$heartbeat_pid" 2>/dev/null || true
    "$helper" clear --id "$task_id" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT
  trap "exit 130" INT
  trap "exit 143" TERM
  trap "exit 129" HUP
  "$helper" register --id "$task_id" --owner-bot "$owner" --pod "$pod" \
    --pid "$$" --pgid "$(ps -o pgid= -p "$$" | tr -d " ")" \
    --expected-duration "$expected" --desc "$desc"
  while sleep 60; do
    "$helper" heartbeat --id "$task_id" >/dev/null || exit 70
  done &
  heartbeat_pid=$!
  "$@"
' long-task-wrapper TASK_ID OWNER_BOT POD EXPECTED_SECONDS DESCRIPTION \
  COMMAND ARG... </dev/null >>/absolute/path/to/task.log 2>&1 &
launcher_pid=$!
```

The command must be argumentized after `--`/positional parameters as shown; do
not interpolate untrusted command text into the shell program. Record the task
ID, log path, and launcher PID in the FATQ comment or working notes.

## Manifest format and freshness

The helper writes one atomic JSON file per task under
`shared/state/long-tasks/`:

```json
{
  "schema_version": 1,
  "id": "task-id",
  "owner_bot": "anna",
  "pod": "builder",
  "pid": 1234,
  "pgid": 1234,
  "started_at": "2026-07-26T10:00:00Z",
  "expected_duration": 1800,
  "desc": "fresh-clone verification",
  "heartbeat_ts": "2026-07-26T10:01:00Z"
}
```

Freshness is computed only from the recorded `heartbeat_ts`. File mtime is not
evidence of liveness. Malformed matching manifests fail closed and block an
early restart; the 60-minute a9e4 deadline still forces the restart and logs
the manifests it sacrifices.

## Helper operations

```bash
shared/bin/long-task-manifest.sh --help
shared/bin/long-task-manifest.sh heartbeat --id TASK_ID
shared/bin/long-task-manifest.sh clear --id TASK_ID
shared/bin/long-task-manifest.sh list-active --pod builder --stale-after 300
```

All writes use a same-directory temporary file and atomic rename. IDs, bot/pod
names, PIDs, durations, and JSON schemas are validated fail-closed.

## Relationship to task dispatch discipline

This block extends, but never replaces, [[block-task-queue]] §11/FATQ dispatch
discipline: claim first, keep work scoped to the assigned bot, preserve
verification evidence, and submit through `fatq-cli.sh`. Detaching a command
does not detach accountability. If the worker turn ends, the manifest and
durable log are the handoff needed to resume observation safely.
