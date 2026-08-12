from __future__ import annotations

import csv
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

RESULTS = Path(__file__).resolve().parent.parent / "results"
OUT = Path(__file__).resolve().parent
WINNER_COLOR = "#00b34a"
OTHER_COLOR = "#3a3f4b"
# Busbar is the measured winner on this fork; it is highlighted green. Added by GetBusbar.
WINNER = "busbar"
SERIES_STYLES = {
    "busbar": ("#00b34a", "*", "-"),
    "litellm-rust": ("#0072B2", "o", "--"),
    "litellm-python": ("#E69F00", "s", "--"),
    "bifrost": ("#D55E00", "^", "-."),
    "portkey": ("#6A3D9A", "D", ":"),
}
GATEWAYS = {
    "busbar": "Busbar",
    "litellm-rust": "LiteLLM (Rust)",
    "litellm-python": "LiteLLM (Python v1)",
    "bifrost": "Bifrost",
    "portkey": "Portkey",
}


def _colors_by_rank(values: list[float], best: str = "min") -> list[str]:
    """Green goes to whichever gateway MEASURED best on this metric (won by the data).

    best='min' → lowest value wins (latency, RSS, cost); best='max' → highest wins (throughput).
    """
    if not values:
        return []
    target = min(values) if best == "min" else max(values)
    return [WINNER_COLOR if v == target else OTHER_COLOR for v in values]


def _csv(name: str) -> list[dict[str, str]]:
    with (RESULTS / name).open(newline="") as file:
        return list(csv.DictReader(file))


def _present(name: str) -> list[str]:
    """Gateway keys (in canonical GATEWAYS order) that actually have a row in the CSV."""
    have = {row["gateway"] for row in _csv(name)}
    return [key for key in GATEWAYS if key in have]


def session_chart() -> None:
    data = {row["gateway"]: row for row in _csv("session_overhead.csv")}
    keys = _present("session_overhead.csv")
    fig, ax = plt.subplots(figsize=(9, 4.8))
    y = list(range(len(keys)))
    height = 0.35
    claude = [float(data[key]["claude_code_added_seconds"]) for key in keys]
    codex = [float(data[key]["codex_added_seconds"]) for key in keys]
    # Green = lowest combined added session time (measured winner).
    combined = [c + x for c, x in zip(claude, codex)]
    colors = _colors_by_rank(combined, "min")
    ax.barh([v - height / 2 for v in y], claude, height=height, color=colors, alpha=0.95, label="Claude Code")
    ax.barh([v + height / 2 for v in y], codex, height=height, color=colors, alpha=0.55, label="Codex-style")
    ax.set_yticks(y, [GATEWAYS[key] for key in keys])
    ax.set_xlabel("Added session wall time (seconds; lower is better)")
    ax.set_title("Whole-session gateway overhead", loc="left", fontweight="bold")
    ax.legend(frameon=False)
    ax.grid(axis="x", alpha=0.2)
    fig.text(0.01, 0.01, "30 deterministic turns; added = gateway total - direct mock total. Gateways run non-streaming for an apples-to-apples session (Rust and Portkey have no /messages streaming path yet).", fontsize=7, color="#777")
    fig.tight_layout(rect=(0, 0.05, 1, 1))
    fig.savefig(OUT / "session_overhead.png", dpi=160, bbox_inches="tight")


def concurrency_chart() -> None:
    data = _csv("latency_vs_concurrency.csv")
    fig, ax = plt.subplots(figsize=(8, 4.8))
    for key in _present("latency_vs_concurrency.csv"):
        rows = [row for row in data if row["gateway"] == key]
        rows.sort(key=lambda row: int(row["concurrency"]))
        ax.plot(
            [int(row["concurrency"]) for row in rows],
            [float(row["p99_added_latency_ms"]) for row in rows],
            label=GATEWAYS[key],
            color=SERIES_STYLES[key][0],
            marker=SERIES_STYLES[key][1],
            linestyle=SERIES_STYLES[key][2],
            linewidth=1.8,
            markersize=6,
        )
    ax.set_xscale("log", base=2)
    ax.set_yscale("symlog", linthresh=1)
    ax.set_xlabel("Concurrency")
    ax.set_ylabel("p99 added latency (ms, symlog)")
    ax.set_title("Tail overhead versus concurrency", loc="left", fontweight="bold")
    ax.grid(True, which="both", alpha=0.2)
    ax.legend(frameon=False)
    fig.text(0.01, 0.01, "n=2000 per point; persistent Rust reqwest driver and fast Rust mock; direct baseline measured at each concurrency. Retained through concurrency 64 because direct p99 stayed within 2x its single-client floor; 256 was dropped. Signed differences are measurements, not speedups.", fontsize=7, color="#777")
    fig.tight_layout(rect=(0, 0.05, 1, 1))
    fig.savefig(OUT / "latency_vs_concurrency.png", dpi=160, bbox_inches="tight")


