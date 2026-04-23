# Haiku vs Jieba Skeleton Search Benchmark

Date: 2026-04-10

Corpus: 470 documents (joined on slug)

Queries: 30 total (10 person, 10 topic, 10 natural language)

## Summary

| Metric | Jieba | Haiku | Winner |
|--------|-------|-------|--------|
| Avg hits/query | 47.3 | 42.5 | Jieba |
| Avg top-5 match score | 6.7 | 6.5 | Jieba |
| Queries with exclusive hits (only this found results) | 0 | 2 | - |

### By Category

| Category | Jieba total hits | Haiku total hits | Delta |
|----------|-----------------|-----------------|-------|
| person | 309 | 568 | +259 |
| topic | 547 | 385 | -162 |
| natural | 562 | 323 | -239 |

## Per-Query Detail

### Person Queries

**老兔** (terms: `['老兔']`)
- Jieba: 108 hits | Haiku: 99 hits
- Jieba top-5: 00Daily-2026-04-09(1), Archive-MOC-MOC-Home(1), Assets-ChannelLab-Equity-CHL_Term_Sheet(1), Assets-ChannelLab-Equity-_202604(1), Assets-Portfolio-PRD-Anya-Voice-Assistant(1)
- Haiku top-5: 00Daily-2026-04-06(1), 00Daily-2026-04-08(1), 00Daily-2026-04-09(1), 08-Daily-2026-04-06(1), 08-Daily-2026-04-08(1)
- Haiku-only (sample): ['Closet-Cards-ChannelLab', 'Closet-Cards-AI-agent-bot', 'Closet-Cards-MCP-background-agent']
- Jieba-only (sample): ['Closet-Concepts-SOP-New-Tool-Adoption-SOP', 'Closet-Concepts-SOP-Team-Onboarding-SOP', 'Closet-Concepts-crypto-ai-skills-shortlist']

**Ron** (terms: `['ron']`)
- Jieba: 58 hits | Haiku: 63 hits
- Jieba top-5: Assets-ChannelLab-GEO-Service-GEO-Frontend-Redesign-Spec(1), Bot-Config-setup-local-ai-sop(1), Closet-Cards-ChannelLab(1), Closet-Cards-hermes-agent(1), Closet-Concepts-Architecture-ChannelLab-AI-Architecture(1)
- Haiku top-5: Assets-ChannelLab-Equity-CHL_Term_Sheet(1), Assets-ChannelLab-Equity-_202604(1), Assets-ChannelLab-GEO-Service-GEO-Frontend-Redesign-Spec(1), Bot-Config-channellab-bot-framework(1), Closet-Archive-CLSC-Dictionary(1)
- Haiku-only (sample): ['Closet-Wings-ChannelLab-Org-profit-sharing-202604', 'Assets-ChannelLab-Equity-CHL_Term_Sheet', 'Closet-Projects-ChannelLab-profit-sharing-202604']
- Jieba-only (sample): ['Closet-Research-gnekt-mybrain-vs-channellab', 'Closet-Wings-ChannelLab-GEO-Deals-_README', 'Closet-Research-knowledge-infra-proposal-chef']

**Nicky** (terms: `['nicky']`)
- Jieba: 29 hits | Haiku: 50 hits
- Jieba top-5: Assets-ChannelLab-Equity-Nicky_Equity_Overview(1), Assets-ChannelLab-Equity-_202604(1), Bot-Config-setup-local-ai-sop(1), Closet-Concepts-Architecture-ChannelLab-AI-Architecture(1), Closet-Concepts-SOP-Local-Setup-AI-SOP(1)
- Haiku top-5: 00Daily-2026-04-09(1), 00Daily-2026-04-10(1), Assets-ChannelLab-Equity-CHL_Term_Sheet(1), Assets-ChannelLab-Equity-Nicky_Equity_Overview(1), Assets-ChannelLab-Equity-_202604(1)
- Haiku-only (sample): ['Closet-Cards-ChannelLab', 'Ocean-Chart-ADR-Knowledge-Infra-ADR-2026-04-08', 'Assets-ChannelLab-Equity-CHL_Term_Sheet']
- Jieba-only (sample): ['Closet-Research-mempalace-deep-mining-2026-04-08', 'Ocean-Research-mempalace-deep-mining-2026-04-08', 'Ocean-Chart-MemOcean']

**Anna** (terms: `['anna']`)
- Jieba: 41 hits | Haiku: 112 hits
- Jieba top-5: 00Daily-2026-04-09(1), Closet-Concepts-ADR-CLSC(1), Closet-Concepts-Architecture-browser-automation-landscape(1), Closet-Concepts-CLSC-CLSC(1), Closet-Concepts-CLSC-CLSC-Technical-Spec-zh(1)
- Haiku top-5: 00Daily-2026-04-06(1), 00Daily-2026-04-09(1), 00Daily-2026-04-10(1), 08-Daily-2026-04-06(1), Archive-MOC-MOC-Claude-Bots(1)
- Haiku-only (sample): ['Assets-Research-GEO-Analyzer-PRD', 'Closet-Cards-MCP-background-agent', 'Bot-Config-gstack-workflow']
- Jieba-only (sample): ['Closet-Reviews-CR-20260408-hermes-skill-loop-poc', 'Closet-Research-knowledge-infra-proposal-elon-musk', 'Ocean-Chart-CLSC-CLSC-Technical-Spec-zh']

