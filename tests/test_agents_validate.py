#!/usr/bin/env python3
"""Agents: Validation (venv suite, offline, no network).
stats (Sharpe, max DD, PSR, DSR, PBO/CSCV), walk-forward folds (calendar and
bar mode, no train/test overlap, train-only tuning), the gate engine on tiny
handcrafted bars (next-open fill with slippage, intrabar stop, take profit,
signal exit at the next open), legacy parity vs lib/backtest_engine.py on the
fixtures, gate criteria flips, synthetic -> not passed, the gate schema, the
report HTML (balanced tags, escaping), the trial log / DSR trial count, and
the v2 signal series vs bash_compat.v2_from_bars. Run with .venv-agents/bin/python.
"""
import json
import math
import os
import shutil
import sys
import tempfile
import unittest
from html.parser import HTMLParser
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from agents_unittest import PROJECT_DIR, run_tests  # noqa: E402,F401

os.environ["SST_OFFLINE"] = "1"
_CACHE = tempfile.mkdtemp(prefix="sst_validate_test.")
os.environ["AGENT_CACHE_DIR"] = _CACHE

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

from agents.fixtures import load_fixture_bars  # noqa: E402
from agents.signals import SIGNAL_IDS, get_signals  # noqa: E402
from agents.signals.base import RISK_GRID, SignalFrame, full_grid  # noqa: E402
from agents.signals.mean_reversion import mr_signal  # noqa: E402
from agents.signals.trend_follow import tf_signal  # noqa: E402
from agents.signals import v2_confluence as v2mod  # noqa: E402
from agents.validate import engine as E  # noqa: E402
from agents.validate import stats as st  # noqa: E402
from agents.validate import trials as tr  # noqa: E402
from agents.validate.gate import (CRITERIA, decide, evaluate_criteria, gate_errors,  # noqa: E402
                                  thresholds, write_gate)
from agents.validate.report import render_html, write_report  # noqa: E402
from agents.validate.walkforward import bar_folds, calendar_folds, slice_index, walk_forward  # noqa: E402

FIXTURES = {s: load_fixture_bars(s) for s in ("AAA", "BBB", "CCC", "SPY")}
COSTS = {"slippage_per_side": 0.001, "fees_per_side": 0.0}


class TestStats(unittest.TestCase):
    def test_sharpe_constant_is_zero(self):
        self.assertEqual(st.sharpe([0.01] * 50), 0.0)
        self.assertEqual(st.sharpe([]), 0.0)

    def test_sharpe_known_value(self):
        r = [0.01, -0.01, 0.02, 0.0]
        a = np.array(r)
        self.assertAlmostEqual(st.sharpe(r), a.mean() / a.std(ddof=1) * math.sqrt(252), places=12)

    def test_max_drawdown(self):
        self.assertAlmostEqual(st.max_drawdown([1, 2, 1, 1.5, 0.5, 3]), 0.75)
        self.assertEqual(st.max_drawdown([1, 2, 3]), 0.0)

    def test_psr_half_at_zero(self):
        self.assertAlmostEqual(st.psr(0.0, 252, 0.0, 3.0, 0.0), 0.5, places=12)

    def test_dsr_n1_equals_psr(self):
        self.assertEqual(st.expected_max_sr([0.05], 1), 0.0)
        self.assertAlmostEqual(st.dsr(0.08, [0.08], 500, -0.2, 4.0),
                               st.psr(0.08, 500, -0.2, 4.0, 0.0), places=12)

    def test_dsr_falls_with_more_trials(self):
        srs = [0.01, 0.03, 0.05, 0.02, 0.04]
        d5 = st.dsr(0.05, srs, 500, 0, 3, n_trials=5)
        d100 = st.dsr(0.05, srs, 500, 0, 3, n_trials=100)
        self.assertLess(d100, d5)
        self.assertLessEqual(d5, st.psr(0.05, 500, 0, 3, 0))

    def test_sr0_formula(self):
        srs = [0.01, 0.03, 0.05, 0.02, 0.04]
        from scipy.stats import norm
        g = 0.5772156649
        want = math.sqrt(np.var(srs, ddof=1)) * ((1 - g) * norm.ppf(1 - 1 / 10) + g * norm.ppf(1 - 1 / (10 * math.e)))
        self.assertAlmostEqual(st.expected_max_sr(srs, 10), want, places=12)

    def test_pbo_dominant_column_is_zero(self):
        rng = np.random.default_rng(7)
        M = rng.normal(0, 0.01, size=(800, 6))
        M[:, 2] += 0.02  # dominates every block
        self.assertLessEqual(st.pbo_cscv(M, S=16)["pbo"], 0.01)

    def test_pbo_iid_noise_mid(self):
        rng = np.random.default_rng(12345)
        M = rng.normal(0, 0.01, size=(800, 20))
        p = st.pbo_cscv(M, S=16)
        self.assertTrue(0.3 <= p["pbo"] <= 0.7, p["pbo"])
        self.assertEqual(p["n_splits"], 12870)
        self.assertIn("median", p["lambda"])

    def test_pbo_trims_to_multiple_of_s(self):
        rng = np.random.default_rng(1)
        p = st.pbo_cscv(rng.normal(0, 0.01, size=(1000, 4)), S=16)
        self.assertEqual(p["T_used"], 992)
        p8 = st.pbo_cscv(rng.normal(0, 0.01, size=(1003, 4)), S=8)
        self.assertEqual(p8["T_used"], 1000)
        self.assertEqual(p8["n_splits"], 70)


