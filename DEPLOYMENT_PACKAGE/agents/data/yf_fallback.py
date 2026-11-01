"""Opt-in yfinance fallback (AGENT_DATA_FALLBACK=yfinance; yfinance is not in
requirements-agents.txt). Results are labeled data_source 'yfinance' with the
warning 'fallback source'."""

from __future__ import annotations

import importlib.util
import os
from datetime import timedelta

import pandas as pd

WARNING = "fallback source"


def is_enabled() -> bool:
    """True only with AGENT_DATA_FALLBACK=yfinance and yfinance importable."""
    if (os.environ.get("AGENT_DATA_FALLBACK") or "none").strip().lower() != "yfinance":
        return False
    return importlib.util.find_spec("yfinance") is not None


def fetch(symbol: str, start, end):
    """Daily bars START..END (inclusive) as a DataFrame, or None."""
    try:
        import yfinance as yf

        end_excl = (pd.Timestamp(end) + timedelta(days=1)).strftime("%Y-%m-%d")
        df = yf.download(symbol, start=pd.Timestamp(start).strftime("%Y-%m-%d"), end=end_excl,
                         interval="1d", progress=False, auto_adjust=True)
    except Exception:
        return None
    if df is None or len(df) == 0:
        return None
    if isinstance(df.columns, pd.MultiIndex):
        df.columns = df.columns.get_level_values(0)
    try:
        df = df.rename(columns=str.lower)[["open", "high", "low", "close", "volume"]].dropna().astype(float)
    except KeyError:
        return None
    df.index = pd.DatetimeIndex(pd.to_datetime(df.index).date, name="date")
    return df if len(df) else None
