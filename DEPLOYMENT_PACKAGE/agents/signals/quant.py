"""Quant gate signals (Phase 2, plan Q12): quant_topk, xgb_topk, quant_rank.

Inputs: the out-of-sample predictions of `python -m agents quant train`,
cache/agents/quant/predictions/<arm>.parquet (datetime, instrument, score,
label, fold). Scores of date t use features up to the close of t (the label
starts at the open of t+1), so a decision at the close of t that the gate
engine fills at the next open has no look-ahead.

quant_topk (arm lgbm) / xgb_topk (arm xgb14)
    Rebalance every REBALANCE_EVERY (5) prediction sessions, anchored at the
    first prediction date. On a rebalance close: entry = the symbol is in the
    top k by score (ties: symbol order), exit = it is not (names staying in
    the top k keep their position). No signal off rebalance days or before
    the first prediction. Grid k in {5, 10, 20} x the risk grid (27 configs);
    'slots' sizing (shared cash, k slots of init_cash / k).
    quant_topk's baseline is xgb_topk (baseline_improvement criterion).

quant_rank (arm lgbm; the gate id lib/agent_adapter.sh checks before
AGENT_QUANT_WEIGHT may apply)
    The bash v2 replay of v2_confluence (60-bar windows, ML unavailable,
    sentiment na) with the quant percentile q_t blended exactly as
    calculate_confluence_score_v2 does with an applied agent:
    score = printf "%.0f" (awk printf "%.4f" core x (1 - w) + q x w), w =
    QUANT_RANK_WEIGHT (0.15), on the unrounded core; agents cast no votes,
    so the recommendation uses the v2 bull/bear counts. Without a
    percentile at t: the plain v2 result. Entries BUY/STRONG_BUY, exits
    SELL/STRONG_SELL, per-symbol sizing like v2_confluence; grid = risk grid
    (9). Baseline v2_confluence. The per-bar core (conf string, bull, bear)
    is cached in cache/agents/validate/signals/v2_core/<SYM>_<bars hash>.csv.

Percentiles: per date among the symbols with a score, 100 x (rank_asc - 1) /
(n - 1) rounded to 1 decimal (100 = best; ties by symbol order), as the
live envelopes (agents.quant.predict.rank_predictions); n < 2 -> none.
"""

from __future__ import annotations

import os
import re
import tempfile
from functools import lru_cache
from pathlib import Path
from typing import Any, Dict, Optional

import pandas as pd

from agents.cache import cache_root, check_symbol
from agents.signals.base import SignalFrame, SignalSpec, bars_hash, legacy_atr

REBALANCE_EVERY = 5
TOPK_GRID = [{"k": 5}, {"k": 10}, {"k": 20}]
QUANT_RANK_WEIGHT = 0.15
WINDOW = 60
ENTRY_RECS = ("BUY", "STRONG_BUY")
EXIT_RECS = ("SELL", "STRONG_SELL")
CORE_COLUMNS = ["conf", "bull", "bear"]
ARM_RE = re.compile(r"^[a-z0-9_]{1,32}$")


class PredictionsMissing(FileNotFoundError):
    """No OOS predictions parquet for the arm (run `quant train` first)."""


def predictions_file(arm: str, root: Optional[Path] = None) -> Path:
    if not ARM_RE.fullmatch(str(arm)):
        raise ValueError("invalid arm: %r" % (arm,))
    return (root or cache_root()) / "quant" / "predictions" / ("%s.parquet" % arm)


@lru_cache(maxsize=8)
def _wide(path: str, mtime_ns: int) -> pd.DataFrame:
    df = pd.read_parquet(path, columns=["datetime", "instrument", "score"])
    df["datetime"] = pd.to_datetime(df["datetime"]).dt.normalize()
    df["instrument"] = df["instrument"].astype(str).str.upper()
    wide = df.pivot_table(index="datetime", columns="instrument", values="score", aggfunc="last")
    wide = wide.sort_index().reindex(sorted(wide.columns), axis=1)
    wide.index = pd.DatetimeIndex(wide.index)
    wide.columns.name = None
    return wide.astype(float)


