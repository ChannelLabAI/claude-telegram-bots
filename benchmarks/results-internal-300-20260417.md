# MemOcean Work Scenario Benchmark v2

Run: 2026-04-17 12:05:22

Corpus: 586 radar entries, 806 KG entities, 828 KG triples

Questions: 300 total

## 1. Overall Hit@K

### Seabed Search (216 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 37.5% (81) | 44.9% (97) | 45.4% (98) | 45.8% (99) |
| OR | 78.7% (170) | 91.7% (198) | 94.4% (204) | 96.3% (208) |
| FTS5+BM25 | 67.1% (145) | 81.9% (177) | 84.3% (182) | 89.3% (193) |

### Messages Search (25 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| FTS5 | 56.0% (14) | 60.0% (15) | 64.0% (16) | 68.0% (17) |

### KG Query (19 questions)

| Hit Rate | 100.0% (19/19) |
|---|---|

### Ocean Search (40 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| Ocean FTS | 0.0% (0) | 2.5% (1) | 2.5% (1) | 5.0% (2) |

## 2. Per-Scene Breakdown

### cross_language (20 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 11.8% | 17.6% | 17.6% | 17.6% |
| OR | 76.5% | 88.2% | 88.2% | 88.2% |
| FTS5+BM25 | 52.9% | 70.6% | 82.3% | 82.3% |

Messages FTS5: Hit@1=50.0% Hit@3=50.0% Hit@5=50.0% Hit@10=50.0%

KG: 100.0% (1/1)

### decision_record (27 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 40.0% | 45.0% | 45.0% | 45.0% |
| OR | 95.0% | 100.0% | 100.0% | 100.0% |
| FTS5+BM25 | 75.0% | 85.0% | 90.0% | 95.0% |

Messages FTS5: Hit@1=100.0% Hit@3=100.0% Hit@5=100.0% Hit@10=100.0%

Ocean FTS: Hit@1=0.0% Hit@3=0.0% Hit@5=0.0% Hit@10=0.0%

### org_structure (19 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 50.0% | 50.0% | 50.0% | 50.0% |
| OR | 62.5% | 62.5% | 62.5% | 62.5% |
| FTS5+BM25 | 62.5% | 75.0% | 75.0% | 75.0% |

Messages FTS5: Hit@1=0.0% Hit@3=0.0% Hit@5=100.0% Hit@10=100.0%

KG: 100.0% (6/6)

Ocean FTS: Hit@1=0.0% Hit@3=0.0% Hit@5=0.0% Hit@10=0.0%

### person_lookup (30 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 35.3% | 35.3% | 41.2% | 41.2% |
| OR | 82.3% | 88.2% | 94.1% | 94.1% |
| FTS5+BM25 | 64.7% | 82.3% | 88.2% | 94.1% |

Messages FTS5: Hit@1=50.0% Hit@3=50.0% Hit@5=50.0% Hit@10=50.0%

KG: 100.0% (7/7)

Ocean FTS: Hit@1=0.0% Hit@3=0.0% Hit@5=0.0% Hit@10=0.0%

### process_sop (38 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 50.0% | 60.0% | 60.0% | 60.0% |
| OR | 76.7% | 93.3% | 96.7% | 96.7% |
| FTS5+BM25 | 66.7% | 83.3% | 83.3% | 93.3% |

Messages FTS5: Hit@1=33.3% Hit@3=33.3% Hit@5=33.3% Hit@10=33.3%

Ocean FTS: Hit@1=0.0% Hit@3=0.0% Hit@5=0.0% Hit@10=0.0%

### product_feature (24 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 55.6% | 55.6% | 55.6% | 55.6% |
| OR | 94.4% | 94.4% | 100.0% | 100.0% |
| FTS5+BM25 | 88.9% | 94.4% | 94.4% | 100.0% |

Messages FTS5: Hit@1=50.0% Hit@3=100.0% Hit@5=100.0% Hit@10=100.0%

Ocean FTS: Hit@1=0.0% Hit@3=0.0% Hit@5=0.0% Hit@10=0.0%

### project_info (30 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 47.4% | 47.4% | 47.4% | 47.4% |
| OR | 94.7% | 100.0% | 100.0% | 100.0% |
| FTS5+BM25 | 73.7% | 89.5% | 89.5% | 94.7% |

Messages FTS5: Hit@1=50.0% Hit@3=50.0% Hit@5=50.0% Hit@10=50.0%

KG: 100.0% (2/2)

Ocean FTS: Hit@1=0.0% Hit@3=0.0% Hit@5=0.0% Hit@10=0.0%