**Bella** (terms: `['bella']`)
- Jieba: 37 hits | Haiku: 130 hits
- Jieba top-5: Closet-Archive-CLSC-Spec(1), Closet-Cards-Reviewer(1), Closet-Concepts-ADR-CLSC(1), Closet-Concepts-CLSC-CLSC-Test-Spec(1), Closet-Research-hermes-agent-research(1)
- Haiku top-5: 00Daily-2026-04-06(1), 00Daily-2026-04-08(1), 00Daily-2026-04-09(1), 08-Daily-2026-04-06(1), 08-Daily-2026-04-08(1)
- Haiku-only (sample): ['Assets-Research-GEO-Analyzer-PRD', 'Bot-Config-gstack-workflow', 'Closet-Concepts-Architecture-Bot-Team-Architecture']
- Jieba-only (sample): ['Closet-Reviews-Test-CLSC-Result-v0-1', 'Ocean-Reviews-CR-20260408-clsc-v0-6-hancloset', 'Ocean-Pearl-Reviewer']

**桃桃** (terms: `['桃桃']`)
- Jieba: 14 hits | Haiku: 38 hits
- Jieba top-5: Assets-ChannelLab-Equity-_202604(1), Closet-Projects-ChannelLab-profit-sharing-202604(1), Closet-Projects-NOXCAT-meetings-2026-04-07(1), Closet-Research-knowledge-infra-proposal-elon-musk(1), Closet-Wings-ChannelLab-Org-profit-sharing-202604(1)
- Haiku top-5: Assets-ChannelLab-Equity-CHL_Term_Sheet(1), Assets-ChannelLab-Equity-_202604(1), Bot-Config-channellab-bot-framework(1), Closet-Companies-ChannelLab-Equity(1), Closet-Companies-ChannelLab-Projects(1)
- Haiku-only (sample): ['Ocean-Chart-ADR-Knowledge-Infra-ADR-2026-04-08', 'Assets-ChannelLab-Equity-CHL_Term_Sheet', 'Ocean-Chart-SOP-Google-Calendar-MCP-Setup-SOP']
- Jieba-only (sample): ['Wiki-Projects-NOXCAT-meetings-2026-04-07', 'Wiki-Projects-ChannelLab-profit-sharing-202604', 'Ocean-Currents-NOXCAT-meetings-2026-04-07']

**菜姐** (terms: `['菜姐']`)
- Jieba: 16 hits | Haiku: 41 hits
- Jieba top-5: Closet-Concepts-CLSC-CLSC(1), Closet-Concepts-CLSC-CLSC-dogfood-week1(1), Closet-Reviews-CR-20260408-clsc-v0-4-fork(1), Closet-Reviews-CR-20260408-clsc-v0-6-hancloset(1), Closet-Wings-ChannelLab-Org-People(1)
- Haiku top-5: 00Daily-2026-04-09(1), Assets-ChannelLab-Equity-CHL_Term_Sheet(1), Assets-ChannelLab-Equity-_202604(1), Bot-Config-channellab-bot-framework(1), Closet-Archive-CLSC-Dictionary-Anya-Ext(1)
- Haiku-only (sample): ['Closet-Wings-ChannelLab-Org-profit-sharing-202604', 'Assets-ChannelLab-Equity-CHL_Term_Sheet', 'Closet-Concepts-FATQ']
- Jieba-only (sample): ['Ocean-Chart-CLSC-CLSC-dogfood-week1', 'Ocean-Reviews-CR-20260408-clsc-v0-6-hancloset', 'Wiki-Concepts-CLSC-CLSC-dogfood-week1']

**星星人** (terms: `['星星人']`)
- Jieba: 0 hits | Haiku: 10 hits
- Jieba top-5: 
- Haiku top-5: Closet-Concepts-Architecture-Bot-Team-Architecture(1), Closet-Concepts-Architecture-ChannelLab-AI-Architecture(1), Closet-Reviews-CR-20260408-vps-since-infra-audit(1), Ocean-Chart-Architecture-Bot-Team-Architecture(1), Ocean-Chart-Architecture-ChannelLab-AI-Architecture(1)
- Haiku-only (sample): ['Wiki-Concepts-Architecture-Bot-Team-Architecture', 'Closet-Concepts-Architecture-Bot-Team-Architecture', 'Closet-Reviews-CR-20260408-vps-since-infra-audit']

**Vincent** (terms: `['vincent']`)
- Jieba: 0 hits | Haiku: 8 hits
- Jieba top-5: 
- Haiku top-5: 00Daily-2026-04-09(1), Closet-People-JD_BD_Japan_Web3_2026-04(1), Closet-Research-nick-spisak-method(1), Closet-Wings-ChannelLab-GEO-People-JD_BD_Japan_Web3_2026-04(1), Ocean-Currents-ChannelLab-GEO-People-JD_BD_Japan_Web3_2026-04(1)
- Haiku-only (sample): ['Closet-Research-nick-spisak-method', 'Closet-People-JD_BD_Japan_Web3_2026-04', 'Closet-Wings-ChannelLab-GEO-People-JD_BD_Japan_Web3_2026-04']

