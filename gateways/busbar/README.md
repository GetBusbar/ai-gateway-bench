# Busbar

[Busbar](https://github.com/GetBusbar/busbar) is a single-binary Rust AI gateway that speaks the
Anthropic Messages API natively and forwards to the mock. Governance is always-on in busbar 1.5.0, so
the bench uses the in-memory store plus one minted virtual key (a single in-memory hashmap lookup on
the hot path). No TLS, no hooks — pure proxy overhead.

## Build

```
cargo build --release -p busbar     # -> target/release/busbar  (~9.8 MB, stripped)
```

## Launch

Data listener `:8105`, admin listener `:8106`; upstream is the AIGatewayBench mock on `:9000`
(`gateways/busbar/providers.yaml` sets `base_url: http://127.0.0.1:9000`).

```
BUSBAR_PROVIDERS=gateways/busbar/providers.yaml \
BUSBAR_CONFIG=gateways/busbar/config.yaml \
BENCH_MOCK_KEY=x \
BUSBAR_ADMIN_TOKEN=bench-admin \
  /path/to/target/release/busbar &
```

Mint one virtual key on the admin listener (busbar governance is always-on):

```
KEY=$(curl -s -X POST -H "x-admin-token: bench-admin" -d '{"name":"bench"}' \
  http://127.0.0.1:8106/api/v1/admin/keys | jq -r .token)
```

## Benchmarked endpoint

`POST http://127.0.0.1:8105/bench-pool/v1/messages` with header `x-api-key: $KEY`. The Anthropic
Messages ingress carries the pool name in the path; the body `model` field is ignored (busbar routes
by the path pool). Example:

```
./target/release/load-probe --label busbar \
  --url http://127.0.0.1:8105/bench-pool/v1/messages \
  --count 5000 --concurrency 1 --model anthropic/mock \
  --header "x-api-key: $KEY" --output results/busbar.json
```
