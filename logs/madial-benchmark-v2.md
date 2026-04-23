# MADial-Bench v2 — CLSC Retrieval Benchmark Results

> Date: 2026-04-10
> Model: `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` (384d)
> Dataset: 171 memories, 160 dialogues
> Benchmark: MADial-Bench Chinese subset (NAACL 2025)

---

## 1. Summary — Hit@K Comparison

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 | Avg Latency |
|------|-------|-------|-------|--------|-------------|
| **Keyword Overlap (jieba OR)** | 22.5% | 41.9% | 54.4% | 66.9% | 8.9ms |
| **FTS5 BM25 (trigram)** | 15.0% | 20.6% | 23.8% | 31.9% | 2.2ms |
| **FTS5+instr → Embedding Reranker** | 20.0% | 29.4% | 31.9% | 40.0% | 1680.8ms |
| **Pure Embedding KNN** | 19.4% | 45.0% | 58.1% | 68.8% | 80.3ms |
| **Keyword top-20 → Embedding Reranker** | 38.8% | 53.8% | 67.5% | 78.8% | 2475.1ms |
| *Prev keyword baseline v1 (ref)* | 28.1% | 51.9% | 65.6% | 79.4% | -- |
| *OpenAI text-embedding (ref)* | 64.4% | 85.0% | 90.0% | 96.2% | -- |

### Delta from Keyword Overlap Baseline (Mode A)

| Mode | dHit@1 | dHit@3 | dHit@5 | dHit@10 |
|------|--------|--------|--------|---------|
| FTS5 BM25 (trigram) | -7.5 | -21.3 | -30.6 | -35.0 |
| FTS5+instr → Embedding Reranker | -2.5 | -12.5 | -22.5 | -26.9 |
| Pure Embedding KNN | -3.1 | +3.1 | +3.7 | +1.9 |
| Keyword top-20 → Embedding Reranker | +16.3 | +11.9 | +13.1 | +11.9 |

### Mode C Fallback Path Distribution

- FTS5 BM25 had results (primary path): **160** dialogues
- FTS5 returned 0, instr OR fallback used: **0** dialogues
- Both FTS5 + instr returned 0, pure KNN fallback: **0** dialogues

---

## 2. Per-Scene Breakdown (Hit@5)

| Scene | n | Keyword Overlap | FTS5 BM25 | FTS5+Reranker | Pure KNN | Keyword+Reranker |
|-------|---|-----------------|-----------|---------------|----------|------------------|
| 其他类 | 75 | 53.3% | 33.3% | 36.0% | 48.0% | 60.0% |
| 喜好类 | 62 | 61.3% | 21.0% | 33.9% | 56.5% | 75.8% |
| 情绪类 | 33 | 57.6% | 3.0% | 12.1% | 87.9% | 72.7% |
| 活动类 | 92 | 58.7% | 22.8% | 30.4% | 64.1% | 77.2% |
| 物品类 | 1 | 100.0% | 0.0% | 0.0% | 100.0% | 100.0% |

### Full Per-Scene x Per-K (Mode C: BM25+Reranker)

| Scene | n | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|-------|---|-------|-------|-------|--------|
| 其他类 | 75 | 20.0% | 33.3% | 36.0% | 46.7% |
| 喜好类 | 62 | 25.8% | 30.6% | 33.9% | 41.9% |
| 情绪类 | 33 | 12.1% | 12.1% | 12.1% | 18.2% |
| 活动类 | 92 | 20.7% | 29.3% | 30.4% | 39.1% |
| 物品类 | 1 | 0.0% | 0.0% | 0.0% | 0.0% |

---

## 3. Reranker Impact -- Example Queries

The embedding reranker improved Hit@5 over keyword-only in **33** dialogues.

### Example 1 (dialogue 10, scene: 活动类)
- **Query**: <Lisa>:"昨天我帮助我的同学写作业，我感觉挺开心的！" <Assistant>:"这真是太好了！帮助别人总能带来快乐，你最喜欢哪部分呢？" <Lisa>:"我喜欢解释数学问题，当他们明白后，看起来好高兴！" <Assistant>:"...
- **Relevant IDs**: ['11', '10']
- **Keyword top-5**: ['30', '24', '127', '20', '25']
- **Reranked top-5**: ['30', '23', '132', '10', '125']

### Example 2 (dialogue 14, scene: 活动类, 其他类)
- **Query**: <Lisa>:"昨天我和爸爸下棋，我赢了一盘耶！" <Assistant>:"真是太棒了！下棋可以锻炼思考能力。你喜欢下哪种棋呢？" <Lisa>:"我最喜欢国际象棋了，因为里面的马可以跳得好高！" <Assistant>:"国际象棋的马确...
- **Relevant IDs**: ['15', '145', '144', '152', '102']
- **Keyword top-5**: ['58', '79', '92', '54', '109']
- **Reranked top-5**: ['77', '87', '144', '74', '123']

