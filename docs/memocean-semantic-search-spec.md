---
type: spec
created: 2026-04-14
status: draft
tags: [memocean, semantic-search, BGE-m3, sqlite-vec, hybrid-search, RRF]
related:
  - "[[MemOcean-Vector-Search-Consensus-20260412]]"
  - "[[RnD-Reranker-Pipeline]]"
  - "[[MemOcean]]"
  - "[[FTS5-跨bot記憶搜尋]]"
owner: Anya
---

# MemOcean Semantic Search Architecture Spec

> **Status:** Draft — pending implementation by Anna
> **Context:** Builds on the 2026-04-12 team consensus ([MemOcean-Vector-Search-Consensus-20260412]). BGE-m3 is the chosen embedding model; this spec defines the full implementation blueprint.

---

## 1. Why We Need This

Current MemOcean uses pure BM25 (SQLite FTS5) for all knowledge retrieval. BM25 is fast and highly accurate on keyword queries (Hit@5 = 95.8% on the keyword benchmark), but it breaks in three common real-world scenarios:

| Failure case | Example | What happens |
|---|---|---|
| Semantic / paraphrase | "上次那個 OTC 討論" | Misses NOXCAT OTC PRD unless exact words match |
| Cross-lingual | English query → Chinese document | No overlap, zero results |
| Abbreviations / colloquial | "NOX OTC那邊" | Fragile, depends on whether abbreviation appears verbatim |

Adding a vector search path alongside BM25 — combined via Reciprocal Rank Fusion — closes these gaps while preserving the existing fast path.

**Baseline benchmark (2026-04-12 consensus):**

| System | Hit@5 |
|---|---|
| Pure BM25 (current) | 84–86% |
| BM25 + BGE-m3 KNN + RRF | ~85–86% overall, +3.2pp at Hit@3, meaningful gains on semantic queries |

The overall number barely moves because BM25 is already strong. The real gain is that semantic / colloquial / cross-lingual queries — which BM25 fails silently — now have a second path to find the right answer.

---

## 2. What This Means for Bots

Before this change, a bot asking "上次 OTC 那個提案呢" might get no results because the exact phrase "OTC" doesn't appear in the stored summary text.

After this change, the same query will find the relevant Radar entry because the vector search path recognises the semantic intent ("OTC 提案" = "NOXCAT OTC PRD"), even if the exact words don't match.

**In plain terms:**
- Bots can ask questions in natural language instead of crafting precise keyword queries
- Colloquial references ("上次那個 X") find the right memory
- Mixing English and Chinese in a query still works
- Fallback to pure BM25 is instant if the vector path has any problem — no reliability regression

---

## 3. Embedding Model: BGE-m3

**Model:** `BAAI/bge-m3`
**Source:** HuggingFace (`pip install FlagEmbedding`)

| Property | Value |
|---|---|
| Dimensions | 1,024 float32 |
| Languages | Multilingual — zh, en, mixed, ja, etc. |
| Model size on disk | ~2.2 GB |
| RAM at inference | ~1.5–2 GB |
| Embed latency (CPU, single query) | ~500ms warm / ~15–20s cold start |
| Embed latency (CPU, batch 315 entries) | ~90s one-time backfill |
| License | Apache 2.0 |

**Why BGE-m3 over alternatives:**

- **vs MiniLM:** MiniLM KNN was a net negative (−6.4pp Hit@5). BGE-m3 is the decisive improvement that made KNN a positive contributor.
- **vs Jina Embeddings API:** API option eliminates local model cost, but introduces latency variability, API key dependency, and per-call cost. Use as fallback only (see §8).
- **vs OpenAI text-embedding-3:** Same API-dependency problem. Also BGE-m3 is better for zh/en mixed content.

**VPS feasibility:** Model runs on CPU only. GCP VPS with 4+ GB RAM handles it. No GPU required. BGE-m3 is loaded once at service start and kept in memory.

---

## 4. Vector Storage: sqlite-vec

