# CLSC Benchmark v2 — Search Hit Rate: AND vs OR Comparison

Run: 2026-04-10 09:16:28

Database: `/home/oldrabbit/.claude-bots/memory.db`

## Summary Comparison

| Set | AND Hit Rate | OR Hit Rate | Delta | Miss→Hit |
|---|---|---|---|---|
| A: Real log | 41.2% | 94.1% | +52.9pp | 9 queries |
| B: Msg-sampled | 0.0% | 55.0% | +55.0pp | 11 queries |
| C: Ocean files | 75.0% | 90.0% | +15.0pp | 3 queries |

## Token Savings Comparison

| Metric | AND-match | OR-match | Delta |
|---|---|---|---|
| Hits analyzed | 73 | 174 | +101 |
| Path A tokens (skeleton-first) | 55,238 | 134,402 | +79,164 |
| Path B tokens (read original) | 263,972 | 610,419 | +346,447 |
| **Total tokens saved** | **208,734** | **476,017** | **+267,283** |
| **Avg savings %** | **79.1%** | **78.0%** | -1.1pp |
| Fallback rate (assumed) | 10.5% | 10.5% | — |

## Set A: Real log replay

| Mode | Queries | Hits | Hit Rate | Avg Hits/Query |
|---|---|---|---|---|
| AND | 17 | 7 | 41.2% | 74.6 |
| OR | 17 | 16 | 94.1% | 95.7 |

### Miss → Hit Conversions (9 queries)

| Query | OR Hits | Top 3 Results (slug : match_count) |
|---|---|---|
| 日本 商務 JD | 28 | `Wiki-People-JD_BD_Japan_Web3_2026-0`:2, `Closet-People-JD_BD_Japan_Web3_2026`:2, `Closet-Wings-ChannelLab-GEO-People-`:2 |
| 日本 業務 職缺 | 18 | `Wiki-People-JD_BD_Japan_Web3_2026-0`:2, `Closet-People-JD_BD_Japan_Web3_2026`:2, `Closet-Wings-ChannelLab-GEO-People-`:2 |
| obsidian headless MCP REST API | 107 | `Wiki-Concepts-Local-Setup-AI-SOP`:3, `Wiki-Concepts-SOP-Local-Setup-AI-SO`:3, `Closet-Concepts-SOP-Local-Setup-AI-`:3 |
| 搶票 AOT | 3 | `Wiki-Reviews-CR-20260408-vps-since-`:1, `Closet-Reviews-CR-20260408-vps-sinc`:1, `Ocean-Reviews-CR-20260408-vps-since`:1 |
| ibon ticket bot playwright | 136 | `stversions-Wiki-Concepts-CLSC-20260`:1, `Archive-MOC-MOC-Claude-Bots`:1, `Archive-Xbar-Bot-Status-Plugin`:1 |
| closet migrate wiki vault skeleton | 141 | `Closet-_schema`:4, `Wiki-Research-gnekt-mybrain-vs-chan`:3, `Closet-Research-gnekt-mybrain-vs-ch`:3 |
| GEO service pricing | 61 | `Wiki-Companies-ChannelLab-GEO-Prici`:2, `Closet-Companies-ChannelLab-GEO-Pri`:2, `Closet-Wings-ChannelLab-GEO-Channel`:2 |
| ocean rename metaphor currents pearl chart | 6 | `Ocean-_schema`:3, `Assets-Research-Planning-claude_cod`:1, `Ocean-Pearl-pearl-clsc`:1 |
| pearl sonar pipeline lint hook ingest | 37 | `Wiki-Research-mempalace-deep-mining`:3, `Closet-Research-mempalace-deep-mini`:3, `Ocean-Research-mempalace-deep-minin`:3 |

### Still Missing Under OR (1 queries)

| Query |
|---|
| 履歷 候選人 |

## Set B: Message-sampled

| Mode | Queries | Hits | Hit Rate | Avg Hits/Query |
|---|---|---|---|---|
| AND | 20 | 0 | 0.0% | 0.0 |
| OR | 20 | 11 | 55.0% | 36.4 |

### Miss → Hit Conversions (11 queries)

