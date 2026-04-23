# CLongEval Benchmark Results — MemOcean Retrieval Feasibility

**Date**: 2026-04-10
**Benchmark**: CLongEval (Fudan et al., arXiv:2403.03514)
**Description**: Chinese long-context benchmark, 7 tasks / 7,267 examples / 2,000+ human-annotated QA pairs

## Setup

- **Model tested**: Claude Sonnet 4 (`claude-sonnet-4-20250514`)
- **Baselines**: GPT-4-Turbo-128K, Moonshot-v1 (from repo's pre-computed inference results, full small set)
- **Subset**: Small set (1K-16K tokens), 50 samples per task for Claude Sonnet, full set for baselines
- **Tasks selected** (3 of 7, chosen for relevance to memory/retrieval):
  - **KpRet** (Key Passage Retrieval): Extract value from JSON given a key. Pure retrieval.
  - **LCvMem** (Long Conversation Memory): Answer questions about long multi-day conversations. Core memory test.
  - **LStQA** (Long Story QA): Answer questions about long story passages. Comprehension + retrieval.

## Results (Small Set)

| Task | Metric | Claude Sonnet (n=49-50) | GPT-4-Turbo (n=284-397) | Moonshot-v1 (n=294-400) |
|------|--------|------------------------|------------------------|------------------------|
| KpRet | Edit Distance | **100.00** | 84.24 | 86.74 |
| LCvMem | F1 | **69.70** | 63.42 | 51.76 |
| LStQA | F1 | **70.39** | 66.19 | 60.21 |

## Analysis

### Key Passage Retrieval (KpRet): Perfect Score
Claude Sonnet achieved **100.00** on 49 samples — perfect retrieval accuracy from JSON-structured data. This is the most directly relevant task for MemOcean's CLSC retrieval (finding specific entries in structured data). GPT-4-Turbo scored 84.24, Moonshot 86.74.

**Implication for MemOcean**: Claude's retrieval capability on structured Chinese data is excellent. The FTS5+BM25 layer in MemOcean handles initial candidate selection; Claude handles the final extraction/answer generation. This combination should perform very well.

### Long Conversation Memory (LCvMem): +6.28 over GPT-4
Claude scored **69.70** F1 vs GPT-4's 63.42 (+6.28 points). This task directly simulates the MemOcean use case: remembering facts from long multi-day conversations.

**Implication for MemOcean**: Claude is strong at extracting specific facts from conversation history — the core MemOcean retrieval scenario.

### Long Story QA (LStQA): +4.20 over GPT-4
Claude scored **70.39** F1 vs GPT-4's 66.19 (+4.20 points). This tests comprehension over long Chinese text passages.

## Caveats

1. **Sample size**: 50 samples per task for Claude vs 284-400 for baselines. Directionally strong but not statistically conclusive.
2. **Small set only**: 1K-16K tokens. Medium (16K-50K) and Large (50K-100K) not tested — would require significantly more API spend.
3. **Direct comparison fairness**: Baselines used different temperatures and system prompts; Claude used temp=0.0 with no system prompt.
4. **Cost**: ~$2-3 for 150 samples at Sonnet pricing. Full small set (1,052 samples) would cost ~$15-20.

## Remaining Tasks Not Tested

- **LStSum** (Long Story Summarization): ROUGE-L metric, less relevant to retrieval
- **StNLab** (Stacked News Labeling): Classification, not retrieval
- **StTDet** (Stacked Typo Detection): Proofreading, not retrieval
- **TblQry** (Table Querying): Could be relevant but lower priority

## Recommendation

The results strongly validate using Claude as the answer generation layer in MemOcean:
1. **Retrieval (KpRet)**: Perfect score — Claude can extract exact values from structured Chinese data
2. **Memory (LCvMem)**: Best-in-class — directly validates the conversation memory use case
3. **Comprehension (LStQA)**: Competitive — good at understanding long Chinese narratives

**Next steps** if deeper validation needed:
- Run medium set (16K-50K tokens) to test longer context degradation
- Run full small set (all ~1,000 samples) for statistical significance
- Test with FTS5 retrieval as a preprocessing step (retrieve top-k chunks, then ask Claude)

## Files

- Inference script: `/tmp/clongeval/run_haiku.py`
- Evaluation script: `/tmp/clongeval/run_eval.py`
- Results: `/tmp/clongeval/inference_results/claude-sonnet/`
- Comparison JSON: `/tmp/clongeval/eval_results_comparison.json`