**Elon** (terms: `['elon']`)
- Jieba: 6 hits | Haiku: 17 hits
- Jieba top-5: Closet-Concepts-ADR-Knowledge-Infra-ADR-2026-04-08(1), Closet-Wings-NOXCAT(1), Ocean-Chart-ADR-Knowledge-Infra-ADR-2026-04-08(1), Ocean-Currents-NOXCAT(1), Wiki-Concepts-ADR-Knowledge-Infra-ADR-2026-04-08(1)
- Haiku top-5: Closet-Archive-CLSC-Dictionary-Anya-Ext(1), Closet-Concepts-ADR-Knowledge-Infra-ADR-2026-04-08(1), Closet-Concepts-FATQ(1), Closet-Research-knowledge-infra-proposal-elon-musk(1), Closet-Wings-NOXCAT(1)
- Haiku-only (sample): ['Closet-Research-knowledge-infra-proposal-elon-musk', 'Ocean-Depth-CLSC-Dictionary-Anya-Ext', 'Closet-Concepts-FATQ']

### Topic Queries

**GEO 服務** (terms: `['geo', '服務']`)
- Jieba: 71 hits | Haiku: 64 hits
- Jieba top-5: Closet-Companies-ChannelLab-GEO-Pricing(2), Closet-Wings-ChannelLab-GEO-ChannelLab-GEO-Pricing(2), Ocean-Currents-ChannelLab-GEO-ChannelLab-GEO-Pricing(2), Wiki-Companies-ChannelLab-GEO-Pricing(2), 00Daily-2026-04-06(1)
- Haiku top-5: Closet-Cards-ChannelLab(2), Closet-Companies-ChannelLab-GEO-Pricing(2), Closet-Reviews-CR-20260408-temporal-kg-fork(2), Ocean-Currents-ChannelLab-GEO-ChannelLab-GEO-Pricing(2), Ocean-Reviews-CR-20260408-temporal-kg-fork(2)
- Haiku-only (sample): ['Closet-Cards-ChannelLab', 'Archive-MOC-MOC-AI-Research', 'Closet-Reviews-CR-20260408-temporal-kg-fork']
- Jieba-only (sample): ['Assets-Portfolio-Bonk-Bonk_GEO_Report', 'Assets-Research-GEO-Analyzer-PRD', 'Closet-Wings-ChannelLab-GEO-ChannelLab-GEO-Pricing']

**搶票 Bot** (terms: `['搶票', 'bot']`)
- Jieba: 123 hits | Haiku: 61 hits
- Jieba top-5: Archive-MOC-MOC-Claude-Bots(1), Archive-Xbar-Bot-Status-Plugin(1), Assets-Research-GEO-Analyzer-PRD(1), Bot-Config-channellab-bot-framework(1), Bot-Config-claude-bots-README-claude-telegram-bots(1)
- Haiku top-5: 00Daily-2026-04-06(1), 00Daily-2026-04-08(1), 00Daily-2026-04-10(1), 08-Daily-2026-04-06(1), 08-Daily-2026-04-08(1)
- Haiku-only (sample): ['00Daily-2026-04-10', 'CLAUDE', '00Daily-2026-04-08']
- Jieba-only (sample): ['Assets-Research-GEO-Analyzer-PRD', 'Closet-Concepts-FATQ', 'Closet-Cards-FATQ-File-Atomic-Task-Queue']

**知識庫 架構** (terms: `['知識庫', '架構']`)
- Jieba: 95 hits | Haiku: 86 hits
- Jieba top-5: Closet-Concepts-FTS5-bot(2), Closet-Research-nick-spisak-method(2), Ocean-Chart-FTS5-bot(2), Ocean-Chart-MemOcean(2), Ocean-Chart-chart-clsc(2)
- Haiku top-5: Closet-Archive-llm-wiki-log(2), Closet-Research-knowledge-infra-proposal-panda(2), Closet-Reviews-CR-20260408-clsc-v0-6-hancloset(2), Closet-_index(2), Ocean-Chart-MemOcean(2)
- Haiku-only (sample): ['Ocean-Depth-llm-wiki-log', 'Closet-Cards-AI-agent-bot', 'Closet-Cards-MCP-background-agent']
- Jieba-only (sample): ['Closet-Research-nick-spisak-method', 'Assets-Research-Planning-claude_code_prompt', 'Closet-Concepts-Architecture-ChannelLab-AI-Architecture']

**壓縮 compression** (terms: `['壓縮', 'compression']`)
- Jieba: 45 hits | Haiku: 69 hits
- Jieba top-5: Closet-Archive-CLSC-Spec(2), Ocean-Depth-CLSC-Spec(2), Wiki-Archive-CLSC-Spec(2), Wiki-Concepts-CLSC-CLSC-Spec(2), Wiki-Concepts-CLSC-Spec(2)
- Haiku top-5: Closet-Research-chinese-llm-compression-landscape(2), Ocean-Chart-CLSC-CLSC-Technical-Spec(2), Ocean-Research-chinese-llm-compression-landscape(2), Ocean-Reviews-CR-20260408-clsc-v0-4-fork(2), Wiki-Concepts-CLSC-CLSC-Technical-Spec(2)
- Haiku-only (sample): ['Ocean-Reviews-CR-20260408-clsc-v0-4-fork', 'Wiki-Concepts-CLSC-CLSC-Technical-Spec', 'Wiki-Research-chinese-llm-compression-landscape']
- Jieba-only (sample): ['Closet-Reviews-Test-CLSC-Result-v0-1', 'Ocean-Chart-CLSC-CLSC-Technical-Spec-zh', 'Closet-Concepts-CLSC-CLSC']

