#!/usr/bin/env python3
"""Agents: Quant (run with .venv-agents/bin/python; no network).

Quant data pipeline (Phase 2, FEAT-001): universe file, raw Alpaca bar store
(offline fixtures and a 127.0.0.1 Alpaca stub), the 14 legacy features, the
Qlib bin store (round trip through qlib.data.D.features) and the CLI.
Quant model (FEAT-002): folds + embargo, metrics (IC, Newey-West t, top-k),
handlers (label, feature count, no look-ahead), tiny training on a planted
signal (QUANT_TEST_FAST=1), predictions -> envelopes, train/predict CLI.
Every test runs with a temp AGENT_CACHE_DIR; socket connects to anything but
loopback raise.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from agents_unittest import PROJECT_DIR, run_tests  # noqa: E402

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

from agents.config import SafetyError  # noqa: E402
from agents.data.alpaca import COLUMNS, AlpacaBarsClient  # noqa: E402
from agents.data.bars import BarsResult, Unavailable  # noqa: E402
from agents.fixtures import load_fixture_bars  # noqa: E402
from agents.quant import raw, store, universe  # noqa: E402
from agents.quant.legacy_features import (SST_COLUMNS, SST_FEATURES, legacy_feature_frame,  # noqa: E402
                                          legacy_features_at)
from agents.validate.universe import OFFLINE_UNIVERSE, PHASE1_UNIVERSE  # noqa: E402

FIX = Path(PROJECT_DIR) / "tests" / "fixtures" / "agents"
PAGE1 = json.loads((FIX / "alpaca" / "bars_page1.json").read_text())
KEY, SECRET = "PKFAKEQUANT00000", "fakeQuantSecret00000"
QUANT_FIXTURES = ("QAA", "QBB", "QCC", "QDD", "QEE", "QFF", "QGG", "QHH", "QII", "QJJ", "QKK", "QLL")

# --- socket guard: only loopback connections are allowed ---------------------
_REAL_CONNECT = socket.socket.connect


def _guarded_connect(self, address):
    host = address[0] if isinstance(address, tuple) else address
    if host not in ("127.0.0.1", "::1", "localhost"):
        raise OSError("network disabled in tests (connect to %r)" % (host,))
    return _REAL_CONNECT(self, address)


socket.socket.connect = _guarded_connect


class TempCacheMixin:
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sst_agents_quant.")
        self._env = mock.patch.dict(os.environ, {"AGENT_CACHE_DIR": self.tmp, "SST_OFFLINE": "1"}, clear=False)
        self._env.start()
        for k in ("SST_ALLOW_SYNTHETIC", "AGENT_DATA_FALLBACK"):
            os.environ.pop(k, None)

    def tearDown(self):
        self._env.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)


# ---------------------------------------------------------------------------
class UniverseTests(unittest.TestCase):
    def test_real_universe_file(self):
        u = universe.load_universe()
        rank, bench = u["rank"], u["benchmark"]
        self.assertTrue(universe.MIN_SIZE <= len(rank) <= universe.MAX_SIZE, len(rank))
        self.assertEqual(len(rank), len(set(rank)))
        self.assertFalse([s for s in rank + bench if "." in s])
        self.assertFalse(set(PHASE1_UNIVERSE) - set(rank))
        self.assertEqual(bench, ["SPY", "QQQ", "IWM"])
        self.assertFalse(set(bench) & set(rank))
        text = universe.UNIVERSE_FILE.read_text()
        self.assertIn("SURVIVORSHIP BIAS", text)
        self.assertEqual(universe.all_symbols(False), rank + bench)

    def test_offline_universe(self):
        self.assertEqual(universe.rank_universe(True), list(QUANT_FIXTURES) + ["AAA", "BBB", "CCC"])
        self.assertEqual(universe.benchmarks(True), ["SPY"])
        self.assertEqual(OFFLINE_UNIVERSE, ("AAA", "BBB", "CCC"))  # validate default unchanged
        for s in universe.all_symbols(True):
            self.assertIsNotNone(load_fixture_bars(s), s)

    def test_invalid_files_raise(self):
        tmp = tempfile.mkdtemp(prefix="sst_quant_univ.")
        try:
            cases = {
                "dotted": "# rank\nAAPL\nBRK.B\n# benchmark\nSPY\n",
                "dupe": "# rank\nAAPL\nMSFT\nAAPL\n# benchmark\nSPY\n",
                "nosection": "AAPL\n# rank\nMSFT\n# benchmark\nSPY\n",
                "bad": "# rank\naapl\n# benchmark\nSPY\n",
                "nobench": "# rank\nAAPL\n",
            }
            for name, body in cases.items():
                p = Path(tmp) / ("%s.txt" % name)
                p.write_text(body)
                with self.assertRaises(ValueError, msg=name):
                    universe.load_universe(p)
            ok = Path(tmp) / "ok.txt"
            ok.write_text("# comment\n# rank\nAAPL  # inline\n\nMSFT\n# benchmark\nSPY\n")
            self.assertEqual(universe.load_universe(ok), {"rank": ["AAPL", "MSFT"], "benchmark": ["SPY"]})
            with self.assertRaises(ValueError):
                universe.load_universe(ok, check_size=True)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


# ---------------------------------------------------------------------------
class RawOfflineTests(TempCacheMixin, unittest.TestCase):
    def test_offline_ingest_writes_synthetic_raw_files(self):
        syms = universe.all_symbols(True)
        res = raw.ingest(syms, offline=True)
        self.assertEqual((res["requested"], res["fetched"], res["skipped"]), (16, 16, 0))
        self.assertEqual(res["data_sources"], {"fixture": 16})
        self.assertIs(res["synthetic"], True)
        self.assertEqual(res["requests_made"], 0)
        for s in syms:
            meta = json.loads((raw.raw_dir() / ("%s.meta.json" % s)).read_text())
            self.assertEqual((meta["data_source"], meta["synthetic"]), ("fixture", True))
            self.assertIn("SYNTHETIC", meta["warning"])
            self.assertEqual(meta["rows"], 1000)
            self.assertEqual(len(meta["bars_sha12"]), 12)
            df = pd.read_csv(raw.raw_dir() / ("%s.csv" % s))
            self.assertEqual(list(df.columns), ["date"] + raw.RAW_COLUMNS)
        df = load_fixture_bars("QAA")
        got = raw.load_raw(["QAA"])["QAA"]
        self.assertIsInstance(got, BarsResult)
        self.assertTrue(got.synthetic)
        np.testing.assert_allclose(got.df["close"].to_numpy(), df["close"].to_numpy())
        np.testing.assert_allclose(got.df["vwap"].to_numpy(), ((df.high + df.low + df.close) / 3).to_numpy())
        st = raw.raw_status()
        self.assertEqual((st["symbols"], st["synthetic"]), (16, True))

    def test_resume_and_refresh(self):
        syms = ["QAA", "QBB", "SPY"]
        raw.ingest(syms, offline=True)
        again = raw.ingest(syms, offline=True)
        self.assertEqual((again["fetched"], again["skipped"]), (0, 3))
        self.assertEqual(again["data_sources"], {"fixture": 3})
        other_end = raw.ingest(syms, end="2022-06-30", offline=True)
        self.assertEqual((other_end["fetched"], other_end["skipped"]), (3, 0))
        ref = raw.ingest(syms, end="2022-06-30", refresh=True, offline=True)
        self.assertEqual((ref["fetched"], ref["skipped"]), (3, 0))
        self.assertEqual(raw.read_meta("QAA")["last_bar"], "2022-06-30")

    def test_missing_symbol(self):
        res = raw.ingest(["QAA", "ZZZ"], offline=True)
        self.assertEqual(res["fetched"], 1)
        self.assertIn("ZZZ", res["unavailable"])
        got = raw.load_raw(["ZZZ"])["ZZZ"]
        self.assertIsInstance(got, Unavailable)
        self.assertEqual(got.reason, "not_ingested")


# ---------------------------------------------------------------------------
class StubHandler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj=None, headers=None):
        body = json.dumps(obj if obj is not None else {"message": "error"}).encode()
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        self.server.log.append({"method": "GET", "path": u.path, "query": q})
        if u.path != "/v2/stocks/bars":
            return self._send(404)
        syms = q.get("symbols", [""])[0].split(",")
        if self.server.count_429 > 0:
            self.server.count_429 -= 1
            return self._send(429, {"message": "too many requests"}, {"Retry-After": "0"})
        if self.server.fail_symbol in syms:
            return self._send(500, None, {"Retry-After": "0"})
        bars = {}
        for s in syms:
            df = load_fixture_bars(s)
            if df is None:
                continue
            df = df[(df.index >= pd.Timestamp(q["start"][0]))].iloc[-120:]
            bars[s] = [{"t": "%sT04:00:00Z" % d.strftime("%Y-%m-%d"), "o": r.open, "h": r.high, "l": r.low,
                        "c": r.close, "v": int(r.volume), "vw": round(r.close * 1.001, 4)}
                       for d, r in df.iterrows()]
        return self._send(200, {"bars": bars, "next_page_token": None})

    def _refuse(self):
        self.server.log.append({"method": self.command, "path": self.path})
        self._send(405)

    do_POST = do_DELETE = do_PUT = do_PATCH = _refuse


class RawRealModeTests(TempCacheMixin, unittest.TestCase):
    START, END = "2022-01-03", "2022-11-01"

    def setUp(self):
        super().setUp()
        os.environ.pop("SST_OFFLINE", None)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), StubHandler)
        self.server.log, self.server.count_429, self.server.fail_symbol = [], 0, None
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.write_config("https://paper-api.alpaca.markets")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        super().tearDown()

    def write_config(self, base_url):
        path = os.path.join(self.tmp, "config.test.sh")
        with open(path, "w") as fh:
            fh.write('export ALPACA_API_KEY="%s"\nexport ALPACA_SECRET_KEY="%s"\n' % (KEY, SECRET))
            fh.write('export ALPACA_BASE_URL="%s"\nexport ALPACA_DATA_URL="%s"\n' % (base_url, self.url))
        os.environ["SST_CONFIG_FILE"] = path

    def test_real_ingest_get_only_with_vwap(self):
        res = raw.ingest(["QAA", "QBB", "SPY"], start=self.START, end=self.END)
        self.assertEqual((res["fetched"], res["synthetic"]), (3, False))
        self.assertEqual(res["data_sources"], {"alpaca:sip": 3})
        self.assertEqual(res["adjustment"], "all")
        self.assertGreaterEqual(res["requests_made"], 1)
        self.assertEqual({r["method"] for r in self.server.log}, {"GET"})
        self.assertEqual(self.server.log[0]["query"]["adjustment"], ["all"])
        got = raw.load_raw(["QAA"])["QAA"]
        self.assertEqual((got.data_source, got.synthetic, got.warning), ("alpaca:sip", False, None))
        self.assertIn("vwap", got.df.columns)
        np.testing.assert_allclose(got.df["vwap"].to_numpy(), np.round(got.df["close"].to_numpy() * 1.001, 4))
        meta = raw.read_meta("QAA")
        self.assertEqual((meta["feed"], meta["end"], meta["start"]), ("sip", self.END, self.START))
        # no Alpaca disk cache in the raw-store path (use_cache=False)
        self.assertFalse((Path(self.tmp) / "data" / "alpaca").exists())
        # resume: same end -> no request
        n = len(self.server.log)
        again = raw.ingest(["QAA", "QBB", "SPY"], start=self.START, end=self.END)
        self.assertEqual((again["fetched"], again["skipped"], again["requests_made"]), (0, 3, 0))
        self.assertEqual(len(self.server.log), n)

    def test_429_then_200_is_retried(self):
        self.server.count_429 = 1
        res = raw.ingest(["QAA"], start=self.START, end=self.END)
        self.assertEqual(res["fetched"], 1)
        self.assertEqual(len(self.server.log), 2)  # 429 (Retry-After 0), then 200
        self.assertEqual(res["requests_made"], 2)

    def test_failed_batch_keeps_earlier_files(self):
        raw.ingest(["QCC"], start=self.START, end=self.END)
        before = (raw.raw_dir() / "QCC.csv").read_bytes()
        self.server.fail_symbol = "QCC"
        res = raw.ingest(["QAA", "QBB", "QCC", "QDD"], start=self.START, end=self.END, refresh=True, batch=2)
        self.assertEqual(sorted(res["fetched_symbols"]), ["QAA", "QBB"])
        self.assertEqual(sorted(res["unavailable"]), ["QCC", "QDD"])
        self.assertEqual(res["unavailable"]["QCC"], "http_500")
        self.assertTrue((raw.raw_dir() / "QAA.csv").is_file())
        self.assertEqual((raw.raw_dir() / "QCC.csv").read_bytes(), before)  # previous file kept
        self.assertFalse((raw.raw_dir() / "QDD.csv").exists())

    def test_non_paper_base_url_raises_before_any_request(self):
        self.write_config("https://api.alpaca.markets")
        with self.assertRaises(SafetyError):
            raw.ingest(["QAA"], start=self.START, end=self.END)
        self.assertEqual(self.server.log, [])
        self.assertFalse(raw.raw_dir().exists())

    def test_rows_to_frame_default_has_no_vwap(self):
        rows = PAGE1["bars"]["AAA"]
        df = AlpacaBarsClient.rows_to_frame(rows)
        self.assertEqual(list(df.columns), COLUMNS)
        dv = AlpacaBarsClient.rows_to_frame(rows, include_vwap=True)
        self.assertEqual(list(dv.columns), COLUMNS + ["vwap"])
        self.assertEqual(float(dv["vwap"].iloc[0]), float(rows[0]["vw"]))
        no_vw = [{k: v for k, v in r.items() if k != "vw"} for r in rows[:3]]
        dt = AlpacaBarsClient.rows_to_frame(no_vw, include_vwap=True)
        np.testing.assert_allclose(dt["vwap"].to_numpy(), ((dt.high + dt.low + dt.close) / 3).to_numpy())
        empty = AlpacaBarsClient.rows_to_frame([], include_vwap=True)
        self.assertEqual(list(empty.columns), COLUMNS + ["vwap"])

    def test_vwap_cache_file_name(self):
        from agents.config import Config

        cfg = Config({"ALPACA_BASE_URL": "https://paper-api.alpaca.markets", "ALPACA_DATA_URL": self.url})
        a = AlpacaBarsClient(cfg)._cache_files("AAA")[0]
        b = AlpacaBarsClient(cfg, include_vwap=True)._cache_files("AAA")[0]
        self.assertTrue(a.endswith("AAA_1Day_all.csv"))
        self.assertTrue(b.endswith("AAA_1Day_all_vw.csv"))


# ---------------------------------------------------------------------------
class LegacyFeatureTests(unittest.TestCase):
    def setUp(self):
        self.df = load_fixture_bars("QBB")

    def test_last_row_equals_extract_features(self):
        frame = legacy_feature_frame(self.df)
        self.assertEqual(list(frame.columns), list(SST_COLUMNS))
        self.assertEqual(len(SST_FEATURES), 14)
        ref = legacy_features_at(self.df)
        for name in SST_FEATURES:
            np.testing.assert_allclose(frame["sst_" + name].iloc[-1], float(ref[name]), rtol=1e-6, err_msg=name)

    def test_prefix_rows_equal_extract_features(self):
        frame = legacy_feature_frame(self.df)
        for t in (49, 60, 61, 250, 500, 998):
            ref = legacy_features_at(self.df.iloc[:t + 1])
            for name in SST_FEATURES:
                np.testing.assert_allclose(frame["sst_" + name].iloc[t], float(ref[name]), rtol=1e-6,
                                           err_msg="%s t=%d" % (name, t))

    def test_no_look_ahead(self):
        t = 400
        base = legacy_feature_frame(self.df)
        changed = self.df.copy()
        changed.iloc[t + 1:, :] = changed.iloc[t + 1:, :] * 1.7
        changed.iloc[t + 1:, changed.columns.get_loc("volume")] = 1.0
        after = legacy_feature_frame(changed)
        pd.testing.assert_frame_equal(base.iloc[:t + 1], after.iloc[:t + 1])
        self.assertFalse(base.iloc[t + 1:].equals(after.iloc[t + 1:]))

    def test_undefined_warmup_rows_are_nan(self):
        frame = legacy_feature_frame(self.df)
        self.assertTrue(frame["sst_rsi_14"].iloc[:15].isna().all())
        self.assertFalse(np.isnan(frame["sst_rsi_14"].iloc[15]))
        self.assertTrue(frame["sst_ema_50"].iloc[:49].isna().all())
        self.assertTrue(frame["sst_atr"].iloc[:14].isna().all())
        self.assertFalse(frame.iloc[49:].isna().any().any())


# ---------------------------------------------------------------------------
class StoreTests(TempCacheMixin, unittest.TestCase):
    """Store layout without qlib (qlib round trip: QlibRoundTripTests)."""

    def bars(self):
        raw.ingest(universe.all_symbols(True), offline=True)
        return raw.load_raw(universe.all_symbols(True))

    def test_layout_calendar_instruments(self):
        meta = store.build_store(self.bars(), universe.rank_universe(True), universe.benchmarks(True))
        root = store.store_dir()
        cal = (root / "calendars" / "day.txt").read_text().splitlines()
        self.assertEqual(cal, [d.strftime("%Y-%m-%d") for d in load_fixture_bars("AAA").index])
        all_lines = (root / "instruments" / "all.txt").read_text().splitlines()
        rank_lines = (root / "instruments" / "sst_us.txt").read_text().splitlines()
        self.assertEqual(len(all_lines), 16)
        self.assertEqual(len(rank_lines), 15)
        self.assertIn("QAA\t2019-01-02\t2022-11-01", rank_lines)
        self.assertNotIn("SPY", [l.split("\t")[0] for l in rank_lines])
        self.assertIn("SPY\t2019-01-02\t2022-11-01", all_lines)
        files = sorted(p.name for p in (root / "features" / "qaa").iterdir())
        self.assertEqual(files, sorted("%s.day.bin" % f for f in store.FIELDS))
        self.assertEqual(len(store.FIELDS), 21)
        arr = np.fromfile(root / "features" / "qaa" / "close.day.bin", dtype="<f")
        self.assertEqual((arr[0], len(arr)), (0.0, 1001))
        fac = np.fromfile(root / "features" / "qaa" / "factor.day.bin", dtype="<f")
        self.assertTrue((fac[1:] == 1.0).all())
        self.assertEqual((meta["sessions"], meta["rank_instruments"], meta["benchmarks"]), (1000, 15, ["SPY"]))
        self.assertIs(meta["synthetic"], True)
        self.assertEqual(set(meta["data_sources"].values()), {"fixture"})
        self.assertEqual(store.read_store_meta()["bars_sha12"], meta["bars_sha12"])

    def test_late_start_and_missing_sessions(self):
        bars = self.bars()
        qbb = bars["QBB"]
        df = qbb.df.iloc[100:].drop(qbb.df.index[[200, 201, 202]])
        bars["QBB"] = BarsResult(df, qbb.data_source, qbb.synthetic, qbb.warning)
        meta = store.build_store(bars, universe.rank_universe(True), universe.benchmarks(True))
        self.assertEqual(meta["missing_sessions"]["QBB"], 3)
        arr = np.fromfile(store.store_dir() / "features" / "qbb" / "close.day.bin", dtype="<f")
        self.assertEqual(arr[0], 100.0)
        self.assertEqual(len(arr) - 1, 900)
        self.assertTrue(np.isnan(arr[1 + 100]) and np.isnan(arr[1 + 102]))
        self.assertAlmostEqual(float(arr[1]), float(df["close"].iloc[0]), places=3)

    def test_swap_keeps_prev_and_error_leaves_store_untouched(self):
        bars = self.bars()
        rank, bench = universe.rank_universe(True), universe.benchmarks(True)
        store.build_store(bars, rank, bench)
        first = store.read_store_meta()["built_at"]
        store.build_store(bars, rank, bench)
        self.assertTrue((store.store_dir().parent / "qlib_data.prev" / "store_meta.json").is_file())
        before = (store.store_dir() / "store_meta.json").read_bytes()
        with mock.patch("agents.quant.store.legacy_feature_frame", side_effect=RuntimeError("boom")):
            with self.assertRaises(RuntimeError):
                store.build_store(bars, rank, bench)
        self.assertEqual((store.store_dir() / "store_meta.json").read_bytes(), before)
        self.assertEqual(sorted(p.name for p in store.store_dir().parent.iterdir() if p.name.startswith("qlib_data")),
                         ["qlib_data", "qlib_data.prev"])
        self.assertTrue(first)


# ---------------------------------------------------------------------------
class QlibRoundTripTests(unittest.TestCase):
    """One TestCase so `import qlib` (~13 s) happens once."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="sst_agents_quant_qlib.")
        cls._env = mock.patch.dict(os.environ, {"AGENT_CACHE_DIR": cls.tmp, "SST_OFFLINE": "1",
                                                "MLFLOW_ALLOW_FILE_STORE": "true"}, clear=False)
        cls._env.start()
        syms = universe.all_symbols(True)
        raw.ingest(syms, offline=True)
        cls.bars = raw.load_raw(syms)
        store.build_store(cls.bars, universe.rank_universe(True), universe.benchmarks(True))
        from agents.quant.qlib_env import init_qlib

        # same settings as qlib.init(provider_uri=store, region=REG_US, kernels=1,
        # expression_cache=None, dataset_cache=None); MLflow file store in the temp dir
        init_qlib(store.store_dir(), mlruns=Path(cls.tmp) / "mlruns", force=True)

    @classmethod
    def tearDownClass(cls):
        cls._env.stop()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_features_round_trip_float32(self):
        from qlib.data import D

        got = D.features(["QAA"], ["$close", "$vwap", "$sst_rsi_14", "$factor"],
                         start_time="2019-01-02", end_time="2022-11-01", freq="day")
        got = got.xs("QAA", level="instrument")
        src = self.bars["QAA"].df
        self.assertEqual(len(got), len(src))
        self.assertEqual(list(pd.DatetimeIndex(got.index)), list(src.index))
        np.testing.assert_array_equal(got["$close"].to_numpy(dtype=np.float32), src["close"].to_numpy(dtype=np.float32))
        np.testing.assert_array_equal(got["$vwap"].to_numpy(dtype=np.float32), src["vwap"].to_numpy(dtype=np.float32))
        rsi = legacy_feature_frame(src)["sst_rsi_14"].to_numpy(dtype=np.float32)
        np.testing.assert_array_equal(got["$sst_rsi_14"].to_numpy(dtype=np.float32), rsi)
        self.assertTrue((got["$factor"] == 1.0).all())

    def test_instruments_market(self):
        from qlib.data import D

        names = D.list_instruments(D.instruments("sst_us"), as_list=True)
        self.assertEqual(sorted(names), sorted(universe.rank_universe(True)))
        cal = D.calendar(freq="day")
        self.assertEqual(len(cal), 1000)


