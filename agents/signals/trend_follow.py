"""tf_only: lib/backtest_engine.py TrendFollowStrategy with parameters.

EMA = pandas ewm(span, adjust=False) (the legacy Indicators.ema).
  signal 1  fast crosses above slow: fast[i] > slow[i] and fast[i-1] <= slow[i-1]
  signal -1 fast crosses below slow: fast[i] < slow[i] and fast[i-1] >= slow[i-1]
  bar 0 is always 0.

Grid (fast, slow): (8, 21), (12, 26), (20, 50). (12, 26) equals the legacy
generate_signals (checked by `validate parity`).
"""

from __future__ import annotations

from typing import Any, Dict

import numpy as np
import pandas as pd

from agents.signals.base import SignalFrame, SignalSpec, signal_params, signal_to_frame

SIGNAL_ID = "tf_only"
PARAM_GRID = [{"fast": f, "slow": s} for f, s in ((8, 21), (12, 26), (20, 50))]
LEGACY_PARAMS = {"fast": 12, "slow": 26}


def tf_signal(df: pd.DataFrame, fast: int = 12, slow: int = 26) -> pd.Series:
    """1 / -1 / 0 per bar (int Series on df.index)."""
    c = pd.Series(df["close"].to_numpy(dtype=float))
    ef = c.ewm(span=fast, adjust=False).mean().to_numpy()
    es = c.ewm(span=slow, adjust=False).mean().to_numpy()
    sig = np.zeros(len(c), dtype=int)
    if len(c) > 1:
        up = (ef[1:] > es[1:]) & (ef[:-1] <= es[:-1])
        dn = (ef[1:] < es[1:]) & (ef[:-1] >= es[:-1])
        sig[1:] = np.where(up, 1, np.where(dn, -1, 0))
    return pd.Series(sig, index=df.index)


def build(df: pd.DataFrame, params: Dict[str, Any], symbol: str = "SYM") -> SignalFrame:
    p = dict(LEGACY_PARAMS)
    p.update(signal_params(params))
    return signal_to_frame(df, tf_signal(df, int(p["fast"]), int(p["slow"])))


SPEC = SignalSpec(SIGNAL_ID, PARAM_GRID, build,
                  "Legacy trend follow: EMA(fast) crosses above EMA(slow); exit on the reverse cross")
