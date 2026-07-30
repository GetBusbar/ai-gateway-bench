#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# AIGatewayBench — full, self-contained, idempotent reproduction on ONE box.
#
# On a clean Ubuntu 24.04 host (4 vCPU / 16 GB; Graviton m7g.xlarge on arm64 or
# m7i.xlarge on x86) this script:
#   1. installs every dependency (build tools, Rust, Node, Python venv),
#   2. fetches + builds busbar, the four competitor gateways, and the mock +
#      Rust load driver,
#   3. runs the FULL benchmark for every reproducible gateway at the SAME
#      uniform load — concurrency 1, n=5000 (AIGatewayBench's stated method) —
#      one gateway at a time, never two load tests at once,
#   4. writes results/*.json + results/mem_*.txt + cost + session files with the
#      exact filenames the chart pipeline expects,
#   5. regenerates every chart PNG with busbar registered as the green winner,
#   6. emits results/summary_<arch>.json (per-gateway p50/p99 added ms, peak RSS
#      MB, errors) for a machine-readable diff across repeated runs.
#
# It is deterministic and re-runnable: run it 1, 2, or 3 times on fresh boxes
# and the numbers should reproduce. Everything is loopback + a local mock, so
# there is no network or provider noise.
#
#   bash bench/run-all.sh
#
# busbar source: prefers ~/busbar if present (an rsynced working copy — used for
# the unreleased 1.5.0 line), otherwise clones GetBusbar/busbar. The build stamp
# (version + git SHA) is recorded in results/summary_<arch>.json.
# ---------------------------------------------------------------------------
set -uo pipefail

# ── locations ───────────────────────────────────────────────────────────────
BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # the fork checkout
RESULTS="$BENCH_DIR/results"
GATEWAYS="$BENCH_DIR/gateways"
BUSBAR_SRC="${BUSBAR_SRC:-$HOME/busbar}"
BUSBAR_REPO="${BUSBAR_REPO:-https://github.com/GetBusbar/busbar.git}"
LITELLM_SRC="${LITELLM_SRC:-$HOME/litellm-rust-src}"
LITELLM_BRANCH="litellm_rust_gateway_v1_messages_route"   # public branch (README's *_messages_route is stale)

COUNT="${COUNT:-5000}"          # requests per headline load run (uniform c1)
CONC="${CONC:-1}"              # uniform concurrency for the headline latency runs
SWEEP_CONCS="${SWEEP_CONCS:-16 32 64 128 256 512}"   # concurrency ramp for the throughput ceiling
SWEEP_COUNT="${SWEEP_COUNT:-5000}"                    # requests per sweep point
DIRECT_CEILING_MULT="${DIRECT_CEILING_MULT:-2.0}"     # baseline "controlled" ⇔ direct p99 ≤ mult× its c1 floor
MOCK_PORT=9000

ARCH="$(uname -m)"; case "$ARCH" in aarch64|arm64) ARCHTAG=arm64 ;; x86_64) ARCHTAG=x86 ;; *) ARCHTAG="$ARCH" ;; esac
mkdir -p "$RESULTS"
log() { echo "[$(date +%H:%M:%S)] $*"; }

