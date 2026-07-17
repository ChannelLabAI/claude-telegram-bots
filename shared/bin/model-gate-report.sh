#!/usr/bin/env bash
set -euo pipefail

ROOT="${MODEL_GATE_ROOT:-/home/oldrabbit/.claude-bots}"
BOT=""
BASELINE_FROM=""
BASELINE_TO=""
TREATMENT_FROM=""
TREATMENT_TO=""

usage() {
  echo "Usage: model-gate-report.sh --bot <name> --baseline-from <date> --baseline-to <date> --treatment-from <date> [--treatment-to <date>]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bot) BOT="${2:-}"; shift 2 ;;
    --baseline-from) BASELINE_FROM="${2:-}"; shift 2 ;;
    --baseline-to) BASELINE_TO="${2:-}"; shift 2 ;;
    --treatment-from) TREATMENT_FROM="${2:-}"; shift 2 ;;
    --treatment-to) TREATMENT_TO="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

[[ -n "$BOT" && -n "$BASELINE_FROM" && -n "$BASELINE_TO" && -n "$TREATMENT_FROM" ]] || usage

python3 - "$ROOT" "$BOT" "$BASELINE_FROM" "$BASELINE_TO" "$TREATMENT_FROM" "$TREATMENT_TO" <<'PY'
import json
import statistics
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(sys.argv[1])
BOT = sys.argv[2]
BASELINE_FROM = sys.argv[3]
BASELINE_TO = sys.argv[4]
TREATMENT_FROM = sys.argv[5]
TREATMENT_TO = sys.argv[6] or None
MIN_TREATMENT_TASKS = 25

def parse_date(value, end=False):
    dt = datetime.fromisoformat(value)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone(timedelta(hours=8)))
    if len(value) == 10:
        if end:
            dt = dt.replace(hour=23, minute=59, second=59, microsecond=999999)
        else:
            dt = dt.replace(hour=0, minute=0, second=0, microsecond=0)
    return dt

def parse_ts(value):
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        text = value.strip().replace("Z", "+00:00")
        dt = datetime.fromisoformat(text)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone(timedelta(hours=8)))
        return dt
    except Exception:
        return None

def norm_bot(value):
    return str(value or "").strip().lower()

def safe_load(path):
    try:
        with path.open(encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict) or not isinstance(data.get("history"), list):
            return None
        return data
    except Exception:
        return None

def task_bot(data):
    for key in ("assigned", "assigned_to", "assignee"):
        if data.get(key):
            return norm_bot(data.get(key))
    return ""

def action(entry):
    if not isinstance(entry, dict):
        return ""
    return str(entry.get("action") or entry.get("status") or entry.get("state") or "").lower()

def entry_ts(entry):
    if not isinstance(entry, dict):
        return None
    return parse_ts(entry.get("ts") or entry.get("at") or entry.get("time"))

def terminal_ts(history):
    terminal = None
    for h in history:
        a = action(h)
        if "verdict_approve" in a or "verdict_reject" in a or a in {"done", "reject", "rejected"}:
            terminal = entry_ts(h) or terminal
        elif a == "review":
            terminal = entry_ts(h) or terminal
    return terminal

def claim_ts(history):
    for h in history:
        a = action(h)
        if "claim" in a or a == "in_progress":
            ts = entry_ts(h)
            if ts:
                return ts
    return None

def reject_entries(history):
    out = []
    for h in history:
        if not isinstance(h, dict):
            continue
        a = action(h)
        if "verdict_reject" in a or a == "reject" or a == "rejected":
            out.append(h)
    return out

def issue_type(entry):
    value = entry.get("issue_type")
    if value:
        return str(value)
    return "execution_error"

def iter_tasks():
    for state in ("done", "rejected"):
        d = ROOT / "tasks" / state
        if not d.is_dir():
            continue
        for path in sorted(d.glob("*.json")):
            data = safe_load(path)
            if data is None:
                continue
            if task_bot(data) != norm_bot(BOT):
                continue
            history = data.get("history", [])
            end = terminal_ts(history) or parse_ts(data.get("updated_at")) or parse_ts(data.get("created_at"))
            start = claim_ts(history) or parse_ts(data.get("created_at"))
            if not end:
                continue
            yield {
                "path": path,
                "state": state,
                "data": data,
                "start": start,
                "end": end,
                "rejects": reject_entries(history),
            }

baseline_from = parse_date(BASELINE_FROM)
baseline_to = parse_date(BASELINE_TO, end=True)
treatment_from = parse_date(TREATMENT_FROM)
requested_treatment_to = parse_date(TREATMENT_TO, end=True) if TREATMENT_TO else None
default_treatment_to = treatment_from + timedelta(days=14) - timedelta(microseconds=1)
max_treatment_to = treatment_from + timedelta(days=28) - timedelta(microseconds=1)

