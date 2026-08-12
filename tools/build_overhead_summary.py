"""Build results/overhead_summary.json from the raw load-probe result files + the direct baseline.

overhead = gateway_p{50,99} - baseline_p{50,99}, on the same mock, same body, same box.
Fills the previously-uncommitted step so the headline chart regenerates end-to-end from raw runs:

    python tools/build_overhead_summary.py && python tools/build_chart_csv.py && python analyze/make_chart.py

Added by GetBusbar (busbar fork). Skips any gateway whose result file is absent, so it works whether
you ran all five gateways or a subset.
"""

from __future__ import annotations

import json
from pathlib import Path

RESULTS = Path(__file__).resolve().parent.parent / "results"

# gateway key -> the load-probe result file it wrote (see each gateways/<name>/README.md).
GATEWAYS = {
    "busbar": "busbar.json",
    "litellm-rust": "litellm_rust.json",
    "litellm-python": "litellm_python.json",
    "bifrost": "bifrost.json",
    "portkey": "portkey_nonstream.json",
}
BASELINE = "direct_anthropic.json"


def main() -> None:
    base = json.loads((RESULTS / BASELINE).read_text())
    out = []
    for gateway, filename in GATEWAYS.items():
        path = RESULTS / filename
        if not path.exists():
            print(f"skip {gateway}: {filename} not found")
            continue
        r = json.loads(path.read_text())
        out.append(
            {
                "gateway": gateway,
                "endpoint": r["url"],
                "baseline_endpoint": base["url"],
                "latency_p50_overhead_ms": round(r["latency_p50_ms"] - base["latency_p50_ms"], 3),
                "latency_p99_overhead_ms": round(r["latency_p99_ms"] - base["latency_p99_ms"], 3),
                "gateway_result": filename,
                "baseline_result": BASELINE,
            }
        )
    (RESULTS / "overhead_summary.json").write_text(json.dumps(out, indent=2) + "\n")
    print(f"wrote {len(out)} gateways -> results/overhead_summary.json")


if __name__ == "__main__":
    main()
