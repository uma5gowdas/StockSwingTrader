"""Qlib binary store writer (plan Q5), same format as qlib/scripts/dump_bin.py.

store_dir() = cache_root()/quant/qlib_data:
  calendars/day.txt                 one YYYY-MM-DD per line (union of all bar dates)
  instruments/all.txt               SYMBOL<TAB>start<TAB>end (every symbol)
  instruments/sst_us.txt            same, rank symbols only (the cross-section)
  features/<sym lower>/<field>.day.bin
                                    little-endian float32; first value = the
                                    calendar index of the symbol's first bar,
                                    then one value per session up to its last
                                    bar (missing sessions NaN)
  store_meta.json                   {built_at, calendar range, sessions,
                                    instruments, fields, data_sources, synthetic,
                                    bars_sha12, missing_sessions,
                                    ohlc_anomalies (implausible bars,
                                    listed, not changed), ...}
Fields: open, high, low, close, volume, vwap, factor (1.0: prices are already
adjusted, adjustment=all) and the 14 legacy features sst_<name>.

The store is built in qlib_data.tmp-<pid> and swapped in: the current store
becomes qlib_data.prev (an older .prev is deleted first). On error the tmp
dir is removed and the current store is untouched.
"""

from __future__ import annotations

import os
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Optional

import numpy as np
import pandas as pd

from agents.cache import atomic_write_json, cache_root, check_symbol, read_json
from agents.quant.legacy_features import SST_COLUMNS, legacy_feature_frame

PRICE_FIELDS = ("open", "high", "low", "close", "volume", "vwap", "factor")
FIELDS = PRICE_FIELDS + SST_COLUMNS
FREQ = "day"
RANK_MARKET = "sst_us"
# ohlc_anomalies thresholds (relative to the open/close body)
OHLC_HIGH_MULT = 1.25
OHLC_LOW_MULT = 0.8
# qlib.utils.code_to_fname: Windows device names get this prefix
_RESERVED = {"CON", "PRN", "AUX", "NUL"} | {"COM%d" % i for i in range(10)} | {"LPT%d" % i for i in range(10)}


def store_dir() -> Path:
    return cache_root() / "quant" / "qlib_data"


def instrument_dirname(symbol: str) -> str:
    """Feature dir name Qlib looks up for SYMBOL (code_to_fname + lower)."""
    code = "_qlib_" + symbol if symbol.upper() in _RESERVED else symbol
    return code.lower()


def _write_bin(path: Path, start_index: int, values: np.ndarray) -> None:
    np.hstack([[start_index], values]).astype("<f").tofile(str(path))


def ohlc_anomalies(df: pd.DataFrame) -> List[dict]:
    """Bars with an implausible print: high > OHLC_HIGH_MULT x max(open, close)
    or low < OHLC_LOW_MULT x min(open, close). Detection only: the bars are
    stored unchanged and listed in store_meta.json (review finding: bad SIP
    prints; clipping would change every downstream number, deferred)."""
    body_hi = df[["open", "close"]].max(axis=1)
    body_lo = df[["open", "close"]].min(axis=1)
    bad = (df["high"] > OHLC_HIGH_MULT * body_hi) | (df["low"] < OHLC_LOW_MULT * body_lo)
    out: List[dict] = []
    for ts, row in df[bad].iterrows():
        out.append({"date": pd.Timestamp(ts).strftime("%Y-%m-%d"),
                    **{k: round(float(row[k]), 4) for k in ("open", "high", "low", "close")}})
    return out


def _instrument_lines(spans: Dict[str, tuple], symbols: Iterable[str]) -> str:
    return "".join("%s\t%s\t%s\n" % (s, spans[s][0], spans[s][1]) for s in symbols if s in spans)


