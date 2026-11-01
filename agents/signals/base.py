"""Signal interface shared by the validation engine.

SignalSpec(signal_id, param_grid, build): build(df, params, symbol) returns a
SignalFrame of boolean entries / exits (decided at the close of each bar; the
gate engine fills them at the next bar's open) and the ATR14 series used for
the bracket-style stop.

The risk grid (stop_atr_mult x take_profit_pct) is crossed with every signal
grid by full_grid(). The live defaults (2.0 x ATR stop clamped to
[ORDER_MIN_STOP_PCT 1, ORDER_MAX_STOP_PCT 15] %, take profit 8 %) are part
of the grid (DEFAULT_RISK).
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional

import numpy as np
import pandas as pd

STOP_ATR_MULTS = (1.5, 2.0, 3.0)
TAKE_PROFIT_PCTS = (5, 8, 12)
RISK_GRID: List[Dict[str, float]] = [
    {"stop_atr_mult": m, "take_profit_pct": t} for m in STOP_ATR_MULTS for t in TAKE_PROFIT_PCTS
]
DEFAULT_RISK = {"stop_atr_mult": 2.0, "take_profit_pct": 8}
RISK_KEYS = ("stop_atr_mult", "take_profit_pct")


@dataclass
class SignalFrame:
    """Boolean entries/exits and ATR14, all on the bars' index."""
    entries: pd.Series
    exits: pd.Series
    atr: pd.Series
    extra: Dict[str, Any] = field(default_factory=dict)


@dataclass
class SignalSpec:
    """One signal family: id, its own parameter grid and the builder."""
    signal_id: str
    param_grid: List[Dict[str, Any]]
    build: Callable[..., SignalFrame]
    description: str = ""

    def grid(self) -> List[Dict[str, Any]]:
        return full_grid(self)


def full_grid(spec: SignalSpec) -> List[Dict[str, Any]]:
    """Signal grid x RISK_GRID in a fixed order (signal params outer)."""
    return [dict(p, **r) for p in spec.param_grid for r in RISK_GRID]


def signal_params(params: Dict[str, Any]) -> Dict[str, Any]:
    """PARAMS without the risk keys (what the signal builder needs)."""
    return {k: v for k, v in params.items() if k not in RISK_KEYS}


def legacy_atr(df: pd.DataFrame, period: int = 14) -> pd.Series:
    """ATR as lib/backtest_engine.py Indicators.atr: TR[0] = high - low, then
    max(h-l, |h-prev_c|, |l-prev_c|); simple rolling mean over PERIOD."""
    h = df["high"].to_numpy(dtype=float)
    l = df["low"].to_numpy(dtype=float)
    c = df["close"].to_numpy(dtype=float)
    tr = np.zeros(len(h))
    if len(h):
        tr[0] = h[0] - l[0]
    if len(h) > 1:
        prev = c[:-1]
        tr[1:] = np.maximum.reduce([h[1:] - l[1:], np.abs(h[1:] - prev), np.abs(l[1:] - prev)])
    return pd.Series(tr, index=df.index).rolling(window=period).mean()


def signal_to_frame(df: pd.DataFrame, signal: pd.Series, extra: Optional[Dict[str, Any]] = None) -> SignalFrame:
    """1 / -1 / 0 signal series -> SignalFrame (entries = 1, exits = -1)."""
    s = pd.Series(signal, index=df.index).fillna(0)
    return SignalFrame(entries=(s == 1), exits=(s == -1), atr=legacy_atr(df), extra=extra or {})


def bars_hash(df: pd.DataFrame) -> str:
    """sha256 of the bars as CSV (date + OHLCV), first 12 hex chars."""
    cols = [c for c in ("open", "high", "low", "close", "volume") if c in df.columns]
    text = df[cols].to_csv(float_format="%.10g")
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:12]
