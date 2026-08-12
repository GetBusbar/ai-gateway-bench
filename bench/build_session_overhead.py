"""Build results/session_overhead.json from the per-gateway session replay files.

session_runner writes results/session_<profile>_<gw>.json with total_wall_time_ms.
Added session time = gateway_total - direct_total, per profile (claude_code, codex).

Added by GetBusbar (busbar fork). Skips any gateway missing a session file.
"""

from __future__ import annotations

import json
from pathlib import Path

RESULTS = Path(__file__).resolve().parent.parent / "results"

# gateway key -> filename suffix used by run-all.sh (session_<profile>_<suffix>.json)
GATEWAYS = {
    "busbar": "busbar",
    "litellm-rust": "litellm-rust",
    "litellm-python": "litellm-python",
    "bifrost": "bifrost",
    "portkey": "portkey",
}
PROFILES = ("claude_code", "codex")


def _total_seconds(path: Path) -> float | None:
    if not path.exists():
        return None
    data = json.loads(path.read_text())
    ms = data.get("total_wall_time_ms")
    return None if ms is None else ms / 1000.0


def main() -> None:
    direct = {p: _total_seconds(RESULTS / f"session_{p}_direct.json") for p in PROFILES}
    out: dict[str, dict] = {}
    for gw, suffix in GATEWAYS.items():
        entry: dict[str, dict] = {}
        ok = True
        for p in PROFILES:
            gw_total = _total_seconds(RESULTS / f"session_{p}_{suffix}.json")
            base_total = direct.get(p)
            if gw_total is None or base_total is None:
                ok = False
                break
            entry[p] = {
                "gateway_total_seconds": gw_total,
                "direct_total_seconds": base_total,
                "added_seconds": round(gw_total - base_total, 6),
            }
        if ok:
            out[gw] = entry
    (RESULTS / "session_overhead.json").write_text(json.dumps(out, indent=2) + "\n")
    print(f"wrote session_overhead.json ({len(out)} gateways)")


if __name__ == "__main__":
    main()
