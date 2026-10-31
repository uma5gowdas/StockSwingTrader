"""Test stub: yfinance returning a fixed, deterministic daily OHLCV series
(stands in for real market data so the real-data code path runs offline).
Mimics recent yfinance: (field, ticker) MultiIndex columns, DatetimeIndex.
Put this directory first on PYTHONPATH."""
import numpy as np
import pandas as pd

__version__ = "stub-fixture"


def download(tickers, start=None, end=None, period=None, interval="1d", progress=True, **kwargs):
    if start is not None:
        end_ts = pd.Timestamp(end) if end is not None else pd.Timestamp("2024-01-01")
        index = pd.bdate_range(pd.Timestamp(start), end_ts, inclusive="left")
    else:
        index = pd.bdate_range(end=pd.Timestamp("2024-06-28"), periods=250)
    n = len(index)
    t = np.arange(n)
    # Smooth oscillation plus drift: produces RSI/Bollinger and EMA crossings
    close = 100 + 8 * np.sin(t / 9.0) + 0.05 * t
    frame = pd.DataFrame({
        "Open": close * 0.998,
        "High": close * 1.01,
        "Low": close * 0.99,
        "Close": close,
        "Volume": 1_000_000 + (t % 7) * 10_000,
    }, index=index)
    frame.columns = pd.MultiIndex.from_tuples([(c, str(tickers)) for c in frame.columns])
    return frame
