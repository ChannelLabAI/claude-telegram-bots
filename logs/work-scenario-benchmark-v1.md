# MemOcean Work Scenario Benchmark v1

Run: 2026-04-12 19:23:04

Corpus: 289 closet entries, 806 KG entities, 828 KG triples

Questions: 200 total

## 1. Overall Hit@K

### Seabed Search (156 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 30.8% (48) | 31.4% (49) | 31.4% (49) | 31.4% (49) |
| OR | 93.6% (146) | 96.2% (150) | 96.8% (151) | 97.4% (152) |
| FTS5+BM25 | 93.6% (146) | 96.2% (150) | 96.8% (151) | 97.4% (152) |

### Messages Search (25 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| FTS5 | 60.0% (15) | 60.0% (15) | 64.0% (16) | 72.0% (18) |

### KG Query (19 questions)

| Hit Rate | 100.0% (19/19) |
|---|---|

## 2. Per-Scene Breakdown

### cross_language (20 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 17.6% | 17.6% | 17.6% | 17.6% |
| OR | 94.1% | 94.1% | 94.1% | 94.1% |
| FTS5+BM25 | 94.1% | 94.1% | 94.1% | 94.1% |

Messages FTS5: Hit@1=50.0% Hit@3=50.0% Hit@5=50.0% Hit@10=50.0%

KG: 100.0% (1/1)

### decision_record (20 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 41.2% | 41.2% | 41.2% | 41.2% |
| OR | 88.2% | 94.1% | 94.1% | 94.1% |
| FTS5+BM25 | 88.2% | 94.1% | 94.1% | 94.1% |

Messages FTS5: Hit@1=100.0% Hit@3=100.0% Hit@5=100.0% Hit@10=100.0%

### org_structure (15 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 25.0% | 25.0% | 25.0% | 25.0% |
| OR | 62.5% | 75.0% | 75.0% | 87.5% |
| FTS5+BM25 | 62.5% | 75.0% | 75.0% | 87.5% |

Messages FTS5: Hit@1=0.0% Hit@3=0.0% Hit@5=100.0% Hit@10=100.0%

KG: 100.0% (6/6)

### person_lookup (20 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 18.2% | 18.2% | 18.2% | 18.2% |
| OR | 100.0% | 100.0% | 100.0% | 100.0% |
| FTS5+BM25 | 100.0% | 100.0% | 100.0% | 100.0% |

Messages FTS5: Hit@1=50.0% Hit@3=50.0% Hit@5=50.0% Hit@10=50.0%

KG: 100.0% (7/7)

### process_sop (20 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 52.9% | 52.9% | 52.9% | 52.9% |
| OR | 94.1% | 100.0% | 100.0% | 100.0% |
| FTS5+BM25 | 94.1% | 100.0% | 100.0% | 100.0% |

Messages FTS5: Hit@1=33.3% Hit@3=33.3% Hit@5=33.3% Hit@10=66.7%

### product_feature (20 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 44.4% | 44.4% | 44.4% | 44.4% |
| OR | 94.4% | 94.4% | 100.0% | 100.0% |
| FTS5+BM25 | 94.4% | 94.4% | 100.0% | 100.0% |

Messages FTS5: Hit@1=100.0% Hit@3=100.0% Hit@5=100.0% Hit@10=100.0%

### project_info (25 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 47.4% | 47.4% | 47.4% | 47.4% |
| OR | 100.0% | 100.0% | 100.0% | 100.0% |
| FTS5+BM25 | 100.0% | 100.0% | 100.0% | 100.0% |

Messages FTS5: Hit@1=50.0% Hit@3=50.0% Hit@5=50.0% Hit@10=50.0%

KG: 100.0% (2/2)

### semantic_fuzzy (20 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 0.0% | 0.0% | 0.0% | 0.0% |
| OR | 94.1% | 94.1% | 94.1% | 94.1% |
| FTS5+BM25 | 94.1% | 94.1% | 94.1% | 94.1% |

Messages FTS5: Hit@1=50.0% Hit@3=50.0% Hit@5=50.0% Hit@10=100.0%

KG: 100.0% (1/1)

### tech_architecture (25 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 35.0% | 40.0% | 40.0% | 40.0% |
| OR | 95.0% | 100.0% | 100.0% | 100.0% |
| FTS5+BM25 | 95.0% | 100.0% | 100.0% | 100.0% |

Messages FTS5: Hit@1=100.0% Hit@3=100.0% Hit@5=100.0% Hit@10=100.0%

KG: 100.0% (2/2)

### temporal_reasoning (15 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 8.3% | 8.3% | 8.3% | 8.3% |
| OR | 100.0% | 100.0% | 100.0% | 100.0% |
| FTS5+BM25 | 100.0% | 100.0% | 100.0% | 100.0% |

Messages FTS5: Hit@1=33.3% Hit@3=33.3% Hit@5=33.3% Hit@10=33.3%

## 3. Per-Difficulty Breakdown

### Seabed Search by Difficulty

