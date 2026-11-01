#!/usr/bin/env python3
"""Generate the offline agent fixtures (deterministic; numpy default_rng(20260101)).

Writes (relative to this file):
  bars/{AAA,BBB,CCC,SPY}.csv   date,open,high,low,close,volume; 1000 business
                               days from 2019-01-02 in four regime segments
                               (trend-up, sideways oscillation, trend-down,
                               high volatility) so mean-reversion and trend-
                               following both trade
  bars/QAA..QLL.csv            quant cross-section (12 random walks with
                               per-symbol drift; own rng SEED + 1000 + i,
                               generated last so the files above are unchanged)
  bars/meta.json               {synthetic: true, generator, seed, ..., quant_panel}
  alpaca/bars_page1.json       Alpaca v2 multi-symbol bars (AAA, BBB), page 1
  alpaca/bars_page2.json       page 2 (next_page_token null)
  alpaca/bars_stale.json       AAA bars that end 10 business days early

These bars are GENERATED, not market data (no recorded vendor data is
committed). Run with the agent venv:
  .venv-agents/bin/python tests/fixtures/agents/make_fixtures.py
Re-running gives byte-identical files.
"""

import json
import os
from datetime import datetime
from zoneinfo import ZoneInfo

import numpy as np
import pandas as pd

SEED = 20260101
N_DAYS = 1000
START = "2019-01-02"
SYMBOLS = {  # symbol: (start price, volatility scale, base volume)
    "AAA": (100.0, 1.0, 2_000_000),
    "BBB": (50.0, 1.3, 3_500_000),
    "CCC": (200.0, 0.8, 1_200_000),
    "SPY": (250.0, 0.6, 60_000_000),
}
# Quant panel (Phase 2): separate seeds, same calendar
QUANT_SYMBOLS = ("QAA", "QBB", "QCC", "QDD", "QEE", "QFF", "QGG", "QHH", "QII", "QJJ", "QKK", "QLL")
HERE = os.path.dirname(os.path.abspath(__file__))
NY = ZoneInfo("America/New_York")


