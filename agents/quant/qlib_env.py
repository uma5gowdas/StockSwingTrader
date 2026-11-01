"""Qlib initialisation for the quant agent (plan Q10).

init_qlib() sets the environment Qlib/MLflow need BEFORE qlib is imported
(MLFLOW_ALLOW_FILE_STORE=true, MLFLOW_DISABLE_AGENT_HINT=1, and
MLFLOW_DISABLE_TELEMETRY=true + DO_NOT_TRACK=true: MLflow 3 would otherwise
send usage telemetry over HTTPS) and then calls
qlib.init with:
  provider_uri     the quant Qlib store (agents.quant.store.store_dir())
  region           REG_US
  kernels          1 (shared Mac; no joblib worker pool)
  expression_cache / dataset_cache  None (no disk cache next to the store)
  exp_manager      MLflowExpManager, file store cache_root()/quant/mlruns,
                   default experiment sst_quant (never ./mlruns)
  logging_level    WARNING
Calling it again with the same store and mlruns is a no-op; a different
store or mlruns re-initialises Qlib.

Nothing imports qlib at module import time of agents.cli / agents.quant.agent;
only functions that need Qlib call init_qlib().
"""

from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Optional, Tuple

EXPERIMENT = "sst_quant"
DEFAULT_N_JOBS = 4
_STATE: Optional[Tuple[str, str]] = None


def mlruns_dir() -> Path:
    from agents.cache import cache_root

    return cache_root() / "quant" / "mlruns"


def n_jobs() -> int:
    """QUANT_N_JOBS (default 4) clamped to 1..8; non-numeric -> 4."""
    try:
        n = int(os.environ.get("QUANT_N_JOBS", DEFAULT_N_JOBS))
    except (TypeError, ValueError):
        n = DEFAULT_N_JOBS
    return max(1, min(8, n))


def quiet() -> None:
    """Qlib / MLflow / LightGBM loggers to WARNING (also the child loggers
    Qlib creates with an explicit INFO level)."""
    prefixes = ("qlib", "mlflow", "lightgbm", "alembic")
    names = [n for n in list(logging.root.manager.loggerDict) if n.startswith(prefixes)]
    for name in set(prefixes) | set(names):
        logging.getLogger(name).setLevel(logging.WARNING)


_quiet = quiet


def init_qlib(store=None, mlruns=None, force: bool = False) -> Tuple[str, str]:
    """Initialise Qlib on STORE (default the quant store) with the MLflow
    file recorder at MLRUNS; returns (provider_uri, mlruns_uri). FORCE
    re-initialises (clears Qlib's memory cache, e.g. after a store rebuild)."""
    global _STATE
    os.environ.setdefault("MLFLOW_ALLOW_FILE_STORE", "true")
    os.environ.setdefault("MLFLOW_DISABLE_AGENT_HINT", "1")
    # MLflow 3 sends usage telemetry to mlflow-telemetry.io by default: off
    # (the agent layer makes no outbound call besides Alpaca market data)
    os.environ["MLFLOW_DISABLE_TELEMETRY"] = "true"
    os.environ["DO_NOT_TRACK"] = "true"
    from agents.quant.store import store_dir

    provider = str(Path(store or store_dir()).resolve())
    runs = Path(mlruns or mlruns_dir()).resolve()
    uri = "file:" + str(runs)
    if _STATE == (provider, uri) and not force:
        return _STATE
    runs.mkdir(parents=True, exist_ok=True)
    import qlib
    from qlib.constant import REG_US

    qlib.init(
        provider_uri=provider, region=REG_US, kernels=1,
        expression_cache=None, dataset_cache=None,
        exp_manager={"class": "MLflowExpManager", "module_path": "qlib.workflow.expm",
                     "kwargs": {"uri": uri, "default_exp_name": EXPERIMENT}},
        logging_level=logging.WARNING,
    )
    _quiet()
    _STATE = (provider, uri)
    return _STATE


def reset() -> None:
    """Forget the init state (tests switch caches between cases)."""
    global _STATE
    _STATE = None
