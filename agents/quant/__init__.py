"""Quant research agent (Phase 2, Microsoft Qlib).

  universe.py         fixed universe file (survivorship bias stated)
  raw.py              resumable Alpaca raw-bar store (with VWAP)
  legacy_features.py  the 14 lib/ml_inference.py features as time series
  store.py            Qlib binary store writer
  agent.py            CLI handlers (python -m agents quant ...)
Heavy imports (qlib, lightgbm, xgboost) stay inside functions.
"""