# ---------------------------------------------------------------------------
class QuantCliTests(TempCacheMixin, unittest.TestCase):
    def run_cli(self, *args):
        cfg = os.path.join(self.tmp, "config.cli.sh")
        with open(cfg, "w") as fh:
            fh.write('export ALPACA_API_KEY="%s"\nexport ALPACA_SECRET_KEY="%s"\n' % (KEY, SECRET))
            fh.write('export ALPACA_BASE_URL="https://paper-api.alpaca.markets"\n')
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.tmp, "AGENT_CACHE_DIR": self.tmp,
               "SST_OFFLINE": "1", "SST_CONFIG_FILE": cfg}
        p = subprocess.run([sys.executable, "-m", "agents", *args], cwd=PROJECT_DIR, env=env,
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=300)
        self.assertNotIn(KEY, p.stdout + p.stderr)
        self.assertNotIn(SECRET, p.stdout + p.stderr)
        return p

    def test_ingest_status_run(self):
        p = self.run_cli("quant", "ingest", "--offline")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        out = json.loads(p.stdout)
        self.assertEqual(sorted(out), ["raw", "store"])
        self.assertEqual(out["raw"]["fetched"], 16)
        for k in ("dir", "sessions", "calendar_start", "calendar_end", "instruments", "rank_instruments",
                  "data_sources", "synthetic", "missing_sessions_over_5"):
            self.assertIn(k, out["store"])
        self.assertEqual((out["store"]["rank_instruments"], out["store"]["synthetic"]), (15, True))
        root = Path(self.tmp) / "quant" / "qlib_data"
        self.assertTrue((root / "calendars" / "day.txt").is_file())
        self.assertTrue((root / "instruments" / "all.txt").is_file())
        self.assertTrue((root / "instruments" / "sst_us.txt").is_file())
        self.assertTrue(list((root / "features" / "qaa").glob("*.day.bin")))

        p = self.run_cli("quant", "status")
        self.assertEqual(p.returncode, 0, p.stdout)
        st = json.loads(p.stdout)
        self.assertEqual((st["agent"], st["raw"]["symbols"], st["store"]["built"]), ("quant", 16, True))
        self.assertIn("has_alpaca_api_key", st)
        self.assertIsNone(st["models"])

        p = self.run_cli("quant", "run")
        self.assertEqual(p.returncode, 1)
        self.assertEqual(json.loads(p.stdout), {"error": "not_implemented", "agent": "quant", "command": "run"})

    def test_ingest_without_rank_data_exits_2_and_keeps_store(self):
        p = self.run_cli("quant", "ingest", "--offline", "--symbols", "ZZZ,SPY")
        self.assertEqual(p.returncode, 2, p.stdout)
        out = json.loads(p.stdout)
        self.assertEqual(out["error"], "market_data_unavailable")
        self.assertFalse((Path(self.tmp) / "quant" / "qlib_data").exists())


