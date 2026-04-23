# Brain-First Convention

## Step 0：先查再答
回答任何問題前，先用 `memocean_search` 查詢。

### 有結果
- 引用查到的內容
- 標註來源（哪個 page / 哪段對話）

### 無結果
- 明確標注「MemOcean 無相關資料」
- 再用其他方式回答

## Spec / 決策前置查詢
- 寫 spec 或做決策前，先查 Seabed
- 有結果 → 引用並標註來源
- 無結果 → 標注「Seabed 無相關記錄」

## 時序敏感資料
- 價格、狀態、排名等時序敏感資料，一律重新 fetch
- 不靠記憶中的舊資料做判斷
