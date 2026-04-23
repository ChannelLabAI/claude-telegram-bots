# CLSC Benchmark v3 — Three-way Search Comparison: AND vs OR vs FTS5+BM25

Run: 2026-04-10 10:13:49

Database: `/home/oldrabbit/.claude-bots/memory.db`

## 1. Summary Comparison

| Set | AND | OR | FTS5+BM25 | OR vs AND | FTS5 vs AND |
|---|---|---|---|---|---|
| A: Real log | 50.0% | 88.5% | 88.5% | +38.5pp | +38.5pp |
| B: Msg-sampled | 0.0% | 55.0% | 55.0% | +55.0pp | +55.0pp |
| C: Ocean files | 85.0% | 95.0% | 95.0% | +10.0pp | +10.0pp |

## 2. Per-set Details

### Set A: Real log replay

| Mode | Queries | Hits | Hit Rate | Avg Hits/Query |
|---|---|---|---|---|
| AND | 26 | 13 | 50.0% | 9.3 |
| OR | 26 | 23 | 88.5% | 9.5 |
| FTS5+BM25 | 26 | 23 | 88.5% | 9.7 |

**FTS5 vs OR differences (17 queries):**

| Query | OR Hits | FTS5 Hits | FTS Mode | OR Top-1 | FTS5 Top-1 |
|---|---|---|---|---|---|
| ChannelLab | 10 | 10 | fts5 | `08-Daily-2026-04-06` | `Wiki-Cards-ChannelLab` |
| obsidian headless MCP REST API | 10 | 10 | fts5 | `Wiki-Concepts-Local-Setup-AI-S` | `Wiki-Concepts-Local-Setup-AI-S` |
| ibon ticket bot playwright | 10 | 10 | fts5 | `Archive-MOC-MOC-Claude-Bots` | `Wiki-Cards-Playwright-MCP-vs-g` |
| CLSC dictionary | 10 | 10 | fts5 | `Wiki-Cards-ADR-CLSC` | `Wiki-Concepts-CLSC-CLSC-Dictio` |
| closet migrate wiki vault skeleton | 10 | 10 | fts5 | `Closet-_schema` | `Ocean-Chart-MemOcean` |
| CLSC skeleton | 10 | 10 | fts5 | `Wiki-Concepts-CLSC-Technical-S` | `Ocean-Chart-MemOcean` |
| channellab GEO | 10 | 10 | fts5 | `08-Daily-2026-04-06` | `Closet-Wings-ChannelLab-GEO-Ch` |
| GEO service pricing | 10 | 10 | fts5 | `Wiki-Companies-ChannelLab-GEO-` | `Ocean-Currents-ChannelLab-GEO-` |
| wings room skeleton clsc aaak | 10 | 10 | fts5 | `Ocean-Chart-MemOcean` | `Ocean-Chart-MemOcean` |
| GEO | 10 | 10 | fts5 | `08-Daily-2026-04-06` | `Closet-Wings-ChannelLab-GEO-Bo` |
| ocean rename metaphor currents pearl cha | 5 | 10 | fts5 | `Ocean-_schema` | `Ocean-_schema` |
| ChannelLab | 10 | 10 | fts5 | `08-Daily-2026-04-06` | `Wiki-Cards-ChannelLab` |
| Knowledge | 10 | 10 | fts5 | `Wiki-Cards-graphify` | `Wiki-Concepts-CLSC-empirical-r` |
| task queue | 10 | 10 | fts5 | `Wiki-Concepts-CLSC-Spec` | `Wiki-Cards-FATQ-File-Atomic-Ta` |
| Knowledge | 10 | 10 | fts5 | `Wiki-Cards-graphify` | `Wiki-Concepts-CLSC-empirical-r` |
| task queue | 10 | 10 | fts5 | `Wiki-Concepts-CLSC-Spec` | `Wiki-Cards-FATQ-File-Atomic-Ta` |
| FATQ protocol | 10 | 10 | fts5 | `Wiki-llm-wiki-wiki-topics` | `Wiki-Cards-FATQ-File-Atomic-Ta` |

**English queries — OR vs FTS5 top-3 (19 queries with hits):**

