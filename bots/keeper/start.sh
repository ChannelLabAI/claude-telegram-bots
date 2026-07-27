#!/bin/bash
source "/home/oldrabbit/.claude-bots/shared/bin/secrets-loader.sh" "" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || true
# Deliberately do not use tmux: its server may outlive the unit and escape its
# cgroup. The supervisor keeps vault watching and the listener in one unit.
exec /home/oldrabbit/.claude-bots/shared/diana-resident/resident-supervisor.sh
