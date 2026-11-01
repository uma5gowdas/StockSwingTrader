"""Prediction metrics of the quant agent (plan Q11). numpy/pandas only.

Input: a prediction frame with columns datetime, instrument, score, label;
label = the RAW open-to-open 5-day return (not cross-sectionally
normalised). Daily cross-sections with fewer than MIN_NAMES names are
dropped.

Labels overlap (5-day returns sampled daily), so consecutive daily ICs are
autocorrelated and the naive t overstates significance. rank_ic_t_nw (the
Newey-West t with Bartlett weights, lag 4) is the t the go rule uses;
rank_ic_t_nonoverlap uses every 5th date only.
"""

from __future__ import annotations

import math
from typing import Dict, Iterable, List, Optional

import numpy as np
import pandas as pd

MIN_NAMES = 5
HORIZON = 5
NW_LAG = 4


def _f(x, nd: int = 6) -> Optional[float]:
    """JSON-safe float (None for NaN/inf/None)."""
    if x is None:
        return None
    try:
        v = float(x)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(v):
        return None
    return round(v, nd)


def _clean(pred_df: pd.DataFrame) -> pd.DataFrame:
    df = pred_df[["datetime", "instrument", "score", "label"]].copy()
    df["datetime"] = pd.to_datetime(df["datetime"])
    return df.dropna(subset=["score", "label"])


def daily_ic(pred_df: pd.DataFrame, min_names: int = MIN_NAMES) -> pd.DataFrame:
    """DataFrame[date, ic, rank_ic, n]: Pearson / Spearman of score vs label
    per date (dates with < MIN_NAMES names or a constant column dropped)."""
    rows = []
    for d, g in _clean(pred_df).groupby("datetime", sort=True):
        if len(g) < min_names:
            continue
        s, y = g["score"].to_numpy(float), g["label"].to_numpy(float)
        if np.std(s) == 0 or np.std(y) == 0:
            continue
        ic = float(np.corrcoef(s, y)[0, 1])
        rs = pd.Series(s).rank().to_numpy()
        ry = pd.Series(y).rank().to_numpy()
        ric = float(np.corrcoef(rs, ry)[0, 1])
        rows.append((pd.Timestamp(d), ic, ric, len(g)))
    return pd.DataFrame(rows, columns=["date", "ic", "rank_ic", "n"])


def newey_west_t(series: Iterable[float], lag: int = NW_LAG) -> Optional[float]:
    """mean / HAC standard error (Bartlett weights 1 - l/(lag+1)); None when
    fewer than 2 values or the variance is not positive."""
    x = pd.Series(list(series), dtype=float).dropna().to_numpy()
    n = len(x)
    if n < 2:
        return None
    e = x - x.mean()
    var = float(np.dot(e, e) / n)
    for l in range(1, min(int(lag), n - 1) + 1):
        w = 1.0 - l / (lag + 1.0)
        var += 2.0 * w * float(np.dot(e[l:], e[:-l]) / n)
    if var <= 0:
        return None
    return float(x.mean() / math.sqrt(var / n))


def naive_t(series: Iterable[float]) -> Optional[float]:
    x = pd.Series(list(series), dtype=float).dropna()
    if len(x) < 2 or x.std(ddof=1) == 0:
        return None
    return float(x.mean() / (x.std(ddof=1) / math.sqrt(len(x))))


