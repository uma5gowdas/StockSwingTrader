"""Benchmarks over the walk-forward test windows (same fills as the gate).

spy_buy_hold(spy_df, dates, slippage)
    Buy at the open of the first date with slippage, hold, sell at the close
    of the last date with slippage. Daily returns on DATES:
    r_0 = close_0 / (open_0 (1 + s)) - 1, r_t = close_t / close_{t-1} - 1,
    and the last day additionally x (1 - s).
equal_weight_buy_hold(bars, dates, slippage)
    Equal dollars in every symbol at the open of the first date (same fills),
    no rebalancing; portfolio value = mean of the per-symbol value paths
    (closes forward-filled over missing days).
Both return a daily returns Series on DATES. The pooled benchmark is the
concatenation over the test folds, like the strategy.
"""

from __future__ import annotations

from typing import Dict

import numpy as np
import pandas as pd


def _value_path(df: pd.DataFrame, dates: pd.DatetimeIndex, slippage: float) -> pd.Series:
    """Value of $1 bought at the first date's open (with slippage), marked at
    each close, sold at the last close (with slippage)."""
    d = df.reindex(dates)
    close = d["close"].astype(float).ffill()
    first_open = d["open"].astype(float).dropna()
    if not len(first_open) or close.isna().all():
        return pd.Series(1.0, index=dates)
    entry = float(first_open.iloc[0]) * (1.0 + slippage)
    val = close / entry
    val = val.fillna(1.0)
    val.iloc[-1] = val.iloc[-1] * (1.0 - slippage)
    return val


def _returns_from_value(val: pd.Series) -> pd.Series:
    prev = val.shift(1)
    prev.iloc[0] = 1.0
    return (val / prev - 1.0).astype(float)


def spy_buy_hold(spy_df: pd.DataFrame, dates: pd.DatetimeIndex, slippage: float = 0.001) -> pd.Series:
    dates = pd.DatetimeIndex(dates)
    if not len(dates):
        return pd.Series(dtype=float)
    return _returns_from_value(_value_path(spy_df, dates, slippage))


def equal_weight_buy_hold(bars: Dict[str, pd.DataFrame], dates: pd.DatetimeIndex,
                          slippage: float = 0.001) -> pd.Series:
    dates = pd.DatetimeIndex(dates)
    if not len(dates) or not bars:
        return pd.Series(dtype=float)
    paths = [_value_path(df, dates, slippage) for _s, df in sorted(bars.items())]
    val = pd.concat(paths, axis=1).mean(axis=1)
    return _returns_from_value(val)


def pooled(fold_series) -> pd.Series:
    """Concatenate per-fold return series (in fold order)."""
    parts = [s for s in fold_series if s is not None and len(s)]
    if not parts:
        return pd.Series(dtype=float)
    return pd.concat(parts)


def fold_return(r: pd.Series) -> float:
    a = np.asarray(r, dtype=float)
    a = a[np.isfinite(a)]
    return float(np.prod(1.0 + a) - 1.0) if len(a) else 0.0
