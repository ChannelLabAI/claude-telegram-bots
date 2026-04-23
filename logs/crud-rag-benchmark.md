# CRUD-RAG Benchmark Results
Date: 2026-04-10 16:31:46

## Setup
- Corpus: CRUD-RAG 80k Chinese news (20000 docs ingested)
- Index: SQLite FTS5 trigram tokenizer (same as MemOcean memory.db)
- DB size: 182.7 MB
- Ingest time: 25.6s
- Sample size per task: 100
- Retrieval top-k: 8

## Search Pipeline
1. jieba keyword extraction from question
2. FTS5 trigram BM25 ranking (primary)
3. instr() substring fallback (for short CJK tokens)

## Results

| Task | N | Hit Rate | Retrieval Recall | ROUGE-L | BLEU-1 | Avg Latency |
|------|---|----------|-----------------|---------|--------|-------------|
| QA-1doc | 100 | 100.0% | 0.098 | 0.081 | 0.079 | 14.0ms |
| QA-2docs | 100 | 100.0% | 0.101 | 0.105 | 0.147 | 16.3ms |
| QA-3docs | 100 | 99.0% | 0.090 | 0.098 | 0.149 | 28.4ms |

## Metric Definitions
- **Hit Rate**: % of questions where FTS5 returned at least 1 result
- **Retrieval Recall**: token-level recall of gold evidence in retrieved text (jieba tokens >= 2 chars)
- **ROUGE-L**: F1 of longest common subsequence between retrieved text and gold answer
- **BLEU-1**: unigram precision of retrieved text against gold answer
- **Avg Latency**: mean search time per query

## Example Queries

### questanswer_1doc
- Q: 国家卫生健康委员会于2023年7月28日启动了名为"启明行动"的专项活动，旨在针对特定群体的特定健康问题进行防控。请问这项活动具体针对哪个群体的健康问题？同时，
  FTS5 query: `"委员会" "指导性" "国家" "专项" "群体"`
  Results: 8, Recall: 0.088, ROUGE-L: 0.041, Latency: 9.3ms
- Q: 最近，陕西省西安市发放大量了体育类电子消费券，供市民使用。这些电子消费券的具体金额是多少？可以在多少家体育场馆使用？
  FTS5 query: `"陕西省" "西安市" "体育场馆" "体育类" "大量"`
  Results: 8, Recall: 0.040, ROUGE-L: 0.037, Latency: 4.9ms
- Q: 国家药监局在对哪5个品种的医疗器械进行产品质量监督抽检时，共发现了多少批（台）产品不符合标准规定？
  FTS5 query: `"国家药监局" "医疗器械" "产品质量" "符合标准" "品种"`
  Results: 2, Recall: 0.057, ROUGE-L: 0.071, Latency: 2.0ms

### questanswer_2docs
- Q: 在“启明行动”中，国家卫健委推广的《防控儿童青少年近视核心知识十条》包含哪些内容，且医疗机构应如何配合该行动向家长提供指导？
  FTS5 query: `"卫健委" "青少年" "医疗机构" "国家" "儿童"`
  Results: 1, Recall: 0.100, ROUGE-L: 0.099, Latency: 1.3ms
- Q: 上海和成都市体育局在促进体育消费和全民健身运动方面有哪些相似和不同的措施？
  FTS5 query: `"成都市" "上海" "体育局" "全民" "方面"`
  Results: 8, Recall: 0.120, ROUGE-L: 0.099, Latency: 1.9ms
- Q: 结合江西省药监局公布的医疗器械产品抽检结果，列举一些不符合标准规定的产品及其生产企业，并指出这次抽检中不合格产品的总数量。
  FTS5 query: `"江西省" "药监局" "医疗器械" "符合标准" "产品"`
  Results: 8, Recall: 0.099, ROUGE-L: 0.104, Latency: 6.0ms

