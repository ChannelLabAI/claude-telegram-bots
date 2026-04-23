# 自動化腳本總覽

> ChannelLab Bot 系統所有定時任務與自動化腳本。
> 最後更新：2026-04-14

---

## 系統 Crontab

| 排程 | 腳本 | 用途 |
|---|---|---|
| `*/15 * * * *` | `scripts/sync-closet-backfill.sh` | MemOcean Radar 增量補填（知識庫同步） |
| `*/5 * * * *` | `scripts/bot-watchdog.sh` | Bot 進程監控，崩潰自動重啟 |
| `0,30 9-20 * * *` | `scripts/heartbeat-ping.sh` | 每 30 分鐘 Ping 所有 Bot，保持 prompt cache |
| `13 * * * *` | `scripts/regenerate-team-l0.sh` | 每小時重生 `team-l0.md`（Bot 喚醒背景） |
| `17 * * * *` | `scripts/sync-ocean-bot-system.sh` | 鏡像 bots/ CLAUDE.md + blocks/ → Ocean |
| `20 * * * *` | `scripts/regen-reef-clsc.sh` | 把 radar DB 寫回 vault Reef .clsc.md 索引 |
| `37 9 * * *` | `scripts/inject-cards-lint.sh` | 每日 Cards 連結密度檢查 |
| `57 8 * * *` | `scripts/daily-briefing-trigger.sh morning` | 平日早報觸發（08:57） |
| `0 15 * * *` | `shared/scripts/tg-daily-ingest.sh` | 每日 TG 訊息入庫 MemOcean |
| `0 18 * * *` | `scripts/daily-briefing-trigger.sh evening` | 平日晚報觸發（18:00） |
| `0 18 * * *` | `shared/scripts/stale_knowledge_check.py` | 知識庫過期條目檢查 |
| `5 19 * * *` | `shared/scripts/daily_link_updater.py` | Dream Cycle 後更新每日連結 |
| `10 19 * * *` | `scripts/sync-github-docs.sh` | 同步 GitHub docs 到本地 |
| `0 19 * * *` | `shared/scripts/dream_cycle.py --mode=live` | 夜間知識整合（Dream Cycle） |
| `0 10 * * 5` | `scripts/pearl-draft-reminder.sh` | 每週五提醒審查 Pearl 草稿 |
| `0 2 * * *` | *(inline find)* | 清除 30 天前的已處理 inbox 檔案 |
| `0 3 * * *` | *(logrotate)* | inotify-watch log 輪轉 |

---

## Sync 類腳本（資料同步）

| 腳本 | 頻率 | 說明 |
|---|---|---|
| `sync-closet-backfill.sh` | 每 15 分鐘 | 讀 Ocean vault .md → 壓縮成 CLSC → 存進 radar DB |
| `regen-reef-clsc.sh` | 每小時 :20 | 把 radar DB 的摘要寫回 vault 各 Reef 的 .clsc.md 索引 |
| `sync-ocean-bot-system.sh` | 每小時 :17 | 鏡像 `.claude-bots/bots/` 結構（CLAUDE.md + blocks/）到 Ocean |
| `sync-github-docs.sh` | 每天 19:10 | 同步 GitHub repo docs 到本地 |

---

## 維運類腳本

| 腳本 | 頻率 | 說明 |
|---|---|---|
| `bot-watchdog.sh` | 每 5 分鐘 | 監控 bot 進程，崩潰自動重啟 |
| `heartbeat-ping.sh` | 每 30 分鐘（9-20h） | 在主團群 ping 所有 Bot，讓 prompt cache TTL 續命 |
| `regenerate-team-l0.sh` | 每小時 :13 | 重生 `shared/wakeup/team-l0.md`，供 Bot 啟動時載入 |
| `inject-cards-lint.sh` | 每天 09:37 | 檢查 Cards/ 筆記連結密度，推送 lint 結果 |
| `pearl-draft-reminder.sh` | 每週五 10:00 | 提醒審查 Pearl _drafts 候選清單 |

---

## 知識處理類腳本

| 腳本 | 頻率 | 說明 |
|---|---|---|
| `shared/scripts/dream_cycle.py` | 每天 19:00 | 夜間整合：三元組提取、Pearl 萃取、記憶鞏固 |
| `shared/scripts/stale_knowledge_check.py` | 每天 18:00 | 標記 memory.db 中過期的記憶條目 |
| `shared/scripts/tg-daily-ingest.sh` | 每天 15:00 | TG 對話紀錄入庫，建立可搜索的 FTS 索引 |
| `shared/scripts/daily_link_updater.py` | 每天 19:05 | Dream Cycle 後更新知識圖譜連結 |

---

## 一次性 / 手動腳本

| 腳本 | 說明 |
|---|---|
| `setup-fatq-dirs.sh` | 建立 FATQ 所有 tasks/ 子目錄（冪等，FATQ-002） |
| `snapshot.sh` | 手動備份 memory.db + kg.db |
| `snapshot-restore.sh` | 從備份還原 |

---

## 各 Bot 自建定時任務（Session 啟動時 CronCreate）

| Bot | 排程 | 用途 |
|---|---|---|
| 所有特助 | `57 8 * * 1-5` | 早上建立今日 Daily Note + 拉 Calendar + 送代辦通知 |
| 所有特助 | `3 18 * * 1-5` | 晚上補寫 Compiled Truth + 更新日誌總結 |

> 詳細 prompt 與規則見各 Bot 的 `blocks/block-daily-log.md`

---

## FATQ 目錄流程

```
pending → spec_review → design → design_review → in_progress → review → done
                                                                       ↘ rejected
```

| 目錄 | inotify 通知對象 |
|---|---|
| `pending` | assigned_to 對應 Bot |
| `spec_review` | Bella |
| `design` | 星星人（nicky-builder） |
| `design_review` | Bella |
| `review` | Bella |
| `rejected` | assigned_to 對應 Bot |
