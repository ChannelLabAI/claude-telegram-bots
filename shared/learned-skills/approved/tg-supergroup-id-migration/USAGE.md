# Usage: TG Supergroup ID Migration

## 前置確認

在動手之前，先確認你真的遇到的是這個問題，而不是其他原因：

- [ ] log 裡確實有 `chat not found` 或 HTTP 400 來自 sendMessage / sendChatAction
- [ ] 同一隻 bot 對**其他** chat_id（例如老兔 DM 1050312492）發訊息**正常**——排除 token 失效
- [ ] 該群組仍然存在（請老兔在手機上確認，不要自己猜）

三條都符合 → 繼續。

## 取得新 chat_id

兩種辦法，擇一：

**方法 A（推薦）**：請老兔在新群組裡 @ 你說一句話。等下次你的 telegram polling 收到 update，從 message 的 `chat.id` 直接抓到新 id。記下來。

**方法 B**：請老兔在群組設定裡看 invite link，從 link 反推。比較麻煩，A 行不通才用。

確認新 id 一定是 `-100` 開頭。如果不是，那不是 supergroup 升級問題，停下來重新診斷。

## 全域搜尋舊 id

需要更新的位置（**全部**都要改，少改一個就會繼續壞）：

```
~/.claude-bots/bots/CLAUDE.md                    # 共用團隊規則
~/.claude-bots/bots/{每個bot}/CLAUDE.md          # 各自的人設檔
~/.claude-bots/state/{每個bot}/session.json      # 各自的 session 狀態
~/.claude-bots/shared/                           # 任何 shared 設定
~/.claude-bots/scripts/                          # 啟動腳本、廣播腳本
~/.claude-bots/templates/                        # bot 模板（重要！否則新 bot 又會帶舊 id）
```

用 Grep 搜尋舊 id 字串。**逐一檢查每個 hit**，不要無腦 replace_all——有些是歷史紀錄、案例文件，那些不要動。

## 改完之後的驗證

1. 重啟所有受影響的 bot session（screen 視 setup 而定）
2. 每隻 bot 啟動自檢時應該能成功對新群組發喚醒訊息
3. 在群組裡 @ 一隻 bot 講話，確認它能收到 update 並 react
4. 對 `~/.claude-bots/shared/mistakes.md` 加一條「supergroup 升級會改 id」的提醒，避免下次又踩

## 檢查清單

- [ ] 確認是 chat not found 而非其他錯誤
- [ ] 從 update payload 拿到新 `-100xxx` chat_id
- [ ] grep 舊 id，逐個檢查是否該改
- [ ] 改 `bots/CLAUDE.md`
- [ ] 改每隻 bot 的 `bots/{bot}/CLAUDE.md`
- [ ] 改每隻 bot 的 `state/{bot}/session.json`
- [ ] 改 `templates/`
- [ ] 改 `scripts/` 裡的廣播腳本
- [ ] 重啟 bots
- [ ] 真實發訊驗證雙向（bot→group, group→bot）
- [ ] mistakes.md 加註記

## 不要做的事

- 不要直接 `sed -i` 全 repo 取代——會改到歷史 docs 跟 EXAMPLE 檔，污染知識庫
- 不要只改自己的 bot——其他 bot 不會自己發現
- 不要假設「下次重啟就好」——bot 不會自動取得新 id，必須人工 grep