### Example 3 (dialogue 21, scene: 活动类, 情绪类)
- **Query**: <Bart>:"为什么今天学校里的同学都不和我玩呢？" <Assistant>:"哎呀，那感觉一定很不好吧。要知道，有时候大家可能只是想要一点个人空间。" <Bart>:"但是我感觉他们不喜欢我，我做错了什么吗？" <Assistant>:...
- **Relevant IDs**: ['63', '61', '54', '66', '64']
- **Keyword top-5**: ['20', '30', '107', '142', '44']
- **Reranked top-5**: ['68', '63', '169', '66', '64']

### Example 4 (dialogue 23, scene: 活动类, 情绪类, 其他类)
- **Query**: <Lisa>:"我今天考试没考好，感觉自己好笨。" <Assistant>:"哎呀，没事的，考试偶尔不如意很正常。你记得哪些题目难住你了吗？" <Lisa>:"主要是数学题，我总是算不出来。" <Assistant>:"数学题目有时候挺复杂...
- **Relevant IDs**: ['163', '86', '47', '90', '52']
- **Keyword top-5**: ['79', '87', '101', '141', '145']
- **Reranked top-5**: ['52', '37', '90', '87', '81']

### Example 5 (dialogue 29, scene: 喜好类, 活动类)
- **Query**: <Bart>:"我今天在班上被老师问为什么抄作业，我好难过。" <Assistant>:"哎呀，这的确是一个难过的时刻。发生了什么让你觉得需要抄作业呢？" <Bart>:"因为我做不完，我怕没有完成作业被批评。" <Assistant>:"...
- **Relevant IDs**: ['51', '55', '38', '78', '91']
- **Keyword top-5**: ['30', '54', '60', '61', '66']
- **Reranked top-5**: ['68', '67', '49', '66', '91']

---

## 4. Analysis

### Key Findings

1. **Keyword + Reranker (Mode E) achieves Hit@5 = 67.5%**, Hit@10 = 78.8%.
2. **FTS5 + Reranker (Mode C) achieves Hit@5 = 31.9%**, limited by FTS5 trigram recall quality for Chinese.
3. **Pure KNN (Mode D) achieves Hit@5 = 58.1%** -- this is the `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` model's ceiling.
4. **vs OpenAI embedding**: Best mode is +67.5% vs 90.0% (-22.5pp gap).
5. **vs Previous v1 keyword baseline**: Mode E is +1.9pp at Hit@5 (v1: 65.6%).

### Architecture Validation

The hybrid keyword+embedding architecture is validated, but the **recall source matters enormously**:
- Keyword overlap (jieba instr): Hit@10=66.9% -- good recall for Chinese
- FTS5 BM25 (trigram): Hit@10=31.9% -- poor recall due to trigram limitations
- **Keyword + Reranker (Mode E)**: Hit@1=38.8%, Hit@5=67.5%, Hit@10=78.8%
- **FTS5 + Reranker (Mode C)**: Hit@1=20.0%, Hit@5=31.9%, Hit@10=40.0%
- Reranker boost over keyword-only: +16.3pp at Hit@1, +13.1pp at Hit@5
- Pure KNN (Mode D): Hit@5=58.1% -- embedding ceiling for this model

### FTS5 Trigram Limitation for Chinese

The trigram tokenizer requires 3+ Chinese characters per term. Many common Chinese words
are 2 characters (e.g., 跳舞, 游泳, 画画), which cannot be used as FTS5 query terms.
While FTS5 returns results for most queries (via 3+ char terms), the results are noisy --
trigram matching on Chinese characters produces many false positive matches on common
character combinations, diluting BM25 scores. This makes FTS5 trigram **unsuitable as**
**the primary recall method for Chinese memory retrieval**.

**Recommendation**: For Chinese text, use jieba-segmented keyword overlap (instr) as the
primary recall method, not FTS5 trigram. The production closet_search should prioritize
the instr fallback path for CJK queries.

### Latency

- Keyword Overlap (jieba OR): **8.9ms** avg per query
- FTS5 BM25 (trigram): **2.2ms** avg per query
- FTS5+instr → Embedding Reranker: **1680.8ms** avg per query
- Pure Embedding KNN: **80.3ms** avg per query
- Keyword top-20 → Embedding Reranker: **2475.1ms** avg per query

---

## 5. Methodology

- **Dataset**: MADial-Bench Chinese subset (171 memories, 160 dialogues)
- **Query**: Full dialogue context up to (not including) the test turn
- **Ground truth**: `relevant-id` field in each dialogue
- **Embedding model**: `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` (384d, ONNX via fastembed)
- **Segmentation**: jieba for Chinese word segmentation (keyword modes)
- **Mode A**: jieba-segment query, multi-term OR via `instr()`, ranked by match_count
- **Mode B**: FTS5 trigram tokenizer, 3+ char terms OR-joined, BM25 ranking
- **Mode C**: FTS5 top-20 recall -> embedding cosine rerank to top-K; instr OR fallback if FTS5=0; pure KNN fallback if both=0
- **Mode D**: Direct embedding KNN via sqlite-vec, no keyword filtering
- **Mode E**: Keyword overlap top-30 recall -> embedding cosine rerank to top-K; KNN fallback if keywords return 0
