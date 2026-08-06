# Cloudflare OS：capability 與非同步核准讀書筆記

連結：[[MVP-開發日誌]]、[[Bot-Team-Architecture]]

## 結論一：capability binding 可採「縮小版」，不能直接取代現有權限／稽核鏈

**立場：能改善，但只能取代 bot 現有的「環境可讀憑證 + 規範／hook 判斷」這一段；不能取代 vault audit hash chain 或 FATQ history。** Cloudflare OS 的預設是 agent/Gadget 沒有任何外部資源；使用者把一個特定 resource 介紹給它後，backend 才建立 Gatekeeper，取得其 id，並以名稱 bind 進 Gadget 或 agent-spawner 的 `env`。這是「把能力物件交給工作單元」，不是把 provider credential 放進所有工作單元。[來源：`packages/workshop-backend/src/server.ts`，行 411–485](https://raw.githubusercontent.com/cloudflare/cloudflare-os/refs/heads/main/packages/workshop-backend/src/server.ts)。

GitHub Gatekeeper 也把能力縮到 repository／issue／PR URL；README 明載連線建立後，Gadget 僅能存取被選取的 resource scope。[來源：`packages/gatekeeper-github/README.md`](https://github.com/cloudflare/cloudflare-os/blob/main/packages/gatekeeper-github/README.md)、[`src/github.ts` 的 `SUPPORTED_RESOURCES`](https://raw.githubusercontent.com/cloudflare/cloudflare-os/refs/heads/main/packages/gatekeeper-github/src/github.ts)。這對我方可改善的是：gateway 在建立 worker/task 時發一份短命、scope-bound 的 tool grant（例如「此 FATQ task 可讀 task asset、可寫自己的 patch、不得讀 TG token」），工具 adapter 只接受 grant；不再讓 bot 直接看到 `.env` 的 TG/GCP/API secret，也不把 CLAUDE.md 規範當唯一防線。

代價是每一個工具都要改成經 adapter 驗證 grant，並要有 issuance、撤銷、過期與授權決策 audit；現有 vault hash chain 仍記錄 secret 存取、FATQ history 仍記錄狀態轉換，兩者是不可互換的事後證據。此次未讀 Cloudflare OS 的 shared Gatekeeper interface 定義，故不主張照抄它的型別或 RPC。

## 結論二：非同步核准可套用，建議採「預備結果 + pending action」骨架

**立場：能套用。** GitHub Gatekeeper 對副作用動作先 `stage`，送入 `ApprovalQueue`，成功後標為 `pending`；資料模型另有 `approved`／`rejected` 狀態。[來源：`packages/gatekeeper-github/src/github.ts`，`submitActionForApproval()`](https://raw.githubusercontent.com/cloudflare/cloudflare-os/refs/heads/main/packages/gatekeeper-github/src/github.ts)。建立 issue／PR 立即回傳使用 provisional id 的物件；在尚未實際建立前，讀取該 id 會從 staged create action 建出 provisional details，而核准後再把 real id 回填。[來源：同檔 `createIssue()`/`createPullRequest()` 與 `#getIssueDetails()`](https://raw.githubusercontent.com/cloudflare/cloudflare-os/refs/heads/main/packages/gatekeeper-github/src/github.ts)。這正是 agent 不必在第一個批准點停住的原因。

我方最小形狀：在 gateway／FATQ 加 `approval_request` 記錄（task、tool、不可逆 action、摘要、預備輸出、狀態）；工具 adapter 遇到 `[ESCALATION]` 不阻塞 worker，而是回傳 `pending:<id>` 與可讀的預備結果。worker 可繼續做所有不依賴真實副作用的步驟；若下一步必須讀回真實結果，必須顯式等待該 id，不能把預備結果冒充已生效。人批准後由獨立 executor 執行一次、寫入 result／audit，並喚醒或讓後續 retry 消費結果；拒絕則回填拒絕原因並讓依賴步驟停止。這會直接把 e599／faff／c9ba 類「整條任務等人」縮成只有相依節點等待。

邊界：不可逆且後續結果強依賴的操作不能任意模擬；初版僅允許可序列化、可摘要的 write tool，並要求 idempotency key。此次未讀 `ApprovalQueue` 的實作與 Cloudflare OS 的批次 UI，所以沒有主張我方必須批次核准或能完整模擬所有工具。

## 讀取與查核

只讀指定三處，未 clone、未安裝套件、未執行 pnpm/wrangler/workerd，無磁碟增量。上述所有 Cloudflare 路徑均以 GitHub 目錄頁或 raw URL 開啟確認；本筆記引用的是 2026-08-06 `main` 可見內容。
