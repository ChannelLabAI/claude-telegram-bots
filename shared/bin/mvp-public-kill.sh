#!/usr/bin/env bash
# mvp-public-kill.sh — 一鍵切斷 MVP 公網訪問（c8b4「一鍵可停」acceptance criterion）
#
# 只殺公網暴露的通道（cloudflared tunnel 進程），不動 mvp-server 本體——
# 團隊透過 SSH tunnel 存取 127.0.0.1:8090 的既有用法不受影響，只是公網那扇門關掉。
# 用法：bash shared/bin/mvp-public-kill.sh
set -u
pids=$(pgrep -f "cloudflared tunnel" 2>/dev/null)
if [ -z "$pids" ]; then
  echo "[mvp-public-kill] 目前沒有 cloudflared tunnel 在跑，公網本來就沒開。"
  exit 0
fi
echo "[mvp-public-kill] 找到 cloudflared tunnel process：$pids，準備關閉..."
kill $pids 2>/dev/null
sleep 1
still=$(pgrep -f "cloudflared tunnel" 2>/dev/null)
if [ -n "$still" ]; then
  echo "[mvp-public-kill] 一般 kill 沒關掉，改用 kill -9：$still"
  kill -9 $still 2>/dev/null
  sleep 1
fi
if pgrep -f "cloudflared tunnel" >/dev/null 2>&1; then
  echo "[mvp-public-kill] ⚠️仍有 cloudflared tunnel process 存活，請人工確認（ps aux | grep cloudflared）"
  exit 1
fi
echo "[mvp-public-kill] ✓ 公網通道已關閉，mvp-server 本體未受影響（SSH tunnel 存取照常）。"
