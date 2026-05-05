FROM oven/bun:1 AS builder
WORKDIR /app
COPY package.json ./
RUN bun install
COPY index.ts ./

FROM oven/bun:1
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./
COPY index.ts ./

ENV NODE_ENV=production
ENV GCP_PROJECT=channellab-prod

CMD ["bun", "run", "index.ts"]
