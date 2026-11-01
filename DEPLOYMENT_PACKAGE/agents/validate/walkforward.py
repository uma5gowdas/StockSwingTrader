"""Walk-forward folds and train-only tuning (plan D18/D19).

calendar_folds(index, start='2016-01-01', train_years=2, test_months=6,
               step_months=6, min_test_bars=21)
    fold k: train [start + k*step, + train_years), test [train end,
    + test_months). Folds are generated while the test window starts on or
    before the last bar; the last test window may be shorter (kept when it
    holds >= min_test_bars bars).
bar_folds(index, train_bars=252, test_bars=126, n_folds=2)
    Anchored at the end of the data: the last fold's test window ends at the
    last bar, earlier folds step back by test_bars (offline mode).

Fold boundaries are Timestamps; a fold covers train_start <= t < train_end
and test_start <= t < test_end (test_end exclusive; the last calendar fold's
test_end is just after the last bar). Train and test never overlap.

walk_forward(evaluate, configs, folds): for each fold, evaluate every config
on the train window, pick the max train Sharpe (ties: first in grid order),
evaluate it on the test window. Indicators/signals are computed on the full
series before slicing (all causal, so no look-ahead past each bar).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Optional

import pandas as pd


@dataclass
class Fold:
    fold: int
    train_start: pd.Timestamp
    train_end: pd.Timestamp
    test_start: pd.Timestamp
    test_end: pd.Timestamp

    def as_dict(self) -> Dict[str, str]:
        return {"train": [str(self.train_start.date()), str(self.train_end.date())],
                "test": [str(self.test_start.date()), str(self.test_end.date())]}


def calendar_folds(index: pd.DatetimeIndex, start="2016-01-01", train_years: int = 2, test_months: int = 6,
                   step_months: int = 6, min_test_bars: int = 21) -> List[Fold]:
    index = pd.DatetimeIndex(index).sort_values()
    if not len(index):
        return []
    last = index[-1]
    s0 = pd.Timestamp(start)
    folds: List[Fold] = []
    k = 0
    while True:
        tr_s = s0 + pd.DateOffset(months=k * step_months)
        tr_e = tr_s + pd.DateOffset(years=train_years)
        te_s = tr_e
        te_e = te_s + pd.DateOffset(months=test_months)
        if te_s > last:
            break
        if te_e > last:
            te_e = last + pd.Timedelta(days=1)
        n_test = int(((index >= te_s) & (index < te_e)).sum())
        if n_test >= min_test_bars:
            folds.append(Fold(len(folds), tr_s, tr_e, te_s, te_e))
        k += 1
    return folds


def bar_folds(index: pd.DatetimeIndex, train_bars: int = 252, test_bars: int = 126, n_folds: int = 2) -> List[Fold]:
    index = pd.DatetimeIndex(index).sort_values()
    n = len(index)
    folds: List[Fold] = []
    for i in range(n_folds):
        test_end_i = n - (n_folds - 1 - i) * test_bars  # exclusive position
        test_start_i = test_end_i - test_bars
        train_start_i = test_start_i - train_bars
        if train_start_i < 0:
            continue
        te_e = index[test_end_i] if test_end_i < n else index[-1] + pd.Timedelta(days=1)
        folds.append(Fold(len(folds), index[train_start_i], index[test_start_i], index[test_start_i], te_e))
    return folds


def slice_index(index: pd.DatetimeIndex, start: pd.Timestamp, end: pd.Timestamp) -> pd.DatetimeIndex:
    """Bars with start <= t < end."""
    return index[(index >= start) & (index < end)]


def walk_forward(evaluate: Callable[[Dict[str, Any], pd.Timestamp, pd.Timestamp], Dict[str, Any]],
                 configs: List[Dict[str, Any]], folds: List[Fold],
                 on_eval: Optional[Callable[[Dict[str, Any], int, str, Dict[str, Any]], None]] = None) -> List[Dict[str, Any]]:
    """EVALUATE(config, start, end) -> {sharpe, returns, trades, ...}.

    Returns per fold {fold, train, test, params, train_sharpe, test: <evaluate
    result on the test window>}. ON_EVAL(config, fold, phase, result) is
    called for every evaluation (trial logging)."""
    out = []
    for f in folds:
        best_i, best_sr = 0, None
        for i, cfg in enumerate(configs):
            r = evaluate(cfg, f.train_start, f.train_end)
            if on_eval:
                on_eval(cfg, f.fold, "train", r)
            sr = r["sharpe"]
            if best_sr is None or sr > best_sr:
                best_i, best_sr = i, sr
        cfg = configs[best_i]
        t = evaluate(cfg, f.test_start, f.test_end)
        if on_eval:
            on_eval(cfg, f.fold, "test", t)
        out.append({"fold": f.fold, **f.as_dict(), "params": cfg, "config_index": best_i,
                    "train_sharpe": best_sr, "test_result": t})
    return out