def build_store(bars: Dict[str, object], rank_symbols: Iterable[str], benchmark_symbols: Iterable[str]) -> dict:
    """Write the Qlib store from BARS {SYM: BarsResult} (other values are
    ignored). Returns the store meta (also written to store_meta.json)."""
    from agents.data.bars import BarsResult
    from agents.signals.base import bars_hash

    usable = {check_symbol(s): r for s, r in bars.items() if isinstance(r, BarsResult) and len(r.df)}
    rank = [s for s in rank_symbols if s in usable]
    bench = [s for s in benchmark_symbols if s in usable and s not in rank]
    symbols = rank + bench + sorted(s for s in usable if s not in rank and s not in bench)
    if not symbols:
        raise ValueError("no bars to build the quant store from")

    calendar = sorted(set().union(*[set(pd.DatetimeIndex(usable[s].df.index).normalize()) for s in symbols]))
    cal_index = pd.DatetimeIndex(calendar)
    pos = {d: i for i, d in enumerate(cal_index)}

    final = store_dir()
    final.parent.mkdir(parents=True, exist_ok=True)
    tmp = final.parent / ("qlib_data.tmp-%d" % os.getpid())
    prev = final.parent / "qlib_data.prev"
    if tmp.exists():
        shutil.rmtree(tmp)
    try:
        (tmp / "calendars").mkdir(parents=True)
        (tmp / "instruments").mkdir()
        (tmp / "features").mkdir()
        (tmp / "calendars" / ("%s.txt" % FREQ)).write_text(
            "".join(d.strftime("%Y-%m-%d") + "\n" for d in cal_index), encoding="utf-8")

        spans: Dict[str, tuple] = {}
        data_sources: Dict[str, str] = {}
        hashes: Dict[str, str] = {}
        missing: Dict[str, int] = {}
        anomalies: Dict[str, List[dict]] = {}
        synthetic = False
        for s in symbols:
            res = usable[s]
            df = res.df.copy()
            df.index = pd.DatetimeIndex(df.index).normalize()
            df = df[~df.index.duplicated(keep="last")].sort_index()
            if "vwap" not in df.columns:
                df["vwap"] = (df["high"] + df["low"] + df["close"]) / 3.0
            frame = df[["open", "high", "low", "close", "volume", "vwap"]].astype(float)
            frame["factor"] = 1.0
            frame = frame.join(legacy_feature_frame(df))
            first, last = frame.index[0], frame.index[-1]
            span = cal_index[pos[first]:pos[last] + 1]
            frame = frame.reindex(span)
            missing[s] = int(len(span) - len(df))
            bad = ohlc_anomalies(df)
            if bad:
                anomalies[s] = bad
            fdir = tmp / "features" / instrument_dirname(s)
            fdir.mkdir(parents=True)
            for field in FIELDS:
                _write_bin(fdir / ("%s.%s.bin" % (field.lower(), FREQ)), pos[first], frame[field].to_numpy(dtype=float))
            spans[s] = (first.strftime("%Y-%m-%d"), last.strftime("%Y-%m-%d"))
            data_sources[s] = res.data_source
            hashes[s] = bars_hash(df)
            synthetic = synthetic or bool(res.synthetic)

        (tmp / "instruments" / "all.txt").write_text(_instrument_lines(spans, symbols), encoding="utf-8")
        (tmp / "instruments" / ("%s.txt" % RANK_MARKET)).write_text(_instrument_lines(spans, rank), encoding="utf-8")
        meta = {
            "built_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "calendar_start": cal_index[0].strftime("%Y-%m-%d"),
            "calendar_end": cal_index[-1].strftime("%Y-%m-%d"),
            "sessions": int(len(cal_index)),
            "instruments": len(symbols), "rank_instruments": len(rank),
            "rank_symbols": rank, "benchmarks": bench, "market": RANK_MARKET,
            "fields": list(FIELDS), "data_sources": data_sources, "synthetic": synthetic,
            "bars_sha12": hashes, "missing_sessions": missing,
            "ohlc_anomalies": anomalies,
            "ohlc_anomaly_rule": "high > %s x max(open, close) or low < %s x min(open, close); stored unchanged"
                                 % (OHLC_HIGH_MULT, OHLC_LOW_MULT),
            "spans": {s: list(v) for s, v in spans.items()},
        }
        atomic_write_json(tmp / "store_meta.json", meta)

        if final.exists():
            if prev.exists():
                shutil.rmtree(prev)
            os.replace(final, prev)
        os.replace(tmp, final)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    return meta


def read_store_meta() -> Optional[dict]:
    meta = read_json(store_dir() / "store_meta.json")
    return meta if isinstance(meta, dict) else None
