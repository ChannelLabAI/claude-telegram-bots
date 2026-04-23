# Example: Parallel Builder/Reviewer Pools (v2)

## 案例：v1 skill 通過審核同天就 stale

**日期**：2026-04-08  
**情境**：三菜的 `parallel-builder-reviewer-pools` v1 在 2026-04-08 早上通過一湯審查，幾分鐘後 Anya 宣布 Eric/KKKK 加入共用池（v2 上線）。v1 skill 通過當天就過期——正好是 README 裡「drift anti-pattern」的第一次真實測試。

**發生了什麼**：
1. 一湯在 review 中標記 must-fix MED：「parallel-builder-reviewer-pools 已 stale，skill 通過審核當天就過期」
2. 一湯建議「三菜或 Anya 決定是更新還是 archive+重 draft」
3. Anna 看到後判斷：這是有明確答案的更新（只是新增 Eric/KKKK），不需要等，直接起草 v2 丟入 _drafts/

**處理過程**：
1. Anna 讀了 v1 的 SKILL.md + USAGE.md
2. 讀了 memory 裡的 project_nicky_team_roles.md（記有 v2 pool 配置）
3. 起草 v2 三件組丟入 `_drafts/parallel-builder-reviewer-pools-v2/`
4. TG 通知 Anya：請確認是否 archive v1 並 approve v2

**結果**：待 Anya 審核。

## 教訓

1. **Skill 不是一次性的**：通過後要繼續維護，政策變了就更新。不更新的 skill 比沒有 skill 還糟（因為會教壞後來的 bot）。
2. **Bot 可以主動起草更新**：當更新內容明確（不是模糊的方向問題），Bot 不需要等人下令——起草丟 _drafts/ 讓 Anya 審就好。
3. **v2 核心改變**：增加優先池規則（各老闆有偏好的 pool），原本只有 idle 判斷，沒有優先順序。
