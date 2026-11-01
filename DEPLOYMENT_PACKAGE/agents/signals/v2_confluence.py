"""v2_confluence and v2_confluence_adx: the bash v2 scan replayed historically
(plan D16).

For every bar t with at least WINDOW (60) bars up to and including t, the
window df[t-59 .. t] goes through bash_compat (the exact port of
calculate_all_indicators -> score_stock -> calculate_confluence_score_v2):
  ml_mode 'unavailable'  ML excluded (the model is trained on synthetic data
                         and would leak); weights renormalised 35/30/20 over 85
  sentiment 'na'         no historical sentiment
  Bollinger price        the window's last close (offline scan behaviour)
  MiroFish / agents      off
Entry when the recommendation is BUY or STRONG_BUY, exit when it is SELL or
STRONG_SELL (decided at the close of t; the gate engine fills at t+1 open).

v2_confluence_adx replaces v2_inputs.regime by the TA-Lib regime_adx at t
(talib_features.compute_series on the full series, causal), like the opt-in
scan hook (D14): when regime_adx is undefined the bash regime is kept.

v2 has no parameters of its own; its grid is the risk grid (9 configs).
Both series are computed in one pass and cached per symbol in
cache/agents/validate/signals/<signal_id>/<SYM>_<sha256(bars csv)[:12]>.csv
(recomputed when the bars change).
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, Optional

import pandas as pd

from agents.cache import cache_root, check_symbol
from agents.signals.base import SignalFrame, SignalSpec, bars_hash, legacy_atr

WINDOW = 60
ENTRY_RECS = ("BUY", "STRONG_BUY")
EXIT_RECS = ("SELL", "STRONG_SELL")
REGIMES = ("sideways", "trending_bull", "trending_bear", "volatile")
COLUMNS = ["regime", "confluence_score", "recommendation"]


def cache_file(signal_id: str, symbol: str, df: pd.DataFrame, root: Optional[Path] = None) -> Path:
    check_symbol(symbol)
    return (root or cache_root()) / "validate" / "signals" / signal_id / ("%s_%s.csv" % (symbol, bars_hash(df)))


def compute_v2_series(df: pd.DataFrame, symbol: str = "SYM") -> Dict[str, pd.DataFrame]:
    """{'v2_confluence': frame, 'v2_confluence_adx': frame}, each indexed like
    DF with columns regime, confluence_score, recommendation (empty strings /
    NaN for the first WINDOW-1 bars)."""
    from agents.technical import bash_compat as bc
    from agents.technical.talib_features import compute_series

    regime_adx = compute_series(df)["regime_adx"]
    rows_bash, rows_adx = [], []
    for i in range(len(df)):
        if i < WINDOW - 1:
            rows_bash.append(("", float("nan"), ""))
            rows_adx.append(("", float("nan"), ""))
            continue
        window = df.iloc[i - WINDOW + 1:i + 1]
        ind = bc.calculate_all_indicators(symbol, window, "history")
        s = bc.score_stock(symbol, ind, ml_mode="unavailable", sentiment="na")
        c = s["confluence_v2"]
        rows_bash.append((str(ind["v2_inputs"].get("regime")), c["confluence_score"], c["recommendation"]))
        r_adx = regime_adx.iloc[i]
        if r_adx in REGIMES:
            ind2 = dict(ind)
            ind2["v2_inputs"] = dict(ind["v2_inputs"], regime=r_adx)
            c2 = bc.score_stock(symbol, ind2, ml_mode="unavailable", sentiment="na")["confluence_v2"]
            rows_adx.append((r_adx, c2["confluence_score"], c2["recommendation"]))
        else:
            rows_adx.append(rows_bash[-1])
    return {
        "v2_confluence": pd.DataFrame(rows_bash, index=df.index, columns=COLUMNS),
        "v2_confluence_adx": pd.DataFrame(rows_adx, index=df.index, columns=COLUMNS),
    }


def _read_cache(path: Path, index: pd.Index) -> Optional[pd.DataFrame]:
    try:
        fr = pd.read_csv(path, parse_dates=["date"], keep_default_na=False,
                         dtype={"regime": str, "recommendation": str}).set_index("date")
    except (OSError, ValueError, KeyError):
        return None
    if len(fr) != len(index) or not (fr.index == index).all():
        return None
    fr["confluence_score"] = pd.to_numeric(fr["confluence_score"], errors="coerce")
    return fr[COLUMNS]


def _write_cache(path: Path, frame: pd.DataFrame) -> None:
    import os
    import tempfile

    path.parent.mkdir(parents=True, exist_ok=True)
    out = frame.copy()
    out.index.name = "date"
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".%s." % path.name, suffix=".tmp")
    os.close(fd)
    try:
        out.to_csv(tmp, date_format="%Y-%m-%d")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def v2_series(signal_id: str, df: pd.DataFrame, symbol: str = "SYM", use_cache: bool = True) -> pd.DataFrame:
    """Cached per-bar v2 frame for SIGNAL_ID (v2_confluence | v2_confluence_adx)."""
    path = cache_file(signal_id, symbol, df)
    if use_cache and path.is_file():
        fr = _read_cache(path, df.index)
        if fr is not None:
            return fr
    both = compute_v2_series(df, symbol)
    if use_cache:
        for sid, fr in both.items():
            _write_cache(cache_file(sid, symbol, df), fr)
    return both[signal_id]


def _builder(signal_id: str):
    def build(df: pd.DataFrame, params: Dict[str, Any], symbol: str = "SYM") -> SignalFrame:
        fr = v2_series(signal_id, df, symbol)
        rec = fr["recommendation"]
        return SignalFrame(entries=rec.isin(ENTRY_RECS), exits=rec.isin(EXIT_RECS), atr=legacy_atr(df),
                           extra={"v2": fr})
    return build


SPEC_V2 = SignalSpec("v2_confluence", [{}], _builder("v2_confluence"),
                     "Bash v2 confluence replay (60-bar windows, ML and sentiment excluded)")
SPEC_V2_ADX = SignalSpec("v2_confluence_adx", [{}], _builder("v2_confluence_adx"),
                         "Bash v2 confluence replay with the TA-Lib real-ADX regime (regime_adx)")
