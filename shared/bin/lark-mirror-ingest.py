#!/usr/bin/env python3
"""Ingest one mirrored Markdown file through MemOcean's idempotent file ingester."""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "memocean-mcp"
sys.path.insert(0, str(ROOT))

from memocean_mcp.tools.ingest_file import ingest_file  # noqa: E402


def main() -> int:
    if len(sys.argv) != 2:
        print(json.dumps({"error": "usage", "code": "USAGE"}))
        return 2
    result = ingest_file(sys.argv[1])
    print(json.dumps(result, ensure_ascii=False))
    return 1 if result.get("error") else 0


if __name__ == "__main__":
    raise SystemExit(main())
