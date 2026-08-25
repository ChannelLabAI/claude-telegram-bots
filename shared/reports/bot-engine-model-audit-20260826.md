# 全隊引擎／模型實測盤點 — 2026-08-26

> 老兔指示：「親自去查各個 bot 的運行 session 確認模型，不要用其他資料源。」
> 方法：主動 relay 喚醒全隊 → 從 `/proc/<pid>/cmdline` 讀 `--model` → 21/21 完成。
> 工具：`bots/anya/bin/model-observer.sh`（cron `*/2` 持續蒐集）。

## 實測結果

| bot | engine | model | 角色 |
|---|---|---|---|
| anya | claude | claude-opus-5 | 特助 |
| zhuchu | claude | claude-opus-5 | 特助 |
| huizhang | claude | claude-opus-5 | 特助 |
| diana | claude | claude-opus-5 | 常駐（tmux + start.sh） |
| twinkle | claude | claude-opus-5 | designer |
| stargazer | claude | claude-opus-4-8 | 特助 |
| panda | claude | claude-sonnet-5 | 特助 |
| zhanglinghe | claude | claude-sonnet-5 | 特助 |
| buddy | claude | claude-sonnet-5 | 特助 |
| elon | claude | claude-sonnet-5 | 特助 |
| fengfeng | claude | claude-sonnet-5 | 特助 |
| **bella** | claude | **claude-sonnet-5** | **reviewer** |
| **yitang** | claude | **claude-sonnet-5** | **reviewer** |
| **kk** | claude | **claude-sonnet-5** | **reviewer** |
| keeper | claude | claude-haiku-4-5 | 機房層 |
| anna | codex | gpt-5.6-sol | builder |
| sancai | codex | gpt-5.6-sol | builder |
| eric | codex | gpt-5.6-sol | builder |
| sara | codex | gpt-5.6-sol | designer |
| orange | codex | gpt-5.6-terra | 特助 |
| spark | codex | gpt-5.3-codex-spark | builder |

## 已修正

| 項目 | commit |
|---|---|
| `bot-routing.yml` anna / sancai engine → codex | `2c27308` |
| `bot-routing.yml` eric engine → codex | `2ea0c05` |
| `model-router.yml` 移除 5 個 codex bot 的頂層假條目 + 標註適用範圍 | `f3872ff` |

`model-router.yml` 的模型記載本身**全部正確**（含 `codex.bot_defaults` 分段），不需改動。
先前判定它過期是誤讀——只讀了頂層 `bot_defaults` 而未讀 codex 分段。

## 待決（未自行處理）

1. **eric 的 codex tier 漂移**：設定 `terra`（gpt-5.6-terra / effort=medium），實測與本人自述皆為 `gpt-5.6-sol` / effort=`high`，完整命中 `sol` tier 兩個欄位。改它是**行為變更**（決定未來派工用哪個 tier），非資料對齊。同檔 sancai 有「2026-07-25 terra→sol 回滾，因連續兩單 execution_error 觸發 kill criteria」的註解先例，eric 無對應註解——可能是有意調整未留痕，也可能是漂移。
2. **pod 端 4 筆假 claude 值**：`f3872ff` 拆掉 router 端的假值後，`model-drift-check.sh` 新增 4 筆告警（anna / eric / orange / sancai：`pod=claude-sonnet-5, model-router=<missing>`）。那是 `pod-system/pods/*.json` 裡同樣從未生效的值浮出水面。改動 pod 設定會影響 gateway 實際派 worker，另案。
3. **`codexSandbox` 殘留欄位**：twinkle 的 pod 設定帶 `codexSandbox: workspace-write` 但無 `engine: codex`，依 `gateway.ts:1452` 對她完全惰性。誰若 grep 該欄位推論引擎會判錯。建議與第 2 項一起清。
4. **名字對齊**：`ron-reviewer`（=kk）與 `nicky-builder`（=twinkle）。**不是改字串，是改生產派工語義**——`bot-routing.yml:11-13` 註解明文警告，且 `bot-identity-map.yml` 是專門處理此事的映射層。`ron-reviewer` 有 4 處依賴（含 `dispatch-affinity.json` 的 Ron 線 reviewer），`nicky-builder` 僅 1 處。低風險替代：在每個 legacy id 旁加註解指向 identity-map。

## 對照組織決策的落差

老兔 2026-07-07 決議 #4：「審查=判斷活（**最高階模型**，審查模型等級=審查品質下限，**全系統最不能省的一筆**）」。

實測結果相反：**特助跑 opus-5，審查層三人全部 sonnet-5**。該決議未落地。

## 資料源可靠度（本次實證）

| 來源 | 表現 |
|---|---|
| `/proc` 實測 | ✅ 唯一真相 |
| `model-router.yml` | ✅ 全部正確 |
| `bot-routing.yml` engine | ❌ 3 個標錯（已修） |
| bot 自述 | ⚠️ 九份：星星人／eric／spark／stargazer／yitang／kk／buddy／panda 準，sara／orange 只對引擎 |
| bot 自己的 CLAUDE.md | ❌ stargazer 的寫「日常主線 Sonnet」，實跑 opus-4-8 |

自述品質差異**與引擎無關**，是個體差異。星星人貼了四個可觀測來源交叉驗證並用 sara 當對照組；eric 主動核對設定檔並指出不符。

## 方法備忘（三個會靜默給錯答案的坑）

1. 判進程歸屬用 `/proc/<pid>/comm`，**不要**比對 cmdline 的可執行檔路徑——pod worker 是 `/…/bin/claude -p`（有路徑），diana 常駐是 `claude --model …`（純命令名），只認一種會整類漏掉常駐進程。
2. 判 bot 名用 cwd 優先、argv 只當 fallback——codex 把整個 prompt 當 argv 傳，prompt 內文的 `/bots/xxx` 會被誤抓。
3. relay 的 `requires_reply` 必須是 JSON boolean，字串會被丟進 `relay/quarantine`（reason=`invalid-requires-reply`）。檢查投遞成功看 quarantine 有無新增 + relay 根目錄是否清空，**不要**看 `.read-by-*` marker。
