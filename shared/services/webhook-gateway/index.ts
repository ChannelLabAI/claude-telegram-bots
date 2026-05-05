import { Hono } from "hono";
import { PubSub } from "@google-cloud/pubsub";
import { SecretManagerServiceClient } from "@google-cloud/secret-manager";

const PROJECT = process.env.GCP_PROJECT ?? "channellab-prod";
const pubsub = new PubSub({ projectId: PROJECT });
const smClient = new SecretManagerServiceClient();

// Secrets cached at startup
let webhookSecretsMap: Record<string, string> = {}; // {bot_name: webhook_secret}
let botTokenMap: Record<string, string> = {};        // {bot_token: bot_name}

async function accessSecret(name: string): Promise<string> {
  const [version] = await smClient.accessSecretVersion({
    name: `projects/${PROJECT}/secrets/${name}/versions/latest`,
  });
  return version.payload!.data!.toString();
}

async function loadSecrets(): Promise<void> {
  const [ws, bt] = await Promise.all([
    accessSecret("webhook-secrets-map"),
    accessSecret("bot-token-map"),
  ]);
  webhookSecretsMap = JSON.parse(ws);
  botTokenMap = JSON.parse(bt);
  console.log(`[gateway] loaded secrets: ${Object.keys(botTokenMap).length} bots`);
}

const app = new Hono();

// Health check
app.get("/", (c) => c.text("ok"));

// TG webhook endpoint: POST /{botToken}
app.post("/:botToken", async (c) => {
  const botToken = c.req.param("botToken");
  const botName = botTokenMap[botToken];
  if (!botName) {
    return c.text("not found", 404);
  }

  // Validate X-Telegram-Bot-Api-Secret-Token header
  const providedSecret = c.req.header("X-Telegram-Bot-Api-Secret-Token");
  const expectedSecret = webhookSecretsMap[botName];
  if (!expectedSecret || providedSecret !== expectedSecret) {
    console.warn(`[gateway] forbidden: ${botName} (wrong or missing secret)`);
    return c.text("forbidden", 403);
  }

  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.text("bad request", 400);
  }

  const topicName = `tg-inbound-${botName}`;
  try {
    await pubsub.topic(topicName).publishMessage({
      data: Buffer.from(JSON.stringify(body)),
      attributes: { bot_name: botName },
    });
    console.log(`[gateway] published: ${botName} → ${topicName}`);
    return c.text("ok");
  } catch (err) {
    console.error(`[gateway] publish error for ${botName}:`, err);
    return c.text("internal error", 500);
  }
});

// Startup: load secrets then start server
await loadSecrets().catch((err) => {
  console.error("[gateway] fatal: failed to load secrets:", err);
  process.exit(1);
});

export default {
  port: Number(process.env.PORT ?? 8080),
  fetch: app.fetch,
};