| Difficulty | Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 | N |
|---|---|---|---|---|---|---|
| easy | AND | 47.5% | 49.1% | 49.1% | 49.1% | 59 |
| easy | OR | 94.9% | 98.3% | 98.3% | 100.0% | 59 |
| easy | FTS5+BM25 | 94.9% | 98.3% | 98.3% | 100.0% | 59 |
| medium | AND | 25.0% | 25.0% | 25.0% | 25.0% | 60 |
| medium | OR | 95.0% | 98.3% | 100.0% | 100.0% | 60 |
| medium | FTS5+BM25 | 95.0% | 98.3% | 100.0% | 100.0% | 60 |
| hard | AND | 13.5% | 13.5% | 13.5% | 13.5% | 37 |
| hard | OR | 89.2% | 89.2% | 89.2% | 89.2% | 37 |
| hard | FTS5+BM25 | 89.2% | 89.2% | 89.2% | 89.2% | 37 |

### Messages Search by Difficulty

| Difficulty | Hit@1 | Hit@3 | Hit@5 | Hit@10 | N |
|---|---|---|---|---|---|
| medium | 50.0% | 50.0% | 50.0% | 62.5% | 8 |
| hard | 64.7% | 64.7% | 70.6% | 76.5% | 17 |

### KG Query by Difficulty

| Difficulty | Hit Rate | N |
|---|---|---|
| easy | 100.0% (1/1) | 1 |
| medium | 100.0% (12/12) | 12 |
| hard | 100.0% (6/6) | 6 |

## 4. Hard Failures (not found in top-10 by any mode)

### Seabed Failures (4)

| ID | Scene | Diff | Query | Expected | AND Top-3 | OR Top-3 | FTS5 Top-3 |
|---|---|---|---|---|---|---|---|
| 74 | decision_record | hard | Redis 任務佇列 為什麼不用 | `Wiki-Cards-FATQ-File-Atomic-Ta`, `Closet-Cards-FATQ-File-Atomic-` | --- | --- | --- |
| 142 | org_structure | hard | 資本儲備 水位線 | `Wiki-Projects-ChannelLab-profi`, `Closet-Projects-ChannelLab-pro` | --- | --- | --- |
| 175 | cross_language | hard | SPA AI 爬蟲 | `Research-agent-browser-researc`, `Chart-Architecture-browser-aut` | --- | `BOT-bots-yitang-CLAUDE`, `Currents-ChannelLab-Produ`, `Ocean-BOT-bots-yitang-CLA` | `BOT-bots-yitang-CLAUDE`, `Currents-ChannelLab-Produ`, `Ocean-BOT-bots-yitang-CLA` |
| 191 | semantic_fuzzy | hard | 丟進去 分身 不用管 | `Wiki-Cards-Ops-background-agen`, `Ocean-Pearl-Ops-background-age` | --- | --- | --- |

### Messages Failures (7)

| ID | Scene | Diff | Query | Expected Snippets | Results |
|---|---|---|---|---|---|
| 5 | person_lookup | medium | 桃桃 工作 | 桃桃, PM, 培訓, NOXCAT | 0 |
| 27 | project_info | medium | NOXCAT 會議 技術 | OTC, 跨鏈, 錢包 | 10 |
| 38 | project_info | hard | 輿情監控 | 輿情, 監控, 情感分析 | 0 |
| 110 | process_sop | hard | 老兔 信仰 禁忌 | 耶和華見證人, 不慶生, 不輸血 | 0 |
| 153 | temporal_reason | hard | 本週 重大事件 進度 | CLSC, 知識基礎設施, FATQ | 0 |
| 158 | temporal_reason | medium | 發薪日 幾號 | 發薪, 帳務 | 0 |
| 176 | cross_language | hard | code-switching 策略 中英 | code-switching, 中文, 英文 | 0 |

### KG Failures (0)

None!

## 5. Summary Statistics

- **Total questions**: 200
- **Seabed (FTS5) Hit@10**: 97.4%
- **Messages Hit@10**: 72.0%
- **KG hit rate**: 100.0%
- **Weighted overall Hit@10**: 94.5%
- **Total hard failures**: 11

### Seabed Mode Comparison (Hit@10)

- AND: 31.4%
- OR: 97.4% (delta vs AND: +66.0pp)
- FTS5+BM25: 97.4% (delta vs AND: +66.0pp)

### Scenes ranked by FTS5 Hit@10 (seabed only)

- org_structure: 87.5% (n=8)
- cross_language: 94.1% (n=17)
- decision_record: 94.1% (n=17)
- semantic_fuzzy: 94.1% (n=17)
- person_lookup: 100.0% (n=11)
- process_sop: 100.0% (n=17)
- product_feature: 100.0% (n=18)
- project_info: 100.0% (n=19)
- tech_architecture: 100.0% (n=20)
- temporal_reasoning: 100.0% (n=12)

---
*Generated by `work-scenario-benchmark-v1.py` on 2026-04-12 19:23:04*