"""Quant raw-bar store (plan Q3): cache_root()/quant/raw/<SYM>.csv + .meta.json.

  csv   date,open,high,low,close,volume,vwap (daily, adjustment=all)
  meta  {symbol, data_source, synthetic, warning, adjustment, feed, start,
         end, first_bar, last_bar, rows, fetched_at, bars_sha12}

Real data: one AlpacaBarsClient(include_vwap=True, use_cache=False) per
ingest (assert_paper() runs in its __init__; GET only). The full history is
refetched per symbol (adjustment=all back-adjusts on every dividend, so
appending would mix price bases). Resume: a symbol whose meta has the same
start, end and adjustment and rows > 0 is skipped unless refresh=True. Bars
are fetched in batches; each batch's files are written before the next batch,
so a failed batch does not lose finished symbols (their old files are kept).

Offline (SST_OFFLINE=1 or offline=True): generated fixtures, vwap = typical
price, data_source 'fixture', synthetic True + FIXTURE_WARNING.
"""

from __future__ import annotations

import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Union

import pandas as pd

from agents.cache import atomic_write_json, cache_root, check_symbol, read_json
from agents.config import SafetyError
from agents.data.alpaca import _parse_date, expected_last_session, ny_today
from agents.data.bars import BarsResult, Unavailable
from agents.fixtures import FIXTURE_WARNING, is_offline, load_fixture_bars

DEFAULT_START = "2016-01-01"
RAW_COLUMNS = ["open", "high", "low", "close", "volume", "vwap"]
OFFLINE_ADJUSTMENT = "fixture"


def raw_dir() -> Path:
    return cache_root() / "quant" / "raw"


def _paths(symbol: str):
    check_symbol(symbol)
    base = raw_dir() / symbol
    return Path(str(base) + ".csv"), Path(str(base) + ".meta.json")


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _write_symbol(symbol: str, res: BarsResult, adjustment: str, start: str, end: str) -> dict:
    from agents.signals.base import bars_hash

    csv_path, meta_path = _paths(symbol)
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    df = res.df.copy()
    if "vwap" not in df.columns:
        df["vwap"] = (df["high"] + df["low"] + df["close"]) / 3.0
    df = df[RAW_COLUMNS].astype(float)
    tmp = Path(str(csv_path) + ".tmp.%d" % os.getpid())
    try:
        df.to_csv(tmp, index_label="date", date_format="%Y-%m-%d")
        os.replace(tmp, csv_path)
    finally:
        if tmp.exists():
            tmp.unlink()
    label = res.data_source
    meta = {
        "symbol": symbol, "data_source": label, "synthetic": bool(res.synthetic), "warning": res.warning,
        "adjustment": adjustment, "feed": label.split(":", 1)[1] if label.startswith("alpaca:") else label,
        "start": start, "end": end,
        "first_bar": df.index[0].strftime("%Y-%m-%d"), "last_bar": df.index[-1].strftime("%Y-%m-%d"),
        "rows": int(len(df)), "fetched_at": _now_iso(), "bars_sha12": bars_hash(df),
    }
    atomic_write_json(meta_path, meta)
    return meta


def read_meta(symbol: str) -> Optional[dict]:
    meta = read_json(_paths(symbol)[1])
    return meta if isinstance(meta, dict) else None


def _is_current(symbol: str, meta: Optional[dict], start: str, end: str, adjustment: str) -> bool:
    if not meta or not _paths(symbol)[0].is_file():
        return False
    try:
        return (meta.get("start") == start and meta.get("end") == end
                and meta.get("adjustment") == adjustment and int(meta.get("rows") or 0) > 0)
    except (TypeError, ValueError):
        return False


def _offline_bars(symbol: str, start: str, end: str) -> Union[BarsResult, Unavailable]:
    df = load_fixture_bars(symbol)
    if df is None:
        return Unavailable("no fixture for %s" % symbol)
    df = df[(df.index >= pd.Timestamp(start)) & (df.index <= pd.Timestamp(end))].copy()
    if not len(df):
        return Unavailable("no fixture bars in range")
    df["vwap"] = (df["high"] + df["low"] + df["close"]) / 3.0
    return BarsResult(df, "fixture", True, FIXTURE_WARNING)