all_tasks = list(iter_tasks())
baseline_tasks = [t for t in all_tasks if baseline_from <= t["end"] <= baseline_to]
treatment_candidates = [t for t in all_tasks if t["end"] >= treatment_from]
treatment_candidates.sort(key=lambda t: t["end"])
if requested_treatment_to:
    treatment_to = requested_treatment_to
else:
    treatment_to = default_treatment_to
    if sum(1 for t in treatment_candidates if t["end"] <= treatment_to) < MIN_TREATMENT_TASKS:
        if len(treatment_candidates) >= MIN_TREATMENT_TASKS:
            treatment_to = min(treatment_candidates[MIN_TREATMENT_TASKS - 1]["end"], max_treatment_to)
        else:
            treatment_to = max_treatment_to
treatment_tasks = [t for t in treatment_candidates if t["end"] <= treatment_to]

def median(values):
    return statistics.median(values) if values else None

def pct(value):
    return "n/a" if value is None else f"{value * 100:.1f}%"

def num(value):
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.2f}"
    return str(value)

def summarize(tasks):
    rejects = [len(t["rejects"]) for t in tasks]
    total_rejects = sum(rejects)
    issue_counts = Counter()
    missing_issue = 0
    wall_hours = []
    escalations = 0
    for t in tasks:
        for r in t["rejects"]:
            if not r.get("issue_type"):
                missing_issue += 1
            issue_counts[issue_type(r)] += 1
        if t["start"] and t["end"] and t["end"] >= t["start"]:
            wall_hours.append((t["end"] - t["start"]).total_seconds() / 3600)
        if len(t["rejects"]) > 3:
            escalations += 1
    n = len(tasks)
    return {
        "tasks": n,
        "first_pass_rate": (sum(1 for r in rejects if r == 0) / n) if n else None,
        "avg_rework": (sum(rejects) / n) if n else None,
        "rejects": total_rejects,
        "issue_counts": issue_counts,
        "issue_missing_rate": (missing_issue / total_rejects) if total_rejects else 0.0,
        "median_wall_hours": median(wall_hours),
        "escalations": escalations,
    }

def usage_rows():
    path = ROOT / "logs" / "usage.jsonl"
    if not path.exists():
        return []
    rows = []
    with path.open(encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                row = json.loads(line)
            except Exception:
                continue
            if norm_bot(row.get("bot")) != norm_bot(BOT):
                continue
            ts = parse_ts(row.get("ts") or row.get("timestamp") or row.get("created_at"))
            if not ts:
                continue
            rows.append((ts, row))
    return rows

def token_total(row):
    direct = row.get("total_tokens")
    if isinstance(direct, (int, float)):
        return int(direct)
    total = 0
    for key in ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "cache_tokens"):
        value = row.get(key)
        if isinstance(value, (int, float)):
            total += int(value)
    tokens = row.get("tokens")
    if isinstance(tokens, dict):
        for key in ("input", "output", "cache", "cache_creation_input", "cache_read_input"):
            value = tokens.get(key)
            if isinstance(value, (int, float)):
                total += int(value)
    return total

def rate_limit(row):
    value = row.get("rate_limit_events", 0)
    return int(value) if isinstance(value, (int, float)) else 0

usage = usage_rows()

def usage_summary(start, end, tasks):
    rows = [(ts, row) for ts, row in usage if start <= ts <= end]
    rate = sum(rate_limit(row) for _, row in rows)
    per_session = defaultdict(list)
    for ts, row in rows:
        sid = str(row.get("session_id") or row.get("session") or "unknown")
        per_session[sid].append((ts, token_total(row)))
    total_delta = 0
    for sid, vals in per_session.items():
        vals.sort()
        prev = None
        for _, total in vals:
            if prev is None:
                delta = max(total, 0)
            else:
                delta = max(total - prev, 0)
            total_delta += delta
            prev = total
    max_parallel = 0
    for t in tasks:
        if not t["start"] or not t["end"]:
            continue
        concurrent = 0
        for other in tasks:
            if other is t or not other["start"] or not other["end"]:
                continue
            if other["start"] <= t["end"] and t["start"] <= other["end"]:
                concurrent += 1
        max_parallel = max(max_parallel, concurrent)
    return {"rate_limit_events": rate, "approx_tokens": total_delta, "max_parallel_tasks": max_parallel}

baseline = summarize(baseline_tasks)
treatment = summarize(treatment_tasks)
baseline_usage = usage_summary(baseline_from, baseline_to, baseline_tasks)
treatment_usage = usage_summary(treatment_from, treatment_to, treatment_tasks)

