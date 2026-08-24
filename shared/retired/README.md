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

**已知遺留**：當時仍存在的 mailbox-watch 腳本、fixture、unit 與 spec，已在
`mailbox-watch-subsystem-20260824.tar.gz` 這一筆整組退役。

## mailbox-watch-subsystem-20260824.tar.gz

| 項目 | 值 |
|---|---|
| 封存日期 | 2026-08-24 |
| sha256 | `02718f2e287671942cbbd7bdd31af01d27f2b9ed04635e58cc786238abb319ca` |
| 內容 | 8 entries：production checkout 腳本 2、fixture 1、舊 spec 1、user unit 1，以及 infra source 腳本 2、unit 1 |
| 原路徑 | tar 內保留從 `/` 起算的完整相對路徑；另將舊 spec 保存為 `shared/retired/mac-agent-comms.md` |

**這是什麼**：監看已刪除 `shared/mac-bridge/to-vps/` 信箱並轉成 relay 的 watcher、
health helper、systemd user unit、fixture 與舊通訊規格。Mac→VPS 現行保留通道直接寫入
`relay/`，由 pod-system gateway 消費，不依賴本子系統。

**封存前實測狀態**：

- 所有待刪路徑均先執行 `shared/bin/probe-pinned-files.sh`。watcher 同時被
  cancelled/be1e 與 done+closed/3882 的歷史 `verify_commands` 釘住；其餘待刪檔案
  `NOT_PINNED`。兩張舊單的 write-once probe 不修改，由本退休單明載 supersession。
- `systemctl --user is-active/is-enabled/show` 在執行 session 因無 DBUS，皆回
  `Failed to connect to bus: No medium found`。檔案系統查核顯示 unit 檔存在、
  `default.target.wants/` 沒有 mailbox-watch symlink；未執行服務重啟。
- 先建立封存，再解壓至 `/tmp/b4c1-mailbox-restore.NifqOE/`；八個原路徑逐項
  `diff -r` 均為空輸出、exit 0，確認還原一致後才製作刪除 patch。

**內容清點**：`tar -tzf mailbox-watch-subsystem-20260824.tar.gz | wc -l` → `8`。

**還原驗證方式**：先解壓到臨時目錄而非直接覆寫：

```bash
restore_dir="$(mktemp -d /tmp/mailbox-watch-restore.XXXXXX)"
tar -xzf shared/retired/mailbox-watch-subsystem-20260824.tar.gz -C "$restore_dir"
diff -r /home/oldrabbit/.claude-bots/shared/bin/mailbox-watch.sh \
  "$restore_dir/home/oldrabbit/.claude-bots/shared/bin/mailbox-watch.sh"
```

其餘七個 `tar -tzf` 所列路徑同樣逐項比較；全部通過後，若確需還原才由授權維護者
審閱內容並解壓至 `/`。封存包含 production 與 infra 的原始副本，因此還原前應先確認
目前版本與服務狀態，避免覆蓋後續變更。
