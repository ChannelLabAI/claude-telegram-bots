#!/usr/bin/env bash
# setup-pubsub-topics.sh — Create ChannelLab Pub/Sub topics (one-time setup)
# Run with: bash setup-pubsub-topics.sh
# Requires: gcloud auth with channellab-prod access

set -euo pipefail

PROJECT="channellab-prod"

TOPICS=(
    "tg-inbound-anya"
    "tg-inbound-panda"
    "tg-inbound-zhanglinghe"
    "tg-inbound-elon"
    "tg-inbound-zhuchu"
    "tg-inbound-33-huizhang"
    "tg-inbound-anna"
    "tg-inbound-bella"
    "diana-events"
    "team-broadcast"
    "bridge-health"
    "tg-inbound-deadletter"
)

echo "[setup-pubsub] Creating ${#TOPICS[@]} topics in project ${PROJECT}..."

for topic in "${TOPICS[@]}"; do
    if gcloud pubsub topics describe "$topic" --project="$PROJECT" >/dev/null 2>&1; then
        echo "[setup-pubsub] EXISTS: $topic (skipped)"
    else
        gcloud pubsub topics create "$topic" --project="$PROJECT"
        echo "[setup-pubsub] CREATED: $topic"
    fi
done

echo "[setup-pubsub] Done. Verifying..."
gcloud pubsub topics list --project="$PROJECT" --format="value(name)" | grep -c "projects/${PROJECT}/topics/" && echo "[setup-pubsub] topics visible in gcloud ✓"
