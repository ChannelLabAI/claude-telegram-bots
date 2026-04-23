#!/usr/bin/env python3
"""
CLSC A/B Benchmark v2
Compare two indexing strategies using the FULL radar_search() pipeline
(BM25 instr-OR recall + Haiku reranker) for both groups.

  Group A — Stripped skeleton (no structure tags)
  Group B — Production CLSC skeleton (with tags, current baseline)
"""

import json
import re
import sqlite3
import shutil
import sys
import os
from datetime import datetime
from pathlib import Path

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
SNAPSHOT_DB = "/home/oldrabbit/.claude-bots/benchmarks/memory-snapshot-20260416.db"
GROUP_A_DB = "/tmp/clsc-ab-group-a.db"
QUESTIONS_FILE = "/home/oldrabbit/.claude-bots/benchmarks/work-scenario-200.json"
OUT_DIR = "/home/oldrabbit/.claude-bots/benchmarks"
K_VALUES = [1, 3, 5, 10]


# ─────────────────────────────────────────────
# Step 1: Build Group A temp DB (stripped CLSC)
# ─────────────────────────────────────────────
def strip_clsc_tags(clsc: str) -> str:
    if not clsc:
        return clsc
    # Remove [SLUG|TITLE] prefix
    stripped = re.sub(r'^\[.*?\]\s*', '', clsc)
    # Remove ENT: KEY: TAG: label prefixes (keep the content after the label)
    stripped = re.sub(r'\b(ENT|KEY|TAG):', '', stripped)
    # Normalize whitespace
    return re.sub(r'\s+', ' ', stripped).strip()


def build_group_a_db():
    """Copy snapshot DB and overwrite radar.clsc with stripped content."""
    print(f"Building Group A DB at {GROUP_A_DB}...")
    shutil.copy(SNAPSHOT_DB, GROUP_A_DB)

    conn_a = sqlite3.connect(GROUP_A_DB)
    rows = conn_a.execute('SELECT slug, clsc FROM radar').fetchall()
    print(f"  Loaded {len(rows)} rows from snapshot")

    for slug, clsc in rows:
        stripped = strip_clsc_tags(clsc or "")
        conn_a.execute('UPDATE radar SET clsc=? WHERE slug=?', (stripped, slug))

    # Rebuild radar_fts with stripped content
    conn_a.execute('DELETE FROM radar_fts')
    conn_a.execute("INSERT INTO radar_fts(slug, clsc) SELECT slug, clsc FROM radar")
    conn_a.commit()
    conn_a.close()
    print(f"  Group A DB built: {len(rows)} rows, radar_fts rebuilt")


# ─────────────────────────────────────────────
# Step 2: Set up radar_search for evaluation
# ─────────────────────────────────────────────
def setup_radar_search():
    """Import radar_search module and configure env vars."""
    sys.path.insert(0, '/home/oldrabbit/.claude-bots/shared/memocean-mcp')

    # Enable Haiku reranker
    os.environ['ENABLE_HAIKU_RERANKER'] = '1'
    # Disable KNN (test BM25 + Haiku only)
    os.environ.pop('KNN_ENABLED', None)
    # Disable query expansion (benchmarks show it hurts)
    os.environ.pop('ENABLE_QUERY_EXPANSION', None)

    api_key = os.environ.get('ANTHROPIC_API_KEY')
    if not api_key:
        print("WARNING: ANTHROPIC_API_KEY not set — Haiku reranker will be disabled!")
    else:
        print(f"  ANTHROPIC_API_KEY present (length={len(api_key)})")
        print("  ENABLE_HAIKU_RERANKER=1 — Haiku reranker active")

    import memocean_mcp.config as cfg
    import memocean_mcp.tools.radar_search as rs

    return cfg, rs


