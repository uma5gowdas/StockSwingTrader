#!/usr/bin/env python3
"""Agents: Data Clients (run with .venv-agents/bin/python; no network).

The Alpaca bars client runs against an in-process http.server on 127.0.0.1
that serves tests/fixtures/agents/alpaca/*.json. Also covers the offline
fixture loader and the opt-in yfinance fallback (stub module).
"""

import json
import os
import re
import shutil
import sys
import tempfile
import threading
import time
import unittest
from datetime import date, datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from agents_unittest import PROJECT_DIR, run_tests  # noqa: E402

import pandas as pd  # noqa: E402

from agents.config import Config, SafetyError  # noqa: E402
from agents.data import BarsResult, Unavailable, load_bars  # noqa: E402
from agents.data import alpaca as alpaca_mod  # noqa: E402
from agents.data import yf_fallback  # noqa: E402
from agents.data.alpaca import AlpacaBarsClient, expected_last_session, staleness_cutoff  # noqa: E402

FIX = Path(PROJECT_DIR) / "tests" / "fixtures" / "agents"
PAGE1 = json.loads((FIX / "alpaca" / "bars_page1.json").read_text())
PAGE2 = json.loads((FIX / "alpaca" / "bars_page2.json").read_text())
STALE = json.loads((FIX / "alpaca" / "bars_stale.json").read_text())
KEY, SECRET = "PKFAKEDATA000000", "fakeDataSecret000000"
START, END, AS_OF = "2022-09-01", "2022-11-02", "2022-11-02"


class StubHandler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _record(self):
        u = urlparse(self.path)
        self.server.log.append({"method": self.command, "path": u.path, "query": parse_qs(u.query),
                                "headers": {k: v for k, v in self.headers.items()}})
        return u, parse_qs(u.query)

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
        u, q = self._record()
        mode = self.server.mode
        if u.path != "/v2/stocks/bars":
            return self._send(404)
        if mode == "slow":
            time.sleep(1.5)
        if mode == "sip403" and q.get("feed") == ["sip"]:
            return self._send(403, {"message": "subscription does not permit querying recent SIP data"})
        if mode == "429" and self.server.count_429 > 0:
            self.server.count_429 -= 1
            return self._send(429, {"message": "too many requests"}, {"Retry-After": "0"})
        if mode == "500":
            return self._send(500)
        if mode == "stale":
            return self._send(200, STALE)
        if q.get("page_token") == ["fixture-page-2"]:
            return self._send(200, PAGE2)
        return self._send(200, PAGE1)

    def _refuse(self):
        self._record()
        self._send(405)

    do_POST = do_DELETE = do_PUT = do_PATCH = _refuse


class AlpacaStubMixin:
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sst_agents_data.")
        self._env = mock.patch.dict(os.environ, {"AGENT_CACHE_DIR": self.tmp}, clear=False)
        self._env.start()
        for k in ("SST_OFFLINE", "SST_ALLOW_SYNTHETIC", "AGENT_DATA_FALLBACK", "AGENT_MAX_BAR_STALENESS_DAYS"):
            os.environ.pop(k, None)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), StubHandler)
        self.server.log, self.server.mode, self.server.count_429 = [], "paged", 0
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.sleeps = []

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self._env.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def cfg(self, **kw):
        values = {"ALPACA_BASE_URL": "https://paper-api.alpaca.markets", "ALPACA_DATA_URL": self.url,
                  "ALPACA_API_KEY": KEY, "ALPACA_SECRET_KEY": SECRET}
        values.update(kw)
        return Config(values)

    def client(self, **kw):
        timeout = kw.pop("timeout", 5.0)
        use_cache = kw.pop("use_cache", True)
        return AlpacaBarsClient(self.cfg(**kw), timeout=timeout, sleep=self.sleeps.append, use_cache=use_cache)


