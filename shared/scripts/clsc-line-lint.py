#!/usr/bin/env python3
"""Fail closed when a chats.clsc.md record is not a single legal CLSC line."""
from __future__ import annotations

import argparse
import re
from pathlib import Path

CLSC_LINE_RE = re.compile(
    r'^\[(?P<prefix>[^\r\n]+)\|"(?P<quote>[^"\r\n]*)"\|'
    r'(?P<weight>[^|\]\r\n]+)\|(?P<sentiment>[^|\]\r\n]+)\|'
    r'(?P<source>[^|\]\r\n]+)\]$'
)


def is_valid_clsc_line(line: str) -> bool:
    match = CLSC_LINE_RE.fullmatch(line)
    if not match:
        return False
    fields = match.group("prefix").split("|")
    return len(fields) >= 3 and all(fields)


def lint(path: Path) -> int:
    errors = 0
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.startswith("["):
            continue
        if not is_valid_clsc_line(line):
            errors += 1
            print(f"{path}:{number}: invalid CLSC: {line[:120]}")
    if errors:
        print(f"clsc-line-lint: FAIL ({errors} invalid record(s))")
        return 1
    print(f"clsc-line-lint: OK ({path})")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    raise SystemExit(lint(parser.parse_args().path))
