#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# CALIBRATION CONTROL — reproduce BerriAI's OWN published litellm-rust numbers
# before we chart anything against busbar.
#
# BerriAI report (AIGatewayBench): litellm-rust ≈ 0.66 ms p99 added latency and
# ≈ 21.8 MB peak RSS. If our harness can't reproduce THEIR gateway's numbers,
# our harness is measuring something different and no busbar comparison is valid.
#
# This script launches litellm-rust EXACTLY as their gateways/litellm-rust/README
# documents (features server,python-config; LITELLM_MASTER_KEY/LITELLM_CONFIG_PATH/
# PORT env; embedded pyo3 interpreter) and captures the RSS trajectory at three
# moments — IDLE (pre-traffic) → after the FIRST request → UNDER LOAD — plus the
# c1 p99 overhead against the same direct-to-mock baseline they subtract.
#
# It runs TWO variants to settle the 21.8 MB question definitively:
#   A) litellm[proxy] importable (their README setup) — does it serve, at what RSS?
#   B) litellm NOT importable                          — lower RSS, but does it
#                                                         still serve /v1/messages?
#
# Deterministic: local mock (20 ms TTFT), n=5000, concurrency 1, loopback only.
# Same inputs → same numbers. Emits results/calibration/report.json.
# ---------------------------------------------------------------------------
set -uo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$BENCH_DIR/results/calibration"
GATEWAYS="$BENCH_DIR/gateways"
LITELLM_SRC="${LITELLM_SRC:-$HOME/litellm-rust-src}"
LITELLM_BRANCH="litellm_rust_gateway_v1_messages_route"
COUNT="${COUNT:-5000}"
CONC=1
MOCK_PORT=9000
LR_PORT=8101
mkdir -p "$OUT"
log() { echo "[$(date +%H:%M:%S)] $*"; }

# ── venv + python ────────────────────────────────────────────────────────────
if ! command -v python3 >/dev/null; then sudo apt-get update -q && sudo apt-get install -y -q python3-venv python3-pip; fi
PY="$OUT/venv/bin/python"
if [ ! -x "$PY" ]; then python3 -m venv "$OUT/venv"; fi
"$OUT/venv/bin/pip" install -q --upgrade pip psutil >/dev/null 2>&1 || true

# ── toolchains ───────────────────────────────────────────────────────────────
if ! command -v cargo >/dev/null; then
  log "installing rust"; curl -sSf https://sh.rustup.rs | sh -s -- -y >/dev/null 2>&1; . "$HOME/.cargo/env"
fi
. "$HOME/.cargo/env" 2>/dev/null || true

# ── build mock + probe + litellm-rust ────────────────────────────────────────
log "building mock-upstream + load-probe"
( cd "$BENCH_DIR" && cargo build --release -p mock-upstream -p load-probe ) || { log "probe build failed"; exit 1; }
MOCK_BIN="$BENCH_DIR/target/release/mock-upstream"
PROBE_BIN="$BENCH_DIR/target/release/load-probe"

if [ ! -d "$LITELLM_SRC" ]; then
  log "cloning litellm-rust ($LITELLM_BRANCH)"
  git clone --depth 1 -b "$LITELLM_BRANCH" https://github.com/BerriAI/litellm "$LITELLM_SRC" \
    || { log "litellm-rust clone FAILED — branch missing"; exit 1; }
fi
log "building litellm-ai-gateway (server,python-config)"
( cd "$LITELLM_SRC/litellm-rust" && cargo build --release -p litellm-ai-gateway --features server,python-config ) \
  || { log "litellm-rust build FAILED"; exit 1; }
LR_BIN="$(find "$LITELLM_SRC/litellm-rust/target/release" -maxdepth 1 -type f -perm -u+x \
  \( -name 'litellm-ai-gateway' -o -name 'litellm_ai_gateway' -o -name 'server' \) 2>/dev/null | head -1)"
[ -n "${LR_BIN:-}" ] || { log "litellm-rust binary not found"; exit 1; }
log "litellm-rust binary: $LR_BIN"

