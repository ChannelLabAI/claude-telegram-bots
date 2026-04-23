# Haiku LLM Reranker Test — MADial-Bench Results

> Date: 2026-04-10 16:23
> Model: `claude-haiku-4-5-20251001`
> Pipeline: keyword top-20 -> Haiku rerank
> Dataset: 171 memories, 160 dialogues

---

## 1. Hit@K Results

| Method | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|--------|-------|-------|-------|--------|
| **Haiku reranker** | **57.5%** | **67.5%** | **71.9%** | **75.6%** |
| v4_C_cjk_routing | 36.9% | 54.4% | 62.5% | 71.2% |
| v4_E_keyword_reranked | 38.1% | 55.6% | 66.9% | 77.5% |
| v1_keyword_baseline | 28.1% | 51.9% | 65.6% | 79.4% |
| openai_text_embedding | 64.4% | 85.0% | 90.0% | 96.2% |

### Delta vs best previous (Hit@5)

- Previous best (keyword+reranker): 90.0%
- Haiku reranker: 71.9%
- Delta: **-18.1pp**

---

## 2. Per-Scene Breakdown (Hit@5)

| Scene | n | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|-------|---|-------|-------|-------|--------|
| 其他类 | 49 | 55.1% | 57.1% | 57.1% | 59.2% |
| 喜好类 | 29 | 44.8% | 62.1% | 79.3% | 79.3% |
| 情绪类 | 22 | 59.1% | 77.3% | 77.3% | 77.3% |
| 活动类 | 59 | 64.4% | 74.6% | 78.0% | 86.4% |
| 物品类 | 1 | 100.0% | 100.0% | 100.0% | 100.0% |

---

## 3. Cost & Latency

| Metric | Value |
|--------|-------|
| Input tokens | 212,222 |
| Output tokens | 6,521 |
| Total tokens | 218,743 |
| Input cost | $0.2122 |
| Output cost | $0.0326 |
| **Total cost** | **$0.2448** |
| Avg latency per call | 1299ms |
| Total latency | 207.8s |
| Errors | 0 |
| Recall failures (0 candidates) | 0 |

---

## 4. Methodology

1. For each dialogue, extract keywords via jieba from context up to test-turn
2. Keyword OR-match (`instr()`) against 171 memory event texts -> top-20 candidates
3. Send candidates + dialogue context to `claude-haiku-4-5-20251001` for reranking
4. Parse Haiku's ranked output, compute Hit@K against ground truth
5. Rate limited to ~3 req/s

