#!/usr/bin/env bun
import { readFileSync, realpathSync } from "node:fs";

type Entry = { name: string; type: string; enum?: string[]; min?: number; max?: number };
function die(message: string): never { console.error(message); process.exit(1); }
function arg(name: string): string {
  const index = process.argv.indexOf(name);
  if (index < 0 || !process.argv[index + 1]) die(`MISSING_ARGUMENT=${name}`);
  return process.argv[index + 1];
}
function readEnv(path: string, values: Map<string,string>, duplicates: Set<string>): void {
  for (const raw of readFileSync(path, "utf8").split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const match = line.match(/^([A-Z][A-Z0-9_]*)=(.*)$/);
    if (!match) die(`INVALID_ENV_LINE=${path}`);
    let value = match[2];
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1,-1);
    if (values.has(match[1])) duplicates.add(match[1]);
    values.set(match[1], value);
  }
}

const manifestPath = arg("--manifest");
const customerEnvPath = arg("--customer-env");
const secretsEnvPath = arg("--secrets-env");
const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as { schema_version:number; required:Entry[] };
if (manifest.schema_version !== 1 || !Array.isArray(manifest.required)) die("INVALID_ENV_MANIFEST");
const required = new Map(manifest.required.map(entry => [entry.name, entry]));
if (required.size !== manifest.required.length) die("DUPLICATE_MANIFEST_KEY");
const values = new Map<string,string>(), duplicates = new Set<string>();
readEnv(customerEnvPath, values, duplicates); readEnv(secretsEnvPath, values, duplicates);
if (duplicates.size) die(`DUPLICATE_ENV=${[...duplicates].sort().join(",")}`);
const missing = [...required.keys()].filter(name => !values.get(name));
if (missing.length) die(`MISSING_REQUIRED_ENV=${missing.sort().join(",")}`);
if (values.has("MVP_GBRAIN_URL")) die("FORBIDDEN_ENV=MVP_GBRAIN_URL");
const extras = [...values.keys()].filter(name => name.startsWith("MVP_") && !required.has(name));
if (extras.length) die(`UNEXPECTED_MVP_ENV=${extras.sort().join(",")}`);
const invalid:string[]=[];
for (const [name, entry] of required) {
  const value=values.get(name)!;
  if (value.includes("__REQUIRED_") || (entry.enum && !entry.enum.includes(value))) { invalid.push(name); continue; }
  if (entry.type === "integer") { const n=Number(value); if (!Number.isInteger(n) || (entry.min != null && n<entry.min) || (entry.max != null && n>entry.max)) invalid.push(name); }
  if (entry.type === "boolean" && !["0","1","false","true"].includes(value)) invalid.push(name);
  if (entry.type === "url") { try { new URL(value); } catch { invalid.push(name); } }
  if (entry.type === "absolute_path") {
    if (!value.startsWith("/") || value.includes("/home/oldrabbit") || value.includes("/.claude-bots") || /\/Ocean(?:\/|$)/.test(value)) invalid.push(name);
  }
}
if (invalid.length) die(`INVALID_REQUIRED_ENV=${invalid.sort().join(",")}`);
if (values.get("MVP_GBRAIN_MODE") !== "disabled") die("INVALID_REQUIRED_ENV=MVP_GBRAIN_MODE");
for (const key of ["MVP_DATA_DIR","MVP_OCEAN_SEARCH_ROOT","MVP_OCEAN_WRITE_ROOT"]) {
  const value=values.get(key); if (value && !value.startsWith("/var/lib/channellab-mvp/")) die(`PATH_OUTSIDE_CUSTOMER_ROOT=${key}`);
}
console.log(`PREFLIGHT_OK required=${required.size}`);
const execIndex=process.argv.indexOf("--exec");
if (execIndex >= 0) {
  const executable=process.argv[execIndex+1]; if (!executable) die("MISSING_ARGUMENT=--exec");
  const cleanEnv:Record<string,string>={HOME:"/var/lib/channellab-mvp",PATH:"/usr/local/bin:/usr/bin:/bin",LANG:"C.UTF-8",CHANNELLAB_DEPLOYMENT:"customer",CHANNELLAB_ENV_MANIFEST:realpathSync(manifestPath)};
  for (const [key,value] of values) cleanEnv[key]=value;
  const child=Bun.spawn([executable],{env:cleanEnv,stdin:"inherit",stdout:"inherit",stderr:"inherit"});
  process.exit(await child.exited);
}
