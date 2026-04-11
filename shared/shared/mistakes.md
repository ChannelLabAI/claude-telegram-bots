# Mistakes Log — 團隊踩坑記錄

每次犯錯就記一筆，避免重複踩坑。格式：日期 + 誰 + 做了什麼 + 正確做法。

---

## 2026-03-26

- **Anya** — 對 bot 訊息嘗試 react emoji → Telegram Bot API 不允許 bot 對 bot react → 正確做法：bot 訊息用 reply 回應，不用 react
- **Anya** — screen -S quit 以為殺掉了 bot → 只殺了 screen 殼，底層 claude 進程還在跑，造成雙 session 搶 polling → 正確做法：改用 tmux，`tmux kill-session -t <name>` 才能確保 start.sh + claude 一起停
- **Anya** — 群組打招呼訊息沒 @ 被 hook 擋住 → hook 太嚴格，不分廣播和定向訊息 → 已修復：改成只擋提到其他 bot 名字但沒 @ 的訊息
- **Anya** — 終端回覆老兔看不到 → 所有要給老兔看的內容必須走 TG，不能只留在終端

## 2026-04-04

- **Anya** — 重啟 bot 時只殺 Claude 進程，沒殺 start.sh → auto-restart 自動拉起新 Claude，造成雙重 session → 正確做法：重啟時用 `tmux kill-session -t <name>`（連帶結束 start.sh 和 Claude），再開新 tmux session
