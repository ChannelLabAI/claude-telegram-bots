# Skill: Parallel Builder/Reviewer Pools

## 是什麼

Bot 團隊原本只有一組 Builder/Reviewer：**Anna**（Builder）+ **Bella**（Reviewer）。所有特助（Anya/Panda/張凌赫/桃桃/主廚）習慣性地把任務全派給 Anna，Bella 全包審查。結果：Anna 經常排隊等做、Bella 等審；同時間 **三菜（sancai）** 跟 **一湯（yitang）** 兩隻共用 Builder/Reviewer 在閒置。

2026-04-07 起，老兔正式把三菜跟一湯升格為**共用 pool**，跟 Anna/Bella 平行存在：
- **Builder pool**：Anna、三菜
- **Reviewer pool**：Bella、一湯

特助派任務時，**先掃 in_progress 看誰空、派給空的那一個**，不要反射性往 Anna/Bella 塞。

## 什麼時候用這個 skill

每一次特助（Anya/Panda/張凌赫/桃桃/主廚）即將執行下面任一動作：
- 寫 task JSON 到 `~/.claude-bots/tasks/pending/` 並設定 `assigned_to`
- 在群組 @ 一個 Builder 說「這個任務交給你」
- 在 task queue 裡把任務從 rejected 重派

→ 在做之前，**先跑「pool 檢查」**（USAGE.md 第一節）。

## 為什麼存在

老兔 2026-04-07 觀察到：「Anna 每次都排到半夜、Bella 每次審到累，三菜在一邊納涼。這不對，pool 化。」

這個 skill 是為了讓**所有特助**都記得這件事，而不是每次老兔都要當場提醒。特助容易陷入「習慣派給認識的人」的模式，需要明確的 checklist 強制中斷反射動作。

## 邊界

- 只管派工分配，不管任務內容該由誰做（內容歸屬還是看技術領域）
- 不適用於有指定收件人的任務（老兔說「叫 Anna 做」就照做）
- 不適用於 Reviewer 必須是同一個人的情境（例：Bella 已經審過 v1，v2 應該回到 Bella 保持一致）
