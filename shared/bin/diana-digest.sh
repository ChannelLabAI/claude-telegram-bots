#!/usr/bin/env bash
# Diana PM structural-change digest. Sends only field names and redacted input references.
set -euo pipefail

PM_REPO="${DIANA_DIGEST_PM_REPO:-/home/oldrabbit/pm-hub}"
STATE_FILE="${DIANA_DIGEST_STATE:-/home/oldrabbit/.claude-bots/shared/state/diana-digest.json}"
TG_CHAT_ID="${DIANA_DIGEST_TG_CHAT_ID:-1050312492}"
AUTHOR="${DIANA_DIGEST_AUTHOR:-diana}"
SINCE="${DIANA_DIGEST_SINCE:-14 days ago}"
MODE="daily"
DRY_RUN=0

usage() { echo "usage: diana-digest.sh [--daily|--major-only] [--dry-run]" >&2; }
while (($#)); do
  case "$1" in
    --daily) MODE="daily" ;;
    --major-only) MODE="major" ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

for command_name in git python3 flock; do
  command -v "$command_name" >/dev/null || { echo "[diana-digest] missing command: $command_name" >&2; exit 2; }
done
git -C "$PM_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "[diana-digest] not a git repository: $PM_REPO" >&2
  exit 2
}

mkdir -p "$(dirname "$STATE_FILE")"
exec {state_lock_fd}>>"${STATE_FILE}.lock"
flock -x "$state_lock_fd"
message_file="$(mktemp)"
sha_file="$(mktemp)"
cleanup() { rm -f "$message_file" "$sha_file"; }
trap cleanup EXIT

python3 - "$PM_REPO" "$STATE_FILE" "$AUTHOR" "$SINCE" "$MODE" "$message_file" "$sha_file" <<'PY'
import difflib
import json
import re
import subprocess
import sys
from pathlib import Path

repo, state_path, author, since, mode, message_path, sha_path = sys.argv[1:]

