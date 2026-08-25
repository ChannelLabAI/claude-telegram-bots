#!/usr/bin/env bun
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

const [sourceRoot, allowlistPath, outputRoot] = process.argv.slice(2);
if (!sourceRoot || !allowlistPath || !outputRoot) {
  throw new Error("usage: prepare-customer-source.ts SOURCE_ROOT SOURCE_ALLOWLIST OUTPUT_ROOT");
}

const files = readFileSync(allowlistPath, "utf8")
  .split(/\r?\n/)
  .map(value => value.trim())
  .filter(value => value && !value.startsWith("#"));

for (const file of files) {
  const destination = join(outputRoot, file);
  mkdirSync(dirname(destination), { recursive: true });
  copyFileSync(join(sourceRoot, file), destination);
}

const serverPath = join(outputRoot, "mvp-server.ts");
let server = readFileSync(serverPath, "utf8");

function replaceExactly(label: string, before: string, after: string): void {
  const first = server.indexOf(before);
  if (first < 0) throw new Error(`CUSTOMER_SOURCE_TRANSFORM_MISSING=${label}`);
  if (server.indexOf(before, first + before.length) >= 0) {
    throw new Error(`CUSTOMER_SOURCE_TRANSFORM_DUPLICATE=${label}`);
  }
  server = server.slice(0, first) + after + server.slice(first + before.length);
}

replaceExactly(
  "attach-origin-default",
  'const ATTACH_ORIGIN = process.env["MVP_ATTACH_ORIGIN"] ?? "https://attach.channellab.io";',
  'const ATTACH_ORIGIN = process.env["MVP_ATTACH_ORIGIN"] ?? "";',
);
replaceExactly(
  "oauth-secret-manager-fallback",
  `function loadSecretGcp(name: string): string {
  const r = spawnSync("gcloud", ["secrets", "versions", "access", "latest",
    \`--secret=\${name}\`, "--project=channellab-prod"], { encoding: "utf8", timeout: 20_000 });
  return (r.stdout ?? "").trim();
}
let GOOGLE_CLIENT_ID = "", GOOGLE_CLIENT_SECRET = "";
try {
  GOOGLE_CLIENT_ID = loadSecretGcp("mvp-google-client-id");
  GOOGLE_CLIENT_SECRET = loadSecretGcp("mvp-google-client-secret");
} catch {}`,
  `const GOOGLE_CLIENT_ID = process.env["MVP_GOOGLE_CLIENT_ID"] ?? "";
const GOOGLE_CLIENT_SECRET = process.env["MVP_GOOGLE_CLIENT_SECRET"] ?? "";`,
);
replaceExactly(
  "public-password-secret-manager-fallback",
  '  if (!PUBLIC_PASSWORD) { try { PUBLIC_PASSWORD = loadSecretGcp("mvp-public-gate-password"); } catch {} }\n',
  "",
);
replaceExactly(
  "admin-password-secret-manager-fallback",
  '  if (!ADMIN_PASSWORD) { try { ADMIN_PASSWORD = loadSecretGcp("mvp-admin-gate-password"); } catch {} }\n',
  "",
);
replaceExactly(
  "oauth-setup-help",
  "(mvp-google-client-id / mvp-google-client-secret)",
  "(MVP_GOOGLE_CLIENT_ID / MVP_GOOGLE_CLIENT_SECRET)",
);
replaceExactly(
  "pm-finance-secret-manager-calls",
  `  const aid = loadSecretGcp(\`lark-app-id-\${prefix}\`).trim();
  const sec = loadSecretGcp(\`lark-app-secret-\${prefix}\`).trim();`,
  '  throw new Error("customer build does not provide PM finance");',
);

writeFileSync(serverPath, server);
console.log("CUSTOMER_SOURCE_TRANSFORMS=6");
