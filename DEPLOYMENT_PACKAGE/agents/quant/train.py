"""Quant model training (plan Q8-Q10): `python -m agents quant train`.

Arms (no hyperparameter search; model trial count 1):
  lgbm      LightGBM (qlib LGBModel) on Alpha158 + sst14 with Qlib's published
            Alpha158 benchmark parameters = the quant model
  xgb14     XGBoost (qlib XGBModel) on the 14 legacy features only with the
            lib/train_ml_model.py parameters = the baseline ("today's ML path
            retrained on real data")
  xgb_full  XGBoost, legacy parameters, Alpha158 + sst14 (IC diagnostic)

Each handler is built ONCE over the whole store calendar (data stays in
memory); every fold is a DatasetH over it. Real data: yearly folds (first
test year 2018); offline: two bar folds. Each fit runs inside a Qlib
recorder (MLflow file store cache_root()/quant/mlruns, experiment sst_quant,
recorder <arm>_<fold>) that keeps params, model.pkl and pred.pkl. Our own
artefacts (cache_root()/quant):
  models/<train_run_id>/<arm>/fold_<name>/model.pkl, .../live/model.pkl
  models/<train_run_id>/train_manifest.json, models/latest.json
  predictions/<arm>.parquet  (datetime, instrument, score, label, fold;
                              label = RAW open-to-open 5-day return)
QUANT_TEST_FAST=1 (tests only): 20 boosting rounds for every arm.
"""

from __future__ import annotations

import os
import pickle
import secrets
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

import pandas as pd

from agents.cache import atomic_write_json, cache_root, read_json
from agents.quant.handler import FEATURE_SETS, LABEL_EXPR, LABEL_NAME
from agents.quant.qlib_env import n_jobs

FIRST_TEST_YEAR = 2018
EMBARGO = 7
WARMUP = 60
FAST_ROUNDS = 20

LGBM_PARAMS = {
    "loss": "mse", "learning_rate": 0.2, "num_leaves": 210, "max_depth": 8,
    "colsample_bytree": 0.8879, "subsample": 0.8789, "lambda_l1": 205.6999, "lambda_l2": 580.9768,
    "early_stopping_rounds": 50, "num_boost_round": 1000, "seed": 42, "verbose": -1,
}
XGB_PARAMS = {"max_depth": 6, "eta": 0.1, "objective": "reg:squarederror", "seed": 42}
XGB_ROUNDS = 100

ARMS: Dict[str, Dict[str, Any]] = {
    "lgbm": {"handler": "alpha158_sst14", "model": "lgbm",
             "description": "LightGBM, Alpha158 + sst14, Qlib Alpha158 benchmark params"},
    "xgb14": {"handler": "sst14", "model": "xgb",
              "description": "XGBoost, the 14 legacy features, legacy params (baseline)"},
    "xgb_full": {"handler": "alpha158_sst14", "model": "xgb",
                 "description": "XGBoost, Alpha158 + sst14, legacy params (IC diagnostic)"},
}
DEFAULT_ARMS = ("lgbm", "xgb14", "xgb_full")


class StoreUnavailable(RuntimeError):
    """The Qlib store has not been built (run `quant ingest` first)."""


def fast_mode() -> bool:
    return os.environ.get("QUANT_TEST_FAST") == "1"


def models_dir() -> Path:
    return cache_root() / "quant" / "models"


def predictions_dir() -> Path:
    return cache_root() / "quant" / "predictions"


def new_train_run_id() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(3)


def parse_arms(raw: Optional[str]) -> List[str]:
    """'lgbm,xgb14' -> ['lgbm', 'xgb14']; ValueError on an unknown arm."""
    arms = [a.strip() for a in (raw or ",".join(DEFAULT_ARMS)).split(",") if a.strip()]
    bad = [a for a in arms if a not in ARMS]
    if bad or not arms:
        raise ValueError("unknown arm(s): %s (use %s)" % (",".join(bad) or "<none>", ",".join(ARMS)))
    return list(dict.fromkeys(arms))


def arm_params(arm: str) -> Dict[str, Any]:
    """Model parameters of ARM (QUANT_TEST_FAST=1 -> 20 rounds)."""
    if ARMS[arm]["model"] == "lgbm":
        p = dict(LGBM_PARAMS)
        p["num_threads"] = n_jobs()
        if fast_mode():
            p["num_boost_round"] = FAST_ROUNDS
        return p
    p = dict(XGB_PARAMS)
    p["nthread"] = n_jobs()
    p["num_boost_round"] = FAST_ROUNDS if fast_mode() else XGB_ROUNDS
    return p


def make_model(arm: str):
    p = arm_params(arm)
    if ARMS[arm]["model"] == "lgbm":
        from qlib.contrib.model.gbdt import LGBModel

        return LGBModel(**p)
    from qlib.contrib.model.xgboost import XGBModel

    return XGBModel(**{k: v for k, v in p.items() if k != "num_boost_round"})


