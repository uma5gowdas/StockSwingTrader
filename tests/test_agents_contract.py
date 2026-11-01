#!/usr/bin/env python3
"""Agents: Contract (run with .venv-agents/bin/python; offline, no network).

Envelope schema + rules, atomic cache writes, cache path guards, config
loading/masking, assert_paper, LLM providers and the $0 budget, CLI exit
codes and secret-free status output.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.request
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from agents_unittest import PROJECT_DIR, run_tests  # noqa: E402

from agents import AGENT_NAMES, __version__  # noqa: E402
from agents import cache as cache_mod  # noqa: E402
from agents.config import Config, SafetyError, assert_paper, endpoint_mode, load_config  # noqa: E402
from agents.envelope import (EnvelopeError, envelope_errors, make_envelope,  # noqa: E402
                             unavailable_envelope, validate_envelope)
from agents.llm import (BudgetLedger, BudgetRefused, FakeProvider, NoneProvider,  # noqa: E402
                        OllamaProvider, OpenAICompatibleProvider, get_provider)

FAKE_KEY = "PKFAKEKEY0123456789X"
FAKE_SECRET = "fakeSecretValue0123456789abcdef"


def good(**kw):
    args = dict(score=62, direction="bullish", confidence=0.55, data_sources=["alpaca:sip"])
    args.update(kw)
    return make_envelope("technical", "AAPL", "2026-10-30", **args)


class TempCacheMixin:
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sst_agents_contract.")
        self._env = mock.patch.dict(os.environ, {"AGENT_CACHE_DIR": self.tmp}, clear=False)
        self._env.start()

    def tearDown(self):
        self._env.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)


class EnvelopeSchemaTests(unittest.TestCase):
    def test_valid_envelope_has_exactly_the_section_5_2_fields(self):
        env = good()
        self.assertEqual(envelope_errors(env), [])
        self.assertEqual(set(env), {
            "agent", "agent_version", "symbol", "as_of", "generated_at", "ttl_hours", "available",
            "reason", "data_sources", "synthetic", "score", "direction", "confidence", "veto",
            "features", "evidence", "llm", "validation", "warning"})
        self.assertEqual(env["agent_version"], __version__)
        self.assertEqual(env["llm"]["mode"], "none")
        self.assertRegex(env["generated_at"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

    def test_schema_rejects_bad_values(self):
        for field, value in (("score", 150), ("score", -1), ("direction", "up"), ("confidence", 1.5),
                             ("symbol", "aapl"), ("as_of", "2026-1-1"), ("agent", "nope"),
                             ("ttl_hours", 0), ("data_sources", "alpaca")):
            env = good()
            env[field] = value
            self.assertTrue(envelope_errors(env), "%s=%r should be invalid" % (field, value))
            with self.assertRaises(EnvelopeError):
                validate_envelope(env)

    def test_schema_rejects_missing_and_extra_fields(self):
        env = good()
        del env["warning"]
        self.assertTrue(envelope_errors(env))
        env = good()
        env["extra"] = 1
        self.assertTrue(envelope_errors(env))
        self.assertTrue(envelope_errors([]))

    def test_unavailable_envelope_rules(self):
        env = unavailable_envelope("quant", "MSFT", "2026-10-30", "no market data")
        self.assertEqual(envelope_errors(env), [])
        self.assertIs(env["available"], False)
        self.assertIsNone(env["score"])
        self.assertIsNone(env["direction"])
        self.assertIsNone(env["confidence"])
        self.assertEqual(env["data_sources"], [])
        self.assertEqual(env["reason"], "no market data")

    def test_available_false_with_score_or_sources_is_invalid(self):
        env = unavailable_envelope("quant", "MSFT", "2026-10-30", "x")
        for field, value in (("score", 50), ("data_sources", ["alpaca:sip"]), ("direction", "neutral"),
                             ("confidence", 0.5), ("reason", None)):
            bad = dict(env)
            bad[field] = value
            self.assertTrue(any(e.startswith("rule:") for e in envelope_errors(bad)), field)

    def test_synthetic_requires_warning(self):
        with self.assertRaises(EnvelopeError):
            good(synthetic=True)
        with self.assertRaises(EnvelopeError):
            good(synthetic=True, warning="")
        env = good(synthetic=True, warning="SYNTHETIC fixture data")
        self.assertEqual(envelope_errors(env), [])


class CacheTests(TempCacheMixin, unittest.TestCase):
    def test_cache_root_from_env_and_relative_resolution(self):
        self.assertEqual(cache_mod.cache_root(), Path(self.tmp))
        with mock.patch.dict(os.environ, {"AGENT_CACHE_DIR": "cache/agents_rel"}):
            self.assertEqual(cache_mod.cache_root(), Path(PROJECT_DIR) / "cache" / "agents_rel")
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("AGENT_CACHE_DIR", None)
            self.assertEqual(cache_mod.cache_root(), Path(PROJECT_DIR) / "cache" / "agents")

    def test_cache_path_layout(self):
        p = cache_mod.cache_path("quant", "2026-10-30", "BRK.B")
        self.assertEqual(p, Path(self.tmp) / "quant" / "2026-10-30" / "BRK.B.json")
        self.assertEqual(cache_mod.gate_path("quant_rank"), Path(self.tmp) / "gates" / "quant_rank.json")

    def test_cache_path_rejects_traversal_bad_as_of_unknown_agent(self):
        for sym in ("../etc", "AA/BB", "A..B", "..", "", "aapl", "TOOLONGSYMBOL1", "AAPL\n"):
            with self.assertRaises(ValueError, msg=repr(sym)):
                cache_mod.cache_path("quant", "2026-10-30", sym)
        for as_of in ("2026-1-30", "../2026-10-30", "20261030", "2026-10-30/..", ""):
            with self.assertRaises(ValueError, msg=repr(as_of)):
                cache_mod.cache_path("quant", as_of, "AAPL")
        for agent in ("nope", "../quant", "", "gates"):
            with self.assertRaises(ValueError, msg=repr(agent)):
                cache_mod.cache_path(agent, "2026-10-30", "AAPL")
        for sig in ("../x", "Quant", "", "a/b"):
            with self.assertRaises(ValueError):
                cache_mod.gate_path(sig)
        self.assertEqual(set(AGENT_NAMES), {"market", "fundamental", "technical", "quant", "validate", "portfolio"})

    def test_atomic_write_leaves_no_temp_file(self):
        target = Path(self.tmp) / "sub" / "x.json"
        cache_mod.atomic_write_json(target, {"a": 1})
        self.assertEqual(json.loads(target.read_text()), {"a": 1})
        self.assertEqual(sorted(os.listdir(target.parent)), ["x.json"])

    def test_failed_write_leaves_no_partial_file(self):
        target = Path(self.tmp) / "y.json"
        cache_mod.atomic_write_json(target, {"v": "old"})
        with mock.patch("agents.cache.os.replace", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                cache_mod.atomic_write_json(target, {"v": "new"})
        self.assertEqual(json.loads(target.read_text()), {"v": "old"})
        self.assertEqual(sorted(os.listdir(self.tmp)), ["y.json"])
        with self.assertRaises(ValueError):
            cache_mod.atomic_write_json(Path(self.tmp) / "nan.json", {"v": float("nan")})
        self.assertFalse((Path(self.tmp) / "nan.json").exists())
        self.assertEqual(sorted(os.listdir(self.tmp)), ["y.json"])

    def test_concurrent_writers_leave_valid_json(self):
        target = Path(self.tmp) / "c.json"
        cache_mod.atomic_write_json(target, {"writer": -1, "pad": "x" * 5000})
        bad = []
        stop = threading.Event()

        def writer(n):
            for i in range(40):
                cache_mod.atomic_write_json(target, {"writer": n, "i": i, "pad": "x" * 5000})

        def reader():
            while not stop.is_set():
                try:
                    json.loads(target.read_text())
                except ValueError as exc:
                    bad.append(str(exc))

        r = threading.Thread(target=reader)
        r.start()
        ws = [threading.Thread(target=writer, args=(n,)) for n in range(6)]
        for w in ws:
            w.start()
        for w in ws:
            w.join()
        stop.set()
        r.join()
        self.assertEqual(bad, [])
        self.assertIn(json.loads(target.read_text())["writer"], range(6))
        self.assertEqual(sorted(os.listdir(self.tmp)), ["c.json"])

    def test_write_envelope_validates_first(self):
        env = good()
        path = cache_mod.write_envelope(env)
        self.assertEqual(path, Path(self.tmp) / "technical" / "2026-10-30" / "AAPL.json")
        self.assertEqual(json.loads(path.read_text()), env)
        env2 = dict(env, symbol="MSFT", score=999)
        with self.assertRaises(EnvelopeError):
            cache_mod.write_envelope(env2)
        self.assertFalse((Path(self.tmp) / "technical" / "2026-10-30" / "MSFT.json").exists())


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sst_agents_cfg.")
        self.cfg_file = os.path.join(self.tmp, "config.sh")
        with open(self.cfg_file, "w") as fh:
            fh.write('export ALPACA_API_KEY="%s"\n' % FAKE_KEY)
            fh.write('export ALPACA_SECRET_KEY="%s"\n' % FAKE_SECRET)
            fh.write('export ALPACA_BASE_URL="https://paper-api.alpaca.markets"\n')
            fh.write('export AGENT_QUANT_WEIGHT="0.2"\n')
            fh.write('export API_KEY_FINNHUB=""\n')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def env(self, **extra):
        e = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.tmp, "SST_CONFIG_FILE": self.cfg_file}
        e.update(extra)
        return e

    def test_reads_whitelisted_names_from_config_file(self):
        cfg = load_config(self.env())
        self.assertEqual(cfg.get("ALPACA_API_KEY"), FAKE_KEY)
        self.assertEqual(cfg.get("AGENT_QUANT_WEIGHT"), "0.2")
        self.assertEqual(cfg.get("ALPACA_BASE_URL"), "https://paper-api.alpaca.markets")
        # template defaults are read too (AGENT_* block in config.template.sh)
        self.assertEqual(cfg.get("AGENTS_ENABLED"), "false")
        self.assertNotIn("PATH", cfg)
        self.assertNotIn("MAX_ORDER_QTY", cfg)

    def test_file_value_wins_and_environment_is_fallback(self):
        cfg = load_config(self.env(ALPACA_API_KEY="ENVKEY_SHOULD_LOSE", FRED_API_KEY="envfredkey123",
                                   API_KEY_NEWSAPI="envnews123"))
        self.assertEqual(cfg.get("ALPACA_API_KEY"), FAKE_KEY)
        self.assertEqual(cfg.get("FRED_API_KEY"), "envfredkey123")
        # template: API_KEY_NEWSAPI="${API_KEY_NEWSAPI:-demo}" keeps the env value
        self.assertEqual(cfg.get("API_KEY_NEWSAPI"), "envnews123")
        self.assertFalse(cfg.has("API_KEY_FINNHUB"))  # empty in file; template placeholder "demo"

    def test_repr_masks_values(self):
        cfg = load_config(self.env())
        text = repr(cfg) + str(cfg)
        self.assertNotIn(FAKE_KEY, text)
        self.assertNotIn(FAKE_SECRET, text)
        self.assertIn("ALPACA_API_KEY=<set>", text)
        self.assertNotIn("SECRETVALUE", repr(Config({"X": "SECRETVALUE"})))

    def test_assert_paper(self):
        assert_paper(Config({"ALPACA_BASE_URL": "https://paper-api.alpaca.markets"}))
        assert_paper(Config({"ALPACA_BASE_URL": "https://paper-api.alpaca.markets/v2"}))
        for url in ("https://api.alpaca.markets", "https://paper-api.alpaca.markets.evil.example",
                    "https://evil.example/paper-api.alpaca.markets", "http://127.0.0.1:8080", ""):
            with self.assertRaises(SafetyError, msg=url):
                assert_paper(Config({"ALPACA_BASE_URL": url}))
        with self.assertRaises(SafetyError):
            assert_paper(Config({}))
        self.assertEqual(endpoint_mode(Config({"ALPACA_BASE_URL": "https://api.alpaca.markets"})), "LIVE")
        self.assertEqual(endpoint_mode(Config({"ALPACA_BASE_URL": "http://127.0.0.1:9"})), "LOCAL")


class LLMTests(TempCacheMixin, unittest.TestCase):
    def test_none_provider_is_default_and_returns_none(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("LLM_PROVIDER", None)
            self.assertIsInstance(get_provider(), NoneProvider)
        self.assertIsNone(NoneProvider().complete("p", {"type": "object"}, {}))

    def test_fake_provider(self):
        schema = {"type": "object", "required": ["tone"], "properties": {"tone": {"type": "number"}}}
        fake = FakeProvider([{"tone": 0.5}, {"bad": 1}])
        self.assertEqual(fake.complete("p1", schema, {"a": 1}), {"tone": 0.5})
        self.assertIsNone(fake.complete("p2", schema, {}))  # fails the schema
        self.assertIsNone(fake.complete("p3", schema, {}))  # queue empty
        self.assertEqual([c["prompt"] for c in fake.calls], ["p1", "p2", "p3"])

    def test_budget_zero_refuses_cloud_and_local_before_any_http(self):
        def no_http(*a, **k):
            raise AssertionError("urlopen must not be called")

        ledger = Path(self.tmp) / "llm" / "ledger.jsonl"
        with mock.patch.object(urllib.request, "urlopen", side_effect=no_http) as m:
            with mock.patch.dict(os.environ, {"LLM_MONTHLY_BUDGET_USD": "0", "LLM_MAX_CALLS_PER_RUN": "5"}):
                cloud = OpenAICompatibleProvider("https://api.example.invalid", "m", api_key="sk-test")
                self.assertIsNone(cloud.complete("hello", {"type": "object"}, {"x": 1}))
            with mock.patch.dict(os.environ, {"LLM_MONTHLY_BUDGET_USD": "100", "LLM_MAX_CALLS_PER_RUN": "0"}):
                cloud = OpenAICompatibleProvider("https://api.example.invalid", "m")
                self.assertIsNone(cloud.complete("hello", {"type": "object"}, {}))
                local = OllamaProvider()
                self.assertIsNone(local.complete("hello", {"type": "object"}, {}))
            for k in ("LLM_MONTHLY_BUDGET_USD", "LLM_MAX_CALLS_PER_RUN"):
                os.environ.pop(k, None)
            self.assertIsNone(OpenAICompatibleProvider("https://api.example.invalid", "m").complete("x", {}, {}))
            self.assertEqual(m.call_count, 0)
        self.assertFalse(ledger.exists())
        with self.assertRaises(BudgetRefused):
            BudgetLedger().authorize("cloud", 0.01)
        self.assertNotIn("sk-test", repr(OpenAICompatibleProvider("https://a.invalid", "m", api_key="sk-test")))


class CLITests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sst_agents_cli.")
        self.cfg_file = os.path.join(self.tmp, "config.sh")
        with open(self.cfg_file, "w") as fh:
            fh.write('export ALPACA_API_KEY="%s"\nexport ALPACA_SECRET_KEY="%s"\n' % (FAKE_KEY, FAKE_SECRET))
            fh.write('export ALPACA_BASE_URL="https://paper-api.alpaca.markets"\n')
            fh.write('export FRED_API_KEY="fredFAKE0123456789"\n')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_cli(self, *args, cfg=None):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.tmp,
               "AGENT_CACHE_DIR": os.path.join(self.tmp, "cache"), "SST_OFFLINE": "1"}
        if cfg is not False:
            env["SST_CONFIG_FILE"] = cfg or self.cfg_file
        return subprocess.run([sys.executable, "-m", "agents", *args], cwd=PROJECT_DIR, env=env,
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)

    def test_status_prints_booleans_not_values(self):
        for args in (("status",), ("technical", "status"), ("quant", "status")):
            p = self.run_cli(*args)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            for secret in (FAKE_KEY, FAKE_SECRET, "fredFAKE0123456789"):
                self.assertNotIn(secret, p.stdout + p.stderr)
            out = json.loads(p.stdout)
            self.assertEqual(out["endpoint_mode"], "PAPER")
            self.assertIs(out["has_alpaca_api_key"], True)
            self.assertIs(out["has_fred_api_key"], True)
            self.assertIs(out["has_api_key_newsapi"], False)
            self.assertEqual(out["agents_version"], __version__)
            self.assertEqual(out["cache_dir"], os.path.join(self.tmp, "cache"))
            self.assertTrue(all(isinstance(v, bool) for k, v in out.items() if k.startswith("has_")))

    def test_status_with_the_real_config_prints_no_key_value(self):
        p = self.run_cli("status", cfg=False)
        self.assertEqual(p.returncode, 0, p.stderr)
        cfg = load_config({"PATH": os.environ.get("PATH", ""), "HOME": self.tmp})
        leaked = [n for n in ("ALPACA_API_KEY", "ALPACA_SECRET_KEY", "API_KEY_FINNHUB", "API_KEY_NEWSAPI",
                              "FRED_API_KEY") if len(cfg.get(n, "") or "") >= 8 and cfg.get(n) in p.stdout]
        self.assertEqual(leaked, [])  # names only; values are never printed
        self.assertEqual(json.loads(p.stdout)["endpoint_mode"], "PAPER")

    def test_exit_codes(self):
        p = self.run_cli("bogus", "run")
        self.assertEqual(p.returncode, 1)
        self.assertEqual(json.loads(p.stdout)["error"], "unknown_agent")
        p = self.run_cli("quant", "run")
        self.assertEqual(p.returncode, 1)
        self.assertEqual(json.loads(p.stdout), {"error": "not_implemented", "agent": "quant", "command": "run"})
        for agent in ("market", "fundamental", "portfolio"):
            p = self.run_cli(agent, "run")
            self.assertEqual((p.returncode, json.loads(p.stdout)["error"]), (1, "not_implemented"))
        p = self.run_cli("quant", "nonsense")
        self.assertEqual((p.returncode, json.loads(p.stdout)["error"]), (1, "unknown_command"))
        p = self.run_cli("--no-such-option")
        self.assertEqual(p.returncode, 1)  # usage error is 1, not argparse's 2
        p = self.run_cli("technical", "run", "--as-of", "2026/10/30")
        self.assertEqual(p.returncode, 1)

    def test_live_endpoint_is_reported_not_used(self):
        live = os.path.join(self.tmp, "live.sh")
        with open(live, "w") as fh:
            fh.write('export ALPACA_BASE_URL="https://api.alpaca.markets"\n')
        p = self.run_cli("status", cfg=live)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(json.loads(p.stdout)["endpoint_mode"], "LIVE")

    def test_agent_settings_in_config_file_reach_the_cli(self):
        # AGENT_CACHE_DIR set in config.sh must be the dir the Python writer
        # uses, like lib/agent_adapter.sh (the scan sources config.sh too)
        cfg_cache = os.path.join(self.tmp, "cfg_cache")
        with open(self.cfg_file, "a") as fh:
            fh.write('export AGENT_CACHE_DIR="%s"\nexport LLM_PROVIDER="fake"\n' % cfg_cache)
        p = self.run_cli("status")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        out = json.loads(p.stdout)
        self.assertEqual(out["cache_dir"], cfg_cache)
        self.assertEqual(out["llm_provider"], "fake")

    def test_template_settings_match_the_config_template(self):
        from agents.config import TEMPLATE_SETTINGS
        import re as _re

        with open(os.path.join(PROJECT_DIR, "config.template.sh")) as fh:
            names = set(_re.findall(r"^export ((?:AGENTS?|LLM)_[A-Z_]+)=", fh.read(), _re.M))
        self.assertEqual(set(TEMPLATE_SETTINGS), names)


if __name__ == "__main__":
    sys.exit(run_tests(sys.modules[__name__]))