| Query | OR Top-3 | FTS5 Top-3 |
|---|---|---|
| ChannelLab | `08-Daily-2026-04-06`, `Assets-ChannelLab-Equity-`, `Assets-ChannelLab-Equity-` | `Wiki-Cards-ChannelLab`, `Ocean-Pearl-ChannelLab`, `Closet-Cards-ChannelLab` |
| obsidian headless MCP REST API | `Wiki-Concepts-Local-Setup`, `Wiki-Concepts-SOP-Local-S`, `Closet-Concepts-SOP-Local` | `Wiki-Concepts-Local-Setup`, `Ocean-Chart-SOP-Local-Set`, `Wiki-Concepts-SOP-Local-S` |
| 搶票 AOT | `Wiki-Reviews-CR-20260408-`, `Closet-Reviews-CR-2026040`, `Ocean-Reviews-CR-20260408` | `Wiki-Reviews-CR-20260408-`, `Ocean-Reviews-CR-20260408`, `Closet-Reviews-CR-2026040` |
| ibon ticket bot playwright | `Archive-MOC-MOC-Claude-Bo`, `Archive-Xbar-Bot-Status-P`, `Assets-Research-GEO-Analy` | `Wiki-Cards-Playwright-MCP`, `Ocean-Pearl-Playwright-MC`, `Closet-Cards-Playwright-M` |
| CLSC dictionary | `Wiki-Cards-ADR-CLSC`, `Wiki-Concepts-CLSC-Dictio`, `Wiki-Concepts-CLSC-Dictio` | `Wiki-Concepts-CLSC-CLSC-D`, `Ocean-Depth-CLSC-Dictiona`, `Wiki-Archive-CLSC-Diction` |
| closet migrate wiki vault skeleton | `Closet-_schema`, `Wiki-Research-gnekt-mybra`, `Closet-Research-gnekt-myb` | `Ocean-Chart-MemOcean`, `Closet-_schema`, `Ocean-_schema` |
| CLSC skeleton | `Wiki-Concepts-CLSC-Techni`, `Wiki-Concepts-CLSC-dogfoo`, `Wiki-Concepts-CLSC-CLSC-T` | `Ocean-Chart-MemOcean`, `Ocean-Chart-CLSC-CLSC-dog`, `Wiki-Concepts-CLSC-CLSC-d` |
| channellab GEO | `08-Daily-2026-04-06`, `Assets-ChannelLab-GEO-Ser`, `Assets-Portfolio-Bonk-Bon` | `Closet-Wings-ChannelLab-G`, `Closet-Wings-ChannelLab-G`, `Ocean-Currents-ChannelLab` |
| GEO service pricing | `Wiki-Companies-ChannelLab`, `Closet-Companies-ChannelL`, `Closet-Wings-ChannelLab-G` | `Ocean-Currents-ChannelLab`, `Assets-ChannelLab-GEO-Ser`, `Assets-ChannelLab-GEO-Ser` |
| wings room skeleton clsc aaak | `Ocean-Chart-MemOcean`, `Wiki-Concepts-CLSC-Techni`, `Wiki-Research-mempalace-v` | `Ocean-Chart-MemOcean`, `Closet-_schema`, `Ocean-Chart-CLSC-CLSC-Tec` |
| GEO | `08-Daily-2026-04-06`, `Archive-MOC-MOC-Business`, `Archive-MOC-MOC-GEO-Analy` | `Closet-Wings-ChannelLab-G`, `Ocean-Currents-ChannelLab`, `Closet-Wings-ChannelLab-G` |
| ocean rename metaphor currents pearl cha | `Ocean-_schema`, `Ocean-Chart-chart-clsc`, `Assets-Research-Planning-` | `Ocean-_schema`, `Ocean-Chart-chart-clsc`, `Ocean-Pearl-pearl-clsc` |
| ChannelLab | `08-Daily-2026-04-06`, `Assets-ChannelLab-Equity-`, `Assets-ChannelLab-Equity-` | `Wiki-Cards-ChannelLab`, `Ocean-Pearl-ChannelLab`, `Closet-Cards-ChannelLab` |
| pearl sonar pipeline lint hook ingest | `Wiki-Research-mempalace-d`, `Closet-Research-mempalace`, `Ocean-Research-mempalace-` | `Wiki-Research-mempalace-d`, `Ocean-Research-mempalace-`, `Closet-Research-mempalace` |
| Knowledge | `Wiki-Cards-graphify`, `Wiki-Concepts-Knowledge-I`, `Wiki-Concepts-crypto-ai-s` | `Wiki-Concepts-CLSC-empiri`, `Ocean-Chart-CLSC-CLSC-emp`, `Wiki-Concepts-CLSC-CLSC-e` |

