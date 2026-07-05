---
triggers: ["VPS", "GCP", "ssh", "SSH", "VNC", "restart bot", "重啟", "部署架構", "deployment", "34.80", "35.236", "xfce4", "terminal", "start.sh", "screen", "bot process"]
description: "Load when user asks about VPS infrastructure, SSH access, bot restart, or GCP deployment"
---

# Block: VPS Ops

## 部署架構

**全 16 隻 bot 跑在單一台 GCP VPS（34.80.149.148）上 24/7 運行**——Anya / Anna / Bella / 三菜 / 一湯 / 星星人 ... 等全員同箱。
（2026-06-19 當機事件實測校正：本機 self-ping RTT 0.4ms 確認 = 34.80.149.148；hostname `instance-20260404-022056`）

> ⚠️ **35.236.131.187 = 本機的舊浮動 IP，已釋放**（老兔 2026-06-19 確認）。不是另一台機器、沒有藏 gateway。舊文件用它當地址已過時，一律改用 34.80.149.148。litellm/langfuse gateway 本機沒有 → 已退役（內部 bot 走訂閱帳號不需它），別再找。

## VPS 資訊
- IP: 34.80.149.148（GCP，本機 = 全 bot 艦隊）
- SSH: `ssh -i ~/.ssh/gcp_channellab oldrabbit@34.80.149.148`
- 啟動方式：VNC 桌面開 xfce4-terminal 視窗跑 start.sh
- Vault: ~/Documents/Obsidian Vault/（Syncthing 即時雙向同步 Mac ↔ VPS）
- VNC: port 5901, password channellab

## VPS 管理指令
- 查狀態：`ssh ... "ps aux | grep claude | grep -v grep"`
- 重啟 bot：在 VNC 桌面關閉對應 terminal 視窗，重新開 terminal 跑 `~/.claude-bots/bots/{name}/start.sh`
- 遠端開 terminal：`ssh ... "export DISPLAY=:1 && nohup xfce4-terminal --title='{Name}' -e 'bash -lc \"cd ~/.claude-bots/bots/{name} && bash start.sh\"' &>/dev/null &"`

## 當機防護（2026-06-19 事件後加固）
- **根因模式**：整機斷網（連 metadata 169.254.169.254 都不通）→ google-cloud-ops-agent 的 otelcol 無窮 retry → 預設 LimitNOFILE=524288 + 記憶體無上限把 fd/連線吃光 → sshd accept 不到 → 對外全死，但 VM 仍顯示 RUNNING。
- **已加固**：`/etc/systemd/system/google-cloud-ops-agent-opentelemetry-collector.service.d/zz-resource-bound.conf` 限 NOFILE=8192 + MemoryMax=512M；journald `SystemMaxUse=200M`（drop-in，原本無上限長到 817M）。
- **SSH 暴力破解**：btmp 常有數萬筆失敗登入，但本機 `passwordauthentication=no` + 純金鑰 → 打不進來，是噪音非風險。fail2ban 未裝（非必要）。
