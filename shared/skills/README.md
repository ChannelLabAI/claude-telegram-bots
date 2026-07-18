# shared/skills — 第三方 skill 釘版單源

第三方 vendored skill 的 canonical 位置。各 bot 要用 → 從自己的 `.claude/skills/<name>` symlink 過來，**禁止各自複製**（漂移＝供應鏈盲區）。

## 現有

| skill | 上游 | 釘版 | 供應鏈審查 | 授權範圍 |
|---|---|---|---|---|
| hallmark | Nutlope/hallmark v1.1.0 | commit aeb42fb | anya 2026-07-11 | **僅 twinkle（星星人）**。老兔 7/11 授權 Anya 裁量，Anya 決定不全隊鋪——設計萃取結果走 `shared/design/DESIGN.md`，全隊讀文件不跑工具；builder 拿到會跟「頁面服從系統」打架。 |
| scroll-world | oso95/scroll-world | commit f941ef9 | anya 2026-07-13（無注入/無外洩/curl 僅拉生成結果） | **僅 twinkle**（老兔 7/13 指示安裝）。捲動運鏡 landing page 管線。⚠️外部依賴：Higgsfield CLI＋帳號＋credits（單次全跑 ≈N 圖+2N-1 影片生成，每個 3-8 分鐘）；無帳號時 skill 只能出 mock/結構不能出真素材。 |
| apple-design | emilkowalski/skills | commit 6bf2443 | anya 2026-07-18（單檔 SKILL.md 282 行純設計知識，零外呼/零腳本/無注入面） | **twinkle＋pixel**（老兔 7/18 指示安裝；7/19 pixel 建立時擴散）。Apple WWDC 流體介面設計原則之 web 轉譯：spring 動效/手勢/1:1 拖曳/可中斷轉場/材質景深/字體排印/reduced-motion。與 DESIGN.md 分工：DESIGN.md 管品牌（色彩字體版式），此 skill 管互動手感，互補不衝突。 |
| taste-skill | leonxlnx/taste-skill | commit 7c397f2 | anya 2026-07-19（13 子技能純 prompt 內容＋查表 skill.sh 無害；grep 零外呼/零密鑰面；research/ 未 vendor） | **twinkle＋pixel**（老兔 7/19 指示，出處 X@btcqzy1 推文）。排版/配色/留白/圓角/比例＋既有頁面審計重構（反 AI 塑料感）；gpt-tasteskill 為 codex 調校版（pixel 優先讀）。 |
| gsap-skills | greensock/gsap-skills（官方） | commit aed9cfd | anya 2026-07-19（GreenSock 官方 repo，8 技能結構規範，examples 未 vendor，零注入面） | **twinkle＋pixel**（老兔 7/19 指示，同上出處）。GSAP 動效全家：core/timeline/scrolltrigger/plugins/react/frameworks/performance/utils。 |

## 升級 SOP

1. 上游有新版 → **不直接 pull**。anya 先 diff 新舊版全文（skill＝prompt 注入面），重做供應鏈審查
2. 審過 → 更新本目錄 + 更新上表釘版 commit + git commit 記錄
3. symlink 端自動生效，無需逐 bot 動

## 擴散 SOP

要給新 bot 用 → 先過 anya（用途是否錯配、是否有更窄的替代），過了就 symlink 一條，更新上表授權範圍。