**All three modes miss (3 queries):**

- `履歷 候選人`
- `xyznonexistent`
- `xyznonexistent`

### Set B: Message-sampled

| Mode | Queries | Hits | Hit Rate | Avg Hits/Query |
|---|---|---|---|---|
| AND | 20 | 0 | 0.0% | 0.0 |
| OR | 20 | 11 | 55.0% | 8.1 |
| FTS5+BM25 | 20 | 11 | 55.0% | 7.3 |

**FTS5 vs OR differences (7 queries):**

| Query | OR Hits | FTS5 Hits | FTS Mode | OR Top-1 | FTS5 Top-1 |
|---|---|---|---|---|---|
| API Next proxy | 10 | 10 | fts5 | `Wiki-Cards-concepts-Anthropic-` | `Wiki-Research-Anthropic-Manage` |
| 找合作方 調度 Nicky | 10 | 10 | fts5 | `Wiki-Concepts-ChannelLab-AI-Ar` | `Wiki-People-Nicky` |
| Dashboard 做完建議後的預估分數 媒體 | 10 | 5 | fts5 | `Archive-MOC-MOC-Dashboard` | `Archive-MOC-MOC-Dashboard` |
| 收工 Bellalovechl_Bot done | 10 | 6 | fts5 | `Wiki-Cards-ADR-CLSC` | `Wiki-Research-knowledge-infra-` |
| 同時是 00 Anna | 10 | 10 | fts5 | `Wiki-Cards-ADR-CLSC` | `Wiki-Reviews-CR-20260408-team-` |
| relay cloud i5bm9u | 5 | 5 | fts5 | `Assets-Portfolio-PRD-Anya-Voic` | `Assets-Portfolio-PRD-Anya-Voic` |
| 隨時可以接單 review Bella | 10 | 10 | fts5 | `Wiki-Cards-Reviewer` | `Wiki-Cards-Reviewer` |

**English queries — OR vs FTS5 top-3 (7 queries with hits):**

| Query | OR Top-3 | FTS5 Top-3 |
|---|---|---|
| 162 162 truncation | `00Daily-2026-04-09` | `00Daily-2026-04-09` |
| Anyachl_bot 收到 待命中 | `Bot-Config-channellab-bot`, `Wiki-Concepts-channellab-`, `Wiki-Concepts-Architectur` | `Bot-Config-channellab-bot`, `Wiki-Concepts-channellab-`, `Wiki-Concepts-Architectur` |
| API Next proxy | `Wiki-Cards-concepts-Anthr`, `Wiki-Research-Anthropic-M`, `Closet-Research-Anthropic` | `Wiki-Research-Anthropic-M`, `Ocean-Research-Anthropic-`, `Closet-Research-Anthropic` |
| 收工 Bellalovechl_Bot done | `Wiki-Cards-ADR-CLSC`, `Wiki-Research-knowledge-i`, `Wiki-Reviews-CR-20260408-` | `Wiki-Research-knowledge-i`, `Ocean-Research-knowledge-`, `Closet-Research-knowledge` |
| 同時是 00 Anna | `Wiki-Cards-ADR-CLSC`, `Wiki-Research-hermes-agen`, `Wiki-Reviews-CR-20260408-` | `Wiki-Reviews-CR-20260408-`, `Ocean-Reviews-CR-20260408`, `Closet-Reviews-CR-2026040` |
| relay cloud i5bm9u | `Assets-Portfolio-PRD-Anya`, `Wiki-Concepts-Google-Cale`, `Wiki-Concepts-SOP-Google-` | `Assets-Portfolio-PRD-Anya`, `Wiki-Concepts-Google-Cale`, `Ocean-Chart-SOP-Google-Ca` |
| 隨時可以接單 review Bella | `Wiki-Cards-Reviewer`, `Wiki-Concepts-CLSC-Spec`, `Wiki-Reviews-CR-20260408-` | `Wiki-Cards-Reviewer`, `Ocean-Pearl-Reviewer`, `Closet-Cards-Reviewer` |

**All three modes miss (9 queries):**

