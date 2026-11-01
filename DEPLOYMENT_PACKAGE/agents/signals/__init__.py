"""Historical signals for the Strategy Validation Agent (plan D16/D18).

  v2_confluence      bash v2 scan score replayed on rolling 60-bar windows
                     (bash_compat.v2_from_bars; ML unavailable, sentiment na)
  v2_confluence_adx  the same with regime = TA-Lib regime_adx (real ADX14)
  mr_only            lib/backtest_engine.py MeanReversion rules, with a grid
  tf_only            lib/backtest_engine.py TrendFollow rules, with a grid

Every signal grid is crossed with the risk grid (base.RISK_GRID).
"""

from agents.signals.base import (  # noqa: F401
    RISK_GRID, SignalFrame, SignalSpec, full_grid, legacy_atr)


def get_signals():
    """{signal_id: SignalSpec} for the four Phase-1 signals (grid order fixed)."""
    from agents.signals.mean_reversion import SPEC as MR
    from agents.signals.trend_follow import SPEC as TF
    from agents.signals.v2_confluence import SPEC_V2, SPEC_V2_ADX

    return {s.signal_id: s for s in (SPEC_V2, SPEC_V2_ADX, MR, TF)}


SIGNAL_IDS = ("v2_confluence", "v2_confluence_adx", "mr_only", "tf_only")
