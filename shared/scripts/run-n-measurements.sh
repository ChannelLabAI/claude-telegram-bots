#!/usr/bin/env bash
# run-n-measurements.sh BOT_NAME LABEL_PREFIX N OUT_JSON [METHOD]
#
# Runs measure-bot-startup.sh N times (METHOD = audit | tokens, default audit),
# collects JSON outputs into a single aggregated file with individual runs +
# summary stats.

set -uo pipefail

BOT="${1:?bot name required}"
PREFIX="${2:?label prefix required}"
N="${3:?n required}"
OUT="${4:?output path required}"
METHOD="${5:-audit}"

if [ "$METHOD" != "audit" ] && [ "$METHOD" != "tokens" ]; then
  echo "METHOD must be audit or tokens (got: $METHOD)" >&2
  exit 1
fi

MEASURE="$HOME/.claude-bots/shared/scripts/measure-bot-startup.sh"
RUNS=()
for i in $(seq 1 "$N"); do
  LABEL="${PREFIX}-${i}"
  echo "[${i}/${N}] running $BOT $LABEL (method=$METHOD)..." >&2
  OUTPUT=$("$MEASURE" "$BOT" "$LABEL" --method "$METHOD" 2>/dev/null)
  if [ -n "$OUTPUT" ]; then
    RUNS+=("$OUTPUT")
    echo "  -> $OUTPUT" >&2
  else
    echo "  -> EMPTY (skipping)" >&2
  fi
  # Small gap between runs so audit.log / JSONL writes settle
  sleep 2
done

# Join runs into JSON array and compute stats
RUNS_JSON=$(printf '%s\n' "${RUNS[@]}" | jq -s '.')

# Fields depend on method
if [ "$METHOD" = "audit" ]; then
  FIELDS='["boot_to_plugin_ready","plugin_to_first_audit","boot_to_first_audit"]'
else
  FIELDS='["input_tokens","cache_creation_input_tokens","cache_read_input_tokens","input_tokens_bootstrap"]'
fi

SUMMARY=$(RUNS_JSON="$RUNS_JSON" FIELDS_JSON="$FIELDS" python3 <<'PY'
import json, os, statistics
runs = json.loads(os.environ["RUNS_JSON"])
fields = json.loads(os.environ["FIELDS_JSON"])
def stat(field):
    vals = [r[field] for r in runs if field in r and r[field] is not None]
    if not vals:
        return {"n": 0}
    return {
        "n": len(vals),
        "mean": round(statistics.mean(vals), 3),
        "median": round(statistics.median(vals), 3),
        "stdev": round(statistics.stdev(vals), 3) if len(vals) > 1 else 0.0,
        "cv_pct": round(statistics.stdev(vals) / statistics.mean(vals) * 100, 1) if len(vals) > 1 and statistics.mean(vals) > 0 else 0.0,
        "min": round(min(vals), 3),
        "max": round(max(vals), 3),
    }
print(json.dumps({f: stat(f) for f in fields}, indent=2))
PY
)

jq -n --arg bot "$BOT" --arg prefix "$PREFIX" --arg method "$METHOD" --argjson runs "$RUNS_JSON" --argjson summary "$SUMMARY" \
  '{bot:$bot, prefix:$prefix, method:$method, runs:$runs, summary:$summary}' > "$OUT"

echo "wrote $OUT" >&2
cat "$OUT" | jq -r '.summary | to_entries[] | "\(.key): n=\(.value.n) mean=\(.value.mean) stdev=\(.value.stdev) CV=\(.value.cv_pct)%"'
