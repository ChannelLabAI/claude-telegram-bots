#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# patch-server.sh
# Re-apply patched server.ts after Claude Code updates
# Usage: ./patch-server.sh [--rollback]
# ─────────────────────────────────────────────

SHARED_DIR="$HOME/.claude-bots/shared"
PATCHED_SERVER="$SHARED_DIR/server.patched.ts"
# Base plugin version this patch was built against
PATCH_BASE_VERSION="0.0.4"

# ─── Dynamic plugin discovery ───
# Find ALL telegram plugin locations (marketplace + cache versions)

find_all_plugin_dirs() {
  local dirs=()
  local PLUGIN_BASE="$HOME/.claude/plugins/cache/claude-plugins-official/telegram"
  local PLUGIN_MKT="$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram"

  # 1. Marketplace path
  if [[ -d "$PLUGIN_MKT" && -f "$PLUGIN_MKT/server.ts" ]]; then
    dirs+=("$PLUGIN_MKT")
  fi

  # 2. Cache path — all version dirs
  if [[ -d "$PLUGIN_BASE" ]]; then
    while IFS= read -r d; do
      [[ -f "${d%/}/server.ts" ]] && dirs+=("${d%/}")
    done < <(ls -d "$PLUGIN_BASE"/*/ 2>/dev/null)
  fi

  # 3. Fallback: search for any we missed
  while IFS= read -r f; do
    local d; d="$(dirname "$f")"
    local already=false
    for existing in "${dirs[@]:-}"; do
      [[ "$existing" == "$d" ]] && already=true && break
    done
    $already || dirs+=("$d")
  done < <(find "$HOME/.claude/plugins" -name "server.ts" -path "*/telegram/*" 2>/dev/null)

  if [[ ${#dirs[@]} -eq 0 ]]; then
    return 1
  fi
  printf '%s\n' "${dirs[@]}"
}

if [[ ! -f "$PATCHED_SERVER" ]]; then
  echo "ERROR: No patched server.ts found at $PATCHED_SERVER" >&2
  echo "Copy your working server.ts (with relay support) there first." >&2
  exit 1
fi

PLUGIN_DIRS=()
while IFS= read -r d; do
  PLUGIN_DIRS+=("$d")
done < <(find_all_plugin_dirs 2>/dev/null || true)

if [[ ${#PLUGIN_DIRS[@]} -eq 0 ]]; then
  echo "ERROR: Telegram plugin not found." >&2
  echo "Searched: ~/.claude/plugins (recursive)" >&2
  echo "Is the telegram plugin installed? Try: claude plugins install telegram" >&2
  exit 1
fi

echo "→ Found ${#PLUGIN_DIRS[@]} plugin location(s)"

# ─── Version compatibility check ───

detect_plugin_version() {
  local dir="$1"
  # Try to detect from directory name (e.g., .../telegram/0.0.4/)
  local dir_version
  dir_version=$(echo "$dir" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1)
  if [[ -n "$dir_version" ]]; then
    echo "$dir_version"
    return
  fi
  # Try package.json
  if [[ -f "$dir/package.json" ]]; then
    local pkg_version
    pkg_version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$dir/package.json" | head -1)
    if [[ -n "$pkg_version" ]]; then
      echo "$pkg_version"
      return
    fi
  fi
  echo "unknown"
}

# ─── Rollback mode ───

if [[ "${1:-}" == "--rollback" ]]; then
  ROLLED=0
  for PLUGIN_CACHE in "${PLUGIN_DIRS[@]}"; do
    if [[ -f "$PLUGIN_CACHE/server.ts.original" ]]; then
      cp "$PLUGIN_CACHE/server.ts.original" "$PLUGIN_CACHE/server.ts"
      echo "→ Rolled back: $PLUGIN_CACHE"
      ROLLED=$((ROLLED + 1))
    else
      echo "⚠ No backup at: $PLUGIN_CACHE (skipped)"
    fi
  done
  if [[ $ROLLED -gt 0 ]]; then
    echo "→ Rolled back $ROLLED location(s). Restart your bots."
  else
    echo "ERROR: No backups found. Cannot rollback." >&2
    exit 1
  fi
  exit 0
fi

# ─── Apply patch to all locations ───

PATCHED=0
for PLUGIN_CACHE in "${PLUGIN_DIRS[@]}"; do
  DETECTED_VERSION=$(detect_plugin_version "$PLUGIN_CACHE")

  echo "→ $PLUGIN_CACHE (v$DETECTED_VERSION)"

  if ! cmp -s "$PATCHED_SERVER" "$PLUGIN_CACHE/server.ts"; then
    if [[ "$DETECTED_VERSION" != "unknown" && "$DETECTED_VERSION" != "$PATCH_BASE_VERSION" ]]; then
      echo "  ⚠ Version $DETECTED_VERSION differs from patch base $PATCH_BASE_VERSION"
    fi
    # Backup original before patching (first run only)
    if [[ ! -f "$PLUGIN_CACHE/server.ts.original" ]]; then
      cp "$PLUGIN_CACHE/server.ts" "$PLUGIN_CACHE/server.ts.original"
      echo "  → Backed up original server.ts"
    fi
    cp "$PATCHED_SERVER" "$PLUGIN_CACHE/server.ts"
    echo "  → Patched ✓"
    PATCHED=$((PATCHED + 1))
  else
    echo "  → Already up to date"
  fi
done

if [[ $PATCHED -gt 0 ]]; then
  echo "→ Patched $PATCHED location(s). Restart your bots to pick up changes."
else
  echo "→ All locations already up to date."
fi