| Query | OR Hits | Top 3 Results (slug : match_count) |
|---|---|---|
| 162 162 truncation | 1 | `00Daily-2026-04-09`:2 |
| Anyachl_bot 收到 待命中 | 5 | `Bot-Config-channellab-bot-framework`:1, `Wiki-Concepts-channellab-bot-framew`:1, `Wiki-Concepts-Architecture-channell`:1 |
| API Next proxy | 25 | `Wiki-Cards-concepts-Anthropic-Manag`:2, `Wiki-Research-Anthropic-Managed-Age`:2, `Closet-Research-Anthropic-Managed-A`:2 |
| 找合作方 調度 Nicky | 32 | `Wiki-Concepts-ChannelLab-AI-Archite`:2, `Wiki-Concepts-Architecture-ChannelL`:2, `Closet-Concepts-Architecture-Channe`:2 |
| 有幾個小 QA 留白充足 | 8 | `Bot-Config-channellab-bot-framework`:1, `Wiki-Cards-Reviewer`:1, `Wiki-Concepts-channellab-bot-framew`:1 |
| Dashboard 做完建議後的預估分數 媒體 | 19 | `Archive-MOC-MOC-Dashboard`:1, `Assets-Portfolio-Bonk-Bonk_CN_GEO_R`:1, `Wiki-Cards-ChannelLab`:1 |
| Notion 长按文件 列表 | 43 | `Wiki-Companies-ChannelLab-Projects`:2, `Closet-Companies-ChannelLab-Project`:2, `Closet-Wings-ChannelLab-Org-Channel`:2 |
| 收工 Bellalovechl_Bot done | 10 | `Wiki-Cards-ADR-CLSC`:1, `Wiki-Research-knowledge-infra-propo`:1, `Wiki-Reviews-CR-20260408-inotify-wa`:1 |
| 同時是 00 Anna | 160 | `Wiki-Cards-ADR-CLSC`:2, `Wiki-Research-hermes-agent-research`:2, `Wiki-Reviews-CR-20260408-inotify-wa`:2 |
| relay cloud i5bm9u | 5 | `Assets-Portfolio-PRD-Anya-Voice-Ass`:1, `Wiki-Concepts-Google-Calendar-MCP-S`:1, `Wiki-Concepts-SOP-Google-Calendar-M`:1 |
| 隨時可以接單 review Bella | 92 | `Wiki-Cards-ADR-CLSC-sync-conflict-2`:2, `Wiki-Cards-Reviewer`:2, `Wiki-Concepts-CLSC-Spec`:2 |

### Set B Detailed OR Results (all queries)

