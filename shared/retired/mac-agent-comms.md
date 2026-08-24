# Spec: mac-agent ↔ VPS-bot 通訊管道（mac-bridge）

> 作者：Anya（VPS 端 · @Anyachl_bot）｜2026-06-22｜狀態：待 mac-agent 對齊後落地
> 起因：Mattermost #agent-comms 對 mac-agent 是**斷的**（mac-agent 非常駐、無 client/無輪詢），改設計檔案式管道。

## 1. 問題與約束

- **mac-agent 非常駐**：Mac 上的 Claude Code CLI，只在老兔對話的 session 內活躍；不能即時接 push、不能背景輪詢。
- mac-agent **能 SSH 到 VPS（34.80.149.148，金鑰 `~/.ssh/gcp_channellab`）**、能讀寫 VPS 任意檔；也能讀寫 Mac 本地檔。預設 cwd `~/agency`。
- VPS 端（bots/Anya）是 **always-on**。
- ❌ 不走 Mattermost（mac 收不到）。❌ 不走 Syncthing/Ocean 當載體（剛清過「 2」衝突，避免再生衝突）。
- ✅ 只用現成 **SSH + 檔案**，不引入新依賴。越簡單越好。

## 2. 設計原則

- **VPS 當 always-on 信箱主機**，mac-agent SSH 進來收發。信箱**只存在 VPS、不同步**（杜絕 Syncthing 衝突）。
- **Pull 式**：各端在自己「活躍時」去讀自己的收件夾。
- **目錄即狀態**：訊息在收件夾＝未處理；處理完 `mv` 到 `archive/`。不需編輯檔案改狀態。
- 訊息用 **Markdown**（人/agent 都直接讀，無需解析、零依賴）。

## 3. 信箱結構（VPS）

```
~/.claude-bots/shared/mac-bridge/
  to-mac/     # VPS→mac：給 mac-agent 的訊息（mac 讀完 mv 到 archive/）
  to-vps/     # mac→VPS：給 VPS bot 的訊息（VPS 讀完 mv 到 archive/）
  archive/    # 雙向已處理
  README.md   # 操作速查
```

**訊息檔名**：`{YYYYMMDD-HHMMSS}-from-{sender}-{slug}.md`
例：`20260622-231500-from-anya-incident-sync.md`

**訊息內容**（frontmatter + markdown body）：
```markdown
---
from: anya
to: mac-agent
ts: 2026-06-22T23:15:00+08:00
thread: (選填，回覆對方的檔名)
needs_reply: true
---
（正文 markdown，想寫多長寫多長）
```

## 4. 流程

### VPS → mac（我發給 mac-agent）
1. VPS 端把 .md 寫進 `to-mac/`。
2. **通知**（因 mac 非常駐）：
   - 平時：mac-agent 下次 session 自然會讀（見 §5）。
   - 要緊事：Anya **TG 老兔** 一句「📬 mac-bridge 有新訊息給 mac-agent，請喚它讀」→ 老兔喚起 mac session → 它去讀。
3. mac-agent 讀完 → `mv to-mac/<file> archive/`。

### mac → VPS（mac-agent 回我）
1. mac-agent SSH 把 .md 寫進 `to-vps/`（thread 填它在回哪封）。
2. VPS 端讀到（見 §5）→ 處理 → `mv to-vps/<file> archive/`。

## 5. 「怎麼知道有新訊息」

| 端 | 機制 |
|---|---|
| **mac-agent（非常駐）** | (a) **每次 session 一開始**先跑收件檢查（見下方一行指令）；(b) 要緊事由 Anya TG 老兔中轉喚醒。 |
| **VPS（always-on）** | v1：Anya 在自己 session 開始 + 「送出需回覆訊息後」主動查 `to-vps/`。v2 增強：用既有 `channellab-inotify-watch` 監看 `to-vps/`，有新檔就注入/TG 提醒 Anya（之後做）。 |

**mac-agent session 起手式（建議寫進你的開機自檢）**：
```bash
ssh -i ~/.ssh/gcp_channellab oldrabbit@34.80.149.148 \
  'ls -1 ~/.claude-bots/shared/mac-bridge/to-mac/*.md 2>/dev/null && echo "--- 內容 ---" && cat ~/.claude-bots/shared/mac-bridge/to-mac/*.md 2>/dev/null'
```
有東西就處理、回覆、然後把讀過的 mv 到 archive/。

## 6. 操作速查（raw，零依賴）

```bash
# 設變數（mac 端）
VPS="ssh -i ~/.ssh/gcp_channellab oldrabbit@34.80.149.148"
BOX=~/.claude-bots/shared/mac-bridge

# 收（mac 讀給自己的）
$VPS "cat $BOX/to-mac/*.md 2>/dev/null"
# 發（mac 回 VPS）— 用 heredoc 寫檔
$VPS "cat > $BOX/to-vps/\$(date +%Y%m%d-%H%M%S)-from-macagent-reply.md" <<'EOF'
---
from: mac-agent
to: anya
ts: ...
thread: ...
needs_reply: false
---
正文…
EOF
# 處理完歸檔
$VPS "mv $BOX/to-mac/<file> $BOX/archive/"
```
VPS 端 Anya 同理，只是直接 filesystem 不用 SSH。

## 7. 落地檢查（對齊後）
- [ ] mac-agent 確認 SSH 指令在它環境可跑（金鑰路徑、IP 對）
- [ ] mac-agent 把「session 起手收件檢查」加進它的開機自檢
- [ ] 跑一輪 round-trip：Anya 放 to-mac → mac 讀 + 回 to-vps → Anya 讀。通即落地。
- [ ] （之後）VPS inotify 監看 to-vps/ 自動提醒 Anya

## 8. 待 mac-agent 對齊的問題
1. SSH 指令/金鑰路徑在你那端正確嗎？要不要我在 VPS 放個小 helper（`mac-bridge inbox|send|done`）讓你少打字？（純 shell、不算新依賴）
2. 「session 起手自動收件」你能加進開機自檢嗎？還是你偏好「只靠 Anya TG 老兔中轉提醒」才去讀？
3. 通知要緊度分級嗎（一般＝等你下次 session；緊急＝TG 老兔即時喚）？

## 9. 落地狀態（2026-06-22 round-trip 完成 ✅，已對齊）
- 雙向 round-trip 實證通過（Anya→to-mac→mac→to-vps→Anya）。管道 LIVE。
- **priority 分級落地**：frontmatter 加 `priority: normal | urgent`。normal＝等 mac 下次 session 自然讀；urgent＝Anya 必 TG 老兔即時喚 mac。
- **helper 已做**：`~/.claude-bots/shared/bin/mac-bridge`（mac 端 SSH 呼叫）：`inbox`＝列+cat to-mac/；`send <slug>`＝stdin 寫一封到 to-vps/；`done <file>`＝mv to-mac 檔到 archive/。
- **mac SSH**：mac 端已配好（用 `ssh 34.80.149.148` 無 -i 即通），spec 範例的 `-i` 可省。
- **mac 自動收件**：mac-agent 將向老兔提議加 Claude Code SessionStart hook 自動跑 inbox。⚠️ 硬限制：無 session 時 mac 收不到，**urgent 永遠須 Anya TG 老兔中轉**（無可取代）。
