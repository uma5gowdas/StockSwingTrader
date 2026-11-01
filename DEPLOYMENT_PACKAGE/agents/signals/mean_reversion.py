"""mr_only: lib/backtest_engine.py MeanReversionStrategy with parameters.

RSI(14) is a copy of the legacy Indicators.rsi (its quirks kept: the seed
averages deltas[:period+1] over `period`, the first `period` values are NaN,
a zero delta counts on the loss branch). Bollinger(20, bb_std) uses the
pandas rolling mean / std (ddof=1), as the legacy engine does.

  signal 1  (entry)  rsi < rsi_buy  and close < lower
  signal -1 (exit)   rsi > rsi_sell and close > upper
  bar 0 is always 0 (the legacy loop starts at 1)

Grid: rsi_buy {25, 30, 35} x bb_std {1.5, 2.0, 2.5}, rsi_sell 70.
With rsi_buy 30, bb_std 2.0 the signal equals the legacy generate_signals
(checked by `validate parity`).
"""

from __future__ import annotations

from typing import Any, Dict

import numpy as np
import pandas as pd

from agents.signals.base import SignalFrame, SignalSpec, signal_params, signal_to_frame

SIGNAL_ID = "mr_only"
PARAM_GRID = [{"rsi_buy": b, "bb_std": s, "rsi_sell": 70} for b in (25, 30, 35) for s in (1.5, 2.0, 2.5)]
LEGACY_PARAMS = {"rsi_buy": 30, "bb_std": 2.0, "rsi_sell": 70}


def legacy_rsi(prices: np.ndarray, period: int = 14) -> np.ndarray:
    """Exact copy of lib/backtest_engine.py Indicators.rsi."""
    prices = np.asarray(prices, dtype=float)
    deltas = np.diff(prices)
    seed = deltas[:period + 1]
    up = seed[seed >= 0].sum() / period
    down = -seed[seed < 0].sum() / period
    rs = np.zeros_like(prices)
    rs[:period] = np.nan
    for i in range(period, len(prices)):
        delta = deltas[i - 1]
        if delta > 0:
            up = (up * (period - 1) + delta) / period
            down = down * (period - 1) / period
        else:
            up = up * (period - 1) / period
            down = (down * (period - 1) - delta) / period
        rs[i] = 100 - 100 / (1 + up / down) if down != 0 else 100 if up > 0 else 0
    return rs


def legacy_bollinger(prices: np.ndarray, period: int = 20, std_dev: float = 2.0):
    """(lower, sma, upper) as lib/backtest_engine.py Indicators.bollinger_bands."""
    s = pd.Series(np.asarray(prices, dtype=float))
    sma = s.rolling(window=period).mean().values
    rstd = s.rolling(window=period).std().values
    return sma - rstd * std_dev, sma, sma + rstd * std_dev


def mr_signal(df: pd.DataFrame, rsi_buy: float = 30, bb_std: float = 2.0, rsi_sell: float = 70) -> pd.Series:
    """1 / -1 / 0 per bar (int Series on df.index)."""
    close = df["close"].to_numpy(dtype=float)
    rsi = legacy_rsi(close, 14)
    lower, _mid, upper = legacy_bollinger(close, 20, bb_std)
    with np.errstate(invalid="ignore"):
        buy = (rsi < rsi_buy) & (close < lower)
        sell = (rsi > rsi_sell) & (close > upper)
    sig = np.where(buy, 1, np.where(sell, -1, 0))
    if len(sig):
        sig[0] = 0
    return pd.Series(sig.astype(int), index=df.index)


def build(df: pd.DataFrame, params: Dict[str, Any], symbol: str = "SYM") -> SignalFrame:
    p = dict(LEGACY_PARAMS)
    p.update(signal_params(params))
    return signal_to_frame(df, mr_signal(df, p["rsi_buy"], p["bb_std"], p["rsi_sell"]))


SPEC = SignalSpec(SIGNAL_ID, PARAM_GRID, build,
                  "Legacy mean reversion: RSI(14) < rsi_buy and close < BB(20, bb_std) lower; "
                  "exit RSI > 70 and close > upper")
