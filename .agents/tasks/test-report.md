# StockSwingTrader v6.3 - Test Report

**Generated:** 2026-11-01 03:29:31  
**Command:** `bash tests/test_runner.sh`  
**Result:** ✅ All suites passed

## Summary

| Metric | Value |
|--------|-------|
| Suites | 26 (26 passed, 0 failed, 0 skipped) |
| Total Tests | 1582 |
| Tests Passed | **1582** |
| Tests Failed | **0** |
| Success Rate | 100% |

## Results by Suite

| Suite | Status | Time | Details |
|-------|--------|------|---------|
| ML Predictor | ✅ PASS | 26469ms | 29 passed, 0 failed |
| Regime Weighting | ✅ PASS | 44208ms | 30 passed, 0 failed |
| Kalman Filter | ✅ PASS | 4602ms | 18 passed, 0 failed |
| Backtest | ✅ PASS | 7744ms | 34 passed, 0 failed |
| ML Scoring Integration | ✅ PASS | 36816ms | 29 passed, 0 failed |
| Regime Detector | ✅ PASS | 42085ms | 20 passed, 0 failed |
| Scoring Integration (Python) | ✅ PASS | 100ms | 32 passed, 0 failed |
| Dashboard Components | ✅ PASS | 2041ms | 27 passed, 0 failed |
| Backend API | ✅ PASS | 754ms | 17 passed, 0 failed |
| Kelly Sizing & Risk Budget | ✅ PASS | 7666ms | 51 passed, 0 failed |
| Sentiment (deterministic) | ✅ PASS | 4172ms | 36 passed, 0 failed |
| MiroFish Cache Adapter | ✅ PASS | 13318ms | 42 passed, 0 failed |
| Phase 1 Integration (CLI) | ✅ PASS | 203138ms | 38 passed, 0 failed |
| No Silent Fake Data | ✅ PASS | 114961ms | 71 passed, 0 failed |
| Broker Commands (stubbed) | ✅ PASS | 77473ms | 137 passed, 0 failed |
| V2 CLI Scoring | ✅ PASS | 150932ms | 81 passed, 0 failed |
| Order Execution (stubbed) | ✅ PASS | 42890ms | 81 passed, 0 failed |
| Live Safety (stubbed) | ✅ PASS | 197093ms | 188 passed, 0 failed |
| Agents: Contract | ✅ PASS | 5547ms | 26 passed, 0 failed |
| Agents: Data Clients | ✅ PASS | 8957ms | 20 passed, 0 failed |
| Agent Adapter (bash) | ✅ PASS | 12072ms | 83 passed, 0 failed |
| Scoring + Agents (zero-weight identity) | ✅ PASS | 215543ms | 90 passed, 0 failed |
| Agents: Technical | ✅ PASS | 8336ms | 21 passed, 0 failed |
| Agents: Parity vs bash | ✅ PASS | 135288ms | 322 passed, 0 failed |
| Agents: Validation | ✅ PASS | 25212ms | 36 passed, 0 failed |
| Agents: CLI (offline) | ✅ PASS | 53744ms | 23 passed, 0 failed |

Counts are taken from each suite's own summary output. A suite passes only
when it exits 0 with at least one passed test and zero failures.

## Suites