### project_status (13 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 53.8% | 84.6% | 84.6% | 84.6% |
| OR | 61.5% | 100.0% | 100.0% | 100.0% |
| FTS5+BM25 | 69.2% | 100.0% | 100.0% | 100.0% |

### resource_find (5 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 80.0% | 100.0% | 100.0% | 100.0% |
| OR | 80.0% | 100.0% | 100.0% | 100.0% |
| FTS5+BM25 | 80.0% | 100.0% | 100.0% | 100.0% |

### semantic_fuzzy (24 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 5.9% | 5.9% | 5.9% | 5.9% |
| OR | 76.5% | 76.5% | 82.3% | 94.1% |
| FTS5+BM25 | 64.7% | 64.7% | 64.7% | 82.3% |

Messages FTS5: Hit@1=50.0% Hit@3=50.0% Hit@5=50.0% Hit@10=100.0%

KG: 100.0% (1/1)

Ocean FTS: Hit@1=0.0% Hit@3=0.0% Hit@5=0.0% Hit@10=25.0%

### tech_architecture (35 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 40.0% | 50.0% | 50.0% | 50.0% |
| OR | 85.0% | 95.0% | 100.0% | 100.0% |
| FTS5+BM25 | 65.0% | 85.0% | 90.0% | 90.0% |

Messages FTS5: Hit@1=100.0% Hit@3=100.0% Hit@5=100.0% Hit@10=100.0%

KG: 100.0% (2/2)

Ocean FTS: Hit@1=0.0% Hit@3=10.0% Hit@5=10.0% Hit@10=10.0%

### tech_lookup (20 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 35.0% | 55.0% | 55.0% | 55.0% |
| OR | 65.0% | 95.0% | 95.0% | 100.0% |
| FTS5+BM25 | 65.0% | 75.0% | 75.0% | 75.0% |

### temporal_reasoning (15 questions)

| Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 |
|---|---|---|---|---|
| AND | 0.0% | 0.0% | 0.0% | 8.3% |
| OR | 50.0% | 83.3% | 91.7% | 100.0% |
| FTS5+BM25 | 41.7% | 66.7% | 66.7% | 75.0% |

Messages FTS5: Hit@1=33.3% Hit@3=33.3% Hit@5=33.3% Hit@10=33.3%

## 3. Per-Difficulty Breakdown

### Seabed Search by Difficulty

| Difficulty | Mode | Hit@1 | Hit@3 | Hit@5 | Hit@10 | N |
|---|---|---|---|---|---|---|
| easy | AND | 49.4% | 58.6% | 58.6% | 59.8% | 87 |
| easy | OR | 80.5% | 96.5% | 96.5% | 97.7% | 87 |
| easy | FTS5+BM25 | 75.9% | 87.4% | 88.5% | 95.4% | 87 |
| medium | AND | 36.4% | 42.0% | 43.2% | 43.2% | 88 |
| medium | OR | 78.4% | 89.8% | 95.5% | 96.6% | 88 |
| medium | FTS5+BM25 | 62.5% | 81.8% | 85.2% | 87.5% | 88 |
| hard | AND | 14.6% | 21.9% | 21.9% | 21.9% | 41 |
| hard | OR | 75.6% | 85.4% | 87.8% | 92.7% | 41 |
| hard | FTS5+BM25 | 58.5% | 70.7% | 73.2% | 80.5% | 41 |

### Messages Search by Difficulty

| Difficulty | Hit@1 | Hit@3 | Hit@5 | Hit@10 | N |
|---|---|---|---|---|---|
| medium | 37.5% | 50.0% | 50.0% | 50.0% | 8 |
| hard | 64.7% | 64.7% | 70.6% | 76.5% | 17 |

### KG Query by Difficulty

| Difficulty | Hit Rate | N |
|---|---|---|
| easy | 100.0% (1/1) | 1 |
| medium | 100.0% (12/12) | 12 |
| hard | 100.0% (6/6) | 6 |

## 4. Hard Failures (not found in top-10 by any mode)

### Seabed Failures (6)

