"""Strategy Validation Agent: `python -m agents validate gate|parity|status`.

gate   [--signals v2_confluence,v2_confluence_adx,mr_only,tf_only]
       [--symbols ...] [--benchmark SPY] [--start 2016-01-01] [--end <last
       session>] [--offline] [--report-dir DIR]
       Loads daily bars for the universe + benchmark (agents.data.load_bars;
       WARMUP_DAYS extra calendar days before --start). Any symbol or the
       benchmark unavailable -> error JSON, exit 2, no gate files. Otherwise,
       per signal: build the signal frames on the full series, run the
       walk-forward (real: calendar 2y/6m/6m from --start; offline: bar
       folds 252/126 x 2) with train-only tuning, the full-sample grid (PBO,
       DSR trial Sharpes), the SPY and equal-weight benchmarks over the same
       test windows, the §5.6 criteria; write the gate file, the trial log
       and the report; print {run_id, report_html, gates: {id: {passed,
       failed_criteria}}} and exit 0 (a failed gate is a valid result).
parity [--offline] [--symbols ...]
       lib/backtest_engine.py vs vectorbt legacy mode for mean reversion and
       trend follow per symbol; exit 1 on any trade-count mismatch or a P&L
       difference > 1 % of |legacy P&L| (> $1 when |legacy P&L| < $100);
       exit 2 without data.
status Gate files with passed / status / age_days / data_sources.

Read-only: market-data GETs through agents.data only (paper asserted by the
Alpaca client); nothing here can place, cancel or modify orders.
"""

from __future__ import annotations

import argparse
import math
import os
import secrets
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

import numpy as np
import pandas as pd

from agents import __version__
from agents.envelope import utc_now_iso

AGENT = "validate"
OFFLINE_FOLDS = {"train_bars": 252, "test_bars": 126, "n_folds": 2}
REAL_FOLDS = {"train_years": 2, "test_months": 6, "step_months": 6}
PBO_S_REAL = 16
PBO_S_OFFLINE = 8
MAX_CURVE_POINTS = 400


def _clean(x: Any) -> Any:
    """JSON-safe copy (NaN/inf -> None, numpy scalars -> Python)."""
    if isinstance(x, dict):
        return {str(k): _clean(v) for k, v in x.items()}
    if isinstance(x, (list, tuple)):
        return [_clean(v) for v in x]
    if isinstance(x, (np.bool_,)):
        return bool(x)
    if isinstance(x, (np.integer,)):
        return int(x)
    if isinstance(x, (float, np.floating)):
        f = float(x)
        return f if math.isfinite(f) else None
    return x


def new_run_id() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(3)


def _span(dates: pd.DatetimeIndex, fallback: List[str]) -> List[str]:
    """[first bar, last bar] (inclusive) of DATES, else FALLBACK boundaries."""
    if len(dates):
        return [str(dates[0].date()), str(dates[-1].date())]
    return list(fallback)


def _downsample(vals: List[float], n: int = MAX_CURVE_POINTS) -> List[float]:
    if len(vals) <= n:
        return [float(v) for v in vals]
    idx = np.linspace(0, len(vals) - 1, n).round().astype(int)
    return [float(vals[i]) for i in idx]


# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------

def _default_end(offline: bool) -> Optional[str]:
    if offline:
        return None
    from agents.data.alpaca import expected_last_session, ny_today

    return expected_last_session(ny_today()).isoformat()


def load_universe(symbols: List[str], benchmark: str, start: Optional[str], end: Optional[str],
                  offline: bool, client=None) -> Dict[str, Any]:
    """{bars: {SYM: BarsResult}, unavailable: {SYM: reason}} for SYMBOLS + BENCHMARK."""
    from agents.data import load_bars
    from agents.validate.universe import WARMUP_DAYS

    if offline:
        os.environ["SST_OFFLINE"] = "1"
    s = pd.Timestamp(start) - pd.Timedelta(days=WARMUP_DAYS) if start else pd.Timestamp("1990-01-01")
    e = pd.Timestamp(end) if end else pd.Timestamp("2100-01-01")
    wanted = list(dict.fromkeys(list(symbols) + [benchmark]))
    res = load_bars(wanted, s.date(), e.date(), as_of=e.date() if end else None, client=client)
    bars, unavailable = {}, {}
    for sym in wanted:
        r = res.get(sym)
        if r is None or not getattr(r, "available", False):
            unavailable[sym] = getattr(r, "reason", None) or "no data"
        elif len(r.df) < 60:
            unavailable[sym] = "insufficient bars: %d" % len(r.df)
        else:
            bars[sym] = r
    return {"bars": bars, "unavailable": unavailable}


