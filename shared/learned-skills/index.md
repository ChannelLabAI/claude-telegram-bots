# Learned Skills Index

Bots 在啟動自檢時讀本檔。每一行：skill 名稱 → 一句話描述 → 什麼時候用。

當你發現當前 session 的情境符合下面某一條，去讀 `approved/{slug}/SKILL.md` 跟 `USAGE.md` 並照做。

## Approved

- **tg-supergroup-id-migration** — TG 群被升級成 supergroup 後 chat_id 改變、bot 找不到群。**Use when**: bot 回報 `400 chat not found` 或喚醒訊息送不出去，且最近群組設定有變動。
- **parallel-builder-reviewer-pools** — 派任務前先掃 `tasks/in_progress/` 看哪個 Builder/Reviewer 空閒，不要反射性塞給 Anna+Bella。**Use when**: 特助準備 dispatch 一個新的開發任務。**v2 (2026-04-08)**: 共用池擴大為 Anna+三菜+Eric / Bella+一湯+KKKK，含 owner 偏好回退規則。
- **recall-mistakes** — 快速 grep `~/.claude-bots/shared/mistakes.md` 找過去的失誤模式和教訓。**Use when**: 開始複雜任務前、踩到錯誤後想查類似前例。用法：`/recall-mistakes <keyword>`。
- **memocean-research** — Vault-First 研究流程：memocean_search → (條件) WebSearch → 寫 Pearl 草稿到 Ocean/_drafts/。**Use when**: 老兔要求研究主題、要建立新 Pearl card、要寫需要知識底蘊的提案、回答不確定的問題。強制 Vault 優先，節省 WebSearch 成本，避免重複研究孤立產出。

## Drafts

（目前無草稿。bot 遇到新模式時會把 SKILL 草稿丟進 `_drafts/`，等老兔或 Anya 審查。）

## Archive

歷史版本見 `_archive/`：
- `parallel-builder-reviewer-pools-v1-20260408-030109` — 2026-04-08 v1，**通過審核 5 分鐘後就 stale**（Eric/KKKK 加入共用池導致）。第一個 drift 反模式實戰案例。
