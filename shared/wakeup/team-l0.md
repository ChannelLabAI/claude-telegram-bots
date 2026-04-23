---
type: wakeup-layer
generated_at: 2026-04-23
related: ["[[Bot-Team-Architecture]]", "[[Knowledge-Infra-ADR-2026-04-08]]", "[[CLSC]]"]
---

# ChannelLab Team L0

> 每隻 bot 啟動必讀。fixed ≤300 + agenda ≤200 + total ≤500 tokens。詳見 [architecture-constraints](../shared/architecture-constraints.md)。

**團隊**：老兔(CEO) / 菜姐(PMO) / Ron / Nicky / 桃桃 / 川哥(外部顧問) / Lilai / Wes
**特助**：Anya↔老兔, Panda↔Ron, 張凌赫↔Nicky, Elon Musk↔桃桃, 主廚↔菜姐, 風風↔Lilai, Wes-buddy↔Wes
**共用池**: Builder=Anna+三菜+Eric / Reviewer=Bella+一湯+KKKK / Designer=星星人

**Active queue**: pending=5, in_progress=3, review=3

**Latest ADR**: none

**焦點任務（進行中）**：
老兔：
  - 🟡 **GBrain × MemOcean Merge Phase 1 Path A**（04-20 拍板）：GBrain 作檢索底層、MemOcean 作應用層，5 特助 MCP 介面不變。Anya 首次自撰 spec，Bella plan-review **APPROVE_WITH_NOTES（4 BLOCKERS 待修 ~2hr）**，修完派 Anna 實作，10 天 timeline。**老兔焦點任務**。
  - 🟡 **Seabed 重構 Phase 1.5**（04-20 拍板）：Seabed 升級為所有原檔統一命名空間（chats/docs/reef/raw），對話移子目錄，4 個 auto-save 入口改寫 + 90 天 backward compat。FATQ 派 Eric，3-4 天 timeline，與 Phase 1 並行不衝突。
  - ✅ **Cove Protocol Phase 2 + Mac cutover + cv6/cv7 auto-surface 全收**（04-22 20+ 小時連續作戰）：cv5 三段 + cv5-hf2/hf3 + cv1b（3 commits a16b67f/c16e3ee/6bac96b）+ Mac cutover（trust_list 只剩 mcp-agent 6bb06983）+ **cv6 hook auto-inject ship**（UserPromptSubmit 自動浮現 `<channel source="plugin:cove">`）+ **cv7 Relay Injection ship**（Ron Approach E，session 無新 prompt ≤30s 自動浮現，42/42 tests，daemon 23:04 restart）。**剩 P2**：`cv1b-mypubkey-op-bug`（my_pubkey op 回空）；runbook v2 重寫（v1 staging 已加 6 條後記）；cv7 Mac 端 E2E 多次實測穩定性觀察。
菜姐：
  - 🟡 AOT-003：菜姐提供 ThaiTicketMajor 帳號 + 信用卡 → dry run → 4/18 11:00 開搶
  - 🟡 等詹小萱回覆確認入職（駐日 BD）
  - 🟡 準備合約給詹小萱（駐日 BD）
Ron：
  - **地推隊長管理系統**（captain-tracker）— 百位隊長 KPI 追蹤，9 個月 $1.7 億美金目標；VPS: `~/projects/captain-tracker/`
  - **ChannelPulse 內容運營** — 媒體內容板塊日常推進
Nicky：
  （未建立）
Wes：
  （尚無待跟進項目）
Lilai：
  （未建立）
桃桃：
  （未建立）

**📋 Agenda 摘要**（原文 `agenda.md`，每小時刷新）:
## Current OKR
- **agenda.md 格式不統一 — `：` vs `—`**
- **Syncthing 同步穩定性**
- **gstack SOP 對純 infra 任務不靈活**

## Pending Decisions
- **駐日 BD 詹小萱 Offer**
- **MemOcean Phase B 實作形式**
- **Bonk GEO 提案**
_(+2 more)_

## Risk Watch
- **Governance debt — 架構約束散落**
- **MEMO-INTENT-A 測試覆蓋 gap — CJK 括號 header**

**Wakeup steps**: (1) 讀此檔 (2) 讀自己的 memory/MEMORY.md (3) 讀 mistakes.md (4) 掃 FATQ 找自己單 (5) TG 報到

**Routing**: 履歷→Notion 候選人+Ocean/People; 任務→tasks/; 客戶→Notion Pipeline; 知識→Ocean/Cards+Concepts; 不能刪 Notion→title 加 🗑️(DELETE ME)

**深入閱讀**：[[Knowledge-Infra-ADR-2026-04-08]] / [[CLSC]] / [[Bot-Team-Architecture]]
