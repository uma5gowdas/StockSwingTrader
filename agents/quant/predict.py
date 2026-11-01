"""Nightly quant predictions -> agent envelopes (plan Q16): `quant predict`.

run_predict(as_of): (real mode, unless refresh_data=False) refresh the raw
store + Qlib store for the quant universe (resume: current symbols are not
refetched), load the live model of ARM from models/latest.json, build the
arm's handler over the PREDICT_WINDOW sessions ending at the feature date
(the last store session <= as_of) and predict that date. The prediction is
ranked across the rank universe present at that date:
  percentile  100 * (rank_asc - 1) / (n - 1), 1 decimal (100 = best); n >= 2
  rank        1 = best
  direction   bullish >= 80, bearish <= 20, else neutral
  confidence  abs(percentile - 50) / 50
One envelope per rank-universe symbol (and per requested symbol) in
cache/agents/quant/<as_of>/<SYM>.json, ttl_hours QUANT_TTL_HOURS (84: a
Friday prediction is still fresh on Monday or after a holiday). Unavailable
envelopes: not_in_quant_universe, no_features_at_as_of, stale_data (newest
store session older than the staleness cutoff), universe_too_small.
validation = {gate_id: quant_rank, passed: the gate file's passed}.
A historical --as-of whose label lies inside the live model's data gets an
"IN-SAMPLE" warning (score kept; it is not out of sample).
"""

from __future__ import annotations

import os
from datetime import date
from typing import Any, Dict, Iterable, List, Optional

import pandas as pd

from agents.cache import check_as_of, gate_path, read_json, write_envelope
from agents.envelope import make_envelope, unavailable_envelope

AGENT = "quant"
GATE_ID = "quant_rank"
PREDICT_WINDOW = 130
DEFAULT_TTL_HOURS = 84.0
MODEL_MAX_AGE_DAYS = 400
DEFAULT_ARM = "lgbm"
BULLISH, BEARISH = 80.0, 20.0


class PredictionsUnavailable(RuntimeError):
    """No trained live model for the arm (run `quant train` first)."""


def ttl_hours() -> float:
    try:
        v = float(os.environ.get("QUANT_TTL_HOURS") or DEFAULT_TTL_HOURS)
    except ValueError:
        v = DEFAULT_TTL_HOURS
    return v if v > 0 else DEFAULT_TTL_HOURS


def direction_for(pct: float) -> str:
    if pct >= BULLISH:
        return "bullish"
    if pct <= BEARISH:
        return "bearish"
    return "neutral"


def rank_predictions(pred: pd.Series) -> pd.DataFrame:
    """DataFrame[instrument, prediction, rank, percentile] (rank 1 = best,
    ties broken by symbol order); needs >= 2 names."""
    s = pred.astype(float).sort_index()
    n = len(s)
    asc = s.rank(method="first", ascending=True)
    df = pd.DataFrame({"instrument": s.index, "prediction": s.to_numpy()})
    df["rank"] = (n - asc.to_numpy() + 1).astype(int)
    df["percentile"] = [round(100.0 * (a - 1) / (n - 1), 1) for a in asc.to_numpy()]
    return df


def gate_passed() -> bool:
    g = read_json(gate_path(GATE_ID))
    return bool(isinstance(g, dict) and g.get("passed") is True)


def _default_as_of(offline: bool, meta: Optional[dict]) -> str:
    if offline and meta and meta.get("calendar_end"):
        return str(meta["calendar_end"])
    from agents.data.alpaca import expected_last_session, ny_today

    return expected_last_session(ny_today()).isoformat()


def _raw_source(symbol: str, store_meta: dict):
    from agents.fixtures import FIXTURE_WARNING
    from agents.quant import raw

    m = raw.read_meta(symbol) or {}
    label = m.get("data_source") or (store_meta.get("data_sources") or {}).get(symbol) or "unknown"
    synthetic = bool(m.get("synthetic")) if m else bool(store_meta.get("synthetic"))
    warning = (m.get("warning") or FIXTURE_WARNING) if synthetic else None
    return label, synthetic, warning