| Query | AND Hits | OR Hits | Top 3 OR Results (slug : match_count) |
|---|---|---|---|
| 162 162 truncation | 0 | 1 | `00Daily-2026-04-09`:2 **NEW** |
| Anyachl_bot 收到 待命中 | 0 | 5 | `Bot-Config-channellab-bot-fram`:1, `Wiki-Concepts-channellab-bot-f`:1, `Wiki-Concepts-Architecture-cha`:1 **NEW** |
| API Next proxy | 0 | 25 | `Wiki-Cards-concepts-Anthropic-`:2, `Wiki-Research-Anthropic-Manage`:2, `Closet-Research-Anthropic-Mana`:2 **NEW** |
| 等三菜完成後開始審查 不動設定 CarrotAAA_bot | 0 | 0 |  |
| 找合作方 調度 Nicky | 0 | 32 | `Wiki-Concepts-ChannelLab-AI-Ar`:2, `Wiki-Concepts-Architecture-Cha`:2, `Closet-Concepts-Architecture-C`:2 **NEW** |
| 有幾個小 QA 留白充足 | 0 | 8 | `Bot-Config-channellab-bot-fram`:1, `Wiki-Cards-Reviewer`:1, `Wiki-Concepts-channellab-bot-f`:1 **NEW** |
| Dashboard 做完建議後的預估分數 媒體 | 0 | 19 | `Archive-MOC-MOC-Dashboard`:1, `Assets-Portfolio-Bonk-Bonk_CN_`:1, `Wiki-Cards-ChannelLab`:1 **NEW** |
| 之後再來整理好了 我們繼續討論wiki 我們的01 | 0 | 0 |  |
| 0x167fBF7E0826A2c266090c27Cc4ba362b9815D36 0x | 0 | 0 |  |
| 不能只看 通過了 通過但 | 0 | 0 |  |
| Notion 长按文件 列表 | 0 | 43 | `Wiki-Companies-ChannelLab-Proj`:2, `Closet-Companies-ChannelLab-Pr`:2, `Closet-Wings-ChannelLab-Org-Ch`:2 **NEW** |
| 一眼看懂 新版乾淨很多 一行說明 | 0 | 0 |  |
| 收工 Bellalovechl_Bot done | 0 | 10 | `Wiki-Cards-ADR-CLSC`:1, `Wiki-Research-knowledge-infra-`:1, `Wiki-Reviews-CR-20260408-inoti`:1 **NEW** |
| 開始合併兩個 branch annadesu_bot | 0 | 0 |  |
| 同時是 00 Anna | 0 | 160 | `Wiki-Cards-ADR-CLSC`:2, `Wiki-Research-hermes-agent-res`:2, `Wiki-Reviews-CR-20260408-inoti`:2 **NEW** |
| 聯創只拿分紅 團隊激勵直接給到員工 | 0 | 0 |  |
| relay cloud i5bm9u | 0 | 5 | `Assets-Portfolio-PRD-Anya-Voic`:1, `Wiki-Concepts-Google-Calendar-`:1, `Wiki-Concepts-SOP-Google-Calen`:1 **NEW** |
| Designer 錢包設計稿在排隊中 TwinkleCHL_bot | 0 | 0 |  |
| TwinkleCHL_bot 啟動自我檢視 | 0 | 0 |  |
| 隨時可以接單 review Bella | 0 | 92 | `Wiki-Cards-ADR-CLSC-sync-confl`:2, `Wiki-Cards-Reviewer`:2, `Wiki-Concepts-CLSC-Spec`:2 **NEW** |

### Still Missing Under OR (9 queries)

| Query |
|---|
| 等三菜完成後開始審查 不動設定 CarrotAAA_bot |
| 之後再來整理好了 我們繼續討論wiki 我們的01 |
| 0x167fBF7E0826A2c266090c27Cc4ba362b9815D36 0x92e4f1731f2ef18 |
| 不能只看 通過了 通過但 |
| 一眼看懂 新版乾淨很多 一行說明 |
| 開始合併兩個 branch annadesu_bot |
| 聯創只拿分紅 團隊激勵直接給到員工 |
| Designer 錢包設計稿在排隊中 TwinkleCHL_bot |
| TwinkleCHL_bot 啟動自我檢視 |

## Set C: Ocean filenames

| Mode | Queries | Hits | Hit Rate | Avg Hits/Query |
|---|---|---|---|---|
| AND | 20 | 15 | 75.0% | 6.0 |
| OR | 20 | 18 | 90.0% | 93.8 |

### Miss → Hit Conversions (3 queries)

| Query | OR Hits | Top 3 Results (slug : match_count) |
|---|---|---|
| Bot Team Architecture | 133 | `Wiki-Concepts-Bot-Team-Architecture`:2, `Wiki-Concepts-CLSC-Spec`:2, `Wiki-Concepts-Team-Onboarding-SOP`:2 |
| GAIA  Account manager JD (Malaysia) | 16 | `Wiki-llm-wiki-wiki-entities-EIP-814`:1, `Wiki-llm-wiki-wiki-entities`:1, `Wiki-llm-wiki-wiki-sources-2026-04-`:1 |
| CLSC Dictionary Anya Ext.sync conflict 20260408 10 | 181 | `Wiki-Concepts-CLSC-Dictionary-Anya-`:3, `Wiki-Concepts-CLSC-Dictionary-Anya-`:3, `Wiki-Research-chinese-claude-token-`:3 |

### Still Missing Under OR (2 queries)

| Query |
|---|
| 市场部工作内容拆解 |
| 設計和開發是兩種思維 |

---
*Generated by `clsc-benchmark-search-v2.py` on 2026-04-10 09:16:28*