# ---------------------------------------------------------------------------
# FEAT-002: folds, metrics, handlers, training, predictions
# ---------------------------------------------------------------------------
from agents.envelope import validate_envelope  # noqa: E402
from agents.quant import folds as qfolds  # noqa: E402
from agents.quant import metrics as qmetrics  # noqa: E402
from agents.quant.handler import LABEL_EXPR  # noqa: E402


class FoldTests(unittest.TestCase):
    CAL = pd.bdate_range("2016-01-04", "2026-10-30")

    def idx(self, ts):
        return int(self.CAL.get_loc(ts))

    def check_embargo(self, segs, embargo=7, warmup=60):
        for s in segs:
            self.assertEqual(s.train[0], self.CAL[warmup])
            self.assertLess(self.idx(s.train[1]) + embargo, self.idx(s.valid[0]), s.name)
            self.assertLess(self.idx(s.valid[1]) + embargo, self.idx(s.test[0]), s.name)
            self.assertLessEqual(s.valid[0], s.valid[1])
            self.assertLessEqual(s.test[0], s.test[1])

    def test_yearly_folds(self):
        segs = qfolds.yearly_folds(self.CAL, first_test_year=2018)
        self.assertEqual([s.name for s in segs], [str(y) for y in range(2018, 2027)])
        self.check_embargo(segs)
        first = segs[0]
        self.assertEqual(first.test[0], pd.Timestamp("2018-01-01"))
        self.assertEqual(first.valid[0], pd.Timestamp("2017-01-02"))
        for a, b in zip(segs, segs[1:]):  # test years do not overlap
            self.assertLess(a.test[1], b.test[0])
        last = segs[-1]
        self.assertEqual(last.test[1], self.CAL[-1])  # partial last year
        self.assertLess(len(self.CAL[(self.CAL >= last.test[0]) & (self.CAL <= last.test[1])]), 260)
        self.assertEqual(sorted(first.segments()), ["test", "train", "valid"])

    def test_year_without_sessions_skipped(self):
        cal = self.CAL[self.CAL.year != 2020]
        segs = qfolds.yearly_folds(cal, first_test_year=2018)
        self.assertNotIn("2020", [s.name for s in segs])
        self.assertIn("2021", [s.name for s in segs])

    def test_live_and_offline_folds(self):
        live = qfolds.live_segment(self.CAL)
        self.assertEqual(live.valid[1], self.CAL[-1])
        self.assertEqual(self.idx(live.valid[0]), len(self.CAL) - 252)
        self.assertLess(self.idx(live.train[1]) + 7, self.idx(live.valid[0]))
        cal = pd.bdate_range("2019-01-02", periods=1000)
        off = qfolds.bar_folds_offline(cal)
        self.assertEqual([s.name for s in off], ["bar1", "bar2"])
        self.assertEqual(off[-1].test[1], cal[-1])
        for s in off:
            n_test = len(cal[(cal >= s.test[0]) & (cal <= s.test[1])])
            self.assertEqual(n_test, 126)
            self.assertLess(int(cal.get_loc(s.valid[1])) + 7, int(cal.get_loc(s.test[0])))
            self.assertLess(int(cal.get_loc(s.train[1])) + 7, int(cal.get_loc(s.valid[0])))
        self.assertLess(off[0].test[1], off[1].test[0])
        with self.assertRaises(ValueError):
            qfolds.live_segment(cal[:200])


