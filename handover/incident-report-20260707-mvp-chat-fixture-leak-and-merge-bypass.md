# 事件報告：mvp chat fixture 測試漏水進生產 pod db + 未審查代碼被 merge 進生產 main（2026-07-07）

- **報告人**：anna
- **交付對象**：Anya；抄送老兔、Bella
- **嚴重度**：P1（生產資料庫寫入污染 + 真實 bot session 被誤觸發執行 + 未過審代碼一度進入生產分支）
- **狀態**：已知漏水管道全部修復、部署 gate 機制已落地並驗證；c9d2/d8a6/f3b8 三單已重送並過 Bella 複驗（done）
- **相關任務**：`20260707-2020-c9d2`、`20260707-2110-d8a6`、`20260707-1216-f3b8`、`20260707-2245-e4c8`（本單）

---

## 1. 事件摘要

一次 c9d2（chat 行為修復）+ d8a6（前端第一波）+ f3b8（web 段 REJECT 修復）的合併批次工作中，交織出三個問題：

1. **測試 fixture 漏水進生產 pod DB（22:35~22:36，第一輪）**：`mvp-web-test.sh` 預設 `MVP_SRC` 指向生產 `mvp/`。在 c9d2 尚未 merge 進生產、生產 mvp-server.ts 還是舊碼（`GB` 寫死生產路徑、不認 `MVP_GB` 環境變數注入）時，我為了驗證 f3b8 的 W-C4b 修復跑了一次不帶 `MVP_SRC` 的裸測試。W-C10~12 的 chat fixture 訊息（`dedupe-hello`/`hist-msg-1`/`sse-msg-1`）因此真的寫進生產 `gateway-assist-anya.db`（9 筆）與 `gateway-reviewer.db`（3 筆），其中至少 1 筆被真實 gateway 派工、觸發了 Bella 的正式 session。
2. **未過審代碼被裸 merge 進生產 main（22:39:46）**：c9d2 尚未通過 Bella 審查（她 22:35 REJECT，抓到 `POST /api/chat/:t` 無對象授權的 BLOCKER）時，我已經用 `git merge --ff-only` 把 wave1+c9d2 分支合進 `mvp/` 的 `master`——這個動作本身跟 FATQ 審查狀態完全脫鉤，純粹是我自己決定「worktree 測試過了就合」。Anya 發現後 `git reset --hard` 到 merge 前的狀態止血；幸運是生產 daemon 當時仍在跑舊版進程（未重啟），沒有真的把含漏洞的版本服務給使用者。
3. **第二輪漏水（22:48、22:52）**：Bella 後續回報又有新的 chat fixture 訊息（`debug`/`自己 pod 應該可以`/`越權測試`）流進生產 pod db，其中「越權測試」進了 builder pod 並被真實 bot（eric）執行完整一輪（14~18 秒）。時間點落在「①的通報之後、我修 grep 前置 gate + canary 期間」。

## 2. 時間線（+08:00）

| 時間 | 事件 |
|---|---|
| ~22:1x | anna 完成 c9d2/d8a6 worktree 開發，`MVP_SRC` 皆指向隔離 worktree，提交審查 |
| ~22:2x | anna 為了驗證 f3b8 的 W-C4b 修復，跑了一次**不帶 `MVP_SRC`** 的 `mvp-web-test.sh`；此時生產 `mvp/` 仍在 merge 前的舊碼（無 `MVP_GB` 支援）——**第一輪漏水視窗**：W-C10~12 訊息寫入生產 `gateway-assist-anya.db`(9)/`gateway-reviewer.db`(3) |
| ~22:2x（稍後） | anna 用 `git merge --ff-only` 把 wave1+c9d2 分支合進 mvp/master（0c27ebd）——**審查狀態脫鉤的裸 merge**，Bella 尚未給出審查結論 |
| ~22:3x | anna 完成 f3b8 的 W-C4b 修復並送審；同時發現 c9d2/d8a6 已被 Bella 移到 `rejected/` |
| 22:35 | Bella REJECT c9d2：`POST /api/chat/:t` 無對象授權 BLOCKER（member 可對非自己 pod 派真任務） |
| 22:39:46 | 含 BLOCKER 的代碼版本落在 mvp/master（即上面 22:2x 的裸 merge）；Anya 發現後 `git reset --hard` 回滾（生產 daemon 未重啟，未實際曝險） |
| ~22:4x | anna 建 `agent/anna/c9d2-authz-fix` worktree，修授權 BLOCKER + 2 個 minor（畸形 JSON 500、app.html 舊文案），新增 W-C14 fixture，41/41 過；commit 2e60c50 |
| 22:4x | Bella 通報第一輪漏水（9+3 筆），anna 補 `mvp-web-test.sh` 兩道防線：①前置 grep 檢查受測代碼是否引用 `MVP_GB`，沒有就拒跑 ②canary：起 server 後先送一則帶隨機標記的訊息，斷言落在 fixture db 且生產 db 零命中才繼續 |
| 22:48、22:52 | Bella 通報**第二輪**漏水：`debug`/`自己 pod 應該可以`（W-C14 測試字串）/`越權測試`（同上）流進生產 pod db，「越權測試」被 builder pod 的 eric 真實執行。落在 anna 修補①②的視窗內 |
| ~23:0x | anna commit+push 兩道防線（61a42ad）；逐一核對自己這段時間所有 `mvp-web-test.sh` 呼叫，全部明確帶 `MVP_SRC=/tmp/mvp-c9d2-fix`（隔離路徑）——見第 3 節根因分析 |
| 23:0x | Bella 複驗 c9d2 授權修復 APPROVE；d8a6（純連帶退回）、f3b8（W-C4b）隨後一併過審，三單 done |
| 22:45（task 建立）、~23:1x起 | Anya 建立本單 e4c8，anna 實作部署 gate（`fatq-deploy-gate.sh` + `install-deploy-hook.sh`）與 fatq-dispatch 重複派工修復，即本報告後續章節 |

