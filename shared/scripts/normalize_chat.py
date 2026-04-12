#!/usr/bin/env python3
"""
normalize_chat.py — Convert any chat export format to unified markdown transcript.

Forked from upstream mempalace/normalize.py (MIT, 328 lines, zero-dep).
Modifications:
    - Added source-format detection tag + timestamp header on output
    - Dropped mempalace.spellcheck soft-import (pure rules only)
    - CLI writes full normalized transcript to stdout (was preview only)

Supported input formats:
    1. Claude Code JSONL          (~/.claude/projects/*/*.jsonl)
    2. Claude.ai JSON export      (privacy export or flat messages)
    3. ChatGPT conversations.json (mapping tree)
    4. OpenAI Codex CLI JSONL     (~/.codex/sessions/.../rollout-*.jsonl)
    5. Slack channel JSON export  ([{"type":"message",...}, ...])

Unified output:
    ---
    source: <format-tag>
    normalized_at: <iso8601>
    origin: <basename>
    ---

    > user: ...

    assistant: ...

    > user: ...

    ...

No API. No network. Pure local rules.

Usage:
    normalize_chat.py <input-file> > out.md
"""

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, Tuple


# ---------- top-level dispatcher ----------

def normalize(filepath: str) -> str:
    """Load file, detect format, return unified markdown transcript (with header)."""
    try:
        with open(filepath, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
    except OSError as e:
        raise IOError(f"Could not read {filepath}: {e}")

    if not content.strip():
        return content

    source_tag, body = _detect_and_normalize(content, filepath)
    header = _make_header(source_tag, filepath)
    return header + body


def _detect_and_normalize(content: str, filepath: str) -> Tuple[str, str]:
    """Return (source_tag, markdown_body)."""
    # Already a transcript? pass through
    lines = content.split("\n")
    if sum(1 for line in lines if line.strip().startswith(">")) >= 3:
        return "passthrough", content

    ext = Path(filepath).suffix.lower()
    first_char = content.strip()[:1]
    if ext in (".json", ".jsonl") or first_char in ("{", "["):
        # JSONL formats first
        body = _try_claude_code_jsonl(content)
        if body:
            return "claude-code-jsonl", body
        body = _try_codex_jsonl(content)
        if body:
            return "codex-cli-jsonl", body
        try:
            data = json.loads(content)
        except json.JSONDecodeError:
            return "unknown", content

        for tag, parser in (
            ("claude-ai-json", _try_claude_ai_json),
            ("chatgpt-json", _try_chatgpt_json),
            ("slack-json", _try_slack_json),
        ):
            body = parser(data)
            if body:
                return tag, body

    return "unknown", content


def _make_header(source_tag: str, filepath: str) -> str:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    origin = os.path.basename(filepath)
    return (
        "---\n"
        f"source: {source_tag}\n"
        f"normalized_at: {ts}\n"
        f"origin: {origin}\n"
        "---\n\n"
    )


# ---------- per-format parsers ----------

def _try_claude_code_jsonl(content: str) -> Optional[str]:
    """Claude Code JSONL sessions (~/.claude/projects/.../*.jsonl)."""
    lines = [ln.strip() for ln in content.strip().split("\n") if ln.strip()]
    messages = []
    for line in lines:
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(entry, dict):
            continue
        msg_type = entry.get("type", "")
        message = entry.get("message", {}) or {}
        if msg_type in ("human", "user"):
            text = _extract_content(message.get("content", ""))
            if text:
                messages.append(("user", text))
        elif msg_type == "assistant":
            text = _extract_content(message.get("content", ""))
            if text:
                messages.append(("assistant", text))
    if len(messages) >= 2:
        return _messages_to_transcript(messages)
    return None


def _try_codex_jsonl(content: str) -> Optional[str]:
    """OpenAI Codex CLI sessions. Requires session_meta to avoid false positives."""
    lines = [ln.strip() for ln in content.strip().split("\n") if ln.strip()]
    messages = []
    has_session_meta = False
    for line in lines:
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(entry, dict):
            continue
        entry_type = entry.get("type", "")
        if entry_type == "session_meta":
            has_session_meta = True
            continue
        if entry_type != "event_msg":
            continue
        payload = entry.get("payload", {})
        if not isinstance(payload, dict):
            continue
        payload_type = payload.get("type", "")
        msg = payload.get("message")
        if not isinstance(msg, str):
            continue
        text = msg.strip()
        if not text:
            continue
        if payload_type == "user_message":
            messages.append(("user", text))
        elif payload_type == "agent_message":
            messages.append(("assistant", text))
    if len(messages) >= 2 and has_session_meta:
        return _messages_to_transcript(messages)
    return None


def _try_claude_ai_json(data) -> Optional[str]:
    """Claude.ai JSON export: flat messages list OR privacy export w/ chat_messages."""
    if isinstance(data, dict):
        data = data.get("messages", data.get("chat_messages", []))
    if not isinstance(data, list):
        return None

    # Privacy export: array of conversation objects with chat_messages inside each
    if data and isinstance(data[0], dict) and "chat_messages" in data[0]:
        all_messages = []
        for convo in data:
            if not isinstance(convo, dict):
                continue
            for item in convo.get("chat_messages", []):
                if not isinstance(item, dict):
                    continue
                role = item.get("role", "") or item.get("sender", "")
                text = _extract_content(item.get("content", item.get("text", "")))
                if role in ("user", "human") and text:
                    all_messages.append(("user", text))
                elif role in ("assistant", "ai") and text:
                    all_messages.append(("assistant", text))
        if len(all_messages) >= 2:
            return _messages_to_transcript(all_messages)
        return None

    # Flat messages list
    messages = []
    for item in data:
        if not isinstance(item, dict):
            continue
        role = item.get("role", "")
        text = _extract_content(item.get("content", ""))
        if role in ("user", "human") and text:
            messages.append(("user", text))
        elif role in ("assistant", "ai") and text:
            messages.append(("assistant", text))
    if len(messages) >= 2:
        return _messages_to_transcript(messages)
    return None


def _try_chatgpt_json(data) -> Optional[str]:
    """ChatGPT conversations.json with mapping tree."""
    if not isinstance(data, dict) or "mapping" not in data:
        return None
    mapping = data["mapping"]
    messages = []
    root_id = None
    fallback_root = None
    for node_id, node in mapping.items():
        if node.get("parent") is None:
            if node.get("message") is None:
                root_id = node_id
                break
            elif fallback_root is None:
                fallback_root = node_id
    if not root_id:
        root_id = fallback_root
    if root_id:
        current_id = root_id
        visited = set()
        while current_id and current_id not in visited:
            visited.add(current_id)
            node = mapping.get(current_id, {})
            msg = node.get("message")
            if msg:
                role = msg.get("author", {}).get("role", "")
                content = msg.get("content", {})
                parts = content.get("parts", []) if isinstance(content, dict) else []
                text = " ".join(str(p) for p in parts if isinstance(p, str) and p).strip()
                if role == "user" and text:
                    messages.append(("user", text))
                elif role == "assistant" and text:
                    messages.append(("assistant", text))
            children = node.get("children", [])
            current_id = children[0] if children else None
    if len(messages) >= 2:
        return _messages_to_transcript(messages)
    return None


def _try_slack_json(data) -> Optional[str]:
    """Slack channel export. Alternates roles so chunking works with 3+ speakers."""
    if not isinstance(data, list):
        return None
    messages = []
    seen_users = {}
    last_role = None
    for item in data:
        if not isinstance(item, dict) or item.get("type") != "message":
            continue
        user_id = item.get("user", item.get("username", ""))
        text = (item.get("text", "") or "").strip()
        if not text or not user_id:
            continue
        if user_id not in seen_users:
            if not seen_users:
                seen_users[user_id] = "user"
            elif last_role == "user":
                seen_users[user_id] = "assistant"
            else:
                seen_users[user_id] = "user"
        last_role = seen_users[user_id]
        messages.append((seen_users[user_id], text))
    if len(messages) >= 2:
        return _messages_to_transcript(messages)
    return None


# ---------- helpers ----------

def _extract_content(content) -> str:
    """Pull text from content — handles str, list of blocks, or dict."""
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                if item.get("type") == "text":
                    parts.append(item.get("text", ""))
                elif "text" in item and isinstance(item["text"], str):
                    parts.append(item["text"])
        return " ".join(p for p in parts if p).strip()
    if isinstance(content, dict):
        return str(content.get("text", "")).strip()
    return ""


def _messages_to_transcript(messages) -> str:
    """Convert [(role, text), ...] to '> user\\n\\nassistant\\n' markdown."""
    lines = []
    i = 0
    while i < len(messages):
        role, text = messages[i]
        if role == "user":
            lines.append(f"> {text}")
            if i + 1 < len(messages) and messages[i + 1][0] == "assistant":
                lines.append("")
                lines.append(messages[i + 1][1])
                i += 2
            else:
                i += 1
        else:
            lines.append(text)
            i += 1
        lines.append("")
    return "\n".join(lines)


# ---------- CLI ----------

def main():
    if len(sys.argv) < 2:
        print("Usage: normalize_chat.py <input-file> > out.md", file=sys.stderr)
        sys.exit(1)
    filepath = sys.argv[1]
    try:
        result = normalize(filepath)
    except IOError as e:
        print(str(e), file=sys.stderr)
        sys.exit(2)
    sys.stdout.write(result)


if __name__ == "__main__":
    main()
