#!/usr/bin/env bun
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [sourceRoot, allowlistPath, manifestPath, templatePath] = process.argv.slice(2);
if (!sourceRoot || !allowlistPath || !manifestPath || !templatePath) {
  throw new Error("usage: generate-env-manifest.ts SOURCE_ROOT SOURCE_ALLOWLIST MANIFEST TEMPLATE");
}
const files = readFileSync(allowlistPath, "utf8").split(/\r?\n/).map(v => v.trim()).filter(v => v && !v.startsWith("#"));
const found = new Set<string>();
// Cover direct process.env access and the typed env parameter used by
// resolveMvpPaths. A newly introduced equivalent access must enter R.
const pattern = /(?:process\.env|\benv)(?:\[\s*["'](MVP_[A-Z0-9_]+)["']\s*\]|\.(MVP_[A-Z0-9_]+))/g;
for (const file of files) {
  const text = readFileSync(join(sourceRoot, file), "utf8");
  for (const match of text.matchAll(pattern)) found.add(match[1] || match[2]);
}

type RequiredPolicy = { name: string; reason: string };
type NonRequiredVariable = { name: string; reason: string; effective_default?: string };
type NonRequiredPolicy = { reason: string; variables: NonRequiredVariable[] };
type Policy = {
  schema_version: number;
  customer_required: RequiredPolicy[];
  non_required: Record<string, NonRequiredPolicy>;
};
const policyPath = join(import.meta.dir, "customer-env-var-policy.json");
const policy = JSON.parse(readFileSync(policyPath, "utf8")) as Policy;
if (policy.schema_version !== 1 || !Array.isArray(policy.customer_required) || !policy.non_required) {
  throw new Error("invalid customer env variable policy");
}
const requiredReasons = new Map<string, string>();
for (const entry of policy.customer_required) {
  if (!entry.name?.match(/^MVP_[A-Z0-9_]+$/) || !entry.reason?.trim() || requiredReasons.has(entry.name)) {
    throw new Error(`invalid or duplicate customer-required policy entry: ${entry.name ?? "<missing>"}`);
  }
  requiredReasons.set(entry.name, entry.reason.trim());
}
const classified = new Map<string, string>();
for (const name of requiredReasons.keys()) classified.set(name, "customer_required");
for (const [classification, entry] of Object.entries(policy.non_required)) {
  if (!entry.reason?.trim() || !Array.isArray(entry.variables)) {
    throw new Error(`invalid non-required policy class: ${classification}`);
  }
  for (const variable of entry.variables) {
    const name = variable?.name;
    if (!name?.match(/^MVP_[A-Z0-9_]+$/) || !variable.reason?.trim() || classified.has(name)) {
      throw new Error(`invalid or duplicate env policy entry: ${name ?? "<missing>"}`);
    }
    classified.set(name, classification);
  }
}
const unclassified = [...found].filter(name => !classified.has(name)).sort();
const stalePolicy = [...classified.keys()].filter(name => !found.has(name)).sort();
if (unclassified.length || stalePolicy.length) {
  throw new Error(`customer env policy drift unclassified=${unclassified.join(",") || "none"} stale=${stalePolicy.join(",") || "none"}`);
}
const names = [...requiredReasons.keys()].sort();
if (!names.length) throw new Error("no MVP_* environment references found");

function rule(name: string): any {
  if (name === "MVP_GBRAIN_MODE") return { name, type: "string", enum: ["disabled"] };
  if (name === "MVP_PUBLIC_MODE" || name === "MVP_DEV_MODE" || name === "MVP_SKIP_SERVE")
    return { name, type: "boolean", enum: ["0"] };
  if (/(?:PORT|_BYTES|_COUNT|_SEC|_MS|_HOURS|_DAYS|_CAP)$/.test(name))
    return { name, type: "integer", min: name === "MVP_PORT" ? 1024 : 0, max: name === "MVP_PORT" ? 65535 : undefined };
  if (/(?:_URL|_ORIGIN)$/.test(name)) return { name, type: "url" };
  if (/(?:_DIR|_ROOT|_PATH|_FILE|_BIN|_DB|_JSON|_JSONL|_TSV|_AUDIT)$/.test(name) || ["MVP_DIR", "MVP_GB"].includes(name))
    return { name, type: "absolute_path" };
  return { name, type: "string" };
}
const required = names.map(name => ({ ...rule(name), required_reason: requiredReasons.get(name) }))
  .map(value => Object.fromEntries(Object.entries(value).filter(([, v]) => v !== undefined)));
writeFileSync(manifestPath, JSON.stringify({ schema_version: 1, generated_from: files, required }, null, 2) + "\n");
writeFileSync(templatePath, required.map(entry => `${entry.name}=${entry.name === "MVP_GBRAIN_MODE" ? "disabled" : entry.enum?.[0] ?? `__REQUIRED_${entry.name}__`}`).join("\n") + "\n");
console.log(`ENV_MANIFEST_REQUIRED=${required.length}`);
