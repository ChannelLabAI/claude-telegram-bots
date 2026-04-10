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
- **Anya** — Mac→VPS 遷移時直接 scp 複製 plugin 檔案，但 known_marketplaces.json 裡路徑寫死 /Users/oldrabbit → 正確做法：複製後用 `sed -i 's|/Users/oldrabbit|/home/oldrabbit|g'` 修所有 json，再用 `claude plugin install` 重新註冊
- **Anya** — start.sh 裡 `stat -f%m` 是 macOS 語法，Linux 要改 `stat -c%Y`
- **Anya** — VPS 首次啟動 Claude Code 有兩個互動確認（trust folder + bypass permissions），需要在 xfce4-terminal 手動通過；之後再用 tmux 或 xfce4-terminal 正常啟動

## 2026-04-05

- **Anya** — Bot 遷移到 VPS 後，Mac 端殘留殭屍進程仍在用同一個 bot token polling Telegram → 兩邊搶 getUpdates 造成訊息重複（同一內容拿到多個 message_id）和漏訊息 → 正確做法：遷移後確認 Mac 端所有相關進程（claude、bun、start.sh）全部清乾淨
- **Anya** — Cron 定時任務是 session-only，session 重啟後 cron 消失 → 早上 9 點沒有主動找老兔報告 → 正確做法：每次重啟後確認 cron 任務有重新建立，或在 session.json 裡記下待辦讓啟動自檢提醒
- **Anya** — 簡報沒經過 QA 就直接丟給老兔看，切版問題一堆（白字配淺底看不清、手機沒自適應）→ 浪費老兔時間 → 正確做法：任何要給老兔看的交付物，必須先自己檢查 + Bella QA 通過，確認沒問題才發

## 2026-04-08 — CLSC 三輪 kill 教訓

設計 token 壓縮前必檢查兩條：
1. **壓縮後 token 長度 ≥ entity 長度** → 直接 fail，不用跑 benchmark（CLSC v0.3 fatal：`@anna` 5 字 > `anna` 4 字）
2. **entity 在真實 corpus 的 density** → 如果 < 5% 字典壓縮 surface area 不夠，gzip 自然語言處理已經贏（CLSC v0.3 setC/D：1.2-1.3% density 不夠）

「**測試 corpus 反映真實使用場景嗎**」這條一樣有效（這是 v0.2 的教訓），但 v0.3 又疊加一個物理層教訓。

## 2026-04-08 — AOT-001 搶票腳本 selector 翻車

**結果：** <OWNER_NAME>朋友手動搶贏腳本。場次 selector 5 次 retry 全失敗，最後<OWNER_NAME>手動接手 chrome for testing。

**Root cause：用結構性 selector 猜真實 DOM。**

`pickSession` 用 `tr.locator('button, a').first()` 抓「該列第一個可點元素」。但年代售票每場次列裡同時有 `id=PLACE_ADDRESS target=GoogleMap` 的地址連結，position 0 是它，**不是訂購按鈕**。dry run 時按鈕還沒 active 看不出來，正式跑就翻車。

### 鐵律（搶票/任何沒法 rehearsal 的腳本通用）

1. **沒有真實開賣後 DOM 不要寫結構性 selector。** `nth(0)`, `first()`, `tr > a` 這類「猜順序」的寫法是地雷。
2. **要用文字內容 selector + 屬性過濾**，不靠位置：
   - ✅ `tr:has-text("19:30") button:has-text("立即訂購")`
   - ✅ `tr:has-text("19:30") a[onclick*="UTK02"]`（年代訂購連結特徵）
   - ❌ `tr.locator('button, a').first()`
3. **每個關鍵動作至少 3 條 fallback selector**，前後綴 + 屬性 + 文字 + 結構多維命中。
4. **selector 要排除已知干擾**：地址連結、客服按鈕、Google Map、社群分享。寫成黑名單 filter。
5. **同站任何已開賣商品都該爬一遍真實 DOM**，存 reference HTML 給後人對照。沒爬不要動工。
6. **dry run 失敗 ≠ 「未開賣自然 fail」可以放過。** 至少要驗證 selector 邏輯本身能匹配靜態元素（地址行、頁腳連結之類）。靜態能命中 → 動態才有信心。
7. **腳本必須附「手動 backup 步驟卡片」** 跟啟動指令一起交付。使用者 5 秒能切手動。
8. **開賣前一晚交付，不是當天早上。** 留 buffer 給 dry run + 熟悉 + hot patch。
9. **開賣前 30 分主廚/特助強制 sanity check** — 不是逐項問，是真的跑一次靜態 selector 命中測試。

**主要教訓一句話：** 搶票腳本最大的敵人不是時鐘也不是風控，是「**你以為的 DOM 跟實際的 DOM 不一樣**」。靜態 fallback 比結構猜測值錢 100 倍。

### Reviewer 流程改進（一湯複審補充）