def split_windows(tasks):
    if not tasks:
        return [], []
    ordered = sorted(tasks, key=lambda t: t["end"])
    midpoint = max(1, len(ordered) // 2)
    return ordered[:midpoint], ordered[midpoint:]

def trigger_states(rule):
    if treatment["tasks"] < MIN_TREATMENT_TASKS:
        return "INSUFFICIENT_DATA", ["INSUFFICIENT_DATA", "INSUFFICIENT_DATA"]
    windows = split_windows(treatment_tasks)
    states = []
    for window in windows:
        ws = summarize(window)
        wu = usage_summary(min((t["end"] for t in window), default=treatment_from), max((t["end"] for t in window), default=treatment_from), window)
        trig = False
        if rule == "R1" and baseline["first_pass_rate"] is not None and ws["first_pass_rate"] is not None:
            trig = (baseline["first_pass_rate"] - ws["first_pass_rate"]) > 0.15
        elif rule == "R2" and baseline_usage["approx_tokens"] and wu["approx_tokens"]:
            trig = wu["approx_tokens"] > baseline_usage["approx_tokens"]
        elif rule == "R3" and baseline["median_wall_hours"] and ws["median_wall_hours"]:
            trig = ws["median_wall_hours"] > baseline["median_wall_hours"] * 1.5
        elif rule == "R4":
            trig = ws["escalations"] > baseline["escalations"]
        states.append("TRIGGER" if trig else "PASS")
    while len(states) < 2:
        states.append("PASS")
    if states[0] == "TRIGGER" and states[1] == "TRIGGER":
        return "FAIL", states
    if "TRIGGER" in states:
        return "WARNING(1/2)", states
    return "PASS", states

print(f"# Model Gate Report: {BOT}")
print()
print(f"Baseline: {BASELINE_FROM}..{BASELINE_TO}")
print(f"Treatment: {TREATMENT_FROM}..{treatment_to.date().isoformat()}")
print(f"Data threshold: treatment done+rejected >= {MIN_TREATMENT_TASKS}")
print(f"Overall conclusion: {'INSUFFICIENT_DATA' if treatment['tasks'] < MIN_TREATMENT_TASKS else 'EVALUATED'}")
print()
print("## M1/M2/M3/M5 Comparison")
print()
print("| metric | baseline | treatment |")
print("|---|---:|---:|")
print(f"| terminal tasks | {baseline['tasks']} | {treatment['tasks']} |")
print(f"| M1 avg rework rounds | {num(baseline['avg_rework'])} | {num(treatment['avg_rework'])} |")
print(f"| first-pass rate | {pct(baseline['first_pass_rate'])} | {pct(treatment['first_pass_rate'])} |")
print(f"| M2 reject rounds | {baseline['rejects']} | {treatment['rejects']} |")
print(f"| M2 missing issue_type rate | {pct(baseline['issue_missing_rate'])} | {pct(treatment['issue_missing_rate'])} |")
print(f"| M3 median wall-clock hours | {num(baseline['median_wall_hours'])} | {num(treatment['median_wall_hours'])} |")
print(f"| M5 rate_limit_events | {baseline_usage['rate_limit_events']} | {treatment_usage['rate_limit_events']} |")
print()
print("## M2 Issue Types")
print()
all_issues = sorted(set(baseline["issue_counts"]) | set(treatment["issue_counts"]))
if not all_issues:
    print("No reject issue_type data in selected windows.")
else:
    print("| issue_type | baseline | treatment |")
    print("|---|---:|---:|")
    for issue in all_issues:
        print(f"| {issue} | {baseline['issue_counts'][issue]} | {treatment['issue_counts'][issue]} |")
print()
print("## M4 Approximate Token Signal")
print()
print("M4 is approximate: usage rows have no task_id. Token deltas are counted by bot/session snapshots inside the observation window. Concurrent same-bot tasks can over-count.")
print()
print("| window | approx_token_delta | max_parallel_same_bot_tasks |")
print("|---|---:|---:|")
print(f"| baseline | {baseline_usage['approx_tokens']} | {baseline_usage['max_parallel_tasks']} |")
print(f"| treatment | {treatment_usage['approx_tokens']} | {treatment_usage['max_parallel_tasks']} |")
print()
print("## Rollback Gate")
print()
print("| rule | result | window 1 | window 2 |")
print("|---|---|---|---|")
for rule in ("R1", "R2", "R3", "R4"):
    result, states = trigger_states(rule)
    print(f"| {rule} | {result} | {states[0]} | {states[1]} |")
PY