# ---------------------------------------------------------------------------
# Gate run
# ---------------------------------------------------------------------------

class _SignalRun:
    """Walk-forward + full-sample evaluation of one signal on one universe."""

    def __init__(self, spec, bars: Dict[str, pd.DataFrame], index: pd.DatetimeIndex, costs: Dict[str, Any]):
        self.spec = spec
        self.bars = bars
        self.index = index
        self.costs = costs
        self._frames: Dict[Any, Dict[str, Any]] = {}
        self.n_evaluations = 0

    def frames(self, cfg: Dict[str, Any]):
        from agents.signals.base import signal_params

        key = tuple(sorted(signal_params(cfg).items()))
        if key not in self._frames:
            self._frames[key] = {s: self.spec.build(df, cfg, s) for s, df in self.bars.items()}
        return self._frames[key]

    def evaluate(self, cfg: Dict[str, Any], start: pd.Timestamp, end: pd.Timestamp) -> Dict[str, Any]:
        from agents.validate.engine import gate_backtest
        from agents.validate.stats import sharpe
        from agents.validate.walkforward import slice_index

        idx = slice_index(self.index, start, end)
        self.n_evaluations += 1
        if len(idx) < 2:
            return {"sharpe": 0.0, "returns": pd.Series(0.0, index=idx), "trades": 0}
        res = gate_backtest(self.bars, self.frames(cfg), cfg, self.costs, index=idx)
        r = res["returns"].fillna(0.0)
        return {"sharpe": sharpe(r), "returns": r, "trades": res["trades"], "per_symbol": res["per_symbol"]}


