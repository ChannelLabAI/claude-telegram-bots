# Skill: TG Supergroup ID Migration

## 是什麼

當一個 Telegram 普通群組被升級成 supergroup（管理員在群設定裡開啟了 supergroup 功能、加了 username、開了 history visible，或人數突破門檻自動升級），群組的 `chat_id` **會改變**：
- 原本：`-{大正整數}`（例：`-5267778636`）
- 升級後：`-100{更大的正整數}`（例：`-1003634255226`）

舊 id 立刻失效。任何把舊 id 寫死在程式碼、CLAUDE.md、session.json 裡的 bot 都會瞬間「失聯」——它們以為自己還能發訊息到主群組，但 Telegram API 會回 `400 Bad Request: chat not found`，而 bot 通常不會主動發現這件事，因為「沒人理我」跟「大家剛好沒在說話」長得一樣。

## 什麼時候用這個 skill

觸發訊號（任一即可）：

1. Bot 啟動自檢時喚醒訊息送不出去，log 出現 `chat not found` / `Bad Request: chat not found` / HTTP 400
2. 老兔（或任何人）說「群組怎麼變安靜了」「你有收到我訊息嗎」但你 log 顯示沒收到任何 update
3. 你發現 `bots/CLAUDE.md` 或 `session.json` 裡的主群組 chat_id 是負的、且**不是** `-100` 開頭，而最近群組設定有變動
4. 主群組加了 username（可被搜尋）→ 幾乎確定升級了

## 為什麼存在

2026-04-07 主團隊群組從普通 group 升級成 supergroup，所有把 `-5267778636` 寫死的地方瞬間全壞。當下沒有 SOP，每隻 bot 都自己摸索，浪費了好幾個 session 的時間。這個 skill 把當天的處理流程固化下來，下次任何群組升級都能在 5 分鐘內處理完。

## 邊界

- 只處理 chat_id 變更。不處理 token rotation、bot 被踢、API rate limit。
- 只處理「升級成 supergroup」這個方向。supergroup 不會降級回 group，所以反方向不存在。
- 不處理 DM（個人聊天的 chat_id 永遠不變）。