class TestWalkForward(unittest.TestCase):
    def test_calendar_folds(self):
        idx = pd.bdate_range("2015-06-01", "2024-03-28")
        folds = calendar_folds(idx, start="2016-01-01")
        self.assertEqual(folds[0].train_start, pd.Timestamp("2016-01-01"))
        self.assertEqual(folds[0].train_end, pd.Timestamp("2018-01-01"))
        self.assertEqual(folds[0].test_start, pd.Timestamp("2018-01-01"))
        self.assertEqual(folds[0].test_end, pd.Timestamp("2018-07-01"))
        self.assertEqual(folds[1].train_start, pd.Timestamp("2016-07-01"))
        for f in folds:
            tr_i = slice_index(idx, f.train_start, f.train_end)
            te_i = slice_index(idx, f.test_start, f.test_end)
            self.assertEqual(len(tr_i.intersection(te_i)), 0)
            self.assertLess(tr_i[-1], te_i[0])
        for a, b in zip(folds, folds[1:]):  # consecutive, non-overlapping test windows
            self.assertEqual(a.test_end, b.test_start)
        self.assertGreaterEqual(folds[-1].test_end, idx[-1])
        self.assertEqual(len(folds), 13)  # 2018-01 .. 2024-01 test starts

    def test_bar_folds(self):
        idx = FIXTURES["AAA"].index
        folds = bar_folds(idx, 252, 126, 2)
        self.assertEqual(len(folds), 2)
        for f in folds:
            tr_i = slice_index(idx, f.train_start, f.train_end)
            te_i = slice_index(idx, f.test_start, f.test_end)
            self.assertEqual((len(tr_i), len(te_i)), (252, 126))
            self.assertEqual(len(tr_i.intersection(te_i)), 0)
        self.assertEqual(slice_index(idx, folds[-1].test_start, folds[-1].test_end)[-1], idx[-1])

    def test_tuning_picks_max_train_sharpe_first_on_ties(self):
        idx = pd.bdate_range("2020-01-01", periods=40)
        folds = bar_folds(idx, 20, 10, 2)
        scores = {"a": 1.0, "b": 2.0, "c": 2.0}

        def ev(cfg, s, e):
            return {"sharpe": scores[cfg["k"]], "returns": pd.Series(0.0, index=slice_index(idx, s, e)), "trades": 0}
        out = walk_forward(ev, [{"k": "a"}, {"k": "b"}, {"k": "c"}], folds)
        self.assertEqual([o["params"]["k"] for o in out], ["b", "b"])


def _bars(o, h, l, c):
    idx = pd.bdate_range("2024-01-01", periods=len(c))
    return pd.DataFrame({"open": o, "high": h, "low": l, "close": c, "volume": [1e6] * len(c)},
                        index=idx, dtype=float)


def _frame(df, entries=(), exits=(), atr=None):
    e = pd.Series(False, index=df.index)
    x = pd.Series(False, index=df.index)
    for i in entries:
        e.iloc[i] = True
    for i in exits:
        x.iloc[i] = True
    a = pd.Series(np.nan if atr is None else atr, index=df.index, dtype=float)
    return SignalFrame(e, x, a)


