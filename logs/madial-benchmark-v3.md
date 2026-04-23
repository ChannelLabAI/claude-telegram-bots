# MADial-Bench v3 — CJK Routing Verification Results

> Date: 2026-04-10
> Model: `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` (384d)
> Dataset: 171 memories, 160 dialogues
> Benchmark: MADial-Bench Chinese subset (NAACL 2025)
> Change: **CJK routing** — CJK queries skip FTS5, use instr() OR-match top-20 -> embedding reranker

---

## 1. v2 vs v3 Comparison — All Modes

| Mode | v2 Hit@1 | v3 Hit@1 | v2 Hit@3 | v3 Hit@3 | v2 Hit@5 | v3 Hit@5 | v2 Hit@10 | v3 Hit@10 |
|------|----------|----------|----------|----------|----------|----------|-----------|-----------|
| Keyword Overlap (jieba OR) | 22.5% | 22.5% | 41.9% | 41.9% | 54.4% | 54.4% | 66.9% | 66.9% |
| FTS5 BM25 (trigram) | 15.0% | 15.0% | 20.6% | 20.6% | 23.8% | 23.8% | 31.9% | 31.9% |
| **CJK Routing (instr+reranker for CJK, FTS5+reranker for non-CJK)** | 20.0% | 33.8% | 29.4% | 50.6% | 31.9% | 63.8% | 40.0% | 71.2% |
| Pure Embedding KNN | 19.4% | 19.4% | 45.0% | 45.0% | 58.1% | 58.1% | 68.8% | 68.8% |
| Keyword top-20 → Embedding Reranker | 38.8% | 38.8% | 53.8% | 53.8% | 67.5% | 67.5% | 78.8% | 78.8% |
| *v1 keyword baseline (ref)* | 28.1% | -- | 51.9% | -- | 65.6% | -- | 79.4% | -- |
| *OpenAI text-embedding (ref)* | 64.4% | -- | 85.0% | -- | 90.0% | -- | 96.2% | -- |

### Mode C Delta (CJK Routing Impact)

| Metric | v2 (FTS5+instr+Reranker) | v3 (CJK Routing) | Delta |
|--------|--------------------------|-------------------|-------|
| Hit@1 | 20.0% | 33.8% | **+13.8pp** |
| Hit@3 | 29.4% | 50.6% | **+21.2pp** |
| Hit@5 | 31.9% | 63.8% | **+31.9pp** |
| Hit@10 | 40.0% | 71.2% | **+31.2pp** |

### CJK Routing Path Distribution

- CJK detected -> instr() OR-match + reranker: **160** dialogues
- Non-CJK -> FTS5 BM25 + reranker: **0** dialogues
- No keyword results -> pure KNN fallback: **0** dialogues

---

## 2. Per-Scene Breakdown — Mode C (v2 vs v3)

| Scene | n | v2 Hit@1 | v3 Hit@1 | v2 Hit@5 | v3 Hit@5 | v2 Hit@10 | v3 Hit@10 | dHit@5 |
|-------|---|----------|----------|----------|----------|-----------|-----------|--------|
| 其他类 | 75 | 20.0% | 28.0% | 36.0% | 54.7% | 46.7% | 66.7% | **+18.7pp** |
| 喜好类 | 62 | 25.8% | 40.3% | 33.9% | 74.2% | 41.9% | 82.3% | **+40.3pp** |
| 情绪类 | 33 | 12.1% | 45.5% | 12.1% | 75.8% | 18.2% | 78.8% | **+63.7pp** |
| 活动类 | 92 | 20.7% | 37.0% | 30.4% | 69.6% | 39.1% | 79.3% | **+39.2pp** |
| 物品类 | 1 | 0.0% | 100.0% | 0.0% | 100.0% | 0.0% | 100.0% | **+100.0pp** |

---

## 3. Full v3 Summary — Hit@K

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 | Avg Latency |
|------|-------|-------|-------|--------|-------------|
| **Keyword Overlap (jieba OR)** | 22.5% | 41.9% | 54.4% | 66.9% | 9.3ms |
| **FTS5 BM25 (trigram)** | 15.0% | 20.6% | 23.8% | 31.9% | 2.3ms |
| **CJK Routing (instr+reranker for CJK, FTS5+reranker for non-CJK)** | 33.8% | 50.6% | 63.8% | 71.2% | 1720.9ms |
| **Pure Embedding KNN** | 19.4% | 45.0% | 58.1% | 68.8% | 84.2ms |
| **Keyword top-20 → Embedding Reranker** | 38.8% | 53.8% | 67.5% | 78.8% | 2563.8ms |
| *v1 keyword baseline (ref)* | 28.1% | 51.9% | 65.6% | 79.4% | -- |
| *OpenAI text-embedding (ref)* | 64.4% | 85.0% | 90.0% | 96.2% | -- |

