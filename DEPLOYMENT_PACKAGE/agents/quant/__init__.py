"""Quant research agent (Phase 2, Microsoft Qlib).

  universe.py         fixed universe file (survivorship bias stated)
  raw.py              resumable Alpaca raw-bar store (with VWAP)
  legacy_features.py  the 14 lib/ml_inference.py features as time series
  store.py            Qlib binary store writer
  qlib_env.py         qlib.init wrapper (REG_US, kernels=1, MLflow file store)
  handler.py          SSTAlpha158 (Alpha158 + sst14) and SST14Handler, label
  folds.py            yearly / live / offline folds with a 7-session embargo
  train.py            arms lgbm / xgb14 / xgb_full, OOS predictions, manifest
  metrics.py          IC, Rank-IC, Newey-West t, top-k and quintile spreads
  predict.py          live model -> quant envelopes (rank percentile)
  agent.py            CLI handlers (python -m agents quant ...)
Heavy imports (qlib, lightgbm, xgboost) stay inside functions.
"""
