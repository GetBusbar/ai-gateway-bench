"""Aggregate every raw per-gateway file bench/run-all.sh wrote into the chart inputs.

Produces (all from THIS run's raw files, uniform c1 latency + a per-gateway concurrency
ceiling sweep + a streaming TTFT probe):
  results/cost_per_million.json   ((avg_cpu_frac*$/vCPU-hr)+(peak_rss_gb*$/GB-hr))/sustained_rps*1e6
  results/rps_per_dollar.json/csv sustained_rps / hourly_cost ($0.24/hr: 4 vCPU + 16 GB)
  results/ttft_overhead.json      per-gateway added TTFT vs direct (available=false + errors if it 5xx'd)
  results/summary_<arch>.json     machine-readable per-gateway matrix

Fairness rules (from the audit): under-load peak RSS for EVERY gateway (no idle substitution),
uniform c1 for the headline latency, ceiling = highest sustained RPS with p99<1000ms AND zero
errors. Added by GetBusbar (busbar fork). Skips any gateway whose files are absent.
"""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

RESULTS = Path(__file__).resolve().parent.parent / "results"
VCPU_HOUR_USD = 0.04
GB_HOUR_USD = 0.005
HOURLY_COST_USD = 4 * VCPU_HOUR_USD + 16 * GB_HOUR_USD  # $0.24/hr — their 4 vCPU / 16 GB model

# gateway key -> (result json, under-load mem txt, cost csv, ceiling json, ttft json)
FILES = {
    "busbar": ("busbar.json", "mem_busbar_messages.txt", "cost_busbar_run.json", "ceiling_busbar.json", "ttft_busbar.json"),
    "litellm-rust": ("litellm_rust.json", "mem_litellm_rust_messages.txt", "cost_rust_run.json", "ceiling_litellm-rust.json", "ttft_litellm-rust.json"),
    "litellm-python": ("litellm_python.json", "mem_litellm_python_messages.txt", "cost_python_run.json", "ceiling_litellm-python.json", "ttft_litellm-python.json"),
    "bifrost": ("bifrost.json", "mem_bifrost_messages.txt", "cost_bifrost_run.json", "ceiling_bifrost.json", "ttft_bifrost.json"),
    "portkey": ("portkey_nonstream.json", "mem_portkey_messages.txt", "cost_portkey_run.json", "ceiling_portkey.json", "ttft_portkey.json"),
}
BASELINE = "direct_anthropic.json"
TTFT_DIRECT = "ttft_direct.json"


def _load(path: Path):
    return json.loads(path.read_text()) if path.exists() else None


def _peak_rss_mb(path: Path) -> float | None:
    if not path.exists():
        return None
    for line in path.read_text().splitlines():
        if line.startswith("peak_rss_mb="):
            return float(line.split("=", 1)[1])
    return None


