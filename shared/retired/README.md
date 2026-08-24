# shared/retired/

已退役子系統的封存區。**這裡的東西沒有執行中的消費者**，只保留歷史紀錄。
每筆封存都要寫明：封存日期、封存前的實測狀態、以及「刪掉會不會影響運行」的答案。

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
