#!/usr/bin/env bash
# Provision isolated, local MVP customer instances. Remote targets are part of
# the interface contract but intentionally unsupported in v1.
set -euo pipefail

umask 077

SYSTEMD_USER_DIR="${PROVISION_SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
CUSTOMER_CONFIG_ROOT="${PROVISION_CONFIG_ROOT:-${XDG_CONFIG_HOME:-$HOME/.config}/channellab/customers}"
SYSTEMCTL_BIN="${PROVISION_SYSTEMCTL_BIN:-systemctl}"
SS_BIN="${PROVISION_SS_BIN:-ss}"
BUN_BIN_DEFAULT="${PROVISION_BUN_BIN:-$HOME/.bun/bin/bun}"
PRODUCTION_MVP_DIR="/home/oldrabbit/.claude-bots/mvp"

usage() {
  cat <<'EOF'
Usage:
  provision-customer-env.sh provision --target local --customer CODE --port PORT \
    --emails EMAILS --data-dir DIR --vault-root DIR [--code-dir DIR] [--bun-bin FILE]
  provision-customer-env.sh uninstall --target local --customer CODE [--purge-data]
  provision-customer-env.sh list [--target local]

Environment overrides for isolated tests:
  PROVISION_SYSTEMD_USER_DIR, PROVISION_CONFIG_ROOT,
  PROVISION_SYSTEMCTL_BIN, PROVISION_SS_BIN, PROVISION_BUN_BIN
EOF
}

