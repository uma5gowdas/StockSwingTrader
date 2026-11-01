"""Performance and overfitting statistics.

sharpe(r)             annualised by sqrt(252), rf 0, ddof 1; 0 when std is 0
                      or there are fewer than 2 returns
sharpe_per_period(r)  the same, not annualised (the unit PSR/DSR use)
max_drawdown(equity)  positive fraction (0.25 = -25 %)
cagr(r)               (prod(1 + r)) ** (252 / T) - 1
psr(sr, T, skew, kurt, sr0)
    Probabilistic Sharpe Ratio (Bailey & Lopez de Prado 2012), per-period
    SR, non-excess kurtosis (normal = 3):
    Phi((sr - sr0) sqrt(T - 1) / sqrt(1 - skew sr + (kurt - 1) / 4 sr^2))
dsr(sr_selected, trial_srs, T, skew, kurt, n_trials=None)
    Deflated Sharpe Ratio (Bailey & Lopez de Prado 2014): PSR at
    SR0 = sqrt(V[SR_trials]) ((1 - g) Phi^-1(1 - 1/N) + g Phi^-1(1 - 1/(N e))),
    g = 0.5772156649 (Euler-Mascheroni); N = n_trials or len(trial_srs);
    N = 1 -> SR0 = 0 (so DSR = PSR).
pbo_cscv(M, S=16)
    Probability of Backtest Overfitting via CSCV (Bailey, Borwein, Lopez de
    Prado, Zhu 2015): trim T to a multiple of S, split into S blocks, for
    every one of the C(S, S/2) IS/OOS splits pick the config with the best
    IS Sharpe, take its relative OOS rank w = rank / (N + 1) (ranks 1..N,
    ties averaged), lambda = logit(w); PBO = mean(lambda <= 0).
"""

from __future__ import annotations

import itertools
import math
from typing import Any, Dict, Optional, Sequence

import numpy as np
import pandas as pd
from scipy import stats as sps

EULER_GAMMA = 0.5772156649
TRADING_DAYS = 252


def _arr(r) -> np.ndarray:
    a = np.asarray(r, dtype=float)
    return a[np.isfinite(a)]


def sharpe_per_period(r) -> float:
    a = _arr(r)
    if len(a) < 2:
        return 0.0
    sd = a.std(ddof=1)
    if not np.isfinite(sd) or sd <= 1e-15:
        return 0.0
    return float(a.mean() / sd)


def sharpe(r) -> float:
    return sharpe_per_period(r) * math.sqrt(TRADING_DAYS)


def max_drawdown(equity) -> float:
    e = _arr(equity)
    if not len(e):
        return 0.0
    peak = np.maximum.accumulate(e)
    with np.errstate(divide="ignore", invalid="ignore"):
        dd = np.where(peak > 0, 1.0 - e / peak, 0.0)
    return float(max(0.0, dd.max()))


def equity_from_returns(r, start: float = 1.0) -> np.ndarray:
    return start * np.cumprod(1.0 + _arr(r))


def cagr(r) -> float:
    a = _arr(r)
    if not len(a):
        return 0.0
    growth = float(np.prod(1.0 + a))
    if growth <= 0:
        return -1.0
    return growth ** (TRADING_DAYS / len(a)) - 1.0


def moments(r) -> Dict[str, float]:
    """{T, skew, kurt} (kurt non-excess; normal values for degenerate input)."""
    a = _arr(r)
    if len(a) < 3 or a.std() <= 1e-15:
        return {"T": int(len(a)), "skew": 0.0, "kurt": 3.0}
    return {"T": int(len(a)), "skew": float(sps.skew(a, bias=False)),
            "kurt": float(sps.kurtosis(a, fisher=False, bias=False))}


def psr(sr: float, T: int, skew: float = 0.0, kurt: float = 3.0, sr0: float = 0.0) -> float:
    if T is None or T < 2:
        return 0.0
    var = 1.0 - skew * sr + (kurt - 1.0) / 4.0 * sr * sr
    if not np.isfinite(var) or var <= 1e-12:
        var = 1e-12
    z = (sr - sr0) * math.sqrt(T - 1) / math.sqrt(var)
    return float(sps.norm.cdf(z))


