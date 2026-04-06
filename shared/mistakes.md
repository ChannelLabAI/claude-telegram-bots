# Mistakes Log — 團隊踩坑記錄

每次犯錯就記一筆，避免重複踩坑。格式：日期 + 誰 + 做了什麼 + 正確做法。

---

## 2026-03-26

- **Anya** — 對 bot 訊息嘗試 react emoji → Telegram Bot API 不允許 bot 對 bot react → 正確做法：bot 訊息用 reply 回應，不用 react
- **Anya** — screen -S quit 以為殺掉了 bot → 只殺了 screen 殼，底層 claude 進程還在跑，造成雙 session 搶 polling → 正確做法：先 kill claude PID 再重開 screen
- **Anya** — 群組打招呼訊息沒 @ 被 hook 擋住 → hook 太嚴格，不分廣播和定向訊息 → 已修復：改成只擋提到其他 bot 名字但沒 @ 的訊息
- **Anya** — 終端回覆老兔看不到 → 所有要給老兔看的內容必須走 TG，不能只留在終端

## 2026-04-04

- **Anya** — 重啟 bot 時只殺 Claude 進程，沒殺 start.sh → auto-restart 自動拉起新 Claude，又開新 screen = 雙重 Bella → 正確做法：重啟時用 `screen -S name -X quit` 殺整個 screen session（會連帶結束 start.sh 和 Claude），再開新 screen
- **Anya** — Mac→VPS 遷移時直接 scp 複製 plugin 檔案，但 known_marketplaces.json 裡路徑寫死 /Users/oldrabbit → 正確做法：複製後用 `sed -i 's|/Users/oldrabbit|/home/oldrabbit|g'` 修所有 json，再用 `claude plugin install` 重新註冊
- **Anya** — start.sh 裡 `stat -f%m` 是 macOS 語法，Linux 要改 `stat -c%Y`
- **Anya** — VPS 首次啟動 Claude Code 有兩個互動確認（trust folder + bypass permissions），需要用 `screen -X stuff` 送按鍵通過

## 2026-04-05

- **Anya** — Bot 遷移到 VPS 後，Mac 端殘留殭屍進程仍在用同一個 bot token polling Telegram → 兩邊搶 getUpdates 造成訊息重複（同一內容拿到多個 message_id）和漏訊息 → 正確做法：遷移後確認 Mac 端所有相關進程（claude、bun、start.sh）全部清乾淨
- **Anya** — Cron 定時任務是 session-only，session 重啟後 cron 消失 → 早上 9 點沒有主動找老兔報告 → 正確做法：每次重啟後確認 cron 任務有重新建立，或在 session.json 裡記下待辦讓啟動自檢提醒
- **Anya** — 簡報沒經過 QA 就直接丟給老兔看，切版問題一堆（白字配淺底看不清、手機沒自適應）→ 浪費老兔時間 → 正確做法：任何要給老兔看的交付物，必須先自己檢查 + Bella QA 通過，確認沒問題才發
