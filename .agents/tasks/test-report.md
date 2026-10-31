# StockSwingTrader v6.3 - Test Report

**Generated:** 2026-10-31 01:30:35  
**Command:** `bash tests/test_runner.sh`  
**Result:** ✅ All suites passed

## Summary

| Metric | Value |
|--------|-------|
| Suites | 13 (13 passed, 0 failed) |
| Total Tests | 390 |
| Tests Passed | **390** |
| Tests Failed | **0** |
| Success Rate | 100% |

## Results by Suite

| Suite | Status | Time | Details |
|-------|--------|------|---------|
| ML Predictor | ✅ PASS | 26183ms | 29 passed, 0 failed |
| Regime Weighting | ✅ PASS | 32385ms | 30 passed, 0 failed |
| Kalman Filter | ✅ PASS | 3417ms | 18 passed, 0 failed |
| Backtest | ✅ PASS | 8359ms | 34 passed, 0 failed |
| ML Scoring Integration | ✅ PASS | 33964ms | 29 passed, 0 failed |
| Regime Detector | ✅ PASS | 32152ms | 20 passed, 0 failed |
| Scoring Integration (Python) | ✅ PASS | 106ms | 32 passed, 0 failed |
| Dashboard Components | ✅ PASS | 1925ms | 21 passed, 0 failed |
| Backend API | ✅ PASS | 722ms | 16 passed, 0 failed |
| Kelly Sizing & Risk Budget | ✅ PASS | 6594ms | 51 passed, 0 failed |
| Sentiment (deterministic) | ✅ PASS | 4341ms | 36 passed, 0 failed |
| MiroFish Cache Adapter | ✅ PASS | 14054ms | 42 passed, 0 failed |
| Phase 1 Integration (CLI) | ✅ PASS | 127931ms | 32 passed, 0 failed |

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

## Environment

- **OS:** Darwin 25.6.0 (arm64)
- **Bash:** GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)
- **Python:** Python 3.13.12
- **Node:** v25.6.1
- **Offline mode:** SST_OFFLINE=1 (synthetic/seeded data, no network)