class MetricsTests(unittest.TestCase):
    def panel(self, dates, scores, labels):
        rows = []
        for d, sc, lb in zip(dates, scores, labels):
            for i, (a, b) in enumerate(zip(sc, lb)):
                rows.append({"datetime": d, "instrument": "S%02d" % i, "score": a, "label": b})
        return pd.DataFrame(rows)

    def test_daily_ic_known_spearman(self):
        d = pd.bdate_range("2021-01-04", periods=3)
        df = self.panel(d, [[1, 2, 3, 4, 5]] * 2 + [[1, 2, 3, 4]],
                        [[1, 3, 2, 5, 4], [5, 4, 3, 2, 1], [1, 2, 3, 4]])
        ic = qmetrics.daily_ic(df)
        self.assertEqual(len(ic), 2)  # 4-name date dropped
        self.assertAlmostEqual(ic["rank_ic"].iloc[0], 0.8)
        self.assertAlmostEqual(ic["rank_ic"].iloc[1], -1.0)
        self.assertAlmostEqual(ic["ic"].iloc[0], float(np.corrcoef([1, 2, 3, 4, 5], [1, 3, 2, 5, 4])[0, 1]))
        self.assertEqual(list(ic["n"]), [5, 5])

    def test_newey_west_hand_computed(self):
        # x = [1,-1,2,0,3], lag 1: mean 1, gamma0 2, gamma1 -1, w 0.5 -> var 1, se sqrt(1/5), t sqrt(5)
        self.assertAlmostEqual(qmetrics.newey_west_t([1, -1, 2, 0, 3], lag=1), 5 ** 0.5)
        x = np.random.default_rng(3).normal(0.1, 1, 300)
        e = x - x.mean()
        var = e @ e / 300 + sum(2 * (1 - l / 5.0) * (e[l:] @ e[:-l]) / 300 for l in range(1, 5))
        self.assertAlmostEqual(qmetrics.newey_west_t(x, lag=4), x.mean() / (var / 300) ** 0.5)
        self.assertIsNone(qmetrics.newey_west_t([1.0]))

    def test_topk_and_quintile_sign(self):
        rng = np.random.default_rng(7)
        d = pd.bdate_range("2021-01-04", periods=40)
        labels = [list(rng.normal(0, 0.02, 30)) for _ in d]
        df = self.panel(d, labels, labels)  # score == label
        top = qmetrics.topk_spread(df, 5)
        self.assertEqual((top["k"], top["n_days"]), (5, 40))
        self.assertGreater(top["mean_excess"], 0)
        self.assertEqual(top["hit_rate"], 1.0)
        self.assertAlmostEqual(top["annualised"], top["mean_excess"] * 252 / 5, places=5)
        self.assertGreater(qmetrics.quintile_spread(df)["mean_excess"], 0)
        ev = qmetrics.evaluate_arm(df)
        self.assertAlmostEqual(ev["ic"]["rank_ic_mean"], 1.0)
        self.assertEqual(ev["ic"]["n_days"], 40)
        self.assertEqual([t["k"] for t in ev["topk"]], [5, 10, 20])
        self.assertEqual(ev["per_year"][0]["year"], 2021)
        self.assertEqual(ev["ic"]["pct_positive"], 1.0)
        rev = qmetrics.summarize_ic(qmetrics.daily_ic(df.assign(score=-df["score"])))
        self.assertAlmostEqual(rev["rank_ic_mean"], -1.0)
        self.assertEqual(qmetrics.summarize_ic(qmetrics.daily_ic(df.iloc[:0]))["n_days"], 0)