def _trades(res):
    return res["portfolio"].trades.values


class TestGateEngine(unittest.TestCase):
    def test_entry_fills_next_open_with_slippage(self):
        df = _bars([100, 100, 101, 102, 103, 104], [101, 102, 103, 104, 105, 106],
                   [99, 99, 100, 101, 102, 103], [100, 101, 102, 103, 104, 105])
        res = E.gate_backtest({"A": df}, {"A": _frame(df, entries=[0])},
                              {"stop_atr_mult": 2, "take_profit_pct": 50}, COSTS, init_cash=10000)
        t = _trades(res)
        self.assertEqual(len(t), 1)
        self.assertEqual(int(t[0]["entry_idx"]), 1)
        self.assertAlmostEqual(float(t[0]["entry_price"]), 100 * 1.001, places=9)
        self.assertEqual(float(t[0]["size"]), float(int(10000 / 100.1)))

    def test_stop_hit_intrabar_exits_at_stop(self):
        df = _bars([100, 100, 101, 99, 96, 96], [101, 101, 102, 100, 97, 97],
                   [99, 99, 100, 90, 95, 95], [100, 100, 101, 98, 96, 96])
        # ATR 2.5 at the signal bar, close 100 -> stop 2 x 2.5 / 100 = 5 %
        res = E.gate_backtest({"A": df}, {"A": _frame(df, entries=[0], atr=2.5)},
                              {"stop_atr_mult": 2, "take_profit_pct": 50}, COSTS, init_cash=10000)
        t = _trades(res)[0]
        stop = 100 * 1.001 * (1 - 0.05)
        self.assertEqual(int(t["exit_idx"]), 3)
        self.assertAlmostEqual(float(t["exit_price"]), stop * (1 - 0.001), places=6)

    def test_stop_clamped(self):
        df = _bars([100] * 3, [101] * 3, [99] * 3, [100] * 3)
        fr = _frame(df, atr=50.0)
        self.assertAlmostEqual(float(E.stop_fraction(fr, df["close"], 2.0).iloc[0]), 0.15)
        fr = _frame(df, atr=0.1)
        self.assertAlmostEqual(float(E.stop_fraction(fr, df["close"], 2.0).iloc[0]), 0.01)
        fr = _frame(df)
        self.assertAlmostEqual(float(E.stop_fraction(fr, df["close"], 2.0).iloc[0]), 0.05)

    def test_take_profit_hit(self):
        df = _bars([100, 100, 101, 103, 104, 104], [101, 101, 102, 110, 105, 105],
                   [99, 99, 100, 102, 103, 103], [100, 100, 101, 104, 104, 104])
        res = E.gate_backtest({"A": df}, {"A": _frame(df, entries=[0], atr=1.0)},
                              {"stop_atr_mult": 2, "take_profit_pct": 8}, COSTS, init_cash=10000)
        t = _trades(res)[0]
        self.assertEqual(int(t["exit_idx"]), 3)
        self.assertAlmostEqual(float(t["exit_price"]), 100 * 1.001 * 1.08 * (1 - 0.001), places=6)

    def test_signal_exit_at_next_open(self):
        df = _bars([100, 100, 101, 102, 103, 104], [101, 101, 102, 103, 104, 105],
                   [99.5, 99.5, 100.5, 101.5, 102.5, 103.5], [100, 100.5, 101.5, 102.5, 103.5, 104])
        res = E.gate_backtest({"A": df}, {"A": _frame(df, entries=[0], exits=[2], atr=1.0)},
                              {"stop_atr_mult": 2, "take_profit_pct": 50}, COSTS, init_cash=10000)
        t = _trades(res)[0]
        self.assertEqual(int(t["exit_idx"]), 3)
        self.assertAlmostEqual(float(t["exit_price"]), 102 * (1 - 0.001), places=9)
        self.assertEqual(res["closed_trades"], 1)

    def test_signal_on_last_bar_is_dropped(self):
        df = _bars([100] * 4, [101] * 4, [99] * 4, [100] * 4)
        res = E.gate_backtest({"A": df}, {"A": _frame(df, entries=[3])},
                              {"stop_atr_mult": 2, "take_profit_pct": 8}, COSTS, init_cash=10000)
        self.assertEqual(res["trades"], 0)

    def test_equal_capital_per_symbol(self):
        df = _bars([100] * 5, [101] * 5, [99] * 5, [100] * 5)
        res = E.gate_backtest({"A": df, "B": df}, {"A": _frame(df), "B": _frame(df)},
                              {"stop_atr_mult": 2, "take_profit_pct": 8}, COSTS, init_cash=10000)
        self.assertAlmostEqual(float(res["equity"].iloc[0]), 10000.0)
        self.assertEqual(len(res["returns"]), 5)


