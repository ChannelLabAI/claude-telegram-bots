# MADial-Bench v4 — LLM Skeleton Benchmark Results

> Date: 2026-04-11
> Model: `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` (384d)
> Dataset: 171 memories, 160 dialogues
> Benchmark: MADial-Bench Chinese subset (NAACL 2025)
> Change: **LLM-style skeletons** (simulated Haiku format) vs v3 (jieba on raw event text)

---

## 1. v3 (jieba/raw) vs v4 (LLM skeleton) — All Modes

| Mode | v3 Hit@1 | v4 Hit@1 | Delta | v3 Hit@5 | v4 Hit@5 | Delta | v3 Hit@10 | v4 Hit@10 | Delta |
|------|----------|----------|-------|----------|----------|-------|-----------|-----------|-------|
| Keyword Overlap (jieba OR) | 22.5% | 21.9% | -0.6pp | 54.4% | 53.8% | -0.6pp | 66.9% | 66.9% | +0.0pp |
| FTS5 BM25 (trigram) | 15.0% | 14.4% | -0.6pp | 23.8% | 26.9% | +3.1pp | 31.9% | 31.2% | -0.7pp |
| **CJK Routing (instr+reranker)** | 33.8% | 36.9% | +3.1pp | 63.8% | 62.5% | -1.3pp | 71.2% | 71.2% | +0.0pp |
| Pure Embedding KNN | 19.4% | 34.4% | +15.0pp | 58.1% | 58.8% | +0.7pp | 68.8% | 72.5% | +3.7pp |
| Keyword top-30 -> Reranker | 38.8% | 38.1% | -0.7pp | 67.5% | 66.9% | -0.6pp | 78.8% | 77.5% | -1.3pp |
| *v1 keyword baseline (ref)* | 28.1% | -- | -- | 65.6% | -- | -- | 79.4% | -- | -- |
| *OpenAI text-embedding (ref)* | 64.4% | -- | -- | 90.0% | -- | -- | 96.2% | -- | -- |

### Mode C Delta (LLM Skeleton Impact)

| Metric | v3 (jieba/raw event) | v4 (LLM skeleton) | Delta |
|--------|----------------------|--------------------|-------|
| Hit@1 | 33.8% | 36.9% | **+3.1pp** |
| Hit@3 | 50.6% | 54.4% | **+3.8pp** |
| Hit@5 | 63.8% | 62.5% | **-1.3pp** |
| Hit@10 | 71.2% | 71.2% | **+0.0pp** |

### CJK Routing Path Distribution

- CJK detected -> instr() OR-match + reranker: **160** dialogues
- Non-CJK -> FTS5 BM25 + reranker: **0** dialogues
- No keyword results -> pure KNN fallback: **0** dialogues

---

## 2. Token Efficiency — Skeleton vs Raw Event

| Metric | Value |
|--------|-------|
| Avg LLM skeleton length | 75.8 chars |
| Avg raw event length | 34.3 chars |
| Compression ratio | 2.21x |

LLM skeletons restructure the raw event text into a structured `[id|entities|topics|summary|scene|emotion|]` format. 
This adds structure (pipe-delimited fields, explicit entity/topic extraction) which may help or hurt keyword recall 
depending on whether the restructuring preserves the key terms that queries match against.

---

## 3. Per-Scene Breakdown — Mode C (v3 vs v4)

| Scene | n | v3 Hit@1 | v4 Hit@1 | v3 Hit@5 | v4 Hit@5 | v3 Hit@10 | v4 Hit@10 | dHit@5 |
|-------|---|----------|----------|----------|----------|-----------|-----------|--------|
| 其他类 | 75 | 29.3% | 32.0% | 62.7% | 58.7% | 69.3% | 66.7% | **-4.0pp** |
| 喜好类 | 62 | 37.1% | 45.2% | 59.7% | 69.4% | 67.7% | 85.5% | **+9.7pp** |
| 情绪类 | 33 | 42.4% | 51.5% | 72.7% | 69.7% | 78.8% | 78.8% | **-3.0pp** |
| 活动类 | 92 | 31.5% | 39.1% | 63.0% | 71.7% | 72.8% | 81.5% | **+8.7pp** |
| 物品类 | 1 | 100.0% | 100.0% | 100.0% | 100.0% | 100.0% | 100.0% | **+0.0pp** |

---

