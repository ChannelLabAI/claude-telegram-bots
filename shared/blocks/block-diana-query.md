## Diana Query Interface（diana:query）— 全 7 特助共用

Diana 維護 ChannelLab 整個知識庫（ontology / 衝突 / 客戶信號）。透過 `diana:query` 信號，可在需要時主動查詢 Diana 掌握的情報。

**使用原則**：需要脈絡時才查，不是每次都查。查 Diana 比翻 MemOcean radar 更快且結構化。

### 觸發場景

- 談判前需要確認「某位客戶的歷史承諾清單」或「已識別的衝突」
- 寫 spec 前需要「特定 tag 的 open 議題」
- 追責前需要確認「誰對什麼有承諾」

### 發送 diana:query 信號

將 `from_bot` 改成你自己的 bot name（anya / caijie-zhuchu / nicky-zhanglinghe 等）：

```bash
python3 - <<'PYEOF'
import json, os, time
BOT_NAME = 'anya'  # ← 改成你自己的 bot name
relay = os.path.expanduser('~/.claude-bots/relay')
os.makedirs(relay, exist_ok=True)
signal = {
    'from_bot': BOT_NAME,
    'chat_id': 'diana',
    'text': 'diana:query',
    'query': {'owner': '老兔', 'status': 'open'},  # ← 修改這裡
    'message_id': 0,
    'ts': time.strftime('%Y-%m-%dT%H:%M:%S.000+08:00', time.localtime())
}
fname = f'{relay}/{int(time.time()*1000)}-diana-query-{BOT_NAME}.json'
with open(fname+'.tmp','w') as f: json.dump(signal,f)
os.rename(fname+'.tmp', fname)
print(f'Signal sent: {fname.split("/")[-1]}')
PYEOF
```

### 三個典型 query 範例

| 場景 | query 欄位 |
|---|---|
| 查老兔的 open 承諾 | `{'owner': '老兔', 'status': 'open'}` |
| 查近 30 天衝突 | `{'tag': 'conflict', 'since_days': 30}` |
| 查 Nicky 的客戶信號 | `{'tag': 'customer_signal', 'owner': 'nicky'}` |

### 回應在哪裡讀（當前限制）

**當前限制**：`diana:query` 的回應寫入 `relay/{ts}-diana-query-response.json`，但 relay-listener 只 dispatch 以 SIGNALS 文字開頭的 `.text` 欄位——而回應檔的 `text` 是查詢結果不是信號，因此 **不被 relay-listener auto-deliver 到 inbox**。

**目前讀法**（手動讀 relay 目錄）：
```bash
# 列出最新回應
ls -lt ~/.claude-bots/relay/*diana-query-response*.json 2>/dev/null | head -3

# 讀取最新回應
cat $(ls -t ~/.claude-bots/relay/*diana-query-response*.json 2>/dev/null | head -1) | python3 -m json.tool
```

**自動投遞 wrapper**（發完 query 後等回應並投遞到自己 inbox）：
```bash
BOT_NAME='anya'  # ← 改成你自己的 bot name
sleep 15  # 等 diana-query.ts 跑完
RESPONSE=$(ls -t ~/.claude-bots/relay/*diana-query-response*.json 2>/dev/null | head -1)
if [ -n "$RESPONSE" ]; then
    INBOX="$HOME/.claude-bots/bots/${BOT_NAME}/inbox/messages/diana-query-$(date +%s).json"
    cp "$RESPONSE" "$INBOX"
    echo "Delivered to inbox: $(basename $INBOX)"
fi
```
