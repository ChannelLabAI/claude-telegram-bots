#!/usr/bin/env bash
set -euo pipefail
WAKEUP_DIR="$HOME/.claude-bots/shared/wakeup"
mkdir -p "$WAKEUP_DIR"

python3 - "$HOME/.claude-bots/scripts/team-l0-config.yml" "$WAKEUP_DIR/team-l0.md" "$HOME" <<'PYEOF'
import sys, re, yaml
from pathlib import Path
from datetime import datetime

config_path, target_path, home = sys.argv[1], sys.argv[2], sys.argv[3]

# ── extract_agenda helpers ────────────────────────────────────────────────────
_SECTION_HEADERS = ["## Current OKR", "## Pending Decisions", "## Risk Watch"]
_MAX_TITLE_CHARS = 40
_MAX_ITEMS_PER_SECTION = 3
_AGENDA_TOKEN_BUDGET = 200
_NOT_CREATED = "_（尚未建立）_"
_PARSE_ERROR = "_（解析失敗，請檢查 agenda.md）_"

def _approx_tokens(text):
    return max(1, len(text) // 4)

def _parse_section_items(section_body):
    items = []
    for line in section_body.splitlines():
        stripped = line.strip()
        m = re.match(r'^-\s+(\*\*[^*]+\*\*(?:\s*[—：:]\s*.+)?)', stripped)
        if not m:
            continue
        title = m.group(1)
        em_match = re.match(r'^(\*\*[^*]+\*\*)\s*[—：:]\s*(.+)$', title)
        if em_match:
            bold_part = em_match.group(1)
            desc_part = em_match.group(2)
            if len(desc_part) > _MAX_TITLE_CHARS:
                desc_part = desc_part[:_MAX_TITLE_CHARS].rstrip() + "…"
            title = f"{bold_part} — {desc_part}"
        items.append(title)
    return items

def _render_section(header, items):
    lines = [header]
    if not items:
        lines.append("_（無）_")
        return "\n".join(lines)
    shown = items[:_MAX_ITEMS_PER_SECTION]
    hidden = len(items) - len(shown)
    for item in shown:
        lines.append(f"- {item}")
    if hidden > 0:
        lines.append(f"_(+{hidden} more)_")
    return "\n".join(lines)

def _split_sections(body):
    sections = {}
    parts = re.split(r'(## [^\n]+)', body)
    i = 1
    while i < len(parts) - 1:
        header = parts[i].strip()
        body_part = parts[i + 1] if i + 1 < len(parts) else ""
        # Normalize key: strip trailing CJK/ASCII parentheticals, keep ## prefix + name
        normalized = re.sub(r'\s*[（(（].*$', '', header).strip()
        sections[normalized] = body_part
        sections[header] = body_part  # also store exact for direct lookup
        i += 2
    return sections

def extract_agenda(agenda_path):
    if not agenda_path.exists():
        return _NOT_CREATED
    raw = agenda_path.read_text(encoding="utf-8")
    if not raw.strip():
        return _NOT_CREATED
    fm_match = re.match(r'^---\n(.*?)\n---\n', raw, re.DOTALL)
    if not fm_match:
        return _PARSE_ERROR
    try:
        fm = yaml.safe_load(fm_match.group(1))
        if not isinstance(fm, dict) or "type" not in fm:
            return _PARSE_ERROR
    except yaml.YAMLError:
        return _PARSE_ERROR
    body = raw[fm_match.end():]
    sections_map = _split_sections(body)
    drop_order = list(reversed(_SECTION_HEADERS))

    def _find_body(hdr):
        if hdr in sections_map:
            return sections_map[hdr]
        # Normalized fallback (strip trailing parentheticals)
        norm = re.sub(r'\s*[（(（].*$', '', hdr).strip()
        return sections_map.get(norm, "")

    def build_output(active_headers):
        parts = []
        for hdr in active_headers:
            items = _parse_section_items(_find_body(hdr))
            parts.append(_render_section(hdr, items))
        return "\n\n".join(parts)

    active = list(_SECTION_HEADERS)
    output = build_output(active)
    for drop_hdr in drop_order:
        if _approx_tokens(output) <= _AGENDA_TOKEN_BUDGET:
            break
        if drop_hdr in active:
            active.remove(drop_hdr)
            output = build_output(active)
    if _approx_tokens(output) > _AGENDA_TOKEN_BUDGET:
        budget_chars = _AGENDA_TOKEN_BUDGET * 4
        output = output[:budget_chars].rstrip() + "\n_(truncated)_"
    return output

# ── Load static config (with fallbacks) ──────────────────────────────────────
try:
    cfg = yaml.safe_load(Path(config_path).read_text())
except Exception:
    cfg = {}

def get(key, default):
    return cfg.get(key, default)

# 團隊 line (from team_line_members)
team_members = get("team_line_members", [])
team_parts = [f"{m.get('name','')}({m.get('role','')})" if m.get('role') else m.get('name','')
              for m in team_members]
team_line = " / ".join(team_parts) or "（未設定）"

assistants_line = ", ".join(get("assistants", [])) or "（未設定）"

pools = get("shared_pools", {})
pools_line = " / ".join(f"{k}={v}" for k, v in pools.items()) or "（未設定）"

routing_line = "; ".join(get("routing", [])) or "（未設定）"

steps = get("wakeup_steps", [])
wakeup_line = " ".join(f"({i+1}) {s}" for i, s in enumerate(steps)) or "（未設定）"

links_line = " / ".join(get("related_links", [])) or "（未設定）"
description = get("description", "每隻 bot 啟動必讀。")

# ── Dynamic: FATQ counts ──────────────────────────────────────────────────────
tasks_base = Path(home) / ".claude-bots/tasks"
pending = len(list((tasks_base / "pending").glob("*.json")))
in_progress = len(list((tasks_base / "in_progress").glob("*.json")))
review = len(list((tasks_base / "review").glob("*.json")))

# ── Dynamic: Latest ADR ───────────────────────────────────────────────────────
adr_files = sorted(
    Path(home).glob("Documents/Obsidian Vault/Ocean/Chart/*ADR*.md"),
    key=lambda p: p.stat().st_mtime, reverse=True
)
latest_adr = adr_files[0].name if adr_files else "none"

# ── Dynamic: 焦點任務 per focus_member ───────────────────────────────────────
def extract_focus(vault_name):
    p = Path(home) / f"Documents/Obsidian Vault - {vault_name}/00Daily/日誌總結.md"
    if not p.exists():
        return "  （未建立）"
    text = p.read_text(encoding="utf-8")
    m = re.search(r'### 進行中\n(.*?)(?=###|\Z)', text, re.DOTALL)
    if not m:
        return "  （未建立）"
    lines = [l.strip() for l in m.group(1).splitlines()
             if l.strip() and not l.strip().startswith("（每天")]
    return "\n".join(f"  {l}" for l in lines[:3]) if lines else "  （未建立）"

focus_lines = ""
for m in get("focus_members", []):
    name = m.get("name", "")
    vault = m.get("vault", "")
    if not (name and vault):
        continue
    focus = extract_focus(vault)
    focus_lines += f"{name}：\n{focus}\n"

# ── Dynamic: Agenda 摘要 ──────────────────────────────────────────────────────
agenda_path = Path(home) / ".claude-bots/shared/wakeup/agenda.md"
agenda_block = extract_agenda(agenda_path)

# ── Write team-l0.md ─────────────────────────────────────────────────────────
ts = datetime.now().strftime("%Y-%m-%d")
content = f"""---
type: wakeup-layer
generated_at: {ts}
related: ["[[Bot-Team-Architecture]]", "[[Knowledge-Infra-ADR-2026-04-08]]", "[[CLSC]]"]
---

# ChannelLab Team L0

> {description}

**團隊**：{team_line}
**特助**：{assistants_line}
**共用池**: {pools_line}

**Active queue**: pending={pending}, in_progress={in_progress}, review={review}

**Latest ADR**: {latest_adr}

**焦點任務（進行中）**：
{focus_lines}
**📋 Agenda 摘要**（原文 `agenda.md`，每小時刷新）:
{agenda_block}

**Wakeup steps**: {wakeup_line}

**Routing**: {routing_line}

**深入閱讀**：{links_line}
""".rstrip() + "\n"

Path(target_path).write_text(content)
size = Path(target_path).stat().st_size
print(f"regenerated: {size} bytes (date={ts})")
PYEOF