**部署 VPS** (terms: `['部署', 'vps']`)
- Jieba: 30 hits | Haiku: 11 hits
- Jieba top-5: Bot-Config-setup-local-ai-sop(2), Closet-Concepts-SOP-Local-Setup-AI-SOP(2), Ocean-Chart-SOP-Local-Setup-AI-SOP(2), Wiki-Concepts-Local-Setup-AI-SOP(2), Wiki-Concepts-SOP-Local-Setup-AI-SOP(2)
- Haiku top-5: Bot-Config-setup-local-ai-sop(2), Closet-Concepts-SOP-Local-Setup-AI-SOP(2), Ocean-Chart-SOP-Local-Setup-AI-SOP(2), Wiki-Concepts-Local-Setup-AI-SOP(2), Wiki-Concepts-SOP-Local-Setup-AI-SOP(2)
- Haiku-only (sample): ['Bot-Config-claude-bots-README-claude-telegram-bots', 'Ocean-Seabed-chats-clsc', 'Ocean-Reviews-CR-20260408-vps-since-infra-audit']
- Jieba-only (sample): ['Closet-Research-gnekt-mybrain-vs-channellab', 'Ocean-Research-gnekt-mybrain-vs-channellab', 'Closet-Research-knowledge-infra-proposal-elon-musk']

**Task Queue** (terms: `['task', 'queue']`)
- Jieba: 48 hits | Haiku: 8 hits
- Jieba top-5: Closet-Archive-CLSC-Spec(2), Closet-Cards-FATQ-File-Atomic-Task-Queue(2), Closet-Concepts-FATQ(2), Ocean-Chart-FATQ(2), Ocean-Depth-CLSC-Spec(2)
- Haiku top-5: Closet-Concepts-FATQ(2), Ocean-Chart-FATQ(2), Wiki-Concepts-FATQ(2), Archive-Templates-Daily-Note(1), Closet-Cards-FATQ-File-Atomic-Task-Queue(1)
- Haiku-only (sample): ['Ocean-Research-knowledge-infra-proposal-chef', 'Archive-Templates-Daily-Note', 'Ocean-Reviews-CR-20260408-hermes-skill-loop-poc']
- Jieba-only (sample): ['Closet-Research-knowledge-infra-proposal-chef', 'Closet-Research-knowledge-infra-proposal-panda', 'Wiki-Cards-FATQ-File-Atomic-Task-Queue']

**Obsidian vault** (terms: `['obsidian', 'vault']`)
- Jieba: 61 hits | Haiku: 51 hits
- Jieba top-5: Bot-Config-setup-local-ai-sop(2), CLAUDE(2), Closet-Concepts-SOP-Local-Setup-AI-SOP(2), Closet-Research-gnekt-mybrain-vs-channellab(2), Closet-Research-graphify-research(2)
- Haiku top-5: CLAUDE(2), Closet-Research-gnekt-mybrain-vs-channellab(2), Closet-Research-knowledge-infra-proposal-chef(2), Ocean-Research-knowledge-infra-proposal-chef(2), Ocean-Research-knowledge-infra-proposal-elon-musk(2)
- Haiku-only (sample): ['Ocean-Chart-CLSC-CLSC-empirical-results', 'Ocean-Chart-ADR-Knowledge-Infra-ADR-2026-04-08', 'Closet-Cards-MCP-background-agent']
- Jieba-only (sample): ['Ocean-Research-gnekt-mybrain-vs-channellab', 'Wiki-Concepts-Local-Setup-AI-SOP', 'Ocean-Research-knowledge-infra-proposal-panda']

**Telegram hook** (terms: `['telegram', 'hook']`)
- Jieba: 36 hits | Haiku: 22 hits
- Jieba top-5: Archive-MOC-MOC-Claude-Bots(1), Bot-Config-channellab-bot-framework(1), Bot-Config-claude-bots-README-claude-telegram-bots(1), Bot-Config-mistakes(1), Closet-Cards-hermes-agent(1)
- Haiku top-5: Archive-MOC-MOC-Claude-Bots(1), Archive-Xbar-Bot-Status-Plugin(1), Bot-Config-channellab-bot-framework(1), Bot-Config-claude-bots-README-claude-telegram-bots(1), Bot-Config-mistakes(1)
- Haiku-only (sample): ['Wiki-Concepts-Team-Onboarding-SOP', 'Closet-Research-gnekt-mybrain-vs-channellab', 'Wiki-Cards-hermes-agent']
- Jieba-only (sample): ['Closet-Research-knowledge-infra-proposal-chef', 'Ocean-Research-knowledge-infra-proposal-chef', 'Ocean-Research-hermes-agent-research']