def summarize_ic(ic_df: pd.DataFrame) -> Dict[str, Optional[float]]:
    n = int(len(ic_df))
    if n == 0:
        keys = ("ic_mean", "ic_std", "icir", "rank_ic_mean", "rank_ic_std", "rank_icir", "rank_ic_t_naive",
                "rank_ic_t_nw", "rank_ic_t_nonoverlap", "pct_positive")
        out: Dict[str, Optional[float]] = {k: None for k in keys}
        out["n_days"] = 0
        return out
    ic, ric = ic_df["ic"].astype(float), ic_df["rank_ic"].astype(float)
    ic_std = ic.std(ddof=1) if n > 1 else float("nan")
    ric_std = ric.std(ddof=1) if n > 1 else float("nan")
    return {
        "ic_mean": _f(ic.mean()), "ic_std": _f(ic_std),
        "icir": _f(ic.mean() / ic_std) if ic_std and math.isfinite(ic_std) else None,
        "rank_ic_mean": _f(ric.mean()), "rank_ic_std": _f(ric_std),
        "rank_icir": _f(ric.mean() / ric_std) if ric_std and math.isfinite(ric_std) else None,
        "rank_ic_t_naive": _f(naive_t(ric), 4),
        "rank_ic_t_nw": _f(newey_west_t(ric), 4),
        "rank_ic_t_nonoverlap": _f(naive_t(ric.iloc[::HORIZON]), 4),
        "n_days": n,
        "pct_positive": _f((ric > 0).mean(), 4),
    }


def per_year(ic_df: pd.DataFrame) -> List[Dict[str, object]]:
    out: List[Dict[str, object]] = []
    if not len(ic_df):
        return out
    years = pd.to_datetime(ic_df["date"]).dt.year
    for y, g in ic_df.groupby(years, sort=True):
        s = summarize_ic(g)
        out.append({"year": int(y), "n_days": s["n_days"], "ic_mean": s["ic_mean"],
                    "rank_ic_mean": s["rank_ic_mean"], "rank_icir": s["rank_icir"],
                    "rank_ic_t_nw": s["rank_ic_t_nw"]})
    return out


def _spread_stats(excess: pd.Series) -> Dict[str, Optional[float]]:
    excess = excess.dropna()
    if not len(excess):
        return {"mean_excess": None, "annualised": None, "t_nw": None, "hit_rate": None, "n_days": 0}
    m = float(excess.mean())
    return {"mean_excess": _f(m, 8), "annualised": _f(m * 252.0 / HORIZON, 6),
            "t_nw": _f(newey_west_t(excess), 4), "hit_rate": _f((excess > 0).mean(), 4),
            "n_days": int(len(excess))}


def topk_spread(pred_df: pd.DataFrame, k: int) -> Dict[str, Optional[float]]:
    """Top-K mean label minus the universe mean label per date (dates with
    at most K names skipped)."""
    vals = {}
    for d, g in _clean(pred_df).groupby("datetime", sort=True):
        if len(g) <= k:
            continue
        top = g.nlargest(int(k), "score")["label"].mean()
        vals[pd.Timestamp(d)] = float(top - g["label"].mean())
    out: Dict[str, Optional[float]] = {"k": int(k)}
    out.update(_spread_stats(pd.Series(vals, dtype=float)))
    return out


def quintile_spread(pred_df: pd.DataFrame) -> Dict[str, Optional[float]]:
    """Q5 - Q1 mean label per date (quintiles of score; >= 5 names)."""
    vals = {}
    for d, g in _clean(pred_df).groupby("datetime", sort=True):
        if len(g) < 5:
            continue
        q = pd.qcut(g["score"].rank(method="first"), 5, labels=False)
        vals[pd.Timestamp(d)] = float(g["label"][q == 4].mean() - g["label"][q == 0].mean())
    return _spread_stats(pd.Series(vals, dtype=float))


def evaluate_arm(pred_df: pd.DataFrame, ks: Iterable[int] = (5, 10, 20)) -> Dict[str, object]:
    clean = _clean(pred_df)
    ic_df = daily_ic(pred_df)
    return {
        "n_rows": int(len(clean)),
        "n_dates": int(clean["datetime"].nunique()) if len(clean) else 0,
        "start": clean["datetime"].min().strftime("%Y-%m-%d") if len(clean) else None,
        "end": clean["datetime"].max().strftime("%Y-%m-%d") if len(clean) else None,
        "ic": summarize_ic(ic_df),
        "per_year": per_year(ic_df),
        "topk": [topk_spread(pred_df, int(k)) for k in ks],
        "quintile": quintile_spread(pred_df),
    }
