#!/usr/bin/env python3
"""
p2c_dryrun.py — P2c 寫入計畫 dry-run（唯讀）

讀 p2-link-suggestions JSON，篩 46 對強關係（延伸/導致/反例/引用），
雙向展開，對每張珍珠卡做 idempotent 檢查，
產出 p2c-write-plan.md 供 Anya/老兔審閱後才真寫。

⚠️ 全程唯讀：不改任何 .md、不寫 memory.db。

Usage:
  python3 p2c_dryrun.py
  python3 p2c_dryrun.py --suggestions /path/to/suggestions.json --output /path/to/plan.md
"""
import argparse
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

SUGGESTIONS_PATH = (
    Path(__file__).parent.parent.parent
    / "bots/anya/work/p2-link-suggestions-20260701-0910.json"
)
OUTPUT_PATH = (
    Path(__file__).parent.parent.parent / "bots/anya/work/p2c-write-plan.md"
)
STRONG_RELATIONS = {"延伸", "導致", "反例", "引用"}
HUB_THRESHOLD = 5  # cards gaining this many new links are flagged as hub candidates


# ── Card parsing (read-only) ──────────────────────────────────────────────────

def extract_existing_link_slugs(content: str) -> set[str]:
    """Return set of wikilink titles already in the 連結 section.

    Strips trailing text like （延伸）: matches [[slug]] and [[slug]]（…）.
    Both `[[slug]]` and `[[slug]]（relation）` count as 'already linked'.
    """
    # Find 連結 section — may be wrapped in --- or not
    section_match = re.search(
        r"(?:^|\n)[-—]{3,}\s*\n連結：\n(.*?)(?:\n[-—]{3,}|\Z)",
        content,
        re.S,
    )
    if not section_match:
        section_match = re.search(
            r"(?:^|\n)連結：\n(.*?)(?:\n[-—]{3,}|\n#+\s|\Z)",
            content,
            re.S,
        )
    if not section_match:
        return set()
    raw = section_match.group(1)
    # Extract slug from [[slug]] or [[slug]]（…） — capture only the inner part
    return set(re.findall(r"\[\[([^\]]+)\]\]", raw))


# ── Main dry-run logic ────────────────────────────────────────────────────────

def run_dryrun(suggestions_path: Path, output_path: Path) -> dict:
    """Build write plan. Returns summary stats."""
    import json
    with open(suggestions_path, encoding="utf-8") as f:
        data = json.load(f)

    # Filter to 46 strong pairs only
    strong = [
        s for s in data["suggestions"]
        if s.get("relation") in STRONG_RELATIONS
    ]

    # Build bidirectional directed edges: (source_wl, target_wl, relation, src_path, tgt_path)
    edges: list[tuple[str, str, str, str, str]] = []
    for s in strong:
        src_wl = Path(s["path_a"]).stem
        tgt_wl = Path(s["path_b"]).stem
        rel = s["relation"]
        edges.append((src_wl, tgt_wl, rel, s["path_a"], s["path_b"]))
        edges.append((tgt_wl, src_wl, rel, s["path_b"], s["path_a"]))

    # Group by source card
    card_additions: dict[str, dict] = {}
    for src_wl, tgt_wl, rel, src_path, tgt_path in edges:
        if src_wl not in card_additions:
            card_additions[src_wl] = {
                "path": src_path,
                "new": [],
                "skip": [],
            }
        card_additions[src_wl].setdefault("_targets_seen", set())
        if tgt_wl in card_additions[src_wl]["_targets_seen"]:
            continue
        card_additions[src_wl]["_targets_seen"].add(tgt_wl)

        # Read card and check existing links (idempotent)
        src_content = Path(src_path).read_text(encoding="utf-8")
        existing = extract_existing_link_slugs(src_content)

        if tgt_wl in existing:
            card_additions[src_wl]["skip"].append({
                "target": tgt_wl, "relation": rel, "target_path": tgt_path,
            })
        else:
            card_additions[src_wl]["new"].append({
                "target": tgt_wl, "relation": rel, "target_path": tgt_path,
            })

    # Stats
    total_new = sum(len(v["new"]) for v in card_additions.values())
    total_skip = sum(len(v["skip"]) for v in card_additions.values())
    cards_affected = sum(1 for v in card_additions.values() if v["new"])
    hub_candidates = [
        (wl, len(v["new"]))
        for wl, v in card_additions.items()
        if len(v["new"]) >= HUB_THRESHOLD
    ]
    hub_candidates.sort(key=lambda x: -x[1])

    # Produce plan markdown
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    lines = [
        "# P2c 寫入計畫（dry-run，唯讀）",
        f"> 產出時間：{now}",
        f"> 來源：{suggestions_path.name}",
        f"> 格式：新連結用 `- [[target]]（關係）`，雙向；idempotent 比對 `[[slug]]` 部分（不管後綴）",
        "",
        "## 統計",
        f"- 強關係對數（46 對 × 2）：{len(edges)} 條有向邊",
        f"- 涉及卡片數（有新增連結）：{cards_affected} 張",
        f"- 實際新增連結條數：{total_new}",
        f"- 因已存在而跳過：{total_skip}",
        "",
    ]

    if hub_candidates:
        lines += [
            "## ⚠️ 樞紐候選（新增連結 ≥ 5 條，建議評估是否改 MOC）",
        ]
        for wl, cnt in hub_candidates:
            lines.append(f"- `{wl}` — 新增 {cnt} 條連結")
        lines.append("")

    lines.append("## 逐卡明細")
    lines.append("")

    for wl, info in sorted(card_additions.items()):
        if not info["new"] and not info["skip"]:
            continue
        lines.append(f"### {wl}")
        lines.append(f"> 路徑：`{info['path']}`")
        lines.append("")
        if info["new"]:
            lines.append("**新增（dry-run）：**")
            for item in info["new"]:
                lines.append(f"- `- [[{item['target']}]]（{item['relation']}）`")
            lines.append("")
        if info["skip"]:
            lines.append("**已存在跳過：**")
            for item in info["skip"]:
                lines.append(f"- ~~`[[{item['target']}]]`~~ （已連，跳過）")
            lines.append("")

    plan_content = "\n".join(lines)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(plan_content, encoding="utf-8")

    return {
        "strong_pairs": len(strong),
        "directed_edges": len(edges),
        "cards_affected": cards_affected,
        "total_new": total_new,
        "total_skip": total_skip,
        "hub_candidates": hub_candidates,
        "output": str(output_path),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--suggestions", default=str(SUGGESTIONS_PATH))
    parser.add_argument("--output", default=str(OUTPUT_PATH))
    args = parser.parse_args()

    result = run_dryrun(Path(args.suggestions), Path(args.output))

    print("\n=== P2c Write Plan (dry-run) ===")
    print(f"Strong pairs × 2 : {result['directed_edges']} directed edges")
    print(f"Cards affected    : {result['cards_affected']}")
    print(f"New links         : {result['total_new']}")
    print(f"Skipped (exist)   : {result['total_skip']}")
    if result["hub_candidates"]:
        hubs_str = ", ".join(f"{wl}({n})" for wl, n in result["hub_candidates"])
        print(f"Hub candidates    : {hubs_str}")
    print(f"Output            : {result['output']}")


if __name__ == "__main__":
    main()