def run_group(cfg, rs, db_path: str, label: str, questions: list, k_values: list) -> dict:
    """Run radar_search() with FTS_DB patched to db_path."""
    p = Path(db_path)
    # Patch FTS_DB at all module levels
    cfg.FTS_DB = p
    rs.FTS_DB = p

    hits = {k: 0 for k in k_values}
    total = len(questions)
    max_k = max(k_values)

    print(f"\n--- {label} (n={total}) ---", flush=True)
    for i, q in enumerate(questions):
        query = q['query_terms']
        expected = q.get('expected_slugs', [])
        try:
            results = rs.radar_search(query, limit=max_k)
            # Clear expansion cache between runs
            if hasattr(rs, '_EXPANSION_CACHE'):
                rs._EXPANSION_CACHE.clear()
            slugs = [r['slug'] for r in results]
        except Exception as e:
            print(f"  ERROR q{i}: {e}", flush=True)
            slugs = []
        for k in k_values:
            if any(s in slugs[:k] for s in expected):
                hits[k] += 1
        if (i + 1) % 30 == 0:
            pct5 = hits[5] / (i + 1) * 100
            print(f"  {i+1}/{total} Hit@5={pct5:.1f}%", flush=True)

    print(f"\n=== {label} ===")
    for k in k_values:
        print(f"  Hit@{k}: {hits[k]}/{total} = {hits[k]/total*100:.2f}%")

    return {k: round(hits[k] / total, 4) for k in k_values}


# ─────────────────────────────────────────────
# Step 3: Load questions
# ─────────────────────────────────────────────
def load_questions():
    with open(QUESTIONS_FILE) as f:
        data = json.load(f)
    questions = [
        q for q in data['questions']
        if q.get('search_api') == 'seabed_search' and q.get('expected_slugs')
    ]
    print(f"  Loaded {len(questions)} questions (seabed_search + expected_slugs)")
    return questions


# ─────────────────────────────────────────────
# Chart
# ─────────────────────────────────────────────
def make_hitatk_chart(group_a_scores, group_b_scores, k_values, out_path):
    """Bar chart comparing Hit@K for Group A vs Group B."""
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        import numpy as np
    except ImportError:
        print("  matplotlib not available, skipping chart")
        return False

    fig, ax = plt.subplots(figsize=(12, 8), dpi=100)

    x = np.arange(len(k_values))
    width = 0.35

    vals_a = [group_a_scores[k] * 100 for k in k_values]
    vals_b = [group_b_scores[k] * 100 for k in k_values]

    bars_a = ax.bar(x - width/2, vals_a, width, label="A: Stripped (no tags)", color="#4472C4", alpha=0.85)
    bars_b = ax.bar(x + width/2, vals_b, width, label="B: Production CLSC (with tags)", color="#ED7D31", alpha=0.85)

    for bar in bars_a:
        h = bar.get_height()
        ax.annotate(f"{h:.1f}%", xy=(bar.get_x() + bar.get_width() / 2, h),
                    xytext=(0, 3), textcoords="offset points", ha="center", va="bottom", fontsize=10)
    for bar in bars_b:
        h = bar.get_height()
        ax.annotate(f"{h:.1f}%", xy=(bar.get_x() + bar.get_width() / 2, h),
                    xytext=(0, 3), textcoords="offset points", ha="center", va="bottom", fontsize=10)

    ax.set_title("CLSC A/B v2: Hit@K Comparison — Full Pipeline with Haiku Reranker (n=156)",
                 fontsize=13, fontweight="bold", pad=15)
    ax.set_xlabel("K", fontsize=12)
    ax.set_ylabel("Hit@K (%)", fontsize=12)
    ax.set_xticks(x)
    ax.set_xticklabels([f"K={k}" for k in k_values], fontsize=11)
    ax.set_ylim(0, 110)
    ax.yaxis.grid(True, linestyle="--", alpha=0.7)
    ax.set_axisbelow(True)
    ax.legend(fontsize=11)

    plt.tight_layout()
    plt.savefig(out_path)
    plt.close()
    print(f"  Saved: {out_path}")
    return True


# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
def main():
    print("=" * 60)
    print("CLSC A/B Benchmark v2 — Full Pipeline with Haiku Reranker")
    print(f"Run at: {datetime.now().isoformat()}")
    print("=" * 60)

    # Step 1: Build Group A DB
    build_group_a_db()

    # Step 2: Set up radar_search
    print("\nSetting up radar_search pipeline...")
    cfg, rs = setup_radar_search()

    # Step 3: Load questions
    print("\nLoading questions...")
    questions = load_questions()

    # Step 4: Run Group A (stripped)
    group_a_scores = run_group(
        cfg, rs,
        GROUP_A_DB,
        "Group A: Stripped CLSC (no structure tags)",
        questions,
        K_VALUES
    )

    # Step 5: Run Group B (production)
    group_b_scores = run_group(
        cfg, rs,
        SNAPSHOT_DB,
        "Group B: Production CLSC (with structure tags)",
        questions,
        K_VALUES
    )

    hit5_gap = group_b_scores[5] - group_a_scores[5]
    print(f"\nHit@5 gap (B - A): {hit5_gap*100:+.1f}%")

    # Step 6: Load existing token_analysis from current JSON
    existing_json_path = os.path.join(OUT_DIR, "results-clsc-ab-20260416.json")
    token_analysis = {}
    try:
        with open(existing_json_path) as f:
            existing = json.load(f)
        token_analysis = existing.get("token_analysis", {})
        print(f"\nPreserved token_analysis from existing JSON")
    except Exception as e:
        print(f"\nWarning: could not load existing JSON for token_analysis: {e}")

    # Step 7: Generate chart
    print("\nGenerating Hit@K chart...")
    hitatk_chart_path = os.path.join(OUT_DIR, "clsc-ab-chart-hitatk.png")
    make_hitatk_chart(group_a_scores, group_b_scores, K_VALUES, hitatk_chart_path)

    # Step 8: Write results JSON
    result = {
        "run_at": datetime.now().isoformat(),
        "snapshot_date": "2026-04-16",
        "dataset": "work-scenario-200",
        "n_questions": len(questions),
        "pipeline": "full radar_search() with Haiku reranker (ENABLE_HAIKU_RERANKER=1)",
        "methodology_note": (
            "A/B 兩組均使用完整 radar_search() pipeline"
            "（BM25 instr-OR recall + Haiku reranker）。"
            "FTS_DB patched per group。"
            "差異僅在 clsc 欄位有無結構性 tag。"
            "KNN/semantic 停用（純 BM25 + Haiku 測試）。"
        ),
        "group_a": {
            "name": "stripped skeleton（去結構 tag）",
            "hit_at_1": group_a_scores[1],
            "hit_at_3": group_a_scores[3],
            "hit_at_5": group_a_scores[5],
            "hit_at_10": group_a_scores[10],
        },
        "group_b": {
            "name": "CLSC skeleton（生產，含 tag）",
            "hit_at_1": group_b_scores[1],
            "hit_at_3": group_b_scores[3],
            "hit_at_5": group_b_scores[5],
            "hit_at_10": group_b_scores[10],
        },
        "hit5_gap_b_minus_a": round(hit5_gap, 4),
        "token_analysis": token_analysis,
        "charts": [
            "benchmarks/clsc-ab-chart-hitatk.png",
            "benchmarks/clsc-ab-chart-tokens.png",
        ],
    }

    out_json = os.path.join(OUT_DIR, "results-clsc-ab-20260416.json")
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
    print(f"\nResults written: {out_json}")

    # Summary
    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)
    print(f"Pipeline: full radar_search() + Haiku reranker (ENABLE_HAIKU_RERANKER=1)")
    print(f"{'K':<6} {'Group A':>12} {'Group B':>12} {'Gap (B-A)':>12}")
    print("-" * 44)
    for k in K_VALUES:
        a = group_a_scores[k] * 100
        b = group_b_scores[k] * 100
        gap = b - a
        print(f"{'Hit@'+str(k):<6} {a:>11.1f}% {b:>11.1f}% {gap:>+11.1f}%")


if __name__ == "__main__":
    main()
