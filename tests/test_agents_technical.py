#!/usr/bin/env python3
"""Agents: Technical (venv suite, offline).

TA-Lib features on the AAA fixture (finite, ranges), the regime_adx rule
table (one handcrafted case per branch), trend_state, envelope validity,
< 60 bars -> unavailable, fixture -> synthetic + warning, and the CLI
(`python -m agents technical run --offline`): atomic files, exit codes 0 / 2,
`technical status`. Run with .venv-agents/bin/python.
"""
import json
import math
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from agents_unittest import PROJECT_DIR, run_tests  # noqa: E402

os.environ["SST_OFFLINE"] = "1"

from agents.data import BarsResult, Unavailable  # noqa: E402
from agents.envelope import envelope_errors  # noqa: E402
from agents.fixtures import FIXTURE_WARNING, load_fixture_bars  # noqa: E402
from agents.technical import agent as tech  # noqa: E402
from agents.technical.talib_features import (  # noqa: E402
    compute_features, compute_series, regime_from, trend_from)

AAA = load_fixture_bars("AAA")


def _cli(args, cache_dir):
    env = dict(os.environ, AGENT_CACHE_DIR=str(cache_dir), SST_OFFLINE="1")
    return subprocess.run([sys.executable, "-m", "agents", "technical"] + args, cwd=PROJECT_DIR,
                          env=env, capture_output=True, text=True, timeout=300)


