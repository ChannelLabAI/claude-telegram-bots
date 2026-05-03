#!/usr/bin/env bash
# setup-gcp-jobs.sh — One-time Cloud Run Jobs + Cloud Scheduler setup
# Run after: docker image is built and pushed via cloudbuild.yaml
# Requires: gcloud auth with channellab-prod access

set -euo pipefail

PROJECT="channellab-prod"
REGION="asia-east1"
IMAGE="asia-east1-docker.pkg.dev/${PROJECT}/services/scheduler-jobs:latest"

echo "[setup-gcp-jobs] Creating Cloud Run Jobs..."

# morning-todo Cloud Run Job
gcloud run jobs create chl-scheduler-jobs-morning \
    --image="$IMAGE" \
    --region="$REGION" \
    --project="$PROJECT" \
    --set-env-vars="JOB_TYPE=morning-todo,GCP_PROJECT=${PROJECT}" \
    --max-retries=1 \
    --task-timeout=120 || \
gcloud run jobs update chl-scheduler-jobs-morning \
    --image="$IMAGE" \
    --region="$REGION" \
    --project="$PROJECT" \
    --set-env-vars="JOB_TYPE=morning-todo,GCP_PROJECT=${PROJECT}"

# diana-batch Cloud Run Job
gcloud run jobs create chl-scheduler-jobs-diana \
    --image="$IMAGE" \
    --region="$REGION" \
    --project="$PROJECT" \
    --set-env-vars="JOB_TYPE=diana-batch,GCP_PROJECT=${PROJECT}" \
    --max-retries=1 \
    --task-timeout=120 || \
gcloud run jobs update chl-scheduler-jobs-diana \
    --image="$IMAGE" \
    --region="$REGION" \
    --project="$PROJECT" \
    --set-env-vars="JOB_TYPE=diana-batch,GCP_PROJECT=${PROJECT}"

echo "[setup-gcp-jobs] Creating Cloud Scheduler jobs..."

# morning-todo-job: 08:57 CST (Asia/Taipei timezone)
gcloud scheduler jobs create http morning-todo-job \
    --location="$REGION" \
    --project="$PROJECT" \
    --schedule="57 8 * * *" \
    --time-zone="Asia/Taipei" \
    --uri="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT}/jobs/chl-scheduler-jobs-morning:run" \
    --http-method=POST \
    --oauth-service-account-email="scheduler@${PROJECT}.iam.gserviceaccount.com" \
    --message-body="{}" || echo "morning-todo-job may already exist"

# diana-batch-job: 23:00 CST = 15:00 UTC
gcloud scheduler jobs create http diana-batch-job \
    --location="$REGION" \
    --project="$PROJECT" \
    --schedule="0 15 * * *" \
    --time-zone="UTC" \
    --uri="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT}/jobs/chl-scheduler-jobs-diana:run" \
    --http-method=POST \
    --oauth-service-account-email="scheduler@${PROJECT}.iam.gserviceaccount.com" \
    --message-body="{}" || echo "diana-batch-job may already exist"

echo "[setup-gcp-jobs] Done. Verify with:"
echo "  gcloud run jobs list --project=$PROJECT --region=$REGION"
echo "  gcloud scheduler jobs list --project=$PROJECT --location=$REGION"