# ── helpers ──────────────────────────────────────────────────────────────────
wait_http() { local url="$1" tries="${2:-60}"; for _ in $(seq 1 "$tries"); do curl -fsS -o /dev/null "$url" 2>/dev/null && return 0; sleep 0.5; done; return 1; }
kill_pid() { [ -n "${1:-}" ] && kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; true; }
# sample RSS of a pid over a short window with ZERO traffic → idle snapshot
sample_rss() { "$PY" "$BENCH_DIR/tools/mem_sampler.py" "$1" --interval 0.1 --duration "${2:-3}" --output "$OUT/_rss_tmp.csv" 2>/dev/null | sed -n 's/^peak_rss_mb=//p'; }
# one messages request; echo "<http_status> <curl_time_total_s>"
one_req() { curl -s -o /dev/null -w '%{http_code} %{time_total}' -X POST "http://127.0.0.1:$LR_PORT/v1/messages" \
  -H 'content-type: application/json' -H 'authorization: Bearer gwbench' \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"; }

# ── deterministic mock ───────────────────────────────────────────────────────
log "starting mock (:$MOCK_PORT, TTFT 20ms)"
MOCK_TTFT_MS=20 "$MOCK_BIN" >"$OUT/mock.log" 2>&1 &
MOCK_PID=$!
wait_http "http://127.0.0.1:$MOCK_PORT/health" || { log "mock failed"; cat "$OUT/mock.log"; exit 1; }

# ── direct baseline (the subtrahend) ─────────────────────────────────────────
log "direct baseline: n=$COUNT c=$CONC against mock"
"$PROBE_BIN" --label direct --url "http://127.0.0.1:$MOCK_PORT/v1/messages" \
  --count "$COUNT" --concurrency "$CONC" --model anthropic/mock --output "$OUT/direct.json" >/dev/null
BASE_P99="$("$PY" -c "import json;print(json.load(open('$OUT/direct.json'))['latency_p99_ms'])")"
log "  direct p99 = ${BASE_P99} ms"

# Their /v1/messages route serves ONLY the `azure_ai` provider (commit 698072308:
# messages_provider_config → Some only for "azure_ai"; their own test asserts
# anthropic/openai are None). So the ONLY way litellm-rust actually serves this
# benchmark's endpoint is via azure_ai, pointed at the mock. api_base ending in
# `/v1/messages` is used verbatim by complete_azure_anthropic_url (transformation.rs:60).
MODEL="azure_ai/mock"
AZ_BASE="http://127.0.0.1:$MOCK_PORT/v1/messages"

# ── one variant: launch litellm-rust, capture idle→first→load RSS + p99 ───────
run_variant() { # name  full_env_string
  local name="$1" venv_env="$2"
  log "── variant [$name] ──"
  # shellcheck disable=SC2086
  env $venv_env LITELLM_MASTER_KEY=gwbench PORT=$LR_PORT "$LR_BIN" >"$OUT/${name}.log" 2>&1 &
  local pid=$!
  # give it time to boot the embedded interpreter + read config
  if ! wait_http "http://127.0.0.1:$LR_PORT/health" 80; then
    log "  [$name] no /health — trying a raw request to see if it's up"
  fi
  sleep 2
  local idle_rss; idle_rss="$(sample_rss "$pid" 3)"
  log "  [$name] IDLE rss (pre-traffic) = ${idle_rss:-?} MB"
  local first; first="$(one_req)"; local status="${first%% *}"; local ttime="${first##* }"
  log "  [$name] FIRST /v1/messages -> HTTP $status  (${ttime}s)"
  local post_rss; post_rss="$(sample_rss "$pid" 3)"
  log "  [$name] RSS after first req = ${post_rss:-?} MB"
  # under load: sample RSS during the probe
  "$PY" "$BENCH_DIR/tools/mem_sampler.py" "$pid" --interval 0.1 --duration 200 --output "$OUT/${name}_rss.csv" >"$OUT/${name}_rss.txt" 2>/dev/null &
  local memp=$!
  "$PROBE_BIN" --label "$name" --url "http://127.0.0.1:$LR_PORT/v1/messages" \
    --count "$COUNT" --concurrency "$CONC" --model "$MODEL" \
    --header "authorization: Bearer gwbench" \
    --output "$OUT/${name}.json" >/dev/null 2>&1 || log "  [$name] probe errored (see ${name}.json)"
  kill "$memp" 2>/dev/null; wait "$memp" 2>/dev/null
  local load_rss lp99 errcnt
  load_rss="$(sed -n 's/^peak_rss_mb=//p' "$OUT/${name}_rss.txt")"
  lp99="$("$PY" -c "import json;d=json.load(open('$OUT/${name}.json'));print(d['latency_p99_ms'])" 2>/dev/null || echo null)"
  errcnt="$("$PY" -c "import json;d=json.load(open('$OUT/${name}.json'));print(len(d.get('errors',[])))" 2>/dev/null || echo '?')"
  log "  [$name] LOAD peak rss = ${load_rss:-?} MB   gateway p99 = ${lp99} ms   errors = ${errcnt}"
  # append to report
  "$PY" - "$name" "$status" "$ttime" "$idle_rss" "$post_rss" "$load_rss" "$lp99" "$BASE_P99" "$errcnt" >>"$OUT/report.jsonl" <<'PYEOF'
import json,sys
name,status,ttime,idle,post,load,lp99,base,errc=sys.argv[1:10]
def f(x):
    try: return float(x)
    except: return None
p99=f(lp99); b=f(base)
print(json.dumps({
  "variant":name,"first_request_http_status":int(status) if status.isdigit() else status,
  "first_request_seconds":f(ttime),
  "served_mock":(p99 is not None and p99>15),   # ~20ms mock TTFT means it really proxied
  "idle_rss_mb":f(idle),"post_first_req_rss_mb":f(post),"load_peak_rss_mb":f(load),
  "gateway_p99_ms":p99,"direct_p99_ms":b,
  "p99_added_ms":(round(p99-b,3) if (p99 is not None and b is not None) else None),
  "errors":int(errc) if str(errc).isdigit() else errc,
}))
PYEOF
  kill_pid "$pid"
  sleep 1
}

rm -f "$OUT/report.jsonl"

# Variant A — LEAN env config (build_router_from_env): no LITELLM_CONFIG_PATH, so the
# embedded Python reader is never invoked → no `import litellm` → minimal RSS. This is
# the config that matches their PUBLISHED ~21.8 MB. Serves azure_ai → mock.
run_variant "lean_env" \
  "LITELLM_MODEL_NAME=$MODEL LITELLM_MODEL=$MODEL LITELLM_API_BASE=$AZ_BASE"

# Variant B — their README's python-config path: LITELLM_CONFIG_PATH + litellm[proxy]
# importable → embedded CPython loads the full litellm tree at startup → ~275 MB.
log "installing litellm[proxy] into venv (their README: config reader must import)"
"$OUT/venv/bin/pip" install -q 'litellm[proxy]' >/dev/null 2>&1 || log "litellm[proxy] install had issues"
LLP="$("$OUT/venv/bin/python" -c 'import site;print(site.getsitepackages()[0])' 2>/dev/null)"
# azure_ai config pointing at the mock (their config.yaml used anthropic/mock, which 400s).
cat > "$OUT/config_azure.yaml" <<YAML
model_list:
  - model_name: $MODEL
    litellm_params:
      model: $MODEL
      api_base: $AZ_BASE
      api_key: dummy
YAML
run_variant "python_config" \
  "PYTHONPATH=$LLP LITELLM_CONFIG_PATH=$OUT/config_azure.yaml"

kill_pid "$MOCK_PID"

# ── final report ─────────────────────────────────────────────────────────────
"$OUT/venv/bin/python" - >"$OUT/report.json" <<PYEOF
import json
rows=[json.loads(l) for l in open("$OUT/report.jsonl") if l.strip()]
print(json.dumps({
  "berriai_reported":{"p99_added_ms":0.66,"peak_rss_mb":21.8},
  "arch":"$(uname -m)","count":$COUNT,"concurrency":$CONC,"mock_ttft_ms":20,
  "variants":rows,
}, indent=2))
PYEOF
log "=========================================================="
cat "$OUT/report.json"
log "=========================================================="