一湯 v1 review 抓到 `pickPrice` fallback 太寬要求 scope 容器，但**沒同時要求 `pickSession` 加同等級容器 scope** — `tr.first()` 結構性猜測過審了。漏審。流程修補：

1. **新增 review 第六維「DOM 假設驗證」**（補進 yitang/CLAUDE.md Five-Dimension → Six-Dimension）
   - 任何沒實際看過真站 DOM 的 selector → 一律標 **HIGH risk must-fix**
   - 三選一才能放行：(a) 同站歷史商品爬證據 (b) hybrid mode 留人工 fallback (c) fail-safe 找不到停 N 秒等人點

2. **Selector 強度三層 ranking**（寫進 review checklist）：
   - **Tier 1 文字 anchor**（`getByText` + `role`，`tr:has-text("19:30") a:has-text("立即訂購")`）— 主路徑必須走這層
   - **Tier 2 屬性 anchor**（`name=`/`id=`/`onclick*=`）— fallback 1
   - **Tier 3 結構 anchor**（`nth-child`/`first()`）— **一律標紅，只能當最後 fallback；review 看到主路徑用 Tier 3 直接 REJECT**

3. **Builder 必交「DOM 假設清單」當交付物** — 列每個 selector 對應預期元素長相 + 證據來源（猜/爬/實測）。沒這份 review 不放行。

4. **「手動 backup 卡片」列為硬交付物** — 跟腳本同 commit，不附 → REJECT。

5. **「無 rehearsal 腳本」標籤** — 任何沒法 dry run 真正路徑的腳本（搶票、競標、限時搶購）review 時自動套上面 4 條，不靠 reviewer 記性。

6. **配合主廚的 process gate（主廚 2026-04-08 加碼）** — 主廚派任務時 task spec 直接寫「reference DOM snapshot 必填」，不等 builder 寫完才被 reviewer 擋。Builder 動工前先交 snapshot，reviewer 拿 snapshot 對 selector 才開始 review。

**Reviewer 一湯這次的具體錯**：走完 5 維抓到一堆 nit 但沒把「結構性 selector + 無真實 DOM」當 blocker。下次見到 `nth/first/tr > a` 沒文字 anchor 直接 REJECT，不放過。

## 2026-04-08 — collective bias 寫法律：「老兔的 workflow ≠ 全公司 workflow」

今晚一個晚上踩 4 次：
1. CLSC sample bias（cherrypicked 7 段 cards 推理整套用法）
2. SSOT 假設（用「老兔工程腦」當全公司 baseline）
3. 待辦工具假設（推「老兔用 Notion」→ 結果他親口說從不開）
4. inbox 假設（同上，三個 bot 一起腦補）

**永久規則**：
1. user-level 紅線必須來自**老兔親口確認**，不能跨人推廣（<OWNER_NAME> / <OWNER_NAME> / <OWNER_NAME> 用什麼 ≠ 老兔用什麼）
2. 季度做「**最弱使用者 review**」（Elon 提）— 最弱使用者跟最強使用者都會移動
3. 設計 spec 時加一條檢查：「**這個假設是被驗證的還是被推論的？**」
4. test corpus 必須代表真實使用，**不要 cherrypick**（CLSC v0.1 → v0.3 教訓）

## 2026-04-08 — dm-block-executor.sh 安全漏洞記錄

**Blocker 1（已修）**: sancai/yitang 的 dm-block hook 放在 `settings.local.json`，而非 `settings.json`。`settings.local.json` 不受版本控制且優先級低，等同 hook 不存在。→ **永遠把 hook 寫進 `settings.json`，不用 `settings.local.json`**。

**Blocker 2（已修）**: `dm-block-executor.sh` 在 `chat_id` 解析失敗（malformed input）時 `exit 0`（fail-OPEN）。攻擊者可構造無效 JSON 繞過 DM 封鎖。→ **malformed input 一律 `exit 2`（fail-CLOSED）**，並寫 violation log。

**Blocker 3（已修）**: dm-block hook matcher 只覆蓋 `reply`，未覆蓋 `edit_message`。bot 可以用 `edit_message` 把已有群組訊息的文字改成 DM 目的內容繞過封鎖。→ **matcher 必須同時包含 `reply|edit_message`**。

**Blocker 4（已知限制，未修，需 team 知悉）**: Claude Code PreToolUse hook 只在主 session 中觸發。Sub-agent（`Agent` tool + `run_in_background`）在子 session 執行，**子 session 繼承 hook 設定但行為待驗證**。如果子 session 不觸發 PreToolUse hook，子 agent 就能 bypass dm-block。→ **緩解措施**：(1) 任務 spec 中明確禁止 sub-agent 直接呼叫 reply/edit_message 給人類；(2) 主 session 負責所有對外 TG 發言，sub-agent 只回傳結果；(3) 後續版本需實測確認子 session hook 觸發行為。