def fit_model(arm: str, model, dataset) -> None:
    if ARMS[arm]["model"] == "lgbm":
        model.fit(dataset, verbose_eval=0)
        return
    # legacy path: fixed rounds, no early stopping (lib/train_ml_model.py)
    model.fit(dataset, num_boost_round=arm_params(arm)["num_boost_round"], early_stopping_rounds=None,
              verbose_eval=False, evals_result={})


def best_iteration(model) -> Optional[int]:
    booster = getattr(model, "model", None)
    for attr in ("best_iteration",):
        try:
            v = getattr(booster, attr, None)
        except Exception:  # xgboost raises when no early stopping
            v = None
        if v is not None:
            try:
                return int(v)
            except (TypeError, ValueError):
                return None
    return None


def _pickle(path: Path, obj) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(str(path) + ".tmp.%d" % os.getpid())
    try:
        with open(tmp, "wb") as fh:
            pickle.dump(obj, fh, protocol=pickle.HIGHEST_PROTOCOL)
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink()
    return path


def write_parquet(path: Path, df: pd.DataFrame) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(str(path) + ".tmp.%d" % os.getpid())
    try:
        df.to_parquet(tmp, index=False)
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink()
    return path


def load_model(path) -> Any:
    with open(path, "rb") as fh:
        return pickle.load(fh)  # our own artefact under cache_root() only


def read_latest() -> Optional[Dict[str, Any]]:
    """models/latest.json -> the manifest of the latest training run (or None)."""
    latest = read_json(models_dir() / "latest.json")
    if not isinstance(latest, dict) or not latest.get("train_run_id"):
        return None
    rid = str(latest["train_run_id"])
    if "/" in rid or ".." in rid:
        return None
    manifest = read_json(models_dir() / rid / "train_manifest.json")
    return manifest if isinstance(manifest, dict) else None


def _versions() -> Dict[str, Optional[str]]:
    out: Dict[str, Optional[str]] = {}
    for name in ("qlib", "lightgbm", "xgboost", "pandas", "numpy", "mlflow"):
        try:
            out[name] = __import__(name).__version__
        except Exception:
            out[name] = None
    return out


def _fold_frame(pred: pd.Series, labels: pd.DataFrame, fold: str) -> pd.DataFrame:
    df = pd.DataFrame({"score": pred.astype(float)})
    lab = labels.iloc[:, 0] if isinstance(labels, pd.DataFrame) else labels
    df["label"] = lab.reindex(df.index).astype(float)
    df["fold"] = fold
    df = df.reset_index()
    df = df.rename(columns={df.columns[0]: "datetime", df.columns[1]: "instrument"})
    return df[["datetime", "instrument", "score", "label", "fold"]]