def _stat(arm: str):
    path = predictions_file(arm)
    try:
        st = path.stat()
    except FileNotFoundError:
        raise PredictionsMissing("no predictions for arm %s: %s" % (arm, path)) from None
    return str(path), st.st_mtime_ns


def load_ranks(arm: str) -> pd.DataFrame:
    """Wide DataFrame date x symbol of OOS scores (NaN = no prediction)."""
    return _wide(*_stat(arm))


@lru_cache(maxsize=8)
def _percentiles(path: str, mtime_ns: int) -> pd.DataFrame:
    wide = _wide(path, mtime_ns)
    asc = wide.rank(axis=1, method="first", ascending=True)
    n = wide.notna().sum(axis=1)
    denom = (n - 1).where(n >= 2)
    raw = asc.sub(1).div(denom, axis=0) * 100.0
    return raw.map(lambda v: round(float(v), 1) if pd.notna(v) else float("nan"))


def percentiles(arm: str) -> pd.DataFrame:
    """Wide date x symbol percentile 0..100 (100 = best) per date."""
    return _percentiles(*_stat(arm))


def rebalance_dates(index: pd.Index, every: int = REBALANCE_EVERY,
                    anchor: Optional[pd.Timestamp] = None) -> pd.DatetimeIndex:
    """Every EVERY-th date of INDEX starting at the first date >= ANCHOR
    (default: the first date of INDEX)."""
    idx = pd.DatetimeIndex(index).sort_values().unique()
    if anchor is not None:
        idx = idx[idx >= pd.Timestamp(anchor)]
    return idx[::max(int(every), 1)]


@lru_cache(maxsize=32)
def _top_sets(path: str, mtime_ns: int, k: int, every: int):
    wide = _wide(path, mtime_ns)
    out = {}
    for d in rebalance_dates(wide.index, every):
        row = wide.loc[d].dropna()
        ordered = sorted(row.items(), key=lambda kv: (-float(kv[1]), kv[0]))
        out[d] = frozenset(sym for sym, _ in ordered[:k])
    return out


def top_sets(arm: str, k: int, every: int = REBALANCE_EVERY) -> Dict[pd.Timestamp, frozenset]:
    """{rebalance date: set of the top K symbols}."""
    return _top_sets(*_stat(arm), int(k), int(every))


def topk_builder(arm: str):
    def build(df: pd.DataFrame, params: Dict[str, Any], symbol: str = "SYM") -> SignalFrame:
        k = int(params.get("k", 10))
        sets = top_sets(arm, k)
        entries = pd.Series(False, index=df.index)
        exits = pd.Series(False, index=df.index)
        for d, members in sets.items():
            if d in entries.index:
                if symbol in members:
                    entries.loc[d] = True
                else:
                    exits.loc[d] = True
        return SignalFrame(entries=entries, exits=exits, atr=legacy_atr(df),
                           extra={"arm": arm, "k": k, "rebalance_every": REBALANCE_EVERY})
    return build


# ---------------------------------------------------------------------------
# quant_rank: v2 core + quant percentile
# ---------------------------------------------------------------------------

def core_cache_file(symbol: str, df: pd.DataFrame, root: Optional[Path] = None) -> Path:
    check_symbol(symbol)
    return (root or cache_root()) / "validate" / "signals" / "v2_core" / ("%s_%s.csv" % (symbol, bars_hash(df)))


def compute_v2_core(df: pd.DataFrame, symbol: str = "SYM") -> pd.DataFrame:
    """Per bar: conf (unrounded v2 core string), bull, bear ('' / -1 for the
    first WINDOW-1 bars). Same window pipeline as v2_confluence."""
    from agents.technical import bash_compat as bc

    rows = []
    for i in range(len(df)):
        if i < WINDOW - 1:
            rows.append(("", -1, -1))
            continue
        window = df.iloc[i - WINDOW + 1:i + 1]
        ind = bc.calculate_all_indicators(symbol, window, "history")
        core = bc.score_stock(symbol, ind, ml_mode="unavailable", sentiment="na",
                              with_core=True)["confluence_v2"]["_core"]
        rows.append((str(core["conf"]), int(core["bull"]), int(core["bear"])))
    return pd.DataFrame(rows, index=df.index, columns=CORE_COLUMNS)