class AlpacaClientTests(AlpacaStubMixin, unittest.TestCase):
    def test_pagination_is_merged_and_dates_are_new_york(self):
        res = self.client().fetch(["AAA", "BBB"], START, END, as_of=AS_OF)
        self.assertEqual(len(self.server.log), 2)
        self.assertNotIn("page_token", self.server.log[0]["query"])
        self.assertEqual(self.server.log[1]["query"]["page_token"], ["fixture-page-2"])
        csv = pd.read_csv(FIX / "bars" / "AAA.csv", parse_dates=["date"]).set_index("date").iloc[-40:]
        for sym in ("AAA", "BBB"):
            r = res[sym]
            self.assertIsInstance(r, BarsResult)
            self.assertEqual((r.data_source, r.synthetic, r.warning), ("alpaca:sip", False, None))
            self.assertEqual(len(r.df), 40)
            self.assertTrue(r.df.index.is_monotonic_increasing)
        self.assertEqual(list(res["AAA"].df.index), list(csv.index))
        self.assertAlmostEqual(float(res["AAA"].df["close"].iloc[-1]), float(csv["close"].iloc[-1]), places=4)

    def test_request_parameters_and_auth_header_names(self):
        self.client().fetch(["AAA", "BBB"], START, END, as_of=AS_OF)
        req = self.server.log[0]
        q = req["query"]
        self.assertEqual(q["symbols"], ["AAA,BBB"])
        self.assertEqual((q["timeframe"], q["adjustment"], q["feed"], q["limit"]),
                         (["1Day"], ["all"], ["sip"], ["10000"]))
        self.assertEqual(q["start"], ["2022-09-01"])
        self.assertEqual(q["end"], ["2022-11-03T03:59:59Z"])  # 23:59:59 America/New_York (EDT)
        self.assertEqual(req["headers"].get("APCA-API-KEY-ID"), KEY)
        self.assertEqual(req["headers"].get("APCA-API-SECRET-KEY"), SECRET)

    def test_end_is_clamped_to_20_minutes_ago(self):
        future = (date.today() + timedelta(days=10)).isoformat()
        self.client().fetch(["AAA"], START, future, as_of=AS_OF)
        end = datetime.strptime(self.server.log[0]["query"]["end"][0], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        self.assertLessEqual(end, datetime.now(timezone.utc) - timedelta(minutes=19))

    def test_only_get_requests(self):
        c = self.client()
        c.fetch(["AAA", "BBB"], START, END, as_of=AS_OF)
        self.server.mode = "sip403"
        self.client(use_cache=False).fetch(["AAA"], START, END, as_of=AS_OF)
        self.assertTrue(self.server.log)
        self.assertEqual({r["method"] for r in self.server.log}, {"GET"})
        code = "\n".join(p.read_text() for p in (Path(PROJECT_DIR) / "agents" / "data").glob("*.py"))
        self.assertIsNone(re.search(r'"(POST|DELETE|PUT|PATCH)"|\.(post|delete|put|patch)\(', code))
        self.assertNotIn("/v2/orders", code)

    def test_non_whitelisted_hosts_raise_before_any_request(self):
        for url in ("https://evil.example.com", "http://data.alpaca.markets", "https://data.alpaca.markets.evil.io",
                    "https://api.alpaca.markets"):
            with self.assertRaises(SafetyError, msg=url):
                self.client(ALPACA_DATA_URL=url)
        for base in ("https://api.alpaca.markets", "", "http://127.0.0.1:1"):
            with self.assertRaises(SafetyError, msg=base):
                self.client(ALPACA_BASE_URL=base)
        with self.assertRaises(SafetyError):
            alpaca_mod.check_data_url("ftp://127.0.0.1/x")
        self.assertEqual(self.server.log, [])
        # default data URL is the whitelisted production data host
        c = AlpacaBarsClient(Config({"ALPACA_BASE_URL": "https://paper-api.alpaca.markets"}), use_cache=False)
        self.assertEqual(c.base, "https://data.alpaca.markets")

    def test_sip_403_falls_back_to_iex_once(self):
        self.server.mode = "sip403"
        res = self.client().fetch(["AAA", "BBB"], START, END, as_of=AS_OF)
        self.assertEqual(res["AAA"].data_source, "alpaca:iex")
        self.assertEqual(len(res["AAA"].df), 40)
        self.assertEqual([r["query"]["feed"][0] for r in self.server.log], ["sip", "iex", "iex"])
        self.server.log.clear()
        res = self.client(AGENT_BARS_FEED="iex", use_cache=False).fetch(["AAA"], START, END, as_of=AS_OF)
        self.assertEqual(res["AAA"].data_source, "alpaca:iex")

    def test_429_then_200_is_retried_honouring_retry_after(self):
        self.server.mode, self.server.count_429 = "429", 2
        res = self.client().fetch(["AAA"], START, END, as_of=AS_OF)
        self.assertIsInstance(res["AAA"], BarsResult)
        self.assertEqual(self.sleeps, [0.0, 0.0])
        self.assertEqual(len(self.server.log), 4)  # 429, 429, page1, page2

    def test_persistent_5xx_gives_up_after_3_retries(self):
        self.server.mode = "500"
        res = self.client().fetch(["AAA"], START, END, as_of=AS_OF)
        self.assertIsInstance(res["AAA"], Unavailable)
        self.assertEqual(res["AAA"].reason, "http_500")
        self.assertEqual(len(self.server.log), 4)

    def test_stale_bars_are_unavailable(self):
        self.server.mode = "stale"
        res = self.client().fetch(["AAA"], START, END, as_of=AS_OF)
        self.assertIsInstance(res["AAA"], Unavailable)
        last = STALE["bars"]["AAA"][-1]["t"][:10]
        self.assertEqual(res["AAA"].reason, "stale_data: last bar %s" % last)
        self.assertIsNone(res["AAA"].data_source)

    def test_symbol_without_bars_is_unavailable(self):
        res = self.client().fetch(["AAA", "CCC"], START, END, as_of=AS_OF)
        self.assertIsInstance(res["AAA"], BarsResult)
        self.assertEqual(res["CCC"].reason, "no_bars")

    def test_timeout_is_unavailable(self):
        self.server.mode = "slow"
        res = self.client(timeout=0.3).fetch(["AAA"], START, END, as_of=AS_OF)
        self.assertIsInstance(res["AAA"], Unavailable)
        self.assertEqual(res["AAA"].reason, "timeout")

    def test_cache_reuse_makes_no_second_request(self):
        first = self.client().fetch(["AAA", "BBB"], START, END, as_of=AS_OF)
        n = len(self.server.log)
        self.assertTrue((Path(self.tmp) / "data" / "alpaca" / "AAA_1Day_all.csv").is_file())
        meta = json.loads((Path(self.tmp) / "data" / "alpaca" / "AAA_1Day_all.meta.json").read_text())
        self.assertEqual((meta["data_source"], meta["rows"]), ("alpaca:sip", 40))
        again = self.client().fetch(["AAA", "BBB"], "2022-10-01", END, as_of=AS_OF)
        self.assertEqual(len(self.server.log), n)
        self.assertEqual(again["AAA"].data_source, "alpaca:sip")
        self.assertEqual(list(again["AAA"].df.index), [d for d in first["AAA"].df.index if d >= pd.Timestamp("2022-10-01")])
        # wider range than cached -> fetched again
        self.client().fetch(["AAA"], "2022-01-01", END, as_of=AS_OF)
        self.assertGreater(len(self.server.log), n)

    def test_missing_credentials_make_no_request(self):
        res = self.client(ALPACA_API_KEY="", ALPACA_SECRET_KEY="").fetch(["AAA"], START, END, as_of=AS_OF)
        self.assertIsInstance(res["AAA"], Unavailable)
        self.assertIn("credentials", res["AAA"].reason)
        self.assertEqual(self.server.log, [])
        self.assertNotIn(KEY, repr(self.client()))

    def test_expected_last_session_and_cutoff(self):
        self.assertEqual(expected_last_session("2022-11-02"), date(2022, 11, 2))
        today = alpaca_mod.ny_today()
        exp = expected_last_session(today.isoformat())
        self.assertLess(exp, today)
        self.assertLess(exp.weekday(), 5)
        self.assertEqual(staleness_cutoff("2022-11-02", 3), date(2022, 10, 28))
        self.assertEqual(staleness_cutoff("2022-11-07", 0), date(2022, 11, 7))


class FakeClient:
    def __init__(self, result):
        self.result, self.calls = result, 0

    def fetch(self, symbols, start, end, as_of=None):
        self.calls += 1
        return {s: self.result(s) for s in symbols}


class LoadBarsTests(unittest.TestCase):
    def setUp(self):
        self._env = mock.patch.dict(os.environ, {}, clear=False)
        self._env.start()
        for k in ("SST_OFFLINE", "SST_ALLOW_SYNTHETIC", "AGENT_DATA_FALLBACK"):
            os.environ.pop(k, None)

    def tearDown(self):
        self._env.stop()
        for name in [m for m in sys.modules if m == "yfinance"]:
            del sys.modules[name]

    def test_offline_uses_fixtures_labeled_synthetic(self):
        os.environ["SST_OFFLINE"] = "1"
        res = load_bars(["AAA", "SPY", "NOPE"], "2020-01-01", "2022-12-31", as_of="2022-06-30")
        for sym in ("AAA", "SPY"):
            r = res[sym]
            self.assertIsInstance(r, BarsResult)
            self.assertEqual(r.data_source, "fixture")
            self.assertIs(r.synthetic, True)
            self.assertTrue(r.warning and "SYNTHETIC" in r.warning)
            self.assertLessEqual(r.df.index[-1], pd.Timestamp("2022-06-30"))
            self.assertGreaterEqual(r.df.index[0], pd.Timestamp("2020-01-01"))
            self.assertEqual(list(r.df.columns), ["open", "high", "low", "close", "volume"])
        self.assertIsInstance(res["NOPE"], Unavailable)
        self.assertIn("no fixture", res["NOPE"].reason)

    def test_online_unavailable_stays_unavailable_without_opt_in(self):
        fake = FakeClient(lambda s: Unavailable("http_500"))
        res = load_bars(["AAA"], "2020-01-01", "2022-06-30", as_of="2022-06-30", client=fake)
        self.assertIsInstance(res["AAA"], Unavailable)
        self.assertEqual(res["AAA"].reason, "http_500")
        self.assertEqual(fake.calls, 1)

    def test_allow_synthetic_is_labeled(self):
        os.environ["SST_ALLOW_SYNTHETIC"] = "1"
        res = load_bars(["AAA"], "2020-01-01", "2022-06-30", as_of="2022-06-30",
                        client=FakeClient(lambda s: Unavailable("http_500")))
        self.assertEqual((res["AAA"].data_source, res["AAA"].synthetic), ("fixture", True))
        self.assertTrue(res["AAA"].warning)

    def test_yfinance_fallback_is_off_by_default(self):
        self.assertFalse(yf_fallback.is_enabled())
        stub = str(Path(PROJECT_DIR) / "tests" / "stubs" / "yfinance_fixture")
        sys.path.insert(0, stub)
        try:
            self.assertFalse(yf_fallback.is_enabled())  # importable, but not opted in
            res = load_bars(["AAA"], "2024-01-02", "2024-03-28", as_of="2024-03-28",
                            client=FakeClient(lambda s: Unavailable("http_500")))
            self.assertIsInstance(res["AAA"], Unavailable)
            os.environ["AGENT_DATA_FALLBACK"] = "yfinance"
            self.assertTrue(yf_fallback.is_enabled())
            res = load_bars(["AAA"], "2024-01-02", "2024-03-28", as_of="2024-03-28",
                            client=FakeClient(lambda s: Unavailable("http_500")))
            r = res["AAA"]
            self.assertIsInstance(r, BarsResult)
            self.assertEqual((r.data_source, r.synthetic, r.warning), ("yfinance", False, "fallback source"))
            self.assertGreater(len(r.df), 40)
        finally:
            sys.path.remove(stub)
        os.environ["AGENT_DATA_FALLBACK"] = "yfinance"
        sys.modules.pop("yfinance", None)
        with mock.patch("importlib.util.find_spec", return_value=None):
            self.assertFalse(yf_fallback.is_enabled())  # not importable -> off

    def test_alpaca_result_wins_over_fallback(self):
        os.environ["AGENT_DATA_FALLBACK"] = "yfinance"
        df = pd.DataFrame({"open": [1.0], "high": [1.0], "low": [1.0], "close": [1.0], "volume": [1.0]},
                          index=pd.DatetimeIndex([pd.Timestamp("2022-06-30")], name="date"))
        res = load_bars(["AAA"], "2022-06-01", "2022-06-30", as_of="2022-06-30",
                        client=FakeClient(lambda s: BarsResult(df, "alpaca:sip", False, None)))
        self.assertEqual(res["AAA"].data_source, "alpaca:sip")

    def test_invalid_symbol_raises(self):
        with self.assertRaises(ValueError):
            load_bars(["../x"], "2022-01-01", "2022-06-30", client=FakeClient(lambda s: None))


if __name__ == "__main__":
    sys.exit(run_tests(sys.modules[__name__]))