def ingest(symbols: Iterable[str], start: str = DEFAULT_START, end=None, refresh: bool = False,
           client=None, batch: int = 25, offline: bool = False) -> dict:
    """Fetch SYMBOLS into the raw store; returns a summary dict:
    {requested, fetched, skipped, unavailable{SYM: reason}, requests_made,
     data_sources{label: n}, synthetic, start, end, raw_dir}."""
    syms = [check_symbol(s) for s in symbols]
    offline = bool(offline) or is_offline()
    start_s = _parse_date(start or DEFAULT_START).isoformat()
    end_s = _parse_date(end).isoformat() if end else expected_last_session(ny_today()).isoformat()

    if offline:
        adjustment = OFFLINE_ADJUSTMENT
    else:
        if client is None:
            from agents.data.alpaca import AlpacaBarsClient

            client = AlpacaBarsClient(include_vwap=True, use_cache=False)  # SafetyError propagates
        adjustment = getattr(client, "adjustment", "all")

    fetched: List[str] = []
    skipped: List[str] = []
    unavailable: Dict[str, str] = {}
    todo = []
    for s in syms:
        if not refresh and _is_current(s, read_meta(s), start_s, end_s, adjustment):
            skipped.append(s)
        else:
            todo.append(s)

    for i in range(0, len(todo), max(int(batch), 1)):
        chunk = todo[i:i + max(int(batch), 1)]
        if offline:
            results = {s: _offline_bars(s, start_s, end_s) for s in chunk}
        else:
            try:
                results = client.fetch(chunk, start_s, end_s, as_of=end_s)
            except SafetyError:
                raise
            except Exception as exc:  # keep finished batches; report this one
                results = {s: Unavailable("fetch_failed: %s" % type(exc).__name__) for s in chunk}
        for s in chunk:
            res = results.get(s)
            if isinstance(res, BarsResult) and len(res.df):
                _write_symbol(s, res, adjustment, start_s, end_s)
                fetched.append(s)
            else:
                unavailable[s] = getattr(res, "reason", None) or "no_bars"

    data_sources: Dict[str, int] = {}
    synthetic = False
    for s in fetched + skipped:
        meta = read_meta(s) or {}
        label = meta.get("data_source") or "unknown"
        data_sources[label] = data_sources.get(label, 0) + 1
        synthetic = synthetic or bool(meta.get("synthetic"))
    return {
        "requested": len(syms), "fetched": len(fetched), "skipped": len(skipped),
        "fetched_symbols": fetched, "skipped_symbols": skipped, "unavailable": unavailable,
        "requests_made": int(getattr(client, "requests_made", 0) or 0) if not offline else 0,
        "data_sources": data_sources, "synthetic": synthetic,
        "start": start_s, "end": end_s, "adjustment": adjustment, "raw_dir": str(raw_dir()),
    }


def load_raw(symbols: Iterable[str]) -> Dict[str, Union[BarsResult, Unavailable]]:
    """{SYM: BarsResult (columns open..volume, vwap) | Unavailable('not_ingested')}."""
    out: Dict[str, Union[BarsResult, Unavailable]] = {}
    for s in symbols:
        check_symbol(s)
        csv_path, _ = _paths(s)
        meta = read_meta(s)
        if meta is None or not csv_path.is_file():
            out[s] = Unavailable("not_ingested")
            continue
        try:
            df = pd.read_csv(csv_path, parse_dates=["date"]).set_index("date").sort_index()[RAW_COLUMNS].astype(float)
        except (OSError, ValueError, KeyError):
            out[s] = Unavailable("raw_unreadable")
            continue
        out[s] = BarsResult(df, meta.get("data_source") or "unknown", bool(meta.get("synthetic")), meta.get("warning"))
    return out


def raw_status() -> dict:
    """Summary of the raw store (no network)."""
    base = raw_dir()
    metas = []
    if base.is_dir():
        for p in sorted(base.glob("*.meta.json")):
            m = read_json(p)
            if isinstance(m, dict):
                metas.append(m)
    sources: Dict[str, int] = {}
    for m in metas:
        label = m.get("data_source") or "unknown"
        sources[label] = sources.get(label, 0) + 1
    ends = sorted({m.get("end") for m in metas if m.get("end")})
    return {
        "raw_dir": str(base), "symbols": len(metas), "data_sources": sources,
        "synthetic": any(bool(m.get("synthetic")) for m in metas),
        "ends": ends, "last_fetched_at": max((m.get("fetched_at") or "" for m in metas), default=None) or None,
    }