def planted_panel(n_symbols=12, n_days=700, seed=11):
    """{SYM: BarsResult}: the high-low range at t grows with the planted
    future return open[t+6]/open[t+1]-1, so price_range / KLEN carry it."""
    from agents.fixtures import FIXTURE_WARNING

    idx = pd.bdate_range("2019-01-02", periods=n_days)
    out = {}
    for i in range(n_symbols):
        rng = np.random.default_rng(seed + i)
        opens = 40.0 * (1 + i) * np.exp(np.cumsum(rng.normal(0, 0.015, n_days)))
        fwd = np.full(n_days, np.nan)
        fwd[:-6] = opens[6:] / opens[1:-5] - 1
        rngp = 0.02 * np.exp(8 * np.nan_to_num(fwd, nan=0.0))
        close = opens * (1 + rng.normal(0, 0.003, n_days))
        high = np.maximum(opens, close) * (1 + rngp / 2)
        low = np.minimum(opens, close) * (1 - rngp / 2)
        vol = rng.integers(500_000, 2_000_000, n_days).astype(float)
        df = pd.DataFrame({"open": opens, "high": high, "low": low, "close": close, "volume": vol}, index=idx)
        df.index.name = "date"
        out["P%sX" % chr(ord("A") + i)] = BarsResult(df, "fixture", True, FIXTURE_WARNING)
    return out