# ── 1. system dependencies ──────────────────────────────────────────────────
install_deps() {
  log "installing system dependencies"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    build-essential pkg-config libssl-dev python3-venv python3-pip python3-dev libpython3-dev curl git
  if ! command -v cargo >/dev/null 2>&1 && [ ! -f "$HOME/.cargo/env" ]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y >/dev/null 2>&1
  fi
  # shellcheck disable=SC1091
  [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
  if ! command -v npx >/dev/null 2>&1 || [ "$(node --version 2>/dev/null | sed 's/v\([0-9]*\).*/\1/')" -lt 20 ] 2>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >/dev/null 2>&1
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
  fi
  log "deps: $(cargo --version) · node $(node --version) · $(python3 --version)"
}

# ── 2. builds ────────────────────────────────────────────────────────────────
setup_venv() {
  log "python venv + requirements"
  [ -d "$BENCH_DIR/.venv" ] || python3 -m venv "$BENCH_DIR/.venv"
  # shellcheck disable=SC1091
  . "$BENCH_DIR/.venv/bin/activate"
  pip install -q --upgrade pip
  pip install -q -r "$BENCH_DIR/requirements.txt"
  pip install -q psutil httpx
}

build_probes() {
  log "building mock-upstream + load-probe"
  ( cd "$BENCH_DIR" && cargo build --release -p mock-upstream -p load-probe )
  MOCK_BIN="$BENCH_DIR/target/release/mock-upstream"
  PROBE_BIN="$BENCH_DIR/target/release/load-probe"
}

build_busbar() {
  # Prefer a local working copy at ~/busbar (rsynced by the operator) — this is how the
  # unreleased busbar 1.5.0 line is benchmarked. If absent, clone the PUBLIC GetBusbar/busbar
  # repo so anyone can reproduce (note: public main may be a different version than 1.5.0;
  # the version + SHA actually built are recorded in results/summary_<arch>.json).
  BUSBAR_ORIGIN="rsynced ($BUSBAR_SRC)"
  if [ ! -d "$BUSBAR_SRC" ]; then
    log "no $BUSBAR_SRC — cloning busbar from $BUSBAR_REPO"
    git clone --depth 1 "$BUSBAR_REPO" "$BUSBAR_SRC"
    BUSBAR_ORIGIN="$BUSBAR_REPO"
  fi
  log "building busbar (release) from $BUSBAR_ORIGIN"
  ( cd "$BUSBAR_SRC" && cargo build --release -p busbar )
  BUSBAR_BIN="$BUSBAR_SRC/target/release/busbar"
  BUSBAR_VERSION="$("$BUSBAR_BIN" --version 2>/dev/null | awk '{print $2}')"
  BUSBAR_VERSION="${BUSBAR_VERSION:-$(grep -m1 '^version' "$BUSBAR_SRC/crates/busbar/Cargo.toml" 2>/dev/null | sed 's/.*"\(.*\)".*/\1/')}"
  BUSBAR_SHA="$(git -C "$BUSBAR_SRC" rev-parse --short HEAD 2>/dev/null || echo 'rsynced-no-git')"
  log "busbar $BUSBAR_VERSION ($BUSBAR_SHA) from $BUSBAR_ORIGIN"
}

# litellm-rust: public branch; embeds CPython (pyo3) for the config reader.
# Returns 0 if a runnable binary exists, 1 otherwise (documented + skipped).
LITELLM_RUST_OK=0
build_litellm_rust() {
  if [ ! -d "$LITELLM_SRC" ]; then
    log "cloning litellm-rust ($LITELLM_BRANCH)"
    git clone --depth 1 -b "$LITELLM_BRANCH" https://github.com/BerriAI/litellm "$LITELLM_SRC" || { log "litellm-rust clone failed"; return 1; }
  fi
  log "building litellm-ai-gateway (server,python-config)"
  if ( cd "$LITELLM_SRC/litellm-rust" && cargo build --release -p litellm-ai-gateway --features server,python-config ) ; then
    LITELLM_RUST_BIN="$(find "$LITELLM_SRC/litellm-rust/target/release" -maxdepth 1 -type f -perm -u+x \( -name 'litellm-ai-gateway' -o -name 'litellm_ai_gateway' -o -name 'server' \) 2>/dev/null | head -1)"
    [ -n "${LITELLM_RUST_BIN:-}" ] && LITELLM_RUST_OK=1
  fi
  # its embedded interpreter must be able to `import litellm` at runtime
  [ "$LITELLM_RUST_OK" = 1 ] && pip install -q 'litellm' >/dev/null 2>&1
  [ "$LITELLM_RUST_OK" = 1 ] && log "litellm-rust binary: $LITELLM_RUST_BIN" || log "litellm-rust: NOT built (skipped, see notes)"
}

# ── process helpers ──────────────────────────────────────────────────────────
wait_http() { # url [tries]
  local url="$1" tries="${2:-40}"
  for _ in $(seq 1 "$tries"); do curl -fsS -o /dev/null "$url" 2>/dev/null && return 0; sleep 0.5; done
  return 1
}
kill_pid() { [ -n "${1:-}" ] && kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; true; }

# Concurrency-ceiling sweep: ramp concurrency, keep the highest sustained RPS where p99<1000ms
# AND zero errors AND the direct baseline at that concurrency stayed controlled (p99 within
# DIRECT_CEILING_MULT× its c1 floor). Writes results/ceiling_<name>.json with the best point.
# Uses the SAME model + headers as the headline probe.
sweep_ceiling() {
  local name="$1" url="$2" model="$3"; shift 3
  local extra=("$@")
  local best_rps=0 best_conc=0 best_p99=0
  local direct_c1_p99; direct_c1_p99="$("$PY" -c "import json;print(json.load(open('$RESULTS/direct_anthropic.json'))['latency_p99_ms'])" 2>/dev/null || echo 25)"
  for c in $SWEEP_CONCS; do
    # direct baseline at this concurrency (control)
    "$PROBE_BIN" --label "direct_c$c" --url "http://127.0.0.1:$MOCK_PORT/v1/messages" --count "$SWEEP_COUNT" \
      --concurrency "$c" --model anthropic/mock --output "$RESULTS/direct_sweep_c$c.json" >/dev/null 2>&1
    "$PROBE_BIN" --label "${name}_c$c" --url "$url" --count "$SWEEP_COUNT" --concurrency "$c" --model "$model" \
      --output "$RESULTS/sweep_${name}_c$c.json" "${extra[@]}" >/dev/null 2>&1
    read -r rps p99 errs dp99 <<<"$("$PY" -c "
import json
g=json.load(open('$RESULTS/sweep_${name}_c$c.json')); d=json.load(open('$RESULTS/direct_sweep_c$c.json'))
print(g['rps'], g['latency_p99_ms'], len(g['errors']), d['latency_p99_ms'])
" 2>/dev/null || echo '0 999999 999 999999')"
    local controlled; controlled="$("$PY" -c "print(1 if float('$dp99')<=float('$direct_c1_p99')*$DIRECT_CEILING_MULT else 0)" 2>/dev/null || echo 0)"
    log "    [$name] c=$c rps=${rps%.*} p99=${p99%.*}ms errs=$errs direct_ctrl=$controlled"
    # accept point if p99<1000, zero errors, baseline controlled, and rps improved
    if awk "BEGIN{exit !($p99<1000 && $errs==0 && $controlled==1 && $rps>$best_rps)}" 2>/dev/null; then
      best_rps="$rps"; best_conc="$c"; best_p99="$p99"
    fi
  done
  "$PY" -c "
import json
json.dump({'gateway':'$name','concurrency':$best_conc,'sustained_rps':$best_rps,'p99_ms':$best_p99,
           'errors':0,'rule':'highest sustained RPS with p99<1000ms, zero errors, baseline controlled'},
          open('$RESULTS/ceiling_$name.json','w'), indent=2)
print('ceiling $name: conc=$best_conc rps=%.1f p99=%.1fms'%($best_rps,$best_p99))
" 2>/dev/null || true
}

# probe one gateway: under-load RSS sampler -> load-probe c1 -> cost sampler ->
# TTFT stream probe -> ceiling sweep -> claude_code + codex sessions.
# args: name pid url result_json mem_txt cost_json model [--header "k: v"]...
probe_gateway() {
  local name="$1" pid="$2" url="$3" result="$4" memtxt="$5" costjson="$6" model="$7"; shift 7
  local extra=("$@")
  # RSS sampled UNDER LOAD for EVERY gateway (no idle substitution) — spans the c1 run.
  local memdur=$(( COUNT / 30 + 20 ))
  "$PY" "$BENCH_DIR/tools/mem_sampler.py" "$pid" --interval 0.25 --duration "$memdur" > "$memtxt" 2>/dev/null &
  local memp=$!
  log "  [$name] load-probe n=$COUNT c=$CONC model=$model"
  "$PROBE_BIN" --label "$name" --url "$url" --count "$COUNT" --concurrency "$CONC" --model "$model" --output "$result" "${extra[@]}" >/dev/null
  # cost sampler (CPU) during a steady-state burst
  "$PY" "$BENCH_DIR/tools/cost_sampler.py" "$pid" --output "$costjson" --duration 12 --interval 0.25 > "${costjson%.json}.stdout" 2>/dev/null &
  local costp=$!
  "$PROBE_BIN" --label "${name}_costburst" --url "$url" --count "$COUNT" --concurrency 64 --model "$model" --output "$RESULTS/${name}_costburst.json" "${extra[@]}" >/dev/null
  wait "$costp" 2>/dev/null
  wait "$memp" 2>/dev/null
  # streaming TTFT probe (records available=false + error count if the stream route 5xx's)
  log "  [$name] streaming TTFT probe (n=100 c=16)"
  ( cd "$BENCH_DIR" && "$PY" bench/streaming_probe.py --url "$url" --model "$model" \
    --output "$RESULTS/ttft_${name}.json" --count 100 --concurrency 16 "${extra[@]}" ) >/dev/null 2>&1 || \
    "$PY" -c "import json;json.dump({'available':False,'errors':100,'ttft_p50_ms':None,'ttft_p99_ms':None},open('$RESULTS/ttft_${name}.json','w'))"
  # concurrency-ceiling sweep for throughput / RPS-per-$
  log "  [$name] ceiling sweep ($SWEEP_CONCS)"
  sweep_ceiling "$name" "$url" "$model" "${extra[@]}"
  # whole-session overhead: BOTH profiles, non-streaming for apples-to-apples
  log "  [$name] session_runner claude_code + codex (non-stream)"
  ( cd "$BENCH_DIR" && "$PY" -m agents.session_runner --profile claude_code --url "$url" --non-stream --model "$model" \
    --output "$RESULTS/session_claude_code_${name}.json" "${extra[@]}" ) >/dev/null 2>&1 || true
  ( cd "$BENCH_DIR" && "$PY" -m agents.session_runner --profile codex --url "$url" --non-stream --model "$model" \
    --output "$RESULTS/session_codex_${name}.json" "${extra[@]}" ) >/dev/null 2>&1 || true
}

# ── 3. the bench ─────────────────────────────────────────────────────────────
main() {
  install_deps
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env" 2>/dev/null || true
  setup_venv
  PY="$BENCH_DIR/.venv/bin/python"
  build_probes
  build_busbar
  build_litellm_rust

  export BENCH_MOCK_KEY="dummy"

  # ── start the deterministic mock ──────────────────────────────────────────
  log "starting mock-upstream on :$MOCK_PORT"
  MOCK_TTFT_MS=20 "$MOCK_BIN" >/tmp/mock.log 2>&1 &
  MOCK_PID=$!
  wait_http "http://127.0.0.1:$MOCK_PORT/health" || { log "mock failed to start"; cat /tmp/mock.log; exit 1; }

  # ── direct baseline (once) — the subtrahend for every overhead number ─────
  log "direct baseline: load-probe n=$COUNT c=$CONC against the mock"
  "$PROBE_BIN" --label direct-anthropic --url "http://127.0.0.1:$MOCK_PORT/v1/messages" \
    --count "$COUNT" --concurrency "$CONC" --model anthropic/mock --output "$RESULTS/direct_anthropic.json" >/dev/null
  # direct streaming TTFT baseline (subtrahend for every TTFT-overhead number)
  ( cd "$BENCH_DIR" && "$PY" bench/streaming_probe.py --url "http://127.0.0.1:$MOCK_PORT/v1/messages" \
    --model anthropic/mock --output "$RESULTS/ttft_direct.json" --count 100 --concurrency 16 ) >/dev/null 2>&1 || true
  ( cd "$BENCH_DIR" && "$PY" -m agents.session_runner --profile claude_code --url "http://127.0.0.1:$MOCK_PORT/v1/messages" --non-stream \
    --model anthropic/mock --output "$RESULTS/session_claude_code_direct.json" ) >/dev/null 2>&1 || true
  ( cd "$BENCH_DIR" && "$PY" -m agents.session_runner --profile codex --url "http://127.0.0.1:$MOCK_PORT/v1/messages" --non-stream \
    --model anthropic/mock --output "$RESULTS/session_codex_direct.json" ) >/dev/null 2>&1 || true

  # ══ busbar (:8105, admin :8106) ═══════════════════════════════════════════
  log "gateway: busbar"
  BUSBAR_CONFIG="$GATEWAYS/busbar/config.yaml" BUSBAR_PROVIDERS="$GATEWAYS/busbar/providers.yaml" \
    BENCH_MOCK_KEY=dummy BUSBAR_ADMIN_TOKEN=bench-admin "$BUSBAR_BIN" >/tmp/busbar.log 2>&1 &
  BUSBAR_PID=$!
  if wait_http "http://127.0.0.1:8106/health" 60 || sleep 3; then :; fi
  # Busbar 1.5.0's mint response carries the once-shown signed token under "token" (not "secret").
  KEY="$(curl -sX POST -H 'x-admin-token: bench-admin' -H 'content-type: application/json' \
        -d '{"name":"bench"}' http://127.0.0.1:8106/api/v1/admin/keys | "$PY" -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null)"
  log "  busbar minted key: ${KEY:0:8}…"
  probe_gateway busbar "$BUSBAR_PID" "http://127.0.0.1:8105/bench-pool/v1/messages" \
    "$RESULTS/busbar.json" "$RESULTS/mem_busbar_messages.txt" "$RESULTS/cost_busbar_run.json" \
    "anthropic/mock" --header "x-api-key: $KEY"
  kill_pid "$BUSBAR_PID"

  # litellm's proxy config reader (used by BOTH litellm-rust's embedded interpreter and the
  # python gateway) needs the [proxy] extras (backoff, etc.). Install once, up front.
  log "installing litellm[proxy] (config reader deps)"
  pip install -q 'litellm[proxy]' >/dev/null 2>&1 || true

  # ══ litellm-rust (:8101) ══════════════════════════════════════════════════
  # Embeds CPython (pyo3) to read the proxy YAML; must run with the venv active so
  # `import litellm` resolves. Public branch litellm_rust_gateway_v1_messages_route
  # (the README's litellm_rust_messages_route branch does not exist).
  if [ "$LITELLM_RUST_OK" = 1 ]; then
    log "gateway: litellm-rust"
    LITELLM_MASTER_KEY=gwbench LITELLM_CONFIG_PATH="$GATEWAYS/litellm-rust/config.yaml" PORT=8101 \
      "$LITELLM_RUST_BIN" >/tmp/litellm_rust.log 2>&1 &
    LR_PID=$!
    for _ in $(seq 1 40); do grep -q listening /tmp/litellm_rust.log 2>/dev/null && break; sleep 1; done
    sleep 1
    # Smoke the Anthropic Messages route BEFORE committing to a full probe. On the public
    # branch (commit 698072308) the /v1/messages route only wires the `azure_ai` provider —
    # messages_provider_config() returns None for `anthropic` — so `anthropic/mock` yields
    # HTTP 400 (body "anthropic") and never reaches the mock. Record that honestly and skip.
    LR_CODE="$(curl -s -o /tmp/lr_smoke.txt -w '%{http_code}' -X POST http://127.0.0.1:8101/v1/messages \
      -H 'content-type: application/json' -H 'Authorization: Bearer gwbench' \
      -d '{"model":"anthropic/mock","max_tokens":40,"messages":[{"role":"user","content":"hi"}]}' 2>/dev/null)"
    if [ "$LR_CODE" = "200" ]; then
      probe_gateway litellm-rust "$LR_PID" "http://127.0.0.1:8101/v1/messages" \
        "$RESULTS/litellm_rust.json" "$RESULTS/mem_litellm_rust_messages.txt" "$RESULTS/cost_rust_run.json" \
        "anthropic/mock" --header "Authorization: Bearer gwbench"
    else
      log "  litellm-rust /v1/messages smoke = HTTP $LR_CODE ($(head -c 40 /tmp/lr_smoke.txt)) — Anthropic Messages route not served on the public branch; recording unavailable, skipping"
      LITELLM_RUST_OK=0
    fi
    kill_pid "$LR_PID"
  else
    log "SKIP litellm-rust — see notes (build/run not reproducible on this box)"
  fi

  # ══ litellm-python (:8102) ════════════════════════════════════════════════
  log "gateway: litellm-python"
  LITELLM_MASTER_KEY=gwbench "$BENCH_DIR/.venv/bin/litellm" --config "$GATEWAYS/litellm-python/config.yaml" --port 8102 >/tmp/litellm_py.log 2>&1 &
  LP_PID=$!
  wait_http "http://127.0.0.1:8102/health/liveliness" 100 || wait_http "http://127.0.0.1:8102/health" 40 || sleep 10
  probe_gateway litellm-python "$LP_PID" "http://127.0.0.1:8102/v1/messages" \
    "$RESULTS/litellm_python.json" "$RESULTS/mem_litellm_python_messages.txt" "$RESULTS/cost_python_run.json" \
    "anthropic/mock" --header "Authorization: Bearer gwbench"
  kill_pid "$LP_PID"

  # ══ bifrost (:8103, native /anthropic/v1/messages) ════════════════════════
  # The @maximhq/bifrost npx launcher (npm 1.6.3 → bifrost transport v1.6.x) maps
  # /anthropic/v1/messages onto the custom provider's "responses" capability, so the
  # provider must allow it and the model is provider-prefixed (mock/mock). The
  # committed gateways/bifrost/config.yaml only enables chat_completion; we extend it
  # here (responses[_stream]) so the native Anthropic route resolves on this version.
  log "gateway: bifrost"
  BF_DIR=/tmp/gwbench-bifrost-run; rm -rf "$BF_DIR"; mkdir -p "$BF_DIR"
  cat > "$BF_DIR/config.json" <<'JSON'
{"providers":{"mock":{"keys":[{"name":"mock-key","value":"dummy","models":["*"],"weight":1.0}],"network_config":{"base_url":"http://127.0.0.1:9000","default_request_timeout_in_seconds":60},"custom_provider_config":{"base_provider_type":"anthropic","allowed_requests":{"chat_completion":true,"chat_completion_stream":true,"responses":true,"responses_stream":true}}}},"config_store":{"enabled":false}}
JSON
  npx -y @maximhq/bifrost --app-dir "$BF_DIR" --host 127.0.0.1 --port 8103 >/tmp/bifrost.log 2>&1 &
  BF_PID=$!
  wait_http "http://127.0.0.1:8103/" 90 || sleep 10
  BF_RSS_PID="$(ss -ltnpH 'sport = :8103' 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)"; BF_RSS_PID="${BF_RSS_PID:-$BF_PID}"
  probe_gateway bifrost "$BF_RSS_PID" "http://127.0.0.1:8103/anthropic/v1/messages" \
    "$RESULTS/bifrost.json" "$RESULTS/mem_bifrost_messages.txt" "$RESULTS/cost_bifrost_run.json" \
    "mock/mock"
  kill_pid "$BF_PID"; pkill -f '@maximhq/bifrost' 2>/dev/null || true; pkill -f bifrost 2>/dev/null || true

  # ══ portkey (:8787) ═══════════════════════════════════════════════════════
  log "gateway: portkey"
  npx -y @portkey-ai/gateway >/tmp/portkey.log 2>&1 &
  PK_PID=$!
  wait_http "http://127.0.0.1:8787/v1/health" 90 || sleep 10
  PK_RSS_PID="$(ss -ltnpH 'sport = :8787' 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)"; PK_RSS_PID="${PK_RSS_PID:-$PK_PID}"
  probe_gateway portkey "$PK_RSS_PID" "http://127.0.0.1:8787/v1/messages" \
    "$RESULTS/portkey_nonstream.json" "$RESULTS/mem_portkey_messages.txt" "$RESULTS/cost_portkey_run.json" \
    "anthropic/mock" --header "x-portkey-provider: anthropic" --header "x-portkey-custom-host: http://127.0.0.1:9000/v1"
  kill_pid "$PK_PID"; pkill -f '@portkey-ai/gateway' 2>/dev/null || true

  # ── stop mock ─────────────────────────────────────────────────────────────
  kill_pid "$MOCK_PID"

  # ── 4. aggregate + summary ────────────────────────────────────────────────
  log "building overhead + cost + session summaries"
  ( cd "$BENCH_DIR" && "$PY" tools/build_overhead_summary.py ) || true
  ( cd "$BENCH_DIR" && "$PY" bench/build_cost_and_summary.py \
      --arch "$ARCHTAG" --busbar-version "${BUSBAR_VERSION:-unknown}" --busbar-sha "${BUSBAR_SHA:-unknown}" \
      --litellm-rust "$LITELLM_RUST_OK" ) || true
  ( cd "$BENCH_DIR" && "$PY" bench/build_session_overhead.py ) || true

  # ── 5. charts (busbar registered as the green winner in make_chart.py + make_agent_charts.py) ─
  log "regenerating charts"
  ( cd "$BENCH_DIR" && "$PY" tools/build_chart_csv.py ) || true
  ( cd "$BENCH_DIR" && "$PY" analyze/make_chart.py ) || true
  ( cd "$BENCH_DIR" && "$PY" analyze/make_agent_charts.py ) || true

  log "DONE — summary:"
  cat "$RESULTS/summary_${ARCHTAG}.json" 2>/dev/null || true
}

main "$@"