class TestGateEngineSlots(unittest.TestCase):
    """sizing={'mode': 'slots', 'slots': k} (Phase 2 quant top-k signals)."""

    P = {"stop_atr_mult": 2, "take_profit_pct": 50}

    def _rotation(self, k=2, n_syms=5):
        # Real fixture bars; every 5 bars the top k rotate (one name in, one out)
        bars = {s: FIXTURES[s].iloc[:200] for s in ("AAA", "BBB", "CCC", "SPY")}
        names = list(bars)[:n_syms]
        frames = {}
        for j, s in enumerate(names):
            e = pd.Series(False, index=bars[s].index)
            x = pd.Series(False, index=bars[s].index)
            for r, i in enumerate(range(0, 195, 5)):
                top = {names[(r + q) % len(names)] for q in range(k)}
                if s in top:
                    e.iloc[i] = True
                else:
                    x.iloc[i] = True
            frames[s] = SignalFrame(e, x, pd.Series(np.nan, index=bars[s].index))
        return bars, frames

    def test_default_path_unchanged(self):
        bars, frames = self._rotation()
        a = E.gate_backtest(bars, frames, self.P, COSTS, init_cash=10000)
        b = E.gate_backtest(bars, frames, self.P, COSTS, init_cash=10000, sizing=None)
        self.assertTrue(a["returns"].equals(b["returns"]))
        self.assertEqual(a["trades"], b["trades"])
        self.assertNotIn("sizing", a)

    def test_slots_never_more_than_k_and_cash_never_negative(self):
        for k in (1, 2, 3):
            bars, frames = self._rotation(k=k, n_syms=4)
            res = E.gate_backtest(bars, frames, self.P, COSTS, init_cash=10000, sizing={"mode": "slots", "slots": k})
            pf = res["portfolio"]
            held = (pf.assets() > 0).sum(axis=1)
            self.assertLessEqual(int(held.max()), k, k)
            self.assertEqual(int(held.max()), k, "all k slots get used")
            self.assertGreaterEqual(float(pf.cash().min()), -1e-6, k)
            self.assertAlmostEqual(float(res["equity"].iloc[0]), 10000.0, places=6)
            self.assertEqual(res["sizing"], {"mode": "slots", "slots": k, "slot_cash": 10000.0 / k})
            # every entry buys at most one slot (valued at the open, before slippage) of integer shares
            t = pf.trades.values
            cost = t["size"] * t["entry_price"]
            self.assertTrue(((cost <= 10000.0 / k * (1 + COSTS["slippage_per_side"]) + 1e-6)
                             & (t["size"] == np.floor(t["size"]))).all())

    def test_exit_filled_before_entry_on_the_same_bar(self):
        # k = 1: all cash in A; at bar 2 A exits and B enters -> both fill at bar 3's open
        df = _bars([100] * 8, [101] * 8, [99] * 8, [100] * 8)
        fa = _frame(df, entries=[0], exits=[2])
        fb = _frame(df, entries=[2])
        res = E.gate_backtest({"A": df, "B": df}, {"A": fa, "B": fb}, self.P, COSTS, init_cash=10000,
                              sizing={"mode": "slots", "slots": 1})
        t = res["portfolio"].trades.values
        b = t[t["col"] == 1]
        self.assertEqual(len(b), 1)
        self.assertEqual(int(b[0]["entry_idx"]), 3)
        self.assertGreater(float(b[0]["size"]) * 100, 9000.0, "B got a full slot, so A was sold first")
        a = t[t["col"] == 0]
        self.assertEqual(int(a[0]["exit_idx"]), 3)
        self.assertGreaterEqual(float(res["portfolio"].cash().min()), -1e-6)
        self.assertAlmostEqual(res["per_symbol"]["A"]["total_return"], float(a[0]["pnl"]) / 10000.0)

    def test_bad_sizing(self):
        df = _bars([100] * 4, [101] * 4, [99] * 4, [100] * 4)
        with self.assertRaises(ValueError):
            E.gate_backtest({"A": df}, {"A": _frame(df)}, self.P, COSTS, sizing={"mode": "slots", "slots": 0})
        with self.assertRaises(ValueError):
            E.gate_backtest({"A": df}, {"A": _frame(df)}, self.P, COSTS, sizing={"mode": "kelly"})