def _avg_cpu_fraction(path: Path) -> float | None:
    if not path.exists():
        return None
    with path.open(newline="") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        return None
    return sum(float(r["cpu_percent"]) for r in rows) / len(rows) / 100.0


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--arch", required=True)
    ap.add_argument("--busbar-version", default="unknown")
    ap.add_argument("--busbar-sha", default="unknown")
    ap.add_argument("--litellm-rust", default="0")
    args = ap.parse_args()

    base = _load(RESULTS / BASELINE)
    ttft_direct = _load(RESULTS / TTFT_DIRECT)

    cost_out: dict[str, dict] = {}
    rps_rows: list[dict] = []
    ttft_out: dict[str, dict] = {}
    summary_rows: list[dict] = []

    for gw, (rj, memtxt, costcsv, ceilj, ttftj) in FILES.items():
        r = _load(RESULTS / rj)
        if r is None:
            continue
        peak_rss_mb = _peak_rss_mb(RESULTS / memtxt)
        avg_cpu = _avg_cpu_fraction(RESULTS / costcsv)
        ceiling = _load(RESULTS / ceilj)
        sustained_rps = ceiling.get("sustained_rps") if ceiling else None
        ceiling_conc = ceiling.get("concurrency") if ceiling else None

        p50_add = round(r["latency_p50_ms"] - base["latency_p50_ms"], 3) if base else None
        p99_add = round(r["latency_p99_ms"] - base["latency_p99_ms"], 3) if base else None
        errors = len(r.get("errors", []))

        # ── TTFT overhead (flat format for build_chart_csv.ttft) ──
        t = _load(RESULTS / ttftj)
        if t is not None and ttft_direct is not None:
            avail = bool(t.get("available"))
            p50o = round(t["ttft_p50_ms"] - ttft_direct["ttft_p50_ms"], 3) if avail and t.get("ttft_p50_ms") is not None else None
            p99o = round(t["ttft_p99_ms"] - ttft_direct["ttft_p99_ms"], 3) if avail and t.get("ttft_p99_ms") is not None else None
            ttft_out[gw] = {
                "available": str(avail),
                "p50_overhead_ms": p50o,
                "p99_overhead_ms": p99o,
                "errors": t.get("errors", 0),
            }

        # ── cost + rps/$ (need under-load RSS, CPU, and a ceiling RPS) ──
        dollars_per_million = None
        rps_per_dollar = None
        if peak_rss_mb is not None and avg_cpu is not None and sustained_rps:
            hourly_util = (avg_cpu * VCPU_HOUR_USD) + ((peak_rss_mb / 1000.0) * GB_HOUR_USD)
            dollars_per_million = hourly_util / sustained_rps / 3600.0 * 1_000_000
            rps_per_dollar = sustained_rps / HOURLY_COST_USD
            cost_out[gw] = {
                "avg_cpu_fraction": avg_cpu,
                "peak_rss_mb": peak_rss_mb,
                "sustained_rps": sustained_rps,
                "ceiling_concurrency": ceiling_conc,
                "dollars_per_million": dollars_per_million,
                "assumptions": {"vCPU_hour_usd": VCPU_HOUR_USD, "GB_hour_usd": GB_HOUR_USD},
            }
            rps_rows.append({
                "gateway": gw,
                "sustained_rps": sustained_rps,
                "estimated_hourly_cost_usd": HOURLY_COST_USD,
                "rps_per_dollar": rps_per_dollar,
                "ceiling_concurrency": ceiling_conc,
                "p99_ms": ceiling.get("p99_ms") if ceiling else None,
                "errors": ceiling.get("errors") if ceiling else None,
            })

        summary_rows.append({
            "gateway": gw,
            "p50_added_ms": p50_add,
            "p99_added_ms": p99_add,
            "gateway_p50_ms": r["latency_p50_ms"],
            "gateway_p99_ms": r["latency_p99_ms"],
            "peak_rss_mb": peak_rss_mb,
            "ttft_available": ttft_out.get(gw, {}).get("available"),
            "ttft_p50_added_ms": ttft_out.get(gw, {}).get("p50_overhead_ms"),
            "ceiling_concurrency": ceiling_conc,
            "sustained_rps": sustained_rps,
            "rps_per_dollar": rps_per_dollar,
            "dollars_per_million": dollars_per_million,
            "errors": errors,
            "count": r.get("count"),
            "url": r.get("url"),
        })

    (RESULTS / "cost_per_million.json").write_text(json.dumps(cost_out, indent=2) + "\n")
    (RESULTS / "ttft_overhead.json").write_text(json.dumps(ttft_out, indent=2) + "\n")
    (RESULTS / "rps_per_dollar.json").write_text(json.dumps(rps_rows, indent=2) + "\n")
    if rps_rows:
        with (RESULTS / "rps_per_dollar.csv").open("w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=["gateway", "sustained_rps", "estimated_hourly_cost_usd",
                                              "rps_per_dollar", "ceiling_concurrency", "p99_ms", "errors"])
            w.writeheader()
            w.writerows(rps_rows)

    summary = {
        "arch": args.arch,
        "method": {"latency_concurrency": 1, "count": 5000, "mock_ttft_ms": 20,
                   "ceiling_rule": "highest sustained RPS with p99<1000ms AND zero errors",
                   "hourly_cost_usd": HOURLY_COST_USD,
                   "overhead": "gateway_pXX - direct_pXX (same mock, same body, same box)"},
        "busbar_version": args.busbar_version,
        "busbar_sha": args.busbar_sha,
        "litellm_rust_reproduced": args.litellm_rust == "1",
        "baseline": {"p50_ms": base["latency_p50_ms"] if base else None,
                     "p99_ms": base["latency_p99_ms"] if base else None},
        "gateways": summary_rows,
    }
    (RESULTS / f"summary_{args.arch}.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"wrote cost_per_million.json ({len(cost_out)}), rps_per_dollar ({len(rps_rows)}), "
          f"ttft_overhead.json ({len(ttft_out)}), summary_{args.arch}.json ({len(summary_rows)})")


if __name__ == "__main__":
    main()