class QuantModelTests(unittest.TestCase):
    """Qlib-backed tests in one TestCase (one qlib import)."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="sst_agents_quant_model.")
        cls._env = mock.patch.dict(os.environ, {"SST_OFFLINE": "1", "QUANT_TEST_FAST": "1", "QUANT_N_JOBS": "2",
                                                "AGENT_CACHE_DIR": os.path.join(cls.tmp, "fix")}, clear=False)
        cls._env.start()
        syms = universe.all_symbols(True)
        raw.ingest(syms, offline=True)
        cls.fix_bars = raw.load_raw(syms)
        store.build_store(cls.fix_bars, universe.rank_universe(True), universe.benchmarks(True))
        cls.fix_store = store.store_dir()

    @classmethod
    def tearDownClass(cls):
        cls._env.stop()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def use_cache(self, name):
        os.environ["AGENT_CACHE_DIR"] = os.path.join(self.tmp, name)

    def init(self, store_path):
        from agents.quant.qlib_env import init_qlib

        init_qlib(store_path, mlruns=Path(self.tmp) / "mlruns_misc", force=True)

    def test_label_and_feature_counts(self):
        from qlib.data.dataset.handler import DataHandlerLP

        from agents.quant.handler import feature_count, make_handler

        self.init(self.fix_store)
        h = make_handler("sst14", ["QAA"], "2019-01-02", "2022-11-01")
        lab = h.fetch(col_set="label", data_key=DataHandlerLP.DK_R).xs("QAA", level="instrument").iloc[:, 0]
        o = self.fix_bars["QAA"].df["open"].to_numpy(dtype=np.float32).astype(float)
        for t in (0, 100, 500, 990):
            self.assertAlmostEqual(float(lab.iloc[t]), o[t + 6] / o[t + 1] - 1, places=5)
        self.assertTrue(np.isnan(lab.iloc[-1]))
        self.assertEqual(LABEL_EXPR, "Ref($open, -6) / Ref($open, -1) - 1")
        self.assertEqual(feature_count(h), 14)
        h2 = make_handler("alpha158_sst14", ["QAA", "QBB"], "2022-01-03", "2022-11-01")
        self.assertEqual(feature_count(h2), 172)
        cols = list(h2.fetch(col_set="feature").columns)
        self.assertIn("SST_PRICE_RANGE", cols)
        self.assertIn("KLEN", cols)
        with self.assertRaises(ValueError):
            make_handler("nope", ["QAA"], "2022-01-03", "2022-11-01")

    def test_no_look_ahead_in_features(self):
        from agents.quant.handler import make_handler

        t = pd.Timestamp("2021-06-30")
        changed = {}
        for s, r in self.fix_bars.items():
            df = r.df.copy()
            m = df.index > t
            df.loc[m, ["open", "high", "low", "close", "vwap"]] *= 1.6
            df.loc[m, "volume"] = df.loc[m, "volume"] * 0.3 + 1
            changed[s] = BarsResult(df, r.data_source, r.synthetic, r.warning)
        self.use_cache("changed")
        store.build_store(changed, universe.rank_universe(True), universe.benchmarks(True))
        alt_store = store.store_dir()
        frames = []
        for path in (self.fix_store, alt_store):
            self.init(path)
            h = make_handler("alpha158_sst14", ["QAA", "QCC"], "2019-01-02", "2022-11-01")
            frames.append(h.fetch(col_set="feature"))
        a, b = frames
        da = a.index.get_level_values("datetime")
        pd.testing.assert_frame_equal(a[da <= t], b[b.index.get_level_values("datetime") <= t])
        self.assertFalse(a[da > t].equals(b[b.index.get_level_values("datetime") > t]))

    def test_train_predict_planted_signal(self):
        from agents.quant import predict as qpredict
        from agents.quant import train as qtrain

        self.use_cache("planted")
        bars = planted_panel()
        rank = sorted(bars)
        store.build_store(bars, rank, [])
        summary = qtrain.run_train(["lgbm", "xgb14"], offline=True)
        root = Path(os.environ["AGENT_CACHE_DIR"]) / "quant"
        for arm in ("lgbm", "xgb14"):
            self.assertGreater(summary["arms"][arm]["rank_ic_mean"], 0.05, arm)
            self.assertEqual(summary["arms"][arm]["folds"], 2)
            p = pd.read_parquet(root / "predictions" / ("%s.parquet" % arm))
            self.assertEqual(list(p.columns), ["datetime", "instrument", "score", "label", "fold"])
            self.assertEqual(sorted(p["fold"].unique()), ["bar1", "bar2"])
            self.assertEqual(set(p["instrument"]), set(rank))
        self.assertEqual(summary["arms"]["lgbm"]["n_features"], 172)
        self.assertEqual(summary["arms"]["xgb14"]["n_features"], 14)
        self.assertIs(summary["synthetic"], True)
        self.assertTrue(summary["warning"])
        rid = summary["train_run_id"]
        self.assertEqual(json.loads((root / "models" / "latest.json").read_text())["train_run_id"], rid)
        man = json.loads((root / "models" / rid / "train_manifest.json").read_text())
        for k in ("train_run_id", "generated_at", "offline", "synthetic", "store", "calendar", "arms", "label",
                  "embargo", "n_jobs", "versions"):
            self.assertIn(k, man)
        self.assertEqual(man["label"]["expr"], LABEL_EXPR)
        self.assertEqual((man["embargo"], man["n_jobs"]), (7, 2))
        arm = man["arms"]["lgbm"]
        self.assertEqual(arm["params"]["num_boost_round"], 20)
        for f in arm["folds"]:
            self.assertTrue(Path(f["model_path"]).is_file())
            self.assertGreaterEqual(f["seconds"], 0)
            self.assertGreater(f["n_train"], 0)
        self.assertTrue(Path(arm["live"]["model_path"]).is_file())
        self.assertEqual(arm["live"]["train_end"], man["calendar"]["end"])
        self.assertEqual(man["versions"]["qlib"], "0.9.7")
        mlruns = root / "mlruns"
        self.assertTrue(list(mlruns.glob("*/*/meta.yaml")), "no MLflow recorder under the temp cache")
        self.assertFalse((Path(PROJECT_DIR) / "mlruns").exists())
        self.assertEqual(os.environ.get("MLFLOW_DISABLE_TELEMETRY"), "true")  # no MLflow telemetry call

        out = qpredict.run_predict(offline=True, symbols=rank + ["ZZZ"])
        self.assertEqual(out["as_of"], man["calendar"]["end"])
        self.assertEqual(sorted(out["written"]), rank)
        self.assertEqual(out["unavailable"], {"ZZZ": "not_in_quant_universe"})
        envs = {}
        for f in out["files"]:
            e = json.loads(Path(f).read_text())
            validate_envelope(e)
            envs[e["symbol"]] = e
        live = [envs[s] for s in rank]
        pcts = sorted(e["score"] for e in live)
        self.assertEqual((pcts[0], pcts[-1]), (0.0, 100.0))
        best = max(live, key=lambda e: e["features"]["prediction"])
        self.assertEqual((best["score"], best["features"]["rank"], best["direction"]), (100.0, 1, "bullish"))
        worst = min(live, key=lambda e: e["features"]["prediction"])
        self.assertEqual((worst["score"], worst["direction"], worst["confidence"]), (0.0, "bearish", 1.0))
        for e in live:
            self.assertEqual((e["agent"], e["synthetic"], e["ttl_hours"]), ("quant", True, 84.0))
            self.assertIn("SYNTHETIC", e["warning"])
            self.assertEqual(e["validation"], {"gate_id": "quant_rank", "passed": False})
            self.assertEqual(e["features"]["universe_size"], 12)
            self.assertEqual(e["features"]["model_id"], "lgbm-" + rid)
            self.assertEqual(e["features"]["label"], LABEL_EXPR)
            self.assertAlmostEqual(e["confidence"], abs(e["score"] - 50) / 50, places=4)
        self.assertFalse(envs["ZZZ"]["available"])

        # stale store -> every envelope unavailable 'stale_data'
        stale = qpredict.run_predict(as_of="2023-06-30", offline=True)
        self.assertEqual(stale["written"], [])
        self.assertEqual(set(stale["unavailable"].values()), {"stale_data"})


class QuantTrainCliTests(TempCacheMixin, unittest.TestCase):
    def run_cli(self, *args):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.tmp, "AGENT_CACHE_DIR": self.tmp,
               "SST_OFFLINE": "1", "SST_CONFIG_FILE": os.path.join(self.tmp, "none.sh"), "QUANT_TEST_FAST": "1"}
        return subprocess.run([sys.executable, "-m", "agents", *args], cwd=PROJECT_DIR, env=env,
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=300)

    def test_train_without_store_and_predict_without_models(self):
        p = self.run_cli("quant", "train", "--offline")
        self.assertEqual(p.returncode, 2, p.stdout + p.stderr)
        self.assertEqual(json.loads(p.stdout)["error"], "store_unavailable")
        p = self.run_cli("quant", "train", "--offline", "--arms", "lgbm,nope")
        self.assertEqual(p.returncode, 1, p.stdout)
        self.assertEqual(json.loads(p.stdout)["error"], "invalid_arms")
        raw.ingest(universe.all_symbols(True), offline=True)
        store.build_store(raw.load_raw(universe.all_symbols(True)), universe.rank_universe(True),
                          universe.benchmarks(True))
        p = self.run_cli("quant", "predict", "--offline")
        self.assertEqual(p.returncode, 2, p.stdout + p.stderr)
        self.assertEqual(json.loads(p.stdout)["error"], "predictions_unavailable")


if __name__ == "__main__":
    sys.exit(run_tests(sys.modules[__name__]))
