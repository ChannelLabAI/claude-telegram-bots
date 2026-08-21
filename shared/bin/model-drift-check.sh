#!/usr/bin/env bash
# Compare the canonical pod model with the router mirror and gateway policy.

set -euo pipefail

SHARED_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "$SHARED_DIR/.." && pwd)"
PODS_DIR="${MODEL_PODS_DIR:-$ROOT_DIR/pod-system/pods}"
ROUTER_YML="${MODEL_ROUTER_YML:-$SHARED_DIR/config/model-router.yml}"
GATEWAY_TS="${MODEL_GATEWAY_TS:-$ROOT_DIR/pod-system/gateway.ts}"
RESOLVER="${MODEL_RESOLVE_SHIM:-$SHARED_DIR/bin/model-resolve.sh}"

python3 - "$PODS_DIR" "$ROUTER_YML" "$GATEWAY_TS" "$RESOLVER" <<'PYEOF'
import glob
import json
import os
import re
import subprocess
import sys

pods_dir, router_path, gateway_path, resolver = sys.argv[1:]
errors = []

def source_error(source, detail):
    errors.append(f"DRIFT source={source} detail={detail}")

pod_models = {}
try:
    paths = sorted(glob.glob(os.path.join(pods_dir, "*.json")))
    if not paths:
        raise ValueError("no-pod-json")
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            pod = json.load(handle)
        for bot in pod.get("bots", []):
            name = bot.get("name")
            model = bot.get("model")
            # Codex-only bots such as sara intentionally have no Claude model
            # source. They belong to codex.bot_defaults, not this comparison.
            if bot.get("engine") == "codex" and model is None:
                continue
            if not isinstance(name, str) or not name:
                raise ValueError(f"invalid-bot-name:{path}")
            if not isinstance(model, str) or not re.fullmatch(r"claude-[A-Za-z0-9._-]+", model):
                raise ValueError(f"bot={name}:missing-or-invalid-model")
            if name in pod_models and pod_models[name] != model:
                raise ValueError(f"bot={name}:conflicting-pod-models")
            pod_models[name] = model
except Exception as exc:
    source_error("pod", str(exc))

def top_level_map(lines, section):
    start = None
    for index, line in enumerate(lines):
        if re.fullmatch(re.escape(section) + r"\s*:\s*", line):
            start = index + 1
            break
    if start is None:
        return {}
    result = {}
    for line in lines[start:]:
        if line and not line[0].isspace() and not line.lstrip().startswith("#"):
            break
        match = re.match(r"^\s+([^\s:#]+):\s*([^\s#]+)", line)
        if match:
            result[match.group(1)] = match.group(2).strip("'\"")
    return result

router_models = {}
try:
    with open(router_path, encoding="utf-8") as handle:
        router_lines = handle.read().splitlines()
    aliases = top_level_map(router_lines, "models")
    defaults = top_level_map(router_lines, "bot_defaults")
    if not defaults:
        raise ValueError("missing-top-level-bot_defaults")
    for bot, value in defaults.items():
        if bot == "_default":
            continue
        model = aliases.get(value, value)
        if not re.fullmatch(r"claude-[A-Za-z0-9._-]+", model):
            raise ValueError(f"bot={bot}:unresolved-value={value}")
        router_models[bot] = model
except Exception as exc:
    source_error("model-router", str(exc))

gateway_derived = False
try:
    with open(gateway_path, encoding="utf-8") as handle:
        gateway = handle.read()
    match = re.search(r"const DEFAULT_BOTS = \[(.*?)\n\];", gateway, re.S)
    if not match:
        raise ValueError("DEFAULT_BOTS-block-missing")
    if re.search(r"\bmodel\s*:\s*['\"]claude-", match.group(1)):
        raise ValueError("DEFAULT_BOTS-still-has-literal-model")
    if "function withPodConfiguredModels" not in gateway:
        raise ValueError("pod-derived-model-helper-missing")
    if "const BOTS = POD?.bots ?? withPodConfiguredModels(DEFAULT_BOTS);" not in gateway:
        raise ValueError("legacy-defaults-not-wired-to-pod-models")
    gateway_derived = True
except Exception as exc:
    source_error("gateway", str(exc))

for bot in sorted(set(pod_models) | set(router_models)):
    pod_model = pod_models.get(bot)
    router_model = router_models.get(bot)
    gateway_model = pod_model if gateway_derived else None
    values = {value for value in (pod_model, router_model, gateway_model) if value is not None}
    if pod_model is None or router_model is None or gateway_model is None or len(values) != 1:
        errors.append(
            "DRIFT bot={} pod={} model-router={} gateway={}".format(
                bot,
                pod_model or "<missing>",
                router_model or "<missing>",
                gateway_model or "<unverified>",
            )
        )
        continue

    env = dict(os.environ)
    env["MODEL_PODS_DIR"] = pods_dir
    env["MODEL_ROUTER_YML"] = router_path
    resolved = subprocess.run([resolver, bot], text=True, capture_output=True, env=env)
    stdout_lines = resolved.stdout.splitlines()
    if resolved.returncode != 0 or stdout_lines != [pod_model]:
        errors.append(
            f"DRIFT bot={bot} pod={pod_model} model-resolve={resolved.stdout.strip() or '<empty>'} "
            f"exit={resolved.returncode}"
        )
    elif resolved.stderr:
        errors.append(f"DRIFT bot={bot} model-resolve-unexpected-stderr={resolved.stderr.strip()}")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)

for bot in sorted(pod_models):
    model = pod_models[bot]
    print(f"OK bot={bot} pod={model} model-router={model} gateway=derived(pod)")
print(f"model-drift-check: PASS bots={len(pod_models)}")
PYEOF