def expected_max_sr(trial_srs: Sequence[float], n_trials: Optional[int] = None) -> float:
    """SR0 of the DSR (per-period units)."""
    srs = _arr(trial_srs)
    n = int(n_trials if n_trials is not None else len(srs))
    if n <= 1 or len(srs) < 2:
        return 0.0
    v = float(np.var(srs, ddof=1))
    g = EULER_GAMMA
    return math.sqrt(max(v, 0.0)) * ((1 - g) * sps.norm.ppf(1 - 1.0 / n) + g * sps.norm.ppf(1 - 1.0 / (n * math.e)))


def dsr(sr_selected: float, trial_srs: Sequence[float], T: int, skew: float = 0.0, kurt: float = 3.0,
        n_trials: Optional[int] = None) -> float:
    return psr(sr_selected, T, skew, kurt, expected_max_sr(trial_srs, n_trials))


def _block_sharpes(blocks_sum: np.ndarray, blocks_sq: np.ndarray, blocks_n: np.ndarray, sel) -> np.ndarray:
    """Per-config (per-period) Sharpe over the union of the selected blocks,
    from per-block sums and sums of squares (sample std, ddof 1)."""
    n = blocks_n[list(sel)].sum()
    m = blocks_sum[list(sel)].sum(axis=0) / n
    sq = blocks_sq[list(sel)].sum(axis=0) / n
    var = (sq - m * m) * n / max(n - 1, 1)
    sd = np.sqrt(np.clip(var, 0, None))
    with np.errstate(divide="ignore", invalid="ignore"):
        out = np.where(sd > 1e-15, m / sd, 0.0)
    return out


def pbo_cscv(M, S: int = 16) -> Dict[str, Any]:
    """PBO of a T x N returns matrix (DataFrame or array). Returns {pbo, S,
    T_used, n_configs, n_splits, lambda: {mean, median, min, max, q25, q75}}."""
    X = np.asarray(M, dtype=float)
    if X.ndim != 2:
        raise ValueError("M must be T x N")
    X = np.nan_to_num(X, nan=0.0)
    T, N = X.shape
    if S % 2 or S < 2:
        raise ValueError("S must be even and >= 2")
    T_used = (T // S) * S
    if N < 2 or T_used < S:
        return {"pbo": None, "S": S, "T_used": T_used, "n_configs": N, "n_splits": 0, "lambda": None}
    X = X[T - T_used:]  # keep the most recent T_used rows
    size = T_used // S
    blocks = X.reshape(S, size, N)
    b_sum = blocks.sum(axis=1)
    b_sq = (blocks ** 2).sum(axis=1)
    b_n = np.full(S, size, dtype=float)
    lambdas = []
    all_blocks = set(range(S))
    for is_sel in itertools.combinations(range(S), S // 2):
        oos_sel = tuple(sorted(all_blocks - set(is_sel)))
        sr_is = _block_sharpes(b_sum, b_sq, b_n, is_sel)
        sr_oos = _block_sharpes(b_sum, b_sq, b_n, oos_sel)
        best = int(np.argmax(sr_is))
        ranks = sps.rankdata(sr_oos)  # 1..N ascending, ties averaged
        w = ranks[best] / (N + 1.0)
        lambdas.append(math.log(w / (1.0 - w)))
    lam = np.asarray(lambdas)
    return {"pbo": float(np.mean(lam <= 0)), "S": S, "T_used": int(T_used), "n_configs": int(N),
            "n_splits": int(len(lam)),
            "lambda": {"mean": float(lam.mean()), "median": float(np.median(lam)), "min": float(lam.min()),
                       "max": float(lam.max()), "q25": float(np.percentile(lam, 25)),
                       "q75": float(np.percentile(lam, 75))}}


def summarize_returns(r: pd.Series) -> Dict[str, float]:
    """{sharpe, cagr, max_dd, total_return} of a daily returns series."""
    a = _arr(r)
    eq = equity_from_returns(a)
    return {"sharpe": sharpe(a), "cagr": cagr(a), "max_dd": max_drawdown(np.concatenate([[1.0], eq])),
            "total_return": float(eq[-1] - 1.0) if len(eq) else 0.0}
