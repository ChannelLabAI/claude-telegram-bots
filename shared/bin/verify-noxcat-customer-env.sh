#!/usr/bin/env bash
# Host-only acceptance run. Execute only after Bella approval and both ba17
# patches have been applied. This intentionally provisions, uninstalls, and
# reprovisions the NOXCAT customer unit; Anna's builder sandbox must not run it.
set -euo pipefail

: "${NOXCAT_ALLOWED_EMAILS:?set NOXCAT_ALLOWED_EMAILS to the approved comma-separated allowlist}"

PROVISION_BIN="${PROVISION_BIN:-/home/oldrabbit/.claude-bots/shared/bin/provision-customer-env.sh}"
NOXCAT_PORT="${NOXCAT_PORT:-8091}"
NOXCAT_DATA_DIR="${NOXCAT_DATA_DIR:-/home/oldrabbit/.claude-bots/customers/noxcat/mvp-data}"
NOXCAT_VAULT_ROOT="${NOXCAT_VAULT_ROOT:-/home/oldrabbit/Documents/Obsidian Vault/Ocean/業務流/NOXCAT}"
MVP_CODE_DIR="${MVP_CODE_DIR:-/home/oldrabbit/.claude-bots/mvp}"
PROD_UNIT="mvp-server.service"
CUSTOMER_UNIT="mvp-customer-noxcat.service"
CUSTOMER_CONFIG_ROOT="${PROVISION_CONFIG_ROOT:-${XDG_CONFIG_HOME:-$HOME/.config}/channellab/customers}"
NOXCAT_ENV_FILE="$CUSTOMER_CONFIG_ROOT/noxcat.env"
PRODUCTION_SIGNAL_REGISTRY="${PRODUCTION_SIGNAL_REGISTRY:-/home/oldrabbit/.claude-bots/state/signal-registry.json}"

pid_of() { systemctl --user show "$1" -p MainPID --value; }
show_listener() {
  local port="$1" output
  output="$(ss -H -ltnp "sport = :$port")"
  [[ -n "$output" ]] || { echo "no listener on port $port" >&2; exit 1; }
  printf 'LISTENER_%s=%s\n' "$port" "$output"
}
show_8090() { show_listener 8090; }
show_customer_port() { show_listener "$NOXCAT_PORT"; }
customer_args=(
  --target local
  --customer NOXCAT
  --port "$NOXCAT_PORT"
  --emails "$NOXCAT_ALLOWED_EMAILS"
  --data-dir "$NOXCAT_DATA_DIR"
  --vault-root "$NOXCAT_VAULT_ROOT"
  --code-dir "$MVP_CODE_DIR"
)

baseline_pid="$(pid_of "$PROD_UNIT")"
[[ "$baseline_pid" =~ ^[1-9][0-9]*$ ]] || { echo "production MainPID is not active" >&2; exit 1; }
echo "BASELINE_MAINPID=$baseline_pid"
show_8090
curl -fsS -o /dev/null http://127.0.0.1:8090/

"$PROVISION_BIN" provision "${customer_args[@]}"
after_provision_pid="$(pid_of "$PROD_UNIT")"
echo "AFTER_PROVISION_MAINPID=$after_provision_pid"
[[ "$after_provision_pid" == "$baseline_pid" ]]
show_8090
show_customer_port

# The generated unit must route both the Diana identity card and /api/monitor
# to the customer registry. Prove the live endpoint has no signal IDs in
# common with the production registry; a manufactured local session avoids
# changing customer auth settings merely for this host-side acceptance probe.
grep -Fx "MVP_SIGNAL_REGISTRY_PATH=\"$NOXCAT_DATA_DIR/state/signal-registry.json\"" "$NOXCAT_ENV_FILE"
grep -Fx "MVP_FATQ_ROOT=\"$NOXCAT_DATA_DIR/fatq\"" "$NOXCAT_ENV_FILE"
grep -Fx "MVP_PROJECTS_ROOT=\"$NOXCAT_DATA_DIR/projects\"" "$NOXCAT_ENV_FILE"
grep -Fx 'MVP_FATQ_BIN="/usr/bin/false"' "$NOXCAT_ENV_FILE"
customer_pid="$(pid_of "$CUSTOMER_UNIT")"
[[ "$customer_pid" =~ ^[1-9][0-9]*$ ]] || { echo "customer MainPID is not active" >&2; exit 1; }
customer_runtime_env="$(tr '\0' '\n' < "/proc/$customer_pid/environ")"
grep -Fx "MVP_FATQ_ROOT=$NOXCAT_DATA_DIR/fatq" <<< "$customer_runtime_env"
grep -Fx "MVP_PROJECTS_ROOT=$NOXCAT_DATA_DIR/projects" <<< "$customer_runtime_env"
grep -Fx 'MVP_FATQ_BIN=/usr/bin/false' <<< "$customer_runtime_env"
echo "RUNTIME_MVP_FATQ_ROOT=$NOXCAT_DATA_DIR/fatq"
echo "RUNTIME_MVP_PROJECTS_ROOT=$NOXCAT_DATA_DIR/projects"
echo "RUNTIME_MVP_FATQ_BIN=/usr/bin/false"
unset customer_runtime_env
[[ -s "$PRODUCTION_SIGNAL_REGISTRY" ]]
production_signal_count="$(jq '[.signals[]?.id] | length' "$PRODUCTION_SIGNAL_REGISTRY")"
((production_signal_count > 0))
monitor_cookie="$(bun -e '
  import { Database } from "bun:sqlite";
  import { createHmac } from "node:crypto";
  const db = new Database(process.argv[1], { readonly: true });
  const uid = String((db.query("SELECT id FROM users ORDER BY id LIMIT 1").get() as any)?.id ?? "");
  const secret = String((db.query("SELECT v FROM kv WHERE k=?").get("session_secret") as any)?.v ?? "");
  if (!/^[1-9][0-9]*$/.test(uid) || !secret) process.exit(1);
  const mac = createHmac("sha256", secret).update(uid).digest("hex").slice(0, 32);
  process.stdout.write(`${uid}.${mac}`);