| Suite | File | Runner | Exercises |
|-------|------|--------|-----------|
| ML Predictor | tests/test_ml_predictor.sh | bash | lib/ml_inference.py with the trained XGBoost model, lib/ml_predictor.sh |
| Regime Weighting | tests/test_regime_weighting.sh | bash | lib/regime_weighting.sh (weights, multipliers, recommendations) |
| Kalman Filter | tests/test_kalman_filter.sh | bash | lib/kalman_filter.sh + lib/kalman_inference.py |
| Backtest | tests/test_backtest.sh | bash | lib/backtest.sh + lib/backtest_engine.py end to end (JSON/CSV/HTML) |
| ML Scoring Integration | tests/test_ml_scoring_integration.sh | bash | lib/scoring.sh calculate_confluence_score_v2 with the real ML predictor |
| Regime Detector | tests/test_regime_detector.sh | bash | lib/regime_detector.sh (trend, ADX, BB width, cache, batch) |
| Scoring Integration (Python) | tests/test_scoring_integration.py | python3 | Confluence weighting formula and signal thresholds |
| Dashboard Components | tests/test_dashboard.js | node --test | frontend/src utils, usePolling hook, all App routes, tsc --noEmit |
| Backend API | tests/test_backend.js | node --test | backend/server.js routes on an ephemeral port |
| Kelly Sizing & Risk Budget | tests/test_kelly_sizing.sh | bash | lib/kelly_sizing.sh (fractional Kelly, caps, daily risk budget ledger), risk_management/strategy wiring |
| Sentiment (deterministic) | tests/test_sentiment.sh | bash | lib/sentiment.sh (news keyword classifier, unavailable sources, local Finnhub stub), legacy sentiment sentinel |
| MiroFish Cache Adapter | tests/test_mirofish_adapter.sh | bash | lib/mirofish_adapter.sh cache statuses, legacy and v2 blending, no network calls |
| Phase 1 Integration (CLI) | tests/test_phase1_integration.sh | bash | StockSwingTrader_Agent.sh --kelly/--mirofish/--phase1, help, --backtest syntax, MiroFish-enabled timing |
| No Silent Fake Data | tests/test_no_fake_data.sh | bash | data_source rules with yfinance stubs (no data, error, fixture) |
| Broker Commands (stubbed) | tests/test_broker_commands.sh | bash | --check-account/--view-positions/--buy/--sell and deprecated aliases against a local Alpaca stub, Robinhood with stub functions, confirmation yes/no, invalid input, --ml/--kalman loading, libs keep SCRIPT_DIR |
| Agents: Contract | tests/test_agents_contract.py | .venv-agents python (SKIP without venv) | agents/ envelope schema + rules, atomic cache writes, path guards, config masking, config.sh agent settings reach the CLI, assert_paper, LLM providers + $0 budget, CLI exit codes |
| Agents: Data Clients | tests/test_agents_data.py | .venv-agents python (SKIP without venv) | agents/data Alpaca bars client against a 127.0.0.1 stub (pagination, GET only, host whitelist, sip->iex, retry, stale, timeout, cache), offline fixtures, yfinance fallback off |
| Agent Adapter (bash) | tests/test_agent_adapter.sh | bash | lib/agent_adapter.sh statuses, gates, latest dir, ttl, weight clamp/cap, components reasons, no network |
| Scoring + Agents (zero-weight identity) | tests/test_scoring_agents.sh | bash | v2 goldens captured at 970af57 unchanged (agents off, and on with weights 0), applied weight math, gate/staleness reasons, sentiment ordering, Technical Agent scan hook (regime_adx) |
| Agents: Technical | tests/test_agents_technical.py | .venv-agents python (SKIP without venv) | TA-Lib features (ranges, ADX14), regime_adx rule table, trend_state, envelopes (synthetic, < 60 bars unavailable), technical run/status CLI exit codes |
| Agents: Parity vs bash | tests/test_agents_parity.sh | bash + .venv-agents python (SKIP without venv) | TA-Lib vs bash indicator tolerances, bash_compat port exact vs bash (indicators, 40 score_* edge inputs), v2 port vs 65 stored bash windows, 3 live bash recomputes |
| Agents: Validation | tests/test_agents_validate.py | .venv-agents python (SKIP without venv) | stats (Sharpe, DSR, PSR, PBO/CSCV), walk-forward folds, vectorbt gate engine (next-open fills, ATR stop, TP), legacy parity vs lib/backtest_engine.py, gate criteria + schema, report HTML, trial log, v2 replay vs bash_compat |
| Agents: CLI (offline) | tests/test_agents_cli.sh | bash + .venv-agents python (SKIP without venv) | validate gate --offline (4 synthetic gate files, report), agent_gate_get contract, missing data exit 2, validate parity --offline, technical run exit 2, validate status, no network |

## Environment

- **OS:** Darwin 25.6.0 (arm64)
- **Bash:** GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)
- **Python:** Python 3.13.12
- **Node:** v25.6.1
- **Offline mode:** SST_OFFLINE=1 (synthetic/seeded data, no network)
- **Agent venv:** /Users/P3291917/Builds/6/StockSwingTrader-v6.3/.venv-agents (Python 3.12.12)
