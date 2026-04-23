#!/usr/bin/env python3
"""
LLM (Claude Haiku) vs jieba rule-based CLSC skeleton quality comparison.
Read-only test — no production files or DB modified.
"""

import sqlite3
import anthropic
import json
import time
import os

DB_PATH = "/home/oldrabbit/.claude-bots/memory.db"
MODEL = "claude-haiku-4-20250414"
OUTPUT_PATH = "/home/oldrabbit/.claude-bots/logs/llm-skeleton-test.md"

SKELETON_PROMPT = """你是一個中文文件索引器。請把以下文件壓縮成單行 skeleton 索引，格式：
[SLUG|ENTITIES|topics|"key_quote"|WEIGHT|EMOTIONS|FLAGS]

規則：
- ENTITIES：文中出現的所有人名、公司名、專案名，逗號分隔
- topics：3-5 個主題關鍵字
- key_quote：最重要的一句話
- WEIGHT：1-5 重要度
- EMOTIONS：neutral/positive/negative
- FLAGS：無特殊標記填空

文件 slug: {slug}

文件內容：
{content}"""

JUDGE_PROMPT = """你是品質評審。以下是一篇文件的原文，以及兩個 skeleton 索引（A 和 B），你不知道哪個是機器規則生成、哪個是 LLM 生成。

請對每個 skeleton 打分（1-5），維度：
1. Entity 覆蓋度：有沒有抓到所有重要 entity（人名、公司名、專案名）？
2. 摘要品質：key_quote / 關鍵摘要抓得準不準？
3. Topic 精確度：topics 是否反映文件核心？
4. 精簡度：哪個更精簡但不失重要資訊？

輸出嚴格 JSON，不要任何其他文字：
{{"A": {{"entity": N, "summary": N, "topic": N, "concise": N}}, "B": {{"entity": N, "summary": N, "topic": N, "concise": N}}, "winner": "A" or "B" or "tie", "reason": "一句話"}}

原文（截取前 2000 字）：
{original}

Skeleton A：
{skeleton_a}

Skeleton B：
{skeleton_b}"""


def get_samples():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute(
        "SELECT slug, drawer_path, clsc FROM closet "
        "WHERE drawer_path IS NOT NULL ORDER BY RANDOM() LIMIT 20"
    )
    rows = c.fetchall()
    conn.close()
    return [(r[0], r[1], r[2]) for r in rows]


def read_file(path, max_chars=6000):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()[:max_chars]
    except Exception as e:
        return None


def call_haiku(client, prompt, max_tokens=1024):
    t0 = time.time()
    resp = client.messages.create(
        model=MODEL,
        max_tokens=max_tokens,
        messages=[{"role": "user", "content": prompt}],
    )
    elapsed = time.time() - t0
    text = resp.content[0].text
    usage = resp.usage
    return text, usage.input_tokens, usage.output_tokens, elapsed


