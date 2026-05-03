#!/usr/bin/env bash
# run.sh — Cloud Run Job entrypoint for ChannelLab scheduled tasks
# JOB_TYPE env var selects the job: morning-todo | diana-batch

set -euo pipefail

PROJECT="${GCP_PROJECT:-channellab-prod}"
JOB_TYPE="${JOB_TYPE:-}"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

log() { echo "[scheduler-jobs ${TS}] $*"; }

case "$JOB_TYPE" in
    morning-todo)
        log "Triggering morning-todo → publishing to team-broadcast"
        MSG=$(python3 -c "import json; print(json.dumps({'type':'morning-todo','ts':'${TS}','source':'cloud-scheduler'}))")
        gcloud pubsub topics publish team-broadcast \
            --project="$PROJECT" \
            --message="$MSG"
        log "Published to team-broadcast ✓"
        ;;
    diana-batch)
        log "Triggering diana-batch → publishing to diana-events"
        MSG=$(python3 -c "import json; print(json.dumps({'type':'diana:batch','ts':'${TS}','source':'cloud-scheduler','text':'diana:batch 夜間批次觸發'}))")
        gcloud pubsub topics publish diana-events \
            --project="$PROJECT" \
            --message="$MSG"
        log "Published to diana-events ✓"
        ;;
    *)
        echo "ERROR: JOB_TYPE not set or unknown: '${JOB_TYPE}'" >&2
        echo "Valid values: morning-todo, diana-batch" >&2
        exit 1
        ;;
esac

log "Job complete."
