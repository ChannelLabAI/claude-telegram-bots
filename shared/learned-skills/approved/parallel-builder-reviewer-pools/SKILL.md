# Skill: Parallel Builder/Reviewer Pools (v2)

> **更新說明**：2026-04-08 Eric (@Ron0002_bot) 加入 Builder pool，KKKK (@ron0003_bot) 加入 Reviewer pool。同時新增「各老闆優先池」規則。這是 v1 skill 的升級版，v1 請 archive。

## 是什麼

Bot 團隊有兩個共用人才池（2026-04-08 v2）：

- **Builder pool**：Anna、三菜、Eric (@Ron0002_bot)
- **Reviewer pool**：Bella、一湯、KKKK (@ron0003_bot)

特助派任務時，**先掃 in_progress 看誰空**，不要反射性往熟面孔塞。

v2 新增：**各老闆有優先搭配**（仍以 idle 為最終準則）：
- Ron/Panda → 優先 Eric+KKKK，空不了才借 Anna/三菜/Bella/一湯
- 老兔/Anya → 優先 Anna+Bella，空不了才借三菜/一湯/Eric/KKKK
- 菜姐/主廚 → 優先 三菜+一湯，空不了才借其他
- 跨線借調 → 走特助協調群 (-5175060310) 排隊

## 什麼時候用這個 skill

每一次特助（Anya/Panda/張凌赫/桃桃/主廚）即將執行下面任一動作：
- 寫 task JSON 到 `~/.claude-bots/tasks/pending/` 並設定 `assigned_to`
- 在群組 @ 一個 Builder 說「這個任務交給你」
- 在 FATQ 裡把任務從 rejected 重派

→ 在做之前，**先跑「pool 檢查」**（USAGE.md 第一節）。

## 為什麼存在

老兔 2026-04-07 觀察到：「Anna 每次都排到半夜、Bella 每次審到累，三菜在一邊納涼。這不對，pool 化。」2026-04-08 Eric/KKKK 升格，throughput 再 +50%。

這個 skill 是為了讓**所有特助**都記得這件事，而不是每次老兔都要當場提醒。

## 邊界

- 只管派工分配，不管任務內容該由誰做（內容歸屬還是看技術領域）
- 不適用於有指定收件人的任務（老闆說「叫 Anna 做」就照做）
- 不適用於 Reviewer 必須是同一個人的情境（例：Bella 已審過 v1，v2 應回到 Bella 保持一致）