class TestLegacyParity(unittest.TestCase):
    def test_parity_on_fixtures(self):
        totals = {"mean_reversion": 0, "trend_follow": 0}
        for sym in ("AAA", "BBB", "CCC"):
            df = FIXTURES[sym]
            for name, port in (("mean_reversion", mr_signal(df)), ("trend_follow", tf_signal(df))):
                leg = E.legacy_signals(df, name)
                self.assertTrue((leg.to_numpy() == port.to_numpy()).all(), (sym, name, "signals"))
                L = E.legacy_reference(df, leg)
                V = E.legacy_parity_backtest(df, port)
                self.assertEqual(L["trades"], V["trades"], (sym, name))
                self.assertLessEqual(abs(L["pnl"] - V["pnl"]), max(1.0, 0.01 * abs(L["pnl"])), (sym, name))
                self.assertTrue(E.parity_ok(L, V))
                totals[name] += L["trades"]
        for name, n in totals.items():
            self.assertGreaterEqual(n, 3, name)

    def test_parity_ok_rule(self):
        self.assertFalse(E.parity_ok({"trades": 2, "pnl": 1000}, {"trades": 3, "pnl": 1000}))
        self.assertTrue(E.parity_ok({"trades": 2, "pnl": 1000}, {"trades": 2, "pnl": 1009}))
        self.assertFalse(E.parity_ok({"trades": 2, "pnl": 1000}, {"trades": 2, "pnl": 1011}))
        self.assertTrue(E.parity_ok({"trades": 1, "pnl": 50}, {"trades": 1, "pnl": 50.9}))
        self.assertFalse(E.parity_ok({"trades": 1, "pnl": 50}, {"trades": 1, "pnl": 51.5}))


GOOD = {"oos_sharpe": 1.0, "spy_sharpe": 0.8, "dsr": 0.97, "pbo": 0.1, "oos_max_dd": 0.2,
        "spy_max_dd": 0.3, "oos_trades": 150, "pct_positive_folds": 0.7}
REAL = {"AAA": "alpaca:sip", "SPY": "alpaca:sip"}


class TestGateCriteria(unittest.TestCase):
    def test_all_pass(self):
        c = evaluate_criteria(GOOD, thresholds({}))
        self.assertEqual(set(c), set(CRITERIA))
        ok, reasons = decide(c, False, REAL)
        self.assertTrue(ok, reasons)
        self.assertFalse(c["baseline_improvement"]["applicable"])

    def test_each_criterion_flips(self):
        flips = {"min_oos_sharpe": {"oos_sharpe": 0.4, "spy_sharpe": 0.3},
                 "vs_spy_sharpe": {"spy_sharpe": 1.2},
                 "min_dsr": {"dsr": 0.94}, "max_pbo": {"pbo": 0.31},
                 "max_drawdown_vs_spy": {"oos_max_dd": 0.37},
                 "min_oos_trades": {"oos_trades": 99}, "min_positive_folds": {"pct_positive_folds": 0.59}}
        for name, change in flips.items():
            m = dict(GOOD, **change)
            c = evaluate_criteria(m, thresholds({}))
            failed = [k for k, v in c.items() if v["applicable"] and not v["passed"]]
            self.assertEqual(failed, [name], name)
            ok, reasons = decide(c, False, REAL)
            self.assertFalse(ok)
            self.assertTrue(reasons[0].startswith(name + ":"), reasons)

    def test_missing_metric_fails(self):
        c = evaluate_criteria(dict(GOOD, pbo=None), thresholds({}))
        self.assertFalse(c["max_pbo"]["passed"])

    def test_env_override(self):
        th = thresholds({"GATE_MIN_OOS_TRADES": "10", "GATE_MIN_DSR": "junk"})
        self.assertEqual(th["GATE_MIN_OOS_TRADES"], 10.0)
        self.assertEqual(th["GATE_MIN_DSR"], 0.95)

    def test_synthetic_never_passes(self):
        c = evaluate_criteria(GOOD, thresholds({}))
        ok, reasons = decide(c, True, {"AAA": "fixture", "SPY": "fixture"})
        self.assertFalse(ok)
        self.assertIn("synthetic_data", reasons)
        self.assertIn("non_real_data:AAA", reasons)


