"""Quant research agent: CLI handlers (python -m agents quant <command>).

  ingest   raw Alpaca bars (with VWAP) for the quant universe -> raw store,
           then the Qlib bin store (calendar, instruments, OHLCV + vwap +
           factor + the 14 legacy sst_* features)
  status   agent status, raw store and Qlib store summary (no network)
Exit codes: 0 ok, 1 error, 2 data unavailable. Never prints a key value.
"""

from __future__ import annotations

import argparse
from typing import Any, Dict, List

AGENT = "quant"
MISSING_SESSIONS_WARN = 5


def _store_summary(meta) -> Dict[str, Any]:
    from agents.quant.store import store_dir

    if not meta:
        return {"dir": str(store_dir()), "built": False}
    missing = meta.get("missing_sessions") or {}
    return {
        "dir": str(store_dir()), "built": True, "built_at": meta.get("built_at"),
        "sessions": meta.get("sessions"),
        "calendar_start": meta.get("calendar_start"), "calendar_end": meta.get("calendar_end"),
        "instruments": meta.get("instruments"), "rank_instruments": meta.get("rank_instruments"),
        "data_sources": _count(meta.get("data_sources") or {}),
        "synthetic": bool(meta.get("synthetic")),
        "missing_sessions_over_5": sorted(s for s, n in missing.items() if int(n) > MISSING_SESSIONS_WARN),
    }


def _count(by_symbol: Dict[str, str]) -> Dict[str, int]:
    out: Dict[str, int] = {}
    for label in by_symbol.values():
        out[label] = out.get(label, 0) + 1
    return out


def ingest_and_build(symbols: List[str], rank: List[str], bench: List[str], start, end,
                     refresh: bool, offline: bool, client=None) -> Dict[str, Any]:
    """raw.ingest + store.build_store; {'raw', 'store', 'built'}."""
    from agents.data.bars import BarsResult
    from agents.quant import raw, store

    summary = raw.ingest(symbols, start=start or raw.DEFAULT_START, end=end, refresh=refresh,
                         client=client, offline=offline)
    bars = raw.load_raw(symbols)
    available = {s: r for s, r in bars.items() if isinstance(r, BarsResult)}
    if not any(s in available for s in rank):
        return {"raw": summary, "store": _store_summary(store.read_store_meta()), "built": False}
    meta = store.build_store(available, rank, bench)
    return {"raw": summary, "store": _store_summary(meta), "built": True}


def cli_ingest(args: argparse.Namespace) -> int:
    from agents.cli import EXIT_ERROR, EXIT_OK, EXIT_UNAVAILABLE, emit, parse_symbols
    from agents.fixtures import is_offline
    from agents.quant import universe

    offline = bool(getattr(args, "offline", False)) or is_offline()
    try:
        requested = parse_symbols(getattr(args, "symbols", None))
    except ValueError as exc:
        emit({"error": "invalid_symbol", "detail": str(exc)})
        return EXIT_ERROR
    bench_all = universe.benchmarks(offline)
    if requested:
        rank = [s for s in requested if s not in bench_all]
        bench = [s for s in requested if s in bench_all]
        symbols = requested
    else:
        rank, bench = universe.rank_universe(offline), bench_all
        symbols = rank + bench
    out = ingest_and_build(symbols, rank, bench, getattr(args, "start", None), getattr(args, "end", None),
                           bool(getattr(args, "refresh", False)), offline)
    built = out.pop("built")
    if not built:
        out["error"] = "market_data_unavailable"
        out["detail"] = "no rank symbol had bars; the Qlib store was not changed"
        emit(out)
        return EXIT_UNAVAILABLE
    emit(out)
    return EXIT_OK


def status() -> Dict[str, Any]:
    from agents.quant import raw, store

    return {
        "raw": raw.raw_status(),
        "store": _store_summary(store.read_store_meta()),
        # filled in by later Phase 2 steps (train / predict / evaluate)
        "models": None, "predictions": None, "evaluation": None,
    }


def cli_status(args: argparse.Namespace) -> int:
    from agents.cli import EXIT_OK, emit, status_payload

    out = status_payload(AGENT)
    out.update(status())
    emit(out)
    return EXIT_OK