' "$NOXCAT_DATA_DIR/users.db")"
monitor_body="$(mktemp)"
curl -fsS -o "$monitor_body" -H "Cookie: mvp_session=$monitor_cookie" \
  "http://127.0.0.1:$NOXCAT_PORT/api/monitor"
jq -e --slurpfile production "$PRODUCTION_SIGNAL_REGISTRY" '
  [.signals[]?.id] as $customer
  | [$production[0].signals[]?.id] as $prod
  | ($prod | length) > 0
    and ([$customer[] as $id | select($prod | index($id))] | length) == 0
' "$monitor_body" >/dev/null
echo "MONITOR_PRODUCTION_SIGNAL_COUNT=$production_signal_count"
echo "MONITOR_CROSS_TENANT_SIGNAL_INTERSECTION=0"
rm -f -- "$monitor_body"
unset monitor_cookie

http_body="$(mktemp)"
trap 'rm -f -- "$http_body"' EXIT
read -r http_status http_bytes < <(curl -sS -o "$http_body" -w '%{http_code} %{size_download}\n' \
  "http://127.0.0.1:$NOXCAT_PORT/")
echo "NOXCAT_HTTP_STATUS=$http_status"
echo "NOXCAT_HTTP_BYTES=$http_bytes"
[[ "$http_status" == 200 && "$http_bytes" =~ ^[1-9][0-9]*$ ]]
[[ -s "$http_body" ]]

# Two-way isolation without writing into the production checkout: create a
# customer-only marker, and use the production instance's pre-existing secret
# filename as the existing-only marker. Never print secret contents.
printf 'ba17-noxcat-only\n' > "$NOXCAT_DATA_DIR/ba17-noxcat-only.txt"
test -f "$NOXCAT_DATA_DIR/ba17-noxcat-only.txt"
test ! -e "$MVP_CODE_DIR/ba17-noxcat-only.txt"
echo "NEW_TO_EXISTING_ISOLATION=PASS customer marker absent from production data root"
test -f "$MVP_CODE_DIR/.internal-write-secret"
test ! -e "$NOXCAT_DATA_DIR/.internal-write-secret"
echo "EXISTING_TO_NEW_ISOLATION=PASS production-only marker absent from customer data root"

unit_before="$(find "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" -maxdepth 1 -name 'mvp-customer-noxcat.service' -printf '%f\n' | sort)"
files_before="$(find "$NOXCAT_DATA_DIR" -xdev -printf '%P\t%y\n' | sort)"
marker_sha_before="$(sha256sum "$NOXCAT_DATA_DIR/ba17-noxcat-only.txt")"
"$PROVISION_BIN" provision "${customer_args[@]}"
unit_after="$(find "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" -maxdepth 1 -name 'mvp-customer-noxcat.service' -printf '%f\n' | sort)"
files_after="$(find "$NOXCAT_DATA_DIR" -xdev -printf '%P\t%y\n' | sort)"
marker_sha_after="$(sha256sum "$NOXCAT_DATA_DIR/ba17-noxcat-only.txt")"
[[ "$unit_before" == "$unit_after" ]]
[[ "$files_before" == "$files_after" ]]
[[ "$marker_sha_before" == "$marker_sha_after" ]]
echo "IDEMPOTENT_UNITS_BEFORE=$unit_before"
echo "IDEMPOTENT_UNITS_AFTER=$unit_after"
printf 'IDEMPOTENT_FILES_BEFORE<<EOF\n%s\nEOF\n' "$files_before"
printf 'IDEMPOTENT_FILES_AFTER<<EOF\n%s\nEOF\n' "$files_after"
echo "IDEMPOTENT_MARKER_SHA_BEFORE=$marker_sha_before"
echo "IDEMPOTENT_MARKER_SHA_AFTER=$marker_sha_after"

"$PROVISION_BIN" uninstall --target local --customer NOXCAT
after_uninstall_pid="$(pid_of "$PROD_UNIT")"
echo "AFTER_UNINSTALL_MAINPID=$after_uninstall_pid"
[[ "$after_uninstall_pid" == "$baseline_pid" ]]
show_8090
curl -fsS -o /dev/null http://127.0.0.1:8090/
[[ ! -e "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$CUSTOMER_UNIT" ]]
[[ -f "$NOXCAT_DATA_DIR/ba17-noxcat-only.txt" ]]

# Leave the first customer environment running after proving uninstall.
"$PROVISION_BIN" provision "${customer_args[@]}"
final_pid="$(pid_of "$PROD_UNIT")"
echo "FINAL_MAINPID=$final_pid"
[[ "$final_pid" == "$baseline_pid" ]]
systemctl --user is-active --quiet "$CUSTOMER_UNIT"
show_8090
show_customer_port
curl -fsS -o /dev/null "http://127.0.0.1:$NOXCAT_PORT/"
echo "verify-noxcat-customer-env: PASS"
