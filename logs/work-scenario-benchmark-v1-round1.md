# MemOcean Work Scenario Benchmark v1

Run: 2026-04-12 19:20:39

Corpus: 289 closet entries, 806 KG entities, 828 KG triples

Questions: 200 total

## 1. Overall Hit@K

### Seabed Search (156 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 3.9% (6) | 4.5% (7) | 4.5% (7) | 4.5% (7) |
| OR | 12.2% (19) | 17.3% (27) | 19.9% (31) | 21.8% (34) |
| FTS5+BM25 | 12.2% (19) | 17.3% (27) | 19.9% (31) | 21.8% (34) |

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
| AND | 0.0% | 0.0% | 0.0% | 0.0% |
| OR | 0.0% | 5.9% | 11.8% | 11.8% |
| FTS5+BM25 | 0.0% | 5.9% | 11.8% | 11.8% |

Messages FTS5: Hit@1=50.0% Hit@3=50.0% Hit@5=50.0% Hit@10=50.0%

KG: 100.0% (1/1)

### decision_record (20 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 5.9% | 5.9% | 5.9% | 5.9% |
| OR | 5.9% | 11.8% | 11.8% | 11.8% |
| FTS5+BM25 | 5.9% | 11.8% | 11.8% | 11.8% |

Messages FTS5: Hit@1=100.0% Hit@3=100.0% Hit@5=100.0% Hit@10=100.0%

### org_structure (15 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 0.0% | 0.0% | 0.0% | 0.0% |
| OR | 0.0% | 12.5% | 12.5% | 25.0% |
| FTS5+BM25 | 0.0% | 12.5% | 12.5% | 25.0% |

Messages FTS5: Hit@1=0.0% Hit@3=0.0% Hit@5=100.0% Hit@10=100.0%

KG: 100.0% (6/6)

### person_lookup (20 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 9.1% | 9.1% | 9.1% | 9.1% |
| OR | 9.1% | 9.1% | 9.1% | 18.2% |
| FTS5+BM25 | 9.1% | 9.1% | 9.1% | 18.2% |

Messages FTS5: Hit@1=50.0% Hit@3=50.0% Hit@5=50.0% Hit@10=50.0%

KG: 100.0% (7/7)

### process_sop (20 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 5.9% | 5.9% | 5.9% | 5.9% |
| OR | 11.8% | 23.5% | 29.4% | 29.4% |
| FTS5+BM25 | 11.8% | 23.5% | 29.4% | 29.4% |

Messages FTS5: Hit@1=33.3% Hit@3=33.3% Hit@5=33.3% Hit@10=66.7%

### product_feature (20 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 11.1% | 11.1% | 11.1% | 11.1% |
| OR | 33.3% | 38.9% | 50.0% | 50.0% |
| FTS5+BM25 | 33.3% | 38.9% | 50.0% | 50.0% |

Messages FTS5: Hit@1=100.0% Hit@3=100.0% Hit@5=100.0% Hit@10=100.0%

### project_info (25 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 0.0% | 0.0% | 0.0% | 0.0% |
| OR | 15.8% | 21.1% | 21.1% | 21.1% |
| FTS5+BM25 | 15.8% | 21.1% | 21.1% | 21.1% |

Messages FTS5: Hit@1=50.0% Hit@3=50.0% Hit@5=50.0% Hit@10=50.0%

KG: 100.0% (2/2)

### semantic_fuzzy (20 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 0.0% | 0.0% | 0.0% | 0.0% |
| OR | 5.9% | 5.9% | 5.9% | 5.9% |
| FTS5+BM25 | 5.9% | 5.9% | 5.9% | 5.9% |

Messages FTS5: Hit@1=50.0% Hit@3=50.0% Hit@5=50.0% Hit@10=100.0%

KG: 100.0% (1/1)

### tech_architecture (25 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 0.0% | 5.0% | 5.0% | 5.0% |
| OR | 0.0% | 5.0% | 5.0% | 10.0% |
| FTS5+BM25 | 0.0% | 5.0% | 5.0% | 10.0% |

Messages FTS5: Hit@1=100.0% Hit@3=100.0% Hit@5=100.0% Hit@10=100.0%

KG: 100.0% (2/2)

### temporal_reasoning (15 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 8.3% | 8.3% | 8.3% | 8.3% |
| OR | 41.7% | 41.7% | 41.7% | 41.7% |
| FTS5+BM25 | 41.7% | 41.7% | 41.7% | 41.7% |

Messages FTS5: Hit@1=33.3% Hit@3=33.3% Hit@5=33.3% Hit@10=33.3%

## 3. Per-Difficulty Breakdown

### Seabed Search by Difficulty

| Difficulty | Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 | N |
|---|---|---|---|---|---|---|
| easy | AND | 8.5% | 10.2% | 10.2% | 10.2% | 59 |
| easy | OR | 17.0% | 25.4% | 27.1% | 30.5% | 59 |
| easy | FTS5+BM25 | 17.0% | 25.4% | 27.1% | 30.5% | 59 |
| medium | AND | 1.7% | 1.7% | 1.7% | 1.7% | 60 |
| medium | OR | 11.7% | 15.0% | 18.3% | 20.0% | 60 |
| medium | FTS5+BM25 | 11.7% | 15.0% | 18.3% | 20.0% | 60 |
| hard | AND | 0.0% | 0.0% | 0.0% | 0.0% | 37 |
| hard | OR | 5.4% | 8.1% | 10.8% | 10.8% | 37 |
| hard | FTS5+BM25 | 5.4% | 8.1% | 10.8% | 10.8% | 37 |

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

### Seabed Failures (122)