def run_train(arms: Iterable[str] = DEFAULT_ARMS, offline: bool = False,
              first_test_year: int = FIRST_TEST_YEAR) -> Dict[str, Any]:
    """Train every arm on every fold + the live model; returns a summary."""
    from agents.quant import folds as F
    from agents.quant.handler import feature_count, make_handler
    from agents.quant.metrics import daily_ic, summarize_ic
    from agents.quant.qlib_env import init_qlib, mlruns_dir
    from agents.quant.store import read_store_meta, store_dir

    arms = parse_arms(",".join(arms))
    meta = read_store_meta()
    if not meta or not (store_dir() / "calendars" / "day.txt").is_file():
        raise StoreUnavailable("quant store not built (run: python -m agents quant ingest)")
    init_qlib(force=True)
    from qlib.data import D
    from qlib.data.dataset import DatasetH
    from qlib.data.dataset.handler import DataHandlerLP
    from qlib.workflow import R

    from agents.quant.qlib_env import quiet

    quiet()
    t_all = time.time()
    market = meta.get("market") or "sst_us"
    calendar = pd.DatetimeIndex(D.calendar(freq="day"))
    if offline:
        fold_list = F.bar_folds_offline(calendar, embargo=EMBARGO, warmup=WARMUP)
    else:
        fold_list = F.yearly_folds(calendar, first_test_year=first_test_year, embargo=EMBARGO, warmup=WARMUP)
    if not fold_list:
        raise StoreUnavailable("calendar too short for any fold (%d sessions)" % len(calendar))
    live = F.live_segment(calendar, embargo=EMBARGO, warmup=WARMUP)

    rid = new_train_run_id()
    run_dir = models_dir() / rid
    handlers: Dict[str, Any] = {}
    handler_seconds: Dict[str, float] = {}
    arm_out: Dict[str, Any] = {}
    summary_arms: Dict[str, Any] = {}
    for arm in arms:
        kind = ARMS[arm]["handler"]
        if kind not in handlers:
            t0 = time.time()
            handlers[kind] = make_handler(kind, market, calendar[0], calendar[-1])
            handler_seconds[kind] = round(time.time() - t0, 2)
        h = handlers[kind]
        params = arm_params(arm)
        t_arm = time.time()
        fold_rows: List[Dict[str, Any]] = []
        frames: List[pd.DataFrame] = []
        for seg in fold_list + [live]:
            ds = DatasetH(h, segments=seg.segments())
            n_train = len(ds.prepare("train", col_set="label", data_key=DataHandlerLP.DK_L))
            n_valid = len(ds.prepare("valid", col_set="label", data_key=DataHandlerLP.DK_L))
            model = make_model(arm)
            t0 = time.time()
            with R.start(experiment_name="sst_quant", recorder_name="%s_%s" % (arm, seg.name)):
                fit_model(arm, model, ds)
                fit_s = round(time.time() - t0, 2)
                R.log_params(arm=arm, fold=seg.name, train_run_id=rid, handler=kind,
                             segments=str(seg.segments()), params=str(params), n_train_rows=n_train)
                if seg.name == "live":
                    R.save_objects(**{"model.pkl": model})
                else:
                    pred = model.predict(ds, segment="test")
                    labels = ds.prepare("test", col_set="label", data_key=DataHandlerLP.DK_R)
                    R.save_objects(**{"model.pkl": model, "pred.pkl": pred})
            sub = "live" if seg.name == "live" else "fold_%s" % seg.name
            mpath = _pickle(run_dir / arm / sub / "model.pkl", model)
            row = {"name": seg.name, "segments": seg.to_dict(), "n_train": int(n_train), "n_valid": int(n_valid),
                   "best_iteration": best_iteration(model), "seconds": fit_s,
                   "model_path": str(mpath)}
            if seg.name == "live":
                live_row = row
                continue
            frame = _fold_frame(pred, labels, seg.name)
            row["n_test"] = int(len(frame))
            frames.append(frame)
            fold_rows.append(row)
        preds = pd.concat(frames, ignore_index=True) if frames else pd.DataFrame(
            columns=["datetime", "instrument", "score", "label", "fold"])
        ppath = write_parquet(predictions_dir() / ("%s.parquet" % arm), preds)
        seconds = round(time.time() - t_arm, 2)
        ic = summarize_ic(daily_ic(preds))
        arm_out[arm] = {
            "handler": kind, "feature_set": FEATURE_SETS[kind], "n_features": feature_count(h),
            "model": ARMS[arm]["model"], "params": params, "folds": fold_rows,
            "live": {"segments": live_row["segments"], "model_path": live_row["model_path"],
                     "n_train": live_row["n_train"], "n_valid": live_row["n_valid"],
                     "best_iteration": live_row["best_iteration"], "seconds": live_row["seconds"],
                     "train_end": live_row["segments"]["valid"][1]},
            "predictions_file": str(ppath), "prediction_rows": int(len(preds)),
            "seconds": seconds, "oos_ic": ic,
        }
        summary_arms[arm] = {"n_features": arm_out[arm]["n_features"], "folds": len(fold_rows),
                             "seconds": seconds, "prediction_rows": int(len(preds)),
                             "rank_ic_mean": ic["rank_ic_mean"], "rank_ic_t_nw": ic["rank_ic_t_nw"]}

    manifest = {
        "train_run_id": rid,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "mode": "offline" if offline else "real",
        "offline": bool(offline), "synthetic": bool(meta.get("synthetic")),
        "store": {"dir": str(store_dir()), "built_at": meta.get("built_at"), "market": market,
                  "rank_symbols": meta.get("rank_symbols"), "data_sources": meta.get("data_sources"),
                  "bars_sha12": meta.get("bars_sha12")},
        "calendar": {"start": calendar[0].strftime("%Y-%m-%d"), "end": calendar[-1].strftime("%Y-%m-%d"),
                     "sessions": int(len(calendar))},
        "label": {"name": LABEL_NAME, "expr": LABEL_EXPR},
        "embargo": EMBARGO, "warmup": WARMUP, "first_test_year": None if offline else int(first_test_year),
        "n_jobs": n_jobs(), "fast_mode": fast_mode(),
        "handler_seconds": handler_seconds,
        "mlruns": str(mlruns_dir()), "experiment": "sst_quant",
        "arms": arm_out,
        "versions": _versions(),
        "seconds": round(time.time() - t_all, 2),
    }
    atomic_write_json(run_dir / "train_manifest.json", manifest)
    atomic_write_json(models_dir() / "latest.json", {"train_run_id": rid, "generated_at": manifest["generated_at"]})
    return {
        "train_run_id": rid, "mode": manifest["mode"], "synthetic": manifest["synthetic"],
        "calendar": manifest["calendar"], "folds": [s.name for s in fold_list],
        "arms": summary_arms, "manifest": str(run_dir / "train_manifest.json"),
        "mlruns": manifest["mlruns"], "seconds": manifest["seconds"],
        "warning": ("Trained on offline fixture bars (generated, SYNTHETIC); not market data"
                    if manifest["synthetic"] else None),
    }
