# Phase 1 Deployment Checklist

> GBrain × MemOcean Merge — Phase 1 (Path A)
> Reference: spec §15 REQUIRED-7

---

## Environment Preconditions

- [ ] `gbrain` binary in PATH: `which gbrain` returns non-empty  
  _Check_: `ls -la ~/.bun/bin/gbrain && chmod +x ~/src/gbrain-v013/src/cli.ts`
- [ ] GBrain version ≥ 0.19.0: `gbrain --version`
- [ ] PGLite data dir initialized: `ls ~/.gbrain/brain.pglite/` exists
- [ ] Gemini API key set: `echo $GEMINI_API_KEY | wc -c` > 20  
  _Or_: GOOGLE_API_KEY propagated to MemOcean MCP process env (via systemd EnvironmentFile)
- [ ] MemOcean MCP process has write access to `benchmarks/divergence-log-*.jsonl`
- [ ] `OCEAN_VAULT_ABSOLUTE_PATH` resolves correctly: `python3 -c "import os; print(os.path.realpath(os.path.expanduser('~/Documents/Obsidian Vault/Ocean')))"`
- [ ] OldRabbit/ never appears in any gbrain import history: `grep -r "OldRabbit" ~/.gbrain/ || echo "clean"`
- [ ] `MEMOCEAN_USE_GBRAIN` env var is set: `false` (default, flip to `true` after Stage 1.1 gate)

---

## Stage Gate Checkpoints

### Stage 1.0 — Feature flag + shim skeleton
- [ ] `MEMOCEAN_USE_GBRAIN=false` is the default in deployed config
- [ ] `ocean_search` imports without error: `cd shared/memocean-mcp && python3 -c "from memocean_mcp.tools.ocean_search import memocean_ocean_search; print('OK')"`
- [ ] Privacy module loads: `python3 -c "from memocean_mcp.memocean_mcp.privacy import assert_under_ocean; print('OK')"`
- [ ] Startup health probe runs: check logs for `[ocean_search] GBrain health probe`

### Stage 1.1 — Bootstrap Ocean → GBrain
- [ ] Bootstrap complete: `gbrain list | wc -l` shows expected page count (~1000+)
- [ ] No OldRabbit/ slugs: `gbrain list | grep -i oldrabbit | wc -l` = 0
- [ ] Privacy probe PASS: `bash shared/scripts/gbrain-privacy-check.sh`
- [ ] Benchmark Stage 1.1 gate: `bash shared/scripts/gbrain-benchmark-runner.sh`  
  GBrain Hit@5 ≥ 90.9% (40-question sample)
- [ ] Slug alias map created: `cat shared/memocean-mcp/slug_alias_map.json`

### Stage 1.2 — inotify watcher + 72hr no-drift
- [ ] ocean_watch.py running (Ocean vault daemon, not inotify-watch.sh): `pgrep -f ocean_watch.py && echo running`
- [ ] IN_MOVED_TO + IN_MOVED_FROM events handled by ocean_watch.py: `grep -q "moved_from" shared/scripts/ocean_watch.py && echo OK`
- [ ] Sync test PASS: `bash shared/scripts/test-inotify-sync.sh`  
  (all 4 event types p95 ≤ 5000ms)
- [ ] 72hr observation started: _Start time_: ________
- [ ] 72hr gate PASS: no drift events (drift = gbrain vs filesystem mtime diff > 15min)

### Stage 1.3 — Dual-log mode (≥500 queries OR 7 days)
- [ ] `MEMOCEAN_USE_GBRAIN=true` flipped in MemOcean MCP env
- [ ] Divergence logger active: divergence-log-{date}.jsonl files appearing in benchmarks/
- [ ] Query count checkpoint: `wc -l benchmarks/divergence-log-*.jsonl` ≥ 500  
  _Or_: 7 days elapsed since Stage 1.3 start
- [ ] Divergence report PASS: `bash shared/scripts/gbrain-divergence-report.sh`
  - Top-1 agreement ≥ 60%
  - Top-3 Jaccard median ≥ 0.30
  - Zero breaking cases (GBrain∅ while BM25 has results)
- [ ] Benchmark Stage 1.3 gate: `bash shared/scripts/gbrain-benchmark-runner.sh`  
  GBrain Hit@5 ≥ 90.9% (200-question full set)

### Stage 1.4 — GBrain primary, BM25 fallback
- [ ] AC4 fallback verified: `pytest benchmarks/test_gbrain_fault_matrix.py -v` all PASS
- [ ] AC5 final benchmark: `bash shared/scripts/gbrain-benchmark-runner.sh`  
  GBrain Hit@5 ≥ 90.9%
- [ ] AC6 latency PASS: `bash shared/scripts/gbrain-latency-bench.sh`  
  p95 ≤ 500ms (if median ≥ 200ms, switch to `gbrain serve` HTTP daemon first)
- [ ] BM25 FTS5 re-indexing still ON: `SELECT max(updated_at) FROM fts5_documents` diff < 1h vs filesystem mtime
- [ ] AC8 Privacy CI probe scheduled: Sunday 02:00 UTC cron active

---

## Rollback Procedure

Single env-var rollback (no redeploy):
```bash
export MEMOCEAN_USE_GBRAIN=false
# Restart MemOcean MCP if env is loaded at startup
systemctl --user restart channellab-keeper.service
```

GBrain full teardown (emergency):
```bash
# Stop gbrain daemon if running
pkill -f "gbrain serve" || true
# Flag already off — BM25 takes over immediately
# Verify BM25 freshness
python3 -c "
import sqlite3, os
db = os.path.expanduser('~/.claude-bots/shared/memocean-mcp/memory.db')
conn = sqlite3.connect(db)
print(conn.execute('SELECT max(updated_at) FROM fts5_documents').fetchone())
"
```

---

## Quick Health Check (run anytime)

```bash
# 1. GBrain alive
gbrain --version

# 2. Query returns results
gbrain query "ChannelLab AI" --limit 3

# 3. Page count
gbrain list | wc -l

# 4. Privacy probe
bash shared/scripts/gbrain-privacy-check.sh

# 5. MemOcean fallback (force flag=false)
MEMOCEAN_USE_GBRAIN=false python3 -c "
import sys; sys.path.insert(0, 'shared/memocean-mcp')
from memocean_mcp.tools.ocean_search import memocean_ocean_search
results = memocean_ocean_search('ChannelLab', limit=3)
print(f'BM25 results: {len(results)}')
"
```
