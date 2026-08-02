#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mvp_dir="${SIGNAL_REGISTRY_MVP_DIR:-$root/mvp}"
db_path="${SIGNAL_REGISTRY_MEMORY_DB:-$root/memory.db}"
builder="$mvp_dir/signal-registry-builder.ts"
fixture="$mvp_dir/signal-registry-diana-metrics-fixture.ts"
[[ -f "$builder" && -f "$fixture" && -f "$db_path" ]] || { echo "missing builder, fixture, or memory.db" >&2; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/signal-registry-conflict-gate.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
snapshot="$tmp/signal-registry.json"

SIGNAL_REGISTRY_PATH="$snapshot" SIGNAL_REGISTRY_MEMORY_DB="$db_path" bun "$builder" >/dev/null
bun "$fixture"
bun - "$db_path" "$snapshot" <<'EOF'
import { Database } from "bun:sqlite";
import { readFileSync } from "node:fs";

const [dbPath,snapshotPath]=Bun.argv.slice(-2);
const snapshot=JSON.parse(readFileSync(snapshotPath,"utf8"));
const violations:string[]=[];
const signalById=new Map(snapshot.signals.map((x:any)=>[x.id,x]));
for(const signal of snapshot.signals) if(signal.detail?.summary==="ownership conflict") violations.push(signal.id);
const db=new Database(dbPath,{readonly:true});
const rows=db.query("SELECT rowid,signal,status,ts FROM health_metrics WHERE signal GLOB 'S[1-7]_*'").all() as any[];
db.close();
const latest=new Map<string,any>();
for(const row of rows){ const current=latest.get(row.signal); const time=Date.parse(String(row.ts)); const currentTime=current?Date.parse(String(current.ts)):Number.NEGATIVE_INFINITY; if(!current || time>currentTime || (time===currentTime && row.rowid>current.rowid)) latest.set(row.signal,row); }
const required=["S1_seabed_lag","S2_cron_dream_cycle","S2_cron_keeper_batch","S2_cron_stale","S2_cron_tg_ingest","S3_api_key","S4_disk_db","S6_db_integrity"];
for(const name of required){ const actual=signalById.get(`system.diana.metric.${name.toLowerCase()}`); const expected=latest.get(name); if(!actual) violations.push(`missing system.diana.metric.${name.toLowerCase()}`); else if(!expected || actual.status!==expected.status || actual.ts!==expected.ts) violations.push(`latest mismatch system.diana.metric.${name.toLowerCase()}`); }
if([...signalById.keys()].filter(id=>id.startsWith("system.diana.metric.")).length<8) violations.push("fewer than eight Diana metrics");
// The assertion path must reject the exact unsafe duplicate outcome, so a
// future short-circuit of latest-per-signal turns this gate red.
if(![...signalById.values()].some((x:any)=>x.detail?.summary==="ownership conflict")) { /* production snapshot clean */ } else violations.push("ownership conflict assertion bypassed");
if(violations.length){ console.error("signal-registry conflict gate failed:\n"+violations.join("\n")); process.exit(1); }
console.log(`signal-registry conflict gate passed (${latest.size} Diana metrics)`);
EOF