- `等三菜完成後開始審查 不動設定 CarrotAAA_bot`
- `之後再來整理好了 我們繼續討論wiki 我們的01`
- `0x167fBF7E0826A2c266090c27Cc4ba362b9815D36 0x92e4f1731f2ef18856ed6592fcc0bf55f37c2e1f 地址`
- `不能只看 通過了 通過但`
- `一眼看懂 新版乾淨很多 一行說明`
- `開始合併兩個 branch annadesu_bot`
- `聯創只拿分紅 團隊激勵直接給到員工`
- `Designer 錢包設計稿在排隊中 TwinkleCHL_bot`
- `TwinkleCHL_bot 啟動自我檢視`

### Set C: Ocean filenames

| Mode | Queries | Hits | Hit Rate | Avg Hits/Query |
|---|---|---|---|---|
| AND | 20 | 17 | 85.0% | 5.5 |
| OR | 20 | 19 | 95.0% | 9.3 |
| FTS5+BM25 | 20 | 19 | 95.0% | 9.0 |

**FTS5 vs OR differences (12 queries):**

| Query | OR Hits | FTS5 Hits | FTS Mode | OR Top-1 | FTS5 Top-1 |
|---|---|---|---|---|---|
| CR 20260408 clsc v0.6 hancloset | 10 | 10 | fts5 | `Wiki-Reviews-CR-20260408-clsc-` | `Wiki-Reviews-CR-20260408-clsc-` |
| Bonk GEO | 10 | 10 | fts5 | `08-Daily-2026-04-06` | `Closet-Wings-ChannelLab-GEO-Bo` |
| New Tool Adoption SOP | 10 | 10 | fts5 | `Wiki-Concepts-New-Tool-Adoptio` | `Ocean-Chart-SOP-New-Tool-Adopt` |
| agent browser | 10 | 10 | fts5 | `Wiki-Cards-agent-browser` | `Wiki-Cards-agent-browser` |
| PRD | 10 | 10 | fts5 | `Assets-Portfolio-PRD-Anya-Voic` | `Wiki-Projects-GEO-Analyzer-PRD` |
| Hubble AI | 10 | 4 | fts5 | `Wiki-Companies-Hubble-AI` | `Wiki-Companies-Hubble-AI` |
| Hegotá升級 | 4 | 4 | fts5 | `Wiki-llm-wiki-wiki-entities-He` | `llm-wiki-wiki-entities-Hegot` |
| Team Onboarding SOP | 10 | 10 | fts5 | `Wiki-Concepts-Team-Onboarding-` | `Ocean-Chart-SOP-Team-Onboardin` |
| Bot Team Architecture | 10 | 10 | fts5 | `Wiki-Concepts-Bot-Team-Archite` | `Ocean-Chart-Architecture-Bot-T` |
| GAIA  Account manager JD (Malaysia) | 10 | 10 | fts5 | `Wiki-llm-wiki-wiki-entities-EI` | `llm-wiki-wiki-entities` |
| browser automation landscape | 10 | 10 | fts5 | `Wiki-Concepts-browser-automati` | `Wiki-Concepts-browser-automati` |
| nick spisak method | 10 | 10 | fts5 | `Wiki-Cards-nick-spisak-method` | `Wiki-Cards-nick-spisak-method` |

**English queries — OR vs FTS5 top-3 (18 queries with hits):**