| ID | Scene | Diff | Query | Expected | AND Top-3 | OR Top-3 | FTS5 Top-3 |
|---|---|---|---|---|---|---|---|
| 4 | person_lookup | easy | 菜姐 角色 | `Currents-ChannelLab-Org-People`, `Chart-Architecture-ChannelLab-` | `Chart-MemOcean-MemOcean-B`, `Chart-MemOcean-Benchmarks` | `Chart-MemOcean-MemOcean-B`, `Chart-MemOcean-Benchmarks`, `Chart-Bot-System-global-C` | `Chart-MemOcean-MemOcean-B`, `Chart-MemOcean-Benchmarks`, `Chart-Bot-System-global-C` |
| 137 | org_structure | medium | Nicky 股權 激勵 | `Chart-Architecture-ChannelLab-`, `Chart-Bot-System-bots-nicky-bu` | --- | `Seabed-2026-04-2026-04-08`, `Currents-ChannelLab-BD-Pe`, `Currents-ChannelLab-Org-S` | `People-Nicky`, `Inbox-hello-nicky`, `Currents-ChannelLab-BD-Pe` |
| 142 | org_structure | hard | 資本儲備 水位線 | `Currents-ChannelLab-Org-Seabed`, `Currents-ChannelLab-Org-Seabed` | --- | --- | --- |
| 171 | cross_language | medium | tokenizer 中文 overhead | `Chart-Architecture-ChannelLab-`, `Chart-Bot-System-bots-interns-` | --- | `Chart-MemOcean-CLSC-CLSC-`, `Currents-GitHub-memocean-`, `Research-AI-Memory-System` | `Depth-CLSC-Dictionary`, `Reviews-CR-20260408-clsc-`, `Currents-GitHub-memocean-` |
| 175 | cross_language | hard | SPA AI 爬蟲 | `Research-agent-browser-researc`, `Chart-Architecture-browser-aut` | --- | `Currents-ChannelLab-GEO-P`, `Research-chinese-llm-comp`, `Currents-ChannelLab-Produ` | `Chart-Bot-System-bots-cai`, `Currents-ChannelLab-Event`, `Currents-ChannelLab-Event` |
| 191 | semantic_fuzzy | hard | 丟進去 分身 不用管 | `Pearl-Ops-background-agent`, `Pearl-MCP-background-agent` | --- | --- | --- |

### Messages Failures (8)

| ID | Scene | Diff | Query | Expected Snippets | Results |
|---|---|---|---|---|---|
| 5 | person_lookup | medium | 桃桃 工作 | 桃桃, PM, 培訓, NOXCAT | 0 |
| 27 | project_info | medium | NOXCAT 會議 技術 | OTC, 跨鏈, 錢包 | 10 |
| 38 | project_info | hard | 輿情監控 | 輿情, 監控, 情感分析 | 0 |
| 99 | process_sop | medium | bot 踩坑 錯誤 | kill, PID, screen, polling | 10 |
| 110 | process_sop | hard | 老兔 信仰 禁忌 | 耶和華見證人, 不慶生, 不輸血 | 0 |
| 153 | temporal_reason | hard | 本週 重大事件 進度 | CLSC, 知識基礎設施, FATQ | 0 |
| 158 | temporal_reason | medium | 發薪日 幾號 | 發薪, 帳務 | 0 |
| 176 | cross_language | hard | code-switching 策略 中英 | code-switching, 中文, 英文 | 0 |

### KG Failures (0)

None!

### Ocean Failures (38)

