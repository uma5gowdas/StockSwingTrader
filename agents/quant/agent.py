"""Quant research agent: CLI handlers (python -m agents quant <command>).

  ingest   raw Alpaca bars (with VWAP) for the quant universe -> raw store,
           then the Qlib bin store (calendar, instruments, OHLCV + vwap +
           factor + the 14 legacy sst_* features)
  train    train the model arms (lgbm, xgb14, xgb_full) on rolling folds +
           the live model (agents/quant/train.py); --arms, --offline
  predict  live model -> one envelope per rank symbol in
           cache/agents/quant/<as_of>/<SYM>.json (agents/quant/predict.py);
           --as-of, --symbols, --offline, --arms (first item)
  evaluate IC metrics per arm, gates xgb_topk / quant_topk (rank universe)
           and quant_rank (Phase 1 universe), go / no-go and a JSON + HTML
           report (agents/quant/evaluate.py); --offline, --report-dir, --start
  status   agent status, raw store, Qlib store, models, predictions, the
           latest envelopes, the latest evaluation and the quant gates (no
           network, no qlib import)
Exit codes: 0 ok, 1 error, 2 data / store / model unavailable. Never prints a
key value. Qlib, LightGBM and xgboost write progress to stdout; train and
predict send it to stderr so stdout stays one JSON document.
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
        "ohlc_anomaly_bars": sum(len(v) for v in (meta.get("ohlc_anomalies") or {}).values()),
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


def _quiet_stdout():
    import contextlib
    import sys

    return contextlib.redirect_stdout(sys.stderr)


def cli_train(args: argparse.Namespace) -> int:
    from agents.cli import EXIT_ERROR, EXIT_OK, EXIT_UNAVAILABLE, emit
    from agents.fixtures import is_offline
    from agents.quant.train import StoreUnavailable, parse_arms, run_train

    offline = bool(getattr(args, "offline", False)) or is_offline()
    try:
        arms = parse_arms(getattr(args, "arms", None))
    except ValueError as exc:
        emit({"error": "invalid_arms", "detail": str(exc)})
        return EXIT_ERROR
    try:
        with _quiet_stdout():
            summary = run_train(arms, offline=offline)
    except StoreUnavailable as exc:
        emit({"error": "store_unavailable", "detail": str(exc)})
        return EXIT_UNAVAILABLE
    emit(summary)
    return EXIT_OK


def cli_predict(args: argparse.Namespace) -> int:
    from agents.cli import EXIT_ERROR, EXIT_OK, EXIT_UNAVAILABLE, emit, parse_symbols
    from agents.fixtures import is_offline
    from agents.quant.predict import PredictionsUnavailable, run_predict
    from agents.quant.train import StoreUnavailable, parse_arms

    offline = bool(getattr(args, "offline", False)) or is_offline()
    try:
        syms = parse_symbols(getattr(args, "symbols", None))
        arm = parse_arms(getattr(args, "arms", None) or "lgbm")[0]
    except ValueError as exc:
        emit({"error": "invalid_argument", "detail": str(exc)})
        return EXIT_ERROR
    try:
        with _quiet_stdout():
            out = run_predict(as_of=getattr(args, "as_of", None), offline=offline, symbols=syms or None, arm=arm)
    except StoreUnavailable as exc:
        emit({"error": "store_unavailable", "detail": str(exc)})
        return EXIT_UNAVAILABLE
    except PredictionsUnavailable as exc:
        emit({"error": "predictions_unavailable", "detail": str(exc)})
        return EXIT_UNAVAILABLE
    emit(out)
    return EXIT_OK if out["written"] else EXIT_UNAVAILABLE


def _models_summary() -> Any:
    from datetime import date

    from agents.quant.train import read_latest

    m = read_latest()
    if not m:
        return None
    arms = {}
    for arm, info in (m.get("arms") or {}).items():
        end = (info.get("live") or {}).get("train_end")
        arms[arm] = {"live_train_end": end, "folds": len(info.get("folds") or []),
                     "n_features": info.get("n_features"),
                     "age_days": (date.today() - date.fromisoformat(end)).days if end else None}
    return {"train_run_id": m.get("train_run_id"), "generated_at": m.get("generated_at"),
            "mode": m.get("mode"), "synthetic": m.get("synthetic"), "arms": arms}


def _predictions_summary() -> Any:
    from agents.quant.train import predictions_dir

    base = predictions_dir()
    files = sorted(base.glob("*.parquet")) if base.is_dir() else []
    if not files:
        return None
    import pandas as pd

    out = {}
    for p in files:
        try:
            df = pd.read_parquet(p, columns=["datetime"])
            dts = pd.to_datetime(df["datetime"])
            out[p.stem] = {"file": str(p), "rows": int(len(df)),
                           "start": dts.min().strftime("%Y-%m-%d") if len(df) else None,
                           "end": dts.max().strftime("%Y-%m-%d") if len(df) else None}
        except Exception as exc:  # unreadable file: report, do not fail status
            out[p.stem] = {"file": str(p), "error": type(exc).__name__}
    return out


def _envelopes_summary() -> Any:
    import re

    from agents.cache import cache_root

    base = cache_root() / AGENT
    dirs = sorted(p for p in base.iterdir() if p.is_dir() and re.fullmatch(r"\d{4}-\d{2}-\d{2}", p.name)) \
        if base.is_dir() else []
    if not dirs:
        return None
    return {"latest_as_of": dirs[-1].name, "count": len(list(dirs[-1].glob("*.json"))),
            "as_of_dirs": len(dirs)}


def status() -> Dict[str, Any]:
    from agents.quant import raw, store

    return {
        "raw": raw.raw_status(),
        "store": _store_summary(store.read_store_meta()),
        "models": _models_summary(),
        "predictions": _predictions_summary(),
        "envelopes": _envelopes_summary(),
        "evaluation": _evaluation_summary(),
        "gates": _gates_summary(),
    }


def _evaluation_summary() -> Any:
    from agents.quant.evaluate import latest_evaluation

    return latest_evaluation()


QUANT_GATES = ("quant_topk", "xgb_topk", "quant_rank")


def _gates_summary() -> Dict[str, Any]:
    from datetime import datetime, timezone

    from agents.cache import gate_path, read_json

    out: Dict[str, Any] = {}
    now = datetime.now(timezone.utc)
    for sid in QUANT_GATES:
        g = read_json(gate_path(sid))
        if not isinstance(g, dict):
            out[sid] = None
            continue
        age = None
        try:
            t = datetime.strptime(g.get("generated_at", ""), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            age = round((now - t).total_seconds() / 86400.0, 2)
        except (TypeError, ValueError):
            pass
        out[sid] = {"passed": g.get("passed"), "synthetic": g.get("synthetic"), "age_days": age,
                    "run_id": g.get("run_id")}
    return out


def cli_evaluate(args: argparse.Namespace) -> int:
    from agents.cli import EXIT_ERROR, emit
    from agents.fixtures import is_offline
    from agents.quant.evaluate import run_evaluate
    from agents.validate.agent import _is_date

    offline = bool(getattr(args, "offline", False)) or is_offline()
    start = getattr(args, "start", None)
    if start and not _is_date(start):
        emit({"error": "invalid_date", "detail": "use YYYY-MM-DD", "value": start})
        return EXIT_ERROR
    with _quiet_stdout():
        res = run_evaluate(offline=offline, report_dir=getattr(args, "report_dir", None), start=start)
    emit(res["summary"])
    return int(res["exit"])


def cli_status(args: argparse.Namespace) -> int:
    from agents.cli import EXIT_OK, emit, status_payload

    out = status_payload(AGENT)
    out.update(status())
    emit(out)
    return EXIT_OK