| Query | OR Top-3 | FTS5 Top-3 |
|---|---|---|
| CR 20260408 clsc v0.6 hancloset | `Wiki-Reviews-CR-20260408-`, `Wiki-Reviews-CR-20260408-`, `Closet-Reviews-CR-2026040` | `Wiki-Reviews-CR-20260408-`, `Ocean-Reviews-CR-20260408`, `Closet-Reviews-CR-2026040` |
| Bonk GEO | `08-Daily-2026-04-06`, `Assets-Portfolio-Bonk-Bon`, `Assets-Portfolio-Bonk-Bon` | `Closet-Wings-ChannelLab-G`, `Ocean-Currents-ChannelLab`, `Wiki-Projects-Bonk-GEO` |
| New Tool Adoption SOP | `Wiki-Concepts-New-Tool-Ad`, `Wiki-Concepts-SOP-New-Too`, `Closet-Concepts-SOP-New-T` | `Ocean-Chart-SOP-New-Tool-`, `Wiki-Concepts-SOP-New-Too`, `Closet-Concepts-SOP-New-T` |
| CR 20260408 channellab kb mcp v0.1 | `Wiki-Reviews-CR-20260408-`, `Closet-Reviews-CR-2026040`, `Ocean-Reviews-CR-20260408` | `Wiki-Reviews-CR-20260408-`, `Ocean-Reviews-CR-20260408`, `Closet-Reviews-CR-2026040` |
| CR 20260408 team config centralization | `Wiki-Reviews-CR-20260408-`, `Closet-Reviews-CR-2026040`, `Ocean-Reviews-CR-20260408` | `Wiki-Reviews-CR-20260408-`, `Ocean-Reviews-CR-20260408`, `Closet-Reviews-CR-2026040` |
| agent browser | `Wiki-Cards-agent-browser`, `Wiki-Concepts-browser-aut`, `Wiki-Research-agent-brows` | `Wiki-Cards-agent-browser`, `Ocean-Pearl-agent-browser`, `Closet-Cards-agent-browse` |
| PRD | `Assets-Portfolio-PRD-Anya`, `Assets-Research-GEO-Analy`, `Wiki-Research-knowledge-i` | `Wiki-Projects-GEO-Analyze`, `Closet-Wings-ChannelLab-P`, `Ocean-Currents-ChannelLab` |
| Hubble AI | `Wiki-Companies-Hubble-AI`, `Closet-Companies-Hubble-A`, `Closet-Wings-ChannelLab-G` | `Wiki-Companies-Hubble-AI`, `Closet-Companies-Hubble-A`, `Closet-Wings-ChannelLab-G` |
| Hegotá升級 | `Wiki-llm-wiki-wiki-entiti`, `llm-wiki-wiki-entities-He`, `Closet-Archive-llm-wiki-w` | `llm-wiki-wiki-entities-He`, `Wiki-llm-wiki-wiki-entiti`, `Ocean-Depth-llm-wiki-wiki` |
| Team Onboarding SOP | `Wiki-Concepts-Team-Onboar`, `Wiki-Concepts-SOP-Team-On`, `Closet-Concepts-SOP-Team-` | `Ocean-Chart-SOP-Team-Onbo`, `Wiki-Concepts-SOP-Team-On`, `Closet-Concepts-SOP-Team-` |
| Bot Team Architecture | `Wiki-Concepts-Bot-Team-Ar`, `Wiki-Concepts-CLSC-Spec`, `Wiki-Concepts-Team-Onboar` | `Ocean-Chart-Architecture-`, `Wiki-Concepts-Architectur`, `Closet-Concepts-Architect` |
| knowledge infra proposal anya | `Wiki-Research-knowledge-i`, `Closet-Research-knowledge`, `Ocean-Research-knowledge-` | `Wiki-Research-knowledge-i`, `Ocean-Research-knowledge-`, `Closet-Research-knowledge` |
| mempalace vs channellab architecture | `Wiki-Research-mempalace-v`, `Closet-Research-mempalace`, `Ocean-Research-mempalace-` | `Wiki-Research-mempalace-v`, `Ocean-Research-mempalace-`, `Closet-Research-mempalace` |
| GAIA  Account manager JD (Malaysia) | `Wiki-llm-wiki-wiki-entiti`, `Wiki-llm-wiki-wiki-entiti`, `Wiki-llm-wiki-wiki-source` | `llm-wiki-wiki-entities`, `Wiki-llm-wiki-wiki-entiti`, `Ocean-Depth-llm-wiki-wiki` |
| browser automation landscape | `Wiki-Concepts-browser-aut`, `Wiki-Reviews-CR-20260408-`, `Wiki-Concepts-Architectur` | `Wiki-Concepts-browser-aut`, `Ocean-Chart-Architecture-`, `Wiki-Concepts-Architectur` |

**All three modes miss (1 queries):**

- `市场部工作内容拆解`

## 3. Ranking Quality Analysis (OR vs FTS5)

For queries that hit in BOTH OR and FTS5:

| Metric | Overall | English | Chinese |
|---|---|---|---|
| Queries compared | 53 | 44 | 9 |
| Same top-1 | 27 (50.9%) | 19 (43.2%) | 8 (88.9%) |
| Avg Jaccard top-3 | 0.459 | 0.389 | 0.800 |

**Queries with different rankings (35):**

