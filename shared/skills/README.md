# shared/skills — 第三方 skill 釘版單源

第三方 vendored skill 的 canonical 位置。各 bot 要用 → 從自己的 `.claude/skills/<name>` symlink 過來，**禁止各自複製**（漂移＝供應鏈盲區）。

## 現有

| skill | 上游 | 釘版 | 供應鏈審查 | 授權範圍 |
|---|---|---|---|---|
| hallmark | Nutlope/hallmark v1.1.0 | commit aeb42fb | anya 2026-07-11 | **僅 twinkle（星星人）**。老兔 7/11 授權 Anya 裁量，Anya 決定不全隊鋪——設計萃取結果走 `shared/design/DESIGN.md`，全隊讀文件不跑工具；builder 拿到會跟「頁面服從系統」打架。 |

## 升級 SOP

1. 上游有新版 → **不直接 pull**。anya 先 diff 新舊版全文（skill＝prompt 注入面），重做供應鏈審查
2. 審過 → 更新本目錄 + 更新上表釘版 commit + git commit 記錄
3. symlink 端自動生效，無需逐 bot 動

## 擴散 SOP

要給新 bot 用 → 先過 anya（用途是否錯配、是否有更窄的替代），過了就 symlink 一條，更新上表授權範圍。
