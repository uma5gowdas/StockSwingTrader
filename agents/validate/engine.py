"""vectorbt OSS backtest engine for the Strategy Validation Agent.

Two modes:

legacy_parity_backtest(df, signal)  (plan D21)
    Reproduces lib/backtest_engine.py BacktestEngine._execute_strategy:
    same-bar close fills, buy price close x (1 + 0.1 %), sell close x
    (1 - 0.1 %), commission 0.01 % of each side's value, long only, exit only
    on a -1 signal, an open position at the end is not a trade, integer shares
    int(cash / (close x 1.001) x 0.95). vectorbt's percent sizing divides by
    (1 + fees) and cannot express that share count exactly, so the share
    count of every entry is precomputed by replaying the legacy cash rule
    (legacy_entry_sizes) and passed to Portfolio.from_signals as
    size_type='amount' (still from_signals, not from_orders). vectorbt then
    does the fills, fees, slippage and P&L.

gate_backtest(bars, frames, params, costs)  (plan D17)
    Long only, next-bar-open fills: entries/exits decided at the close of t
    are shifted to t+1 and filled at its open (price=open). Stop loss =
    clip(stop_atr_mult x ATR14_t / close_t, 1 %, 15 %) taken at the signal
    bar (5 % = STOP_LOSS_PERCENT when ATR is undefined), take profit =
    take_profit_pct %; open/high/low/close are passed so stops trigger
    intrabar, relative to the fill price (StopEntryPrice.FillPrice) and filled
    as stop-market orders (the open when the bar gaps through the stop).
    Slippage AGENT_GATE_SLIPPAGE (default 0.001) per side, fees
    AGENT_GATE_FEES (default 0), integer shares, init cash split equally
    across the symbols (cash_sharing=False, group_by=True), freq='1D'.
    vectorbt semantics to know: a stop is not checked on the entry bar
    itself, and when a stop and a signal exit fall on the same bar the stop
    is taken (stop-first; conservative, since the signal exit would fill at
    that bar's open).

gate_backtest(..., sizing={'mode': 'slots', 'slots': k})  (Phase 2, Q12)
    Opt-in sizing for the quant top-k signals: one shared cash pool
    (cash_sharing=True, group_by=True, call_seq='auto' so exits on a bar are
    filled before entries), init_cash = the total (not per symbol), every
    entry buys integer shares worth init_cash / k at the open before
    slippage (size_type='value'; partial when less cash is left). The slot size is fixed: no compounding
    inside a window; each fold window starts with fresh cash (as without
    sizing). The cap of k open positions comes from the signal (at most k
    entries per rebalance, exits for every name that left the top k).
    per_symbol total_return = that column's trade P&L / (init_cash / k).
    sizing=None is exactly the per-symbol mode above.
"""

from __future__ import annotations

import importlib.util
import os
import warnings
from typing import Any, Dict, Optional

import numpy as np
import pandas as pd

from agents.config import PROJECT_ROOT
from agents.signals.base import SignalFrame

LEGACY_SLIPPAGE = 0.001
LEGACY_COMMISSION = 0.0001
LEGACY_INIT_CASH = 100000.0
LEGACY_SIZE_PCT = 0.95

MIN_STOP, MAX_STOP, FALLBACK_STOP = 0.01, 0.15, 0.05
GATE_INIT_CASH = 100000.0

_LEGACY = None


def _vbt():
    warnings.filterwarnings("ignore", category=FutureWarning)
    warnings.filterwarnings("ignore", category=DeprecationWarning)
    import vectorbt as vbt

    return vbt


def load_legacy_engine():
    """lib/backtest_engine.py as a module (importlib; works without yfinance)."""
    global _LEGACY
    if _LEGACY is None:
        import logging

        path = PROJECT_ROOT / "lib" / "backtest_engine.py"
        spec = importlib.util.spec_from_file_location("sst_legacy_backtest_engine", str(path))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        logging.getLogger("sst_legacy_backtest_engine").setLevel(logging.WARNING)
        _LEGACY = mod
    return _LEGACY


def gate_costs() -> Dict[str, Any]:
    """Gate cost assumptions (env-overridable)."""
    def _f(name, default):
        try:
            return float(os.environ.get(name, default))
        except ValueError:
            return float(default)
    return {
        "fill": "next_bar_open",
        "slippage_per_side": _f("AGENT_GATE_SLIPPAGE", 0.001),
        "fees_per_side": _f("AGENT_GATE_FEES", 0.0),
        "stop": "stop_atr_mult x ATR14 (signal bar), clamped 1-15 %, stop-market",
        "take_profit": "take_profit_pct above the fill",
        "sizing": "equal initial cash per symbol, all-in integer shares, no cash sharing",
        "init_cash": GATE_INIT_CASH,
    }


# ---------------------------------------------------------------------------
# Legacy parity
# ---------------------------------------------------------------------------

