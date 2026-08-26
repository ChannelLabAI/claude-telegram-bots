#!/usr/bin/env python3
"""Compatibility notification API backed by the gateway relay queue."""

import logging
import os
import subprocess

logger = logging.getLogger(__name__)

_RELAY_NOTIFY = os.environ.get(
    "ALERT_RELAY_NOTIFY_BIN", "/home/oldrabbit/.claude-bots/shared/bin/relay-notify"
)


def relay_notify(text: str, source: str, recipient: str = "anya") -> bool:
    """Queue a human-facing alert for an explicit bot recipient."""
    try:
        result = subprocess.run(
            [_RELAY_NOTIFY, source, recipient, text],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode != 0:
            logger.warning(
                "%s: relay_notify failed (rc=%d): %s",
                source,
                result.returncode,
                result.stderr.strip()[:200],
            )
            return False
        return True
    except Exception as exc:
        logger.warning("%s: relay_notify error: %s", source, exc)
        return False


def mm_post_notify(text: str, source: str) -> bool:
    """Deprecated compatibility name; routes to relay/TG, never Mattermost."""
    logger.warning("%s: mm_post_notify is deprecated; routing via relay", source)
    return relay_notify(text, source)