### questanswer_3docs
- Q: 在“启明行动”中，国家卫健委推广了哪些核心知识来预防儿童青少年近视，同时医疗机构和家长应承担哪些角色？
  FTS5 query: `"卫健委" "青少年" "医疗机构" "国家" "核心"`
  Results: 1, Recall: 0.100, ROUGE-L: 0.104, Latency: 1.0ms
- Q: 上海和成都市体育局都采取了哪些措施来促进体育消费，以及上海体育消费券的具体使用条件是什么？
  FTS5 query: `"成都市" "上海" "体育局" "措施" "条件"`
  Results: 8, Recall: 0.106, ROUGE-L: 0.104, Latency: 1.9ms
- Q: 在最近的医疗器械产品质量抽检中，哪些具体产品不符合标准规定，这些产品分别由哪些企业生产？
  FTS5 query: `"医疗器械" "产品质量" "符合标准" "产品" "规定"`
  Results: 2, Recall: 0.050, ROUGE-L: 0.051, Latency: 1.5ms

## Additional Metrics

### Answer Keyword Coverage (20-sample spot check)
- Average: 31.6% of answer keywords found in retrieved documents
- 4/20 (20%) above 50% coverage
- 9/20 (45%) above 30% coverage  
- 18/20 (90%) have non-zero coverage
- Only 2/20 (10%) complete miss

### Corpus Coverage Note
- Only 20k/92k docs ingested (22% of corpus, disk limit)
- Gold evidence articles are NOT in the 80k retrieval corpus (by design)
- The 80k corpus contains related but different articles about same events
- This makes the benchmark harder: retrieval must find topically related docs, not exact matches

## Analysis

### What This Tests
This benchmark evaluates our FTS5 trigram search pipeline against
a standardized Chinese RAG benchmark (IAAR-Shanghai CRUD-RAG, ACM TOIS 2024).
The pipeline tested mirrors production (memory.db): FTS5 trigram tokenizer
with BM25 ranking + OR fallback + instr() substring fallback.

### Key Findings
1. **Hit rate is excellent (99-100%)**: The three-layer search strategy
   (AND match -> OR fallback -> instr fallback) ensures almost every
   query returns results
2. **Latency is strong (14-28ms avg)**: FTS5 trigram on 20k docs is fast,
   well within interactive response requirements
3. **Retrieval recall is limited (~10%)**: Expected for lexical search
   against a corpus where exact gold docs aren't present. The search
   finds topically related articles but not the specific evidence needed
4. **Answer coverage is moderate (31.6%)**: Despite low exact recall,
   retrieved docs contain ~1/3 of the keywords needed to answer questions
5. **No semantic gap bridging**: Questions using paraphrased language
   (e.g., "特定群体" for "儿童青少年") won't match via lexical search

### Recommendations for MemOcean
1. **FTS5 is a solid baseline for CJK search** -- fast, zero-dependency, good hit rate
2. **Adding a lightweight embedding layer would significantly improve recall**:
   - bge-base-zh-v1.5 (200MB) would bridge semantic gaps
   - Hybrid FTS5 + vector would combine speed with accuracy
3. **Reranker is high-value next step**: cross-encoder reranking of top-k
   FTS5 results could boost precision without changing the index
4. **Query expansion via jieba POS tagging** (used in this benchmark) is
   worth deploying in production search.py

### Limitations
- Only 22% of corpus indexed (disk constraint)
- No embedding/vector search tested (requires torch + sentence-transformers, ~2GB)
- No reranker tested (would need cross-encoder model)
- BLEU/ROUGE measure text overlap, not semantic quality
- FTS5 trigram is lexical only; CRUD-RAG questions often require
  semantic understanding that pure keyword matching cannot capture

### Comparison Context
- CRUD-RAG paper baselines use vector retrieval (bge-base-zh) + LLM generation
- Our test isolates the *retrieval* step only (no LLM generation)
- Paper reports BLEU/ROUGE on generated answers, not on retrieval alone,
  so direct comparison requires running the full pipeline with an LLM