| Set | Query | Lang | Top-1 Same? | Jaccard | FTS Mode |
|---|---|---|---|---|---|
| A | ChannelLab | EN | **No** | 0.000 | fts5 |
| A | obsidian headless MCP REST API | EN | Yes | 0.500 | fts5 |
| A | ibon ticket bot playwright | EN | **No** | 0.000 | fts5 |
| A | CLSC dictionary | EN | **No** | 0.000 | fts5 |
| A | closet migrate wiki vault skeleton | EN | **No** | 0.200 | fts5 |
| A | CLSC skeleton | EN | **No** | 0.000 | fts5 |
| A | channellab GEO | EN | **No** | 0.000 | fts5 |
| A | GEO service pricing | EN | **No** | 0.000 | fts5 |
| A | wings room skeleton clsc aaak | EN | Yes | 0.200 | fts5 |
| A | GEO | EN | **No** | 0.000 | fts5 |
| A | ocean rename metaphor currents pear | EN | Yes | 0.500 | fts5 |
| A | ChannelLab | EN | **No** | 0.000 | fts5 |
| A | Knowledge | EN | **No** | 0.000 | fts5 |
| A | task queue | EN | **No** | 0.000 | fts5 |
| A | Knowledge | EN | **No** | 0.000 | fts5 |
| A | task queue | EN | **No** | 0.000 | fts5 |
| A | FATQ protocol | EN | **No** | 0.200 | fts5 |
| B | API Next proxy | EN | **No** | 0.500 | fts5 |
| B | 找合作方 調度 Nicky | ZH | **No** | 0.000 | fts5 |
| B | Dashboard 做完建議後的預估分數 媒體 | ZH | Yes | 0.200 | fts5 |
| ... | *15 more* | | | | |

## 4. Token Savings (Three-way)

| Metric | AND | OR | FTS5+BM25 |
|---|---|---|---|
| Hits analyzed | 214 | 484 | 474 |
| Path A (skeleton-first) | 119,769 | 302,766 | 256,135 |
| Path B (read original) | 481,413 | 1,246,364 | 1,098,933 |
| **Tokens saved** | **361,644** | **943,598** | **842,798** |
| **Savings %** | **75.1%** | **75.7%** | **76.7%** |
| Fallback rate | 10.5% | 10.5% | 10.5% |

## 5. FTS5 Fallback Analysis

| Set | Total Queries | FTS5 Direct | OR Fallback | Both Miss |
|---|---|---|---|---|
| A: Real log | 26 | 19 (73%) | 4 (15%) | 3 (12%) |
| B: Msg-sampled | 20 | 9 (45%) | 2 (10%) | 9 (45%) |
| C: Ocean files | 20 | 18 (90%) | 1 (5%) | 1 (5%) |
| **Total** | **66** | **46** (70%) | **7** (11%) | **13** (20%) |

### Fallback Detail

**Set A — FTS5 miss, OR fallback hit (4):**
- `日本 商務 JD` -> 10 hits via OR
- `日本 業務 職缺` -> 10 hits via OR
- `團隊` -> 10 hits via OR
- `團隊` -> 10 hits via OR

**Set A — Both miss (3):**
- `履歷 候選人`
- `xyznonexistent`
- `xyznonexistent`

**Set B — FTS5 miss, OR fallback hit (2):**
- `Anyachl_bot 收到 待命中` -> 5 hits via OR
- `有幾個小 QA 留白充足` -> 8 hits via OR

**Set B — Both miss (9):**
- `等三菜完成後開始審查 不動設定 CarrotAAA_bot`
- `之後再來整理好了 我們繼續討論wiki 我們的01`
- `0x167fBF7E0826A2c266090c27Cc4ba362b9815D36 0x92e4f1731f2ef18856ed6592fcc0bf55f37c2e1f 地址`
- `不能只看 通過了 通過但`
- `一眼看懂 新版乾淨很多 一行說明`
- `開始合併兩個 branch annadesu_bot`
- `聯創只拿分紅 團隊激勵直接給到員工`
- `Designer 錢包設計稿在排隊中 TwinkleCHL_bot`
- `TwinkleCHL_bot 啟動自我檢視`

**Set C — FTS5 miss, OR fallback hit (1):**
- `菜姐` -> 10 hits via OR

**Set C — Both miss (1):**
- `市场部工作内容拆解`

---
*Generated by `clsc-benchmark-search-v3.py` on 2026-04-10 10:13:49*