**股權 equity** (terms: `['股權', 'equity']`)
- Jieba: 22 hits | Haiku: 11 hits
- Jieba top-5: Assets-ChannelLab-Equity-Nicky_Equity_Overview(2), Closet-Companies-ChannelLab-Equity(2), Closet-Wings-ChannelLab-Org-ChannelLab-Equity(2), Closet-_index(2), Ocean-Currents-ChannelLab-Org-ChannelLab-Equity(2)
- Haiku top-5: Assets-ChannelLab-Equity-Nicky_Equity_Overview(2), Wiki-Projects-ChannelLab-profit-sharing-202604(2), Assets-ChannelLab-Equity-CHL_Term_Sheet(1), Assets-ChannelLab-Equity-_202604(1), Closet-Companies-ChannelLab-Equity(1)
- Haiku-only (sample): ['Closet-Wings-ChannelLab-Org-profit-sharing-202604', 'Wiki-Projects-ChannelLab-profit-sharing-202604', 'Closet-Projects-ChannelLab-profit-sharing-202604']
- Jieba-only (sample): ['Ocean-Chart-CLSC-CLSC-empirical-results', 'Ocean-_index', 'Closet-_index']

**設計稿 design** (terms: `['設計稿', 'design']`)
- Jieba: 16 hits | Haiku: 2 hits
- Jieba top-5: Assets-ChannelLab-GEO-Service-GEO-Frontend-Redesign-Spec(1), Closet-Cards-Reviewer(1), Closet-Concepts-Architecture-ChannelLab-AI-Architecture(1), Closet-Projects-NOXCAT-meetings-2026-04-07(1), Closet-Reviews-Test-CLSC-Result-v0-2(1)
- Haiku top-5: Assets-ChannelLab-GEO-Service-GEO-Frontend-Redesign-Spec(1), Bot-Config-gstack-workflow(1)
- Haiku-only (sample): ['Bot-Config-gstack-workflow']
- Jieba-only (sample): ['Wiki-Concepts-ChannelLab-AI-Architecture', 'Closet-Concepts-Architecture-ChannelLab-AI-Architecture', 'Closet-Wings-NOXCAT-meetings-2026-04-07']

### Natural Queries

**上週的決策** (terms: `['上週', '決策']`)
- Jieba: 33 hits | Haiku: 30 hits
- Jieba top-5: Archive-MOC-MOC-Dashboard(1), Bot-Config-channellab-bot-framework(1), Closet-Archive-llm-wiki-raw-articles-2026-04-05-blocktempo-eip-8141-hegota(1), Closet-Cards-Cards-AI(1), Closet-Concepts-ADR-CLSC(1)
- Haiku top-5: Archive-MOC-MOC-Dashboard(1), Archive-Templates-Meeting-Note(1), Closet-Cards-Cards-AI(1), Closet-Concepts-ADR-CLSC(1), Closet-Concepts-SOP-New-Tool-Adoption-SOP(1)
- Haiku-only (sample): ['Closet-Concepts-SOP-New-Tool-Adoption-SOP', 'Closet-People-Ron', 'Closet-Research-knowledge-infra-proposal-chef']
- Jieba-only (sample): ['Ocean-Chart-ADR-Knowledge-Infra-ADR-2026-04-08', 'Closet-Research-CZ-Memoir-Strategy-Lessons', 'Closet-Archive-llm-wiki-raw-articles-2026-04-05-blocktempo-eip-8141-hegota']

**商業模式是什麼** (terms: `['商業', '模式']`)
- Jieba: 55 hits | Haiku: 13 hits
- Jieba top-5: Closet-Concepts-Architecture-ChannelLab-AI-Architecture(2), Ocean-Chart-Architecture-ChannelLab-AI-Architecture(2), Wiki-Concepts-Architecture-ChannelLab-AI-Architecture(2), Wiki-Concepts-ChannelLab-AI-Architecture(2), Archive-MOC-MOC-Business(1)
- Haiku top-5: Archive-MOC-MOC-Business(1), Assets-Research-Planning-claude_code_prompt(1), Closet-Cards-ChannelLab(1), Closet-Reviews-CR-20260408-channellab-kb-mcp-v0-1(1), Closet-_index(1)
- Haiku-only (sample): ['Closet-Cards-ChannelLab', 'Ocean-_index', 'Wiki-Archive-CLSC-Dictionary']
- Jieba-only (sample): ['Closet-Research-gnekt-mybrain-vs-channellab', 'Closet-Cards-nick-spisak-method', 'Closet-Research-knowledge-infra-proposal-chef']

**誰負責 review** (terms: `['負責', 'review']`)
- Jieba: 89 hits | Haiku: 27 hits
- Jieba top-5: Closet-Concepts-Architecture-ChannelLab-AI-Architecture(2), Ocean-Chart-Architecture-ChannelLab-AI-Architecture(2), Wiki-Concepts-Architecture-ChannelLab-AI-Architecture(2), Wiki-Concepts-ChannelLab-AI-Architecture(2), Assets-ChannelLab-Equity-Nicky_Equity_Overview(1)
- Haiku top-5: Closet-Cards-Reviewer(1), Closet-Concepts-Architecture-Bot-Team-Architecture(1), Closet-Concepts-Architecture-channellab-bot-framework(1), Closet-Reviews-CR-20260408-browser-automation-spike(1), Closet-Reviews-CR-20260408-channellab-kb-mcp-v0-1(1)
- Haiku-only (sample): ['Wiki-Concepts-Architecture-Bot-Team-Architecture', 'Ocean-Pearl-Reviewer', 'Closet-Reviews-CR-20260408-vps-since-infra-audit']
- Jieba-only (sample): ['Closet-Research-knowledge-infra-proposal-elon-musk', 'Closet-Research-nick-spisak-method', 'Closet-People-Ron']