def _predict_frame(arm_info: dict, model, market: str, calendar: pd.DatetimeIndex, feature_date) -> pd.Series:
    from qlib.data.dataset import DatasetH
    from qlib.data.dataset.handler import DataHandlerLP

    from agents.quant.handler import make_handler

    i = int(calendar.get_loc(feature_date))
    start = calendar[max(0, i - PREDICT_WINDOW)]
    h = make_handler(arm_info["handler"], market, start, feature_date)
    d = feature_date.strftime("%Y-%m-%d")
    ds = DatasetH(h, segments={"test": (d, d)})
    feats = ds.prepare("test", col_set="feature", data_key=DataHandlerLP.DK_I)
    if not len(feats):
        return pd.Series(dtype=float)
    ok = feats["SST_CLOSE_PRICE"].notna() if "SST_CLOSE_PRICE" in feats.columns else feats.notna().any(axis=1)
    pred = model.predict(ds, segment="test")
    pred = pred[ok.reindex(pred.index).fillna(False).to_numpy(dtype=bool)]
    pred.index = [idx[1] if isinstance(idx, tuple) else idx for idx in pred.index]
    return pred.dropna()


def run_predict(as_of: Optional[str] = None, offline: bool = False, symbols: Optional[Iterable[str]] = None,
                arm: str = DEFAULT_ARM, refresh_data: bool = True) -> Dict[str, Any]:
    """Write quant envelopes for AS_OF; returns {as_of, arm, model_id, written,
    unavailable, files}."""
    from agents.data.alpaca import staleness_cutoff
    from agents.fixtures import is_offline
    from agents.quant.store import read_store_meta, store_dir
    from agents.quant.train import ARMS, StoreUnavailable, load_model, read_latest

    if arm not in ARMS:
        raise ValueError("unknown arm: %r" % (arm,))
    offline = bool(offline) or is_offline()
    if offline:
        os.environ["SST_OFFLINE"] = "1"
    if as_of:
        check_as_of(as_of)
    if not offline and refresh_data:
        from agents.quant import universe
        from agents.quant.agent import ingest_and_build

        rank, bench = universe.rank_universe(False), universe.benchmarks(False)
        ingest_and_build(rank + bench, rank, bench, None, None, False, False)

    meta = read_store_meta()
    if not meta or not (store_dir() / "calendars" / "day.txt").is_file():
        raise StoreUnavailable("quant store not built (run: python -m agents quant ingest)")
    manifest = read_latest()
    arm_info = (manifest or {}).get("arms", {}).get(arm)
    live = (arm_info or {}).get("live") or {}
    if not live.get("model_path") or not os.path.isfile(live["model_path"]):
        raise PredictionsUnavailable("no live %s model (run: python -m agents quant train)" % arm)

    as_of_s = as_of or _default_as_of(offline, meta)
    as_of_ts = pd.Timestamp(as_of_s)
    rank_syms: List[str] = list(meta.get("rank_symbols") or [])
    requested = list(dict.fromkeys(symbols)) if symbols else []
    targets = list(dict.fromkeys(rank_syms + requested)) if not requested else requested
    rid = manifest["train_run_id"]
    model_id = "%s-%s" % (arm, rid)
    train_end = live.get("train_end")
    age_days = (as_of_ts.date() - date.fromisoformat(train_end)).days if train_end else None
    ttl = ttl_hours()
    passed = gate_passed()
    validation = {"gate_id": GATE_ID, "passed": passed}

    reasons: Dict[str, str] = {}
    ranked = None
    feature_date = None
    in_sample = False
    cal_end = pd.Timestamp(meta["calendar_end"])
    if cal_end.date() < staleness_cutoff(as_of_ts.date()):
        reasons = {s: "stale_data" for s in rank_syms}
    else:
        from agents.quant.qlib_env import init_qlib, quiet

        init_qlib()
        from qlib.data import D

        quiet()
        calendar = pd.DatetimeIndex(D.calendar(freq="day"))
        past = calendar[calendar <= as_of_ts]
        if not len(past):
            reasons = {s: "no_features_at_as_of" for s in rank_syms}
        else:
            feature_date = past[-1]
            in_sample = _in_sample(calendar, feature_date, train_end)
            model = load_model(live["model_path"])
            pred = _predict_frame(arm_info, model, meta.get("market") or "sst_us", calendar, feature_date)
            pred = pred[[s in rank_syms for s in pred.index]] if len(pred) else pred
            if len(pred) < 2:
                reasons = {s: "universe_too_small" if s in set(pred.index) else "no_features_at_as_of"
                           for s in rank_syms}
            else:
                ranked = rank_predictions(pred).set_index("instrument")
                reasons = {s: "no_features_at_as_of" for s in rank_syms if s not in ranked.index}

    written: List[str] = []
    unavailable: Dict[str, str] = {}
    files: List[str] = []
    n = 0 if ranked is None else int(len(ranked))
    for s in targets:
        label, synthetic, warning = _raw_source(s, meta)
        if s not in rank_syms:
            env = unavailable_envelope(AGENT, s, as_of_s, "not_in_quant_universe", ttl_hours=ttl,
                                       validation=validation)
        elif ranked is None or s not in ranked.index:
            env = unavailable_envelope(AGENT, s, as_of_s, reasons.get(s, "no_features_at_as_of"),
                                       synthetic=synthetic, warning=warning, ttl_hours=ttl, validation=validation)
        else:
            r = ranked.loc[s]
            pct = float(r["percentile"])
            warn = warning
            if age_days is not None and age_days > MODEL_MAX_AGE_DAYS:
                extra = "model older than %d days (%d)" % (MODEL_MAX_AGE_DAYS, age_days)
                warn = "%s; %s" % (warn, extra) if warn else extra
            if in_sample:
                extra = ("IN-SAMPLE: feature date %s and its label lie inside the live model's training data "
                         "(through %s); this score is not out of sample" % (feature_date.strftime("%Y-%m-%d"),
                                                                            train_end))
                warn = "%s; %s" % (warn, extra) if warn else extra
            env = make_envelope(
                AGENT, s, as_of_s,
                score=pct, direction=direction_for(pct), confidence=round(abs(pct - 50.0) / 50.0, 4),
                data_sources=[label], synthetic=synthetic, warning=warn,
                features={
                    "prediction": float(r["prediction"]), "rank": int(r["rank"]), "universe_size": n,
                    "percentile": pct, "arm": arm, "model_id": model_id, "model_train_end": train_end,
                    "model_age_days": age_days, "label": arm_info.get("label") or _label_expr(),
                    "feature_set": arm_info.get("feature_set"),
                    "feature_date": feature_date.strftime("%Y-%m-%d"),
                },
                ttl_hours=ttl, validation=validation,
            )
        files.append(str(write_envelope(env)))
        if env["available"]:
            written.append(s)
        else:
            unavailable[s] = env["reason"]
    return {"agent": AGENT, "as_of": as_of_s, "arm": arm, "model_id": model_id,
            "feature_date": feature_date.strftime("%Y-%m-%d") if feature_date is not None else None,
            "universe_size": n, "gate": validation, "written": written, "unavailable": unavailable,
            "files": files}


def _in_sample(calendar: pd.DatetimeIndex, feature_date: pd.Timestamp, train_end: Optional[str]) -> bool:
    """True when FEATURE_DATE's label (LABEL_HORIZON sessions ahead) was
    available inside the live model's data, which ends at TRAIN_END: a
    historical --as-of then gets an in-sample score. The nightly default
    (feature date = newest session) is never in sample."""
    from agents.quant.handler import LABEL_HORIZON

    if not train_end:
        return False
    upto = calendar[calendar <= pd.Timestamp(train_end)]
    if not len(upto):
        return False
    return int(calendar.get_loc(feature_date)) + LABEL_HORIZON <= len(upto) - 1


def _label_expr() -> str:
    from agents.quant.handler import LABEL_EXPR

    return LABEL_EXPR