class _TagChecker(HTMLParser):
    VOID = {"meta", "br", "hr", "img", "input", "link"}

    def __init__(self):
        super().__init__()
        self.stack, self.errors = [], []

    def handle_starttag(self, tag, attrs):
        if tag not in self.VOID:
            self.stack.append(tag)

    def handle_endtag(self, tag):
        if tag in self.VOID:
            return
        if not self.stack or self.stack[-1] != tag:
            self.errors.append("unexpected </%s> (open: %s)" % (tag, self.stack[-3:]))
        else:
            self.stack.pop()


class TestGateRunAndReport(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from agents.validate.agent import load_universe, run_signal
        from agents.validate.engine import gate_costs

        data = load_universe(["AAA", "BBB", "CCC"], "SPY", None, None, True)
        cls.bars_res = data["bars"]
        cls.unavailable = data["unavailable"]
        cls.trials_before = len(tr.read_trials())
        cls.out = run_signal(get_signals()["tf_only"], cls.bars_res, ["AAA", "BBB", "CCC"], "SPY", True,
                             None, "test-run-1", gate_costs())
        cls.gate = cls.out["gate"]

    def test_gate_schema_and_synthetic(self):
        self.assertEqual(self.unavailable, {})
        self.assertEqual(gate_errors(self.gate), [])
        self.assertFalse(self.gate["passed"])
        self.assertTrue(self.gate["synthetic"])
        self.assertIn("synthetic_data", self.gate["reasons"])
        self.assertEqual(self.gate["metrics"]["grid_size"], 27)
        self.assertEqual(len(self.gate["folds"]), 2)
        path = write_gate(self.gate)
        self.assertTrue(path.is_file())
        self.assertEqual(json.loads(path.read_text())["signal_id"], "tf_only")

    def test_schema_rejects_bad_gates(self):
        bad = dict(self.gate, passed=True)
        self.assertTrue(any("rule" in e for e in gate_errors(bad)))
        bad = dict(self.gate)
        del bad["metrics"]
        self.assertTrue(gate_errors(bad))
        bad = dict(self.gate, generated_at="2024-01-01T00:00:00.123Z")
        self.assertTrue(gate_errors(bad))

    def test_trials_logged_and_n_trials(self):
        recs = tr.read_trials()
        mine = [r for r in recs if r["run_id"] == "test-run-1"]
        self.assertEqual(len(mine), self.gate["metrics"]["n_evaluations"])
        self.assertEqual({r["phase"] for r in mine}, {"train", "test", "full"})
        self.assertEqual(tr.distinct_configs("tf_only"), 27)
        self.assertEqual(self.gate["metrics"]["n_trials"], 27)
        extra = [{"run_id": "x", "signal_id": "tf_only", "config_hash": "%064x" % i, "params": {}, "fold": None,
                  "phase": "full", "sharpe": 0.0, "trades": 0, "data_source": "fixture"} for i in range(30)]
        n0 = len(tr.read_trials())
        tr.append_trials(extra)
        self.assertEqual(len(tr.read_trials()), n0 + 30)
        self.assertEqual(tr.n_trials("tf_only", 27), 57)
        self.assertEqual(tr.n_trials("mr_only", 81), 81)

    def test_report_html_balanced_and_escaped(self):
        meta = {"run_id": "r<1>", "universe": ["<x>", "AAA"], "benchmark": "SPY", "synthetic": True}
        g = json.loads(json.dumps(self.gate))
        g["signal_id"] = "<x>"
        g["folds"][0]["params"] = {"k": "<script>alert(1)</script>"}
        page = render_html(meta, [g], {"<x>": self.out["curves"]},
                           {"ok": True, "results": [{"symbol": "<x>", "strategy": "s", "ok": True}]})
        chk = _TagChecker()
        chk.feed(page)
        chk.close()
        self.assertEqual(chk.errors, [])
        self.assertEqual(chk.stack, [])
        self.assertNotIn("<x>", page)
        self.assertIn("&lt;x&gt;", page)
        self.assertNotIn("<script", page)
        self.assertIn("SYNTHETIC DATA", page)
        self.assertIn("<polyline", page)
        self.assertNotIn("http://", page.replace('xmlns="http://www.w3.org/2000/svg"', ""))
        self.assertNotIn("https://", page)
        d = tempfile.mkdtemp(dir=_CACHE)
        paths = write_report(Path(d), meta, [g], {"<x>": self.out["curves"]})
        self.assertTrue(Path(paths["report_html"]).is_file())
        self.assertTrue(Path(paths["report_json"]).is_file())


class TestSignals(unittest.TestCase):
    def test_grid_sizes(self):
        specs = get_signals()
        self.assertEqual(tuple(specs), SIGNAL_IDS)
        sizes = {k: len(full_grid(v)) for k, v in specs.items()}
        self.assertEqual(sizes, {"v2_confluence": 9, "v2_confluence_adx": 9, "mr_only": 81, "tf_only": 27})
        self.assertEqual(len(RISK_GRID), 9)
        self.assertIn({"stop_atr_mult": 2.0, "take_profit_pct": 8}, RISK_GRID)

    def test_v2_series_matches_v2_from_bars(self):
        from agents.technical import bash_compat as bc

        df = FIXTURES["BBB"]
        fr = v2mod.v2_series("v2_confluence", df, "BBB")
        self.assertTrue((fr["recommendation"].iloc[:59] == "").all())
        for i in (59, 400, 999):
            want = bc.v2_from_bars(df.iloc[i - 59:i + 1], ml_mode="unavailable", sentiment="na", symbol="BBB")
            self.assertEqual(fr["recommendation"].iloc[i], want["recommendation"], i)
            self.assertEqual(float(fr["confluence_score"].iloc[i]), float(want["confluence_score"]), i)
            self.assertEqual(fr["regime"].iloc[i], want["v2_inputs"]["regime"], i)
            self.assertFalse(want["metadata"]["ml_available"])
        frame = get_signals()["v2_confluence"].build(df, {}, "BBB")
        self.assertTrue(frame.entries.equals(fr["recommendation"].isin(["BUY", "STRONG_BUY"])))
        self.assertTrue(frame.exits.equals(fr["recommendation"].isin(["SELL", "STRONG_SELL"])))

    def test_v2_adx_uses_regime_adx(self):
        from agents.technical.talib_features import compute_series

        df = FIXTURES["BBB"]
        fr = v2mod.v2_series("v2_confluence_adx", df, "BBB")
        ra = compute_series(df)["regime_adx"]
        i = 600
        self.assertEqual(fr["regime"].iloc[i], ra.iloc[i])

    def test_v2_cache_reused_and_keyed_by_data(self):
        df = FIXTURES["AAA"].iloc[:120]
        v2mod.v2_series("v2_confluence", df, "AAA")
        path = v2mod.cache_file("v2_confluence", "AAA", df)
        self.assertTrue(path.is_file())
        self.assertTrue(v2mod.cache_file("v2_confluence_adx", "AAA", df).is_file())
        orig = v2mod.compute_v2_series
        try:
            v2mod.compute_v2_series = lambda *a, **k: (_ for _ in ()).throw(AssertionError("recomputed"))
            v2mod.v2_series("v2_confluence", df, "AAA")  # served from the cache
        finally:
            v2mod.compute_v2_series = orig
        df2 = df.copy()
        df2.iloc[-1, df2.columns.get_loc("close")] += 1.0
        self.assertNotEqual(v2mod.cache_file("v2_confluence", "AAA", df2), path)

    def test_mr_grid_param_changes_signal(self):
        df = FIXTURES["CCC"]
        a = mr_signal(df, 25, 2.5)
        b = mr_signal(df, 35, 1.5)
        self.assertLessEqual(int((a == 1).sum()), int((b == 1).sum()))


def tearDownModule():
    shutil.rmtree(_CACHE, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(run_tests(sys.modules[__name__]))
