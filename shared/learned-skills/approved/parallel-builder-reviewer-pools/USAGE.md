# Usage: Parallel Builder/Reviewer Pools (v2)

## Pool 檢查（每次派工前必跑）

### Step 1：掃 in_progress

```bash
ls ~/.claude-bots/tasks/in_progress/*.json
# 對每個檔案讀 assigned_to 欄位，統計每人手上幾單
```

### Step 2：判斷誰空

**Builder pool** (Anna / 三菜 / Eric)：
- 手上 0 單 → idle
- 多人都有單 → 看誰單少；一樣少 → 看 review/ 裡誰的比較少（快回流）

**Reviewer pool** (Bella / 一湯 / KKKK)：
- 同上規則

### Step 3：優先池過濾

在 idle 的人裡，先選派單老闆的**優先池**成員：

| 派單來源 | Builder 優先池 | Reviewer 優先池 |
|---|---|---|
| Ron / Panda | Eric | KKKK |
| 老兔 / Anya | Anna | Bella |
| 菜姐 / 主廚 | 三菜 | 一湯 |
| Nicky / 張凌赫 | Anna | Bella |
| 桃桃 / Elon | Anna / 三菜 | Bella / 一湯 |
| 跨線借調 | 特助協調群排隊 | 特助協調群排隊 |

優先池沒有 idle → 借調其他池，但要在群組標記「借調」。

### Step 4：派任務

把 `assigned_to` 設成最終選定的 bot。寫 task JSON 進 `~/.claude-bots/tasks/pending/`，然後在對應群組 @ 通知。

**Builder → Reviewer 預設配對**（task JSON 的 `reviewer` 欄位）：
- Anna → Bella
- 三菜 → 一湯
- Eric → KKKK

可以交叉，但預設先按上面，避免混亂。

## 例外情境

### 指定收件人
老闆說「叫 Anna 做」「給 Bella 審」→ **照做**，不套 pool。Pool 化是預設，不是強制。

### 連續性優先
任務 reject 後要重做 → **保持原 Builder/Reviewer 配對**，換人會丟上下文。

### 全 pool 都忙
三個 Builder 都有單 → 
1. 急件 → 派給單最少的，標記「插單，原任務延後」
2. 不急 → 進 pending/ 排隊

### 跨組借調
需要借調其他優先池的 bot → 先在特助協調群 (-5175060310) 說一聲，對方特助確認可借才派。

## 檢查清單

- [ ] 已掃 `tasks/in_progress/` 確認 Builder pool 狀態（Anna/三菜/Eric）
- [ ] 已掃 `tasks/in_progress/` 確認 Reviewer pool 狀態（Bella/一湯/KKKK）
- [ ] 確認派單老闆，套用優先池規則
- [ ] 沒有反射性派給 Anna/Bella
- [ ] 確認非「指定收件人」情境
- [ ] 確認非「連續性優先」情境（reject 重做）
- [ ] 任務 JSON 寫入 pending/，assigned_to 是最終選定 bot
- [ ] 群組 @ 通知對應 bot

## 不要做的事

- 不要憑印象判斷誰閒——**一定要掃磁碟**
- 不要為了「公平」強制輪流——以 idle 為唯一準則
- 不要在沒掃 pool 的情況下說「Anna 來做這個」
- 不要跨組借調不說一聲——走特助協調群
- 不要把 pool 規則凌駕老闆指定——老闆的指定永遠優先
