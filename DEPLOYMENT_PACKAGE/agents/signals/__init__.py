"""Historical signals for the Strategy Validation Agent (plan D16/D18).

  v2_confluence      bash v2 scan score replayed on rolling 60-bar windows
                     (bash_compat.v2_from_bars; ML unavailable, sentiment na)
  v2_confluence_adx  the same with regime = TA-Lib regime_adx (real ADX14)
  mr_only            lib/backtest_engine.py MeanReversion rules, with a grid
  tf_only            lib/backtest_engine.py TrendFollow rules, with a grid
Phase 2 (agents/signals/quant.py; need `quant train` predictions):
  quant_topk         LightGBM top-k long-only, 5-session rebalance, slots
  xgb_topk           the same on the XGBoost 14-feature arm (baseline)
  quant_rank         v2 replay + quant percentile blend (w 0.15)

Every signal grid is crossed with the risk grid (base.RISK_GRID).
SIGNAL_IDS (the `validate gate` default) stays the four Phase 1 ids.
"""

from agents.signals.base import (  # noqa: F401
    RISK_GRID, SignalFrame, SignalSpec, full_grid, legacy_atr)


def get_signals(include_quant: bool = False):
    """{signal_id: SignalSpec}: the four Phase-1 signals (grid order fixed);
    include_quant=True appends the Phase 2 quant signals (lazy import). The
    default stays the Phase 1 set (tests/test_agents_validate.py pins it)."""
    from agents.signals.mean_reversion import SPEC as MR
    from agents.signals.trend_follow import SPEC as TF
    from agents.signals.v2_confluence import SPEC_V2, SPEC_V2_ADX

    specs = [SPEC_V2, SPEC_V2_ADX, MR, TF]
    if include_quant:
        from agents.signals.quant import SPEC_QUANT_RANK, SPEC_QUANT_TOPK, SPEC_XGB_TOPK

        specs += [SPEC_XGB_TOPK, SPEC_QUANT_TOPK, SPEC_QUANT_RANK]
    return {s.signal_id: s for s in specs}


SIGNAL_IDS = ("v2_confluence", "v2_confluence_adx", "mr_only", "tf_only")
QUANT_SIGNAL_IDS = ("xgb_topk", "quant_topk", "quant_rank")