### Per-Scene Breakdown (Hit@5, all modes)

| Scene | n | Keyword Overlap | FTS5 BM25 | CJK Routing | Pure KNN | Keyword+Reranker |
|-------|---|-----------------|-----------|-------------|----------|------------------|
| 其他类 | 75 | 53.3% | 33.3% | 54.7% | 48.0% | 60.0% |
| 喜好类 | 62 | 61.3% | 21.0% | 74.2% | 56.5% | 75.8% |
| 情绪类 | 33 | 57.6% | 3.0% | 75.8% | 87.9% | 72.7% |
| 活动类 | 92 | 58.7% | 22.8% | 69.6% | 64.1% | 77.2% |
| 物品类 | 1 | 100.0% | 0.0% | 100.0% | 100.0% | 100.0% |

---

## 4. Analysis

### CJK Routing Impact

The CJK routing fix changes Mode C from FTS5-based recall to instr() OR-match for Chinese queries.
Since all 160 MADial-Bench queries are Chinese, **100% of queries now take the instr() path**.

- **v2 Mode C** (FTS5+instr+Reranker): Hit@5 = 31.9%
- **v3 Mode C** (CJK Routing): Hit@5 = 63.8% (**+31.9pp**)
- **Mode E** (Keyword+Reranker, top-30): Hit@5 = 67.5%
- **Mode D** (Pure KNN): Hit@5 = 58.1%

Mode C v3 shows significant improvement from CJK routing, confirming that FTS5 trigram was the bottleneck.

### Why Mode C and Mode E May Differ Slightly

- Mode C uses `extract_keywords(max_terms=20)` for recall, Mode E uses `extract_keywords(max_terms=30)` with `recall_limit=30`
- This wider recall window in Mode E may capture more relevant candidates for the reranker
- The core mechanism is identical: jieba instr() OR-match -> embedding cosine rerank

### Architecture Validation

The CJK routing fix validates the v2 recommendation:
- FTS5 trigram is **unsuitable** for Chinese recall (Hit@5 = 23.8%)
- jieba instr() OR-match is the correct recall method for CJK text
- Embedding reranker adds value on top of keyword recall
- Production closet_search with CJK routing now achieves Hit@5 = 63.8% (vs 90.0% OpenAI ceiling)

### Latency

| Mode | v2 Latency | v3 Latency |
|------|------------|------------|
| Keyword Overlap (jieba OR) | 8.9ms | 9.3ms |
| FTS5 BM25 (trigram) | 2.2ms | 2.3ms |
| CJK Routing (instr+reranker for CJK, FTS5+reranker for non-CJK) | 1680.8ms | 1720.9ms |
| Pure Embedding KNN | 80.3ms | 84.2ms |
| Keyword top-20 → Embedding Reranker | 2475.1ms | 2563.8ms |

---

## 5. Methodology

- **Dataset**: MADial-Bench Chinese subset (171 memories, 160 dialogues)
- **Database**: Reused from v2 run (no re-ingestion)
- **Query**: Full dialogue context up to (not including) the test turn
- **Ground truth**: `relevant-id` field in each dialogue
- **Embedding model**: `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` (384d, ONNX via fastembed)
- **Segmentation**: jieba for Chinese word segmentation
- **Mode A**: jieba-segment query, multi-term OR via `instr()`, ranked by match_count
- **Mode B**: FTS5 trigram tokenizer, 3+ char terms OR-joined, BM25 ranking
- **Mode C (CHANGED)**: CJK routing — if query has CJK chars, skip FTS5 and use instr() OR-match top-20 -> embedding cosine rerank; if non-CJK, FTS5 top-20 -> rerank; pure KNN fallback if recall=0
- **Mode D**: Direct embedding KNN via sqlite-vec, no keyword filtering
- **Mode E**: Keyword overlap top-30 recall -> embedding cosine rerank to top-K; KNN fallback if keywords return 0