def run_signal(spec, bars_res: Dict[str, Any], symbols: List[str], benchmark: str, offline: bool,
               start: Optional[str], run_id: str, costs: Dict[str, Any]) -> Dict[str, Any]:
    """Gate dict + curves for one signal (does not write files)."""
    from agents.validate import benchmarks as bm
    from agents.validate import stats as st
    from agents.validate import trials as tr
    from agents.validate.gate import decide, evaluate_criteria, thresholds
    from agents.validate.walkforward import bar_folds, calendar_folds, slice_index, walk_forward

    bars = {s: bars_res[s].df for s in symbols}
    index = None
    for s in symbols:
        index = bars[s].index if index is None else index.intersection(bars[s].index)
    index = pd.DatetimeIndex(index).sort_values()
    if offline:
        folds = bar_folds(index, **OFFLINE_FOLDS)
        wf_desc = dict(OFFLINE_FOLDS, mode="bars")
        full_start = folds[0].train_start if folds else index[0]
    else:
        folds = calendar_folds(index, start=start, **REAL_FOLDS)
        wf_desc = dict(REAL_FOLDS, mode="calendar", start=start)
        full_start = folds[0].train_start if folds else pd.Timestamp(start)
    full_end = index[-1] + pd.Timedelta(days=1)
    data_range = {"start": str(index[index >= full_start][0].date()) if len(index[index >= full_start]) else
                  str(index[0].date()), "end": str(index[-1].date())}
    universe = list(symbols)
    configs = spec.grid()
    runner = _SignalRun(spec, bars, index, costs)
    sources = {s: bars_res[s].data_source for s in symbols + [benchmark]}
    synthetic = any(bars_res[s].synthetic for s in symbols + [benchmark])
    main_source = ",".join(sorted(set(sources.values())))

    records: List[Dict[str, Any]] = []

    def chash(cfg):
        return tr.config_hash(dict(cfg, signal_id=spec.signal_id), costs, universe, data_range)

    def on_eval(cfg, fold, phase, r):
        records.append({"run_id": run_id, "signal_id": spec.signal_id, "config_hash": chash(cfg),
                        "params": cfg, "fold": fold, "phase": phase, "sharpe": _clean(r["sharpe"]),
                        "trades": int(r["trades"]), "data_source": main_source})

    wf = walk_forward(runner.evaluate, configs, folds, on_eval=on_eval)

    slip = float(costs["slippage_per_side"])
    spy_df = bars_res[benchmark].df
    fold_out, oos_parts, spy_parts, ew_parts = [], [], [], []
    for f, w in zip(folds, wf):
        t = w["test_result"]
        dates = t["returns"].index
        spy_r = bm.spy_buy_hold(spy_df, dates, slip)
        ew_r = bm.equal_weight_buy_hold(bars, dates, slip)
        oos_parts.append(t["returns"])
        spy_parts.append(spy_r)
        ew_parts.append(ew_r)
        tr_dates = slice_index(index, f.train_start, f.train_end)
        fold_out.append({"fold": w["fold"], "train": _span(tr_dates, w["train"]), "test": _span(dates, w["test"]),
                         "params": w["params"], "train_sharpe": _clean(w["train_sharpe"]),
                         "oos_sharpe": _clean(st.sharpe(t["returns"])),
                         "oos_return": _clean(bm.fold_return(t["returns"])),
                         "spy_return": _clean(bm.fold_return(spy_r)), "ew_return": _clean(bm.fold_return(ew_r)),
                         "trades": int(t["trades"])})
    oos = bm.pooled(oos_parts)
    spy = bm.pooled(spy_parts)
    ew = bm.pooled(ew_parts)

    # Full-sample grid: trial Sharpes for the DSR and the T x N matrix for PBO
    full_cols, trial_srs = {}, []
    default_sr = None
    from agents.signals.base import DEFAULT_RISK
    for i, cfg in enumerate(configs):
        r = runner.evaluate(cfg, full_start, full_end)
        on_eval(cfg, None, "full", r)
        full_cols[i] = r["returns"]
        trial_srs.append(st.sharpe_per_period(r["returns"]))
        if default_sr is None and all(cfg.get(k) == v for k, v in DEFAULT_RISK.items()):
            default_sr = r["sharpe"]
    M = pd.DataFrame(full_cols).fillna(0.0)
    S = PBO_S_OFFLINE if offline else PBO_S_REAL
    if not offline and len(M) < PBO_S_REAL * 20:
        S = PBO_S_OFFLINE
    pbo = st.pbo_cscv(M.to_numpy(), S=S) if len(configs) > 1 else {"pbo": None, "S": S, "lambda": None}

    tr.append_trials(records)
    n_trials = tr.n_trials(spec.signal_id, len(configs))
    mom = st.moments(oos)
    sr_pp = st.sharpe_per_period(oos)
    sr0 = st.expected_max_sr(trial_srs, n_trials)
    oos_sum = st.summarize_returns(oos)
    spy_sum = st.summarize_returns(spy)
    ew_sum = st.summarize_returns(ew)
    n_pos = sum(1 for f in fold_out if (f["oos_return"] or 0) > 0)
    metrics = {
        "oos_sharpe": oos_sum["sharpe"], "oos_cagr": oos_sum["cagr"], "oos_max_dd": oos_sum["max_dd"],
        "oos_trades": int(sum(f["trades"] for f in fold_out)), "oos_days": int(len(oos)),
        "pct_positive_folds": (n_pos / len(fold_out)) if fold_out else None,
        "spy_sharpe": spy_sum["sharpe"], "spy_max_dd": spy_sum["max_dd"], "spy_cagr": spy_sum["cagr"],
        "ew_sharpe": ew_sum["sharpe"], "ew_max_dd": ew_sum["max_dd"], "ew_cagr": ew_sum["cagr"],
        "dsr": st.dsr(sr_pp, trial_srs, mom["T"], mom["skew"], mom["kurt"], n_trials) if len(oos) > 1 else None,
        "psr": st.psr(sr_pp, mom["T"], mom["skew"], mom["kurt"], 0.0) if len(oos) > 1 else None,
        "pbo": pbo.get("pbo"), "pbo_S": pbo.get("S"), "pbo_lambda": pbo.get("lambda"),
        "sr0_per_period": sr0, "n_trials": int(n_trials), "grid_size": len(configs),
        "n_evaluations": int(runner.n_evaluations), "full_sample_default_sharpe": default_sr,
    }
    metrics = _clean(metrics)
    th = thresholds()
    criteria = evaluate_criteria(metrics, th)
    passed, reasons = decide(criteria, synthetic, sources)
    warning = None
    if synthetic:
        warning = "Gate computed on SYNTHETIC data (offline fixtures); it can never pass."
    gate = {
        "signal_id": spec.signal_id, "agent": AGENT, "agent_version": __version__,
        "generated_at": utc_now_iso(), "run_id": run_id, "mode": "offline" if offline else "real",
        "description": spec.description, "passed": bool(passed), "synthetic": bool(synthetic),
        "data_sources": sorted(set(sources.values())), "symbol_sources": sources,
        "universe": universe, "benchmark": benchmark, "data_range": data_range,
        "walk_forward": _clean(dict(wf_desc, n_folds=len(folds))), "folds": _clean(fold_out),
        "metrics": metrics, "criteria": _clean(criteria), "thresholds": th, "costs": _clean(costs),
        "config_hash": tr.config_hash({"signal_id": spec.signal_id, "grid": configs, "walk_forward": wf_desc},
                                      costs, universe, data_range),
        "reasons": reasons, "warning": warning,
    }
    curves = {
        "strategy": _downsample(list(st.equity_from_returns(oos))),
        "spy": _downsample(list(st.equity_from_returns(spy))),
        "equal_weight": _downsample(list(st.equity_from_returns(ew))),
    }
    return {"gate": gate, "curves": curves}


