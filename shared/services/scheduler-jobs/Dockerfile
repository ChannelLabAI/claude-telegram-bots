FROM google/cloud-sdk:slim

WORKDIR /app
COPY run.sh /app/run.sh
RUN chmod +x /app/run.sh

# JOB_TYPE is set per-job via Cloud Run Job env vars
ENV GCP_PROJECT=channellab-prod

ENTRYPOINT ["/app/run.sh"]
