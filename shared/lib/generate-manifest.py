#!/usr/bin/env python3
"""generate-manifest.py — standalone manifest generator (extracted from l25-trigger-loader.sh).

Usage:
  Write mode:   python3 generate-manifest.py <blocks_dir> <manifest_path>
  Stdout mode:  python3 generate-manifest.py <blocks_dir> --stdout

Write mode (default): generates manifest.json at manifest_path.
Stdout mode: prints manifest JSON to stdout only (no file write) — used by VERIFY V3.
"""

import json
import re
import sys
from pathlib import Path

FRONTMATTER_RE = re.compile(r'^---\s*\n(.*?)\n---', re.DOTALL)


def build_manifest(blocks_dir: Path) -> list:
    manifest = []
    for f in sorted(blocks_dir.glob("block-*.md")):
        if f.name.endswith(".pre-symlink"):
            continue
        text = f.read_text(errors='replace')
        m = FRONTMATTER_RE.match(text)
        if not m:
            continue
        fm = m.group(1)
        # Parse YAML fields manually (avoid pyyaml dep)
        triggers = []
        t_match = re.search(r'^triggers:\s*(\[.*?\])', fm, re.MULTILINE)
        if t_match:
            try:
                triggers = json.loads(t_match.group(1))
            except Exception:
                pass
        priority = "medium"
        p_match = re.search(r'^priority:\s*(\w+)', fm, re.MULTILINE)
        if p_match:
            priority = p_match.group(1).strip()
        size_tokens = 0
        s_match = re.search(r'^size_tokens:\s*(\d+)', fm, re.MULTILINE)
        if s_match:
            size_tokens = int(s_match.group(1))
        manifest.append({
            "name": f.name,
            "path": str(f),
            "triggers": triggers,
            "priority": priority,
            "size_tokens": size_tokens,
        })
    return manifest


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <blocks_dir> <manifest_path|--stdout>", file=sys.stderr)
        sys.exit(1)

    blocks_dir = Path(sys.argv[1])
    mode = sys.argv[2]

    manifest = build_manifest(blocks_dir)
    manifest_json = json.dumps(manifest, ensure_ascii=False, indent=2)

    if mode == "--stdout":
        print(manifest_json)
    else:
        manifest_path = Path(mode)
        manifest_path.write_text(manifest_json)
        print(f"manifest: {len(manifest)} blocks", file=sys.stderr)


if __name__ == "__main__":
    main()