die() { printf 'provision-customer-env: ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf 'provision-customer-env: %s\n' "$*"; }

require_value() {
  local flag="$1" value="${2:-}"
  [[ -n "$value" && "$value" != --* ]] || die "$flag requires a value"
}

customer_slug() {
  local raw="$1"
  [[ "$raw" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$ ]] \
    || die "customer must match [A-Za-z0-9][A-Za-z0-9_-]{0,62}"
  printf '%s' "${raw,,}"
}

validate_target() {
  [[ "$1" == "local" ]] || die "target '$1' is unsupported in v1; pass --target local"
}

validate_emails() {
  local emails="$1" item
  [[ -n "$emails" && "$emails" != *$'\n'* && "$emails" != *$'\r'* ]] || die "emails must be non-empty and single-line"
  IFS=',' read -r -a email_items <<< "$emails"
  ((${#email_items[@]} > 0)) || die "at least one email is required"
  for item in "${email_items[@]}"; do
    [[ "$item" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] \
      || die "invalid email in --emails: $item"
  done
}

validate_single_line() {
  local label="$1" value="$2"
  [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "$label must be non-empty and single-line"
}

validate_unit_path() {
  local label="$1" value="$2"
  validate_single_line "$label" "$value"
  [[ "$value" != *[[:space:]]* ]] || die "$label cannot contain whitespace in v1 systemd units: $value"
}

env_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

append_env() {
  local key="$1" value="$2"
  printf '%s=%s\n' "$key" "$(env_quote "$value")"
}

write_if_absent_or_equal() {
  local destination="$1" source="$2" mode="$3"
  if [[ -e "$destination" ]]; then
    cmp -s "$source" "$destination" || die "refusing to overwrite drifted file: $destination"
    rm -f -- "$source"
    return 1
  fi
  install -m "$mode" "$source" "$destination"
  rm -f -- "$source"
  return 0
}

port_in_use() {
  local port="$1" output
  output="$($SS_BIN -H -ltn "sport = :$port" 2>/dev/null || true)"
  [[ -n "$output" ]]
}

safe_data_dir() {
  local data_dir="$1" code_dir="$2"
  [[ "$data_dir" == /* ]] || die "data-dir must be absolute"
  [[ "$data_dir" != "/" && "$data_dir" != "$HOME" && "$data_dir" != "$PRODUCTION_MVP_DIR" ]] \
    || die "unsafe data-dir: $data_dir"
  [[ "$data_dir" != "$code_dir" ]] || die "data-dir must differ from code-dir"
  [[ "$data_dir" != "$code_dir/"* && "$code_dir" != "$data_dir/"* ]] \
    || die "data-dir and code-dir must not contain one another"
  [[ "$data_dir" != "$SYSTEMD_USER_DIR" && "$data_dir" != "$CUSTOMER_CONFIG_ROOT" ]] \
    || die "data-dir overlaps provisioning control files"
}

marker_text() {
  local customer="$1" slug="$2" data_dir="$3"
  printf 'schema=1\ncustomer=%s\nslug=%s\ndata_dir=%s\n' "$customer" "$slug" "$data_dir"
}

provision() {
  local customer="" port="" emails="" data_dir="" vault_root="" target=""
  local code_dir="$PRODUCTION_MVP_DIR" bun_bin="$BUN_BIN_DEFAULT"
  while (($#)); do
    case "$1" in
      --customer|--port|--emails|--data-dir|--vault-root|--target|--code-dir|--bun-bin)
        require_value "$1" "${2:-}"
        case "$1" in
          --customer) customer="$2" ;;
          --port) port="$2" ;;
          --emails) emails="$2" ;;
          --data-dir) data_dir="$2" ;;
          --vault-root) vault_root="$2" ;;
          --target) target="$2" ;;
          --code-dir) code_dir="$2" ;;
          --bun-bin) bun_bin="$2" ;;
        esac
        shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown provision argument: $1" ;;
    esac
  done

  [[ -n "$customer" && -n "$port" && -n "$emails" && -n "$data_dir" && -n "$vault_root" && -n "$target" ]] \
    || die "provision requires --target, --customer, --port, --emails, --data-dir and --vault-root"
  validate_target "$target"
  local slug; slug="$(customer_slug "$customer")"
  [[ "$port" =~ ^[0-9]+$ ]] || die "port must be numeric"
  ((port >= 1024 && port <= 65535)) || die "port must be between 1024 and 65535"
  ((port != 8090)) || die "port 8090 is reserved for mvp-server.service"
  validate_emails "$emails"
  validate_unit_path "code-dir" "$code_dir"
  validate_single_line "data-dir" "$data_dir"
  validate_single_line "vault-root" "$vault_root"
  validate_unit_path "bun-bin" "$bun_bin"
  validate_unit_path "systemd user dir" "$SYSTEMD_USER_DIR"
  validate_unit_path "customer config root" "$CUSTOMER_CONFIG_ROOT"
  code_dir="$(realpath -e "$code_dir")" || die "code-dir does not exist"
  vault_root="$(realpath -e "$vault_root")" || die "vault-root does not exist"
  data_dir="$(realpath -m "$data_dir")"
  bun_bin="$(realpath -e "$bun_bin")" || die "bun-bin does not exist"
  [[ -f "$code_dir/mvp-server.ts" ]] || die "code-dir has no mvp-server.ts: $code_dir"
  [[ -d "$vault_root" ]] || die "vault-root is not a directory: $vault_root"
  safe_data_dir "$data_dir" "$code_dir"

  mkdir -p "$SYSTEMD_USER_DIR" "$CUSTOMER_CONFIG_ROOT/.locks"
  exec 9>"$CUSTOMER_CONFIG_ROOT/.locks/$slug.lock"
  flock -x 9

  local unit_name="mvp-customer-$slug.service"
  local unit_path="$SYSTEMD_USER_DIR/$unit_name"
  local env_path="$CUSTOMER_CONFIG_ROOT/$slug.env"
  local config_tmp unit_tmp marker_tmp
  config_tmp="$(mktemp "$CUSTOMER_CONFIG_ROOT/.${slug}.env.XXXXXX")"
  unit_tmp="$(mktemp "$SYSTEMD_USER_DIR/.${unit_name}.XXXXXX")"
  marker_tmp="$(mktemp "$CUSTOMER_CONFIG_ROOT/.${slug}.marker.XXXXXX")"
  trap 'rm -f -- "${config_tmp:-}" "${unit_tmp:-}" "${marker_tmp:-}"' RETURN

  {
    append_env CUSTOMER_CODE "$customer"
    append_env MVP_PORT "$port"
    append_env MVP_DIR "$code_dir"
    append_env MVP_DATA_DIR "$data_dir"
    append_env MVP_ALLOWED_EMAILS "$emails"
    # Single-machine mode: both routes stay on this instance, but distinct host
    # spellings keep the preview-only host discriminator from swallowing the
    # whole application. The iframe sandbox/CSP/cookie controls are the actual
    # security boundary; this alias is routing, not a separate trust domain.
    append_env MVP_BASE_URL "http://127.0.0.1:$port"
    append_env MVP_ATTACH_ORIGIN "http://localhost:$port"
    append_env MVP_PUBLIC_MODE "0"
    append_env MVP_OCEAN_SEARCH_ROOT "$vault_root"
    append_env MVP_OCEAN_WRITE_ROOT "$vault_root"
    append_env MVP_FATQ_ROOT "$data_dir/fatq"
    append_env MVP_PROJECTS_ROOT "$data_dir/projects"
    append_env MVP_RELAY_DIR "$data_dir/relay"
    append_env MVP_GB "$data_dir/pod-system"
    append_env MVP_BOTS_DIR "$data_dir/bots"
    append_env MVP_MODEL_ROUTER "$data_dir/config/model-router.yml"
    append_env MVP_TEAM_CONFIG "$data_dir/config/team-config.json"
    append_env MVP_PENDING_DECISIONS "$data_dir/state/pending-decisions.json"
    append_env MVP_SIGNAL_REGISTRY_PATH "$data_dir/state/signal-registry.json"
    append_env MVP_BOT_WATCHDOG_LOG "$data_dir/logs/bot-watchdog.log"
    append_env MVP_SECTION11_VIOLATIONS_JSONL "$data_dir/logs/section11/violations.jsonl"
    append_env MVP_SKILL_XP_TSV "$data_dir/skill-xp/xp.tsv"
    append_env MVP_TRUST_TSV "$data_dir/trust-ledger/trust.tsv"
    append_env MVP_MEMORY_DB "$data_dir/memory.db"
    append_env MVP_KG_DB "$data_dir/kg.db"
    append_env MVP_USAGE_JSONL "$data_dir/logs/usage.jsonl"
    append_env MVP_CLSC_USAGE_JSONL "$data_dir/logs/clsc-usage.jsonl"
    append_env MVP_CODEX_USAGE_JSONL "$data_dir/logs/codex-usage.jsonl"
    append_env MVP_ATTACHMENTS_DIR "$data_dir/attachments"
    append_env MVP_PROJECT_ATTACHMENTS_DIR "$data_dir/project-attachments"
    append_env MVP_INTERNAL_WRITE_SECRET_FILE "$data_dir/.internal-write-secret"
    append_env MVP_KNOWLEDGE_AUDIT "$data_dir/knowledge-write.audit.jsonl"
    # Customer v1 has no isolated agent control plane. Fail closed instead of
    # allowing its web admin routes to mutate the production systemd/FATQ plane.
    append_env MVP_SYSTEMCTL_BIN "/usr/bin/false"
    append_env MVP_FATQ_BIN "/usr/bin/false"
    append_env MVP_MODEL_GATE_SCHEDULE_BIN "/usr/bin/false"
  } > "$config_tmp"

  {
    printf '[Unit]\nDescription=ChannelLab MVP customer instance (%s)\nAfter=network-online.target\n\n' "$customer"
    printf '[Service]\nType=simple\nWorkingDirectory=%s\n' "$code_dir"
    printf 'Environment=%s\n' "$(env_quote "HOME=$HOME")"
    printf 'Environment=%s\n' "$(env_quote "PATH=$(dirname "$bun_bin"):/usr/local/bin:/usr/bin:/bin")"
    printf 'EnvironmentFile=%s\n' "$env_path"
    printf 'ExecStart=%s run mvp-server.ts\n' "$bun_bin"
    printf 'Restart=always\nRestartSec=5\nMemoryMax=512M\nStandardOutput=journal\nStandardError=journal\n\n'
    printf '[Install]\nWantedBy=default.target\n'
  } > "$unit_tmp"
  marker_text "$customer" "$slug" "$data_dir" > "$marker_tmp"

  local existing_pair=0
  if [[ -e "$env_path" || -e "$unit_path" ]]; then
    [[ -f "$env_path" && -f "$unit_path" ]] || die "partial existing instance metadata for $slug"
    cmp -s "$config_tmp" "$env_path" || die "refusing to overwrite drifted config: $env_path"
    cmp -s "$unit_tmp" "$unit_path" || die "refusing to overwrite drifted unit: $unit_path"
    existing_pair=1
  else
    port_in_use "$port" && die "port $port is already listening"
  fi

  local marker_path="$data_dir/.mvp-customer-instance"
  if [[ -e "$data_dir" ]]; then
    [[ -d "$data_dir" && ! -L "$data_dir" ]] || die "data-dir must be a real directory: $data_dir"
    if [[ -e "$marker_path" ]]; then
      [[ -f "$marker_path" && ! -L "$marker_path" ]] || die "unsafe instance marker: $marker_path"
      cmp -s "$marker_tmp" "$marker_path" || die "data-dir belongs to a different instance: $data_dir"
    elif [[ -n "$(find "$data_dir" -mindepth 1 -print -quit)" ]]; then
      die "refusing to adopt non-empty unmarked data-dir: $data_dir"
    fi
  fi

  mkdir -p "$data_dir" "$data_dir/config" "$data_dir/state" "$data_dir/logs/section11" \
    "$data_dir/fatq"/{pending,in_progress,review,done,rejected,cancelled,wont_do,approval_pending,archived} \
    "$data_dir/projects" "$data_dir/relay" "$data_dir/pod-system" "$data_dir/bots" \
    "$data_dir/attachments" "$data_dir/project-attachments" "$data_dir/skill-xp" "$data_dir/trust-ledger"
  if [[ -e "$marker_path" ]]; then
    cmp -s "$marker_tmp" "$marker_path" || die "data-dir belongs to a different instance: $data_dir"
    rm -f -- "$marker_tmp"
  else
    install -m 600 "$marker_tmp" "$marker_path"
    rm -f -- "$marker_tmp"
  fi

  local changed=0
  if ((existing_pair == 0)); then
    write_if_absent_or_equal "$env_path" "$config_tmp" 600 && changed=1
    write_if_absent_or_equal "$unit_path" "$unit_tmp" 644 && changed=1
  else
    rm -f -- "$config_tmp" "$unit_tmp"
  fi

  if ((changed)); then "$SYSTEMCTL_BIN" --user daemon-reload; fi
  if "$SYSTEMCTL_BIN" --user is-active --quiet "$unit_name"; then
    note "$customer unchanged; $unit_name already active"
  else
    "$SYSTEMCTL_BIN" --user enable --now "$unit_name"
    note "$customer provisioned: unit=$unit_name port=$port data=$data_dir"
  fi
}

read_env_value() {
  local file="$1" key="$2" line value
  line="$(awk -v key="$key" 'index($0, key "=") == 1 { print; exit }' "$file")"
  [[ -n "$line" ]] || return 1
  value="${line#*=}"
  [[ "$value" == \"*\" ]] || return 1
  value="${value#\"}"; value="${value%\"}"
  value="${value//\\\"/\"}"; value="${value//\\\\/\\}"
  printf '%s' "$value"
}

uninstall_instance() {
  local customer="" target="" purge=0
  while (($#)); do
    case "$1" in
      --customer|--target)
        require_value "$1" "${2:-}"
        [[ "$1" == --customer ]] && customer="$2" || target="$2"
        shift 2 ;;
      --purge-data) purge=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown uninstall argument: $1" ;;
    esac
  done
  [[ -n "$customer" && -n "$target" ]] || die "uninstall requires --target and --customer"
  validate_target "$target"
  local slug; slug="$(customer_slug "$customer")"
  mkdir -p "$CUSTOMER_CONFIG_ROOT/.locks"
  exec 9>"$CUSTOMER_CONFIG_ROOT/.locks/$slug.lock"
  flock -x 9
  local unit_name="mvp-customer-$slug.service"
  local unit_path="$SYSTEMD_USER_DIR/$unit_name"
  local env_path="$CUSTOMER_CONFIG_ROOT/$slug.env"
  [[ -f "$env_path" && -f "$unit_path" ]] || die "instance metadata not found for $customer"
  local data_dir; data_dir="$(read_env_value "$env_path" MVP_DATA_DIR)" || die "cannot read MVP_DATA_DIR from $env_path"
  data_dir="$(realpath -m "$data_dir")"
  safe_data_dir "$data_dir" "__uninstall_no_code_dir__"

  "$SYSTEMCTL_BIN" --user disable --now "$unit_name"
  rm -f -- "$unit_path" "$env_path"
  "$SYSTEMCTL_BIN" --user daemon-reload

  if ((purge)); then
    local marker="$data_dir/.mvp-customer-instance" expected
    expected="$(marker_text "$customer" "$slug" "$data_dir")"
    [[ -f "$marker" && ! -L "$marker" ]] || die "purge refused: marker missing or unsafe: $marker"
    [[ "$(cat "$marker")" == "$expected" ]] || die "purge refused: marker does not match $customer"
    rm -rf -- "$data_dir"
    note "$customer uninstalled; data purged: $data_dir"
  else
    note "$customer uninstalled; data preserved: $data_dir"
  fi
}

list_instances() {
  local target="local"
  while (($#)); do
    case "$1" in
      --target) require_value "$1" "${2:-}"; target="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown list argument: $1" ;;
    esac
  done
  validate_target "$target"
  printf 'CUSTOMER\tUNIT\tPORT\tDATA_DIR\n'
  local env_path customer port data slug
  shopt -s nullglob
  for env_path in "$CUSTOMER_CONFIG_ROOT"/*.env; do
    slug="$(basename "$env_path" .env)"
    customer="$(read_env_value "$env_path" CUSTOMER_CODE || printf '%s' "$slug")"
    port="$(read_env_value "$env_path" MVP_PORT || printf '?')"
    data="$(read_env_value "$env_path" MVP_DATA_DIR || printf '?')"
    printf '%s\t%s\t%s\t%s\n' "$customer" "mvp-customer-$slug.service" "$port" "$data"
  done
}

main() {
  (($# > 0)) || { usage; exit 2; }
  local action="$1"; shift
  case "$action" in
    provision) provision "$@" ;;
    uninstall) uninstall_instance "$@" ;;
    list) list_instances "$@" ;;
    -h|--help) usage ;;
    *) die "unknown action: $action" ;;
  esac
}

main "$@"
