# LongMemEval Benchmark Results

**Date**: 2026-04-10
**Data**: `longmemeval_s_cleaned.json` (500 questions, ~53 sessions/question, ~115k tokens)
**Granularity**: session-level (user-side text only, matching LongMemEval convention)
**Questions evaluated**: 470 (30 abstention questions skipped per LongMemEval protocol)

## Background

MemPalace reported: raw 96.6%, AAAK 84.2% Recall@5 on LongMemEval.
We test our FTS5+BM25+OR-fallback retrieval against the same benchmark.

## Retrievers Tested

| Retriever | Description |
|---|---|
| flat-bm25 | LongMemEval standard BM25 baseline (rank_bm25 lib, whitespace tokenizer) |
| fts5-bm25 | Our FTS5+BM25 with trigram tokenizer (SQLite built-in) |
| fts5-or-fallback | FTS5+BM25 primary + instr() OR-match fallback (production path) |

## Results (Session-Level Retrieval)

### Recall_any@K (%)

| K | flat-bm25 | fts5-bm25 | fts5-or-fallback |
|---| --- | --- | --- |
| 1 | 71.4% | 75.4% | 75.4% |
| 3 | 84.2% | 88.1% | 88.1% |
| 5 | 88.5% | 90.5% | 90.5% |
| 10 | 92.6% | 94.0% | 94.0% |

### Recall_all@K (%)

| K | flat-bm25 | fts5-bm25 | fts5-or-fallback |
|---| --- | --- | --- |
| 1 | 18.1% | 18.6% | 18.6% |
| 3 | 65.4% | 69.2% | 69.2% |
| 5 | 74.0% | 76.4% | 76.4% |
| 10 | 81.9% | 85.4% | 85.4% |

### NDCG@K (%)

| K | flat-bm25 | fts5-bm25 | fts5-or-fallback |
|---| --- | --- | --- |
| 1 | 71.4% | 75.4% | 75.4% |
| 3 | 74.4% | 78.5% | 78.5% |
| 5 | 76.9% | 80.4% | 80.4% |
| 10 | 79.2% | 82.8% | 82.8% |

### Recall_any@5 by Question Type (LongMemEval_S)

| Type | flat-bm25 | fts5-bm25 | fts5-or-fallback |
|---|---|---|---|
| knowledge-update (n=72) | 98.6% | 98.6% | 98.6% |
| multi-session (n=121) | 90.1% | 92.6% | 92.6% |
| single-session-assistant (n=5) | 80.0% | 100.0% | 100.0% |
| single-session-preference (n=30) | 70.0% | 63.3% | 63.3% |
| single-session-user (n=64) | 93.8% | 93.8% | 93.8% |
| temporal-reasoning (n=127) | 83.5% | 88.2% | 88.2% |

### Oracle Dataset (only evidence sessions, no distractors)

All three retrievers achieve ~100% Recall@5 on `longmemeval_oracle.json`, confirming correctness. flat-bm25 Recall_any@5 = 100.0%, fts5-bm25 = 100.0%.

## Comparison with MemPalace

| System | Recall_any@5 |
|---|---|
| MemPalace raw | 96.6% |
| MemPalace AAAK | 84.2% |
| Our flat-bm25 | 88.5% |
| Our fts5-bm25 | 90.5% |
| Our fts5-or-fallback | 90.5% |

### Analysis

- **FTS5 trigram beats standard BM25 by +2.0pp** on Recall_any@5 (90.5% vs 88.5%). The trigram tokenizer provides better substring matching.
- **FTS5 wins big on temporal-reasoning** (+4.7pp) and multi-session (+2.5pp), likely due to better partial token matching.
- **FTS5 loses on single-session-preference** (-6.7pp). These questions ask about implicit preferences; trigram matching may over-match noise.
- **The OR-fallback never activates** on this English-only dataset -- FTS5 trigram handles English well. The fallback is designed for short CJK tokens (<3 chars) which don't appear here.
- **vs MemPalace**: MemPalace raw 96.6% used the full chat history (long-context approach, not retrieval). Our 90.5% is retrieval-only. MemPalace AAAK 84.2% used compressed summaries as retrieval keys -- our FTS5+BM25 at 90.5% already exceeds this, suggesting BM25 on raw text is a strong baseline that skeleton compression hurts.

## Limitations

1. **Not a direct CLSC comparison**: LongMemEval tests retrieval over raw chat sessions.
   Our closet stores CLSC skeletons (compressed summaries), not raw chat. A true CLSC
   benchmark would require first converting LongMemEval sessions to CLSC skeletons,
   then searching the skeletons.
2. **Session-level granularity only**: We test session-level retrieval (aggregating all
   user turns per session). Turn-level was not tested.
3. **No dense retrieval**: We only test BM25-family retrievers. LongMemEval also tests
   Contriever, Stella, and GTE (dense embedding models) which require GPU.
4. **No LLM evaluation**: QA accuracy evaluation requires OpenAI API (GPT-4o judge).
   We only measure retrieval recall, not end-to-end answer correctness.
5. **Oracle data used**: We test on `longmemeval_oracle.json` (only evidence sessions)
   for feasibility; and `longmemeval_s_cleaned.json` (full haystack) for realistic eval.

## Next Steps

1. Convert LongMemEval sessions to CLSC skeletons and re-run to measure skeleton vs raw retrieval gap
2. Add dense embedding retrieval (e.g., sentence-transformers) for comparison
3. Run QA evaluation with LLM judge if API key available
4. Test on LongMemEval_M (500 sessions per question) for harder difficulty