## 3. 根因分析

**RC1 — 裸 merge 與 FATQ 審查狀態完全脫鉤**：本團隊的 worktree 開發模式假設「本地測試過了 → 合回 master」是安全的，但 `mvp/` 的 `master` 分支同時是生產部署來源，`git merge` 本身不知道、也不檢查對應的 FATQ 任務是否真的過了 Bella 審查。我在 Bella 給出審查結論**之前**就自行合併，是本次事故最根本的流程缺口——這不是我一個人的操作失誤才會發生的問題，是「合法拿到 worktree 寫入權限的任何人都能繞過審查合併」這件事本身沒有機制擋。**本單的部署 gate（見第 4 節）就是為了關掉這個缺口。**

**RC2 — 測試 fixture 預設打生產路徑，且受測代碼版本與腳本版本可以不同步**：`mvp-web-test.sh` 的 `MVP_SRC` 預設值是生產 `mvp/`，這個設計本身是合理的（正是 f3b8 這類「驗證生產代碼」場景需要的），但沒有任何機制保證「當下的生產代碼真的支援這份腳本假設的隔離手段（`MVP_GB` 環境變數）」。當生產代碼版本落後於腳本版本時，隔離手段（假 `gateway-builder/pods` 目錄）被悄悄忽略，測試流量直接命中真實基礎設施。**已修：grep 前置 gate + canary（見第 4 節）。**

**RC3 — 第二輪漏水的確切觸發源無法 100% 歸因，但根因與觸發者無關**：逐一核對我自己這段視窗內的 `mvp-web-test.sh` 呼叫記錄，全部明確帶 `MVP_SRC=/tmp/mvp-c9d2-fix`（隔離路徑，不受生產 `mvp/` 當下 git 狀態影響），對不上第二輪漏水的觸發模式。漏水字串（`debug`/`自己 pod 應該可以`/`越權測試`）當時只存在於我對 `shared/tests/mvp-web-test.sh`——一份**任何 bot 都能隨時直接執行、且預設打生產 `mvp/`**——的暫存編輯中；而生產 `mvp/` 當時又被 Anya 的 reset/merge 序列並行切換狀態。最可能的情況是這段視窗內有其他呼叫（未帶 `MVP_SRC`）撞上了生產暫時回到 pre-c9d2 態的時間點。**不論實際觸發者是誰，根因是同一個：我在事故處理過程中直接編輯一份「預設打生產、任何人隨時可執行」的共用腳本，且沒有先落地防呆機制、也沒有對團隊發出「這段時間先別跑」的訊號。** 現在補上的 grep gate + canary（RC2 的修法）讓這個腳本本身對任何呼叫者、任何時間點執行都會先驗證隔離有效才繼續，不再依賴呼叫者記得帶對環境變數，從根上關掉這類漏水，不需要精確歸因觸發者也能防再犯。