def legacy_entry_sizes(close: np.ndarray, signal: np.ndarray, slippage: float = LEGACY_SLIPPAGE,
                       commission: float = LEGACY_COMMISSION, init_cash: float = LEGACY_INIT_CASH) -> np.ndarray:
    """Share count at every bar where the legacy loop enters (0 elsewhere),
    replaying its cash rule: exit on -1 when long, enter on 1 when flat with
    int(cash / (close x (1 + slippage)) x 0.95) shares."""
    sizes = np.zeros(len(close))
    cash, pos, entry = float(init_cash), 0, 0.0
    for i in range(len(close)):
        s = signal[i]
        if pos != 0 and s == -1:
            px = close[i] * (1 - slippage)
            cash += pos * px - abs(pos * px) * commission
            pos = 0
        if pos == 0 and s == 1:
            entry = close[i] * (1 + slippage)
            pos = int(cash / entry * LEGACY_SIZE_PCT)
            cash -= pos * entry
            cash -= pos * entry * commission
            sizes[i] = pos
    return sizes


def legacy_parity_backtest(df: pd.DataFrame, signal: pd.Series, slippage: float = LEGACY_SLIPPAGE,
                           commission: float = LEGACY_COMMISSION,
                           init_cash: float = LEGACY_INIT_CASH) -> Dict[str, Any]:
    """vectorbt in legacy mode. Returns {trades (closed), pnl (sum of closed
    trade P&L), open_trades, trade_list}."""
    vbt = _vbt()
    close = pd.Series(df["close"].to_numpy(dtype=float), index=df.index)
    sig = pd.Series(signal, index=df.index).fillna(0).astype(int).to_numpy()
    sizes = legacy_entry_sizes(close.to_numpy(), sig, slippage, commission, init_cash)
    entries = pd.Series((sig == 1) & (sizes > 0), index=df.index)
    exits = pd.Series(sig == -1, index=df.index)
    pf = vbt.Portfolio.from_signals(
        close, entries, exits, size=pd.Series(sizes, index=df.index), size_type="amount",
        price=close, fees=commission, slippage=slippage, init_cash=init_cash,
        accumulate=False, direction="longonly", freq="1D")
    rec = pf.trades.values
    closed = rec[rec["status"] == 1]
    trade_list = [{
        "entry_time": df.index[int(r["entry_idx"])].strftime("%Y-%m-%d"),
        "exit_time": df.index[int(r["exit_idx"])].strftime("%Y-%m-%d"),
        "size": float(r["size"]), "entry_price": float(r["entry_price"]),
        "exit_price": float(r["exit_price"]), "pnl": float(r["pnl"]),
    } for r in closed]
    return {"trades": int(len(closed)), "pnl": float(closed["pnl"].sum()) if len(closed) else 0.0,
            "open_trades": int((rec["status"] == 0).sum()), "trade_list": trade_list}


def legacy_reference(df: pd.DataFrame, signal: pd.Series) -> Dict[str, Any]:
    """lib/backtest_engine.py BacktestEngine._execute_strategy on DF/SIGNAL:
    {trades, pnl, trade_list}."""
    mod = load_legacy_engine()
    eng = mod.BacktestEngine({"symbol": "PARITY", "start_date": str(df.index[0].date()),
                              "end_date": str(df.index[-1].date())})
    _eq, _ret, trades = eng._execute_strategy(df, pd.Series(signal, index=df.index))
    return {"trades": len(trades), "pnl": float(sum(t["pnl"] for t in trades)), "trade_list": trades}


def legacy_signals(df: pd.DataFrame, strategy: str) -> pd.Series:
    """The legacy generate_signals for 'mean_reversion' | 'trend_follow'."""
    mod = load_legacy_engine()
    if strategy == "mean_reversion":
        strat = mod.MeanReversionStrategy({"rsi_buy": 30, "rsi_sell": 70, "bb_std": 2.0})
    elif strategy == "trend_follow":
        strat = mod.TrendFollowStrategy({})
    else:
        raise ValueError("unknown legacy strategy: %r" % (strategy,))
    return strat.generate_signals(df)


def parity_ok(legacy: Dict[str, Any], vbt_res: Dict[str, Any]) -> bool:
    """Trade counts equal and |pnl diff| <= 1 % of |legacy pnl| (or <= $1
    when |legacy pnl| < $100)."""
    if legacy["trades"] != vbt_res["trades"]:
        return False
    diff = abs(legacy["pnl"] - vbt_res["pnl"])
    if abs(legacy["pnl"]) < 100:
        return diff <= 1.0
    return diff <= 0.01 * abs(legacy["pnl"])


# ---------------------------------------------------------------------------
# Gate mode
# ---------------------------------------------------------------------------

def stop_fraction(frame: SignalFrame, close: pd.Series, stop_atr_mult: float) -> pd.Series:
    """clip(stop_atr_mult x ATR14 / close, 1 %, 15 %) per bar; 5 % without ATR."""
    with np.errstate(divide="ignore", invalid="ignore"):
        raw = stop_atr_mult * frame.atr.astype(float) / close.astype(float)
    return raw.clip(MIN_STOP, MAX_STOP).fillna(FALLBACK_STOP)