**怎麼部署到生產環境** (terms: `['部署', '生產', '環境']`)
- Jieba: 30 hits | Haiku: 15 hits
- Jieba top-5: Bot-Config-setup-local-ai-sop(2), Closet-Concepts-SOP-Local-Setup-AI-SOP(2), Ocean-Chart-SOP-Local-Setup-AI-SOP(2), Wiki-Concepts-Local-Setup-AI-SOP(2), Wiki-Concepts-SOP-Local-Setup-AI-SOP(2)
- Haiku top-5: Bot-Config-setup-local-ai-sop(2), Closet-Concepts-SOP-Local-Setup-AI-SOP(2), Closet-Reviews-CR-20260408-clsc-v0-6-hancloset(2), Ocean-Chart-SOP-Local-Setup-AI-SOP(2), Ocean-Reviews-CR-20260408-clsc-v0-6-hancloset(2)
- Haiku-only (sample): ['Bot-Config-claude-bots-README-claude-telegram-bots', 'Ocean-Research-ZK-2026-survey', 'Ocean-Reviews-CR-20260408-clsc-v0-6-hancloset']
- Jieba-only (sample): ['Closet-Research-gnekt-mybrain-vs-channellab', 'Ocean-Research-gnekt-mybrain-vs-channellab', 'Ocean-Research-Anthropic-Managed-Agents-2026-04-09']

**Bot 團隊分工** (terms: `['bot', '團隊', '分工']`)
- Jieba: 159 hits | Haiku: 101 hits
- Jieba top-5: Archive-MOC-MOC-Claude-Bots(2), Assets-Research-GEO-Analyzer-PRD(2), Bot-Config-mistakes(2), Closet-Cards-AI-agent-bot(2), Closet-Cards-MCP-background-agent(2)
- Haiku top-5: Ocean-Chart-Architecture-Bot-Team-Architecture(3), Wiki-Concepts-Bot-Team-Architecture(3), 00Daily-2026-04-06(2), 00Daily-2026-04-08(2), 08-Daily-2026-04-06(2)
- Haiku-only (sample): ['Closet-Research-gnekt-mybrain-vs-channellab', 'Ocean-Research-gnekt-mybrain-vs-channellab', 'Wiki-Concepts-Architecture-Bot-Team-Architecture']
- Jieba-only (sample): ['Assets-Research-GEO-Analyzer-PRD', 'Closet-Cards-MCP-background-agent', 'Closet-Concepts-FATQ']

**日曆行程安排** (terms: `['日曆', '行程', '安排']`)
- Jieba: 18 hits | Haiku: 1 hits
- Jieba top-5: 00Daily-2026-04-06(1), 00Daily-2026-04-08(1), 00Daily-2026-04-09(1), 00Daily-2026-04-10(1), 08-Daily-2026-04-06(1)
- Haiku top-5: 08-Daily-2026-04-08(1)
- Jieba-only (sample): ['00Daily-2026-04-09', 'Closet-Wings-NOXCAT-meetings-2026-04-07', 'Wiki-Concepts-CLSC-Test-Spec']

**API 串接方式** (terms: `['api', '串接']`)
- Jieba: 25 hits | Haiku: 28 hits
- Jieba top-5: Assets-ChannelLab-GEO-Service-geo-analyzer-README-geo-demo(1), Assets-Portfolio-PRD-Anya-Voice-Assistant(1), Bot-Config-mistakes(1), Bot-Config-setup-local-ai-sop(1), Closet-Companies-Gene-Capital(1)
- Haiku top-5: Archive-MOC-MOC-Business(1), Archive-MOC-MOC-GEO-Analyzer(1), Assets-Research-Planning-claude_code_prompt(1), Bot-Config-mistakes(1), Closet-Archive-CLSC-Dictionary(1)
- Haiku-only (sample): ['Ocean-_index', 'Assets-Research-Planning-claude_code_prompt', 'Wiki-Concepts-CLSC-CLSC-Dictionary']
- Jieba-only (sample): ['Wiki-Cards-concepts-Anthropic-Managed-Agents-2026-04-09', 'Wiki-Concepts-Local-Setup-AI-SOP', 'Ocean-Research-Anthropic-Managed-Agents-2026-04-09']

