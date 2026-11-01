#!/usr/bin/env python3
"""Agents: Quant (run with .venv-agents/bin/python; no network).

Quant data pipeline (Phase 2, FEAT-001): universe file, raw Alpaca bar store
(offline fixtures and a 127.0.0.1 Alpaca stub), the 14 legacy features, the
Qlib bin store (round trip through qlib.data.D.features) and the CLI.
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
        import qlib
        from qlib.constant import REG_US

        qlib.init(provider_uri=str(store.store_dir()), region=REG_US, kernels=1,
                  expression_cache=None, dataset_cache=None)

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


if __name__ == "__main__":
    sys.exit(run_tests(sys.modules[__name__]))
