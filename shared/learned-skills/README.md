# Learned Skills — 程序記憶系統

這是 bot 團隊的**程序記憶（procedural memory）**：當任一隻 bot 在實戰中發現一個值得保留的處理模式，就把它寫成一個 SKILL 草稿，經老兔審核後成為全團隊共用的知識。

跟 FTS5 的關係：
- **Facts → FTS5**（`~/.claude-bots/shared/fts5/`）：誰是誰、chat_id、token、決策紀錄
- **Procedures → learned-skills**（本目錄）：遇到 X 情境時該怎麼做的步驟知識

兩者互補，不互相取代。

---

## 完整迴圈（6 步）

### 1. Trigger（觸發）

每隻 bot 在 CLAUDE.md 或 sub-agent prompt 裡被告知：
> 當你解決了一個**新類型**的問題（不是 one-off bug，而是會再次發生的模式），把處理過程寫成 SKILL 草稿丟進 `_drafts/`。

品質門檻（缺一不可）：
- **可重複**：未來會再遇到同樣或類似情境
- **有觸發條件**：能用一句話說清楚「什麼時候該用」
- **可執行**：步驟具體到別隻 bot 照做就能成功
- **不是常識**：CLAUDE.md 已經寫過或 gstack 內建的不收

不符合 → 不要寫，避免 skill 爆炸。

### 2. Generation（產生）

Bot 自己寫，三個檔案一組：

```
_drafts/{slug}/
├── SKILL.md     # 是什麼、什麼時候用、為什麼存在
├── USAGE.md     # 步驟、檢查清單、邊界條件
└── EXAMPLE.md   # 真實案例（哪一天、什麼情境、結果如何）
```

slug 用 kebab-case，描述性，不要日期。

### 3. Storage（存放）

草稿留在 `_drafts/`，**永遠不會自動晉升**。沒人審 → 永遠是草稿。這是設計，不是 bug。

### 4. Approval（人工關卡）

老兔（或被授權的特助）審稿流程：

1. 讀 `_drafts/{slug}/` 三個檔
2. 判斷：**收**、**改**、**駁**
3. 收 → `mv _drafts/{slug} approved/{slug}` + 在 `index.md` 加一行
4. 駁 → 直接刪掉或 `mv` 到 `_archive/{slug}-rejected/`

**禁止任何 bot 自己 mv 草稿到 approved/。** 這條是硬規則，違反等於繞過人工審查。

### 5. Retrieval（取用）

每隻 bot 啟動自檢時：
1. 讀 `~/.claude-bots/shared/learned-skills/index.md`
2. 對照當前 session 的工作上下文
3. 看到相關的 entry → 讀對應的 `approved/{slug}/SKILL.md` 與 `USAGE.md`
4. 照做

`index.md` 是平的、人工維護的清單。**沒有語意搜索、沒有 embedding、沒有 RAG。** 平清單夠用且不會壞。

### 6. Maintenance（淘汰）

當一個 skill 失效（描述的情境變了、做法已過時）：
- `mv approved/{slug} _archive/{slug}`
- 在 `index.md` 刪掉那一行
- 在 `_archive/{slug}/` 加一個 `WHY_DEPRECATED.md` 說明

---

## Anti-patterns（反模式，要主動避免）

1. **Skill 爆炸**：每個小麻煩都寫一個 SKILL → index.md 變垃圾。守住「會重複發生」的門檻。
2. **Stale skills**：環境變了但 skill 沒更新 → bot 照舊做法做出錯事。每次有人發現 skill 跟現實對不上，**立刻** archive，不要拖。
3. **Drift**：approved 裡的步驟跟團隊真正在做的事漸漸分歧 → bot 越學越偏。預防：執行 skill 後若發現步驟需要微調，回頭丟一個新 draft 取代舊的。
4. **跟 mistakes.md 混淆**：`~/.claude-bots/shared/mistakes.md` 是「不要再犯的錯」（anti-skills），learned-skills 是「該這樣做」（positive skills）。兩者目前**不合併**。把 mistakes 整合進這套系統是 P1，現在不做。
5. **過度抽象**：寫得像通用方法論而不是具體步驟 → bot 看了等於沒看。SKILL 要具體到能照抄指令。
6. **跳過 EXAMPLE.md**：沒有真實案例的 skill 會被當成空話。每個 approved skill 都必須有至少一個真實事件的紀錄。

---

## 目錄結構

```
learned-skills/
├── README.md           # 本檔
├── index.md            # bot 啟動時讀的平清單
├── _drafts/            # 待審草稿
├── approved/           # 通過審查的正式 skill
│   └── {slug}/
│       ├── SKILL.md
│       ├── USAGE.md
│       └── EXAMPLE.md
└── _archive/           # 已淘汰的 skill（保留歷史）
```

---

## 來源致敬

迴圈設計借鑒了 hermes-agent 的 skill 自動生成想法。**只借概念不抄碼**，本系統純粹是 markdown 檔 + 人工審查，沒有任何自動化、daemon、hook、incremental ingest。

簡單到不會壞，是這個系統的最大特色。