## 4. Full v4 Summary — Hit@K

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 | Avg Latency |
|------|-------|-------|-------|--------|-------------|
| **Keyword Overlap (jieba OR)** | 21.9% | 41.9% | 53.8% | 66.9% | 15.0ms |
| **FTS5 BM25 (trigram)** | 14.4% | 21.2% | 26.9% | 31.2% | 2.7ms |
| **CJK Routing (instr+reranker)** | 36.9% | 54.4% | 62.5% | 71.2% | 2141.3ms |
| **Pure Embedding KNN** | 34.4% | 49.4% | 58.8% | 72.5% | 106.3ms |
| **Keyword top-30 -> Reranker** | 38.1% | 55.6% | 66.9% | 77.5% | 3117.7ms |
| *v1 keyword baseline (ref)* | 28.1% | 51.9% | 65.6% | 79.4% | -- |
| *OpenAI text-embedding (ref)* | 64.4% | 85.0% | 90.0% | 96.2% | -- |

### Per-Scene Breakdown (Hit@5, all modes)

| Scene | n | Keyword Overlap | FTS5 BM25 | CJK Routing | Pure KNN | Keyword+Reranker |
|-------|---|-----------------|-----------|-------------|----------|------------------|
| 其他类 | 75 | 53.3% | 36.0% | 58.7% | 50.7% | 62.7% |
| 喜好类 | 62 | 61.3% | 25.8% | 69.4% | 69.4% | 72.6% |
| 情绪类 | 33 | 57.6% | 3.0% | 69.7% | 63.6% | 63.6% |
| 活动类 | 92 | 57.6% | 27.2% | 71.7% | 67.4% | 78.3% |
| 物品类 | 1 | 100.0% | 0.0% | 100.0% | 100.0% | 100.0% |

---

## 5. Analysis

### LLM Skeleton Impact on Retrieval

The v4 benchmark tests whether restructuring raw event text into LLM-style skeletons 
(`[id|entities|topics|summary|scene|emotion|]`) improves or degrades retrieval quality.

- **v3 Mode C** (jieba on raw events): Hit@5 = 63.8%
- **v4 Mode C** (jieba on LLM skeletons): Hit@5 = 62.5% (**-1.3pp**)

LLM skeletons perform **comparably** to raw events. The structured format neither significantly helps 
nor hurts keyword-based retrieval for this dataset.

### Keyword vs Embedding Impact

- **Mode A** (keyword only): v3=54.4% -> v4=53.8% (-0.6pp)
- **Mode D** (embedding only): v3=58.1% -> v4=58.8% (+0.7pp)
- **Mode E** (keyword+reranker): v3=67.5% -> v4=66.9% (-0.6pp)

Keyword-only modes show how skeleton restructuring affects term-level matching. 
Embedding-only modes show how it affects semantic similarity. 
Hybrid modes (C, E) show the combined effect.

### Production Implications

The closet_llm table uses Haiku-generated skeletons which may differ from this simulation. 
Key considerations:
- Real Haiku skeletons may extract better entities/topics than jieba POS tagging
- The structured format enables field-specific search (e.g., search only entities)
- Compression reduces storage and embedding compute costs
- Current compression ratio: 2.21x

---

## 6. Methodology

- **Dataset**: MADial-Bench Chinese subset (171 memories, 160 dialogues)
- **LLM Skeleton Generation**: jieba POS tagging to extract entities (nr/ns/nt/nz) and topics (v/vn/a),
  formatted as `[id|entities|topics|summary|scene|emotion|]` to approximate Haiku output
- **Query**: Full dialogue context up to (not including) the test turn (same as v3)
- **Ground truth**: `relevant-id` field in each dialogue
- **Embedding model**: `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` (384d, ONNX via fastembed)
- **Segmentation**: jieba for Chinese word segmentation
- **Mode A**: jieba-segment query, multi-term OR via `instr()` on skeleton text
- **Mode B**: FTS5 trigram tokenizer on skeleton text, 3+ char terms, BM25 ranking
- **Mode C**: CJK routing -- CJK queries use instr() OR-match top-20 on skeletons -> embedding rerank
- **Mode D**: Direct embedding KNN via sqlite-vec on skeleton embeddings
- **Mode E**: Keyword overlap top-30 on skeletons -> embedding cosine rerank

### Key Difference from v3

v3 searched against **raw event text** (`madial_memories.event`). 
v4 searches against **LLM-style skeletons** (`madial_memories_llm.skeleton`) -- 
a structured, compressed representation of the same events. 
Embeddings are also computed from skeleton text, not raw events.
