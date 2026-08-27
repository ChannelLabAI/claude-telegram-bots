#!/usr/bin/env bash
# Verify resident relay identity coverage and prove the patched consumer is loaded.
set -euo pipefail

ROOT="${RELAY_IDENTITY_ROOT:-/home/oldrabbit/.claude-bots}"
CONFIG="${RELAY_IDENTITY_CONFIG:-$ROOT/shared/config/relay-consumed-readers.json}"
SERVER="${RELAY_IDENTITY_SERVER:-$ROOT/shared/server.patched.ts}"
SNAPSHOT="${RELAY_IDENTITY_PROCESS_SNAPSHOT:-}"

for command_name in python3 stat; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "ERROR missing-command=$command_name" >&2
    exit 2
  }
done
[[ -r "$CONFIG" ]] || { echo "ERROR identity-config-missing=$CONFIG" >&2; exit 2; }
[[ -r "$SERVER" ]] || { echo "ERROR server-missing=$SERVER" >&2; exit 2; }

tmp_snapshot=""
if [[ -z "$SNAPSHOT" ]]; then
  tmp_snapshot="$(mktemp)"
  trap 'rm -f "$tmp_snapshot"' EXIT
  SNAPSHOT="$tmp_snapshot"
  python3 - "$SNAPSHOT" "$CONFIG" <<'PYTHON'
import json, os, pathlib, sys

proc = pathlib.Path('/proc')
config = json.load(open(sys.argv[2], encoding='utf-8'))
resident_directories = {str(value).lower() for value in config.get('resident_directories', [])}
try:
    btime = next(int(line.split()[1]) for line in (proc / 'stat').read_text().splitlines() if line.startswith('btime '))
    ticks = os.sysconf('SC_CLK_TCK')
except Exception as exc:
    raise SystemExit(f'ERROR proc-clock-read-failed={exc}')

rows = []
for entry in proc.iterdir():
    if not entry.name.isdigit():
        continue
    try:
        cmdline = (entry / 'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace').strip()
        if 'claude' not in cmdline.lower():
            continue
        env = {}
        for item in (entry / 'environ').read_bytes().split(b'\0'):
            if b'=' in item:
                key, value = item.split(b'=', 1)
                env[key.decode(errors='ignore')] = value.decode(errors='replace')
        state_dir = env.get('TELEGRAM_STATE_DIR', '').rstrip('/')
        if not state_dir:
            continue
        directory = pathlib.Path(state_dir).name
        if directory.lower() not in resident_directories:
            continue
        stat_tail = (entry / 'stat').read_text().rsplit(')', 1)[1].split()
        start_epoch = btime + int(stat_tail[19]) / ticks
        rows.append({
            'directory': directory,
            'pid': int(entry.name),
            'start_epoch': start_epoch,
            'command': cmdline,
        })
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        continue
json.dump(rows, open(sys.argv[1], 'w'), ensure_ascii=False)
PYTHON
fi
[[ -r "$SNAPSHOT" ]] || { echo "ERROR process-snapshot-missing=$SNAPSHOT" >&2; exit 2; }

server_mtime="$(stat -c %Y "$SERVER")"
python3 - "$CONFIG" "$SNAPSHOT" "$server_mtime" <<'PYTHON'
import json, sys

config_path, snapshot_path, server_mtime_raw = sys.argv[1:]
server_mtime = float(server_mtime_raw)
errors = []

try:
    config = json.load(open(config_path, encoding='utf-8'))
except Exception as exc:
    raise SystemExit(f'ERROR identity-config-invalid={exc}')
readers = config.get('readers')
if not isinstance(readers, list) or not readers:
    raise SystemExit('ERROR identity-config-invalid=readers-must-be-nonempty-array')
resident_directories = {
    str(value).strip().lower() for value in config.get('resident_directories', [])
    if str(value).strip()
}
if not resident_directories:
    raise SystemExit('ERROR identity-config-invalid=resident-directories-must-be-nonempty-array')

required = ('directory', 'system_identity', 'roster_id', 'dispatch_key', 'tg_username')
directories = set()
alias_owners = {}
for index, row in enumerate(readers):
    if not isinstance(row, dict):
        errors.append(f'identity-row-invalid index={index}')
        continue
    directory = str(row.get('directory', '')).strip()
    if directory:
        directories.add(directory.lower())
    aliases_raw = row.get('aliases')
    aliases = {
        str(value).lstrip('@').strip().lower()
        for value in aliases_raw
        if str(value).strip()
    } if isinstance(aliases_raw, list) else set()
    for key in required:
        value = str(row.get(key, '')).lstrip('@').strip()
        if not value:
            errors.append(f'identity-key-missing directory={directory or "<unknown>"} key={key}')
        elif value.lower() not in aliases:
            errors.append(f'alias-missing directory={directory or "<unknown>"} key={key} value={value}')
    for alias in aliases:
        owner = alias_owners.setdefault(alias, directory.lower())
        if owner != directory.lower():
            errors.append(f'alias-ambiguous alias={alias} directories={owner},{directory.lower()}')
for directory in sorted(resident_directories - directories):
    errors.append(f'resident-identity-missing directory={directory}')
for directory in sorted(directories - resident_directories):
    errors.append(f'identity-not-resident directory={directory}')

try:
    processes = json.load(open(snapshot_path, encoding='utf-8'))
except Exception as exc:
    raise SystemExit(f'ERROR process-snapshot-invalid={exc}')
if not isinstance(processes, list):
    raise SystemExit('ERROR process-snapshot-invalid=expected-array')

seen = set()
for process in processes:
    if not isinstance(process, dict):
        errors.append('process-row-invalid')
        continue
    directory = str(process.get('directory', '')).lower()
    pid = process.get('pid', '<unknown>')
    try:
        started = float(process.get('start_epoch'))
    except (TypeError, ValueError):
        errors.append(f'process-start-invalid directory={directory or "<unknown>"} pid={pid}')
        continue
    if directory not in directories:
        errors.append(f'resident-process-unmapped directory={directory or "<unknown>"} pid={pid}')
        continue
    seen.add(directory)
    if started <= server_mtime:
        errors.append(
            f'process-stale directory={directory} pid={pid} start_epoch={started:.3f} '
            f'server_mtime={server_mtime:.3f}'
        )
for directory in sorted(directories - seen):
    errors.append(f'resident-process-missing directory={directory}')

if errors:
    for error in errors:
        print(f'FAIL {error}')
    raise SystemExit(1)
print(f'PASS identity-alias-coverage readers={len(readers)}')
print(f'PASS resident-process-freshness processes={len(processes)} server_mtime={server_mtime:.3f}')
PYTHON