| ID | Scene | Diff | Query | Expected Titles | Results | Top-3 Got |
|---|---|---|---|---|---|---|
| 201 | tech_architectu | easy | ChannelLab AI architectur | `ChannelLab-AI-Architectur`, `channellab-bot-framework` | 10 | `CR-20260408-channell`, `index`, `2026-04-16-nicky-com` |
| 202 | tech_architectu | easy | browser automation landsc | `browser-automation-landsc`, `browser-automation-tool-s` | 10 | `CR-20260408-channell`, `CR-20260408-browser-`, `CR-20260408-browser-` |
| 203 | tech_architectu | easy | memocean semantic search  | `memocean-semantic-search-` | 10 | `CR-20260408-channell`, `Test-CLSC-Result-v0.`, `CR-20260408-browser-` |
| 205 | tech_architectu | medium | reranker pipeline RnD res | `RnD-Reranker-Pipeline` | 10 | `CR-20260408-channell`, `Test-CLSC-Result-v0.`, `CR-20260408-browser-` |
| 206 | tech_architectu | medium | CLSC technical spec 技術規格 | `CLSC-Technical-Spec-zh`, `CLSC-Technical-Spec` | 10 | `CR-20260408-channell`, `Test-CLSC-Result-v0.`, `CR-20260408-l1-engli` |
| 207 | tech_architectu | medium | vector quantization RnD r | `RnD-Vector-Quantization` | 10 | `CR-20260408-clsc-v0.`, `CR-20260408-browser-`, `_index` |
| 208 | tech_architectu | medium | knowledge infra ADR archi | `Knowledge-Infra-ADR-2026-`, `Knowledge-Graph-Optimizat` | 10 | `CR-20260408-channell`, `Test-CLSC-Result-v0.`, `CR-20260408-clsc-v0.` |
| 209 | tech_architectu | hard | vector search consensus m | `MemOcean-Vector-Search-Co` | 10 | `CR-20260408-channell`, `CR-20260408-browser-`, `CR-20260408-browser-` |
| 210 | tech_architectu | hard | harness engineering desig | `Harness-Engineering`, `harness-engineering-insig` | 10 | `CR-20260408-hermes-s`, `CR-20260408-vps-sinc`, `CR-20260408-browser-` |
| 211 | process_sop | easy | new tool adoption SOP 新工具 | `New-Tool-Adoption-SOP` | 10 | `CR-20260408-channell`, `CR-20260408-browser-`, `CR-20260408-browser-` |
| 212 | process_sop | easy | Google Calendar MCP setup | `Google-Calendar-MCP-Setup` | 10 | `CR-20260408-channell`, `2026-04-05-blocktemp`, `CR-20260408-hermes-s` |
| 213 | process_sop | easy | team onboarding SOP 新人 入職 | `Team-Onboarding-SOP` | 10 | `CR-20260408-clsc-v0.`, `_index`, `CR-20260408-hermes-s` |
| 214 | process_sop | medium | local setup AI SOP 本地 開發環 | `Local-Setup-AI-SOP` | 10 | `CR-20260408-channell`, `Test-CLSC-Result-v0.`, `CR-20260408-clsc-v0.` |
| 215 | process_sop | medium | daily note 每日工作日誌 格式 SOP | `Daily Note` | 10 | `CR-20260408-channell`, `Test-CLSC-Result-v0.`, `CR-20260408-clsc-v0.` |
| 216 | project_info | easy | memocean README project d | `README` | 10 | `CR-20260408-channell`, `CR-20260408-clsc-v0.`, `CR-20260408-temporal` |
| 217 | project_info | medium | 知識基礎設施 長期 優化 提案 anya | `knowledge-infra-proposal-`, `知識基礎設施` | 10 | `CR-20260408-channell`, `Test-CLSC-Result-v0.`, `CR-20260408-clsc-v0.` |
| 218 | project_info | medium | mempalace channellab arch | `mempalace-vs-channellab-a` | 10 | `CR-20260408-channell`, `CR-20260408-browser-`, `CR-20260408-clsc-v0.` |
| 219 | project_info | hard | MemOcean benchmark blind  | `MemOcean-BlindBenchmark-W`, `MemOcean-Benchmark-2026-0` | 10 | `CR-20260408-channell`, `Test-CLSC-Result-v0.`, `CR-20260408-clsc-v0.` |
| 220 | project_info | medium | O2 workflow 工作流 設計 | `O2-WorkFlow` | 10 | `CR-20260408-clsc-v0.`, `CR-20260408-hermes-s`, `CLSC-v0.5-UTF8-Codep` |
| 221 | decision_record | easy | FATQ file atomic task que | `FATQ`, `FATQ-File-Atomic-Task-Que` | 10 | `CR-20260408-channell`, `CR-20260408-clsc-v0.`, `CR-20260408-clsc-v0.` |
| 222 | decision_record | medium | Anthropic managed agents  | `Anthropic-Managed-Agents-` | 10 | `CR-20260408-clsc-v0.`, `CR-20260408-clsc-v0.`, `research_tmp.clsc` |
| 223 | decision_record | medium | Claude Code security 安全配置 | `Claude-Code-三級安全配置-防promp` | 10 | `CR-20260408-channell`, `Test-CLSC-Result-v0.`, `CR-20260408-browser-` |
| 224 | decision_record | hard | RAG benchmark standards e | `RAG-Benchmark-Standards-2`, `AI-Memory-Systems-Benchma` | 10 | `CR-20260408-channell`, `Test-CLSC-Result-v0.`, `CR-20260408-browser-` |
| 225 | org_structure | easy | ChannelLab 三大引擎 GEO 知識 | `ChannelLab三大引擎` | 10 | `CR-20260408-channell`, `CR-20260408-clsc-v0.`, `CR-20260408-clsc-v0.` |
| 226 | org_structure | easy | AI 團隊 槓桿 agent bot 數量 | `AI團隊的槓桿在agent不在bot數量` | 10 | `CR-20260408-channell`, `index`, `Test-CLSC-Result-v0.` |
| 227 | org_structure | medium | 部門制 一對一 效率 組織 | `部門制比一對一制更有效率` | 10 | `CLSC-v0.5-UTF8-Codep`, `CLSC-v0.4-Stress-Tes`, `_schema` |
| 228 | org_structure | hard | Anthropic multi-agent 5 p | `Anthropic-MultiAgent-5Pat` | 10 | `CR-20260408-channell`, `Test-CLSC-Result-v0.`, `CR-20260408-clsc-v0.` |
| 229 | product_feature | easy | GEOFlow tool GEO | `GEOFlow-tool` | 10 | `CR-20260408-channell`, `CR-20260408-browser-`, `CR-20260408-browser-` |
| 230 | product_feature | medium | NOXCAT 防脅迫 功能設計 coercion | `NOXCAT_防脅迫功能設計` | 10 | `CR-20260408-temporal`, `Test-CLSC-Result-v0.`, `CLSC-v0.4-Stress-Tes` |
| 231 | product_feature | medium | NOX Wallet PRD 產品需求 walle | `NOX_Wallet_PRD_v1.1` | 10 | `CR-20260408-temporal`, `Test-CLSC-Result-v0.`, `CLSC-v0.4-Stress-Tes` |
| 232 | product_feature | hard | EverMind AI MSA architect | `EverMind-AI-MSA`, `EverMind-AI-MSA-調研` | 10 | `CR-20260408-channell`, `Test-CLSC-Result-v0.`, `CR-20260408-clsc-v0.` |
| 233 | person_lookup | easy | Nicky profile person Chan | `Nicky` | 10 | `CR-20260408-channell`, `CR-20260408-clsc-v0.`, `CR-20260408-inotify-` |
| 234 | person_lookup | easy | Ron profile person 隊長 gro | `Ron` | 10 | `Test-CLSC-Result-v0.`, `CR-20260408-clsc-v0.`, `CR-20260408-clsc-v0.` |
| 235 | person_lookup | medium | Hubble AI company 公司 deal | `Hubble-AI` | 10 | `CR-20260408-channell`, `Test-CLSC-Result-v0.`, `CR-20260408-clsc-v0.` |
| 236 | person_lookup | medium | CZ memoir personal story  | `CZ-Memoir-Personal-Story` | 10 | `CR-20260408-clsc-v0.`, `CR-20260408-clsc-v0.`, `CR-20260408-hermes-s` |
| 238 | semantic_fuzzy | easy | 先跑起來 再優化 執行 原則 | `先跑起來再優化` | 10 | `Test-CLSC-Result-v0.`, `CR-20260408-clsc-v0.`, `Reviews.clsc` |
| 239 | semantic_fuzzy | medium | Reviewer 審查 三次 review 不是一 | `Reviewer要審三次不是一次` | 10 | `CR-20260408-channell`, `Test-CLSC-Result-v0.`, `CR-20260408-clsc-v0.` |
| 240 | semantic_fuzzy | medium | Cards AI 決策 訓練資料 筆記 | `Cards是AI的決策訓練資料不是人的筆記` | 10 | `CR-20260408-channell`, `Test-CLSC-Result-v0.`, `CR-20260408-clsc-v0.` |

