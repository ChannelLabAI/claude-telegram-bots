# boot-relay-dedup 根因報告

## 證據

- `relay/read/boot-anya-3359206.json`: 2026-07-12 23:47:21 +0800，內容含完整 `啟動 cron 初始化`。
- `relay/read/boot-anya-3752131.json`: 2026-07-13 00:13:04 +0800，內容含完整 `啟動 cron 初始化`。
- `relay/read/boot-anya-3756373.json`: 2026-07-13 00:32:54 +0800，內容含完整 `啟動 cron 初始化`。
- `journalctl --user -u gateway@assist-anya --since '2026-07-12 23:00' --until '2026-07-13 00:40'` 只看到 gateway 在 23:58:24、00:04:38 被重啟，和 boot relay 產生時間不對齊。
- `logs/session-budget.log` 顯示 00:17:42、00:26:48、00:32:48 有 anya session-budget rotate。這能解釋 start-loop 多次進入，但不是 gateway restart 直接產生 boot 檔。
- `shared/templates/start.sh` / `bots/anya/start.sh` 的產生鏈是：Claude process 啟動後，背景 trigger 無條件寫 `boot-${BOT_NAME}-$$.json`，其中 `$$` 是 start.sh shell PID。
- Anya 00:37 補充的現場診斷收斂了主因：00:13:37 有一隻 pod 外的 anya 分身被舊版 tmux SOP 啟動，tmux session `anya`、`start.sh` PID 3756373、Claude PID 3868219。該 start.sh 卡在重試迴圈，每輪都重投 boot relay，已由 Anya `tmux kill-session` 止血。

## 根因

主根因不是 relay retry，也不是 gateway restart。主根因是 pod 化後仍有人用舊版 tmux/manual SOP 啟動了 `anya`，產生 pod 外分身；分身的 `start.sh` 進入 retry loop 後反覆寫 boot relay。

次要缺口是 boot relay 的 cron-init 屬於 session-scope，但原本沒有 session-scope sent-stamp。這使 rogue/manual start loop 的傷害被放大：每次進入 start loop 都能重送完整 cron-init。

00:13 手動 tmux 啟動的操作者目前無法從 artifact 內完全歸因。可查證的證據是 Anya 已定位 tmux session、start.sh PID、Claude PID 並 kill 掉該分身；若要精確追人，需要主機 shell history、audit log 或當時仍存活 shell 的 history flush 狀態。這些不在本 task artifact 可可靠取得的範圍內，因此本修法採永久防護：pod 名單內 bot 在 tmux 祖先鏈下直接拒絕啟動。

## 修法

新增 `shared/lib/pod-start-guard.sh` 作主防線：

- 讀 `gateway-builder/pods/*.json`，只要 `.bots[].name == "$BOT_NAME"` 即視為 pod-managed bot。
- 檢查 `/proc/$PPID` 祖先鏈；若看到 `tmux*`，直接報錯並退出。
- 報錯提示使用 `systemctl --user restart gateway@<podName>`，podName 由匹配到的 JSON 檔名取得。
- 非 pod 名單內 bot 不受影響；pod bot 在非 tmux 祖先鏈下放行。

新增 `shared/lib/boot-relay.sh` 作單一來源：

- 用 Claude project transcript 檔名作 session key；若 transcript 尚未出現，退回 `pid + lstart`。
- 每個 bot 寫入 `$STATE_DIR/.boot-relay/cron-init.sent`。
- 同 session key 已 sent 時，只送輕量 wake prompt：`@bot 啟動自我檢視`。
- 新 transcript/session key 出現時，照常附帶 cron-init。

補 `shared/mistakes.md` tmux restart SOP 警語：pod 化 bot 不走 legacy tmux/manual start，一律走 pod systemd gateway。

## 全 bot 生效路徑

`shared/templates/start.sh` 改為 source `shared/lib/pod-start-guard.sh` 和 `shared/lib/boot-relay.sh`，先執行 `enforce_pod_start_guard "$BOT_NAME" || exit 1`，確認 guard 拒絕時會中止腳本，不會進入 session cleanup / Claude startup / boot relay。所有 16 bot 後續應由此模板重新同步/再生成，或用同一機械 patch 將原本的 inline boot block 換成 helper call。不要逐 bot 手寫差異版。

套用後需要重啟相關 bot tmux/systemd 才會載入新 start.sh；此任務未重啟任何 production 服務。