def parity_results(bars: Dict[str, pd.DataFrame]) -> Dict[str, Any]:
    """Legacy engine vs vectorbt legacy mode per symbol for both strategies."""
    from agents.signals.mean_reversion import mr_signal
    from agents.signals.trend_follow import tf_signal
    from agents.validate import engine as E

    results = []
    for sym in sorted(bars):
        df = bars[sym]
        for name, port in (("mean_reversion", mr_signal(df)), ("trend_follow", tf_signal(df))):
            leg_sig = E.legacy_signals(df, name)
            L = E.legacy_reference(df, leg_sig)
            V = E.legacy_parity_backtest(df, port)
            ok = E.parity_ok(L, V)
            results.append({"symbol": sym, "strategy": name,
                            "signals_equal": bool((leg_sig.to_numpy() == port.to_numpy()).all()),
                            "legacy_trades": L["trades"], "vbt_trades": V["trades"],
                            "legacy_pnl": round(L["pnl"], 6), "vbt_pnl": round(V["pnl"], 6),
                            "pnl_diff": round(abs(L["pnl"] - V["pnl"]), 6), "ok": bool(ok)})
    totals = {}
    for name in ("mean_reversion", "trend_follow"):
        rows = [r for r in results if r["strategy"] == name]
        totals[name] = {"legacy_trades": sum(r["legacy_trades"] for r in rows),
                        "vbt_trades": sum(r["vbt_trades"] for r in rows)}
    return {"ok": all(r["ok"] for r in results) and bool(results), "results": results, "totals": totals,
            "sizing": "from_signals size_type=amount with legacy-replayed integer share counts"}


def run_gate(signal_ids: List[str], symbols: List[str], benchmark: str, start: Optional[str],
             end: Optional[str], offline: bool, report_dir: Optional[str] = None, client=None) -> Dict[str, Any]:
    """Whole gate run. Returns {exit, summary} (summary printed by the CLI)."""
    from agents.signals import get_signals
    from agents.validate.engine import gate_costs
    from agents.validate.gate import write_gate
    from agents.validate.report import report_dir as _report_dir, write_report

    specs = get_signals()
    unknown = [s for s in signal_ids if s not in specs]
    if unknown:
        return {"exit": 1, "summary": {"error": "unknown_signal", "signals": unknown, "known": list(specs)}}
    if not offline and not start:
        from agents.validate.universe import REAL_START

        start = REAL_START
    if not end:
        end = _default_end(offline)
    data = load_universe(symbols, benchmark, start, end, offline, client=client)
    if data["unavailable"]:
        return {"exit": 2, "summary": {"error": "market_data_unavailable", "agent": AGENT,
                                       "unavailable": data["unavailable"],
                                       "detail": "no gate files written"}}
    bars_res = data["bars"]  # incl. WARMUP_DAYS before START; folds start at START
    run_id = new_run_id()
    costs = gate_costs()
    gates, curves, files = [], {}, []
    for sid in signal_ids:
        out = run_signal(specs[sid], bars_res, list(symbols), benchmark, offline, start, run_id, costs)
        files.append(str(write_gate(out["gate"])))
        gates.append(out["gate"])
        curves[sid] = out["curves"]
    parity = parity_results({s: bars_res[s].df for s in symbols})
    synthetic = any(g["synthetic"] for g in gates)
    meta = {
        "run_id": run_id, "generated_at": utc_now_iso(), "mode": "offline" if offline else "real",
        "agent_version": __version__, "universe": list(symbols), "benchmark": benchmark,
        "data_range": gates[0]["data_range"] if gates else None,
        "data_sources": sorted({src for g in gates for src in g["data_sources"]}),
        "walk_forward": gates[0]["walk_forward"] if gates else None, "costs": costs,
        "synthetic": synthetic, "signals": list(signal_ids), "gate_files": files,
        "notes": (["Offline mode: bar folds 252/126 x 2 and PBO with S=%d (short series)." % PBO_S_OFFLINE]
                  if offline else []),
    }
    out_dir = _report_dir(run_id, report_dir)
    paths = write_report(out_dir, _clean(meta), gates, curves, _clean(parity))
    summary = {
        "run_id": run_id, "report_html": paths["report_html"], "report_json": paths["report_json"],
        "synthetic": synthetic,
        "gates": {g["signal_id"]: {"passed": g["passed"],
                                   "failed_criteria": [k for k, c in g["criteria"].items()
                                                       if c.get("applicable") and not c.get("passed")],
                                   "reasons": g["reasons"]} for g in gates},
        "legacy_parity_ok": parity["ok"],
    }
    return {"exit": 0, "summary": summary}


