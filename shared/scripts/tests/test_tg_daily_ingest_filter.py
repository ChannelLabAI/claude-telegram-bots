import importlib.util
import sqlite3
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path


SCRIPTS_DIR = Path(__file__).resolve().parents[1]
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))
SPEC = importlib.util.spec_from_file_location("tg_daily_ingest", SCRIPTS_DIR / "tg_daily_ingest.py")
assert SPEC and SPEC.loader
INGEST = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INGEST)


class RuleFilterTest(unittest.TestCase):
    def test_relay_source_is_removed_before_it_can_take_a_slot(self):
        messages = [
            {"source": "relay-msg", "text": "[FATQ REJECT] " + "x" * 150, "user": "bot"},
            {"source": "telegram", "text": "老兔決定採用完整原文管線", "user": "oldrabbit_eth"},
            {"source": "telegram", "text": "ordinary short note", "user": "someone"},
        ]
        stats = {}
        kept = INGEST.rule_filter(messages, stats)
        self.assertEqual(kept, [messages[1]])
        self.assertEqual(stats, {"relay_msg_filtered": 1})

    def test_window_query_preserves_source_for_filtering(self):
        conn = sqlite3.connect(":memory:")
        conn.execute(
            "CREATE TABLE messages (chat_id TEXT, message_id TEXT, user TEXT, ts TEXT, text TEXT, source TEXT)"
        )
        conn.execute(
            "INSERT INTO messages VALUES (?, ?, ?, ?, ?, ?)",
            ("1", "relay-msg|anya|1", "bot", "2026-08-04T00:00:00.000Z", "notice", "relay-msg"),
        )
        rows = INGEST.get_messages_for_window(
            conn,
            datetime(2026, 8, 4, tzinfo=timezone.utc),
            datetime(2026, 8, 5, tzinfo=timezone.utc),
        )
        self.assertEqual(rows[0]["source"], "relay-msg")


if __name__ == "__main__":
    unittest.main()
