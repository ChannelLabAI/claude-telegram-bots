#!/usr/bin/env bash
# Maintainer-only installation helper; intentionally does not enable/start.
set -euo pipefail
root=/home/oldrabbit/.claude-bots
install -m 0644 "$root/shared/systemd/keeper-diana.service" "$HOME/.config/systemd/user/keeper-diana.service"
echo 'Installed unit only. After QA, maintainer must daemon-reload, enable/start, and run the live listener-kill proof.'
