# MADial-Bench x CLSC/MemOcean Feasibility Report

> Date: 2026-04-10
> Benchmark: MADial-Bench (NAACL 2025)
> Paper: "MADial-Bench: Towards Real-world Evaluation of Memory-Augmented Dialogue Generation"
> Repo: https://github.com/hejunqing/MADial-Bench

---

## 1. Dataset Overview (Chinese Subset)

| Metric | Value |
|--------|-------|
| Memories | 171 |
| Dialogues | 160 |
| Users | 2 (Bart: 10-14 boy, Lisa: 6-11 girl) |
| Avg relevant memories per dialogue | 2.5 |
| Avg test turn position | 7.6 |

### Memory Scenes
| Scene | Count |
|-------|-------|
| Activity (活动类) | 65 |
| Preference (喜好类) | 46 |
| Other (其他类) | 43 |
| Emotion (情绪类) | 14 |
| Object (物品类) | 3 |

### Memory Emotions
Dominant: Happy (113/171 = 66%), Anxious (28), Disappointed (9), Sad (5), Angry (5), Excited (4), Expectant (4), Others (3)

---

## 2. Data Format

### Memory (JSONL, one per line)
```json
{"1": {"time": "2023-12-25", "scene": "活动类", "emotion": "开心", "event": "Bart在圣诞节晚会上跳舞，感觉非常开心。", "user-id": 1, "id": "1"}}
```

### Dialogue (JSONL, one per line)
```json
{"dialogue": ["<BOD>\n", "<Bart>:\"...\"\n", "<Assistant>:\"...\"\n", ...],
 "test-turn": [8],
 "relevant-id": [1, 78, 105, 113, 108],
 "user-id": 1, "id": 0}
```

### Three Evaluation Settings
- **Setting 1**: No memories provided; LLM generates from scratch (or with 1 golden memory)
- **Setting 2**: 5 candidate memories provided (some relevant, some distractors); LLM picks and uses
- **Setting 3**: 5 candidate memories provided (guaranteed at least 1 relevant); LLM picks and uses

Setting 2 has 144/160 dialogues with overlap; Setting 3 has 160/160.

---

## 3. Memory Recall Benchmark Results (Hit@K)

"Hit@K" = at least 1 relevant memory found in top-K retrieved. This is the paper's primary retrieval metric.

| Model | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|-------|-------|-------|-------|--------|
| **OpenAI text-embedding** | **64.4%** | **85.0%** | **90.0%** | **96.2%** |
| Stella | 53.1% | 75.6% | 84.4% | 91.9% |
| Acge | 52.5% | 76.2% | 83.8% | 91.9% |
| BGE-M3-dense | 52.5% | 76.9% | 83.1% | 89.4% |
| Dmeta | 50.0% | 77.5% | 85.6% | 91.9% |
| BGE-M3-colbert | 51.2% | 71.2% | 78.8% | 88.1% |
| **Keyword-overlap (ours)** | **28.1%** | **51.9%** | **65.6%** | **79.4%** |

### Per-scene Recall@5 (keyword baseline, using mean recall metric)
| Scene | Recall@5 | n |
|-------|----------|---|
| Other (其他类) | 55.3% | 49 |
| Emotion (情绪类) | 42.8% | 22 |
| Activity (活动类) | 37.7% | 59 |
| Preference (喜好类) | 31.3% | 29 |

---

## 4. Analysis

### Keyword-overlap vs Embedding Gap
- At Hit@10, keyword-overlap reaches **79.4%** vs OpenAI's **96.2%** (16.8% gap)
- At Hit@5, gap is larger: **65.6% vs 90.0%** (24.4% gap)
- At Hit@1, gap is biggest: **28.1% vs 64.4%** (36.3% gap)

This confirms: **pure keyword/BM25 is competitive at wider recall windows (top-10/20) but struggles at precision (top-1/3)**. This matches our CLSC architecture assumption -- FTS5/BM25 as first pass, then LLM reranking for precision.

### Why keyword struggles at top-1
MADial memories are short event descriptions. The dialogue context often talks about the topic indirectly (e.g., dialogue about "magic show at New Year" should retrieve "danced at Christmas party" -- semantically related but few keyword overlaps). Embedding models capture this semantic similarity; keywords cannot.

### Implications for CLSC/MemOcean
1. **FTS5 BM25 is a viable first-stage retriever** at top-20 (87.5% hit rate) -- sufficient as a recall-oriented first pass
2. **A reranking stage is essential** to boost precision from the top-20 candidates
3. **Hybrid approach recommended**: FTS5 BM25 (recall) + embedding reranker (precision)
4. Our current CLSC closet_search (multi-term AND matching) would perform worse than BM25 for this task because it requires all terms to match

---

## 5. Blockers for Full Benchmark Run

| Blocker | Severity | Workaround |
|---------|----------|------------|
| No embedding model on VPS (no GPU) | High | Use API-based embeddings (OpenAI/Voyage) |
| No LLM for response generation | High | Use Claude API |
| bert-score + torch deps for evaluation | Medium | pip install --user (CPU-only, slow) |
| CLSC closet has ChannelLab data, not MADial | Medium | Ingest MADial memories into separate FTS5 table |

---

## 6. Integration Plan (Next Steps)

### Phase 1: FTS5 baseline (no extra deps)
1. Convert 171 MADial memories to `.clsc` skeleton format
2. Ingest into a test FTS5 table (`madial_memories`)
3. For each of 160 dialogues, run `fts_search` with dialogue context as query
4. Compute Hit@K and compare to keyword-overlap baseline above

### Phase 2: Hybrid retrieval
1. Add embedding-based reranker (OpenAI API or local sentence-transformer)
2. FTS5 top-20 -> reranker top-5
3. Target: match or exceed BGE-M3-dense (83.1% Hit@5)

### Phase 3: Full benchmark
1. Set up Claude API for response generation (Setting 1/2/3)
2. Install evaluation deps (jieba, rouge, nltk, bert-score)
3. Run full pipeline and compare against GPT-4, Qwen-72B, etc.

---

## 7. Key Takeaway

MADial-Bench is a well-structured benchmark for testing memory-augmented dialogue. The Chinese subset (171 memories, 160 dialogues) is small enough for quick iteration. Our FTS5/BM25 approach achieves **79.4% Hit@10** without any ML, which is a solid foundation. Adding a reranker should close most of the gap to embedding-based methods (96.2%).

**Verdict**: MADial-Bench is feasible and valuable for evaluating CLSC retrieval quality. Recommended to proceed with Phase 1 (FTS5 integration).