class TestFeatures(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.window = AAA[AAA.index <= "2022-06-30"].iloc[-280:]
        cls.f = compute_features(cls.window)

    def test_all_core_features_finite(self):
        for k in ("rsi_14", "ema_12", "ema_26", "ema_20", "ema_50", "sma_50", "sma_200", "macd",
                  "macd_signal", "macd_hist", "bb_upper", "bb_middle", "bb_lower", "bb_upper_sample",
                  "bb_lower_sample", "bb_width_pct_sample", "atr_14", "trange", "natr_14", "adx_14",
                  "plus_di_14", "minus_di_14", "stoch_slowk", "stoch_slowd", "stochf_fastk", "willr_14",
                  "obv", "donchian_high_20", "donchian_low_20", "close"):
            v = self.f.get(k)
            self.assertIsInstance(v, float, k)
            self.assertTrue(math.isfinite(v), k)

    def test_ranges(self):
        f = self.f
        self.assertTrue(0 <= f["rsi_14"] <= 100)
        for k in ("stoch_slowk", "stoch_slowd", "stochf_fastk"):
            self.assertTrue(0 <= f[k] <= 100, k)
        self.assertTrue(-100 <= f["willr_14"] <= 0)
        self.assertTrue(0 <= f["adx_14"] <= 100)
        self.assertTrue(f["bb_lower"] < f["bb_middle"] < f["bb_upper"])
        self.assertTrue(f["bb_upper_sample"] > f["bb_upper"])  # sample std > population std
        self.assertTrue(f["donchian_low_20"] <= f["close"] <= f["donchian_high_20"])
        self.assertIn(f["regime_adx"], ("sideways", "trending_bull", "trending_bear", "volatile"))
        self.assertIn(f["trend_state"], ("up", "down", "neutral"))
        self.assertEqual(f["bars"], 280)
        self.assertEqual(f["last_date"], self.window.index[-1].strftime("%Y-%m-%d"))

    def test_sma200_null_when_short(self):
        f = compute_features(AAA.iloc[:120])
        self.assertIsNone(f["sma_200"])
        self.assertIsInstance(f["sma_50"], float)

    def test_series_matches_last_row(self):
        s = compute_series(self.window)
        self.assertEqual(len(s), len(self.window))
        self.assertAlmostEqual(s["adx_14"].iloc[-1], self.f["adx_14"], places=5)
        self.assertEqual(s["regime_adx"].iloc[-1], self.f["regime_adx"])
        self.assertIsNone(s["regime_adx"].iloc[0])  # undefined before ADX/EMA50 exist


class TestRegimeRules(unittest.TestCase):
    def test_volatile_overrides(self):
        self.assertEqual(regime_from(20.01, 40, 110, 100), "volatile")

    def test_volatility_20_is_not_volatile(self):
        self.assertEqual(regime_from(20.0, 10, 110, 100), "sideways")

    def test_trending_bull(self):
        self.assertEqual(regime_from(5, 25.01, 110, 100), "trending_bull")

    def test_trending_bear(self):
        self.assertEqual(regime_from(5, 30, 90, 100), "trending_bear")

    def test_adx_25_is_sideways(self):
        self.assertEqual(regime_from(5, 25.0, 110, 100), "sideways")

    def test_strong_adx_equal_emas_sideways(self):
        self.assertEqual(regime_from(5, 40, 100, 100), "sideways")

    def test_missing_input(self):
        self.assertIsNone(regime_from(float("nan"), 30, 110, 100))
        self.assertIsNone(regime_from(5, None, 110, 100))

    def test_trend_state(self):
        self.assertEqual(trend_from(11, 10, 105, 100), "up")
        self.assertEqual(trend_from(9, 10, 95, 100), "down")
        self.assertEqual(trend_from(11, 10, 95, 100), "neutral")
        self.assertEqual(trend_from(11, 10, 95, float("nan")), "up")
        self.assertEqual(trend_from(9, 10, 95, None), "down")


class TestEnvelope(unittest.TestCase):
    def test_envelope_valid_and_synthetic(self):
        bars = BarsResult(AAA[AAA.index <= "2022-06-30"].iloc[-270:], "fixture", True, FIXTURE_WARNING)
        env = tech.build_envelope("AAA", "2022-06-30", bars)
        self.assertEqual(envelope_errors(env), [])
        self.assertTrue(env["available"])
        self.assertTrue(env["synthetic"])
        self.assertEqual(env["warning"], FIXTURE_WARNING)
        self.assertEqual(env["data_sources"], ["fixture"])
        self.assertEqual(env["ttl_hours"], 36)
        self.assertTrue(0 <= env["score"] <= 100)
        self.assertIn(env["direction"], ("bullish", "bearish", "neutral"))
        self.assertAlmostEqual(env["confidence"], min(1.0, env["features"]["adx_14"] / 50), places=3)
        parts = env["features"]["score_parts"]
        self.assertEqual(env["score"], int(format(sum(parts.values()) / 3, ".0f")))
        for k in ("regime_adx", "regime_bash", "atr_14"):
            self.assertIn(k, env["features"])
        self.assertIn(env["features"]["regime_bash"], ("sideways", "trending_bull", "trending_bear", "volatile"))
        want = {"up": "bullish", "down": "bearish"}.get(env["features"]["trend_state"], "neutral")
        self.assertEqual(env["direction"], want)

    def test_fewer_than_60_bars_unavailable(self):
        bars = BarsResult(AAA.iloc[:59], "fixture", True, FIXTURE_WARNING)
        env = tech.build_envelope("AAA", "2019-03-29", bars)
        self.assertEqual(envelope_errors(env), [])
        self.assertFalse(env["available"])
        self.assertIsNone(env["score"])
        self.assertIn("insufficient bars: 59 < 60", env["reason"])

    def test_no_data_unavailable(self):
        env = tech.build_envelope("ZZZ", "2022-06-30", Unavailable("no fixture for ZZZ"))
        self.assertEqual(envelope_errors(env), [])
        self.assertFalse(env["available"])
        self.assertEqual(env["data_sources"], [])

    def test_run_library_offline(self):
        with tempfile.TemporaryDirectory() as d:
            out = tech.run(["AAA", "CCC"], as_of="2022-06-30", offline=True, root=Path(d))
            self.assertEqual(out["written"], ["AAA", "CCC"])
            env = json.loads((Path(d) / "technical" / "2022-06-30" / "CCC.json").read_text())
            self.assertEqual(envelope_errors(env), [])
            self.assertEqual(env["features"]["last_date"], "2022-06-30")


class TestCli(unittest.TestCase):
    def test_run_offline_writes_atomic_files(self):
        with tempfile.TemporaryDirectory() as d:
            r = _cli(["run", "--symbols", "AAA,BBB", "--offline", "--as-of", "2022-06-30"], d)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            summary = json.loads(r.stdout)
            self.assertEqual(summary["written"], ["AAA", "BBB"])
            self.assertEqual(summary["unavailable"], {})
            day = Path(d) / "technical" / "2022-06-30"
            self.assertEqual(sorted(p.name for p in day.iterdir()), ["AAA.json", "BBB.json"])  # no temp files
            for s in ("AAA", "BBB"):
                env = json.loads((day / ("%s.json" % s)).read_text())
                self.assertEqual(envelope_errors(env), [])
                self.assertTrue(env["synthetic"])
                self.assertTrue(env["warning"])

    def test_unknown_symbol_only_exits_2(self):
        with tempfile.TemporaryDirectory() as d:
            r = _cli(["run", "--symbols", "ZZZ", "--offline", "--as-of", "2022-06-30"], d)
            self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
            summary = json.loads(r.stdout)
            self.assertEqual(summary["written"], [])
            self.assertIn("ZZZ", summary["unavailable"])
            env = json.loads((Path(d) / "technical" / "2022-06-30" / "ZZZ.json").read_text())
            self.assertFalse(env["available"])

    def test_mixed_symbols_exit_0(self):
        with tempfile.TemporaryDirectory() as d:
            r = _cli(["run", "--symbols", "AAA,ZZZ", "--offline", "--as-of", "2022-06-30"], d)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertEqual(json.loads(r.stdout)["written"], ["AAA"])

    def test_bad_symbol_and_missing_symbols_exit_1(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(_cli(["run", "--symbols", "../X", "--offline"], d).returncode, 1)
            self.assertEqual(_cli(["run", "--offline"], d).returncode, 1)

    def test_status_lists_as_of_dirs(self):
        with tempfile.TemporaryDirectory() as d:
            _cli(["run", "--symbols", "AAA,BBB", "--offline", "--as-of", "2022-06-30"], d)
            r = _cli(["status"], d)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            st = json.loads(r.stdout)
            self.assertEqual(st["as_of_dirs"], [{"as_of": "2022-06-30", "symbols": 2}])
            self.assertEqual(st["endpoint_mode"], "PAPER")


if __name__ == "__main__":
    sys.exit(run_tests([TestFeatures, TestRegimeRules, TestEnvelope, TestCli]))
