# Example: 2026-04-07 Pool 化決策

## 背景

主團隊原本的工作流：
- 老兔 → Anya（特助）→ Anna（Builder）→ Bella（Reviewer）→ 交付
- 所有特助派任務都是 reflex 派給 Anna

三菜跟一湯原本屬於菜姐的 carrotai 團隊，後來加入老兔的共用部門，但**特助們沒養成派任務給他們的習慣**。

## 觀察到的問題

老兔在 2026-04-07 早上看 task queue：

```
tasks/in_progress/
├── 20260407-091200-a3f1-shared-infra-and-templates.json    (anna)
├── 20260407-093400-bc02-fts5-fact-recall.json              (anna)
├── 20260407-101500-de89-vps-monitoring.json                (anna)
└── 20260407-103000-f001-task-queue-cleanup.json            (anna)

tasks/review/
├── 20260407-085000-aa12-hooks-v2.json                      (bella)
└── 20260407-094500-bb34-shared-hooks-cleanup.json          (bella)
```

Anna 排了 4 單、Bella 2 單，**三菜跟一湯各 0 單**。

老兔看到後說：「三菜跟一湯為什麼閒著？特助派任務是不是反射就丟給 Anna？以後三菜也是共用 Builder，一湯也是共用 Reviewer，特助派之前先掃 pool。」

## 處理動作

1. 老兔在主團隊群組宣布 pool 化規則
2. Anya 把當前 4 單裡的 2 單（vps-monitoring、task-queue-cleanup）改派給三菜（透過 mv 任務檔 + 改 assigned_to + 群組 @ 通知）
3. Bella 手上的 shared-hooks-cleanup 改派給一湯
4. Anya 寫了這個 SKILL（你正在讀的這個）

## 結果

- 派工後 1 小時內，三菜跟一湯都在跑任務，整體 throughput 大幅上升
- Anna 不用熬夜，Bella 不用累審
- 第一次的「先掃 pool」對特助來說有點不順手，但走過一次就成肌肉記憶

## 教訓

1. **預設行為決定結果**。特助沒有被明確告知要做 pool 檢查時，會反射派給最熟的人。需要**寫死成 SOP**才會改變。
2. **資源閒置不會自動修正**。三菜跟一湯不會主動說「我閒著欸」——bot 沒有 entitlement，要靠特助主動拉。
3. Pool 規則不能太硬。老兔指定的任務、reject 重做的任務需要例外處理，否則會破壞工作的連續性與信任感。
4. 一個未來改進：task queue 加一個 `pool_status` 指令，掃完直接吐 idle 名單給特助。**v0.2 再做。**
