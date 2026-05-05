#!/usr/bin/env bun
// pubsub-bridge.ts — VPS daemon: Pub/Sub → relay/ files
// Subscribes to tg-inbound-{bot}-sub + bridge-health-sub.
// Runs as systemd service channellab-pubsub-bridge.

import { PubSub } from "@google-cloud/pubsub";
import type { Message } from "@google-cloud/pubsub";
import { SecretManagerServiceClient } from "@google-cloud/secret-manager";
import { writeFile, mkdir } from "node:fs/promises";
import { join } from "node:path";

const PROJECT = process.env.GCP_PROJECT ?? "channellab-prod";
const RELAY_DIR = process.env.RELAY_DIR ?? "/home/oldrabbit/.claude-bots/relay";
const HEARTBEAT_FILE =
  process.env.HEARTBEAT_FILE ??
  "/home/oldrabbit/.claude-bots/state/pubsub-bridge-heartbeat.txt";

const pubsub = new PubSub({ projectId: PROJECT });
const smClient = new SecretManagerServiceClient();

// ── Logging ───────────────────────────────────────────────────────────────────

function log(msg: string): void {
  process.stderr.write(`[bridge ${new Date().toISOString()}] ${msg}\n`);
}

// ── Secret Manager ────────────────────────────────────────────────────────────

async function getBotNames(): Promise<string[]> {
  const [version] = await smClient.accessSecretVersion({
    name: `projects/${PROJECT}/secrets/bot-token-map/versions/latest`,
  });
  const map: Record<string, string> = JSON.parse(
    version.payload!.data!.toString()
  );
  // Unique bot names
  return [...new Set(Object.values(map))];
}

// ── Relay file writer ─────────────────────────────────────────────────────────

async function writeRelayFile(botName: string, raw: unknown): Promise<void> {
  const ts = Date.now();
  const update = raw as Record<string, any>;
  const msg = update.message ?? update.callback_query?.message ?? {};
  const from = update.message?.from ?? update.callback_query?.from ?? {};

  const relayMsg = {
    from_bot: "telegram",
    chat_id: String(msg.chat?.id ?? ""),
    user: from.username ?? from.first_name ?? "",
    user_id: from.id ?? null,
    message_id: msg.message_id ?? 0,
    text: update.message?.text ?? update.callback_query?.data ?? "",
    ts: new Date(ts).toISOString(),
    raw: update,
  };

  await mkdir(RELAY_DIR, { recursive: true });
  await writeFile(
    join(RELAY_DIR, `${ts}-tg-${botName}.json`),
    JSON.stringify(relayMsg, null, 2) + "\n",
    "utf8"
  );
  log(`relay written: ${ts}-tg-${botName}.json`);
}

// ── Subscription management ───────────────────────────────────────────────────

async function ensureSubscription(
  topicName: string,
  subName: string
): Promise<ReturnType<typeof pubsub.subscription>> {
  try {
    const topic = pubsub.topic(topicName);
    const opts: Record<string, unknown> = {};
    // Dead letter policy for tg-inbound-* (not deadletter itself or health)
    if (topicName.startsWith("tg-inbound-") && topicName !== "tg-inbound-deadletter") {
      opts.deadLetterPolicy = {
        deadLetterTopic: pubsub.topic("tg-inbound-deadletter").name,
        maxDeliveryAttempts: 5,
      };
    }
    const [sub] = await pubsub.createSubscription(topic, subName, opts);
    log(`created subscription: ${subName}`);
    return sub;
  } catch (err: any) {
    if (err.code === 6) {
      // ALREADY_EXISTS
      log(`reusing subscription: ${subName}`);
      return pubsub.subscription(subName);
    }
    throw err;
  }
}

// ── Message handlers ──────────────────────────────────────────────────────────

async function handleTgMessage(botName: string, message: Message): Promise<void> {
  try {
    const update = JSON.parse(message.data.toString());
    await writeRelayFile(botName, update);
    message.ack();
    log(`ack: ${botName} ps_id=${message.id}`);
  } catch (err) {
    log(`ERROR processing ${botName}: ${String(err)}`);
    message.nack();
  }
}

async function handleHealthMessage(message: Message): Promise<void> {
  try {
    await mkdir(join(HEARTBEAT_FILE, ".."), { recursive: true });
    await writeFile(HEARTBEAT_FILE, new Date().toISOString(), "utf8");
    message.ack();
    log("heartbeat updated");
  } catch (err) {
    log(`ERROR updating heartbeat: ${String(err)}`);
    message.nack();
  }
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  log("=== pubsub-bridge starting ===");
  log(`project: ${PROJECT}, relay dir: ${RELAY_DIR}`);

  const botNames = await getBotNames();
  log(`bots: ${botNames.join(", ")}`);

  // Subscribe to each bot's inbound topic
  for (const botName of botNames) {
    const topicName = `tg-inbound-${botName}`;
    const subName = `tg-inbound-${botName}-sub`;
    const sub = await ensureSubscription(topicName, subName);
    sub.on("message", (msg: Message) => handleTgMessage(botName, msg));
    sub.on("error", (err: Error) => log(`sub error ${subName}: ${err.message}`));
  }

  // Subscribe to bridge-health for watchdog heartbeat
  const healthSub = await ensureSubscription("bridge-health", "bridge-health-sub");
  healthSub.on("message", handleHealthMessage);
  healthSub.on("error", (err: Error) => log(`health sub error: ${err.message}`));

  log("=== pubsub-bridge listening ===");
}

main().catch((err) => {
  log(`FATAL: ${String(err)}`);
  process.exit(1);
});