def main():
    client = anthropic.Anthropic()
    samples = get_samples()

    results = []
    total_input_tokens = 0
    total_output_tokens = 0
    total_time = 0.0
    api_calls = 0

    print(f"Testing {len(samples)} samples...")

    for i, (slug, path, jieba_skel) in enumerate(samples):
        content = read_file(path)
        if not content:
            print(f"  [{i+1}] SKIP {slug} — file unreadable")
            continue

        print(f"  [{i+1}/{len(samples)}] {slug}...")

        # Generate Haiku skeleton
        prompt = SKELETON_PROMPT.format(slug=slug, content=content[:4000])
        try:
            haiku_skel, in_tok, out_tok, elapsed = call_haiku(client, prompt)
        except Exception as e:
            print(f"    ERROR generating skeleton: {e}")
            continue
        total_input_tokens += in_tok
        total_output_tokens += out_tok
        total_time += elapsed
        api_calls += 1

        # Blind judge — randomize order
        import random
        if random.random() > 0.5:
            a_skel, b_skel = jieba_skel[:800], haiku_skel[:800]
            a_is = "jieba"
        else:
            a_skel, b_skel = haiku_skel[:800], jieba_skel[:800]
            a_is = "haiku"

        judge_prompt = JUDGE_PROMPT.format(
            original=content[:2000],
            skeleton_a=a_skel,
            skeleton_b=b_skel,
        )

        try:
            judge_raw, j_in, j_out, j_elapsed = call_haiku(client, judge_prompt, max_tokens=512)
            total_input_tokens += j_in
            total_output_tokens += j_out
            total_time += j_elapsed
            api_calls += 1

            # Parse judge output
            # Try to extract JSON from response
            json_start = judge_raw.find("{")
            json_end = judge_raw.rfind("}") + 1
            if json_start >= 0 and json_end > json_start:
                scores = json.loads(judge_raw[json_start:json_end])
            else:
                scores = None
        except Exception as e:
            print(f"    ERROR judging: {e}")
            scores = None

        # Map back to jieba/haiku
        if scores:
            if a_is == "jieba":
                jieba_scores = scores.get("A", {})
                haiku_scores = scores.get("B", {})
                raw_winner = scores.get("winner", "tie")
                if raw_winner == "A":
                    winner = "jieba"
                elif raw_winner == "B":
                    winner = "haiku"
                else:
                    winner = "tie"
            else:
                jieba_scores = scores.get("B", {})
                haiku_scores = scores.get("A", {})
                raw_winner = scores.get("winner", "tie")
                if raw_winner == "A":
                    winner = "haiku"
                elif raw_winner == "B":
                    winner = "jieba"
                else:
                    winner = "tie"

            results.append({
                "slug": slug,
                "jieba_scores": jieba_scores,
                "haiku_scores": haiku_scores,
                "winner": winner,
                "reason": scores.get("reason", ""),
                "jieba_len": len(jieba_skel) if jieba_skel else 0,
                "haiku_len": len(haiku_skel),
            })
        else:
            results.append({
                "slug": slug,
                "jieba_scores": {},
                "haiku_scores": {},
                "winner": "error",
                "reason": "judge parse failed",
                "jieba_len": len(jieba_skel) if jieba_skel else 0,
                "haiku_len": len(haiku_skel),
            })

    # ---- Aggregate ----
    valid = [r for r in results if r["winner"] != "error"]
    haiku_wins = sum(1 for r in valid if r["winner"] == "haiku")
    jieba_wins = sum(1 for r in valid if r["winner"] == "jieba")
    ties = sum(1 for r in valid if r["winner"] == "tie")

    dims = ["entity", "summary", "topic", "concise"]
    avg_jieba = {}
    avg_haiku = {}
    for d in dims:
        j_vals = [r["jieba_scores"].get(d, 0) for r in valid if r["jieba_scores"]]
        h_vals = [r["haiku_scores"].get(d, 0) for r in valid if r["haiku_scores"]]
        avg_jieba[d] = sum(j_vals) / len(j_vals) if j_vals else 0
        avg_haiku[d] = sum(h_vals) / len(h_vals) if h_vals else 0

    avg_jieba_len = sum(r["jieba_len"] for r in valid) / len(valid) if valid else 0
    avg_haiku_len = sum(r["haiku_len"] for r in valid) / len(valid) if valid else 0

    # ---- Write report ----
    lines = []
    lines.append("# LLM Skeleton vs Jieba Rule-Based — Blind Test Results")
    lines.append(f"\nDate: 2026-04-10")
    lines.append(f"Model: {MODEL}")
    lines.append(f"Sample size: {len(samples)} drawn, {len(valid)} scored")
    lines.append("")
    lines.append("## Overall Winner Tally")
    lines.append(f"| Method | Wins |")
    lines.append(f"|--------|------|")
    lines.append(f"| Haiku  | {haiku_wins}    |")
    lines.append(f"| Jieba  | {jieba_wins}    |")
    lines.append(f"| Tie    | {ties}    |")
    lines.append("")
    lines.append("## Average Scores by Dimension (1-5)")
    lines.append("| Dimension | Jieba | Haiku | Delta |")
    lines.append("|-----------|-------|-------|-------|")
    for d in dims:
        delta = avg_haiku[d] - avg_jieba[d]
        sign = "+" if delta > 0 else ""
        lines.append(f"| {d:9s} | {avg_jieba[d]:.2f}  | {avg_haiku[d]:.2f}  | {sign}{delta:.2f}  |")
    lines.append("")
    lines.append("## Average Token Length (chars)")
    lines.append(f"| Method | Avg chars |")
    lines.append(f"|--------|-----------|")
    lines.append(f"| Jieba  | {avg_jieba_len:.0f}       |")
    lines.append(f"| Haiku  | {avg_haiku_len:.0f}       |")
    lines.append("")
    lines.append("## Cost")
    lines.append(f"- API calls: {api_calls}")
    lines.append(f"- Input tokens: {total_input_tokens:,}")
    lines.append(f"- Output tokens: {total_output_tokens:,}")
    lines.append(f"- Wall time: {total_time:.1f}s")
    lines.append(f"- Estimated cost: ~${(total_input_tokens * 0.25 + total_output_tokens * 1.25) / 1_000_000:.4f}")
    lines.append("")
    lines.append("## Per-Document Detail")
    lines.append("| # | Slug | Winner | Jieba E/S/T/C | Haiku E/S/T/C | Jieba len | Haiku len | Reason |")
    lines.append("|---|------|--------|---------------|---------------|-----------|-----------|--------|")
    for i, r in enumerate(results):
        js = r["jieba_scores"]
        hs = r["haiku_scores"]
        j_str = f"{js.get('entity','-')}/{js.get('summary','-')}/{js.get('topic','-')}/{js.get('concise','-')}"
        h_str = f"{hs.get('entity','-')}/{hs.get('summary','-')}/{hs.get('topic','-')}/{hs.get('concise','-')}"
        reason = r["reason"][:60] if r["reason"] else ""
        lines.append(f"| {i+1} | {r['slug'][:40]} | {r['winner']} | {j_str} | {h_str} | {r['jieba_len']} | {r['haiku_len']} | {reason} |")

    lines.append("")
    lines.append("## Notes")
    lines.append("- Judge: same Haiku model (blind — order randomized)")
    lines.append("- No production files or DB were modified")
    lines.append("- Jieba skeletons from existing `clsc` column in closet table")

    report = "\n".join(lines)

    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        f.write(report)

    print(f"\n{'='*60}")
    print(f"Done. {len(valid)} scored. Haiku {haiku_wins} / Jieba {jieba_wins} / Tie {ties}")
    print(f"Report: {OUTPUT_PATH}")
    print(f"Cost: {total_input_tokens:,} in + {total_output_tokens:,} out tokens, {total_time:.1f}s")


if __name__ == "__main__":
    main()
