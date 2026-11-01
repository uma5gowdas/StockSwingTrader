"""Standard TA-Lib features for the Technical Agent (plan decision D13).

Standard definitions (TA-Lib 0.8.x), not the bash approximations:
  RSI(14), EMA(12/26/20/50), SMA(50/200; null when short), MACD(12,26,9)
  macd/signal/hist, BBANDS(20,2,2) (population std) plus a sample-std (n-1)
  variant (the bash definition), ATR(14) (Wilder), TRANGE, NATR(14),
  ADX(14), PLUS_DI/MINUS_DI(14), STOCH(14,3,3) slowk/slowd, STOCHF(14,3)
  fastk, WILLR(14), OBV, Donchian 20 (MAX(high)/MIN(low)).

trend_state: up if ema_12 > ema_26 and close > sma_50; down if both below;
else neutral (sma_50 missing: the EMA comparison alone).

regime_adx: the detect_market_regime rules with the REAL ADX(14) instead of
min(100, |EMA20 - EMA50| * 10):
  volatility = BB(20, 2, sample std) width % of the middle, capped at 100
  volatility > 20                    -> volatile
  ADX > 25 and EMA20 > EMA50          -> trending_bull
  ADX > 25 and EMA20 < EMA50          -> trending_bear
  otherwise                          -> sideways
  (any input missing -> None)

Known divergences from the bash indicators (pinned in tests, not hidden):
bash MACD signal == macd (histogram 0); bash ATR = SMA of TR (talib.ATR is
Wilder); bash Bollinger uses the sample std.
"""

from __future__ import annotations

import math
from typing import Any, Dict, Optional

import numpy as np
import pandas as pd
import talib

REGIMES = ("sideways", "trending_bull", "trending_bear", "volatile")


def _arr(df: pd.DataFrame, col: str) -> np.ndarray:
    return np.asarray(df[col], dtype=float)


def regime_from(volatility: Optional[float], adx: Optional[float], ema20: Optional[float],
                ema50: Optional[float]) -> Optional[str]:
    """The regime rules above for one bar (None when an input is missing)."""
    vals = (volatility, adx, ema20, ema50)
    if any(v is None or (isinstance(v, float) and math.isnan(v)) for v in vals):
        return None
    if volatility > 20:
        return "volatile"
    if adx > 25 and ema20 > ema50:
        return "trending_bull"
    if adx > 25 and ema20 < ema50:
        return "trending_bear"
    return "sideways"


def trend_from(ema12, ema26, close, sma50) -> Optional[str]:
    """trend_state for one bar: up | down | neutral (None without EMAs)."""
    if any(v is None or (isinstance(v, float) and math.isnan(v)) for v in (ema12, ema26, close)):
        return None
    if sma50 is None or (isinstance(sma50, float) and math.isnan(sma50)):
        if ema12 > ema26:
            return "up"
        if ema12 < ema26:
            return "down"
        return "neutral"
    if ema12 > ema26 and close > sma50:
        return "up"
    if ema12 < ema26 and close < sma50:
        return "down"
    return "neutral"


def compute_series(df: pd.DataFrame) -> pd.DataFrame:
    """Every feature per date (same index as DF; NaN where undefined), plus
    the string columns trend_state and regime_adx. Used by FEAT-003."""
    h, l, c, v = _arr(df, "high"), _arr(df, "low"), _arr(df, "close"), _arr(df, "volume")
    out = pd.DataFrame(index=df.index)
    out["close"] = c
    out["rsi_14"] = talib.RSI(c, timeperiod=14)
    for p in (12, 26, 20, 50):
        out["ema_%d" % p] = talib.EMA(c, timeperiod=p)
    out["sma_50"] = talib.SMA(c, timeperiod=50)
    out["sma_200"] = talib.SMA(c, timeperiod=200)
    macd, sig, hist = talib.MACD(c, fastperiod=12, slowperiod=26, signalperiod=9)
    out["macd"], out["macd_signal"], out["macd_hist"] = macd, sig, hist
    up, mid, lo = talib.BBANDS(c, timeperiod=20, nbdevup=2, nbdevdn=2, matype=0)
    out["bb_upper"], out["bb_middle"], out["bb_lower"] = up, mid, lo
    std_s = pd.Series(c, index=df.index).rolling(20).std(ddof=1).to_numpy()
    out["bb_upper_sample"] = mid + 2 * std_s
    out["bb_lower_sample"] = mid - 2 * std_s
    with np.errstate(divide="ignore", invalid="ignore"):
        width = np.where(mid > 0, (4 * std_s) / mid * 100, np.nan)
    out["bb_width_pct_sample"] = np.minimum(width, 100)
    out["atr_14"] = talib.ATR(h, l, c, timeperiod=14)
    out["trange"] = talib.TRANGE(h, l, c)
    out["natr_14"] = talib.NATR(h, l, c, timeperiod=14)
    out["adx_14"] = talib.ADX(h, l, c, timeperiod=14)
    out["plus_di_14"] = talib.PLUS_DI(h, l, c, timeperiod=14)
    out["minus_di_14"] = talib.MINUS_DI(h, l, c, timeperiod=14)
    sk, sd = talib.STOCH(h, l, c, fastk_period=14, slowk_period=3, slowk_matype=0,
                         slowd_period=3, slowd_matype=0)
    out["stoch_slowk"], out["stoch_slowd"] = sk, sd
    fk, _fd = talib.STOCHF(h, l, c, fastk_period=14, fastd_period=3, fastd_matype=0)
    out["stochf_fastk"] = fk
    out["willr_14"] = talib.WILLR(h, l, c, timeperiod=14)
    out["obv"] = talib.OBV(c, v)
    out["donchian_high_20"] = talib.MAX(h, timeperiod=20)
    out["donchian_low_20"] = talib.MIN(l, timeperiod=20)
    # object dtype keeps None for "undefined" (pandas 3 would infer str + NaN)
    out["trend_state"] = pd.Series([trend_from(a, b, x, s) for a, b, x, s in
                                    zip(out["ema_12"], out["ema_26"], out["close"], out["sma_50"])],
                                   index=df.index, dtype=object)
    out["regime_adx"] = pd.Series([regime_from(w, a, e20, e50) for w, a, e20, e50 in
                                   zip(out["bb_width_pct_sample"], out["adx_14"], out["ema_20"], out["ema_50"])],
                                  index=df.index, dtype=object)
    return out


def _clean(x: Any) -> Any:
    if isinstance(x, (np.floating, float)):
        f = float(x)
        return None if math.isnan(f) or math.isinf(f) else round(f, 6)
    if isinstance(x, (np.integer,)):
        return int(x)
    return x


def compute_features(df: pd.DataFrame) -> Dict[str, Any]:
    """Every feature at the last bar of DF as a JSON-ready dict (NaN ->
    None), plus bars (the number of rows) and last_date."""
    if df is None or not len(df):
        return {"bars": 0}
    s = compute_series(df)
    row = s.iloc[-1]
    feats = {k: _clean(row[k]) for k in s.columns}
    feats["bars"] = int(len(df))
    idx = df.index[-1]
    feats["last_date"] = idx.strftime("%Y-%m-%d") if hasattr(idx, "strftime") else str(idx)
    return feats