def cost_chart() -> None:
    data = {row["gateway"]: row for row in _csv("cost_per_million.csv")}
    keys = sorted(_present("cost_per_million.csv"), key=lambda key: float(data[key]["dollars_per_million"]))
    fig, ax = plt.subplots(figsize=(8, 4.5))
    values = [float(data[key]["dollars_per_million"]) for key in keys]
    ax.bar([GATEWAYS[key] for key in keys], values, color=_colors_by_rank(values, "min"))
    ax.set_ylabel("Estimated dollars per 1M requests")
    ax.set_title("Estimated request cost", loc="left", fontweight="bold")
    ax.tick_params(axis="x", rotation=20)
    ax.grid(axis="y", alpha=0.2)
    for index, value in enumerate(values):
        ax.text(index, value, f"USD {value:.6f}", ha="center", va="bottom", fontsize=8)
    fig.text(0.01, 0.01, r"Estimate only. Estimated \$/1M = ((average CPU fraction × \$/vCPU-hour) + (peak RSS in GB × \$/GB-hour)) ÷ sustained throughput, scaled to 1,000,000 requests. Rates: \$0.04/vCPU-hour and \$0.005/GB-hour; assumes 4 vCPU and 16 GB.", fontsize=7, color="#777")
    fig.tight_layout(rect=(0, 0.05, 1, 1))
    fig.savefig(OUT / "cost_per_million.png", dpi=160, bbox_inches="tight")


def ttft_chart() -> None:
    data = {row["gateway"]: row for row in _csv("ttft_overhead.csv")}
    keys = _present("ttft_overhead.csv")
    values = [float(data[key]["p50_added_ttft_ms"] or 0) for key in keys]
    # Green = lowest added TTFT among gateways that actually stream (available=true).
    avail = [float(data[key]["p50_added_ttft_ms"] or 0) for key in keys if data[key]["available"].lower() == "true"]
    best = min(avail) if avail else None
    colors = [WINNER_COLOR if (data[key]["available"].lower() == "true" and float(data[key]["p50_added_ttft_ms"] or 0) == best) else OTHER_COLOR for key in keys]
    fig, ax = plt.subplots(figsize=(8, 4.5))
    ax.bar([GATEWAYS[key] for key in keys], values, color=colors)
    ax.set_ylabel("Added TTFT (ms; lower is better)")
    ax.set_title("Streaming time-to-first-token overhead", loc="left", fontweight="bold")
    ax.tick_params(axis="x", rotation=20)
    ax.grid(axis="y", alpha=0.2)
    for index, key in enumerate(keys):
        if data[key]["available"].lower() != "true":
            reason = "no SSE streaming yet\nroute returns 502" if key == "litellm-rust" else "no SSE streaming yet\nOSS returns 500"
            ax.text(index, 0, reason, ha="center", va="bottom", fontsize=8)
    fig.text(0.01, 0.01, "n=100, concurrency 16; fast Rust mock baseline. Rust and Portkey are unavailable because their streaming routes return 502 and 500. Signed differences reflect measurement noise, not speedups.", fontsize=7, color="#777")
    fig.tight_layout(rect=(0, 0.05, 1, 1))
    fig.savefig(OUT / "ttft_overhead.png", dpi=160, bbox_inches="tight")


def rps_chart() -> None:
    data = [row for row in _csv("rps_per_dollar.csv") if row["gateway"] in GATEWAYS]
    data.sort(key=lambda row: float(row["rps_per_dollar"]))
    labels = [GATEWAYS[row["gateway"]] for row in data]
    values = [float(row["rps_per_dollar"]) for row in data]
    colors = _colors_by_rank(values, "max")  # highest RPS/$ wins
    fig, ax = plt.subplots(figsize=(8, 4.5))
    bars = ax.bar(labels, values, color=colors)
    ax.set_ylabel("Estimated sustained RPS per USD/hour")
    ax.set_title("Estimated throughput efficiency", loc="left", fontweight="bold")
    ax.tick_params(axis="x", rotation=20)
    ax.grid(axis="y", alpha=0.2)
    for bar, value in zip(bars, values):
        ax.text(bar.get_x() + bar.get_width() / 2, value, f"{value:,.0f}", ha="center", va="bottom", fontsize=8)
    fig.text(0.01, 0.01, "Estimate only. Ceiling is the highest retained baseline-controlled point with zero errors and p99 under 1,000 ms. Hourly cost uses measured CPU and peak RSS with 4 vCPU at USD 0.04/hour and 16 GB at USD 0.005/GB-hour.", fontsize=7, color="#777")
    fig.tight_layout(rect=(0, 0.05, 1, 1))
    fig.savefig(OUT / "rps_per_dollar.png", dpi=160, bbox_inches="tight")


if __name__ == "__main__":
    session_chart()
    concurrency_chart()
    cost_chart()
    ttft_chart()
    rps_chart()