def gate_backtest(bars: Dict[str, pd.DataFrame], frames: Dict[str, SignalFrame], params: Dict[str, Any],
                  costs: Optional[Dict[str, Any]] = None, init_cash: float = GATE_INIT_CASH,
                  index: Optional[pd.Index] = None, sizing: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Gate-mode backtest over the symbols of FRAMES (bars aligned on INDEX,
    default the intersection of the bar indexes).

    Returns {returns: daily group returns Series, equity: group value Series,
    trades: number of trades (closed + open), closed_trades, per_symbol:
    {SYM: {trades, total_return}}}. SIZING: None (equal cash per symbol, all
    in) or {'mode': 'slots', 'slots': k} (shared cash, k fixed slots).
    """
    vbt = _vbt()
    costs = costs or gate_costs()
    syms = sorted(frames)
    if index is None:
        index = None
        for s in syms:
            index = bars[s].index if index is None else index.intersection(bars[s].index)
    cols = {}
    for k in ("open", "high", "low", "close"):
        cols[k] = pd.DataFrame({s: bars[s][k].reindex(index).astype(float) for s in syms}, index=index)
    ent, ext, sl = {}, {}, {}
    for s in syms:
        fr = frames[s]
        e = fr.entries.reindex(index).fillna(False).astype(bool)
        x = fr.exits.reindex(index).fillna(False).astype(bool)
        st = stop_fraction(fr, bars[s]["close"], float(params.get("stop_atr_mult", 2.0))).reindex(index)
        ent[s] = e.shift(1, fill_value=False).astype(bool)
        ext[s] = x.shift(1, fill_value=False).astype(bool)
        sl[s] = st.shift(1).fillna(FALLBACK_STOP)
    entries = pd.DataFrame(ent, index=index)
    exits = pd.DataFrame(ext, index=index)
    sl_stop = pd.DataFrame(sl, index=index)
    tp = float(params.get("take_profit_pct", 8)) / 100.0
    if sizing is not None:
        return _gate_backtest_slots(vbt, syms, cols, entries, exits, sl_stop, tp, costs, init_cash, sizing)
    per_cash = float(init_cash) / max(len(syms), 1)
    pf = vbt.Portfolio.from_signals(
        cols["close"], entries, exits, price=cols["open"], open=cols["open"], high=cols["high"],
        low=cols["low"], sl_stop=sl_stop, tp_stop=tp,
        stop_entry_price="fillprice", stop_exit_price="stopmarket",
        fees=float(costs["fees_per_side"]), slippage=float(costs["slippage_per_side"]),
        size=np.inf, size_granularity=1, init_cash=per_cash, cash_sharing=False, group_by=True,
        accumulate=False, direction="longonly", freq="1D")
    value = pf.value()
    returns = pf.returns()
    rec = pf.trades.values
    per_symbol = {}
    col_value = pf.value(group_by=False)
    for j, s in enumerate(syms):
        r = rec[rec["col"] == j]
        v = col_value[s]
        per_symbol[s] = {"trades": int(len(r)),
                         "total_return": float(v.iloc[-1] / per_cash - 1.0) if len(v) else 0.0}
    return {"returns": returns, "equity": value, "trades": int(len(rec)),
            "closed_trades": int((rec["status"] == 1).sum()), "per_symbol": per_symbol, "portfolio": pf}


def _gate_backtest_slots(vbt, syms, cols, entries, exits, sl_stop, tp, costs, init_cash, sizing) -> Dict[str, Any]:
    """Shared-cash slot sizing (see the module docstring)."""
    if sizing.get("mode") != "slots":
        raise ValueError("unknown sizing mode: %r" % (sizing.get("mode"),))
    k = int(sizing.get("slots") or 0)
    if k < 1:
        raise ValueError("slots must be >= 1")
    slot = float(init_cash) / k
    pf = vbt.Portfolio.from_signals(
        cols["close"], entries, exits, price=cols["open"], open=cols["open"], high=cols["high"],
        low=cols["low"], sl_stop=sl_stop, tp_stop=tp,
        stop_entry_price="fillprice", stop_exit_price="stopmarket",
        fees=float(costs["fees_per_side"]), slippage=float(costs["slippage_per_side"]),
        size=slot, size_type="value", size_granularity=1, init_cash=float(init_cash),
        cash_sharing=True, group_by=True, call_seq="auto",
        accumulate=False, direction="longonly", freq="1D")
    rec = pf.trades.values
    per_symbol = {}
    for j, s in enumerate(syms):
        r = rec[rec["col"] == j]
        per_symbol[s] = {"trades": int(len(r)),
                         "total_return": float(r["pnl"].sum() / slot) if len(r) else 0.0}
    return {"returns": pf.returns(), "equity": pf.value(), "trades": int(len(rec)),
            "closed_trades": int((rec["status"] == 1).sum()), "per_symbol": per_symbol, "portfolio": pf,
            "sizing": {"mode": "slots", "slots": k, "slot_cash": slot}}