| ID | Scene | Diff | Query | Expected | AND Top-3 | OR Top-3 | FTS5 Top-3 |
|---|---|---|---|---|---|---|---|
| 1 | person_lookup | easy | Nicky 角色 職責 | `Wiki-Concepts-ChannelLab-AI-Ar`, `Wiki-Concepts-Architecture-Cha` | --- | `Chart-Architecture-Channe`, `Currents-ChannelLab-Org-P`, `Currents-ChannelLab-Org-p` | `Chart-Architecture-Channe`, `Currents-ChannelLab-Org-P`, `Currents-ChannelLab-Org-p` |
| 2 | person_lookup | easy | Ron 個性 | `Wiki-Concepts-ChannelLab-AI-Ar`, `Wiki-Concepts-Architecture-Cha` | --- | `claude-skills-obsidian-ma`, `BOT-bots-Bella-CLAUDE`, `BOT-bots-anya-blocks-bloc` | `claude-skills-obsidian-ma`, `BOT-bots-Bella-CLAUDE`, `BOT-bots-anya-blocks-bloc` |
| 3 | person_lookup | easy | 老兔 決策風格 | `Wiki-People`, `Closet-People` | --- | `BOT-bots-Bella-CLAUDE`, `BOT-bots-anna-CLAUDE`, `BOT-bots-anya-CLAUDE` | `BOT-bots-Bella-CLAUDE`, `BOT-bots-anna-CLAUDE`, `BOT-bots-anya-CLAUDE` |
| 4 | person_lookup | easy | 菜姐 角色 | `Ocean-Currents-ChannelLab-Org-`, `Closet-Wings-ChannelLab-Org-Pe` | --- | `BOT-bots-caijie-zhuchu-CL`, `BOT-bots-chltao-CLAUDE`, `BOT-bots-sancai-CLAUDE` | `BOT-bots-caijie-zhuchu-CL`, `BOT-bots-chltao-CLAUDE`, `BOT-bots-sancai-CLAUDE` |
| 7 | person_lookup | easy | Anna builder 角色 | `Ocean-Chart-Bot-System-bots-an`, `Currents-ChannelLab-Org-Bot-Us` | --- | `BOT-bots-Bella-CLAUDE`, `BOT-bots-anna-CLAUDE`, `BOT-bots-anya-blocks-bloc` | `BOT-bots-Bella-CLAUDE`, `BOT-bots-anna-CLAUDE`, `BOT-bots-anya-blocks-bloc` |
| 11 | person_lookup | medium | Builder 團隊成員 | `Wiki-Concepts-Architecture-Bot`, `Closet-Concepts-Architecture-B` | --- | `BOT-bots-Bella-CLAUDE`, `BOT-bots-anna-CLAUDE`, `BOT-bots-anya-blocks-bloc` | `BOT-bots-Bella-CLAUDE`, `BOT-bots-anna-CLAUDE`, `BOT-bots-anya-blocks-bloc` |
| 15 | person_lookup | hard | 知識基礎設施 提案 作者 | `Wiki-Research-knowledge-infra-`, `Wiki-Research-knowledge-infra-` | --- | `Chart-CLSC-CLSC-Technical`, `Ocean-Chart-CLSC-CLSC-Tec`, `Ocean-Research-knowledge-` | `Chart-CLSC-CLSC-Technical`, `Ocean-Chart-CLSC-CLSC-Tec`, `Ocean-Research-knowledge-` |
| 16 | person_lookup | easy | Nick Spisak method | `Wiki-Research-nick-spisak-meth`, `Wiki-Cards-nick-spisak-method` | `Ocean-Research-nick-spisa`, `Research-nick-spisak-meth` | `Ocean-Research-nick-spisa`, `Research-nick-spisak-meth`, `BOT-bots-nicky-builder-CL` | `Ocean-Research-nick-spisa`, `Research-nick-spisak-meth`, `BOT-bots-nicky-builder-CL` |
| 17 | person_lookup | medium | Steph Ango kepano agent s | `Wiki-Research-kepano-obsidian-`, `Wiki-Cards-kepano-obsidian-ski` | --- | `Ocean-Research-kepano-obs`, `Research-kepano-obsidian-`, `Chart-crypto-ai-skills-sh` | `Ocean-Research-kepano-obs`, `Research-kepano-obsidian-`, `Chart-crypto-ai-skills-sh` |
| 21 | project_info | easy | Bonk GEO 提案 進度 | `Wiki-Projects-Bonk-GEO`, `Assets-Portfolio-Bonk-Bonk_GEO` | --- | `Currents-ChannelLab-GEO-B`, `Ocean-Currents-ChannelLab`, `Currents-ChannelLab-Produ` | `Currents-ChannelLab-GEO-B`, `Ocean-Currents-ChannelLab`, `Currents-ChannelLab-Produ` |
| 22 | project_info | easy | 南良集團 合作 | `Wiki-Companies-NanLiang`, `Closet-Companies-NanLiang` | `Currents-ChannelLab-GEO-C`, `Ocean-Currents-ChannelLab` | `Currents-ChannelLab-GEO-C`, `Ocean-Currents-ChannelLab`, `BOT-bots-nicky-zhanglingh` | `Currents-ChannelLab-GEO-C`, `Ocean-Currents-ChannelLab`, `BOT-bots-nicky-zhanglingh` |
| 23 | project_info | easy | QuBitDEX GEO | `Wiki-Projects-QuBitDEX-GEO`, `Closet-Projects-QuBitDEX-GEO` | `Currents-ChannelLab-GEO-Q`, `Currents-ChannelLab-Produ`, `Ocean-Currents-ChannelLab` | `Currents-ChannelLab-GEO-Q`, `Currents-ChannelLab-Produ`, `Ocean-Currents-ChannelLab` | `Currents-ChannelLab-GEO-Q`, `Currents-ChannelLab-Produ`, `Ocean-Currents-ChannelLab` |
| 24 | project_info | easy | GWIN RWA 白皮書 | `Wiki-Projects-GWIN-RWA`, `Closet-Projects-GWIN-RWA` | `Currents-ChannelLab-GEO-G`, `Ocean-Currents-ChannelLab` | `Currents-ChannelLab-GEO-G`, `Ocean-Currents-ChannelLab`, `Currents-ChannelLab-GEO-C` | `Currents-ChannelLab-GEO-G`, `Ocean-Currents-ChannelLab`, `Currents-ChannelLab-GEO-C` |
| 25 | project_info | medium | Canalis Angel 融資 營收 | `Wiki-Deals-Canalis_Angel`, `Closet-Deals-Canalis_Angel` | --- | `Currents-ChannelLab-GEO-D`, `Ocean-Currents-ChannelLab` | `Currents-ChannelLab-GEO-D`, `Ocean-Currents-ChannelLab` |
| 28 | project_info | medium | Gene Capital APY 量化 | `Wiki-Companies-Gene-Capital`, `Closet-Companies-Gene-Capital` | --- | `Currents-NOXCAT-Gene-Capi`, `Ocean-Currents-NOXCAT-Gen`, `BOT-shared-team-l0` | `Currents-NOXCAT-Gene-Capi`, `Ocean-Currents-NOXCAT-Gen`, `BOT-shared-team-l0` |
| 30 | project_info | medium | Anya Voice Assistant 技術 | `Wiki-Concepts-ChannelLab-AI-Ar`, `Wiki-Concepts-Team-Onboarding-` | --- | `Ocean-Research-graphify-r`, `Research-graphify-researc`, `Chart-CLSC-CLSC-dogfood-w` | `Ocean-Research-graphify-r`, `Research-graphify-researc`, `Chart-CLSC-CLSC-dogfood-w` |
| 31 | project_info | easy | Bonk Google AIO | `Wiki-Projects-Bonk-AIO-Strateg`, `Assets-Portfolio-Bonk-Bonk_Goo` | `Currents-ChannelLab-GEO-B`, `Ocean-Currents-ChannelLab` | `Currents-ChannelLab-GEO-B`, `Ocean-Currents-ChannelLab`, `BOT-bots-anya-blocks-bloc` | `Currents-ChannelLab-GEO-B`, `Ocean-Currents-ChannelLab`, `BOT-bots-anya-blocks-bloc` |
| 34 | project_info | easy | ChannelLab 進行中 專案 | `Wiki-Cards-ChannelLab`, `Wiki-Concepts-channellab-bot-f` | --- | `Chart-ADR-CLSC`, `Currents-ChannelLab-GEO-C`, `Currents-ChannelLab-Org-C` | `Chart-ADR-CLSC`, `Currents-ChannelLab-GEO-C`, `Currents-ChannelLab-Org-C` |
| 37 | project_info | hard | 南良 ESG 碳稅 | `Wiki-Companies-NanLiang`, `Closet-Companies-NanLiang` | --- | `Currents-ChannelLab-GEO-C`, `Ocean-Currents-ChannelLab`, `Currents-ChannelLab-GEO-D` | `Currents-ChannelLab-GEO-C`, `Ocean-Currents-ChannelLab`, `Currents-ChannelLab-GEO-D` |
| 41 | project_info | medium | 媒體 報價 資源 | `Wiki-Concepts-Media-Pricing`, `Closet-Concepts-Media-Pricing` | `Chart-Media-Pricing`, `Ocean-Chart-Media-Pricing` | `Chart-Media-Pricing`, `Ocean-Chart-Media-Pricing`, `Currents-ChannelLab-GEO-M` | `Chart-Media-Pricing`, `Ocean-Chart-Media-Pricing`, `Currents-ChannelLab-GEO-M` |
| 42 | project_info | easy | hermes agent 研究 | `Wiki-Research-hermes-agent-res`, `Closet-Research-hermes-agent-r` | `Ocean-Research-hermes-age`, `Research-hermes-agent-res` | `Ocean-Research-hermes-age`, `Research-hermes-agent-res`, `Ocean-Research-0xKingsKua` | `Ocean-Research-hermes-age`, `Research-hermes-agent-res`, `Ocean-Research-0xKingsKua` |
| 43 | project_info | easy | graphify | `Wiki-Research-graphify-researc`, `Wiki-Cards-graphify` | `Ocean-Research-graphify-r`, `Research-graphify-researc` | `Ocean-Research-graphify-r`, `Research-graphify-researc` | `Ocean-Research-graphify-r`, `Research-graphify-researc` |
| 44 | project_info | medium | ChannelLab Term Sheet | `Wiki-Cards-ChannelLab`, `Wiki-Companies-ChannelLab-GEO-` | `Currents-ChannelLab-Org-C`, `Ocean-Currents-ChannelLab` | `Currents-ChannelLab-Org-C`, `Ocean-Currents-ChannelLab`, `Chart-CLSC-CLSC-dogfood-w` | `Currents-ChannelLab-Org-C`, `Ocean-Currents-ChannelLab`, `Chart-CLSC-CLSC-dogfood-w` |
| 45 | project_info | medium | deals schema | `Wiki-Deals-_README`, `Closet-Deals-_README` | `Chart-ADR-Knowledge-Infra`, `Currents-ChannelLab-GEO-D`, `Ocean-Chart-ADR-Knowledge` | `Chart-ADR-Knowledge-Infra`, `Currents-ChannelLab-GEO-D`, `Ocean-Chart-ADR-Knowledge` | `Chart-ADR-Knowledge-Infra`, `Currents-ChannelLab-GEO-D`, `Ocean-Chart-ADR-Knowledge` |
| 46 | tech_architectu | easy | CLSC 壓縮率 結果 | `Wiki-Concepts-CLSC-empirical-r`, `Closet-Concepts-CLSC-CLSC-empi` | `Chart-ADR-CLSC`, `Depth-CLSC-Spec`, `Ocean-Chart-ADR-CLSC` | `Chart-ADR-CLSC`, `Depth-CLSC-Spec`, `Ocean-Chart-ADR-CLSC` | `Chart-ADR-CLSC`, `Depth-CLSC-Spec`, `Ocean-Chart-ADR-CLSC` |
| 48 | tech_architectu | easy | CLSC 是什麼 | `Wiki-Concepts-CLSC-CLSC`, `Closet-Concepts-CLSC-CLSC` | `Chart-ADR-CLSC`, `Ocean-Chart-ADR-CLSC` | `Chart-ADR-CLSC`, `Ocean-Chart-ADR-CLSC`, `BOT-bots-CLAUDE` | `Chart-ADR-CLSC`, `Ocean-Chart-ADR-CLSC`, `BOT-bots-CLAUDE` |
| 49 | tech_architectu | medium | FTS5 跨 bot 搜尋 速度 | `Wiki-Concepts-FTS5-bot`, `Closet-Concepts-FTS5-bot` | --- | `Chart-FATQ`, `Chart-FTS5-bot`, `Ocean-Chart-FATQ` | `Chart-FATQ`, `Chart-FTS5-bot`, `Ocean-Chart-FATQ` |
| 51 | tech_architectu | easy | CLSC Technical Spec 中文 | `Wiki-Concepts-CLSC-Technical-S`, `Wiki-Concepts-CLSC-Spec` | `Chart-CLSC-CLSC-Technical`, `Chart-CLSC-CLSC-Technical`, `Ocean-Chart-CLSC-CLSC-Tec` | `Chart-CLSC-CLSC-Technical`, `Chart-CLSC-CLSC-Technical`, `Ocean-Chart-CLSC-CLSC-Tec` | `Chart-CLSC-CLSC-Technical`, `Chart-CLSC-CLSC-Technical`, `Ocean-Chart-CLSC-CLSC-Tec` |
| 52 | tech_architectu | medium | 瀏覽器自動化 比較 | `Wiki-Concepts-browser-automati`, `Closet-Concepts-Architecture-b` | --- | `Ocean-Research-0xKingsKua`, `Ocean-Research-agent-brow`, `Ocean-Reviews-CLSC-v0-5-U` | `Ocean-Research-0xKingsKua`, `Ocean-Research-agent-brow`, `Ocean-Reviews-CLSC-v0-5-U` |
| 53 | tech_architectu | medium | Playwright gstack 比較 | `Wiki-Cards-Playwright-MCP-vs-g`, `Closet-Cards-Playwright-MCP-vs` | --- | `BOT-bots-CLAUDE`, `BOT-bots-nicky-zhanglingh`, `Chart-Architecture-Channe` | `BOT-bots-CLAUDE`, `BOT-bots-nicky-zhanglingh`, `Chart-Architecture-Channe` |
| 54 | tech_architectu | easy | 三 Bot 架構 | `Wiki-Concepts-Architecture-cha`, `Closet-Concepts-Architecture-B` | `BOT-bots-CLAUDE`, `BOT-bots-anya-blocks-bloc`, `BOT-bots-anya-blocks-bloc` | `BOT-bots-CLAUDE`, `BOT-bots-anya-blocks-bloc`, `BOT-bots-anya-blocks-bloc` | `BOT-bots-CLAUDE`, `BOT-bots-anya-blocks-bloc`, `BOT-bots-anya-blocks-bloc` |
| 55 | tech_architectu | medium | CLSC v0.6 HanCloset REJEC | `Wiki-Reviews-CR-20260408-clsc-`, `Closet-Reviews-CR-20260408-cls` | --- | `Chart-CLSC-CLSC`, `Ocean-Chart-CLSC-CLSC`, `Ocean-Reviews-CR-20260408` | `Chart-CLSC-CLSC`, `Ocean-Chart-CLSC-CLSC`, `Ocean-Reviews-CR-20260408` |
| 56 | tech_architectu | easy | CLSC v0.7 審查 | `Wiki-Reviews-CR-20260408-clsc-`, `Closet-Reviews-CR-20260408-cls` | --- | `Chart-CLSC-CLSC`, `Ocean-Chart-CLSC-CLSC`, `Ocean-Research-mempalace-` | `Chart-CLSC-CLSC`, `Ocean-Chart-CLSC-CLSC`, `Ocean-Research-mempalace-` |
| 57 | tech_architectu | easy | agent-browser Rust | `Wiki-Cards-agent-browser`, `Wiki-Research-agent-browser-re` | `Ocean-Research-agent-brow`, `Research-agent-browser-re` | `Ocean-Research-agent-brow`, `Research-agent-browser-re`, `BOT-bots-Bella-CLAUDE` | `Ocean-Research-agent-brow`, `Research-agent-browser-re`, `BOT-bots-Bella-CLAUDE` |
| 58 | tech_architectu | medium | 中文 LLM token 壓縮 市場 | `Wiki-Research-chinese-llm-comp`, `Closet-Research-chinese-llm-co` | --- | `Chart-CLSC-CLSC-Technical`, `Chart-CLSC-CLSC`, `Depth-CLSC-Spec` | `Chart-CLSC-CLSC-Technical`, `Chart-CLSC-CLSC`, `Depth-CLSC-Spec` |
| 59 | tech_architectu | medium | ZK proof 2026 調研 | `Wiki-Research-ZK-2026-survey`, `Closet-Research-ZK-2026-survey` | `Ocean-Research-ZK-2026-su`, `Research-ZK-2026-survey` | `Ocean-Research-ZK-2026-su`, `Research-ZK-2026-survey`, `BOT-_index` | `Ocean-Research-ZK-2026-su`, `Research-ZK-2026-survey`, `BOT-_index` |
| 60 | tech_architectu | easy | EIP-8141 | `Wiki-llm-wiki-wiki-entities-EI`, `Closet-Archive-llm-wiki-wiki-e` | `Depth-llm-wiki-Seabed-art`, `Depth-llm-wiki-wiki-entit`, `Depth-llm-wiki-wiki-entit` | `Depth-llm-wiki-Seabed-art`, `Depth-llm-wiki-wiki-entit`, `Depth-llm-wiki-wiki-entit` | `Depth-llm-wiki-Seabed-art`, `Depth-llm-wiki-wiki-entit`, `Depth-llm-wiki-wiki-entit` |
| 63 | tech_architectu | medium | CLSC dogfood 命中率 | `Wiki-Concepts-CLSC-dogfood-wee`, `Closet-Concepts-CLSC-CLSC-dogf` | --- | `Chart-CLSC-CLSC-dogfood-w`, `Ocean-Chart-CLSC-CLSC-dog`, `BOT-bots-CLAUDE` | `Chart-CLSC-CLSC-dogfood-w`, `Ocean-Chart-CLSC-CLSC-dog`, `BOT-bots-CLAUDE` |
| 65 | tech_architectu | medium | inotify daemon 效能 | `Wiki-Reviews-CR-20260408-inoti`, `Closet-Reviews-CR-20260408-ino` | --- | `Chart-FATQ`, `Ocean-Chart-FATQ`, `Ocean-Research-ZK-2026-su` | `Chart-FATQ`, `Ocean-Chart-FATQ`, `Ocean-Research-ZK-2026-su` |
| 66 | tech_architectu | medium | temporal KG fork 審查 | `Wiki-Reviews-CR-20260408-tempo`, `Closet-Reviews-CR-20260408-tem` | --- | `Ocean-Reviews-CR-20260408`, `Reviews-CR-20260408-tempo`, `BOT-bots-Bella-CLAUDE` | `Ocean-Reviews-CR-20260408`, `Reviews-CR-20260408-tempo`, `BOT-bots-Bella-CLAUDE` |
| 67 | tech_architectu | hard | mempalace ChannelLab 架構 比 | `Wiki-Research-mempalace-vs-cha`, `Closet-Research-mempalace-vs-c` | --- | `Chart-MemOcean`, `Ocean-Chart-MemOcean`, `Ocean-Research-mempalace-` | `Chart-MemOcean`, `Ocean-Chart-MemOcean`, `Ocean-Research-mempalace-` |
| 69 | tech_architectu | medium | channellab-kb-mcp 安全 漏洞 | `Wiki-Reviews-CR-20260408-chann`, `Closet-Reviews-CR-20260408-cha` | --- | `BOT-bots-Bella-CLAUDE`, `BOT-bots-yitang-CLAUDE`, `Chart-Architecture-channe` | `BOT-bots-Bella-CLAUDE`, `BOT-bots-yitang-CLAUDE`, `Chart-Architecture-channe` |
| 71 | decision_record | easy | CLSC 為什麼殺掉 | `Wiki-Reviews-CR-20260408-clsc-`, `Wiki-Reviews-CR-20260408-clsc-` | `Chart-ADR-CLSC`, `Ocean-Chart-ADR-CLSC` | `Chart-ADR-CLSC`, `Ocean-Chart-ADR-CLSC`, `BOT-bots-CLAUDE` | `Chart-ADR-CLSC`, `Ocean-Chart-ADR-CLSC`, `BOT-bots-CLAUDE` |
| 73 | decision_record | medium | Notion Obsidian 分工 | `Wiki-Concepts-Knowledge-Infra-`, `Closet-Concepts-ADR-Knowledge-` | `Ocean-Research-knowledge-`, `Research-knowledge-infra-` | `Ocean-Research-knowledge-`, `Research-knowledge-infra-`, `BOT-bots-anya-CLAUDE` | `Ocean-Research-knowledge-`, `Research-knowledge-infra-`, `BOT-bots-anya-CLAUDE` |
| 74 | decision_record | hard | Redis 任務佇列 為什麼不用 | `Wiki-Cards-FATQ-File-Atomic-Ta`, `Closet-Cards-FATQ-File-Atomic-` | --- | --- | --- |
| 75 | decision_record | medium | CLSC v0.3 字典 失敗 | `Wiki-Reviews-CR-20260408-clsc-`, `Closet-Reviews-CR-20260408-cls` | --- | `Chart-CLSC-CLSC`, `Ocean-Chart-CLSC-CLSC`, `Ocean-Reviews-CR-20260408` | `Chart-CLSC-CLSC`, `Ocean-Chart-CLSC-CLSC`, `Ocean-Reviews-CR-20260408` |
| 77 | decision_record | medium | VPS 基礎設施 審計 | `Wiki-Reviews-CR-20260408-vps-s`, `Closet-Reviews-CR-20260408-vps` | --- | `Ocean-Research-knowledge-`, `Research-knowledge-infra-`, `BOT-bots-anya-blocks-bloc` | `Ocean-Research-knowledge-`, `Research-knowledge-infra-`, `BOT-bots-anya-blocks-bloc` |
| 78 | decision_record | hard | Obsidian 唯一真相源 SSOT | `Wiki-Research-knowledge-infra-`, `Closet-Research-knowledge-infr` | `Ocean-Research-knowledge-`, `Research-knowledge-infra-` | `Ocean-Research-knowledge-`, `Research-knowledge-infra-`, `Chart-ADR-Knowledge-Infra` | `Ocean-Research-knowledge-`, `Research-knowledge-infra-`, `Chart-ADR-Knowledge-Infra` |
| 79 | decision_record | medium | auto schema evolution | `Wiki-Research-auto-schema-evol`, `Closet-Research-auto-schema-ev` | --- | `Ocean-Research-auto-schem`, `Research-auto-schema-evol`, `BOT-shared-team-l0` | `Ocean-Research-auto-schem`, `Research-auto-schema-evol`, `BOT-shared-team-l0` |
| 80 | decision_record | hard | CLSC v0.4 shorthand 壓縮 | `Wiki-Reviews-CR-20260408-clsc-`, `Closet-Reviews-CR-20260408-cls` | --- | `Chart-CLSC-CLSC-Test-Spec`, `Depth-CLSC-Spec`, `Ocean-Chart-CLSC-CLSC-Tes` | `Chart-CLSC-CLSC-Test-Spec`, `Depth-CLSC-Spec`, `Ocean-Chart-CLSC-CLSC-Tes` |
| 81 | decision_record | medium | L1 英文 系統提示詞 token | `Wiki-Research-chinese-claude-t`, `Closet-Reviews-chinese-claude-` | --- | `Chart-CLSC-CLSC-Technical`, `Ocean-Chart-CLSC-CLSC-Tec`, `Chart-CLSC-CLSC-Technical` | `Chart-CLSC-CLSC-Technical`, `Ocean-Chart-CLSC-CLSC-Tec`, `Chart-CLSC-CLSC-Technical` |
| 83 | decision_record | medium | team-config centralizatio | `Wiki-Reviews-CR-20260408-team-`, `Closet-Reviews-CR-20260408-tea` | --- | `Ocean-Reviews-CR-20260408`, `Reviews-CR-20260408-team-`, `BOT-bots-Bella-CLAUDE` | `Ocean-Reviews-CR-20260408`, `Reviews-CR-20260408-team-`, `BOT-bots-Bella-CLAUDE` |
| 84 | decision_record | easy | CLSC closet backfill 審查 | `Wiki-Reviews-CR-20260408-clsc-`, `Closet-Reviews-CR-20260408-cls` | --- | `Ocean-Reviews-CR-20260408`, `Reviews-CR-20260408-clsc-`, `Chart-CLSC-CLSC-Technical` | `Ocean-Reviews-CR-20260408`, `Reviews-CR-20260408-clsc-`, `Chart-CLSC-CLSC-Technical` |
| 85 | decision_record | hard | Panda 知識基礎設施 提案 | `Wiki-Research-knowledge-infra-`, `Closet-Research-knowledge-infr` | `Ocean-Research-knowledge-`, `Research-knowledge-infra-` | `Ocean-Research-knowledge-`, `Research-knowledge-infra-`, `Chart-ADR-Knowledge-Infra` | `Ocean-Research-knowledge-`, `Research-knowledge-infra-`, `Chart-ADR-Knowledge-Infra` |
| 87 | decision_record | medium | browser automation spike  | `Wiki-Reviews-CR-20260408-brows`, `Closet-Reviews-CR-20260408-bro` | --- | `Ocean-Reviews-CR-20260408`, `Ocean-Reviews-CR-20260408`, `Reviews-CR-20260408-brows` | `Ocean-Reviews-CR-20260408`, `Ocean-Reviews-CR-20260408`, `Reviews-CR-20260408-brows` |
| 89 | decision_record | medium | My Brain Is Full MBIF Cha | `Wiki-Research-gnekt-mybrain-vs`, `Closet-Research-gnekt-mybrain-` | `Ocean-Research-gnekt-mybr`, `Research-gnekt-mybrain-vs` | `Ocean-Research-gnekt-mybr`, `Research-gnekt-mybrain-vs`, `Ocean-Research-nick-spisa` | `Ocean-Research-gnekt-mybr`, `Research-gnekt-mybrain-vs`, `Ocean-Research-nick-spisa` |
| 90 | decision_record | medium | mempalace hook 機制 | `Wiki-Research-mempalace-deep-m`, `Closet-Research-mempalace-deep` | `Ocean-Research-mempalace-`, `Research-mempalace-deep-m` | `Ocean-Research-mempalace-`, `Research-mempalace-deep-m`, `Ocean-Research-knowledge-` | `Ocean-Research-mempalace-`, `Research-mempalace-deep-m`, `Ocean-Research-knowledge-` |
| 91 | process_sop | easy | gstack 八步驟 | `Ocean-Chart-gstack-workflow`, `Ocean-Chart-O2-WorkFlow` | --- | `BOT-bots-CLAUDE`, `BOT-bots-nicky-zhanglingh`, `Chart-Architecture-Channe` | `BOT-bots-CLAUDE`, `BOT-bots-nicky-zhanglingh`, `Chart-Architecture-Channe` |
| 92 | process_sop | easy | 新工具 導入 SOP | `Wiki-Concepts-New-Tool-Adoptio`, `Closet-Concepts-SOP-New-Tool-A` | `Chart-SOP-New-Tool-Adopti`, `Ocean-Chart-SOP-New-Tool-` | `Chart-SOP-New-Tool-Adopti`, `Ocean-Chart-SOP-New-Tool-`, `BOT-bots-CLAUDE` | `Chart-SOP-New-Tool-Adopti`, `Ocean-Chart-SOP-New-Tool-`, `BOT-bots-CLAUDE` |
| 93 | process_sop | easy | 新人 入職 onboarding | `Wiki-Concepts-Team-Onboarding-`, `Closet-Concepts-SOP-Team-Onboa` | --- | `Chart-SOP-Local-Setup-AI-`, `Currents-ChannelLab-Org-p`, `Ocean-Chart-SOP-Local-Set` | `Chart-SOP-Local-Setup-AI-`, `Currents-ChannelLab-Org-p`, `Ocean-Chart-SOP-Local-Set` |
| 94 | process_sop | easy | Google Calendar MCP 多帳號 設 | `Wiki-Concepts-Google-Calendar-`, `Closet-Concepts-SOP-Google-Cal` | `Chart-SOP-Google-Calendar`, `Ocean-Chart-SOP-Google-Ca` | `Chart-SOP-Google-Calendar`, `Ocean-Chart-SOP-Google-Ca`, `BOT-bots-nicky-zhanglingh` | `Chart-SOP-Google-Calendar`, `Ocean-Chart-SOP-Google-Ca`, `BOT-bots-nicky-zhanglingh` |
| 95 | process_sop | easy | 本地環境 部署 SOP | `Wiki-Concepts-SOP-Local-Setup-`, `Closet-Concepts-SOP-Local-Setu` | `Chart-SOP-Local-Setup-AI-`, `Ocean-Chart-SOP-Local-Set` | `Chart-SOP-Local-Setup-AI-`, `Ocean-Chart-SOP-Local-Set`, `BOT-bots-CLAUDE` | `Chart-SOP-Local-Setup-AI-`, `Ocean-Chart-SOP-Local-Set`, `BOT-bots-CLAUDE` |
| 100 | process_sop | medium | Claude Telegram bot 多個 部署 | `Ocean-Chart-Bot-System-claude-`, `Chart-Bot-System-claude-bots-S` | `Chart-Architecture-channe`, `Ocean-Chart-Architecture-` | `Chart-Architecture-channe`, `Ocean-Chart-Architecture-`, `Chart-SOP-Local-Setup-AI-` | `Chart-Architecture-channe`, `Ocean-Chart-Architecture-`, `Chart-SOP-Local-Setup-AI-` |
| 101 | process_sop | medium | background agent 用法 | `Wiki-Cards-Ops-background-agen`, `Wiki-Cards-MCP-background-agen` | --- | `BOT-bots-Bella-CLAUDE`, `BOT-bots-anna-CLAUDE`, `BOT-bots-anya-CLAUDE` | `BOT-bots-Bella-CLAUDE`, `BOT-bots-anna-CLAUDE`, `BOT-bots-anya-CLAUDE` |
| 104 | process_sop | easy | 卡片 筆記 規則 | `Wiki-Cards`, `Ocean-Pearl` | `Depth-CLSC-Spec`, `Ocean-Depth-CLSC-Spec` | `Depth-CLSC-Spec`, `Ocean-Depth-CLSC-Spec`, `Chart-Architecture-Channe` | `Depth-CLSC-Spec`, `Ocean-Depth-CLSC-Spec`, `Chart-Architecture-Channe` |
| 105 | process_sop | medium | LLM Wiki schema | `Closet-Cards-Wiki`, `Wiki-_index` | `Ocean-Research-knowledge-`, `Research-knowledge-infra-` | `Ocean-Research-knowledge-`, `Research-knowledge-infra-`, `Chart-ADR-Knowledge-Infra` | `Ocean-Research-knowledge-`, `Research-knowledge-infra-`, `Chart-ADR-Knowledge-Infra` |
| 106 | process_sop | medium | crypto AI agent skill | `Wiki-Concepts-crypto-ai-skills`, `Closet-Concepts-crypto-ai-skil` | `Chart-crypto-ai-skills-sh`, `Ocean-Chart-crypto-ai-ski` | `Chart-crypto-ai-skills-sh`, `Ocean-Chart-crypto-ai-ski`, `Ocean-Research-gnekt-mybr` | `Chart-crypto-ai-skills-sh`, `Ocean-Chart-crypto-ai-ski`, `Ocean-Research-gnekt-mybr` |
| 108 | process_sop | easy | Syncthing 部署 | `Wiki-Concepts-SOP-Local-Setup-`, `Bot-Config-setup-local-ai-sop` | `Chart-SOP-Local-Setup-AI-`, `Ocean-Chart-SOP-Local-Set` | `Chart-SOP-Local-Setup-AI-`, `Ocean-Chart-SOP-Local-Set`, `BOT-bots-anya-blocks-bloc` | `Chart-SOP-Local-Setup-AI-`, `Ocean-Chart-SOP-Local-Set`, `BOT-bots-anya-blocks-bloc` |
| 109 | process_sop | hard | Dataview 查詢 memory type | `Wiki-Concepts-CLSC-dataview-ex`, `Closet-Concepts-CLSC-dataview-` | --- | `Chart-CLSC-dataview-examp`, `Ocean-Chart-CLSC-dataview`, `Ocean-Research-mempalace-` | `Chart-CLSC-dataview-examp`, `Ocean-Chart-CLSC-dataview`, `Ocean-Research-mempalace-` |
| 112 | product_feature | medium | GEO 前端 redesign spec | `Wiki-Cards-GEO`, `Wiki-Projects-QuBitDEX-GEO` | --- | `Chart-MemOcean`, `Ocean-Chart-MemOcean`, `BOT-bots-Bella-CLAUDE` | `Chart-MemOcean`, `Ocean-Chart-MemOcean`, `BOT-bots-Bella-CLAUDE` |
| 113 | product_feature | easy | GEO 定價 方案 | `Wiki-Companies-ChannelLab-GEO-`, `Closet-Companies-ChannelLab-GE` | --- | `Currents-ChannelLab-GEO-C`, `Ocean-Currents-ChannelLab`, `BOT-bots-nicky-builder-CL` | `Currents-ChannelLab-GEO-C`, `Ocean-Currents-ChannelLab`, `BOT-bots-nicky-builder-CL` |
| 114 | product_feature | medium | AI 搜尋 流量 年增率 | `Wiki-Companies-ChannelLab-GEO-`, `Closet-Companies-ChannelLab-GE` | `Currents-ChannelLab-GEO-C`, `Ocean-Currents-ChannelLab` | `Currents-ChannelLab-GEO-C`, `Ocean-Currents-ChannelLab`, `Currents-ChannelLab-Produ` | `Currents-ChannelLab-GEO-C`, `Ocean-Currents-ChannelLab`, `Currents-ChannelLab-Produ` |
| 115 | product_feature | easy | NOXCAT 錢包 功能 | `Wiki-Companies-Meta-Assets-MSP`, `Closet-Companies-Meta-Assets-M` | `Currents-NOXCAT-meetings-`, `Ocean-Currents-NOXCAT-mee` | `Currents-NOXCAT-meetings-`, `Ocean-Currents-NOXCAT-mee`, `Currents-NOXCAT-NOXCAT` | `Currents-NOXCAT-meetings-`, `Ocean-Currents-NOXCAT-mee`, `Currents-NOXCAT-NOXCAT` |
| 117 | product_feature | medium | Brand GEO Score | `Wiki-Cards-GEO`, `Closet-Cards-GEO` | --- | `Currents-ChannelLab-Produ`, `Ocean-Currents-ChannelLab`, `Chart-MemOcean` | `Currents-ChannelLab-Produ`, `Ocean-Currents-ChannelLab`, `Chart-MemOcean` |
| 118 | product_feature | easy | GEO 優化 可見度 提升 | `Closet-Projects-GEO-Analyzer-P`, `Wiki-Projects-GEO-Analyzer-PRD` | --- | `Currents-ChannelLab-Produ`, `Ocean-Currents-ChannelLab`, `Currents-ChannelLab-GEO-C` | `Currents-ChannelLab-Produ`, `Ocean-Currents-ChannelLab`, `Currents-ChannelLab-GEO-C` |
| 120 | product_feature | hard | 語意完整度 引用機率 | `Wiki-Projects-Bonk-AIO-Strateg`, `Closet-Projects-Bonk-AIO-Strat` | `Currents-ChannelLab-GEO-B`, `Ocean-Currents-ChannelLab` | `Currents-ChannelLab-GEO-B`, `Ocean-Currents-ChannelLab` | `Currents-ChannelLab-GEO-B`, `Ocean-Currents-ChannelLab` |
| 122 | product_feature | easy | GEO demo | `Wiki-Cards-GEO`, `Closet-Cards-GEO` | `Currents-ChannelLab-Produ`, `Ocean-Currents-ChannelLab` | `Currents-ChannelLab-Produ`, `Ocean-Currents-ChannelLab`, `Chart-MemOcean` | `Currents-ChannelLab-Produ`, `Ocean-Currents-ChannelLab`, `Chart-MemOcean` |
| 124 | product_feature | hard | CLSC drawer closet 架構 | `Wiki-Concepts-CLSC-CLSC-Techni`, `Closet-Concepts-CLSC-CLSC-Tech` | `Chart-CLSC-CLSC-Technical`, `Chart-MemOcean`, `Ocean-Chart-CLSC-CLSC-Tec` | `Chart-CLSC-CLSC-Technical`, `Chart-MemOcean`, `Ocean-Chart-CLSC-CLSC-Tec` | `Chart-CLSC-CLSC-Technical`, `Chart-MemOcean`, `Ocean-Chart-CLSC-CLSC-Tec` |
| 132 | org_structure | easy | ChannelLab 三大引擎 | `Wiki-Cards-ChannelLab`, `Ocean-Pearl-ChannelLab` | --- | `BOT-bots-ops-CLAUDE`, `BOT-shared-team-l0`, `Chart-ADR-Knowledge-Infra` | `BOT-bots-ops-CLAUDE`, `BOT-shared-team-l0`, `Chart-ADR-Knowledge-Infra` |
| 135 | org_structure | easy | ChannelLab 股權結構 | `Wiki-Concepts-ChannelLab-AI-Ar`, `Wiki-Cards-ChannelLab` | `Currents-ChannelLab-Org-C`, `Ocean-Currents-ChannelLab` | `Currents-ChannelLab-Org-C`, `Ocean-Currents-ChannelLab`, `BOT-bots-ops-CLAUDE` | `Currents-ChannelLab-Org-C`, `Ocean-Currents-ChannelLab`, `BOT-bots-ops-CLAUDE` |
| 137 | org_structure | medium | Nicky 股權 激勵 | `Wiki-Companies-ChannelLab-Equi`, `Wiki-Projects-ChannelLab-profi` | --- | `BOT-bots-nicky-builder-CL`, `BOT-bots-nicky-zhanglingh`, `BOT-shared-team-l0` | `BOT-bots-nicky-builder-CL`, `BOT-bots-nicky-zhanglingh`, `BOT-shared-team-l0` |
| 139 | org_structure | medium | Web3 媒體 監控 資源 | `Wiki-Companies-Media-Resource-`, `Closet-Companies-Media-Resourc` | `Currents-ChannelLab-GEO-M`, `Ocean-Currents-ChannelLab` | `Currents-ChannelLab-GEO-M`, `Ocean-Currents-ChannelLab`, `Chart-Media-Pricing` | `Currents-ChannelLab-GEO-M`, `Ocean-Currents-ChannelLab`, `Chart-Media-Pricing` |
| 142 | org_structure | hard | 資本儲備 水位線 | `Wiki-Projects-ChannelLab-profi`, `Closet-Projects-ChannelLab-pro` | --- | --- | --- |
| 144 | org_structure | hard | 期權池 分配 | `Assets-ChannelLab-Equity-_2026`, `Wiki-Projects-ChannelLab-profi` | --- | `Chart-Architecture-channe`, `Currents-ChannelLab-Org-p`, `Ocean-Chart-Architecture-` | `Chart-Architecture-channe`, `Currents-ChannelLab-Org-p`, `Ocean-Chart-Architecture-` |
| 146 | temporal_reason | easy | 2026-04-06 待辦 | `notion-mcp-write-permission`, `notion-mcp-write-permission-xr` | --- | `BOT-bots-anya-blocks-bloc`, `BOT-bots-caijie-zhuchu-CL`, `BOT-bots-chltao-CLAUDE` | `BOT-bots-anya-blocks-bloc`, `BOT-bots-caijie-zhuchu-CL`, `BOT-bots-chltao-CLAUDE` |
| 147 | temporal_reason | easy | 2026-04-08 待辦 | `notion-mcp-write-permission`, `notion-mcp-write-permission-xr` | --- | `BOT-bots-anya-blocks-bloc`, `BOT-bots-anya-blocks-bloc`, `BOT-bots-caijie-zhuchu-CL` | `BOT-bots-anya-blocks-bloc`, `BOT-bots-anya-blocks-bloc`, `BOT-bots-caijie-zhuchu-CL` |
| 150 | temporal_reason | medium | AOT-002 搶票 時間 | `Ocean-Research-CZ-Memoir-Indus`, `Wiki-Reviews-CR-20260408-tempo` | --- | `BOT-_index`, `BOT-bots-caijie-zhuchu-CL`, `BOT-bots-yitang-CLAUDE` | `BOT-_index`, `BOT-bots-caijie-zhuchu-CL`, `BOT-bots-yitang-CLAUDE` |
| 154 | temporal_reason | easy | Anthropic managed agents  | `Wiki-Research-Anthropic-Manage`, `Closet-Research-Anthropic-Mana` | --- | `Ocean-Research-Anthropic-`, `Research-Anthropic-Manage`, `Chart-CLSC-CLSC` | `Ocean-Research-Anthropic-`, `Research-Anthropic-Manage`, `Chart-CLSC-CLSC` |
| 157 | temporal_reason | hard | CBAM 2026 南良 截止 | `Wiki-Companies-NanLiang`, `Closet-Companies-NanLiang` | --- | `Currents-ChannelLab-GEO-C`, `Ocean-Currents-ChannelLab`, `Currents-ChannelLab-GEO-D` | `Currents-ChannelLab-GEO-C`, `Ocean-Currents-ChannelLab`, `Currents-ChannelLab-GEO-D` |
| 159 | temporal_reason | medium | CLSC Dictionary deprecate | `Wiki-Concepts-CLSC-Spec`, `Wiki-Archive-CLSC-Spec` | --- | `Depth-CLSC-Dictionary-Any`, `Depth-CLSC-Dictionary`, `Ocean-Depth-CLSC-Dictiona` | `Depth-CLSC-Dictionary-Any`, `Depth-CLSC-Dictionary`, `Ocean-Depth-CLSC-Dictiona` |
| 160 | temporal_reason | hard | Canalis Angel 營收 年 | `Wiki-Deals-Canalis_Angel`, `Closet-Deals-Canalis_Angel` | --- | `Currents-ChannelLab-GEO-D`, `Ocean-Currents-ChannelLab`, `BOT-bots-anya-CLAUDE` | `Currents-ChannelLab-GEO-D`, `Ocean-Currents-ChannelLab`, `BOT-bots-anya-CLAUDE` |
| 161 | cross_language | easy | Playwright browser automa | `Wiki-Concepts-browser-automati`, `Closet-Concepts-Architecture-b` | --- | `Ocean-Research-agent-brow`, `Ocean-Reviews-CR-20260408`, `Research-agent-browser-re` | `Ocean-Research-agent-brow`, `Ocean-Reviews-CR-20260408`, `Research-agent-browser-re` |
| 163 | cross_language | medium | OAuth 多帳號 Google Calendar | `Wiki-Concepts-Google-Calendar-`, `Closet-Concepts-SOP-Google-Cal` | `Chart-SOP-Google-Calendar`, `Ocean-Chart-SOP-Google-Ca` | `Chart-SOP-Google-Calendar`, `Ocean-Chart-SOP-Google-Ca`, `BOT-bots-anya-blocks-bloc` | `Chart-SOP-Google-Calendar`, `Ocean-Chart-SOP-Google-Ca`, `BOT-bots-anya-blocks-bloc` |
| 164 | cross_language | medium | MCP server 工具 接線 | `Wiki-Concepts-CLSC-dogfood-wee`, `Closet-Concepts-CLSC-CLSC-dogf` | --- | `Chart-SOP-New-Tool-Adopti`, `Ocean-Chart-SOP-New-Tool-`, `Ocean-Research-agent-brow` | `Chart-SOP-New-Tool-Adopti`, `Ocean-Chart-SOP-New-Tool-`, `Ocean-Research-agent-brow` |
| 166 | cross_language | hard | Schema markup SEO GEO | `Assets-Portfolio-Bonk-Bonk_Goo`, `Wiki-Projects-Bonk-AIO-Strateg` | --- | `Depth-llm-wiki-log`, `Ocean-Depth-llm-wiki-log`, `Chart-ADR-Knowledge-Infra` | `Depth-llm-wiki-log`, `Ocean-Depth-llm-wiki-log`, `Chart-ADR-Knowledge-Infra` |
| 167 | cross_language | hard | E-E-A-T 權威性 AI 引用 | `Wiki-Projects-Bonk-AIO-Strateg`, `Closet-Projects-Bonk-AIO-Strat` | --- | `Chart-CLSC-CLSC`, `Currents-ChannelLab-GEO-B`, `Currents-ChannelLab-Produ` | `Chart-CLSC-CLSC`, `Currents-ChannelLab-GEO-B`, `Currents-ChannelLab-Produ` |
| 168 | cross_language | medium | LLMLingua 壓縮 評估 | `Wiki-Reviews-chinese-claude-to`, `Wiki-Research-chinese-llm-comp` | --- | `Ocean-Research-chinese-ll`, `Research-chinese-llm-comp`, `Chart-ADR-CLSC` | `Ocean-Research-chinese-ll`, `Research-chinese-llm-comp`, `Chart-ADR-CLSC` |
| 169 | cross_language | hard | CDP accessibility ref tok | `Wiki-Research-agent-browser-re`, `Closet-Research-agent-browser-` | --- | `Chart-CLSC-CLSC-Technical`, `Chart-CLSC-CLSC`, `Depth-CLSC-Dictionary` | `Chart-CLSC-CLSC-Technical`, `Chart-CLSC-CLSC`, `Depth-CLSC-Dictionary` |
| 171 | cross_language | medium | tokenizer 中文 overhead | `Wiki-Concepts-CLSC-CLSC-Techni`, `Closet-Concepts-CLSC-CLSC-Tech` | --- | `BOT-bots-nicky-zhanglingh`, `BOT-global-CLAUDE`, `Chart-Architecture-Channe` | `BOT-bots-nicky-zhanglingh`, `BOT-global-CLAUDE`, `Chart-Architecture-Channe` |
| 172 | cross_language | hard | BPE encoding 中文 壓縮 | `Wiki-Reviews-CLSC-v0-5-UTF8-Co`, `Closet-Reviews-CLSC-v0-5-UTF8-` | --- | `Chart-ADR-CLSC`, `Chart-CLSC-CLSC-Technical`, `Chart-CLSC-CLSC-Test-Spec` | `Chart-ADR-CLSC`, `Chart-CLSC-CLSC-Technical`, `Chart-CLSC-CLSC-Test-Spec` |
| 173 | cross_language | hard | Rust CLI daemon MCP 比較 | `Wiki-Research-agent-browser-re`, `Wiki-Cards-agent-browser` | --- | `Ocean-Research-agent-brow`, `Research-agent-browser-re`, `Chart-SOP-Google-Calendar` | `Ocean-Research-agent-brow`, `Research-agent-browser-re`, `Chart-SOP-Google-Calendar` |
| 174 | cross_language | medium | Zettelkasten 方法 | `Wiki-Cards`, `Ocean-Pearl` | --- | `Depth-wiki-test-clsc`, `Depth-wiki-test2-clsc`, `Ocean-Depth-wiki-test-cls` | `Depth-wiki-test-clsc`, `Depth-wiki-test2-clsc`, `Ocean-Depth-wiki-test-cls` |
| 175 | cross_language | hard | SPA AI 爬蟲 | `Research-agent-browser-researc`, `Chart-Architecture-browser-aut` | --- | `BOT-bots-yitang-CLAUDE`, `Currents-ChannelLab-Produ`, `Ocean-BOT-bots-yitang-CLA` | `BOT-bots-yitang-CLAUDE`, `Currents-ChannelLab-Produ`, `Ocean-BOT-bots-yitang-CLA` |
| 178 | cross_language | medium | sprint 驗證 流程 | `Wiki-Concepts-channellab-bot-f`, `Closet-Concepts-Architecture-c` | `Chart-Architecture-channe`, `Ocean-Chart-Architecture-` | `Chart-Architecture-channe`, `Ocean-Chart-Architecture-`, `BOT-shared-mistakes` | `Chart-Architecture-channe`, `Ocean-Chart-Architecture-`, `BOT-shared-mistakes` |
| 179 | cross_language | medium | inotify event routing | `Wiki-Reviews-CR-20260408-inoti`, `Closet-Reviews-CR-20260408-ino` | --- | `BOT-bots-CLAUDE`, `BOT-bots-anya-blocks-bloc`, `Chart-FATQ` | `BOT-bots-CLAUDE`, `BOT-bots-anya-blocks-bloc`, `Chart-FATQ` |
| 180 | cross_language | hard | progressive disclosure sk | `Wiki-Research-kepano-obsidian-`, `Closet-Research-kepano-obsidia` | `Ocean-Research-kepano-obs`, `Research-kepano-obsidian-` | `Ocean-Research-kepano-obs`, `Research-kepano-obsidian-`, `claude-skills-defuddle-SK` | `Ocean-Research-kepano-obs`, `Research-kepano-obsidian-`, `claude-skills-defuddle-SK` |
| 182 | semantic_fuzzy | hard | 檔案系統 任務 排隊 | `Wiki-Concepts-FATQ`, `Closet-Concepts-FATQ` | --- | `BOT-bots-Bella-CLAUDE`, `BOT-bots-anna-CLAUDE`, `BOT-bots-anya-CLAUDE` | `BOT-bots-Bella-CLAUDE`, `BOT-bots-anna-CLAUDE`, `BOT-bots-anya-CLAUDE` |
| 183 | semantic_fuzzy | hard | 品牌 被提到 AI 檢測 | `Wiki-Projects-GEO-Analyzer-PRD`, `Closet-Projects-GEO-Analyzer-P` | --- | `Currents-ChannelLab-Produ`, `Currents-ChannelLab-Produ`, `Ocean-Currents-ChannelLab` | `Currents-ChannelLab-Produ`, `Currents-ChannelLab-Produ`, `Ocean-Currents-ChannelLab` |
| 184 | semantic_fuzzy | hard | AI 搜尋 容易找到 | `Wiki-Companies-ChannelLab-GEO-`, `Wiki-Projects-Bonk-GEO` | --- | `Currents-ChannelLab-GEO-C`, `Currents-ChannelLab-Produ`, `Currents-ChannelLab-Produ` | `Currents-ChannelLab-GEO-C`, `Currents-ChannelLab-Produ`, `Currents-ChannelLab-Produ` |
| 186 | semantic_fuzzy | hard | bot 共享 記憶 搜尋 | `Wiki-Concepts-FTS5-bot`, `Closet-Concepts-FTS5-bot` | --- | `Chart-FATQ`, `Chart-FTS5-bot`, `Chart-MemOcean` | `Chart-FATQ`, `Chart-FTS5-bot`, `Chart-MemOcean` |
| 187 | semantic_fuzzy | hard | 紡織 老公司 轉型 | `Wiki-Companies-NanLiang`, `Closet-Companies-NanLiang` | --- | `Currents-ChannelLab-GEO-C`, `Ocean-Currents-ChannelLab`, `BOT-bots-chltao-CLAUDE` | `Currents-ChannelLab-GEO-C`, `Ocean-Currents-ChannelLab`, `BOT-bots-chltao-CLAUDE` |
| 188 | semantic_fuzzy | hard | 茶葉 代幣化 | `Wiki-Projects-GWIN-RWA`, `Closet-Projects-GWIN-RWA` | --- | `Currents-ChannelLab-GEO-G`, `Ocean-Currents-ChannelLab` | `Currents-ChannelLab-GEO-G`, `Ocean-Currents-ChannelLab` |
| 189 | semantic_fuzzy | hard | 量化 APY 高 | `Wiki-Companies-Gene-Capital`, `Closet-Companies-Gene-Capital` | --- | `Chart-Architecture-channe`, `Chart-Media-Pricing`, `Currents-ChannelLab-GEO-M` | `Chart-Architecture-channe`, `Chart-Media-Pricing`, `Currents-ChannelLab-GEO-M` |
| 190 | semantic_fuzzy | medium | 不分類 連結 筆記 | `Wiki-Cards`, `Ocean-Pearl` | --- | `Depth-CLSC-Spec`, `Ocean-Depth-CLSC-Spec`, `Chart-Architecture-Channe` | `Depth-CLSC-Spec`, `Ocean-Depth-CLSC-Spec`, `Chart-Architecture-Channe` |
| 191 | semantic_fuzzy | hard | 丟進去 分身 不用管 | `Wiki-Cards-Ops-background-agen`, `Ocean-Pearl-Ops-background-age` | --- | --- | --- |
| 193 | semantic_fuzzy | medium | 知識 圖 工具 | `Wiki-Research-graphify-researc`, `Wiki-Cards-graphify` | --- | `BOT-bots-chltao-CLAUDE`, `Chart-ADR-Knowledge-Infra`, `Ocean-BOT-bots-chltao-CLA` | `BOT-bots-chltao-CLAUDE`, `Chart-ADR-Knowledge-Infra`, `Ocean-BOT-bots-chltao-CLA` |
| 194 | semantic_fuzzy | hard | AI 自己 學 新技能 | `Wiki-Research-hermes-agent-res`, `Closet-Research-hermes-agent-r` | --- | `Currents-NOXCAT`, `Ocean-Currents-NOXCAT`, `BOT-bots-chltao-CLAUDE` | `Currents-NOXCAT`, `Ocean-Currents-NOXCAT`, `BOT-bots-chltao-CLAUDE` |
| 195 | semantic_fuzzy | easy | 日本 招人 JD | `Wiki-People-JD_BD_Japan_Web3_2`, `Closet-People-JD_BD_Japan_Web3` | --- | `Currents-ChannelLab-GEO-P`, `Ocean-Currents-ChannelLab`, `Chart-Media-Pricing` | `Currents-ChannelLab-GEO-P`, `Ocean-Currents-ChannelLab`, `Chart-Media-Pricing` |
| 196 | semantic_fuzzy | hard | 整理 不是人的工作 AI | `Wiki-Cards-nick-spisak-method`, `Wiki-Research-nick-spisak-meth` | --- | `BOT-bots-anya-blocks-bloc`, `BOT-bots-caijie-zhuchu-CL`, `BOT-bots-chltao-CLAUDE` | `BOT-bots-anya-blocks-bloc`, `BOT-bots-caijie-zhuchu-CL`, `BOT-bots-chltao-CLAUDE` |
| 197 | semantic_fuzzy | medium | 智慧工廠 SaaS 天使輪 | `Wiki-Deals-Canalis_Angel`, `Closet-Deals-Canalis_Angel` | --- | `Currents-ChannelLab-Produ`, `Ocean-Currents-ChannelLab` | `Currents-ChannelLab-Produ`, `Ocean-Currents-ChannelLab` |
| 199 | semantic_fuzzy | hard | 知識庫 不是圖書館 | `Wiki-Research-knowledge-infra-`, `Closet-Research-knowledge-infr` | --- | `Chart-FTS5-bot`, `Chart-MemOcean`, `Chart-chart-clsc` | `Chart-FTS5-bot`, `Chart-MemOcean`, `Chart-chart-clsc` |
| 200 | semantic_fuzzy | hard | 最溫暖 金融 體驗 | `Wiki-Companies-NOXCAT`, `Closet-Companies-NOXCAT` | --- | `Currents-NOXCAT-NOXCAT`, `Ocean-Currents-NOXCAT-NOX`, `Ocean-Research-CZ-Memoir-` | `Currents-NOXCAT-NOXCAT`, `Ocean-Currents-NOXCAT-NOX`, `Ocean-Research-CZ-Memoir-` |

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
- **Seabed (FTS5) Hit@10**: 21.8%
- **Messages Hit@10**: 72.0%
- **KG hit rate**: 100.0%
- **Weighted overall Hit@10**: 35.5%
- **Total hard failures**: 129

### Seabed Mode Comparison (Hit@10)

- AND: 4.5%
- OR: 21.8% (delta vs AND: +17.3pp)
- FTS5+BM25: 21.8% (delta vs AND: +17.3pp)

### Scenes ranked by FTS5 Hit@10 (seabed only)

- semantic_fuzzy: 5.9% (n=17)
- tech_architecture: 10.0% (n=20)
- cross_language: 11.8% (n=17)
- decision_record: 11.8% (n=17)
- person_lookup: 18.2% (n=11)
- project_info: 21.1% (n=19)
- org_structure: 25.0% (n=8)
- process_sop: 29.4% (n=17)
- temporal_reasoning: 41.7% (n=12)
- product_feature: 50.0% (n=18)

---
*Generated by `work-scenario-benchmark-v1.py` on 2026-04-12 19:20:39*