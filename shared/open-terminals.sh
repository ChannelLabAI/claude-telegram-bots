#!/usr/bin/env bash
# open-terminals.sh — 在 VNC 3 個 workspace 分頁開所有 bot terminal

DISPLAY=${DISPLAY:-:1}
export DISPLAY

# 每頁 5 個 bot，共 3 頁
PAGE1=(anya Bella anna caijie-zhuchu chltao)
PAGE2=(interns lilai-fengfeng nicky-builder nicky-zhanglinghe ron-assistant)
PAGE3=(ron-builder ron-reviewer sancai wes-buddy yitang)

WIN_W=640
WIN_H=330
COLS=2

open_page() {
  local workspace=$1
  shift
  local bots=("$@")
  local i=0
  for bot in "${bots[@]}"; do
    local col=$((i % COLS))
    local row=$((i / COLS))
    local x=$((col * WIN_W))
    local y=$((row * WIN_H))
    xfce4-terminal \
      --title="$bot" \
      --geometry="90x18+${x}+${y}" \
      --command="bash -c 'tmux attach -t $bot || (echo session not found; read)'" &
    sleep 1
    # 把視窗移到對應 workspace
    WID=$(xdotool search --name "^${bot}$" 2>/dev/null | tail -1)
    if [[ -n "$WID" ]]; then
      wmctrl -ir "$WID" -t $((workspace - 1))
    fi
    i=$((i + 1))
  done
}

# 確保有 3 個 workspace
# wmctrl -n 3 — removed, do not override workspace count

echo "Page 1: ${PAGE1[*]}"
open_page 1 "${PAGE1[@]}"

echo "Page 2: ${PAGE2[*]}"
open_page 2 "${PAGE2[@]}"

echo "Page 3: ${PAGE3[*]}"
open_page 3 "${PAGE3[@]}"

echo "Done."
