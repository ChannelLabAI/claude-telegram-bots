# v5: Hybrid Recall + Haiku Reranker — MADial-Bench Results

> Date: 2026-04-11 14:29
> Model: `claude-haiku-4-5-20251001`
> Embedding: `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2`
> Pipeline: keyword top-20 + embedding top-20 -> merge dedup -> Haiku rerank
> Dataset: 171 memories, 160 dialogues

---

## 1. Hit@K Results — Full Comparison

| Method | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|--------|-------|-------|-------|--------|
| **v5 hybrid+Haiku (this)** | **68.1%** | **81.9%** | **86.2%** | **90.6%** |
| v3_keyword+Haiku | 57.5% | 67.5% | 71.9% | 75.6% |
| v4_D_pure_embedding_KNN | 34.4% | 49.4% | 58.8% | 72.5% |
| v4_E_keyword+MiniLM_reranker | 38.1% | 55.6% | 66.9% | 77.5% |
| v4_C_cjk_routing | 36.9% | 54.4% | 62.5% | 71.2% |
| v1_keyword_baseline | 28.1% | 51.9% | 65.6% | 79.4% |
| openai_text_embedding | 64.4% | 85.0% | 90.0% | 96.2% |

### Delta vs v3 (keyword-only + Haiku)

- v3 keyword+Haiku: 71.9%
- v5 hybrid+Haiku: 86.2%
- Delta: **+14.3pp**

---

## 2. Recall Pool Analysis (before Haiku rerank)

| Source | Hit@1 | Hit@3 | Hit@5 | Hit@10 | Hit@20 |
|--------|-------|-------|-------|--------|--------|
| Keyword top-20 | 22.5% | 41.9% | 54.4% | 66.9% | -- |
| Embedding top-20 | 37.5% | 55.6% | 68.1% | 78.8% | -- |
| Hybrid merged | 22.5% | 41.9% | 54.4% | 66.9% | -- |

### Candidate Pool Stats

- Avg pool size after merge: **33.9** candidates
- Min/Max: 27 / 40
- Avg overlap (keyword & embedding): 6.1
- GT in merged pool: **152/160** (95.0%)

### Source of Ground Truth IDs

- In keyword recall only: 47
- In embedding recall only: **104** (NEW recalls from embedding)
- In both: 170

---

## 3. Per-Scene Breakdown

| Scene | n | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|-------|---|-------|-------|-------|--------|
| 其他类 | 49 | 63.3% | 77.6% | 77.6% | 77.6% |
| 喜好类 | 29 | 48.3% | 65.5% | 79.3% | 86.2% |
| 情绪类 | 22 | 77.3% | 90.9% | 100.0% | 100.0% |
| 活动类 | 59 | 78.0% | 89.8% | 91.5% | 100.0% |
| 物品类 | 1 | 100.0% | 100.0% | 100.0% | 100.0% |

---

## 4. Cost & Latency

| Metric | Value |
|--------|-------|
| Input tokens | 314,009 |
| Output tokens | 11,170 |
| Total tokens | 325,179 |
| Input cost | $0.3140 |
| Output cost | $0.0558 |
| **Total cost** | **$0.3699** |
| Avg latency per Haiku call | 1557ms |
| Total Haiku latency | 249.2s |
| Embedding build time | 6.4s |
| Errors | 0 |
| Recall failures | 0 |

---

## 5. Methodology

```
Query -> keyword instr() OR top-20 + embedding KNN top-20 -> merge dedup -> Haiku rerank -> top-K
```

1. For each dialogue, extract query from context up to test-turn
2. **Keyword recall**: jieba segmentation -> instr() OR-match on 171 memory events -> top-20
3. **Embedding recall**: fastembed MiniLM -> cosine KNN on 171 memory embeddings -> top-20
4. **Merge**: union both candidate sets, dedup by memory ID (keyword-first order)
5. **Haiku rerank**: send merged candidates + dialogue context to `claude-haiku-4-5-20251001` for relevance ranking
6. Compute Hit@K against ground truth `relevant-id`