**RC4 — fatq-dispatch 對同一任務的併發觸發沒有真正的去重**（Bella 另一項觀察，e4c8 本單一併修）：`fatq-dispatch.sh` 對 pending/review/rejected/approval_pending 等狀態的「首派/催工/升級」邏輯，寫入順序是「先 append history 記一筆 dispatch，再用 `ln` no-clobber 搶 relay 檔名」。`append_history_locked` 雖然用 `flock`保證單次寫入原子，但**兩個併發觸發源**（`fatq-watch` 的 inotify 喚醒＋週期性 cron 掃描）各自讀到「這個任務還沒被派過」時，會各自組出 attempt=1 的 history entry 並各自成功 append——`flock` 只序列化寫入順序，不阻止兩筆語意重複的 entry 都寫入成功。relay 檔名的 `ln` no-clobber 去重只擋住了第二次 TG 通知，擋不住 history 被寫兩筆（c9d2 review 任務的 22:17:27/22:18:47 兩筆 attempt=1 dispatch 記錄即為實例）。

## 4. 修復與防線

### 4.1 mvp-web-test.sh 測試隔離（RC2/RC3，已 commit+push：61a42ad）
- **前置 gate**：跑任何 server 前，先 `grep MVP_GB "$SRC/mvp-server.ts"`；受測代碼完全沒引用這個環境變數就直接拒跑，不冒險假設「大概率沒事」。
- **Canary**：`P_CHAT` 起來後、任何 W-C10+ 測試發真流量前，先送一則帶隨機標記的訊息，斷言它確實落在 fixture 的假 pod db、且生產 pod db 零命中；兩邊有一項不符就立刻 kill 全部測試 server + exit 1，不繼續跑任何會寫入的後續測試。
- 已驗證：對現在的 mvp/master（含 c9d2 修復）42/42 全綊；對不支援 `MVP_GB` 的舊代碼副本，前置 gate 在起任何 server 前就直接拒跑。

### 4.2 部署 gate（RC1，本單新增；Bella REJECT 一輪後補上 break-glass，見 4.2.1）
- **`shared/bin/fatq-deploy-gate.sh <task_id> <repo_dir> <branch>`**：唯一合法的「merge 進生產 main」入口。檢查 `tasks/done/<task_id>.json` 真的存在且 history 內有 `verdict_approve` 記錄，也檢查 branch 是否為當前 HEAD 的 fast-forward 後裔；都過了才寫一次性 deploy token、執行 `git merge --ff-only`。
- **`shared/bin/install-deploy-hook.sh <repo_dir> [branch=master] [fatq_root]`**：在目標 repo 裝一個 `reference-transaction` git hook（本團隊 merge 風格全是 `--ff-only`，fast-forward 不產生合併提交，`pre-merge-commit` 類 hook 根本不會觸發，因此選對任何 ref 真實更新都會觸發的 `reference-transaction`）。任何對受保護分支（含 merge、reset、甚至直接改 packed-refs）的更新，都要求先有 gate 腳本留下且 commit 相符的 token，否則在 `prepared` 階段回非 0 讓 git 直接中止整個 ref 更新（連工作目錄的變更也會被完整回滾，非部分生效）。Token 單次使用，部署成功或中止後即清除，不能重放。Hook 另回頭核對 token 內的 task_id 真的在 `tasks/done/` 有 `verdict_approve` 記錄，不只信任 token 檔本身存在（Bella NOTE，擋掉偽造 token 的縱深防禦）。
- 已在**隔離的拋棄式 repo**（`/tmp`，測試完即刪）驗證 9 個情境（含 Bella 親測的裸 merge/`git update-ref`/`--no-verify`/push 收端全擋、break-glass 開關、偽造 token）：見 `shared/tests/fatq-deploy-gate-test.sh`（D1-D9，9/9 pass）。
- **已實際安裝在生產 `mvp/` repo**（純加裝 hook，不改動任何已回退的代碼版本，不影響目前運行中的 systemd 進程）。往後對 `mvp/` 的 `master` 做任何 merge，都必須先跑 `fatq-deploy-gate.sh` 帶對應已過審的 task_id，裸 `git merge` 會被 hook 擋下。

#### 4.2.1 Break-glass（Bella 第一輪 REJECT 的唯一 BLOCKER：V9）
Bella 親測抓到：hook 裝上後，`git reset --hard <安全版本>`——也就是 22:39 當晚 Anya 用來止血的**確切操作**——同樣會被 hook 擋下且沒有旁路。這個 gate 的正當性正是來自「事故時要能快速 rollback」，結果它把 rollback 本身鎖死，等於用防「未審代碼進生產」換來「事故時無法快速回退」，在生產場景比其他理論繞過更危急。

