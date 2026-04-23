# Bella 審查指南：FATQ Spec 新欄位說明

> 本文件說明 FATQ spec 格式升級後，Bella 在審查時需注意的新欄位。
> 相關：[[FATQ]]

## 新欄位說明

### `context`（決策脈絡）

Anya 在建立任務時填入的對話背景：
- 老兔說了什麼、為什麼現在做這個
- 隱性期望（沒有寫在 goal 裡的潛在需求）
- 關鍵決策過程

**審 spec 時**：先讀 `context`，了解任務的真正來由，有助判斷 spec 是否符合老兔的原始意圖。

### `review_focus`（審核焦點）

Anya 已標記「最容易出問題的地方」和「成功標準的核心點」。

**使用方式**：
1. 進入 Step 2 spec review 或 Step 6 實作 review，**優先看 `review_focus`**
2. 確保這些焦點點都被你的審查覆蓋到
3. 如果 `review_focus` 描述的重點跟你審查後的判斷不一致，附上說明

### `fast_track`（快速通道）

boolean 欄位：

| 值 | 行為 |
|---|---|
| `false`（預設）| 正常走完 8 步流程（含 spec_review、design_review） |
| `true` | 跳過 Step 2（spec review）和 Step 4（design review），**Bella 只做 Step 6 最終 review** |

**fast_track: true 適用條件**（由 Anya 判斷）：
- Anna 預計 30 分鐘內完成的任務
- 純修復 / 純格式調整 / 無架構決策
- 已有完整 spec + Anna 有先例可循

**Bella 收到 fast_track 任務時**：等待 Anna 完成並提交 review/ 後，直接跑 `/qa` + `/review` 三通道審查，不需先做 spec 方向審查。

## 審查優先順序

1. 查看 `fast_track` → 決定走哪條流程
2. 閱讀 `context` → 了解決策背景
3. 閱讀 `review_focus` → 鎖定審查焦點
4. 對照 `acceptance_criteria` 逐條確認
5. 確認 `out_of_scope` 無越界