def _read_core(path: Path, index: pd.Index) -> Optional[pd.DataFrame]:
    try:
        fr = pd.read_csv(path, parse_dates=["date"], keep_default_na=False,
                         dtype={"conf": str, "bull": int, "bear": int}).set_index("date")
    except (OSError, ValueError, KeyError):
        return None
    if len(fr) != len(index) or not (fr.index == index).all():
        return None
    return fr[CORE_COLUMNS]


def _write_core(path: Path, frame: pd.DataFrame) -> None:
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


def v2_core(df: pd.DataFrame, symbol: str = "SYM", use_cache: bool = True) -> pd.DataFrame:
    path = core_cache_file(symbol, df)
    if use_cache and path.is_file():
        fr = _read_core(path, df.index)
        if fr is not None:
            return fr
    fr = compute_v2_core(df, symbol)
    if use_cache:
        _write_core(path, fr)
    return fr


def blend_recommendations(core: pd.DataFrame, q: pd.Series, w: float = QUANT_RANK_WEIGHT) -> pd.DataFrame:
    """Per bar {confluence_score, recommendation, quant_percentile} from the
    v2 core and the percentile Series Q (NaN = no quant score at t)."""
    from agents.technical.bash_compat import awk_num, printf_f, recommend

    q = q.reindex(core.index)
    scores, recs = [], []
    for conf, bull, bear, qv in zip(core["conf"], core["bull"], core["bear"], q.to_numpy()):
        if conf == "" or int(bull) < 0:
            scores.append(float("nan"))
            recs.append("")
            continue
        if pd.notna(qv) and w > 0:
            blended = format(awk_num(conf) * (1 - w) + float(qv) * w, ".4f")
            score = int(printf_f(blended, 0))
        else:
            score = int(printf_f(conf, 0))
        scores.append(score)
        recs.append(recommend(score, int(bull), int(bear))[0])
    return pd.DataFrame({"confluence_score": scores, "recommendation": recs,
                         "quant_percentile": q.to_numpy()}, index=core.index)


def quant_rank_builder(arm: str = "lgbm", w: float = QUANT_RANK_WEIGHT):
    def build(df: pd.DataFrame, params: Dict[str, Any], symbol: str = "SYM") -> SignalFrame:
        core = v2_core(df, symbol)
        pct = percentiles(arm)
        q = pct[symbol] if symbol in pct.columns else pd.Series(float("nan"), index=pct.index)
        fr = blend_recommendations(core, q, w)
        rec = fr["recommendation"]
        return SignalFrame(entries=rec.isin(ENTRY_RECS), exits=rec.isin(EXIT_RECS), atr=legacy_atr(df),
                           extra={"quant_rank": fr, "arm": arm, "w": w})
    return build


def _slots(params: Dict[str, Any]) -> Dict[str, Any]:
    return {"mode": "slots", "slots": int(params["k"])}


SPEC_QUANT_TOPK = SignalSpec(
    "quant_topk", TOPK_GRID, topk_builder("lgbm"),
    "LightGBM Alpha158+14 top-k long-only, 5-session rebalance",
    sizing=_slots, baseline_id="xgb_topk", quant_arm="lgbm", universe="quant")
SPEC_XGB_TOPK = SignalSpec(
    "xgb_topk", TOPK_GRID, topk_builder("xgb14"),
    "XGBoost 14 legacy features (the existing ML path on real data) top-k long-only, 5-session rebalance",
    sizing=_slots, quant_arm="xgb14", universe="quant")
SPEC_QUANT_RANK = SignalSpec(
    "quant_rank", [{}], quant_rank_builder("lgbm", QUANT_RANK_WEIGHT),
    "v2 confluence + quant percentile blend (w 0.15, as AGENT_QUANT_WEIGHT would apply)",
    baseline_id="v2_confluence", quant_arm="lgbm", universe="phase1")
