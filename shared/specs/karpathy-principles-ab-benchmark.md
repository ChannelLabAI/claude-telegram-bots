# Karpathy Principles A/B Benchmark

> 目的：比較 Anna 在應用 Karpathy Coding Principles 前後的時間效率和 token 消耗。
> 建立日期：2026-04-14
> 相關：[[MemOcean]]

---

## Before（應用前）— Karpathy Principles 安裝前啟動的任務

| Task | 類型 | 開始時間 | 完成時間 | 耗時 | Token 消耗 | Bella K1-K4 評估 |
|---|---|---|---|---|---|---|
| CHL-001 v1.1 (單頁改版) | Frontend dev | 09:26 UTC | 10:07 UTC | ~41 min total (feat 8min + fix 7.3min) | 158,368 tokens / 113 tool_uses (兩輪合計) | K1⚠️ K2⚠️ K3⚠️ K4✅ — R1 REJECT → R2 APPROVE |
| MEMO-003 (messages 向量化) | Backend dev | 09:26 UTC | 10:14 UTC | ~44 min | 60,230 tokens / 56 tool_uses | K1⚠️ K2✅ K3✅(輕微) K4✅ — R1 REJECT → R2 APPROVE |

**注意：** 這兩個任務的 Bella review 將包含 K1-K4 baseline 評估，結果填入上表。

---

## After（應用後）— 待填入

下次 Anna session 重啟後（Karpathy Principles 生效），選相似複雜度任務填入：

| Task | 類型 | 開始時間 | 完成時間 | 耗時 | Token 消耗 | Bella K1-K4 評估 |
|---|---|---|---|---|---|---|
| (待補) | | | | | | |

---

## 比較指標說明

- **時間效率**：任務開始到送 review 的時間
- **Token 消耗**：background agent 回報的 total_tokens
- **Bella K1-K4 評估**：每條 PASS/WARN/FAIL，違反點數量
- **退件率**：APPROVE vs REJECT 比例

---

## 假設

Karpathy Principles 主要作用在：
1. 減少「先動手後發現方向錯」的重工（節省時間）
2. 減少多餘功能/抽象帶來的 token 浪費（降低 token）
3. 減少 Bella REJECT 次數（提升品質）

---

*此文件由 Anya 建立，供老兔評估 Karpathy Principles 效果。*
