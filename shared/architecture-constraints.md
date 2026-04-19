---
type: architecture-policy
scope: all-bots
updated: 2026-04-19
tags: [policy, architecture, budget]
related: [[[Bot-Team-Architecture]], [[MemOcean]], [[memocean-opt-post-mortem-2026-04-18]]]
---

# ChannelLab Bot 系統架構約束

> Reviewer 審任何 spec 前必讀。此檔為單一 source of truth，所有 token / 檔案尺寸 / cron 頻率等系統約束在此集中管理。變更此檔需老兔 CEO 確認（[ESCALATION]）。

## 冷啟動 Token 預算

| 項目 | 上限 | 來源 / 備註 |
|---|---|---|
| 冷啟動總 token | ~8,630 | Phase 2 post-mortem 2026-04-18 達標線 |
| L2.5 priority:high blocks（SessionStart 注入） | 5,000 | memocean-opt-post-mortem-2026-04-18 |
| L2.5 trigger blocks（UserPromptSubmit 注入） | 3,000 | memocean-opt-post-mortem-2026-04-18 |
| team-l0.md — fixed block | 300 | 2026-04-19 spec-memocean-intent-phase-a（原 ≤300 snapshot 升級） |
| team-l0.md — agenda block | 200 | 2026-04-19 新增，配合 MEMO-INTENT-A |
| team-l0.md — total | 500 | 2026-04-19 正式化（原 300 實際已達 467） |
| bots/CLAUDE.md | 3,658 chars | Phase 2 切分後實際值（不是硬上限） |

## 其他系統約束

| 項目 | 值 | 備註 |
|---|---|---|
| Subagent return schema v3 — Haiku | ≤500 tokens | |
| Subagent return schema v3 — Sonnet | ≤1,500 tokens | |
| Subagent return schema v3 — Opus | ≤3,000 tokens | |
| L3a subagent 自我收斂門檻 | 1,500 tokens | §11 |
| FATQ REJECT 升級門檻 | 連續 3 次 | bots/CLAUDE.md §5 |

## 變更流程

1. 任何想變更既有約束的 spec，Reviewer 必標記「架構約束變更」
2. 特助向老兔 [ESCALATION]
3. 老兔批准後更新此檔 + 同步所有引用處

---

## 相關

- [[bots/CLAUDE|Bot 團隊通用規則]]
- [[MemOcean]]
- [[memocean-opt-post-mortem-2026-04-18]]
