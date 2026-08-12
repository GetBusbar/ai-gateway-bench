"""Streaming TTFT probe: N streaming requests at concurrency C, record time-to-first-token.

Writes {"available": bool, "count": N, "errors": M, "ttft_p50_ms":, "ttft_p99_ms":, ...}.
A gateway whose streaming route errors (5xx/4xx) is recorded available=false with the error
count — NOT fabricated. Added by GetBusbar (busbar fork).

  python bench/streaming_probe.py --url URL --model M --output OUT [--count 100] [--concurrency 16] [--header "k: v"]...
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common.sse import stream_request


def _one(url: str, model: str, headers: dict[str, str]) -> tuple[float | None, str | None]:
    body = {
        "model": model,
        "max_tokens": 40,
        "stream": True,
        "messages": [{"role": "user", "content": "token " * 32}],
    }
    with httpx.Client(timeout=60) as client:
        m = stream_request(client, url, body, name="ttft", headers=headers)
    if m.error or m.status_code >= 400:
        return None, (m.error or f"HTTP {m.status_code}")
    return m.ttft_ms, None


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--model", default="anthropic/mock")
    ap.add_argument("--output", required=True)
    ap.add_argument("--count", type=int, default=100)
    ap.add_argument("--concurrency", type=int, default=16)
    ap.add_argument("--header", action="append", default=[])
    args = ap.parse_args()
    headers: dict[str, str] = {}
    for h in args.header:
        k, _, v = h.partition(":")
        headers[k.strip()] = v.strip()

    ttfts: list[float] = []
    errors: list[str] = []
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        for ttft, err in pool.map(lambda _: _one(args.url, args.model, headers), range(args.count)):
            if err:
                errors.append(err)
            elif ttft is not None:
                ttfts.append(ttft)

    ttfts.sort()
    available = len(ttfts) > 0 and len(errors) == 0
    out = {
        "url": args.url,
        "available": available,
        "count": args.count,
        "errors": len(errors),
        "error_sample": errors[:2],
        "ttft_p50_ms": round(statistics.median(ttfts), 3) if ttfts else None,
        "ttft_p99_ms": round(ttfts[int(len(ttfts) * 0.99) - 1], 3) if ttfts else None,
    }
    Path(args.output).write_text(json.dumps(out, indent=2) + "\n")
    print(out)


if __name__ == "__main__":
    main()
