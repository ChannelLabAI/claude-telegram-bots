#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAKE="$WORK/fake"
mkdir -p "$FAKE" "$WORK/root"/{mvp,pod-system/pods-db,tasks,infra,logs} "$WORK/tmp" "$WORK/remote"
touch "$WORK/root/memory.db" "$WORK/root/mvp/users.db" "$WORK/root/kg.db" "$WORK/root/pod-system/pods-db/a.db"

cat > "$FAKE/sqlite3" <<'EOF'
#!/usr/bin/env bash
target=$(sed -n "s/.*\.backup '\(.*\)'/\1/p" <<< "$2")
touch "$target"
EOF
cat > "$FAKE/git" <<'EOF'
#!/usr/bin/env bash
touch "$5"
EOF
cat > "$FAKE/tar" <<'EOF'
#!/usr/bin/env bash
touch "$3"
case "${TAR_MODE:-ok}" in warning) exit 1;; fatal) exit 2;; esac
EOF
cat > "$FAKE/gcloud" <<'EOF'
#!/usr/bin/env bash
set -eu
if [[ "$1" == secrets ]]; then
  [[ "${GCLOUD_MODE:-ok}" == secret_hang ]] && sleep 60
  echo token
  exit 0
fi
if [[ "$1 $2 $3" == "storage cp -r" ]]; then
  [[ "${GCLOUD_MODE:-ok}" == upload_fail ]] && exit 9
  touch "$REMOTE/$(basename "${5%/}").uploaded"
  exit 0
fi
if [[ "$1 $2" == "storage ls" ]]; then
  day=$(sed -n 's#.*backup/\([0-9]\{8\}\)/.*#\1#p' <<< "$3")
  [[ "$day" == "${MISSING_DAY:-}" ]] && exit 1
  echo "gs://fixture/$day/object"
  exit 0
fi
exit 0
EOF
cat > "$FAKE/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_RECORD"
EOF
chmod +x "$FAKE"/*

run_backup() {
  env BACKUP_ROOT="$WORK/root" BACKUP_TMP_ROOT="$WORK/tmp" BACKUP_LOG="$WORK/root/logs/backup.log" \
    BACKUP_DAY=20260808 SQLITE3_BIN="$FAKE/sqlite3" TAR_BIN="$FAKE/tar" GIT_BIN="$FAKE/git" \
    GCLOUD_BIN="$FAKE/gcloud" CURL_BIN="$FAKE/curl" REMOTE="$WORK/remote" CURL_RECORD="$WORK/curl.log" \
    "$ROOT_DIR/scripts/offsite-backup.sh"
}

if ! TAR_MODE=warning run_backup; then
  cat "$WORK/root/logs/backup.log" >&2
  exit 1
fi
test -f "$WORK/remote/20260808.uploaded"
test ! -e "$WORK/tmp/pod-backup-20260808"
grep -q 'tasks changed while tar was reading' "$WORK/root/logs/backup.log"

if GCLOUD_MODE=upload_fail run_backup; then echo 'expected upload failure' >&2; exit 1; fi
test ! -e "$WORK/tmp/pod-backup-20260808"
grep -q 'stage=upload' "$WORK/root/logs/backup.log"
grep -q 'offsite-backup' "$WORK/curl.log"

if TAR_MODE=fatal run_backup; then echo 'expected tar failure' >&2; exit 1; fi
test ! -e "$WORK/tmp/pod-backup-20260808"
grep -q 'stage=tar tasks' "$WORK/root/logs/backup.log"

# A stuck token lookup must time out, then let the EXIT trap clean up.
start=$SECONDS
if TAR_MODE=fatal GCLOUD_MODE=secret_hang run_backup; then echo 'expected fatal tar failure' >&2; exit 1; fi
elapsed=$((SECONDS - start))
[[ "$elapsed" -ge 10 && "$elapsed" -lt 15 ]]
test ! -e "$WORK/tmp/pod-backup-20260808"

run_health() {
  env BACKUP_HEALTH_LOG="$WORK/root/logs/health.log" BACKUP_HEALTH_DAY=20260808 \
    GCLOUD_BIN="$FAKE/gcloud" CURL_BIN="$FAKE/curl" REMOTE="$WORK/remote" CURL_RECORD="$WORK/curl.log" \
    "$ROOT_DIR/shared/tests/offsite-backup-health.sh"
}
if MISSING_DAY=20260804 run_health; then echo 'expected health failure' >&2; exit 1; fi
grep -q '20260804' "$WORK/root/logs/health.log"
run_health
grep -q 'coverage complete' "$WORK/root/logs/health.log"

start=$SECONDS
if MISSING_DAY=20260804 GCLOUD_MODE=secret_hang run_health; then echo 'expected health failure' >&2; exit 1; fi
elapsed=$((SECONDS - start))
[[ "$elapsed" -ge 10 && "$elapsed" -lt 15 ]]

# Alert transport must be bounded: both scripts guard their token lookup and
# Telegram request so an EXIT trap cannot leave temporary backups behind.
grep -Fq 'timeout 10 "$GCLOUD_BIN" secrets versions access' "$ROOT_DIR/scripts/offsite-backup.sh"
grep -Fq '"$CURL_BIN" -sf --max-time 10 -X POST' "$ROOT_DIR/scripts/offsite-backup.sh"
grep -Fq 'timeout 10 "$GCLOUD_BIN" secrets versions access' "$ROOT_DIR/shared/tests/offsite-backup-health.sh"
grep -Fq '"$CURL_BIN" -sf --max-time 10 -X POST' "$ROOT_DIR/shared/tests/offsite-backup-health.sh"

echo 'PASS: tar warning, fatal upload/tar alert+cleanup, health red/green coverage, bounded alert transport'