def run_parity(symbols: List[str], start: Optional[str], end: Optional[str], offline: bool,
               client=None) -> Dict[str, Any]:
    if not offline and not start:
        from agents.validate.universe import REAL_START

        start = REAL_START
    if not end:
        end = _default_end(offline)
    from agents.data import load_bars

    if offline:
        os.environ["SST_OFFLINE"] = "1"
    s = pd.Timestamp(start).date() if start else pd.Timestamp("1990-01-01").date()
    e = pd.Timestamp(end).date() if end else pd.Timestamp("2100-01-01").date()
    res = load_bars(symbols, s, e, as_of=e if (end or offline) else None, client=client)
    unavailable = {k: getattr(v, "reason", "no data") for k, v in res.items() if not getattr(v, "available", False)}
    if unavailable:
        return {"exit": 2, "summary": {"error": "market_data_unavailable", "agent": AGENT,
                                       "unavailable": unavailable}}
    out = parity_results({k: v.df for k, v in res.items()})
    out["data_sources"] = {k: v.data_source for k, v in res.items()}
    out["synthetic"] = any(v.synthetic for v in res.values())
    return {"exit": 0 if out["ok"] else 1, "summary": _clean(out)}


def status() -> Dict[str, Any]:
    from agents.cache import cache_root
    from agents.validate.gate import read_gates

    now = datetime.now(timezone.utc)
    items = []
    for g in read_gates():
        age = None
        try:
            t = datetime.strptime(g.get("generated_at", ""), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            age = round((now - t).total_seconds() / 86400.0, 2)
        except (TypeError, ValueError):
            pass
        items.append({"signal_id": g.get("signal_id"), "passed": g.get("passed"), "synthetic": g.get("synthetic"),
                      "age_days": age, "data_sources": g.get("data_sources"), "run_id": g.get("run_id"),
                      "reasons": g.get("reasons")})
    return {"gates_dir": str(cache_root() / "gates"), "gates": items}


# ---------------------------------------------------------------------------
# CLI handlers (registered in agents.cli.HANDLERS)
# ---------------------------------------------------------------------------

def _symbols(args, offline: bool):
    from agents.cli import parse_symbols
    from agents.validate.universe import default_universe

    syms = parse_symbols(args.symbols)
    return syms or default_universe(offline)


def cli_gate(args: argparse.Namespace) -> int:
    from agents.cli import EXIT_ERROR, emit
    from agents.fixtures import is_offline
    from agents.signals import SIGNAL_IDS
    from agents.validate.universe import default_benchmark

    offline = bool(args.offline) or is_offline()
    try:
        syms = _symbols(args, offline)
        bench = (args.benchmark or default_benchmark(offline)).strip().upper()
        from agents.cache import check_symbol

        check_symbol(bench)
    except ValueError as exc:
        emit({"error": "invalid_symbol", "detail": str(exc)})
        return EXIT_ERROR
    for d in (args.start, args.end):
        if d and not _is_date(d):
            emit({"error": "invalid_date", "detail": "use YYYY-MM-DD", "value": d})
            return EXIT_ERROR
    sigs = [s.strip() for s in (args.signals or ",".join(SIGNAL_IDS)).split(",") if s.strip()]
    res = run_gate(sigs, syms, bench, args.start, args.end, offline, args.report_dir)
    emit(res["summary"])
    return int(res["exit"])


def cli_parity(args: argparse.Namespace) -> int:
    from agents.cli import EXIT_ERROR, emit
    from agents.fixtures import is_offline

    offline = bool(args.offline) or is_offline()
    try:
        syms = _symbols(args, offline)
    except ValueError as exc:
        emit({"error": "invalid_symbol", "detail": str(exc)})
        return EXIT_ERROR
    res = run_parity(syms, args.start, args.end, offline)
    emit(res["summary"])
    return int(res["exit"])


def cli_status(args: argparse.Namespace) -> int:
    from agents.cli import EXIT_OK, emit, status_payload

    out = status_payload(AGENT)
    out.update(status())
    emit(out)
    return EXIT_OK


def _is_date(s: str) -> bool:
    try:
        datetime.strptime(s, "%Y-%m-%d")
        return True
    except ValueError:
        return False