**提案報價流程** (terms: `['提案', '報價', '流程']`)
- Jieba: 68 hits | Haiku: 45 hits
- Jieba top-5: 00Daily-2026-04-06(1), 08-Daily-2026-04-06(1), Assets-Portfolio-Bonk-Bonk_GEO_Proposal_ZH(1), Bot-Config-channellab-bot-framework(1), Bot-Config-gstack-workflow(1)
- Haiku top-5: 00Daily-2026-04-06(1), 00Daily-2026-04-08(1), 08-Daily-2026-04-06(1), 08-Daily-2026-04-08(1), Bot-Config-gstack-workflow(1)
- Haiku-only (sample): ['Closet-Concepts-Architecture-Bot-Team-Architecture', 'Closet-Reviews-CR-20260408-vps-since-infra-audit', 'Bot-Config-setup-local-ai-sop']
- Jieba-only (sample): ['Closet-Research-gnekt-mybrain-vs-channellab', 'Closet-Archive-llm-wiki-wiki-entities-Hegot', 'Closet-Research-knowledge-infra-proposal-chef']

**記憶系統怎麼運作** (terms: `['記憶', '系統', '運作']`)
- Jieba: 57 hits | Haiku: 53 hits
- Jieba top-5: Closet-Research-hermes-agent-research(2), Ocean-Research-hermes-agent-research(2), Wiki-Research-hermes-agent-research(2), Archive-MOC-MOC-Claude-Bots(1), Assets-Portfolio-Bonk-Bonk_CN_GEO_Report-1(1)
- Haiku top-5: Closet-Research-knowledge-infra-proposal-elon-musk(2), Closet-Reviews-CR-20260408-vps-since-infra-audit(2), Ocean-Research-knowledge-infra-proposal-elon-musk(2), Ocean-Research-mempalace-deep-mining-2026-04-08(2), Wiki-Research-hermes-agent-research(2)
- Haiku-only (sample): ['Closet-Research-gnekt-mybrain-vs-channellab', 'Closet-Research-nick-spisak-method', 'Bot-Config-mistakes']
- Jieba-only (sample): ['Assets-Research-Planning-claude_code_prompt', 'Closet-Projects-Bonk-AIO-Strategy', 'Closet-Research-knowledge-infra-proposal-chef']

**每日待辦追蹤** (terms: `['每日', '待辦', '追蹤']`)
- Jieba: 28 hits | Haiku: 10 hits
- Jieba top-5: 00Daily-2026-04-06(2), 00Daily-2026-04-08(2), 08-Daily-2026-04-06(2), 08-Daily-2026-04-08(2), Closet-Concepts-Architecture-ChannelLab-AI-Architecture(2)
- Haiku top-5: 00Daily-2026-04-06(2), 00Daily-2026-04-08(2), 00Daily-2026-04-10(2), 08-Daily-2026-04-08(2), Archive-MOC-MOC-Dashboard(2)
- Haiku-only (sample): ['00Daily-2026-04-10', 'Archive-Templates-Daily-Note', 'Closet-Companies-Media-Resource-List']
- Jieba-only (sample): ['Closet-Research-knowledge-infra-proposal-elon-musk', 'Closet-Research-knowledge-infra-proposal-chef', 'Ocean-Research-knowledge-infra-proposal-chef']

## Entity Precision Analysis (Person Queries)

Check: do person-name queries return topically relevant results?

**老兔**: Jieba 108 hits vs Haiku 99 hits

**Ron**: Jieba 58 hits vs Haiku 63 hits

**Nicky**: Jieba 29 hits vs Haiku 50 hits

**Anna**: Jieba 41 hits vs Haiku 112 hits
  - NOTE: Haiku returns 2.7x more results

**Bella**: Jieba 37 hits vs Haiku 130 hits
  - NOTE: Haiku returns 3.5x more results

**桃桃**: Jieba 14 hits vs Haiku 38 hits
  - NOTE: Haiku returns 2.7x more results

**菜姐**: Jieba 16 hits vs Haiku 41 hits
  - NOTE: Haiku returns 2.6x more results

**星星人**: Jieba 0 hits vs Haiku 10 hits

**Vincent**: Jieba 0 hits vs Haiku 8 hits

**Elon**: Jieba 6 hits vs Haiku 17 hits
  - NOTE: Haiku returns 2.8x more results

## Qualitative Observations

### Skeleton Format Comparison (5 samples)

**00Daily-2026-04-06**
- Jieba: `[2026-04-06|2026-04-06 daily note] ent:行程 key:診斷報告在 ~/aiwork/projects/geo-analyzer/reports/ -   追蹤南良合作進度 p1 channellab   - 等南良|2026-04-06 daily note  ...`
- Haiku: `[2026-04-06-daily-note|bonk,channellab,南良,bot團隊,老兔,bella,anna,geo-analyzer,brand-geo-score|待辦追蹤,提案進度,geo項目,llm集成,github部署|等客戶回覆,追蹤南良合作進度|w3|neutral|]...`

**00Daily-2026-04-08**
- Jieba: `[2026-04-08|2026-04-08（三）] ent:行程 key:2026-04-08（三）  📅 行程  google calendar mcp 連線中，明早補  📋 待辦  🔴 進行中（高優先） -   追蹤 bonk g...`
- Haiku: `2026-04-08-待辦清單|bonk,南良,bella,google calendar,clsc,geo,llm wiki,老兔,chltao_bot|項目進度追蹤,團隊協作,技術開發,系統整合|"追蹤 bonk geo 提案進度，建議主動 follow-up"|w3|neutral||...`