**Extension:** [`sqlite-vec`](https://github.com/asg017/sqlite-vec) — SQLite extension for vector search.

This keeps everything in a single `memory.db` file. No new infrastructure (no Postgres, no Pinecone, no Chroma). The extension adds KNN vector search directly in SQL.

### Schema additions

```sql
-- Load extension once at connection time
SELECT load_extension('vec0');

-- New table: radar vector embeddings
CREATE VIRTUAL TABLE radar_vec USING vec0(
  embedding float[1024]
);

-- Mapping from vec rowid → radar entry id
CREATE TABLE radar_vec_map (
  vec_rowid   INTEGER PRIMARY KEY,
  radar_id    TEXT NOT NULL,   -- matches radar.id
  created_at  TEXT NOT NULL
);
```

`radar_vec` is a virtual table managed by sqlite-vec. Inserts go in alongside inserts into `radar_vec_map` to maintain the id mapping.

### Installation

```bash
pip install sqlite-vec
# Extension auto-loads via Python: sqlite_vec.load(conn)
```

No system-level install needed. Pure Python package.

---

## 5. Embedding Pipeline

### 5.1 One-time backfill

Embed all existing `radar` entries. The CLSC text field is the input; the 1,024-dim vector is the output.

**Script:** `shared/scripts/backfill_radar_vec.py`

```
for each row in radar (315 entries):
    text = row["content"] or row["clsc_summary"]
    vector = bge_m3.encode(text, normalize=True)
    INSERT INTO radar_vec(rowid, embedding) VALUES (?, ?)
    INSERT INTO radar_vec_map(vec_rowid, radar_id, created_at) VALUES (?, ?, ?)
```

Expected runtime: ~90 seconds total on CPU. Run once, idempotent (skip already-embedded rows).

### 5.2 Incremental embedding (new entries)

Hook into the existing `backfill_closet.py` (or wherever new radar entries are inserted). After a new radar row is committed:

```python
vector = embed_text(row["content"])
insert_radar_vec(conn, radar_id=row["id"], vector=vector)
```

This keeps the vector table current without a separate sync job.

### 5.3 Phase 2 — messages table (deferred)

The `messages` FTS table has 7,234 entries. Embedding all of them would cost ~40 minutes CPU one-time and ~7 MB storage. This is deferred to Phase 2 pending a separate decision on whether message-level semantic retrieval is worth the compute cost.

---

## 6. Hybrid Search with Reciprocal Rank Fusion

### Pipeline

```
Query
  │
  ├─── BM25 FTS5 (existing)          → top-20 results with BM25 score
  │
  └─── BGE-m3 embed query (~25ms)
         └─── KNN on radar_vec        → top-20 results with cosine similarity
  │
  └─── RRF merge (k=60)
         └─── top-5 final results
```

### RRF formula

```
rrf_score(d) = 1 / (k + rank_bm25(d))  +  1 / (k + rank_vec(d))
```

- `k = 60` (standard default; dampens the effect of very high ranks)
- Documents that only appear in one list get a partial score from the other (treated as rank = ∞ → contributes 0)
- Final sort by `rrf_score` descending, return top-5

### Implementation

```python
def hybrid_search(query: str, conn, top_k: int = 5, use_knn: bool = True) -> list[dict]:
    # BM25 path (always runs)
    bm25_results = fts_search(conn, query, limit=20)  # existing function

    if not use_knn:
        return bm25_results[:top_k]

    # Vector path
    q_vec = embed_text(query)  # ~25ms
    knn_results = vec_search(conn, q_vec, limit=20)   # ~50-200ms

    # RRF merge
    return rrf_merge(bm25_results, knn_results, k=60, top_k=top_k)
```

### Normalisation note

BM25 scores from FTS5 are negative (more negative = better match). For RRF purposes, only the **rank order** matters — not the raw score — so no score normalisation is needed.

---

## 7. Latency Budget

| Step | Expected time |
|---|---|
| BM25 FTS5 search (315 radar entries) | < 5ms |
| BGE-m3 query embedding (CPU) | ~500ms warm / ~15–20s cold start |
| KNN search via sqlite-vec (315 vectors) | ~20–50ms |
| RRF merge (in-memory, 40 candidates) | < 1ms |
| **Total (hybrid path)** | **~600–700ms warm** |
| **Total (BM25 fallback path)** | **< 5ms** |

At 315 radar entries, the KNN search is trivially small. The dominant cost is BGE-m3 inference on CPU (~500ms warm). This is within the **700ms warm** acceptable budget. Cold start (~15–20s) is a one-time cost at model load; subsequent queries use the cached model.

When messages embedding is added (Phase 2, 7,234 entries), KNN latency will increase — expected ~100–300ms. Still acceptable.

---

## 8. Fallback Strategy

Vector search is wrapped in a try/except. On any failure (model not loaded, extension missing, timeout), the system falls back to BM25-only silently:

```python
def search(query: str, conn) -> list[dict]:
    try:
        if KNN_ENABLED and model_loaded():
            return hybrid_search(query, conn, use_knn=True)
    except Exception as e:
        log.warning(f"Vector search failed, falling back to BM25: {e}")
    return bm25_search(query, conn)
```

**Fallback triggers:**
- `KNN_ENABLED=false` env var (manual disable)
- BGE-m3 model not downloaded / not loaded
- sqlite-vec extension not installed
- Any exception during embed or KNN

Fallback is logged but not surfaced to bots. From a bot's perspective, search always returns results.

**Jina API fallback (optional):** If BGE-m3 cannot run locally (OOM or disk constraint), `embed_text()` can route to Jina's embedding API (`jina-embeddings-v3`). This adds ~200ms network latency per query and requires an API key. Not the default; kept as an option in the config.

---

## 9. Phased Rollout

### Phase 0 — Infrastructure (no live traffic change)
- [x] Install `sqlite-vec` on VPS (`pip install sqlite-vec`)
- [x] Download BGE-m3 model to VPS (~2.2 GB) — ONNX INT8 quantised, ~93-104ms warm
- [x] Run `backfill_radar_vec.py` — embed 337 radar entries (actual count after dedup)
- [x] Verify: `SELECT count(*) FROM radar_vec` returns 337
- [x] Run offline benchmark: hybrid vs BM25-only on existing query set
- [x] No change to live search path yet (`KNN_ENABLED=false`)

### Phase 1 — Hybrid search live (radar only)
- [x] Merge hybrid search code into search endpoint (`memocean_mcp/tools/radar_search.py`)
- [x] Set `KNN_ENABLED=true` in `shared/.env`
- [x] 48hr stability check passed: no OOM, no latency spikes
- [x] Hit@5 reachable: hybrid 90.9% vs BM25 91.6% — within 1pp gate ✅
- [x] Gate passed — hybrid live on radar

### Phase 2 — Messages embedding (separate decision)
- [x] Benchmark: semantic retrieval on messages adds value (+4pp Hit@10, +50pp cross_language)
- [x] Embed 7,374 messages (actual count) — `backfill_messages_vec.py`, stored in `messages_vec`
- [x] Add `messages_vec` table with same pattern as `radar_vec` (msg_key TEXT PRIMARY KEY)
- [x] Add hybrid path to message search (`memocean_mcp/tools/messages_hybrid_search.py`)

### Phase 2 Benchmark Results

| System | Query set | Hit@5 | Hit@10 | Notes |
|---|---|---|---|---|
| Radar BM25 | reachable (155q) | 91.6% | — | Baseline |
| Radar Hybrid (BGE-m3+RRF) | reachable (165q) | **90.9%** | 93.3% | Within 1pp gate ✅ |
| Radar Hybrid (BGE-m3+RRF) | all (198q) | 75.8% | 77.8% | 33 unreachable questions |
| Messages BM25 | — | 64% | 68% | Pure keyword |
| Messages Hybrid (BGE-m3+RRF) | — | **64%** | **72%** | +4pp Hit@10 |
| Messages Hybrid cross_language | semantic subset | — | — | **+50pp** vs BM25 |

> Completed: 2026-04-14. MEMO-001 (radar backfill) → MEMO-002 (radar hybrid) → MEMO-003 (messages backfill) → MEMO-004 (messages hybrid).

---

## 10. Out of Scope

The following are explicitly **not** part of this spec:

- **Reranker:** Both Haiku reranker (−8.3pp Hit@5) and MiniLM reranker (−6.4pp Hit@5) have been tested and rejected. No reranker is planned. See [[RnD-Reranker-Pipeline]] for the full experiment record.
- **Query expansion:** Previously tested with Haiku; confirmed −11.6pp negative on BM25 path. Disabled at code level. Not revisited here.
- **Replacing BM25:** BM25 remains the primary path. Vector search is additive, not a replacement.
- **Full message embedding (Phase 2 only):** In scope only after Phase 1 validation.
- **SimHash / vector quantization:** Tracked in [[RnD-Vector-Quantization]]. Depends on BGE-m3 stability (48hr window after Phase 1 deploy). Calibration required for 1,024-dim (existing doc covers 384-dim MiniLM only — needs update).
- **GPU inference:** Not available on current VPS. CPU is sufficient at current scale.

---

## 11. Key Files

| File | Purpose |
|---|---|
| `shared/scripts/backfill_radar_vec.py` | One-time embedding backfill |
| `shared/scripts/search.py` (or equivalent) | Hybrid search endpoint, RRF logic |
| `shared/.env` | `KNN_ENABLED`, `JINA_API_KEY` (optional) |
| `memory.db` | Single DB file, gains `radar_vec` + `radar_vec_map` tables |

---

## 12. Dependencies

| Package | Version | Purpose |
|---|---|---|
| `FlagEmbedding` | ≥1.2 | BGE-m3 inference |
| `sqlite-vec` | ≥0.1 | Vector KNN in SQLite |
| `torch` (CPU) | ≥2.0 | Required by FlagEmbedding |

Estimated additional disk: ~2.5 GB (model) + ~1.3 MB (315 × 1024 × 4 bytes vectors).

---

*Spec owner: Anya · Last updated: 2026-04-15 · Status: Phase 0-2 COMPLETE*
*See also: [[MemOcean-Vector-Search-Consensus-20260412]] · [[RnD-Reranker-Pipeline]] · [[MemOcean]]*
