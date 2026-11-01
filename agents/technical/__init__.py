"""Technical Agent (Phase 1).

  bash_compat     exact Python port of the bash v2 scan pipeline
                  (lib/indicators.sh, lib/scoring.sh, detect_market_regime,
                  calculate_all_indicators/score_stock), quirks included
  talib_features  standard TA-Lib features incl. a real ADX(14) and
                  regime_adx (the bash regime rules with the real ADX)
  agent           `python -m agents technical run|status`
"""
