---
triggers: ["新通知", "新通道", "notification channel", "新 cron", "watchdog", "loop 上線", "掃描器"]
description: "通道凍結令與 loop 準生證——老兔 2026-07-25 拍板的兩條增生管制政策"
---

# Block: 通道凍結令 & Loop 準生證

> 老兔 2026-07-25 拍板（背景：ai-agent-book ch10 架構體檢，[[2026-07-25-架構體檢-ch10框架]]）。
> 病根診斷：通訊通道與監控 loop 皆為「每次事故長一個器官」式增生——通道 ≥5 套無信封無訂閱無投遞保證，loop 疊床架屋誤報互放大。
> canonical 位置：本檔（shared/blocks/，全隊 symlink 單源）。

## 政策一：通道凍結令（即日生效）

任何**新的通知/通訊需求**，不得再發明：
- 新的檔案投遞慣例（新目錄、新檔名格式的信箱）
- 新的字串標記協定（comment 前綴、emoji 信號、tag 慣例）
- 新的點對點旁路（繞過既有通道直發）

**一律排隊等 W1 事件層承接**（統一協作系統 spec v2 事件層即唯一新增通道的載體；散裝存量通道隨 W1 adapter 階段歸一，屆時凍結清單見架構體檢文件）。

過渡期間：既有通道（relay 檔、inbox 注入、FATQ comment、Mattermost、TG）照常使用，只是**不准生新的**。確有 W1 承接不了的緊急需求 → [ESCALATION] 給 anya 裁定，不得自行開通道。

## 政策二：Loop 準生證（即日生效）

新增任何 cron / watchdog / 掃描器 / 定時 loop **上線前**必須在 `shared/config/loop-registry.yml` 登記：
- `name`：loop 名
- `signal`：產出什麼訊號（檔案/relay/告警）
- `consumer`：誰消費這個訊號
- `overlap`：與清冊中哪些既有 loop 訊號重疊、為何仍需要
- `owner`：負責人（bot 或人）

**無清冊條目不得上線。** Reviewer 審到含新 loop 的 patch 時，先查清冊有無登記，無登記=REJECT（引用本政策）。

存量 loop 已自動種子登記（狀態 unverified），2026-08-01 月度 comprehension-debt 審查主題=全量盤點與合併。

## 執法

- Reviewer 池（Bella/一湯/KK）審查 checklist 加兩問：這個 patch 有沒有發明新通道？有沒有未登記的新 loop？
- anya 建單時對含通知/排程需求的 spec 主動標注政策符合性。
