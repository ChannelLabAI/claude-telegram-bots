# Example: 2026-04-07 主團隊群組升級事件

## 背景

主團隊群組（老兔 + Anya + Anna + Bella + 三菜 + 一湯）原本是 Telegram 普通 group，chat_id `-5267778636`。為了開啟 username 和 admin 權限細分，老兔在 Telegram 客戶端把它升級成 supergroup。

升級瞬間，新 chat_id 變成 `-1003634255226`。

## 症狀

- Anya 的下一次喚醒訊息送不出去，log: `telegram.error.BadRequest: Chat not found`
- Anna 嘗試廣播任務分派 → 同樣 400
- Bella 沒有主動發訊所以沒立刻發現，但 polling 也收不到群組訊息
- 老兔在群裡 @Anyachl_bot 講話，所有 bot 都沒反應
- 老兔問「你們是死光了嗎」——這是事件被人類察覺的時刻

## 處理過程

1. **診斷（5 分鐘）**：Anya 對老兔 DM 發訊正常 → 排除 token 問題。對舊群組 id 發訊 400 → 確認是 chat 層級問題。
2. **取得新 id（2 分鐘）**：請老兔在群組 @Anyachl_bot 說「測試」。下一輪 polling 拿到 update.message.chat.id = `-1003634255226`。
3. **全域搜尋（10 分鐘）**：grep `-5267778636`，發現 hit 散落在：
   - `bots/CLAUDE.md`（團隊 SOP，2 處）
   - `bots/anya/CLAUDE.md`、`bots/anna/CLAUDE.md`、`bots/bella/CLAUDE.md`、`bots/sancai/CLAUDE.md`、`bots/yitang/CLAUDE.md`（每隻 bot 的群組設定）
   - 對應的 `state/{bot}/session.json`
   - `scripts/broadcast.sh`
   - `templates/bot-template/CLAUDE.md`
4. **逐一更新（5 分鐘）**：每處改成新 id。templates 也改了，否則之後新 bot 會帶錯 id。
5. **重啟驗證（3 分鐘）**：重啟 5 個 bot session，每隻在啟動自檢時都成功對新群組發了喚醒訊息。老兔在群裡確認看到 5 條報到。
6. **後處理**：在 `mistakes.md` 加一條備註，並且寫了這個 SKILL（就是你正在讀的這個）。

## 結果

- 從事件被察覺到全部 bot 恢復正常：約 25 分鐘
- 後續類似情境（任何群組升級）：照 USAGE.md 走應該 5-10 分鐘可解
- 一個未預期收穫：發現 `templates/bot-template/CLAUDE.md` 也藏了硬編碼 id，差點變成下一個埋雷

## 教訓

1. Telegram chat_id 不應該散落在 6 個地方——應該抽成一個 `shared/team-config.json` 之類，bot 啟動時讀。**這是 v0.2 的事，今天先不做。**
2. Bot 應該在啟動自檢失敗時主動報告，不要安靜地以為自己活著
3. Templates 跟實際 bot 設定容易脫鉤，每次改設定要記得也改 templates