**00Daily-2026-04-09**
- Jieba: `[2026-04-09|2026-04-09] ent:張凌赫,南良,草稿 key:| ---  📋 待辦（按優先度）  🔴 高優先 - x 0xkingskuan tweet 對比 adr — 等老兔截圖後 anya 處理 ✅ 2026-04|主要交付： - clsc 6 輪 reframe → ...`
- Haiku: `[2026-04-09|anna,anya,bella,张凌赫,nicky,vincent wen,老兔,ck,菜姐,oldrabbit|google calendar mcp,inotify daemon,任務管理,進度追蹤|google calendar mcp 離線，明早確認行事曆|w3|ne...`

**00Daily-2026-04-10**
- Jieba: `[2026-04-10|2026-04-10 (五)] ent:行程 key:2026-04-10 五 ---  📅 行程 | 時間 | 事項 | |------|------| | 全天 | 發薪水 💰 | | 21:00–22:00  tag:[daily]...`
- Haiku: `[2026-04-10-daily|nicky,ck,oldrabbit,anna,anya|發薪日,待辦優先排序,專案追蹤,團隊溝通|"aot-002搶票13:00開搶，確認帳務發薪"|w2|neutral|]...`

**08-Daily-2026-04-06**
- Jieba: `[2026-04-06|2026-04-06 daily note] ent:行程 key:診斷報告在 ~/aiwork/projects/geo-analyzer/reports/ -   追蹤南良合作進度 p1 channellab   - 等南良|2026-04-06 daily note  ...`
- Haiku: `[2026-04-06-daily-note|bonk geo,南良,channellab,bot團隊,老兔,bella,anna|提案追蹤,geo phase 2,llm wiki整合,github pr,brand geo score|等客戶回覆bonk geo提案進度|w3|neutral|]...`

## Deep-Dive: False Positive Analysis

### "Ron" Substring Problem (Jieba)

Jieba skeleton stores raw text, so searching `ron` matches substrings like `frontend`, `cron`, `frontmatter`, `environ`.

| | True Positives | False Positives | Precision |
|---|---|---|---|
| Jieba | 26 | 32 | 44.8% |
| Haiku | 58 | 5 | 92.1% |

Haiku's structured entity field isolates person names, yielding **2x the true positives with 6x fewer false positives**.

### Missing Entities (Jieba)

Jieba skeleton **completely misses** these person names (0 hits):
- **星星人** (0 vs Haiku 10) -- jieba tokenizer splits this compound nickname
- **Vincent** (0 vs Haiku 8) -- jieba drops English names that aren't in its dictionary

### Entity Recall Gap: Anna / Bella / 桃桃

| Person | Jieba hits | Haiku hits | Ratio |
|--------|-----------|-----------|-------|
| Anna | 41 | 112 | 2.7x |
| Bella | 37 | 130 | 3.5x |
| 桃桃 | 14 | 38 | 2.7x |
| 菜姐 | 16 | 41 | 2.6x |

Haiku extracts entity names into a dedicated field even when the original text only mentions them in passing. Jieba skeleton retains raw text, so names get buried or truncated.

### Topic / Natural Language: Why Jieba Wins on Raw Hits

Jieba skeleton preserves more **verbatim text** (action items, bullet points, raw sentences). For broad keyword queries like "部署", "系統", "模式", this acts as a full-text-ish search and produces more hits. However, many of these hits are low-relevance (e.g., "部署" appearing in boilerplate SOP text).

Haiku skeleton **summarizes topics** into concise labels (e.g., "GitHub部署", "系統整合"), so it matches fewer documents but with higher topical relevance.

### Chinese Tokenization: Jieba's Structural Weakness

Jieba `ent:` field extraction is naive -- it frequently tags common nouns as entities:
- `ent:行程` (schedule) appears in many Daily Notes instead of actual person/org names
- `ent:草稿` (draft) tagged as entity
- Compound terms like `星星人` get split by jieba tokenizer and lost

Haiku understands semantics and correctly identifies `星星人` as a person alias, `Vincent Wen` as a full name, etc.

## Conclusion

### Raw Numbers

Jieba produces **11% more total hits** (1418 vs 1276), but this is misleading.

### Adjusted Assessment

| Dimension | Winner | Why |
|-----------|--------|-----|
| **Entity recall** | Haiku (large margin) | +84% more person-name hits; catches names jieba misses entirely |
| **Entity precision** | Haiku (large margin) | 92% vs 45% precision on "Ron" query; no substring false positives |
| **Topic breadth** | Jieba (small margin) | Preserves more raw text, catches more keyword fragments |
| **Topic relevance** | Haiku | Structured topic labels are more semantically meaningful |
| **Natural language** | Jieba (raw count) / Haiku (quality) | Jieba matches more docs but many are noise |
| **Zero-hit queries** | Haiku | 0 zero-hit queries vs Jieba's 2 (星星人, Vincent) |

### Recommendation

**Haiku skeleton is strictly better for entity-centric search** (the primary use case for closet lookup). For keyword/topic search, consider a hybrid approach: use Haiku skeleton for entity matching + jieba/FTS5 for full-text keyword fallback.

The 11% raw hit advantage of jieba is entirely from topic/natural-language categories where many hits are low-relevance noise. In the person-name category where precision matters most, Haiku outperforms by **84% more hits with 2x better precision**.