# Usage: Parallel Builder/Reviewer Pools

## Pool 檢查（每次派工前必跑）

### Step 1：掃 in_progress

```
ls ~/.claude-bots/tasks/in_progress/*.json
```

對每個檔案讀 `assigned_to` 欄位，統計每個 Builder/Reviewer 手上有幾單。

### Step 2：判斷誰空

**Builder pool**：
- Anna 手上 0 單 → idle
- 三菜手上 0 單 → idle
- 兩個都有單 → 看誰單少；都一樣 → 看 review/ 裡誰的比較少（因為快回流了）

**Reviewer pool**：
- Bella 手上 0 單 → idle
- 一湯手上 0 單 → idle
- 同上規則

### Step 3：派任務

把 `assigned_to` 設成 idle 的那一位。寫 task JSON 進 `~/.claude-bots/tasks/pending/`，然後在主團隊群組 @ 對應 bot 通知。

**Builder 的 reviewer 預設配對**（如果任務 JSON 需要寫 `reviewer` 欄位）：
- Anna → Bella
- 三菜 → 一湯

可以交叉，但預設先按上面配，避免混亂。

## 例外情境

### 指定收件人

老兔/Ron/Nicky 等老闆說「叫 Anna 做」「給 Bella 審」→ **照做**，不要硬套 pool。Pool 化是預設行為，不是強制。

### 連續性優先

如果一個任務 reject 後要重做，**保持原 Builder/Reviewer 配對**，不要重新分配——換人會丟失上下文。

### 全 pool 都忙

兩個 Builder 都有單 → 選擇：
1. 急件 → 派給單少的，並在群組標記「插單，原任務延後」
2. 不急 → 進 pending/ 排隊，先派 `assigned_to` 但 bot 不會立刻動

### 跨組任務

如果任務需要兩個 Builder 並行（罕見），可以拆成兩單分別派 Anna 跟三菜，但要在 task JSON 裡標 `parallel_with: {另一單的 id}`。

## 檢查清單

- [ ] 已掃 `tasks/in_progress/` 確認 Builder pool 狀態
- [ ] 已掃 `tasks/in_progress/` 確認 Reviewer pool 狀態
- [ ] 沒有反射性派給 Anna/Bella
- [ ] 確認非「指定收件人」情境
- [ ] 確認非「連續性優先」情境（reject 重做）
- [ ] 任務 JSON 寫入 pending/，assigned_to 是 idle 那位
- [ ] 群組 @ 通知對應 bot

## 不要做的事

- 不要憑印象判斷誰閒——印象通常是錯的，**一定要掃磁碟**
- 不要為了「公平」強制輪流——以 idle 為唯一準則，idle 的拿單
- 不要在沒掃 pool 的情況下說「Anna 來做這個」（這是最常犯的錯）
- 不要把 pool 規則寫死讓老兔不能 override——老兔的指定永遠優先
