# Lark 文件鏡射：老兔目前不需再操作

這個流程不架 tunnel，也不會寫回 Lark。

你已透過官方 `@larksuite/cli` device flow 完成 user 授權，現在不需要再點
連結、註冊 redirect URL，也不要傳任何 token 或 app secret。

鏡射 v1 只透過官方 `lark-cli ... --as user` 呼叫唯讀 GET。官方 CLI 管理
兩小時存取憑證與單次使用的續期輪替；repo、工作樹、vault 與 mirror state
都不保存 token。每 30 分鐘執行可持續觸發續期，失敗會沿既有 relay/TG
路徑大聲告警，不會靜默把空結果當成功。

Bella QA 通過後，由 Anya 在 host 執行首輪；live proof 通過且確認
`lark-mirror-sync` 已在 loop registry 登記後，才設定每 30 分鐘
`shared/bin/lark-mirror sync`。程式只枚舉核准的三個 space，硬排除 10 個
HIGH node；人事行政與 test 不在設定中，禁止呼叫。sheet 與一般 file
只盤點 metadata，不讀儲存格或文件內文。每篇 docx 寫入前還會掃描私鑰、
錢包地址、API key、憑證與金額。命中者只在 0600 state 留下標題、來源與
原因類別，不保存內文、不寫 vault、不 ingest MemOcean。