def make_series(rng, start_price, vol_scale, base_volume, n):
    seg = n // 4
    closes = np.empty(n)
    price = start_price
    for i in range(n):
        k = min(i // seg, 3)
        if k == 0:      # trend up
            ret = 0.0012 + rng.normal(0, 0.010 * vol_scale)
        elif k == 1:    # sideways oscillation around the segment start
            anchor = closes[seg - 1]
            ret = 0.04 * np.sin((i - seg) / 6.0) / 6.0 + 0.15 * (anchor - price) / anchor \
                + rng.normal(0, 0.009 * vol_scale)
        elif k == 2:    # trend down
            ret = -0.0010 + rng.normal(0, 0.010 * vol_scale)
        else:           # high volatility
            ret = 0.0002 + rng.normal(0, 0.028 * vol_scale)
        price = max(price * (1.0 + ret), 1.0)
        closes[i] = price
    opens = np.empty(n)
    opens[0] = closes[0] * (1 + rng.normal(0, 0.002))
    opens[1:] = closes[:-1] * (1 + rng.normal(0, 0.004 * vol_scale, n - 1))
    spread = np.abs(rng.normal(0, 0.008 * vol_scale, n)) + 0.002
    highs = np.maximum(opens, closes) * (1 + spread)
    lows = np.minimum(opens, closes) * (1 - spread)
    volume = (base_volume * (1 + 0.3 * np.abs(rng.normal(0, 1, n)))).astype(np.int64)
    return opens, highs, lows, closes, volume


def make_random_walk(rng, start_price, vol_scale, base_volume, drift, n):
    """Plain random walk with DRIFT per day (quant panel symbols)."""
    rets = drift + rng.normal(0, 0.012 * vol_scale, n)
    closes = np.maximum(start_price * np.cumprod(1.0 + rets), 1.0)
    opens = np.empty(n)
    opens[0] = closes[0] * (1 + rng.normal(0, 0.002))
    opens[1:] = closes[:-1] * (1 + rng.normal(0, 0.004 * vol_scale, n - 1))
    spread = np.abs(rng.normal(0, 0.008 * vol_scale, n)) + 0.002
    highs = np.maximum(opens, closes) * (1 + spread)
    lows = np.minimum(opens, closes) * (1 - spread)
    volume = (base_volume * (1 + 0.3 * np.abs(rng.normal(0, 1, n)))).astype(np.int64)
    return opens, highs, lows, closes, volume


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


def alpaca_rows(df):
    rows = []
    for d, r in df.iterrows():
        t = datetime(d.year, d.month, d.day, tzinfo=NY).astimezone(ZoneInfo("UTC"))
        rows.append({"t": t.strftime("%Y-%m-%dT%H:%M:%SZ"), "o": round(r.open, 4), "h": round(r.high, 4),
                     "l": round(r.low, 4), "c": round(r.close, 4), "v": int(r.volume),
                     "n": int(r.volume // 100), "vw": round((r.high + r.low + r.close) / 3, 4)})
    return rows


def main():
    rng = np.random.default_rng(SEED)
    dates = pd.bdate_range(START, periods=N_DAYS)
    frames = {}
    for sym, (p0, vol, base_v) in SYMBOLS.items():
        o, h, l, c, v = make_series(rng, p0, vol, base_v, N_DAYS)
        lines = ["date,open,high,low,close,volume"]
        for i, d in enumerate(dates):
            lines.append("%s,%.4f,%.4f,%.4f,%.4f,%d" % (d.strftime("%Y-%m-%d"), o[i], h[i], l[i], c[i], v[i]))
        write(os.path.join(HERE, "bars", "%s.csv" % sym), "\n".join(lines) + "\n")
        frames[sym] = pd.DataFrame({"open": np.round(o, 4), "high": np.round(h, 4), "low": np.round(l, 4),
                                    "close": np.round(c, 4), "volume": v}, index=dates)
    meta = {
        "synthetic": True,
        "generator": "tests/fixtures/agents/make_fixtures.py",
        "seed": SEED,
        "rng": "numpy.random.default_rng (PCG64)",
        "symbols": list(SYMBOLS),
        "start": dates[0].strftime("%Y-%m-%d"),
        "end": dates[-1].strftime("%Y-%m-%d"),
        "rows": N_DAYS,
        "segments": ["trend_up", "sideways_oscillation", "trend_down", "high_volatility"],
        "note": "Generated bars, not market data",
    }

    # Alpaca v2 multi-symbol responses: last 40 bars of AAA and BBB, 2 pages
    tail = {s: alpaca_rows(frames[s].iloc[-40:]) for s in ("AAA", "BBB")}
    page1 = {"bars": {s: rows[:20] for s, rows in tail.items()}, "next_page_token": "fixture-page-2"}
    page2 = {"bars": {s: rows[20:] for s, rows in tail.items()}, "next_page_token": None}
    stale = {"bars": {"AAA": alpaca_rows(frames["AAA"].iloc[-40:-10])}, "next_page_token": None}
    for name, obj in (("bars_page1", page1), ("bars_page2", page2), ("bars_stale", stale)):
        write(os.path.join(HERE, "alpaca", "%s.json" % name), json.dumps(obj, indent=1) + "\n")

    # Quant cross-section (Phase 2): generated AFTER everything above, each with
    # its own default_rng(SEED + 1000 + i), so the files above are unchanged.
    for i, sym in enumerate(QUANT_SYMBOLS):
        qrng = np.random.default_rng(SEED + 1000 + i)
        o, h, l, c, v = make_random_walk(qrng, 20.0 + 15.0 * i, 0.7 + 0.08 * i,
                                         800_000 + 250_000 * i, 0.0004 * ((i % 5) - 2), N_DAYS)
        lines = ["date,open,high,low,close,volume"]
        for j, d in enumerate(dates):
            lines.append("%s,%.4f,%.4f,%.4f,%.4f,%d" % (d.strftime("%Y-%m-%d"), o[j], h[j], l[j], c[j], v[j]))
        write(os.path.join(HERE, "bars", "%s.csv" % sym), "\n".join(lines) + "\n")
    meta["symbols"] = list(SYMBOLS) + list(QUANT_SYMBOLS)
    meta["quant_panel"] = {
        "symbols": list(QUANT_SYMBOLS),
        "rng": "numpy.random.default_rng(seed + 1000 + i) per symbol, i = position in symbols",
        "model": "random walk with per-symbol drift (no regime segments)",
        "note": "Offline cross-section for the quant agent (with AAA, BBB, CCC ranked; SPY benchmark)",
    }
    write(os.path.join(HERE, "bars", "meta.json"), json.dumps(meta, indent=2) + "\n")
    print(json.dumps({"bars": meta["symbols"], "end": meta["end"], "alpaca_last": tail["AAA"][-1]["t"]}))


if __name__ == "__main__":
    main()