def git(*args: str, check: bool = True) -> str:
    result = subprocess.run(["git", "-C", repo, *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout

def read_state() -> dict:
    path = Path(state_path)
    if not path.exists():
        return {"version": 1, "sent": {}}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"invalid state file {path}: {exc}") from exc
    if value.get("version") != 1 or not isinstance(value.get("sent"), dict):
        raise RuntimeError(f"unsupported state file {path}")
    return value

def show(commit: str, path: str) -> list[str]:
    return git("show", f"{commit}:{path}", check=False).splitlines()

def parent_show(commit: str, path: str) -> list[str]:
    return git("show", f"{commit}^:{path}", check=False).splitlines()

def yaml_path(lines: list[str], index: int) -> str:
    parents: list[tuple[int, str]] = []
    for line in lines[: index + 1]:
        match = re.match(r"^(\s*)([^#\s][^:]*):(?:\s|$)", line)
        if not match:
            continue
        indent = len(match.group(1).replace("\t", "  "))
        key = match.group(2).strip().strip("'\"")
        while parents and parents[-1][0] >= indent:
            parents.pop()
        parents.append((indent, key))
    return ".".join(key for _, key in parents) or "frontmatter"

def field_at(lines: list[str], index: int) -> str | None:
    if not lines:
        return None
    index = min(max(index, 0), len(lines) - 1)
    frontmatter_end = next((i for i, line in enumerate(lines[1:], 1) if line == "---"), -1)
    if frontmatter_end >= 0 and index < frontmatter_end:
        return yaml_path(lines, index)
    for pos in range(index, -1, -1):
        match = re.match(r"^##\s+(.+?)\s*$", lines[pos])
        if match:
            return match.group(1)
    return None

# Shared last-mile taxonomy for every Telegram-bound label and reference.
# Chinese terms are deliberately grouped and written as traditional/simplified
# pairs so an audit does not depend on spotting omissions in one long regex.
L3_TERMS = {
    "compensation": (
        "薪資", "薪资", "薪酬", "工資", "工资", "薪水", "底薪", "年薪",
        "月薪", "時薪", "时薪", "起薪", "加薪", "調薪", "调薪", "薪金", "獎金",
        "奖金", "紅利", "红利", "花紅", "花红", "分紅", "分红", "津貼",
        "津贴", "佣金", "提成", "salary", "payroll", "compensation", "bonus",
    ),
    "wallet": (
        "wallet", "錢包", "钱包", "私鑰", "私钥", "祕鑰", "祕钥", "秘鑰", "秘钥",
        "密鑰", "密钥", "助記詞", "助记词", "private key", "seed phrase",
        "recovery phrase", "mnemonic",
    ),
    "equity": (
        "股權", "股权", "持股", "股份", "股票", "認股", "认股", "乾股",
        "干股", "配股", "期權", "期权", "選擇權", "选择权", "stock option",
        "equity", "vesting", "解禁", "分潤", "分润",
    ),
}
L3_RE = re.compile(
    "|".join(re.escape(term) for terms in L3_TERMS.values() for term in terms),
    re.IGNORECASE,
)
# Do not use \b or \w lookarounds around fixed-format addresses or numeric tokens.
# Python treats CJK characters as word characters, so normal Chinese prose such
# as "帳戶0x1234567890abcdef餘額" or "進度25%達標" would otherwise bypass
# a Unicode-word boundary check.
WALLET_RE = re.compile(r"(?:0x[a-fA-F0-9]{8,}|[13][a-km-zA-HJ-NP-Z1-9]{20,}|bc1[a-zA-Z0-9]{20,})")
MONEY_RE = re.compile(r"(?:[$€£]\s*[0-9][0-9,]*(?:\.[0-9]+)?|[0-9][0-9,]*(?:\.[0-9]+)?\s*(?:%|USD|USDT|USDC|NTD|TWD|ETH|BTC))", re.IGNORECASE)

def input_reference(line: str) -> str:
    text = re.sub(r"^\s*[-*]?\s*\d{4}-\d{2}-\d{2}\s+\[整理\]\s*", "", line).strip()
    match = re.search(r"(?:依據|來源|input)\s*[:：]?\s*(.+)$", text, re.IGNORECASE)
    reference = (match.group(1) if match else text).strip()
    if L3_RE.search(reference) or WALLET_RE.search(reference):
        return "[L3 聚合輸入]"
    reference = WALLET_RE.sub("[敏感識別已隱去]", reference)
    reference = MONEY_RE.sub("[數值已聚合]", reference)
    return reference[:140] or "該專案 [整理] 日誌"

def safe_label(text: str, l3_replacement: str) -> str:
    # Key paths and headings are themselves L3 information: a personal identifier
    # combined with a sensitive category is detail even when no value is shown.
    # Therefore frontmatter keys, nested YAML paths, and ## headings must receive
    # the same L3 filtering as values before entering a Telegram-bound label.
    if L3_RE.search(text) or WALLET_RE.search(text):
        return l3_replacement
    return MONEY_RE.sub("[數值已聚合]", WALLET_RE.sub("[敏感識別已隱去]", text))[:160]

def project_name(lines: list[str], path: str) -> str:
    for line in lines[:80]:
        match = re.match(r"^name:\s*(.+?)\s*$", line)
        if match:
            return match.group(1).strip("'\"")
    return Path(path).stem

def trace_path(path: str) -> str:
    # The source filename is also Telegram-bound user-controlled metadata.
    # Keep the fixed projects/ location and Markdown suffix for traceability,
    # but apply the same last-mile filter to the arbitrary project slug.
    source = Path(path)
    return f"projects/{safe_label(source.stem, '[L3 專案路徑]')}.md"

def analyse(commit: str, subject: str) -> dict | None:
    paths = [p for p in git("diff-tree", "--no-commit-id", "--name-only", "-r", commit, "--", "projects/*.md").splitlines() if p]
    projects = []
    commit_major = bool(re.search(r"\[重大\]|(?:^|[ :(])major(?:[ :)!]|$)|重大變更", subject, re.IGNORECASE))
    for path in paths:
        old, new = parent_show(commit, path), show(commit, path)
        fields: set[str] = set()
        added整理: list[str] = []
        matcher = difflib.SequenceMatcher(a=old, b=new, autojunk=False)
        for tag, i1, i2, j1, j2 in matcher.get_opcodes():
            if tag == "equal":
                continue
            for line in new[j1:j2]:
                if "[整理]" in line:
                    added整理.append(line)
                if "[重大]" in line:
                    commit_major = True
            positions = list(range(j1, j2)) if j1 != j2 else [min(j1, max(len(new) - 1, 0))]
            for position in positions:
                source = new if new else old
                field = field_at(source, position)
                if field and field != "日誌":
                    fields.add(safe_label(field, "[L3 聚合欄位]"))
        if fields:
            references = list(dict.fromkeys(input_reference(line) for line in added整理))
            if not references:
                references = ["該專案 [整理] 日誌（未提供可安全轉述的輸入引用）"]
            projects.append({"name": safe_label(project_name(new or old, path), "[L3 專案]"), "path": trace_path(path), "fields": sorted(fields), "references": references})
    if not projects:
        return None
    return {"sha": commit, "subject": safe_label(subject, "[L3 結構更新]"), "major": commit_major, "projects": projects}

state = read_state()
sent = state["sent"]
log_lines = git("log", "--reverse", "--regexp-ignore-case", f"--author={author}", f"--since={since}", "--format=%H%x09%s", "--", "projects/*.md").splitlines()
entries = []
for line in log_lines:
    commit, _, subject = line.partition("\t")
    if not commit or commit in sent:
        continue
    entry = analyse(commit, subject)
    if entry and (mode != "major" or entry["major"]):
        entries.append(entry)

if not entries:
    Path(message_path).write_text("", encoding="utf-8")
    Path(sha_path).write_text("", encoding="utf-8")
    raise SystemExit(0)

headline = "🚨 Diana 結構區重大變更" if mode == "major" else "📋 Diana 結構區更新摘要"
out = [headline, f"共 {len(entries)} 筆 commit（事後知會，不是審批）"]
for entry in entries:
    out.extend(["", f"• {entry['sha'][:12]} {entry['subject']}"])
    for project in entry["projects"]:
        out.append(f"  專案：{project['name']}")
        out.append(f"  欄位：{', '.join(project['fields'])}")
        out.append(f"  依據：{'；'.join(project['references'])}")
        out.append(f"  回溯：{project['path']}#日誌 · commit {entry['sha']}")
Path(message_path).write_text("\n".join(out).strip() + "\n", encoding="utf-8")
Path(sha_path).write_text("\n".join(entry["sha"] for entry in entries) + "\n", encoding="utf-8")
PY

if [[ ! -s "$message_file" ]]; then
  echo "[diana-digest] no unsent structural changes ($MODE)" >&2
  exit 0
fi
if ((DRY_RUN)); then
  cat "$message_file"
  exit 0
fi

if [[ -n "${DIANA_DIGEST_SEND_CMD:-}" ]]; then
  [[ -x "$DIANA_DIGEST_SEND_CMD" ]] || { echo "[diana-digest] sender is not executable" >&2; exit 2; }
  "$DIANA_DIGEST_SEND_CMD" "$message_file"
else
  python3 - "$TG_CHAT_ID" "$message_file" <<'PY'
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request

chat_id, message_path = sys.argv[1:]
token = os.environ.get("DIANA_DIGEST_TG_TOKEN", "").strip()
if not token:
    result = subprocess.run(["gcloud", "secrets", "versions", "access", "latest", "--secret=tg-token-diana", "--project=channellab-prod"], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    token = result.stdout.strip() if result.returncode == 0 else ""
if not token:
    raise SystemExit("[diana-digest] Diana TG token unavailable")
text = open(message_path, encoding="utf-8").read()
chunks = []
while text:
    if len(text) <= 3900:
        chunks.append(text)
        break
    split_at = text.rfind("\n", 0, 3900)
    if split_at < 1:
        split_at = 3900
    chunks.append(text[:split_at])
    text = text[split_at:].lstrip("\n")
for index, chunk in enumerate(chunks, 1):
    if len(chunks) > 1:
        chunk = f"[{index}/{len(chunks)}] {chunk}"
    body = urllib.parse.urlencode({"chat_id": chat_id, "text": chunk}).encode()
    request = urllib.request.Request(f"https://api.telegram.org/bot{token}/sendMessage", data=body, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.load(response)
    except Exception as exc:
        raise SystemExit(f"[diana-digest] TG send failed at chunk {index}: {type(exc).__name__}") from exc
    if payload.get("ok") is not True:
        raise SystemExit(f"[diana-digest] TG send returned ok=false at chunk {index}")
PY
fi

python3 - "$STATE_FILE" "$MODE" "$sha_file" <<'PY'
import datetime as dt
import json
import os
import sys
from pathlib import Path

state_path, mode, sha_path = sys.argv[1:]
path = Path(state_path)
state = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {"version": 1, "sent": {}}
now = dt.datetime.now(dt.timezone.utc).isoformat()
for sha in Path(sha_path).read_text(encoding="utf-8").splitlines():
    if sha:
        state["sent"][sha] = {"sent_at": now, "mode": mode}
state["sent"] = dict(list(state["sent"].items())[-500:])
state["updated_at"] = now
tmp = path.with_name(f"{path.name}.tmp.{os.getpid()}")
tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
os.replace(tmp, path)
PY
echo "[diana-digest] sent $(wc -l < "$sha_file" | tr -d ' ') commit(s) ($MODE)" >&2
