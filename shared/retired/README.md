# shared/retired/

已退役子系統的封存區。**這裡的東西沒有執行中的消費者**，只保留歷史紀錄。
每筆封存都要寫明：封存日期、封存前的實測狀態、以及「刪掉會不會影響運行」的答案。

## relay-to-mac-20260824.tar.gz

| 項目 | 值 |
|---|---|
| 封存日期 | 2026-08-24（建立當日退役，存活 2 天）|
| sha256 | `594495d7ef0d50ac1f8f6ac8f9b69d32742f89d93c8b67057715bca4e788fbae` |
| 內容 | README 契約 + `archive/` 2 封（此通道生涯全部流量）|
| 原路徑 | `relay-to-mac/` |

**這是什麼**：VPS→Mac 的非同步出口，2026-08-22 建立（取代 mac-bridge 的 `to-mac/`），
Mac 端以 SessionStart hook 主動取信。

**為什麼刪**（老兔 2026-08-24 裁定，套用刪減原則）：

- **七週零需求**。VPS→Mac 這個方向在舊 mac-bridge 時期約 30 封，全部集中在
  2026-06-22 ~ 07-07 兩週內，之後掛零。
- **不增加能力**。mac-agent 本來就能 SSH 讀 VPS 任何檔案；這條通道加的只是
  「一個它會在 SessionStart 主動去看的位置」這個約定。
- **唯一流量是測試自己**。封存的 2 封分別是端到端測試、以及本封退役通知。

**退役程序**（順序刻意如此，不是保守）：VPS 端無法修改 Mac 上的檔案，若先刪目錄，
Mac 的 hook 會在下次 SessionStart 撲空報錯，且同樣要等它下個 session 才修得掉——
**兩條路延遲相同，先通知只是少了中間那段壞掉的狀態**。故：先投退役通知 → mac-agent
移除 hook 並回報（它另向老兔本人口頭核實授權才動手）→ 才刪除。

**保留的方向**：Mac→VPS 不動，繼續寫 `relay/` 由 pod-system gateway 常駐消費。
該方向有 61 封實績需求，且新設計修掉了真正的病灶（舊 `to-vps/` 61 封只有約 3 封被讀過）。
2026-08-24 端到端實測往返 4m02s。

**封存前實測**：`probe-pinned-files.sh relay-to-mac` → `NOT_PINNED`；pending 0、archive 2；
解壓後 `diff -r` 與原目錄完全一致才刪除。

## mac-bridge-20260824.tar.gz

| 項目 | 值 |
|---|---|
| 封存日期 | 2026-08-24 |
| sha256 | `624d77824ca965b51635a732adcfff8e5ba11259386ab2a13f61616e241d3397` |
| 內容 | 143 entries — `to-vps/` 61、`archive/` 31、`to-mac/` 1、`.mailbox-watch-state/` |
| 原路徑 | `shared/mac-bridge/`（未進版控，564K）|

**這是什麼**：2026-06-22 建立的 Mac↔VPS 檔案信箱，2026-08-20 退役（見包內
`RETIRED.md`）。現行雙向路徑是 Mac→VPS 寫 `relay/`（pod-system gateway 常駐消費）。

**封存前的實測狀態**：

- `probe-pinned-files.sh shared/mac-bridge` → `NOT_PINNED`
- `mailbox-watch.service` → unit file 不存在、`inactive`（無執行中消費者）
- `shared/bin/fatq-cli.sh:3630` 對 mac-bridge 的引用**只是註解**引述一則歷史裁決，非程式相依
- 未進版控（`git ls-files` 為 0），故以 tar.gz 保存而非靠 git 歷史

**還原驗證**：解壓到 `/tmp` 後對原目錄跑 `diff -r`，**完全一致**，之後才刪除原目錄。

**為什麼退役**：61 封 Mac 寫給 VPS 的信裡，只有約 3 封被讀過——問題不是通道壞了，
是**沒有人在收**。新設計把 Mac→VPS 導進 `relay/`，由常駐 gateway 消費；2026-08-24
端到端實測往返 4m02s。老兔裁定：先前已掃過內容，直接封存不重掃。

**已知遺留**：`shared/bin/mailbox-watch.sh`、`mailbox-watch-health.sh`（兩者已進版控）、
`shared/bin/mac-bridge`、`shared/tests/mailbox-watch-fixture.sh` 仍指向已不存在的
`shared/mac-bridge/to-vps`。**沒有執行者所以不會壞**，但屬於同一個退役範圍尚未收乾淨的部分，
另行處理，不在本次範圍內。
