# StockSwingTrader v6.3 Steering Guide
## Code-Verified Reference for AI-Assisted Development

**Version:** 6.3 (`VERSION="6.3"` in `StockSwingTrader_Agent.sh`; the separate `VERSION` file still says v6.2)  
**Last Updated:** 2026-10-31 (live-safety Step 1)  
**Verified against:** commit `5a7abc0` on `main` (live-safety Step 1: v2 scoring in the CLI, Alpaca limit/bracket orders, order safety). Earlier sections were verified at `532828e` and re-checked where Step 1 changed them: [Current State](#current-state-at-a-glance), [Data Sources](#data-sources--synthetic-data), [Data Flow](#data-flow--pipeline), [Execution Safety](#execution-safety-step-1), [Main Agent Flags](#main-agent-flags), [Setup & Configuration](#setup--configuration), [Testing](#testing)  
**Purpose:** Accurate guide for future AI agents to understand, enhance, and maintain the codebase. Every command, function, path, port, weight and threshold below was checked against the code. Where the code does not do something, this guide says so.

> Not financial advice. The ML model is trained on synthetic data (every prediction says `"model_training_data": "synthetic"`). Synthetic prices/features are used only on explicit opt-in (`SST_OFFLINE=1`, `SST_ALLOW_SYNTHETIC=1`, `--synthetic`) and are then marked `"data_source": "synthetic"`. Paper-trade only: the order safety checks of Step 1 reduce risk but are not a reason to trade real money; `config.sh` must stay on `paper-api.alpaca.markets`.

---

## Table of Contents
1. [Current State at a Glance](#current-state-at-a-glance)
   - [Data Sources & Synthetic Data](#data-sources--synthetic-data)
2. [Architecture Overview](#architecture-overview)
3. [Module Structure](#module-structure)
4. [Data Flow & Pipeline](#data-flow--pipeline)
5. [Enhancement Modules](#enhancement-modules)
6. [Execution Safety (Step 1)](#execution-safety-step-1)
7. [Scoring Pipeline Integration](#scoring-pipeline-integration)
8. [Main Agent Flags](#main-agent-flags)
9. [Setup & Configuration](#setup--configuration)
10. [Development Guidelines](#development-guidelines)
11. [Testing](#testing)
12. [Troubleshooting](#troubleshooting)
13. [Future Enhancement Ideas](#future-enhancement-ideas)
14. [Deployment & Versioning](#deployment--versioning)
15. [Appendix: File Reference](#appendix-file-reference)

---

## Current State at a Glance

Since live-safety Step 1 (`4c621fb`, `daf1bca`, `5a7abc0`) the CLI scores with `calculate_confluence_score_v2` by default (ML, regime, Kalman and a real OBV score are part of every `--symbols` run; `--legacy-score` keeps the old formula), and `--buy`/`--sell` go through the pre-trade checks in [Execution Safety](#execution-safety-step-1) and send a limit order with a bracket stop loss / take profit by default. `--regime-adapt` and `--dashboard` still do nothing (issue 2). Known issues, first observed at `532828e` and updated for Step 1:

1. *(Fixed.)* **Path bug.** `lib/scoring.sh`, `lib/ml_predictor.sh`, `lib/backtest.sh` and `lib/robinhood_broker.sh` used to set `SCRIPT_DIR` to `lib/` when sourced, so the agent's `$SCRIPT_DIR/lib/...` lookups became `lib/lib/...`. Each lib now uses its own dir variable (`SCORING_LIB_DIR`, `ML_PREDICTOR_DIR`, `BACKTEST_LIB_DIR`, `ROBINHOOD_LIB_DIR`) and the agent resolves every project path through `AGENT_DIR` (`SCRIPT_DIR` stays an alias of it). `lib/alpaca_broker.sh` no longer turns on `errexit` in the caller. Now working:
   - HTML report, `--backtest`, `--ml` and `--kalman` (the last two load their module; CLI scoring still ignores them, issue 3).
   - Broker flags `--check-account`, `--view-positions`, `--buy`, `--sell` and the deprecated `--alpaca`, `--alpaca-status`, `--place-buy`, `--place-sell` (see [Main Agent Flags](#main-agent-flags)). Use Alpaca **paper** trading only (`ALPACA_BASE_URL=https://paper-api.alpaca.markets`). `--buy`/`--sell` validate the symbol (1–5 uppercase letters) and quantity (> 0) before contacting the broker, run the safety checks, price the order from Alpaca's latest trade (`alpaca_get_quote`, falls back to Yahoo) and send nothing unless you type exactly `yes` (on a LIVE endpoint: `--live` and the typed `SYMBOL QTY`).
   - Robinhood (`--broker robinhood`) loads, but is only tested with stub functions. It needs `ROBINHOOD_CLIENT_ID`/`ROBINHOOD_CLIENT_SECRET` in the environment or `config.sh` (`config.robinhood.sh` is not sourced), and its first-run OAuth wait uses `timeout`, which macOS lacks. It trades real money, so the agent always treats it as LIVE (orders need `--live` + typed confirmation; market orders only; no clock, reconciliation, loss-halt or PDT checks). Not verified against Robinhood.
2. **Missing modules.** `--regime-adapt` looks for `lib/regime_adaptive.sh` and `--dashboard` looks for `lib/dashboard.sh`. Neither exists. The real regime modules are `lib/regime_detector.sh` and `lib/regime_weighting.sh`; there is no dashboard launcher.
3. *(Fixed in Step 1.)* **Scoring not wired in.** The CLI now uses `calculate_confluence_score_v2` (15/35/30/20, optional sentiment) by default, with mean-reversion, trend-following, Kalman trend, regime and OBV inputs computed from the fetched bars (`build_v2_inputs`). `SCORING_MODE=legacy` or `--legacy-score` selects the old `calculate_confluence_score` (80% technical average, 20% sentiment). The OBV score is real in both modes (it was a constant 50). Remaining gaps: the ML predictor still fetches its own bars via yfinance (not the CLI's bars), and the SMA200 term is always 0 because the CLI fetches 60 bars.
4. *(Fixed.)* **Demo data.** `fetch_stock_ohlcv` now fetches 60 daily bars from yfinance (`"data_source":"yfinance"`). The random demo series is generated only on the synthetic opt-in and is marked `"data_source":"synthetic"`. Without data and without the opt-in the symbol is skipped; with 0 symbols analyzed the CLI exits 1 and writes no report (it used to count log lines as an analysis and print "Analysis Complete!").
5. **Wrong help example.** `--backtest AAPL 2022-01-01 2024-01-01` (in `--help` and the script header) is rejected: `Unknown option: 2022-01-01`, exit 1. Dates go in `--start` / `--end`.
6. **bash 3.2.** `--watchlist` uses `mapfile` (bash 4+). macOS `/bin/bash` 3.2 prints `mapfile: command not found` and analyzes 0 stocks.
7. **Backend gaps.** `/api/signals`, `/api/quotes`, `/api/indicators`, `/api/stats` and `/api/portfolio` call lib scripts with sub-commands those scripts do not implement, so they return HTTP 200 with `{"raw": ""}`. Dashboard score and price panels stay empty.
8. **Machine-specific paths.** Backtest output, backend log and ML training report default to `/Users/P3291917/Builds/6/.agents/tasks/...`. Override with `BACKTEST_OUTPUT_DIR` and `SST_LOG_FILE` (the training report path has no override).
9. **ML batch.** `ml_predictor.sh batch '["AAPL", "MSFT"]' 5` returns only the first symbol.
10. **Step 1 side effects and gaps.** `alpaca_init` prints `(Paper Trading)` even on a live endpoint (the `Mode: PAPER|LOCAL STUB|LIVE` line printed by the agent is the reliable one). Sourcing `lib/order_safety.sh` loads `risk_management.sh` → `trade_journal.sh`, which creates `logs/trades.json` in the current directory on every agent start (gitignored; the CLI does not write trades to it). Before a sell, open bracket legs that hold the shares are only warned about, not cancelled.

### Data Sources & Synthetic Data

Synthetic (generated) data never drives a prediction, score or backtest silently.

| Opt-in | Effect |
|---|---|
| `SST_OFFLINE=1` | No network; seeded synthetic data everywhere (test runner, demos) |
| `SST_ALLOW_SYNTHETIC=1` | Real data first, synthetic fallback when real data is unavailable |
| `ml_inference.py --synthetic` | Same as `SST_ALLOW_SYNTHETIC=1` for one ML call |
| backtest config `"allow_synthetic": true` | Same for one `backtest_engine.py` run |

| Module | Real data | No real data, no opt-in | Synthetic (opt-in) marker |
|---|---|---|---|
| `lib/ml_inference.py`, `ml_predictor.sh predict` | `data_source` `yfinance` / `file` / `stdin` | exit 0, `{"available": false, "reason", "data_source": null}`, no direction/confidence | `data_source: "synthetic"` + `warning` |
| `calculate_confluence_score_v2` | `components.ml_confidence.data_source` | ML `score: null`, `weight_percent: 0`, `available: false`; others renormalized to 41.2 / 35.3 / 23.5 (× (1 − w) with MiroFish); `metadata.ml_available: false` | `ml_confidence.data_source: "synthetic"`, `metadata.data_warning` |
| `lib/backtest_engine.py` | results `data_source: "yfinance"` | exit 2, stdout `{"error": "market_data_unavailable", "reason", ...}`, no files; `backtest_strategy` / `backtest_multi_symbol` / `--backtest` non-zero | `data_source: "synthetic"` + `warning`; HTML banner; portfolio summary `data_sources` + `warning` |
| `detect_market_regime SYMBOL [LOOKBACK] [CLOSES...]` | ≥ 20 closes passed: `data_source: "caller"` | `{"regime": "unknown", "available": false}` | demo 30-price series, `data_source: "synthetic"` + `warning`; cached synthetic results are not reused without the opt-in |
| `get_kalman_filtered_prices` | (none; pass prices to `apply_kalman_filter`) | `{"available": false}`, exit 1 | `data_source: "synthetic"` + `warning` |
| Agent `fetch_stock_ohlcv` / `score_stock` | `data_source: "yfinance"`; OBV score, MR/TF scores, Kalman trend and regime (`data_source: "caller"`) are computed from these bars (`.v2_inputs`) | symbol skipped; CLI exits 1 if none analyzed | `data_source: "synthetic"`, `data_warning` (price data only; the ML synthetic warning is in `.confluence_v2.metadata.data_warning`); HTML report banner |
| v2 sentiment (10th arg of `calculate_confluence_score_v2`) | news sentiment from `aggregate_sentiment`: `components.sentiment {score, available: true, weight_percent}`, final = core × (1 − w) + sentiment × w, w = `V2_SENTIMENT_WEIGHT` (0.10) | `{score: null, available: false, weight_percent: 0}`, score unchanged | — (no synthetic sentiment) |
| Order bracket levels (`order_bracket_levels`) | ATR + regime from real yfinance bars (`method: "atr+regime"`) | percent stop `STOP_LOSS_PERCENT` (`method: "percent"`) | synthetic bars are never used: percent method |
| Backend `/api/backtest` | each result has `data_source`, `synthetic` (`unknown` for files without the field) | — | `synthetic: true` |
| Dashboard | — | Analysis: "ML prediction unavailable … zero weight" | alert + "synthetic" badge (Dashboard, Analysis); Trade History labels each backtest `Data: …` and warns on `synthetic` / `unknown` |

Still not real data: the XGBoost model is trained on synthetic samples (`train_ml_model.py`). Fixed in Step 1: the OBV score in `score_stock` is no longer a constant 50; it is `score_obv_trend` over the last `OBV_LOOKBACK` (10) bars (all-up bars → 100, all-down → 0, flat → 50; fewer than N+1 points → 50 with `obv_available: false`). With no live quote, the Bollinger score uses the series' last close instead of price 0 (which always scored 100).

---

## Architecture Overview

### System Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                   StockSwingTrader v6.3                         │
│              Swing Trading Analysis (demo/paper)                │
└─────────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
    ┌───▼────┐          ┌────▼─────┐         ┌────▼────┐
    │  Data  │          │ Analysis │         │ Output  │
    │ (demo/ │          │ Modules  │         │ Modules │
    │yfinance│          │ (lib/)   │         │         │
    └───┬────┘          └────┬─────┘         └────┬────┘
        │                    │                     │
    ┌───▼────────────────────▼─────────────────────▼────┐
    │  Scoring (lib/scoring.sh)                          │
    │  CLI default (v2): calculate_confluence_score_v2   │
    │    15% ML + 35% regime + 30% technical             │
    │    + 20% volume/trend (+ sentiment 10% if any)     │
    │  --legacy-score: calculate_confluence_score        │
    │    80% technical avg + 20% sentiment               │
    └───┬──────────────────────────────────────────────┬─┘
        │  --buy / --sell                              │
    ┌───▼──────────────────────────┐                   │
    │ Order safety                 │                   │
    │ (lib/order_safety.sh,        │                   │
    │  lib/alerts.sh) → broker     │                   │
    └───┬──────────────────────────┘                   │
        │                                              │
    ┌───▼──────────────────────┐            ┌─────────▼──────────┐
    │ Dashboard                │            │ Reports            │
    │ backend :3000 (Express)  │            │ HTML (html_report) │
    │ frontend :5173 (Vite)    │            │ Backtest JSON/HTML │
    └──────────────────────────┘            └────────────────────┘
```

### Module Dependency Graph (as sourced in code)

```
StockSwingTrader_Agent.sh (Main Orchestrator)
│
├── config.template.sh          (always sourced; then config.sh or SST_CONFIG_FILE if present)
├── lib/indicators.sh           RSI, MACD, Bollinger, ATR, OBV, Stochastic, Williams %R, SMA, EMA
├── lib/sentiment.sh            Twitter/Reddit/StockTwits placeholders (randomised)
├── lib/scoring.sh              Indicator scores + confluence (own dir var SCORING_LIB_DIR)
│   ├── lib/ml_predictor.sh  ── lib/ml_inference.py ── lib/models/xgboost_predictor.pkl
│   ├── lib/regime_weighting.sh
│   │   ├── lib/regime_detector.sh
│   │   │   ├── lib/indicators.sh
│   │   │   ├── lib/trading_thresholds.sh
│   │   │   └── lib/kalman_filter.sh
│   │   └── lib/trading_thresholds.sh
│   └── lib/kalman_filter.sh ── lib/kalman_inference.py
├── lib/html_report.sh          generate_html_report (+ Score Breakdown section)
├── lib/kelly_sizing.sh         --kelly / --phase1
├── lib/order_safety.sh         pre-trade checks (own dir var ORDER_SAFETY_LIB_DIR; sourced at
│   │                           startup, BEFORE load_broker_module)
│   ├── lib/alerts.sh           send_alert (own dir var ALERTS_LIB_DIR)
│   └── lib/risk_management.sh  (only if enforce_daily_drawdown_limit is undefined)
│       ├── lib/trading_thresholds.sh, lib/trade_journal.sh, lib/kelly_sizing.sh
│       └── lib/alpaca_wrappers.sh ── lib/alpaca_broker.sh (only if alpaca_submit_order is undefined)
├── lib/backtest.sh  ── lib/backtest_engine.py      (--backtest)
├── lib/alpaca_broker.sh | lib/robinhood_broker.sh   (--broker; loaded after arg parsing;
│                                                     re-sourcing alpaca_broker.sh resets ALPACA_INITIALIZED)
│
│ Not sourced by the agent:
├── lib/strategy_mean_reversion.sh, lib/strategy_trend_follow.sh   (v2 uses graded copies of their
│   │                                                              criteria in lib/scoring.sh instead)
│   └── lib/trading_thresholds.sh, risk_management.sh, trade_journal.sh, alpaca_wrappers.sh
├── lib/train_ml_model.py       (run manually)
└── backend/server.js + frontend/  (started manually with npm)
```

---

## Module Structure

### Core Modules (function names verified with `grep '^name()'`)

| Module | File | Language | Key Functions / Entry Points |
|--------|------|----------|------------------------------|
| Main Agent | `StockSwingTrader_Agent.sh` | Bash | `main`, `usage`, `display_version`, `analyze_stock`, `fetch_stock_ohlcv`, `calculate_all_indicators`, `score_stock`, `generate_report`, `print_score_breakdown`, `init_ml_predictor`, `init_regime_adaptive`, `init_kalman_filter`, `init_dashboard`, `init_all_enhancements`, `load_broker_module`, `broker_connect`, `show_broker_account`, `show_broker_positions`, `validate_order_args`, `get_order_price`, `current_endpoint_mode` (sets `SST_ENDPOINT_MODE`; call without `$(...)`), `check_live_config_guard`, `order_prechecks`, `place_guarded_order`, `place_buy_order` / `place_sell_order` (thin wrappers), `startup_reconcile_warning`, `run_reconcile_command` |
| Order Safety | `lib/order_safety.sh` | Bash | `sst_state_dir`, `kill_switch_file`, `kill_switch_active`, `kill_switch_engage`, `kill_switch_release`, `broker_endpoint_mode`, `endpoint_mode_label`, `config_file_is_tracked`, `order_ledger_file`, `order_ledger_append`, `order_ledger_update`, `order_ledger_entries`, `generate_client_order_id`, `order_lock_acquire`, `order_lock_release`, `check_order_qty_cap`, `daily_buy_notional_used`, `check_order_caps`, `daily_loss_limit_pct`, `check_daily_loss_halt`, `check_duplicate_order`, `reconcile_baseline_file`, `reconcile_compute`, `reconcile_with_broker`, `reconcile_accept`, `check_market_hours`, `check_pdt_warning`, `compute_limit_price`, `order_bracket_levels_from`, `order_bracket_levels`, `safety_status_report` |
| Alerts | `lib/alerts.sh` | Bash | `send_alert LEVEL EVENT MESSAGE [DETAILS_JSON]` (always returns 0), `alert_log_file`, `alert_channels_summary` |
| Indicators | `lib/indicators.sh` | Bash | `calc_rsi`, `calc_macd`, `calc_bollinger_bands`, `calc_atr`, `calc_obv`, `calc_stochastic`, `calc_williams_r`, `calc_sma`, `calc_ema` |
| Extra indicators | `lib/indicators_new.sh` | Bash | `calc_rsi_divergence`, `calc_vwma`, `calc_momentum`, `calc_all_new_indicators` |
| Kalman Filter | `lib/kalman_filter.sh` | Bash | `apply_kalman_filter`, `apply_kalman_filter_fast`, `calc_residual_volatility`, `get_kalman_filtered_prices` |
| Kalman Inference | `lib/kalman_inference.py` | Python | `KalmanFilter1D`, `calculate_volatility`, `calculate_smoothness_improvement`; CLI: `kalman_inference.py [q] [r]` with prices on stdin |
| Regime Detector | `lib/regime_detector.sh` | Bash | `detect_market_regime`, `detect_market_regime_kalman`, `detect_regimes_batch`, `calc_adx`, `calc_bb_width_pct`, `detect_trend_direction`, `clear_regime_cache` |
| Regime Weighting | `lib/regime_weighting.sh` | Bash | `get_regime_weights`, `apply_regime_weights`, `apply_confidence_multiplier`, `apply_regime_weights_batch`, `select_best_strategy`, `calculate_adjusted_stop_loss`, `detect_regime_change` |
| ML Predictor | `lib/ml_predictor.sh` | Bash | `ml_predict_direction`, `ml_get_model_status`, `ml_batch_predict`; CLI: `predict`, `status`, `batch` |
| ML Inference | `lib/ml_inference.py` | Python | `predict`, `unavailable_result`, `synthetic_allowed`, `extract_features_from_data`, `generate_synthetic_features_for_symbol` (opt-in only), `fetch_current_data`; CLI: `--symbol`, `--period`, `--data-file`, `--synthetic` |
| ML Training | `lib/train_ml_model.py` | Python | `main`, `train_model`, `generate_synthetic_features`, `generate_report` (no CLI options) |
| Mean Reversion | `lib/strategy_mean_reversion.sh` | Bash | `mean_reversion_analyze`, `mean_reversion_exit_check`, `mean_reversion_enter`, `mean_reversion_exit`, `mean_reversion_scan`, `mean_reversion_stats` |
| Trend Following | `lib/strategy_trend_follow.sh` | Bash | `trend_follow_analyze`, `trend_follow_exit_check`, `trend_follow_enter`, `trend_follow_exit`, `trend_follow_scan`, `trend_follow_stats` |
| Thresholds | `lib/trading_thresholds.sh` | Bash | Exported constants (`MR_*`, `TF_*`, `RSI_*`, `MACD_*`, ...) |
| Scoring | `lib/scoring.sh` | Bash | `score_rsi`, `score_macd`, `score_bollinger_bands`, `score_stochastic`, `score_williams_r`, `score_obv` (kept, unused by the CLI), `score_obv_trend`, `score_mean_reversion_setup`, `score_trend_follow_setup`, `kalman_trend_from_closes`, `build_v2_inputs`, `calculate_confluence_score`, `apply_mirofish_to_confluence`, `calculate_confluence_score_v2` (optional 10th arg: sentiment), `calc_stop_loss_atr`, `calc_stop_loss_percent`, `calc_take_profit`, `calc_risk_reward_ratio`, `generate_score_summary` |
| Sentiment | `lib/sentiment.sh` | Bash | `parse_twitter_sentiment`, `parse_reddit_sentiment`, `parse_stocktwits_sentiment`, `analyze_news_sentiment`, `aggregate_sentiment`, `sentiment_to_confidence` |
| Risk Management | `lib/risk_management.sh` | Bash | `calculate_position_size`, `calculate_position_qty`, `enforce_stop_loss`, `enforce_take_profit`, `check_max_positions`, `enforce_daily_drawdown_limit`, `monitor_all_positions`, `rebalance_check` |
| Trade Journal | `lib/trade_journal.sh` | Bash | `log_trade_entry`, `close_trade`, `query_trade_journal`, `show_journal`, `export_backtest_data`, `get_strategy_stats` |
| Backtesting | `lib/backtest.sh` | Bash | `backtest_strategy`, `backtest_multi_symbol`, `run_backtest_engine`, `generate_backtest_reports`, `generate_portfolio_summary` (library only, no CLI) |
| Backtest Engine | `lib/backtest_engine.py` | Python | `DataFetcher`, `Indicators`, `MeanReversionStrategy`, `TrendFollowStrategy`, `BacktestEngine`; CLI: `backtest_engine.py CONFIG_JSON` |
| Alpaca Broker | `lib/alpaca_broker.sh` | Bash | `alpaca_init`, `alpaca_get_account` (adds `last_equity`, `pattern_day_trader`, `daytrade_count`; `account_id` masked to `****` + last 4), `alpaca_get_positions` (JSON array), `alpaca_place_order SYM QTY SIDE [TYPE] [LIMIT] [CID] [TIF]` (3-arg call unchanged: market/day), `alpaca_place_bracket_order SYM QTY SIDE LIMIT STOP TP [CID] [TYPE=limit] [TIF=gtc]`, `alpaca_build_order_payload`, `alpaca_submit_order PAYLOAD`, `alpaca_round_price`, `alpaca_validate_client_order_id`, `alpaca_get_open_orders [SYM]`, `alpaca_get_orders_since ISO_TS`, `alpaca_get_order_by_client_id ID`, `alpaca_get_clock`, `alpaca_get_calendar START END`, `alpaca_get_quote` (latest trade, `last_price`), `alpaca_get_order_status`, `alpaca_cancel_order` |
| Alpaca wrappers | `lib/alpaca_wrappers.sh` | Bash | `alpaca_place_stop_loss`, `alpaca_place_take_profit` (on top of `alpaca_build_order_payload` + `alpaca_submit_order`), `alpaca_get_current_price` (reads `.last_price`). Step 1 removed the definitions that shadowed broker functions (recursive `alpaca_get_positions`, broken `alpaca_place_order`, fake `alpaca_place_bracket_order`, `alpaca_get_order_status`, `alpaca_cancel_order`). `alpaca_get_position_qty`/`avg_price` read `.qty`/`.avg_fill_price`, which broker positions do not have (they return 0; read `alpaca_get_positions` `.quantity` instead) |
| Robinhood Broker | `lib/robinhood_broker.sh` (+ `robinhood_oauth.sh`, `robinhood_mcp_direct.sh`) | Bash | `robinhood_init`, `robinhood_get_account`, `robinhood_get_positions`, `robinhood_place_order`, `robinhood_get_quote` |
| Reports | `lib/html_report.sh` | Bash | `generate_html_report JSON OUTPUT_FILE` (fills the `SCORE_BREAKDOWN_SECTION` placeholder last with `_html_fill_score_breakdown`: `div#score-breakdown` table, strings escaped with jq `@html`) |
| Backend API | `backend/server.js` | Node.js/Express | `/api/health`, `/api/portfolio`, `/api/quotes/:symbol`, `/api/signals/:symbol`, `/api/indicators/:symbol`, `/api/trades`, `/api/stats`, `GET`/`POST /api/settings`, `/api/backtest` |
| Frontend UI | `frontend/src/` | React + TypeScript | Pages: `Dashboard`, `Analysis`, `TradeHistory`, `Watchlist`, `Settings`, `NotFound` |

---

## Data Flow & Pipeline

### What the CLI runs (`--symbols`)

```
Input: --symbols AAPL,MSFT  (or --top-10, --watchlist FILE, or DEFAULT_WATCHLIST)
   │
   ├─▶ fetch_stock_ohlcv       60 daily bars from yfinance (data_source "yfinance");
   │                           random demo bars only on the synthetic opt-in
   │                           (data_source "synthetic"); otherwise skip symbol
   ├─▶ calculate_all_indicators
   │     needs ≥ 30 closes; RSI(14), MACD, Bollinger(20,2), Stochastic(14),
   │     Williams %R(14), ATR(14), OBV
   │     + .v2_inputs = build_v2_inputs (same bars, no extra network):
   │       obv_score (score_obv_trend, OBV_LOOKBACK 10), mr_score, tf_score,
   │       kalman_trend (5-bar slope of apply_kalman_filter_fast vs
   │       KALMAN_TREND_THRESHOLD_PCT 0.5), regime (detect_market_regime on the
   │       closes, data_source "caller"), ema_12/26, sma_50, sma_200 (null: < 200 bars)
   ├─▶ score_stock
   │     score_rsi / score_macd / score_bollinger_bands / score_stochastic /
   │     score_williams_r ; OBV = .v2_inputs.obv_score ; aggregate_sentiment
   │     (news or null); fetch_current_price (Yahoo quoteSummary via curl, for
   │     Bollinger; falls back to the series' last close)
   │     SCORING_MODE=v2 (default):
   │       calculate_confluence_score_v2 SYMBOL RSI MACD BB OBV REGIME MR TF
   │         KALMAN SENTIMENT   (MiroFish applied inside v2, once)
   │       .confluence = {model:"v2", final_confidence, signal, reasoning,
   │         sentiment_available, sentiment_contribution, [mirofish]}
   │       .confluence_v2 = full v2 JSON
   │     SCORING_MODE=legacy / --legacy-score:
   │       calculate_confluence_score (mean of 6 scores × 0.8 + sentiment × 0.2)
   │       + apply_mirofish_to_confluence (unchanged shape)
   │     output: ONE compact JSON line {symbol, data_source, data_warning,
   │       scoring_model, scores, confluence, [confluence_v2], v2_inputs,
   │       v2_inputs_available, indicators, [position_sizing]}
   ├─▶ Kelly (--kelly): .confluence.final_confidence + v2 regime
   ├─▶ sleep 0.5 between symbols
   ├─▶ print_score_breakdown   "SCORE BREAKDOWN (v2: ...)" block on stdout
   └─▶ generate_report → swing_analysis_<ts>.json (array of analyses) +
         swing_analysis_<ts>.html (Score Breakdown table; SYNTHETIC DATA banner
         when any analysis has data_source "synthetic")
```

Example (`SST_OFFLINE=1 ./StockSwingTrader_Agent.sh --symbols AAPL --output-dir /tmp/sst_report_check`, synthetic data, exit 0):

```
SCORE BREAKDOWN (v2: 15% ML + 35% regime-weighted MR/TF + 30% technical + 20% OBV/Kalman volume-trend; sentiment 0.10 when available)
AAPL  score 48 HOLD | ML 82 up (15%) | Regime 28 trending_bear (35%) | Technical 48 (30%) | Volume/Trend 57 (20%) | Sentiment n/a (0%) | OBV 65 | data synthetic
```

`--ml` and `--kalman` only load their modules; v2 scoring uses ML and Kalman whether or not they are given. `.data_warning` is about price data only; the ML synthetic warning stays in `.confluence_v2.metadata.data_warning`. When `.v2_inputs` is missing (hand-made indicator JSON), `score_stock` uses neutral 50 / 0 / `unknown` and sets `v2_inputs_available: false`.

**Graded MR/TF scores (D3).** `score_mean_reversion_setup`: `MR = clamp(round(50 + vol_mult × (rsi_term + bb_term) + macd_term), 0, 100)` with `rsi_term = clamp((50 − RSI)/20, −1, 1) × 25`, `bb_term = clamp((0.5 − bbfrac)/0.5, −1, 1) × 15` (bbfrac = position in the bands), `vol_mult = 1.2` when the last volume > 20-bar average, `macd_term = ±5` (0 when MACD == signal, which `calc_macd` always returns today). `score_trend_follow_setup`: `TF = clamp(round(50 + vol_mult × (ema_term ± 15 + sma50_term ± 15 + sma200_term ± 10)), 0, 100)` (terms 0 on equality or when the SMA is unavailable; `vol_mult` vs 30-bar average).

### Library pipeline (`calculate_confluence_score_v2`, used by tests/examples)

```
Inputs: symbol, rsi_score, macd_score, bb_score, obv_score, regime,
        [mr_score=50], [tf_score=50], [kalman_trend=-1|0|1, default 0],
        [sentiment = number | na | null | unavailable | ""]   (10th arg, Step 1)
   │
   ├─▶ ML (15%)         bash lib/ml_predictor.sh predict SYMBOL 5, killed after
   │                    ML_TIMEOUT_SECONDS (default 5); on error/timeout
   │                    confidence=50, direction=neutral, metadata.ml_error set;
   │                    {"available": false} (no market data): score null,
   │                    weight 0, other weights renormalized (35/85, 30/85, 20/85)
   ├─▶ Regime (35%)     sideways: 0.7·MR + 0.3·TF
   │                    trending_bull / trending_bear: 0.3·MR + 0.7·TF
   │                    volatile: (0.5·MR + 0.5·TF) × 0.8
   │                    other: 0.5·MR + 0.5·TF
   ├─▶ Technical (30%)  (rsi + macd + bb) / 3
   ├─▶ Volume/Trend (20%)
   │                    kalman_trend=1:  0.8·OBV + 0.2·75
   │                    kalman_trend=-1: 0.8·OBV + 0.2·25
   │                    kalman_trend=0:  OBV
   ├─▶ confluence = 0.15·ML + 0.35·Regime + 0.30·Technical + 0.20·VolumeTrend
   │                (ML unavailable: (35·Regime + 30·Technical + 20·VolumeTrend) / 85)
   ├─▶ MiroFish (when enabled and fresh): core × (1 − w) + mirofish × w
   ├─▶ Sentiment (only when the 10th arg is passed):
   │     numeric and V2_SENTIMENT_WEIGHT ws > 0: final = core × (1 − ws) + s × ws
   │       (core = unrounded score incl. MiroFish); every other weight_percent × (1 − ws);
   │       components.sentiment = {score, available: true, weight_percent}
   │     unavailable: components.sentiment = {score: null, available: false,
   │       weight_percent: 0}; score unchanged. Sentiment casts no vote.
   └─▶ recommendation (see Signal Classification)
```

Calls with ≤ 9 arguments produce exactly the pre-Step-1 output (no `sentiment` component). The library pipeline has no stop-loss/target output and no risk-management step. Stop/target helpers exist separately in `lib/scoring.sh` (`calc_stop_loss_atr`, default multiplier 2; `calc_stop_loss_percent`, default 5%; `calc_take_profit`, default 8%; `calc_risk_reward_ratio`).

### Signal Classification

**Legacy `calculate_confluence_score` (CLI with `--legacy-score` / `SCORING_MODE=legacy`):**

| Final confidence | Signal |
|---|---|
| ≥ 75 | `STRONG_BUY` |
| ≥ 60 | `BUY` |
| ≥ 40 | `HOLD` |
| ≥ 25 | `SELL` |
| < 25 | `STRONG_SELL` |

**`calculate_confluence_score_v2` (CLI default):** each component votes bullish or bearish. ML votes when confidence > 60 (direction up/down). Regime, technical and volume/trend vote bullish when > 60 and bearish when < 40. `signal_strength` = number of voting components (0–4).

- 3+ votes, ≥3 bullish and 0 bearish: `STRONG_BUY` if score > 70, `BUY` if > 55, otherwise `HOLD`.
- 3+ votes, ≥3 bearish and 0 bullish: `STRONG_SELL` if score < 30, `SELL` if < 45, otherwise `HOLD`.
- 3+ votes but mixed: `HOLD`.
- An unavailable ML component casts no vote.
- Fewer than 3 votes: `BUY` if > 60, `SELL` if < 40, otherwise `HOLD`.

The `CONFIDENCE_*` variables in `config.template.sh` are not read by either function (and `CONFIDENCE_STRONG_SELL=10` differs from the hard-coded 25).

### JSON Output: legacy `calculate_confluence_score`

```bash
source lib/scoring.sh
calculate_confluence_score 70 70 70 70 70 50 80
# {"final_confidence":69,"signal":"BUY","reasoning":"Most indicators bullish; good entry opportunity","technical_avg":66,"sentiment_contribution":80}
```

### JSON Output: `calculate_confluence_score_v2`

```bash
source lib/scoring.sh
calculate_confluence_score_v2 AAPL 65 70 55 60 trending_bull 60 72 1 </dev/null
```

```json
{
  "confluence_score": 68,
  "recommendation": "BUY",
  "signal_strength": 4,
  "components": {
    "ml_confidence":      { "score": 82, "direction": "up", "weight_percent": 15,
                            "available": true, "data_source": "synthetic" },
    "regime_score":       { "score": 68, "regime": "trending_bull", "weight_percent": 35 },
    "technical_score":    { "score": 63, "weight_percent": 30 },
    "volume_trend_score": { "score": 63, "weight_percent": 20 }
  },
  "breakdown": {
    "symbol": "AAPL",
    "individual_scores": {
      "rsi": 65, "macd": 70, "bollinger_bands": 55, "obv": 60,
      "mean_reversion": 60, "trend_following": 72, "kalman_trend": 1
    },
    "signal_counts": { "bullish_signals": 4, "bearish_signals": 0, "total_agreement": 4 }
  },
  "metadata": {
    "confidence_note": "Multiple bullish signals confirmed",
    "ml_error": "",
    "ml_available": true,
    "data_warning": "ML component used SYNTHETIC features (demo/test mode); not market data",
    "latency_ms": 0,
    "timestamp": "2026-10-31T06:15:00Z"
  }
}
```

(Output from an `SST_OFFLINE=1` run, hence `data_source: "synthetic"`. With real data `data_source` is `yfinance` and `data_warning` is empty. With no market data and no opt-in: `"ml_confidence": {"score": null, "direction": "unavailable", "weight_percent": 0, "available": false, "reason": "...", "data_source": null}`, regime/technical/volume weights 41.2/35.3/23.5, `confluence_score` 65 for these inputs and `metadata.ml_available: false`. `latency_ms` and `timestamp` vary. One ML prediction takes several seconds, so it can hit the 5 s default timeout; then `ml_confidence.score` is 50 and `metadata.ml_error` is `timeout_or_failure`. Raise `ML_TIMEOUT_SECONDS` if that happens.)

---

## Enhancement Modules

### Enhancement 1: XGBoost ML Predictor

**Purpose:** Binary up/down prediction for the next 5 periods. No accuracy improvement has been measured on real data; the model is trained on synthetic data.

**Files:**
- `lib/ml_predictor.sh`: Bash wrapper and CLI
- `lib/ml_inference.py`: inference
- `lib/train_ml_model.py`: training
- `lib/models/xgboost_predictor.pkl`: trained model (git-ignored via `*.pkl`; present locally)

**Features (14, order must match training):** `rsi_14`, `macd`, `macd_signal`, `macd_hist`, `bb_position`, `bb_width`, `atr`, `stochastic_k`, `stochastic_d`, `ema_20`, `ema_50`, `volume_ratio`, `close_price`, `price_range`.

**Data source:** `ml_inference.py` needs ≥ 50 rows of real OHLCV (`MIN_ROWS`). It uses the `--data-file` CSV if given (`data_source: "file"`), else a JSON array of OHLCV records on stdin (`"stdin"`), else yfinance (`period='3mo'`, `"yfinance"`; skipped when `SST_OFFLINE=1`). A single stdin record is too short and is ignored (yfinance is tried). Without enough real data the result is `{"available": false, "reason": ..., "data_source": null}` with exit 0. Synthetic features (seeded per symbol with `zlib.crc32`) are used only with `--synthetic`, `SST_ALLOW_SYNTHETIC=1` or `SST_OFFLINE=1`, and the result then has `data_source: "synthetic"` and a `warning`. `ml_predictor.sh` no longer sends a placeholder record when run from a terminal.

**How to Use:**

```bash
bash lib/ml_predictor.sh status
# {"status": "ready", "model_file": ".../lib/models/xgboost_predictor.pkl", "size_bytes": 271672, "modified": "..."}

bash lib/ml_predictor.sh predict AAPL 5 </dev/null      # yfinance, or {"available": false, ...}
SST_OFFLINE=1 bash lib/ml_predictor.sh predict AAPL 5 </dev/null
# {"symbol": "AAPL", "available": true, "direction": "up", "confidence": 82, "probability": 0.825, "period": 5,
#  "data_source": "synthetic", "model_training_data": "synthetic", "timestamp": "...", "warning": "Prediction uses SYNTHETIC features ..."}

python3 lib/ml_inference.py --symbol AAPL --period 5 --data-file prices.csv
# CSV needs High, Low, Close, Volume columns (case-insensitive) and ≥ 50 rows for real features

source lib/ml_predictor.sh
ml_predict_direction AAPL 5 </dev/null
```

Running the script with no sub-command (e.g. `ml_predictor.sh AAPL 5`) prints usage and exits 1. `batch` currently returns only the first symbol (issue 9); loop over `predict` instead.

**Output schema:**

```json
{
  "symbol": "AAPL",
  "available": true,
  "direction": "up|down",
  "confidence": 50-100,
  "probability": 0.5-1.0,
  "period": 5,
  "data_source": "yfinance|file|stdin|synthetic",
  "model_training_data": "synthetic",
  "timestamp": "2026-10-31T06:15:38Z",
  "warning": "only when data_source is synthetic"
}
```

`confidence` = `int(probability × 100)` where `probability` is that of the predicted class, so it is never below 50. There is no `model_version`, `training_accuracy` or `features_used` field. No real data: `{"symbol", "available": false, "reason", "data_source": null, "period", "timestamp"}` (exit 0). Errors: `{"error": "..."}` (exit 1).

**Training (`lib/train_ml_model.py`):** no command-line options. It trains on 200 synthetic samples for each of `AAPL, MSFT, GOOGL, AMZN, TSLA, NVDA, META, JPM, BRK.B, V`, 80/20 split, hyperparameters `max_depth=6`, `learning_rate=0.1`, `n_estimators=100`, `random_state=42`. It overwrites `lib/models/xgboost_predictor.pkl` and writes a report to the hard-coded `/Users/P3291917/Builds/6/.agents/tasks/ml-training-report.md`.

```bash
python3 lib/train_ml_model.py     # overwrites the existing model
```

**How to Enhance:**
1. Add argparse (symbols, days, report path) and real data loading to `train_ml_model.py`.
2. Tune `XGBOOST_PARAMS` in `train_ml_model.py` (e.g. `max_depth` 3–7, `learning_rate` 0.01–0.3, `n_estimators` 100–500, add `subsample`).
3. Add features in both `extract_features_from_data()` and `generate_synthetic_features_for_symbol()` in `ml_inference.py`, update `feature_names` in `predict()`, and match the training script; then retrain.
4. Test: `bash tests/test_ml_predictor.sh`.

---

### Enhancement 2: Regime-Adaptive Weighting

**Purpose:** Weight mean-reversion vs trend-following scores by market regime. No win-rate improvement has been measured.

**Files:**
- `lib/regime_detector.sh`: regime classification (15-minute cache in `REGIME_CACHE_DIR`, default `~/.stockswingtrader/regime_cache`)
- `lib/regime_weighting.sh`: weights, confidence multiplier, stop-loss adjustment

**Detection (`detect_market_regime SYMBOL [lookback] [closes...]`):** it has no market data source of its own. Pass ≥ 20 closing prices (oldest first) for a real result (`data_source: "caller"`; the cache is not read). Without closes it returns `{"regime": "unknown", "available": false, "reason", "data_source": null}`, unless synthetic data is allowed (`SST_ALLOW_SYNTHETIC=1` / `SST_OFFLINE=1`): then it uses its built-in 30-price demo series and marks the result `data_source: "synthetic"` with a `warning`. A cached synthetic result is not returned once the opt-in is gone. `apply_regime_weights` without a REGIME therefore sees `unknown` (50/50 weights) when there is no data. It computes EMA20, EMA50 (falls back to the mean when < 50 prices), Bollinger(20,2), an ADX approximation `min(100, |EMA20 − EMA50| × 10)`, and volatility = BB width % (capped at 100). Rules, in order:
1. volatility > 20 → `volatile`
2. ADX > 25 and EMA20 > EMA50 → `trending_bull`; ADX > 25 and EMA20 < EMA50 → `trending_bear`
3. otherwise → `sideways`

`detect_market_regime_kalman SYMBOL PRICES...` does the same on Kalman-filtered prices you pass in (`data_source: "caller"`).

**Weights (`get_regime_weights REGIME`):**

| Regime | MR % | TF % | `confidence_multiplier` | `stop_loss_adjustment` |
|---|---|---|---|---|
| `sideways` | 70 | 30 | 1.0 | 0 |
| `trending_bull` / `trending_bear` | 30 | 70 | 1.1 | 0 |
| `volatile` | 50 | 50 | 0.8 | 2 |
| other | 50 | 50 | 1.0 | 0 |

`apply_regime_weights` multiplies the weighted score by `apply_confidence_multiplier`: sideways 1.0, trending_bull 1.1, trending_bear 1.05, volatile 0.8 (0.7 when measured volatility > 25). `calculate_confluence_score_v2` uses its own weights and does not apply this multiplier.

**How to Use:**

```bash
export REGIME_CACHE_DIR=$(mktemp -d)   # optional: isolate the cache
source lib/regime_detector.sh
detect_market_regime AAPL 30 $CLOSES     # real closes -> "data_source":"caller"
detect_market_regime AAPL                # {"regime":"unknown","available":false,...}
SST_OFFLINE=1 detect_market_regime AAPL
# {"regime":"sideways","adx":16.30,"trend":"up","volatility":7.56,"ema_20":106.68,"ema_50":105.05,
#  "bb_upper":110.63,"bb_middle":106.60,"bb_lower":102.57,"data_source":"synthetic","symbol":"AAPL",
#  "timestamp":"...","warning":"Regime computed from a SYNTHETIC demo price series, not market data"}

source lib/regime_weighting.sh
apply_regime_weights AAPL 65 72 trending_bull     # SYMBOL MR_SCORE TF_SCORE [REGIME]
```

```json
{
  "symbol": "AAPL",
  "regime": "trending_bull",
  "combined_score": 76.89,
  "original_mr_score": 65.00,
  "original_tf_score": 72.00,
  "weights": {
    "mr_weight_pct": 30,
    "tf_weight_pct": 70,
    "weighted_mr_contribution": 19.50,
    "weighted_tf_contribution": 50.40
  },
  "volatility_pct": 0.00,
  "confidence_adjustment": 1.10,
  "stop_loss_adjustment_pct": 0,
  "recommendation": "trend_follow_buy",
  "regime_analysis": { "favors_strategy": "trend_following", "risk_level": "moderate" },
  "timestamp": "..."
}
```

When REGIME is omitted, `detect_market_regime` is called. `recommendation` values: `mean_reversion_buy`, `trend_follow_buy`, `trend_follow_short`, `hold_wait`, `selective_entry`, `hold_high_risk`, `hold`.

```bash
get_regime_weights volatile
# {"mr_weight": 50, "tf_weight": 50, "confidence_multiplier": 0.8, "stop_loss_adjustment": 2}
calculate_adjusted_stop_loss volatile 3 50     # REGIME BASE_STOP_PCT VOLATILITY → 5.00
```

**How to Enhance:**
1. Give `detect_market_regime` its own real OHLC fetch (e.g. `alpaca_get_bars` or yfinance); today callers must pass closes.
2. Replace the ADX approximation with `calc_adx` on real high/low/close.
3. Thresholds are literals in `detect_market_regime` (volatility `20`, ADX `25`); there are no `ADX_TRENDING`/`VOLATILITY_THRESHOLD` variables yet.
4. Change weights in `get_regime_weights` **and** in the `case "$regime"` block of `calculate_confluence_score_v2` (they are duplicated).
5. Test: `bash tests/test_regime_detector.sh` and `bash tests/test_regime_weighting.sh`.

---

### Enhancement 3: React Dashboard

**Frontend stack (`frontend/package.json`):** React 18, TypeScript, Vite 5, react-router-dom 6, Recharts, Tailwind CSS, axios, lucide-react. Data fetching uses a custom polling hook (`frontend/src/hooks/usePolling.ts`), not TanStack Query.

**Backend stack (`backend/package.json`):** Node.js + Express, cors. Routes run lib scripts with `execFile` (no shell interpolation). `dotenv`, `axios`, `ws`, `bull`, `redis` are listed as dependencies but not used by `server.js`.

**Ports:**
- Backend: `PORT` env var, default **3000** (`server.js`, `backend/start.sh`).
- Frontend dev server: **5173**, `strictPort: true`; Vite proxies `/api` → `http://localhost:3000` (`frontend/vite.config.ts`). The frontend calls `/api` by default, or `VITE_API_BASE_URL`.

**Polling:** default 5000 ms (`DEFAULT_POLLING_INTERVAL_MS` in `frontend/src/utils/preferences.ts`), minimum 1000 ms, changeable on the Settings page and stored in browser localStorage.

**Pages (`frontend/src/App.tsx`):**

| Route | Page | Content |
|---|---|---|
| `/` | Dashboard | Stat cards (symbols, buy/sell/hold counts, average score), signal-score bar chart, watchlist signals table, portfolio, statistics |
| `/analysis?symbol=AAPL` | Analysis | Signals, indicators and quote for one symbol, indicator bar chart |
| `/trades` | TradeHistory | Trades, win rate, total P&L, per-trade Sharpe, filters (symbol, outcome, from date), cumulative P&L chart, backtest results |
| `/watchlist` | Watchlist | Add/remove symbols, alerts (price above/below, score at least); stored in the browser |
| `/settings` | Settings | Polling interval; editable `RISK_PER_TRADE`, `MAX_POSITION_SIZE`, `MIN_CONFLUENCE_SCORE`, `TRADING_ENABLED`; other `config.sh` values read-only (secrets masked) |
| `*` | NotFound | 404 page |

**API endpoints (`backend/server.js`):**

| Method & Path | Backed by | Status at `532828e` |
|---|---|---|
| `GET /api/health` | — | `{"status":"healthy","timestamp":...}` |
| `GET /api/portfolio` | `lib/alpaca_broker.sh get-portfolio` | `{"raw":""}` (no such sub-command) |
| `GET /api/quotes/:symbol` | `lib/alpaca_broker.sh get-quote SYMBOL` | `{"symbol":...,"raw":""}` |
| `GET /api/signals/:symbol` | `lib/scoring.sh SYMBOL` | `{"symbol":...,"raw":""}` (scoring.sh has no CLI) |
| `GET /api/indicators/:symbol` | `lib/indicators_new.sh SYMBOL` | `{"symbol":...,"raw":""}` |
| `GET /api/trades` | `.trades/trade_log.json` | `{"trades":[],"message":"No trade history available"}` when missing |
| `GET /api/stats` | `lib/risk_management.sh calculate-stats` | `{"raw":""}` |
| `GET /api/settings` | `config.sh` | values with secrets masked |
| `POST /api/settings` | `config.sh` | whitelist above; 400 for other keys/invalid values; 404 if the key is not already in `config.sh` (`RISK_PER_TRADE`, `MIN_CONFLUENCE_SCORE`, `TRADING_ENABLED` are not in the template) |
| `GET /api/backtest` | `BACKTEST_OUTPUT_DIR/*.json` | list of `{file, data, data_source, synthetic}`; `data_source` is `unknown` for files without the field |

Invalid symbols return 400. There are no `/api/analysis` or `/api/watchlist` endpoints (404).

**How to Use:**

```bash
cd backend && npm install && npm start      # http://localhost:3000
cd frontend && npm install && npm run dev   # http://localhost:5173
cd frontend && npm run build                # tsc --noEmit + vite build → frontend/dist
```

`./StockSwingTrader_Agent.sh --dashboard` does **not** start these servers (issue 2).

**How to Enhance:**
1. New page: add `frontend/src/pages/NewPage.tsx`, a `<Route>` and `NavLink` in `frontend/src/App.tsx`, an API function in `frontend/src/utils/api.ts`.
2. New endpoint: follow the existing routes in `backend/server.js` (validate input, call `runScript(scriptPath, args, timeout)`, return JSON).
3. Fix the `{"raw":""}` endpoints by adding CLI dispatchers to the lib scripts or pointing routes at functions that exist.
4. Tests: `npm test --prefix backend` (runs `tests/test_backend.js`), `npm test --prefix frontend` (runs `tests/test_dashboard.js`). There is no e2e script.

---

### Enhancement 4: Backtesting Module

**Files:**
- `lib/backtest.sh`: Bash library (no CLI; running it directly does nothing)
- `lib/backtest_engine.py`: engine, called as `python3 lib/backtest_engine.py CONFIG_JSON`

**What it really does:**
- Data: yfinance daily bars (`data_source: "yfinance"`). No data (yfinance missing, empty, missing columns or fetch error) and no opt-in: exit 2, stdout `{"error": "market_data_unavailable", "available": false, "reason", "symbol", "data_source": null, "hint"}`, no results file. Synthetic prices only with `SST_OFFLINE=1` (always) or `SST_ALLOW_SYNTHETIC=1` / config `"allow_synthetic": true` (fallback); results then have `data_source: "synthetic"` and a `warning`, and the HTML report shows a SYNTHETIC DATA banner.
- Split: `train_pct` (default 80). Strategies run on the **test** portion only; the train portion is unused.
- Strategies with fixed parameters: mean reversion (RSI(14) < 30 and close < lower BB(20, 2.0) → buy; RSI > 70 and close > upper BB → sell) and trend follow (EMA12/EMA26 crossover). The better total P&L is reported.
- Long-only, buys with 95% of cash, exits only on a sell signal (no stops or targets). Slippage 0.1%, commission 0.01%, initial capital 100,000.
- The parameter grid in `backtest.sh` (`RSI_MIN..RSI_MAX`, `BB_STD_*`, `STOP_LOSS_*`, `PROFIT_TARGET_*`) is written to the config but **ignored** by the engine. No grid search or `--optimize` exists.
- Metrics: `total_pnl`, `win_rate` (%), `sharpe_ratio`, `max_drawdown` (%), `profit_factor` (0 when there are no losses), `payoff_ratio` (divides by 1 when there are no losses), `num_trades`.

**How to Use:**

```bash
export BACKTEST_OUTPUT_DIR=$PWD/output/backtests   # default is a hard-coded /Users/P3291917/... path
source lib/backtest.sh
backtest_strategy AAPL 2023-01-01 2023-12-31 80            # SYMBOL START END [TRAIN_PCT]
backtest_multi_symbol "AAPL,MSFT" 2022-01-01 2024-01-01 80 # + portfolio_summary_<ts>.json

# Offline (synthetic data, marked "data_source": "synthetic"):
SST_OFFLINE=1 bash -c 'source lib/backtest.sh; backtest_strategy AAPL 2023-01-01 2023-12-31 80'
```

`backtest_strategy` returns 1 (and prints the engine's error JSON on stderr) when the engine fails; `backtest_multi_symbol` returns 1 if any symbol failed or none succeeded. `./StockSwingTrader_Agent.sh --backtest AAPL --start 2023-01-01 --end 2023-12-31` runs `backtest_multi_symbol` and exits with its status.

**Output files** (in `BACKTEST_OUTPUT_DIR`):
- `backtest_<SYMBOL>_<YYYYmmdd_HHMMSS>.json`
- `backtest_<SYMBOL>_<YYYYmmdd_HHMMSS>.html`
- `backtest_<SYMBOL>_<YYYYmmdd_HHMMSS>.csv` (only when there are trades)
- `portfolio_summary_<timestamp>.json` (from `backtest_multi_symbol`; per-symbol `data_source`, `data_sources` list, `warning` if any is synthetic)

**Output schema (results JSON):**

```json
{
  "symbol": "AAPL",
  "strategy": "mean_reversion|trend_follow",
  "period": "2023-01-01 to 2023-12-31",
  "data_source": "yfinance|synthetic",
  "data_points": 52,
  "initial_capital": 100000,
  "final_capital": 100000,
  "total_pnl": 0,
  "win_rate": 0,
  "sharpe_ratio": 0,
  "max_drawdown": 0,
  "profit_factor": 0,
  "payoff_ratio": 0,
  "num_trades": 0,
  "equity_curve": [ ... ],
  "trade_journal": [ ... ],
  "warning": "only when data_source is synthetic"
}
```

(Values from an `SST_OFFLINE=1` run, so `data_source` was `synthetic`.)

**How to Enhance:**
1. Make the engine read `parameter_grid` and search it on the train split, then evaluate on the test split.
2. Add stop-loss/take-profit exits and position sizing (`lib/risk_management.sh` has helpers).
3. Add metrics in `Strategy.calculate_metrics()` in `backtest_engine.py`.
4. Add a CLI dispatcher to `lib/backtest.sh`.
5. Test: `bash tests/test_backtest.sh`.

---

### Enhancement 5: Kalman Filter

**Files:** `lib/kalman_filter.sh` (Bash wrapper with a Bash fallback), `lib/kalman_inference.py` (`KalmanFilter1D`).

**Model:** 1-D filter. `q` = process noise (default 0.01), `r` = measurement noise (default 0.1). Higher `q` or lower `r` follows prices more closely; lower `q` or higher `r` smooths more.

**How to Use:**

```bash
source lib/kalman_filter.sh
apply_kalman_filter 100 101 99 102 103 -q 0.01 -r 0.1     # prices as arguments
apply_kalman_filter_fast '[100,101,99,102,103]' 0.01 0.1   # JSON array, q, r
echo '[100,101,99,102]' | python3 lib/kalman_inference.py 0.05 0.05
get_kalman_filtered_prices AAPL 30   # no data source: {"available": false}, exit 1
SST_ALLOW_SYNTHETIC=1 get_kalman_filtered_prices AAPL 1   # random walk, "data_source":"synthetic"
```

**Output schema (Python path):**

```json
{
  "filtered_prices": [100.0, 100.502465, 99.937596, 100.602671, 101.314678],
  "residuals": [0.0, 1.0, -1.502465, 2.062404, 2.397329],
  "state": 101.314678,
  "covariance": 0.0297,
  "q": 0.01,
  "r": 0.1,
  "count": 5,
  "volatility": 0.943883,
  "smoothness_improvement": 65.08
}
```

`state` and `covariance` are scalars. The Bash fallback (no `python3`) omits `volatility` and `smoothness_improvement`. Errors include `"error": "empty_input"` or `"invalid_input: ..."`.

**How to Enhance:**
1. The CLI already passes `kalman_trend_from_closes` (5-bar slope of the filtered closes) into `calculate_confluence_score_v2`; `detect_market_regime_kalman` is still unused by the CLI.
2. Adaptive q/r based on residual volatility (future idea).
3. Multi-timeframe filtering (future idea).
4. Test: `bash tests/test_kalman_filter.sh`.

---

## Execution Safety (Step 1)

**Files:** `lib/order_safety.sh` (checks, ledger, reconciliation, kill switch), `lib/alerts.sh` (alert log, Slack, email), `lib/alpaca_broker.sh` (limit/bracket orders, client order ids, clock/calendar/orders API), `StockSwingTrader_Agent.sh` (`order_prechecks`, `place_guarded_order`, commands). Tested only against `tests/stubs/alpaca_stub_server.py` on 127.0.0.1 (`tests/test_order_execution.sh`, `tests/test_live_safety.sh`, `tests/test_broker_commands.sh`). Robinhood is exercised with stub shell functions only.

### Order flow (`--buy` / `--sell` → `place_guarded_order SIDE SYMBOL QTY`)

The first failing check exits 1 with a message; nothing is sent.

1. **Before any broker contact** (`order_prechecks`, run in `main` before `load_broker_module` and again in the flow): symbol/qty (`validate_order_args`), `--limit-price` numeric > 0, **kill switch**, **endpoint mode / live guard**, **`MAX_ORDER_QTY`**.
2. **Alpaca only:** market hours (`check_market_hours`), reconciliation (`reconcile_with_broker`, when `RECONCILE_ON_STARTUP=true`; `--allow-mismatch` continues with a warning + alert), account read + **daily loss halt**.
3. Positions; open orders + ledger → **duplicate guard**; a sell while open bracket legs hold the shares prints a warning (legs are not cancelled).
4. Reference price (`get_order_price`: Alpaca latest trade, falls back to Yahoo), limit price (`--limit-price` or `compute_limit_price`), **caps** (`check_order_caps`: notional, daily notional, open positions, no short selling).
5. **Bracket levels** (Alpaca buys, `ORDER_BRACKET=true` and no `--no-bracket`), time in force, **PDT warning**, client order id.
6. **Confirmation screen** (`Symbol`, `Quantity`, `Current Price`, `Estimated Cost`/`Estimated Proceeds`, `Order Type`, `Limit Price`, `Stop Loss`, `Take Profit`, `Time in Force`, `Client Order ID`, `Mode: PAPER|LOCAL STUB|LIVE`). PAPER / LOCAL STUB: type exactly `yes`. LIVE: type `SYMBOL QTY` (e.g. `AAPL 2`); anything else prints `Order cancelled` (exit 0).
7. Under the order lock (`$SST_STATE_DIR/order.lock`, stale after 120 s): ledger line `submitted` → submit → ledger `accepted` / `filled` / `rejected` / `unknown` → alert `order_placed` (+ `order_filled`) or `order_rejected` (`error`, critical, when the outcome is unknown). Output keeps `✓ BUY ORDER PLACED (ALPACA)` / `Failed to place buy order`.

Robinhood: same flow without clock, reconciliation, loss halt, PDT and brackets (one `NOTICE` line each), market orders through the 3-arg `robinhood_place_order`, always LIVE.

### Order types and defaults

| Case | Payload | Time in force | Why |
|---|---|---|---|
| default buy | `type: limit`, `order_class: bracket`, `take_profit.limit_price`, `stop_loss.stop_price`, `client_order_id` | `BRACKET_TIME_IN_FORCE` = `gtc` | Bracket legs inherit the TIF; `day` legs expire at the close, so the stop would not survive overnight for a swing trade |
| `--no-bracket` / sells (limit) | `type: limit` | `ORDER_TIME_IN_FORCE` = `day` | An unfilled entry should not linger for days |
| `--order-type market` | `type: market` | `day` | Same payload as before Step 1 |

- Limit price: buy `ref × (1 + LIMIT_OFFSET_PCT/100)`, sell `ref × (1 − …)`, default offset 0.2%. Prices ≥ $1 round to 2 decimals, < $1 to 4.
- Bracket levels (`order_bracket_levels`): from real yfinance bars, `stop % = ATR(14) × STOP_LOSS_ATR_MULTIPLIER / entry × 100` adjusted by `calculate_adjusted_stop_loss REGIME …` (method `atr+regime`); without real bars (offline, synthetic, fetch failure) `STOP_LOSS_PERCENT` (method `percent`). Clamped to [`ORDER_MIN_STOP_PCT` 1, `ORDER_MAX_STOP_PCT` 15]. Take profit = `TARGET_PROFIT_PERCENT` (8) above entry.
- Client order id: `sst-<SYM>-<b|s>-<YYYYmmddHHMMSS>-<4 hex>`; the `sst-` prefix marks agent orders. `alpaca_submit_order` never resubmits: on HTTP 000/timeout or 5xx it looks the id up (`GET /orders:by_client_order_id`, up to `ALPACA_LOOKUP_ATTEMPTS` 3); found → placed (`confirmed_by: "client_order_id_lookup"`), not found → `order outcome unknown`, ledger `unknown`.
- Request timeout: `ALPACA_TIMEOUT_SECONDS` (template default 15).

### Caps and halts

| Check | Applies to | Config (default) | Message starts with |
|---|---|---|---|
| Quantity | buys and sells, before broker contact | `MAX_ORDER_QTY` (100) | `Order blocked: quantity …` |
| Order notional | buys | `MAX_ORDER_NOTIONAL` (2500) | `Order blocked: notional …` |
| Daily notional | buys; ledger buys of today (America/New_York) with status submitted/accepted/filled/unknown + this order | `MAX_DAILY_NOTIONAL` (10000) | `Order blocked: today's buy notional …` |
| Open positions | buys of a symbol not already held | `MAX_OPEN_POSITIONS` (5) | `Order blocked: N open positions …` |
| No short selling | sells > held quantity | — | `Order blocked: sell … exceeds the held position` |
| Daily loss halt | buys (sells allowed); equity vs `last_equity` (realized + unrealized) via `enforce_daily_drawdown_limit` | `DAILY_LOSS_LIMIT_PCT` (empty = `DEFAULT_RISK_LEVEL` 2/5/10%) | `DAILY LOSS HALT: …` |
| Duplicate | same symbol + side in the ledger within the window, or an open broker order for it; no override | `DUPLICATE_ORDER_WINDOW_SECONDS` (300) | `Order blocked: duplicate …` |

Sells are not counted in daily notional and are not blocked by the notional/position caps, so exits stay possible. Each block sends an alert (`cap_hit`, `halt`, `duplicate_blocked`).

### Kill switch

`--halt [REASON]` writes `${KILL_SWITCH_FILE:-$SST_STATE_DIR/KILL_SWITCH}` = `{ts, reason, by}` (alert `halt`, critical); every order is then refused before any broker contact with `KILL_SWITCH ACTIVE since <ts>: <reason>. No new orders. Run --resume to clear.`. `--resume` removes it (alert `resume`). Both are local (no broker call). Verified: `--halt "news event"` → `--buy AAPL 1` refused → `--resume`.

### Reconciliation

State: `$SST_STATE_DIR/positions_baseline.json` = `{taken_at, broker, positions: {SYM: qty}, accepted_open_order_ids}` and the order ledger `$SST_STATE_DIR/orders.jsonl` (one JSON line per agent order: `ts_epoch, ts, trading_day, client_order_id, broker, mode, symbol, side, qty, type, limit_price, stop_price, take_profit_price, notional, status, broker_order_id`). Expected position = baseline + filled quantity of agent orders (`sst-` prefix, created after `taken_at`, including bracket legs). Mismatches: broker quantity ≠ expected, or open orders without the `sst-` prefix that were not accepted with the baseline. No baseline: OK and created automatically when the account is empty, otherwise `NO BASELINE` (treated as a mismatch).

- `--reconcile`: report; exit 0 match, 3 mismatch, 1 data error.
- `--reconcile-accept`: adopt the broker's current positions (and open orders) as the baseline.
- Orders are refused on mismatch (unless `--allow-mismatch`); `--check-account`, `--view-positions` and `--alpaca` only print a warning (exit code unchanged). Alerts `reconcile_mismatch`, `reconcile_accept`, `order_filled` (newly filled ledger orders).
- External trades (made outside the agent) show up as mismatches until you accept a new baseline. Alpaca only; Robinhood prints `NOTICE: reconciliation not available for robinhood`. `logs/trades.json` (trade journal) is not part of it.

### Market hours, PDT

- `check_market_hours`: `GET /v2/clock`; open → OK. Closed → `GET /v2/calendar` for today decides between `the market is closed` and `market holiday: … is not a trading day`. `OUTSIDE_HOURS_POLICY=refuse` (default) blocks (alert `outside_hours`); `queue` lets Alpaca hold the order until the next open (notice). Clock error → blocked (fail closed).
- `check_pdt_warning`: equity below `PDT_EQUITY_THRESHOLD` (25000) and a same-day round trip is possible (a sell of a symbol bought today, or any bracket buy, whose legs can fill the same day) → `PDT WARNING: … (daytrade_count N; …)` + alert. Warning only; with the paper stub's equity it fires on every bracket buy.

### Modes and the live guard

`broker_endpoint_mode` classifies the endpoint: `paper` (host `paper-api.alpaca.markets`, or an empty URL), `local` (127.0.0.1 / localhost / [::1]; `SST_LOOPBACK_IS_LIVE=1` is a test knob that makes it `live`), `live` (anything else; Robinhood is always `live`). The agent prints `Mode: PAPER|LOCAL STUB|LIVE (<broker>)` once.

- LIVE without `--live` → refused before any broker contact.
- LIVE while the active config file (`SST_CONFIG_FILE`, default `config.sh`) is tracked in git → refused (`config.sh is tracked in git and must stay on paper …`). Live keys go in an untracked file, e.g. `config.live.sh` (gitignored), selected with `SST_CONFIG_FILE=$PWD/config.live.sh … --live`.
- LIVE confirmation is the typed `SYMBOL QTY`.

### Alerts

`send_alert LEVEL EVENT MESSAGE [DETAILS_JSON]` always appends `{ts, level, event, message, details, mode}` to `ALERT_LOG_FILE` (default `<project>/logs/alerts.log`). Slack when `ALERTS_SLACK_ENABLED=true` and `ALERT_SLACK_WEBHOOK_URL` is set (`{"text": "[StockSwingTrader LEVEL] EVENT (MODE): MESSAGE"}`); email when `ALERTS_EMAIL_ENABLED=true` and `ALERT_EMAIL_TO` is set (`$ALERT_SENDMAIL_CMD -t`, subject `[StockSwingTrader LEVEL] EVENT`). Channel failures are logged as `alert_channel_error`, never fatal. Events: `order_placed`, `order_filled`, `order_rejected`, `cap_hit`, `duplicate_blocked`, `halt`, `resume`, `reconcile_mismatch`, `reconcile_accept`, `outside_hours`, `pdt_warning`, `error`. No key values or full account ids are written.

### Status

`--safety-status` (no broker call), verified on the repo config:

```
Mode:               PAPER (alpaca, https://paper-api.alpaca.markets)
Kill switch:        off
Caps:               MAX_ORDER_QTY=100 MAX_ORDER_NOTIONAL=2500 MAX_DAILY_NOTIONAL=10000 MAX_OPEN_POSITIONS=5
Daily loss limit:   5% (DAILY_LOSS_LIMIT_PCT; empty = DEFAULT_RISK_LEVEL moderate)
Today's buys:       $0 of $10000 (alpaca, trading day 2026-10-31)
Order ledger:       0 orders (0 today) in <project>/.state/orders.jsonl
Baseline:           none (run --reconcile-accept)
Orders:             limit (offset 0.2%), bracket true (gtc), outside hours refuse, duplicate window 300 s
Reconcile on start: true
Alerts:             log <project>/lib/../logs/alerts.log; slack off; email off
```

---

## Scoring Pipeline Integration

See [Data Flow & Pipeline](#data-flow--pipeline) for both formulas. Summary:

```
Legacy (--legacy-score):  final = mean(rsi, macd, bb, stoch, williams, obv) × 0.8 + sentiment × 0.2

v2 (CLI default):  confluence = ML × 0.15 + RegimeWeighted × 0.35 + Technical × 0.30 + VolumeTrend × 0.20
  ML           ml_predictor confidence (50–100), or 50 on error/timeout
  Regime       sideways 70/30, trending 30/70, volatile 50/50 × 0.8 (MR/TF)
  Technical    (rsi + macd + bb) / 3
  VolumeTrend  OBV blended with Kalman trend (75 up / 25 down, 20% weight)
  then MiroFish (w, optional) and sentiment (V2_SENTIMENT_WEIGHT, when available)
```

v2 is wired into the CLI in `score_stock` (Step 1): MR/TF scores, regime, Kalman trend and the OBV score come from `.v2_inputs` (`build_v2_inputs` in `calculate_all_indicators`). Both modes keep `.confluence.final_confidence` / `.signal` / `.reasoning`, so Kelly, the HTML report and older consumers read one field.

---

## Main Agent Flags

From the `case` parser in `main()` and `./StockSwingTrader_Agent.sh --help` (re-checked at `5a7abc0`):

| Flag | Effect | Works? |
|---|---|---|
| `--symbols A,B` | Analyze listed symbols | Runs on yfinance data; exits 1 if no symbol had data (synthetic only on opt-in) |
| `--watchlist FILE` | Symbols from file | Needs bash 4 (issue 6) |
| `--top-10` | Fixed list `AAPL MSFT GOOGL AMZN TSLA META NFLX CRM ADBE NVDA` | Same as `--symbols` |
| `--output-dir DIR` | Report directory (default `output/reports`) | — |
| `--debug` | `DEBUG_MODE=true` | Yes |
| `--version` | Print version/features | Yes |
| `--help` | Usage | Yes |
| `--ml` | Source `lib/ml_predictor.sh` | Loads; v2 scoring (the default) runs the ML predictor with or without it |
| `--regime-adapt` | Source `lib/regime_adaptive.sh` | Skipped, file missing (issue 2) |
| `--kalman` | Source `lib/kalman_filter.sh` | Loads; v2 scoring uses the Kalman trend with or without it |
| `--dashboard` | Source `lib/dashboard.sh`, call `start_dashboard_servers` | Skipped, file missing (issue 2) |
| `--full` | `--ml --regime-adapt --kalman --dashboard` | Same as above |
| `--legacy-score` | Legacy score (80% technical average + 20% sentiment) instead of v2; same as `SCORING_MODE=legacy` | Yes |
| `--kelly` | Fractional (quarter) Kelly sizing with daily risk budget (`.position_sizing`) | Yes |
| `--mirofish` | Read the MiroFish scan cache `cache/mirofish/<SYMBOL>.json` if fresh (< 36 h); no network | Yes (no cache producer exists yet) |
| `--phase1` | `--kelly --mirofish` (`--full` does not include them) | Yes |
| `--broker alpaca\|robinhood` | Broker choice (default `alpaca`) | — |
| `--check-account`, `--view-positions` | Broker account (portfolio value, cash, buying power, status; no account number) / open positions; then a reconciliation warning when `RECONCILE_ON_STARTUP=true` and the broker state does not match | Yes (Alpaca paper verified live, read-only; Robinhood stub-tested only) |
| `--buy SYMBOL QTY`, `--sell SYMBOL QTY` | Limit order (bracket stop loss / take profit on buys) after all [safety checks](#execution-safety-step-1) and a `yes` confirmation on stdin (LIVE: `--live` + typed `SYMBOL QTY`) | Yes (tested against the local Alpaca stub only); invalid symbol/qty or missing args exit 1 before any broker call; any other answer cancels |
| `--order-type limit\|market` | Order type (default `ORDER_TYPE=limit`) | Yes |
| `--limit-price PRICE` | Explicit limit price (> 0) instead of quote ± `LIMIT_OFFSET_PCT` | Yes |
| `--no-bracket` | Plain order without the bracket legs | Yes |
| `--live` | Allow an order on a LIVE endpoint (then typed confirmation); refused when the active config is tracked in git | Yes (stub with `SST_LOOPBACK_IS_LIVE=1` only) |
| `--allow-mismatch` | Place the order despite a reconciliation mismatch (warning + alert) | Yes |
| `--halt [REASON]` | Engage the kill switch (reason = next arg unless it starts with `--`); local | Yes |
| `--resume` | Release the kill switch; local | Yes |
| `--safety-status` | Mode, kill switch, caps, today's notional, ledger, baseline, alert channels; local | Yes |
| `--reconcile` | Broker positions/open orders vs baseline + ledger; exit 0 match, 3 mismatch, 1 data error | Yes (Alpaca; read-only) |
| `--reconcile-accept` | Adopt the broker's current positions as the baseline | Yes (Alpaca) |
| `--alpaca`, `--place-buy`, `--place-sell`, `--alpaca-status` | Deprecated Alpaca aliases (`--alpaca` alone shows account + positions) | Yes, same as above (the order aliases go through the same checks) |
| `--backtest SYMBOLS` | Run `backtest_multi_symbol` | Yes (`AGENT_DIR`); non-zero exit without market data |
| `--start DATE`, `--end DATE` | Backtest dates (defaults: 2 years ago, today) | — |
| `--train-pct PCT` | Train split (default 80) | — |

Verified examples:

```bash
./StockSwingTrader_Agent.sh --help
./StockSwingTrader_Agent.sh --version
./StockSwingTrader_Agent.sh --symbols AAPL,MSFT --output-dir /tmp/sst_reports
./StockSwingTrader_Agent.sh --backtest AAPL --start 2023-01-01 --end 2023-12-31   # non-zero exit without market data
./StockSwingTrader_Agent.sh --symbols AAPL --legacy-score
./StockSwingTrader_Agent.sh --check-account      # Alpaca paper keys in config.sh
./StockSwingTrader_Agent.sh --view-positions
./StockSwingTrader_Agent.sh --safety-status      # local, no broker call
./StockSwingTrader_Agent.sh --reconcile-accept   # once, to adopt existing paper positions
./StockSwingTrader_Agent.sh --buy AAPL 1         # limit + bracket; prints a confirmation; type "yes" to send
./StockSwingTrader_Agent.sh --buy AAPL 2 --order-type market --no-bracket
./StockSwingTrader_Agent.sh --halt "news event"; ./StockSwingTrader_Agent.sh --resume
```

Broker settings: `ALPACA_API_KEY`, `ALPACA_SECRET_KEY` (or `ALPACA_OAUTH_TOKEN`), `ALPACA_BASE_URL` (trading API, default paper), `ALPACA_DATA_URL` (market data, default `https://data.alpaca.markets`), `ALPACA_DATA_FEED` (default `iex`), `ALPACA_TIMEOUT_SECONDS` (15). `SST_CONFIG_FILE` replaces `config.sh` as the local config (the broker tests use it to point at a stub; live keys use it to select an untracked `config.live.sh`). `config.sh` hard-sets `ALPACA_BASE_URL` to paper, so an exported `ALPACA_BASE_URL` has no effect while it is the active config.

The agent logs to `LOG_FILE` (default `logs/agent.log`, relative to the current directory) and creates `logs/`.

---

## Setup & Configuration

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
pip install yfinance      # optional: real data for ML inference and backtests (not in requirements.txt)
# requirements.txt pins numpy 1.24.3 / pandas 2.0.3, which only build on Python ≤ 3.11.
# On Python 3.12+ install unpinned instead:
pip install xgboost pandas numpy scikit-learn scipy joblib filterpy requests

(cd backend && npm install)
(cd frontend && npm install)
```

Configuration:
- `config.template.sh` is tracked and has no secrets. The agent sources it, then `config.sh` (or `SST_CONFIG_FILE`) if present, whose values win. Its placeholder `API_KEY_ALPHA_VANTAGE`/`API_KEY_FINNHUB`/`API_KEY_NEWSAPI` values override anything exported earlier; Alpaca keys are read from the environment when `config.sh` does not set them.
- `config.sh` is **tracked** in this private repository (since `52516c3`) and comes with the clone. It holds the Alpaca **paper** keys, `ALPACA_BASE_URL="https://paper-api.alpaca.markets"`, and the Finnhub and NewsAPI keys. To change a key: edit `config.sh`, run `./StockSwingTrader_Agent.sh --check-account`, commit it to the private repo. Never put live keys or a live URL in it: the agent refuses LIVE broker commands while the active config file is tracked. Regenerate any key that was exposed outside the private repo.
- `config.robinhood.sh` and `config.live.sh` are untracked (`.gitignore`, together with `.state/`). Live keys go in `config.live.sh`, selected with `SST_CONFIG_FILE=$PWD/config.live.sh` and used only with `--live`.
- The backend Settings API and the helper scripts (`RUN_TRADING.sh`, `CHECK_ACCOUNT.sh`, `CHECK_ORDERS.sh`) read `config.sh`.
- To edit `RISK_PER_TRADE`, `MIN_CONFLUENCE_SCORE` and `TRADING_ENABLED` from the dashboard, add `export` lines for them to `config.sh` first.

Step 1 config variables (`config.template.sh`, all `${VAR:-default}`, so an exported value wins unless `config.sh` sets it):

| Variable | Default | Meaning |
|---|---|---|
| `SCORING_MODE` | `v2` | `v2` \| `legacy` (`--legacy-score`) |
| `V2_SENTIMENT_WEIGHT` | `0.10` | Sentiment weight in v2 (0..0.5), only when sentiment is available |
| `OBV_LOOKBACK` | `10` | Bars for the OBV trend score |
| `KALMAN_TREND_THRESHOLD_PCT` | `0.5` | 5-bar Kalman slope (%) for trend up/down |
| `ML_TIMEOUT_SECONDS` | `15` (template; library default 5) | ML prediction timeout in v2 (one prediction takes ~5 s) |
| `ORDER_TYPE` | `limit` | `limit` \| `market` (`--order-type`) |
| `LIMIT_OFFSET_PCT` | `0.2` | Limit = quote + (buy) / − (sell) this % |
| `ORDER_BRACKET` | `true` | Buys get a bracket stop loss + take profit (`--no-bracket`) |
| `ORDER_TIME_IN_FORCE` | `day` | Plain limit orders |
| `BRACKET_TIME_IN_FORCE` | `gtc` | Bracket orders (legs inherit it) |
| `ORDER_MIN_STOP_PCT`, `ORDER_MAX_STOP_PCT` | `1`, `15` | Bracket stop distance clamp (%) |
| `MAX_ORDER_QTY` | `100` | Shares per order (both sides) |
| `MAX_ORDER_NOTIONAL` | `2500` | $ per buy |
| `MAX_DAILY_NOTIONAL` | `10000` | $ of agent buys per trading day (America/New_York) |
| `MAX_OPEN_POSITIONS` | `5` | A buy of a new symbol is refused at this count |
| `DAILY_LOSS_LIMIT_PCT` | empty | Empty = `DEFAULT_RISK_LEVEL` limit (conservative 2 / moderate 5 / aggressive 10%) |
| `DUPLICATE_ORDER_WINDOW_SECONDS` | `300` | Same symbol + side refused within this window |
| `SST_STATE_DIR` | empty = `<project>/.state` | Ledger, baseline, kill switch, order lock |
| `KILL_SWITCH_FILE` | empty = `$SST_STATE_DIR/KILL_SWITCH` | |
| `RECONCILE_ON_STARTUP` | `true` | Reconcile before orders (blocks on mismatch) and on account/positions commands (warning) |
| `OUTSIDE_HOURS_POLICY` | `refuse` | `refuse` \| `queue` |
| `PDT_EQUITY_THRESHOLD` | `25000` | PDT warning below this equity |
| `ALERT_LOG_FILE` | empty = `<project>/logs/alerts.log` | |
| `ALERTS_SLACK_ENABLED`, `ALERT_SLACK_WEBHOOK_URL` | `false`, empty | Slack incoming webhook (keep the URL out of tracked files) |
| `ALERTS_EMAIL_ENABLED`, `ALERT_EMAIL_TO`, `ALERT_SENDMAIL_CMD` | `false`, empty, `sendmail` | Email via `$ALERT_SENDMAIL_CMD -t` |
| `ALERT_TIMEOUT_SECONDS` | `5` | Slack/email timeout |
| `ALPACA_TIMEOUT_SECONDS` | `15` | Alpaca request timeout |

Existing variables used by the order flow: `STOP_LOSS_PERCENT` (5), `STOP_LOSS_ATR_MULTIPLIER` (2), `TARGET_PROFIT_PERCENT` (8), `DEFAULT_RISK_LEVEL` (moderate).

Environment variables used by the code: `LOG_FILE`, `DEBUG_MODE`, `BROKER_CHOICE`, `ML_TIMEOUT_SECONDS`, `SST_OFFLINE`, `SST_ALLOW_SYNTHETIC`, `REGIME_CACHE_DIR`, `BACKTEST_OUTPUT_DIR`, `DEBUG_BACKTEST`, `SST_CONFIG_FILE`, `ALPACA_API_KEY`, `ALPACA_SECRET_KEY`, `ALPACA_BASE_URL`, `ALPACA_DATA_URL`, `ALPACA_DATA_FEED`, `ALPACA_TIMEOUT_SECONDS`, `ALPACA_LOOKUP_ATTEMPTS`, `SCORING_MODE`, `SST_STATE_DIR`, `KILL_SWITCH_FILE`, `ALERT_LOG_FILE`, `SST_LOOPBACK_IS_LIVE` (tests only: treat 127.0.0.1 as live), `STUB_SLOW_SECONDS` (stub only), every variable in the table above, `PORT`, `SST_BASE_PATH`, `SST_LOG_FILE`, `VITE_API_BASE_URL`.

---

## Development Guidelines

### Code Style & Conventions

1. **Bash:** `#!/bin/bash`, `set -o pipefail` (agent and `backtest.sh`), `UPPERCASE` globals, `lowercase_with_underscores` functions. Library files are sourced, so do not reassign shared globals such as `SCRIPT_DIR` or `LIB_DIR` at file scope (that was the cause of issue 1; `tests/test_broker_commands.sh` checks every `lib/*.sh`); use a file-specific name. Do not `set -o errexit` in a sourced file. Document functions with a comment block (description, args, returns, example). Remember macOS ships bash 3.2: avoid `mapfile`, associative arrays and `${var,,}`, or require bash 4 explicitly.
2. **Python:** PEP 8, type hints where practical, docstrings.
3. **JSON output:** modules print a JSON object on success and `{"error": "..."}` on failure (there is no common `status`/`code` envelope). Timestamps are ISO 8601 UTC (`date -u +%Y-%m-%dT%H:%M:%SZ`).
4. **Backend:** pass arguments as arrays to `execFile`; validate symbols and settings before use.
5. **Orders and safety:** every new order path goes through `place_guarded_order` (never call `${BROKER_PREFIX}place_order` directly from the CLI). New checks that need no broker go in `order_prechecks`. Test order paths only against `tests/stubs/alpaca_stub_server.py` on 127.0.0.1 with a stub config in `SST_CONFIG_FILE`, and set `HOME`, `SST_STATE_DIR` and `ALERT_LOG_FILE` to temp dirs so the repo `.state/` and kill switch are untouched. Never print key values; mask account ids. Source `lib/order_safety.sh` before `load_broker_module` (it loads `alpaca_broker.sh`, which resets `ALPACA_INITIALIZED`).

### Module Development Workflow

1. Create `lib/my_module.sh`, add a header and functions; if it should run as a script, add a `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` dispatcher like `lib/ml_predictor.sh`.
2. Integrate: `source "$AGENT_DIR/lib/my_module.sh"` in the agent, add a flag in the `case` parser in `main()`, document it in `usage()`.
3. Add a test script in `tests/` and register it in `tests/test_runner.sh` with `add_test "Name" "${SCRIPT_DIR}/test_my_module.sh"`.

### Goals (not measured)

These are targets, not verified benchmarks: under 5 s per symbol for the full pipeline, and modules that emit valid JSON, handle errors, time out external calls and are testable on their own.

---

## Testing

`bash tests/test_runner.sh` runs 18 suites offline (`SST_OFFLINE=1`) and writes `.agents/tasks/test-report.md`. Last verified result: **18 suites, 960/960 passing** at `5a7abc0` (live-safety Step 1, about 13.5 min; run with no `SST_CONFIG_FILE` exported and `HOME` set to the real home). Earlier: 15 suites, 598/598 after the broker/path fix; 14 suites, 468/468 before it (also on a fresh clone that trained its own model with `python3 lib/train_ml_model.py`, xgboost 3.4.1 / numpy 2.5.4). The ML Scoring Integration suite does not depend on what the trained model predicts: it checks the predictor's contract (schema, confidence range, determinism) and runs the STRONG_BUY/STRONG_SELL threshold tests with a stub predictor.

| Suite | File | Runner |
|---|---|---|
| ML Predictor | `tests/test_ml_predictor.sh` | bash |
| Regime Weighting | `tests/test_regime_weighting.sh` | bash |
| Kalman Filter | `tests/test_kalman_filter.sh` | bash |
| Backtest | `tests/test_backtest.sh` | bash |
| ML Scoring Integration | `tests/test_ml_scoring_integration.sh` | bash |
| Regime Detector | `tests/test_regime_detector.sh` | bash |
| Scoring Integration (Python) | `tests/test_scoring_integration.py` | python3 |
| Dashboard Components | `tests/test_dashboard.js` | `node --test` |
| Backend API | `tests/test_backend.js` | `node --test` |
| Kelly Sizing & Risk Budget | `tests/test_kelly_sizing.sh` | bash |
| Sentiment (deterministic) | `tests/test_sentiment.sh` | bash |
| MiroFish Cache Adapter | `tests/test_mirofish_adapter.sh` | bash |
| Phase 1 Integration (CLI) | `tests/test_phase1_integration.sh` | bash |
| No Silent Fake Data | `tests/test_no_fake_data.sh` | bash |
| Broker Commands (stubbed) | `tests/test_broker_commands.sh` | bash |
| V2 CLI Scoring | `tests/test_v2_cli_scoring.sh` | bash |
| Order Execution (stubbed) | `tests/test_order_execution.sh` | bash |
| Live Safety (stubbed) | `tests/test_live_safety.sh` | bash |

`tests/test_v2_cli_scoring.sh` (81 tests) covers the OBV trend score (all up 100, all down 0, flat 50, deterministic), MR/TF/Kalman helpers, the 10th sentiment arg, `analyze_stock` in v2 and legacy mode, MiroFish applied once in v2, the JSON + HTML score breakdown and `--help`. `tests/test_order_execution.sh` (81) covers payload shapes (market/day, limit, bracket gtc, rounding, client order id), bracket orders, duplicate client order id → 422, timeout → lookup with exactly one POST, clock/calendar/open orders, account id masking and that the wrappers no longer shadow broker functions. `tests/test_live_safety.sh` (188, ~2.5 min, one stub per scenario) covers the default limit+bracket buy, every cap, no short selling, kill switch / `--halt` / `--resume`, duplicates, reconciliation (`--reconcile` exit 3, `--reconcile-accept`, fills, unknown open orders, `--allow-mismatch`), market closed / holiday / `queue`, PDT, the live guard (no `--live`, wrong confirmation, typed confirmation, tracked config), that the real `config.sh` points at paper (value check only), Robinhood without `--live`, alerts (log, Slack to the stub `/hooks/slack`, email via a stub sendmail) and `--safety-status`.

`tests/test_no_fake_data.sh` covers the [data-source rules](#data-sources--synthetic-data). It sets `SST_OFFLINE=0` itself and simulates market data with yfinance stubs put first on `PYTHONPATH`: `tests/stubs/yfinance_empty` (no data), `tests/stubs/yfinance_error` (fetch raises) and `tests/stubs/yfinance_fixture` (deterministic real-shaped bars). No network is used.

`tests/test_broker_commands.sh` never contacts a real broker: Alpaca calls go to `tests/stubs/alpaca_stub_server.py` on 127.0.0.1 through a stub config (`SST_CONFIG_FILE`, with temp `SST_STATE_DIR`/`ALERT_LOG_FILE`), Robinhood is exercised with stub functions, and `HOME` is a temp dir. It covers all broker flags and aliases, `yes`/`no`/EOF confirmation (no order on anything but `yes`), invalid symbol/qty, a broker rejection, missing credentials, `--ml`/`--kalman` loading, and that no `lib/*.sh` changes the caller's `SCRIPT_DIR`/`LIB_DIR`/`AGENT_DIR` or enables `errexit`. Step 1 changed only invocations: the Alpaca section first runs `--reconcile-accept`; the market-payload assertion runs `--buy AAPL 2 --order-type market --no-bracket`; Robinhood orders pass `ORDER_LIVE_FLAG=true` with a typed `AAPL 2` / `MSFT 1` (plus a new check that Robinhood without `--live` is refused); the `--place-sell` + `no` case uses AAPL instead of NVDA (an NVDA sell placed just before would now be refused by the duplicate guard before the prompt).

The stub (`alpaca_stub_server.py PORT_FILE REQ_LOG ORDER_LOG [STATE_FILE]`, `ThreadingHTTPServer` on 127.0.0.1) serves account (with `last_equity`, `pattern_day_trader`, `daytrade_count`), positions (AAPL 10, MSFT 5, NVDA 2), latest trade, `GET/POST /v2/orders`, `/v2/orders:by_client_order_id`, `/v2/orders/<id>`, `/v2/clock`, `/v2/calendar` and `POST /hooks/<name>`; symbol `REJ` and a reused client order id → 422, `TMO` answers after `STUB_SLOW_SECONDS` (3), `FIL` fills immediately; `STATE_FILE` (JSON, re-read per request) overrides account/positions/clock/calendar/orders.

Other test scripts not in the runner: `tests/test_alpaca_broker.sh`, `tests/test_robinhood_broker.sh`, `tests/test_regime_simple.sh`.

```bash
bash tests/test_runner.sh               # all 18 suites (~13.5 min)
bash tests/test_live_safety.sh          # order safety against local stubs (~2.5 min)
bash tests/test_order_execution.sh
bash tests/test_v2_cli_scoring.sh
bash tests/test_broker_commands.sh      # broker flags against local stubs
bash tests/test_ml_scoring_integration.sh
npm test --prefix backend               # tests/test_backend.js
npm test --prefix frontend              # tests/test_dashboard.js
bash -n StockSwingTrader_Agent.sh lib/*.sh   # syntax check
```

There is no `tests/test_indicators.sh`, `tests/validate_config.sh`, `DEPLOYMENT_PACKAGE/verify.sh` or e2e script.

---

## Troubleshooting

| Issue | Root Cause | Solution |
|-------|-----------|----------|
| `lib/lib/...` in errors, `Failed to load alpaca broker module` | A lib file reassigning `SCRIPT_DIR` (fixed issue 1) | Use a file-specific dir variable in the lib; run `bash tests/test_broker_commands.sh` |
| `Missing Alpaca API credentials` | No `ALPACA_API_KEY`/`ALPACA_SECRET_KEY` in the environment or `config.sh` | Add paper keys to `config.sh` |
| `Invalid symbol` / `Invalid quantity` on `--buy`/`--sell` | Symbol not 1–5 uppercase letters, or qty not > 0 | e.g. `--buy AAPL 1` |
| `Failed to get current price` on `--buy`/`--sell` | No Alpaca latest trade and Yahoo failed (or `SST_OFFLINE=1`) | Check `ALPACA_DATA_URL`/feed and network |
| `--regime-adapt` / `--dashboard` "module not found" | `regime_adaptive.sh` / `dashboard.sh` do not exist | Use `lib/regime_weighting.sh`; start backend/frontend with npm |
| `No market data for AAPL` / `Skipping AAPL - unable to fetch data` | yfinance missing, offline or no data, and no synthetic opt-in | Install yfinance / check network; or `SST_ALLOW_SYNTHETIC=1` for marked demo data |
| `Unknown option: 2022-01-01` | Positional backtest dates | Use `--start` / `--end` |
| `mapfile: command not found` | bash 3.2 | Run with bash 4+ (`brew install bash`) or use `--symbols` |
| `Model file not found` | `lib/models/xgboost_predictor.pkl` missing (git-ignored) | `python3 lib/train_ml_model.py` |
| ML returns `"available": false` | Fewer than 50 rows of real data (yfinance missing/empty, short `--data-file`) | Install yfinance, pass `--data-file` with ≥ 50 rows; ML then has 0 weight in v2 scoring |
| ML always returns the same value per symbol | `data_source: "synthetic"` (opt-in set, e.g. `SST_OFFLINE=1`) | Unset `SST_OFFLINE` / `SST_ALLOW_SYNTHETIC` |
| Backtest exits 2 with `market_data_unavailable` | No real prices for the period | Check symbol/dates/network; `SST_ALLOW_SYNTHETIC=1` for a marked demo run |
| `pip install -r requirements.txt` fails | numpy/pandas pins need Python ≤ 3.11 | Use Python 3.11 or install unpinned |
| Dashboard panels empty / `{"raw":""}` | Backend calls unimplemented sub-commands | Known issue 7 |
| Dashboard not loading | Backend not on 3000 or port 5173 taken (`strictPort`) | `cd backend && npm start`; free port 5173 |
| Settings save returns 404 | Key not defined in `config.sh` | Add `export KEY=value` to `config.sh` |
| Backtest files land in `/Users/P3291917/...` | Hard-coded default | Set `BACKTEST_OUTPUT_DIR` (backend reads it too) |
| Stale regime result | 15-minute cache | `clear_regime_cache` or set `REGIME_CACHE_DIR` |
| Regime is `unknown` / `available: false` | No closes passed and no synthetic opt-in | Pass ≥ 20 closes: `detect_market_regime SYM 30 $CLOSES` |
| `ml_error: timeout_or_failure` in v2 output | Predictor took longer than `ML_TIMEOUT_SECONDS` (library default 5; the agent's template sets 15) | Raise `ML_TIMEOUT_SECONDS`; check `ml_predictor.sh status` |
| `KILL SWITCH ACTIVE since <ts>: <reason>. No new orders.` | `--halt` was run (file `$SST_STATE_DIR/KILL_SWITCH`) | Check `--safety-status`; `--resume` when it is safe |
| `Order blocked: quantity … exceeds MAX_ORDER_QTY` / `notional … MAX_ORDER_NOTIONAL` / `today's buy notional … MAX_DAILY_NOTIONAL` / `… MAX_OPEN_POSITIONS` | A cap in `config.template.sh` "Live safety" | Smaller order, or raise the cap deliberately in `config.sh` (`export MAX_…=`) |
| `Order blocked: sell … exceeds the held position` | Sell more than you hold (no short selling) | Sell ≤ the position (`--view-positions`) |
| `DAILY LOSS HALT: equity is down …` | Equity below `last_equity` by ≥ the daily loss limit | Buys resume the next trading day; sells are allowed; see `DAILY_LOSS_LIMIT_PCT` |
| `Order blocked: duplicate …` | Same symbol + side placed by the agent within `DUPLICATE_ORDER_WINDOW_SECONDS`, or an open broker order exists | Wait, or cancel the open order at the broker |
| `RECONCILIATION (alpaca): NO BASELINE` / `MISMATCH`, `Order refused: broker state does not match …` | Positions or open orders that the baseline + ledger do not explain (first run, trades made outside the agent) | `--reconcile` to review; `--reconcile-accept` to adopt; `--allow-mismatch` for one order |
| `Order blocked: the market is closed …` / `market holiday …` / `market clock unavailable (fail closed)` | Alpaca clock says closed, or the clock could not be read | Order during market hours, or `OUTSIDE_HOURS_POLICY=queue` |
| `PDT WARNING: equity $… is below $25000 …` | Possible same-day round trip on a small account | Warning only; avoid more than 3 day trades in 5 business days |
| `LIVE endpoint (…): orders need --live and a typed confirmation` | Endpoint is not paper/local (or Robinhood) | Add `--live` and type `SYMBOL QTY`, only if you mean real money |
| `LIVE endpoint refused: config.sh is tracked in git …` | Live URL/keys in a tracked config file | Restore `config.sh` to paper; put live keys in an untracked `config.live.sh` and use `SST_CONFIG_FILE` |
| `Order lock busy` | Another order is being submitted (lock < 120 s old) | Wait; a stale lock is removed after 120 s |
| `order outcome unknown` | Timeout/5xx and the client order id lookup found nothing | Check open orders at the broker before retrying; the ledger line is `unknown` (counts as active) |

### Debug Mode

```bash
./StockSwingTrader_Agent.sh --symbols AAPL --debug
tail -f logs/agent.log

DEBUG_BACKTEST=true bash -c 'source lib/backtest.sh; backtest_strategy AAPL 2023-01-01 2023-12-31'

python3 -c "import joblib; m = joblib.load('lib/models/xgboost_predictor.pkl'); print(type(m))"
```

---

## Future Enhancement Ideas

None of these exist in the code yet.

**Fix first:** the open known issues above (missing `regime_adaptive.sh`/`dashboard.sh`, real price data for the regime detector, backend sub-commands, `--watchlist` on bash 3.2, configurable paths, ML batch parsing, `VERSION` file).

**Deferred from live-safety Step 1:** feed the ML predictor the CLI's own bars (it still fetches via yfinance); the SMA200 term (needs > 200 bars); writing `logs/trades.json` from the CLI; cancel/replace of bracket legs before a sell (only warned); Robinhood brackets, clock and reconciliation; auto-execution; `--watchlist` on bash 3.2.

**Short-term:** real market data for the agent and regime detector; training on real data with a CLI; grid search and stops in the backtester; WebSocket updates instead of polling (`ws` is already a backend dependency but unused).

**Medium-term:** model ensembles or sequence models; walk-forward and Monte Carlo backtests; more sentiment sources; paper-trading auto-execution with P&L tracking (on top of `place_guarded_order`); portfolio-level risk (correlation, VaR).

**Long-term:** other asset classes, reinforcement learning, service split/scaling, notification integrations (Slack/Telegram/email).

---

## Deployment & Versioning

**v6.3 adds:** ML predictor, regime detection and weighting, React dashboard + Express backend, backtesting module, Kalman filter. **Live-safety Step 1** (`4c621fb`, `daf1bca`, `5a7abc0`; `VERSION` unchanged): v2 scoring in the CLI with a real OBV score and score breakdown in reports; Alpaca limit/bracket orders with client order ids; order safety (caps, kill switch, loss halt, duplicate guard, reconciliation, market hours, PDT warning, live guard, alerts).

**Earlier versions (from project docs, not re-verified):** v6.2 Robinhood integration; v6.1 backend API; v6.0 Alpaca broker support.

### How to Check Version

```bash
./StockSwingTrader_Agent.sh --version     # VERSION: 6.3
grep '^VERSION=' StockSwingTrader_Agent.sh
cat VERSION                               # still says v6.2 (not updated)
```

### Deployment Package Contents (`DEPLOYMENT_PACKAGE/`)

```
DEPLOYMENT_PACKAGE/
├── StockSwingTrader_Agent.sh        Main executable (same as repo root)
├── config.template.sh               Configuration template
├── requirements.txt
├── setup-alpaca.sh, setup-robinhood.sh
├── README.md, INSTALLATION.md, ARCHITECTURE.md, FEATURES.md,
│   SETUP_WIZARDS.md, VERSION_HISTORY.md, PACKAGE_MANIFEST.txt, STEERING_GUIDE.md
├── .kiro/steering/stockswingtrader-v6.3.md   (this guide)
├── .gitignore                       includes .state/ and config.live.sh
├── lib/                             25 modules + models/: Step 1 synced the agent, config.template.sh,
│                                    scoring.sh, html_report.sh, alpaca_broker.sh, alpaca_wrappers.sh,
│                                    order_safety.sh, alerts.sh, risk_management.sh, trade_journal.sh,
│                                    trading_thresholds.sh (byte-identical to the repo). Still missing:
│                                    indicators_new.sh, robinhood_oauth.sh, robinhood_mcp_direct.sh
├── backend/                         server.js, start.sh, package.json
├── frontend/                        src/, vite.config.ts, package.json
└── docs/                            KALMAN_FILTER_GUIDE.md, ROBINHOOD_SETUP.md,
                                     ALPACA_SETUP_GUIDE.html, STEERING_GUIDE.md,
                                     STEERING_DEPLOYMENT_SUMMARY.txt
```

There is no `tests/` directory and no `config.sh` in the package (create one from `config.template.sh`; keep it on paper). `trading_thresholds.sh` is now included, so the regime and strategy modules get their threshold constants. `--broker robinhood` fails to load in the package because `robinhood_oauth.sh` is missing.

---

## Appendix: File Reference

```
StockSwingTrader-v6.3/
├── StockSwingTrader_Agent.sh         Main agent
├── config.template.sh                Configuration template (tracked)
├── config.sh                         Private config, TRACKED (private repo): Alpaca paper, Finnhub, NewsAPI keys
├── config.robinhood.sh, config.live.sh   Untracked (gitignored); live keys only in config.live.sh
├── .state/                           Gitignored: orders.jsonl, positions_baseline.json, KILL_SWITCH, order.lock
├── requirements.txt                  Python dependencies
├── VERSION                           Says v6.2 (stale)
├── lib/
│   ├── indicators.sh, indicators_new.sh
│   ├── kalman_filter.sh, kalman_inference.py
│   ├── regime_detector.sh, regime_weighting.sh, trading_thresholds.sh
│   ├── ml_predictor.sh, ml_inference.py, train_ml_model.py
│   ├── models/xgboost_predictor.pkl  (git-ignored)
│   ├── strategy_mean_reversion.sh, strategy_trend_follow.sh
│   ├── scoring.sh, sentiment.sh, risk_management.sh, trade_journal.sh
│   ├── backtest.sh, backtest_engine.py
│   ├── kelly_sizing.sh, mirofish_adapter.sh
│   ├── order_safety.sh, alerts.sh   (live-safety Step 1)
│   ├── alpaca_broker.sh, alpaca_wrappers.sh
│   ├── robinhood_broker.sh, robinhood_oauth.sh, robinhood_mcp_direct.sh
│   └── html_report.sh
├── backend/      server.js, start.sh, package.json
├── frontend/     src/{App.tsx,pages,hooks,utils,components}, vite.config.ts, package.json
├── docs/         STEERING_GUIDE.md (this file), KALMAN_FILTER_GUIDE.md, ROBINHOOD_SETUP.md,
│                 ALPACA_SETUP_GUIDE.html, STEERING_DEPLOYMENT_SUMMARY.txt
├── examples/     ml_scoring_integration_example.sh
├── tests/        test_runner.sh + 18 registered suites (see Testing), broker tests, mock_data.json,
│                 stubs/yfinance_{empty,error,fixture}/ (offline yfinance stand-ins),
│                 stubs/alpaca_stub_server.py (local Alpaca API stand-in, 127.0.0.1)
├── logs/         agent.log, alerts.log, trades.json and broker logs (git-ignored)
└── .agents/tasks/test-report.md      Written by tests/test_runner.sh
```

Copies of this guide that must stay identical: `docs/STEERING_GUIDE.md` (canonical), `DEPLOYMENT_PACKAGE/docs/STEERING_GUIDE.md`, `DEPLOYMENT_PACKAGE/STEERING_GUIDE.md`, `DEPLOYMENT_PACKAGE/.kiro/steering/stockswingtrader-v6.3.md`, and the workspace steering file `.kiro/steering/stockswingtrader-v6.3.md`.

---

**Document Last Updated:** 2026-10-31 (live-safety Step 1)  
**For:** StockSwingTrader v6.3 (commit `5a7abc0`)
