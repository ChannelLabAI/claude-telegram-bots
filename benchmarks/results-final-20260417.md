# MemOcean Final Benchmark Report — 2026-04-17

Run date: 2026-04-17

---

## Summary Table

| Dataset | Questions | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|---|
| **Internal-300 (Seabed FTS5+BM25)** | 216 | 67.1% | 81.9% | **84.3%** | 89.3% |
| Internal-300 (Seabed OR mode) | 216 | 78.7% | 91.7% | **94.4%** | 96.3% |
| Internal-300 (KG Query) | 19 | — | — | 100.0% | 100.0% |
| Internal-300 (Messages FTS5) | 25 | 56.0% | 60.0% | 64.0% | 68.0% |
| Internal-300 (Ocean Search) | 40 | 0.0% | 2.5% | 2.5% | 5.0% |
| **DRCD v2 (Traditional Chinese QA)** | 3493 | 80.3% | 89.6% | **91.9%** | 94.0% |
| **CMRC 2018 (Simplified Chinese QA)** | 3219 | 80.6% | 92.3% | **93.3%** | 93.8% |
| **BEIR SciFact (English Scientific)** | 300 | 51.3% | 64.7% | **70.7%** | 75.0% |

---

## Headline Numbers

- **Internal Hit@5 (FTS5)**: 84.3% — below previous 92-93% target (note: 60 new questions added with slightly harder queries; OR mode reaches 94.4%)
- **DRCD Hit@5**: 91.9% — above 90% target ✅
- **CMRC Hit@5**: 93.3% — above 90% target ✅
- **SciFact Hit@5**: 70.7% — below 90% target (expected; English BM25 on scientific text is harder)

---

## Internal-300 Breakdown

### Corpus
- Radar entries: 586 (upgraded from closet 289)
- KG: 806 entities, 828 triples
- Questions: 300 total (240 original + 60 new)

### Seabed Search (216 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 37.5% | 44.9% | 45.4% | 45.8% |
| OR | 78.7% | 91.7% | 94.4% | 96.3% |
| FTS5+BM25 | 67.1% | 81.9% | 84.3% | 89.3% |

**Note**: OR mode outperforms FTS5 on this internal corpus. This is expected for short Chinese query_terms — FTS5 tokenization disadvantage on CJK text. The OR mode Hit@5 of 94.4% is the operationally relevant number since seabed_search uses OR-match in production.

### Other APIs
- Messages FTS5 (25q): Hit@5 = 64.0%, Hit@10 = 68.0%
- KG Query (19q): 100.0% hit rate
- Ocean Search (40q): Hit@5 = 2.5% — ocean_search MCP not available in benchmark environment (uses live vault access)

### Hard Failures
- Seabed: 6 questions missed in all modes top-10
- Messages: 8 questions (snippets not in messages table snapshot)
- Ocean: 38 questions (ocean_search module not loadable offline)

---

## External Benchmarks

### DRCD v2 (Traditional Chinese MRC)
- Dataset: 3,493 test questions
- Hit@1: 80.3% | Hit@3: 89.6% | **Hit@5: 91.9%** | Hit@10: 94.0%
- Target ≥90%: **YES** ✅
- Gap vs internal baseline: -1.0pp

### CMRC 2018 (Simplified Chinese MRC)
- Dataset: 3,219 test questions
- Hit@1: 80.6% | Hit@3: 92.3% | **Hit@5: 93.3%** | Hit@10: 93.8%
- Target ≥90%: **YES** ✅
- Gap vs internal baseline: +0.4pp

### BEIR SciFact (English Scientific)
- Dataset: 300 test questions
- Hit@1: 51.3% | Hit@3: 64.7% | **Hit@5: 70.7%** | Hit@10: 75.0%
- Target ≥90%: NO (need 58 more hits)
- This is expected — pure BM25 on English scientific text without domain vocabulary is structurally disadvantaged vs specialized embeddings

---

## Changes in This Run

1. Updated benchmark script: `work-scenario-benchmark-v2.py`
   - Uses `radar` table (586 entries) instead of `closet` (289 entries)
   - Uses `radar_fts` / `clsc` column throughout
   - Output paths updated to `results-internal-300-20260417.{json,md}`

2. Extended question set: `work-scenario-300.json`
   - Added 60 new questions (IDs 241-300)
   - Covers 60 previously uncovered radar slugs
   - New scenes: `process_sop`, `tech_lookup`, `person_lookup`, `project_status`, `decision_record`, `resource_find`
   - Difficulty mix: ~60% easy, ~30% medium, ~10% hard

---

## Files

| File | Description |
|---|---|
| `benchmarks/work-scenario-300.json` | Updated 300-question benchmark |
| `scripts/work-scenario-benchmark-v2.py` | Updated script (radar table) |
| `benchmarks/results-internal-300-20260417.json` | Full internal results JSON |
| `benchmarks/results-internal-300-20260417.md` | Internal results markdown |
| `benchmarks/results-drcd-20260416.json` | DRCD results (re-run 2026-04-17) |
| `benchmarks/results-cmrc-20260416.json` | CMRC results (re-run 2026-04-17) |
| `benchmarks/results-scifact-20260416.json` | SciFact results (re-run 2026-04-17) |

---

*Generated 2026-04-17 by work-scenario-benchmark-v2.py*
