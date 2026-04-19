---
type: intent-agenda
scope: channellab-team
updated: 2026-04-19
owner: Anya (Phase A 單人維護)
tags: [policy, agenda, intent]
related: [[[MemOcean]], [[Bot-Team-Architecture]], [[architecture-constraints]]]
---

# ChannelLab Team Agenda

> **Phase A 人工維護版**（MEMO-INTENT-A）。Anya 一人 seed + 編輯；其他特助主軸由各特助主動 submit 給 Anya 統一編排。每次變更寫入 `updated` 欄位。
>
> 每小時由 `regenerate-team-l0.sh` 自動壓縮進 team-l0.md 動態段（上限 200 tokens）。原文在此檔，所有 bot 可按需完整讀取。

---

## Current OKR（Q2 2026）

- **[MemOcean] 冷啟動 token 降至 7k 以下**：已達 7,677（Phase 2 ✅）；持續尋找壓縮空間
- **[MemOcean] Intent + Cognitive Synthesis 上線**：從 infra 跨到 intelligence 層；Phase A（Intent）今日推完，Phase B（Cognitive Synthesis）2 週後排期
- **[ChannelLab] GEO 服務商業化**：Bonk pipeline 推進 + 潛在客戶擴展
- **[HR] 駐日 BD 正式入職**：詹小萱 Offer 確認中

---

## Pending Decisions（待決策）

- **駐日 BD 詹小萱 Offer**
  - owner: 老兔 + 菜姐
  - 狀態: 等詹小萱回覆確認入職；合約準備中
  - ETA: 本週內

- **MemOcean Phase B 實作形式**
  - owner: Anya（決策後需老兔確認）
  - 選項: (a) 常駐統籌 AI（擬人化） vs (b) nightly cognitive_cycle.py 腳本
  - 觸發條件: Phase A 跑滿 2 週後據實測痛點評估
  - ETA: 2026-05-03

- **Bonk GEO 提案**
  - owner: 老兔
  - 狀態: 04-15 老兔再次跟進；等客戶回覆
  - ETA: 無明確，持續追蹤

- **CHL Web POC 剩餘 4 項**
  - owner: Anya 排工
  - 項目: TBH 真實照片替換 / Partners logo 補充（Solana/ICP/OKX/…）/ §case 區塊 / Mobile 詳細 QA
  - ETA: 需決定時程

---

## Risk Watch（觀察中風險）

- **Governance debt — 架構約束散落**
  - 觀察: 昨天 spec-memocean-intent-phase-a 審查踩到 team-l0 ≤300 標頭 vs 執行層 467 tokens 脫節的坑
  - 緩解: 2026-04-19 新建 `shared/architecture-constraints.md` 為單一 source of truth；Reviewer 審 spec 必讀
  - 狀態: 修復中

- **Syncthing 同步穩定性**
  - 觀察: 2026-04-18 老兔 Mac 斷線約 20 小時，Daily Note 未同步；無主動告警
  - 緩解: 需建 Syncthing peer connectivity 監控（僅觀察，未派工）
  - 狀態: 待派工

- **gstack SOP 對純 infra 任務不靈活**
  - 觀察: MEMO-INTENT-A 是 infra 無 UI，Designer 步驟須人工判定跳過
  - 緩解: 修復 SOP 邏輯加入「自動判斷 Designer 必要性」規則
  - 狀態: 待派工

---

## 維護規則

- 此檔為 Phase A 人工維護。Phase B 上線後，由 Cognitive Synthesis 每日自動更新部分條目。
- 條目完成 → 劃掉或移到 `archive/` 段（月末清理）
- 新增條目必附 owner + ETA（若有）
- 所有 bot 啟動前讀此檔（或 team-l0.md 壓縮版）

---

## 相關

- [[MemOcean]]
- [[Bot-Team-Architecture]]
- [[architecture-constraints]]
- [[spec-memocean-intent-phase-a]]
