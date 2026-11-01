"""The 14 legacy ML features (lib/ml_inference.py) as per-bar time series (plan Q6).

legacy_feature_frame(df) computes every feature with the calculate_*
functions of lib/ml_inference.py over the full history, exactly as
extract_features_from_data() does for the last row, and returns one column
per feature named sst_<name> (stored in the Qlib store as $sst_<name>).

Contract: for t >= 49, row t equals extract_features_from_data() on the
prefix df.iloc[:t+1]. The legacy functions are causal (rolling / ewm /
Wilder recursion from the series start), so a prefix gives the same values.
A window that does NOT start at the series start (live use: ~3 months from
yfinance) gives slightly different EMA/MACD values, because ewm(adjust=True)
depends on where the series starts; all other features only look back a
fixed number of bars.

Rows where a legacy value is not yet defined, or would use data after t,
are NaN: RSI t < 15 (its seed uses deltas 0..14), MACD t < 25, EMA20 t < 19,
EMA50 t < 49, Bollinger / volume ratio t < 19, ATR t < 14 (np.roll wraps
the last close into bar 0), stochastic %K t < 14 and %D t < 16.
"""

from __future__ import annotations

import importlib.util
import logging
from typing import Optional

import numpy as np
import pandas as pd

from agents.config import PROJECT_ROOT

SST_FEATURES = (
    "rsi_14", "macd", "macd_signal", "macd_hist",
    "bb_position", "bb_width", "atr",
    "stochastic_k", "stochastic_d",
    "ema_20", "ema_50", "volume_ratio",
    "close_price", "price_range",
)
SST_COLUMNS = tuple("sst_" + n for n in SST_FEATURES)
MODULE_NAME = "sst_legacy_ml_inference"

_LEGACY = None


def load_ml_inference():
    """lib/ml_inference.py as a module (importlib; yfinance is not needed)."""
    global _LEGACY
    if _LEGACY is None:
        path = PROJECT_ROOT / "lib" / "ml_inference.py"
        spec = importlib.util.spec_from_file_location(MODULE_NAME, str(path))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        logging.getLogger(MODULE_NAME).setLevel(logging.WARNING)
        _LEGACY = mod
    return _LEGACY


def _mask(values, first_valid: int) -> np.ndarray:
    out = np.asarray(values, dtype=float).copy()
    out[:max(first_valid, 0)] = np.nan
    return out


def legacy_feature_frame(df: pd.DataFrame, module=None) -> pd.DataFrame:
    """DataFrame (same index as DF, columns sst_<name>) of the 14 legacy
    features. DF needs columns high, low, close, volume (lowercase)."""
    m = module or load_ml_inference()
    close = df["close"].to_numpy(dtype=float)
    high = df["high"].to_numpy(dtype=float)
    low = df["low"].to_numpy(dtype=float)
    volume = df["volume"].to_numpy(dtype=float)
    n = len(close)
    out = {}
    if n == 0:
        return pd.DataFrame({c: pd.Series(dtype=float) for c in SST_COLUMNS}, index=df.index)

    rsi = m.calculate_rsi(close, period=14) if n >= 15 else np.full(n, np.nan)
    out["rsi_14"] = _mask(rsi, 15)

    macd, macd_signal, macd_hist = m.calculate_macd(close)
    for name, arr in (("macd", macd), ("macd_signal", macd_signal), ("macd_hist", macd_hist)):
        out[name] = _mask(arr, 25)

    bb_sma, bb_upper, bb_lower, bb_position = m.calculate_bollinger_bands(close)
    if n < 20:
        bb_sma = bb_upper = bb_lower = bb_position = np.full(n, np.nan)
    bb_sma = np.asarray(bb_sma, dtype=float)
    denom = np.where(bb_sma != 0, bb_sma, 1.0)
    out["bb_position"] = _mask(bb_position, 19)
    out["bb_width"] = _mask((np.asarray(bb_upper) - np.asarray(bb_lower)) / denom, 19)

    out["atr"] = _mask(m.calculate_atr(high, low, close, period=14), 14)

    if n >= 14:
        k, d = m.calculate_stochastic(high, low, close, period=14)
    else:
        k = d = np.full(n, np.nan)
    out["stochastic_k"] = _mask(np.asarray(k, dtype=float) / 100.0, 14)
    out["stochastic_d"] = _mask(np.asarray(d, dtype=float) / 100.0, 16)

    out["ema_20"] = _mask(m.calculate_ema(close, period=20), 19)
    out["ema_50"] = _mask(m.calculate_ema(close, period=50), 49)

    vol_sma = pd.Series(volume).rolling(window=20).mean().to_numpy()
    with np.errstate(divide="ignore", invalid="ignore"):
        ratio = np.where(vol_sma != 0, volume / np.where(vol_sma != 0, vol_sma, 1.0), 1.0)
    out["volume_ratio"] = _mask(np.where(np.isnan(vol_sma), np.nan, ratio), 19)

    out["close_price"] = close.copy()
    out["price_range"] = (high - low) / np.where(close != 0, close, 1.0)

    return pd.DataFrame({"sst_" + name: out[name] for name in SST_FEATURES}, index=df.index)


def legacy_features_at(df: pd.DataFrame, module=None) -> Optional[dict]:
    """extract_features_from_data() of lib/ml_inference.py on DF (lowercase
    columns); None when DF has fewer than MIN_ROWS rows. Used by tests."""
    m = module or load_ml_inference()
    legacy = df.rename(columns={"close": "Close", "high": "High", "low": "Low", "volume": "Volume"})
    return m.extract_features_from_data(legacy)