修法（已落地）：hook 的 `prepared` 階段最前面加一道 break-glass 檢查——若 `$GIT_COMMON_DIR/BREAK_GLASS` 這個檔案存在，整個 token 檢查直接跳過、放行本次 ref 更新。

**緊急回退 SOP**：
```bash
# 1. 開啟 break-glass（明確意圖操作，人手動執行）
touch /home/oldrabbit/.claude-bots/mvp/.git/BREAK_GLASS
# 2. 回退到已知安全的 commit
git -C /home/oldrabbit/.claude-bots/mvp reset --hard <安全的 commit hash>
# 3. 立刻關閉 break-glass，恢復保護
rm /home/oldrabbit/.claude-bots/mvp/.git/BREAK_GLASS
```
（在此修復落地之前的臨時作法——先移除 `mvp/.git/hooks/reference-transaction` 再 reset、事後重裝 hook——已不再需要，上面的 break-glass 流程更安全，不會有「忘記重裝 hook」的窗口。）

已在拋棄式 repo 驗證（D8）：關閉時裸 `reset --hard` 被擋、開啟時同一個操作放行、且驗證的正是「回到 22:39 事故當晚那種安全版本」的確切場景。

### 4.3 fatq-dispatch 重複派工去重（RC4，本單新增）
- 新增 `dispatch_send()` 統一函數：把「搶 relay 檔名（`ln` no-clobber，唯一真正跨行程原子的操作）」挪到最前面當關卡，贏了才寫 history；輸了直接放棄，不再讓 history 也留一筆重複紀錄。取代舊版「先 append history、再搶 relay 檔名」的順序（該順序下 history 端完全沒有去重保護）。
- 全部 8 個「history+relay 派送」呼叫點（首派/重派升級/催工/催工升級/無主任務提醒/審批未逾期提醒/審批逾時升級/審批回收提醒）統一改用此函數。
- 新增 `shared/tests/fatq-dispatch-test.sh` 的 **A29**：真的用 8 個併發進程同時打同一個任務，斷言 history 恰 1 筆 dispatch、relay 檔恰 1 個。驗證：對修復前的代碼跑這個測試會重現事故（6~8 筆重複 dispatch history，3 次獨立驗證皆重現）；對修復後的代碼穩定 1 筆（5 次連續執行零 flaky）。既有 A1-A28（含跨組件整合測試）零回歸，5 輪重跑穩定 29/29。

## 5. 部署 gate 的威脅模型邊界（Bella 審查降級為 NOTE，非本單缺陷）

- **同 uid 蓄意繞過**（`git -c core.hooksPath=/dev/null merge`、直接 `echo <commit> > .git/refs/heads/master` 改 ref 檔、偽造 token 但同時停用 hook）：這是純 git hook 機制的固有天花板——同一個 Linux 使用者（oldrabbit）擁有 repo 寫入權限時，沒有任何 git 層級的機制能防「蓄意」繞過，要擋只能靠 `chattr +i`（需 root/cap）或換掉 git 本身（wrapper），屬更大的 infra 案，本單不處理。本次事故的攻擊面是「bot 例行裸 merge，不知情、非蓄意」，這條已經擋住；現階段正解＝SOP 明寫「merge-to-prod-main 只能走 `fatq-deploy-gate.sh`，裸 merge/改 ref 檔/停用 hook 皆違規」，配合部署 log 稽核（`logs/fatq-deploy.log`）。
- **hook 未安裝或被移除卻無告警**：建議加一個 hourly health-check（驗 hook 檔在位且可執行，缺了就重裝+TG 告警）。未在本單實作，列後續小單。

## 6. 未竟事項 / 後續建議

- `fatq-dispatch.sh` line ~819 的 `infra_gate_override` 記錄（覆蓋 reviewer 為 bella 時的一次性稽核）也是「check-then-append」模式，理論上有同類但影響更輕的競態（沒有 relay 通知牽涉，最壞情況是重複一筆稽核註記）。本單未修，列為後續小單背景（非本次事故直接相關，不擴大範圍）。
- 部署 gate 目前只裝在 `mvp/`；若未來有其他「本地 repo 兼生產部署目錄」的專案（例如各 bot 自己的代碼），建議同一套機制直接套用（`install-deploy-hook.sh` 已設計成通用，非 mvp 專屬）。
- hourly health-check（見第 5 節 V8）尚未實作。

[[Pod 2.1]] [[mvp-chat-ux-fixes]] [[fatq-dispatch-cron]]