## 5. Summary Statistics

- **Total questions**: 300
- **Seabed (FTS5) Hit@10**: 89.3%
- **Messages Hit@10**: 68.0%
- **KG hit rate**: 100.0%
- **Ocean Search Hit@10**: 5.0%
- **Weighted overall Hit@10**: 77.0%
- **Total hard failures**: 52

### Seabed Mode Comparison (Hit@10)

- AND: 45.8%
- OR: 96.3% (delta vs AND: +50.5pp)
- FTS5+BM25: 89.3% (delta vs AND: +43.5pp)

### Scenes ranked by FTS5 Hit@10 (seabed only)

- org_structure: 75.0% (n=8)
- tech_lookup: 75.0% (n=20)
- temporal_reasoning: 75.0% (n=12)
- cross_language: 82.3% (n=17)
- semantic_fuzzy: 82.3% (n=17)
- tech_architecture: 90.0% (n=20)
- process_sop: 93.3% (n=30)
- person_lookup: 94.1% (n=17)
- project_info: 94.7% (n=19)
- decision_record: 95.0% (n=20)
- product_feature: 100.0% (n=18)
- project_status: 100.0% (n=13)
- resource_find: 100.0% (n=5)

---
*Generated by `work-scenario-benchmark-v2.py` on 2026-04-17 12:05:22*