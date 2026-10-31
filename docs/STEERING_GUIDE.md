# StockSwingTrader v6.3 Steering Guide
## Code-Verified Reference for AI-Assisted Development

**Version:** 6.3 (`VERSION="6.3"` in `StockSwingTrader_Agent.sh`; the separate `VERSION` file still says v6.2)  
**Last Updated:** 2026-10-31  
**Verified against:** commit `532828e` on `main`; the data-source rules ([Data Sources & Synthetic Data](#data-sources--synthetic-data)) and the sections that reference them were re-verified after the no-fake-data change  
**Purpose:** Accurate guide for future AI agents to understand, enhance, and maintain the codebase. Every command, function, path, port, weight and threshold below was checked against the code. Where the code does not do something, this guide says so.

> Not financial advice. The ML model is trained on synthetic data (every prediction says `"model_training_data": "synthetic"`). Synthetic prices/features are used only on explicit opt-in (`SST_OFFLINE=1`, `SST_ALLOW_SYNTHETIC=1`, `--synthetic`) and are then marked `"data_source": "synthetic"`. Paper-trade only.

---

## Table of Contents
1. [Current State at a Glance](#current-state-at-a-glance)
   - [Data Sources & Synthetic Data](#data-sources--synthetic-data)
2. [Architecture Overview](#architecture-overview)
3. [Module Structure](#module-structure)
4. [Data Flow & Pipeline](#data-flow--pipeline)
5. [Enhancement Modules](#enhancement-modules)
6. [Scoring Pipeline Integration](#scoring-pipeline-integration)
7. [Main Agent Flags](#main-agent-flags)
8. [Setup & Configuration](#setup--configuration)
9. [Development Guidelines](#development-guidelines)
10. [Testing](#testing)
11. [Troubleshooting](#troubleshooting)
12. [Future Enhancement Ideas](#future-enhancement-ideas)
13. [Deployment & Versioning](#deployment--versioning)
14. [Appendix: File Reference](#appendix-file-reference)

---

## Current State at a Glance

The v6.3 enhancement modules work when you call them directly (sourced as libraries or run as scripts). The main agent does **not** yet run them. Known issues at `532828e`, observed by running the commands:

1. **Path bug.** `lib/scoring.sh` line 16 sets `SCRIPT_DIR` to `lib/`. The agent sources `scoring.sh`, so every later `$SCRIPT_DIR/lib/...` lookup becomes `lib/lib/...`. Effects:
   - *(Fixed: the agent now sources `html_report.sh` via `AGENT_DIR`, so the HTML report is written.)*
   - `--ml` and `--kalman` log "module not found" and are skipped.
   - `--backtest` exits 1 with `Backtest module not found: …/lib/lib/backtest.sh`.
   - Broker flags (`--check-account`, `--view-positions`, `--buy`, `--sell`) fail to load the broker module.
2. **Missing modules.** `--regime-adapt` looks for `lib/regime_adaptive.sh` and `--dashboard` looks for `lib/dashboard.sh`. Neither exists. The real regime modules are `lib/regime_detector.sh` and `lib/regime_weighting.sh`; there is no dashboard launcher.
3. **Scoring not wired in.** The CLI always calls the legacy `calculate_confluence_score` (80% technical average, 20% sentiment). The ML/regime/Kalman engine `calculate_confluence_score_v2` (15/35/30/20) is only called by tests and `examples/ml_scoring_integration_example.sh`.
4. *(Fixed.)* **Demo data.** `fetch_stock_ohlcv` now fetches 60 daily bars from yfinance (`"data_source":"yfinance"`). The random demo series is generated only on the synthetic opt-in and is marked `"data_source":"synthetic"`. Without data and without the opt-in the symbol is skipped; with 0 symbols analyzed the CLI exits 1 and writes no report (it used to count log lines as an analysis and print "Analysis Complete!").
5. **Wrong help example.** `--backtest AAPL 2022-01-01 2024-01-01` (in `--help` and the script header) is rejected: `Unknown option: 2022-01-01`, exit 1. Dates go in `--start` / `--end`.
6. **bash 3.2.** `--watchlist` uses `mapfile` (bash 4+). macOS `/bin/bash` 3.2 prints `mapfile: command not found` and analyzes 0 stocks.
7. **Backend gaps.** `/api/signals`, `/api/quotes`, `/api/indicators`, `/api/stats` and `/api/portfolio` call lib scripts with sub-commands those scripts do not implement, so they return HTTP 200 with `{"raw": ""}`. Dashboard score and price panels stay empty.
8. **Machine-specific paths.** Backtest output, backend log and ML training report default to `/Users/P3291917/Builds/6/.agents/tasks/...`. Override with `BACKTEST_OUTPUT_DIR` and `SST_LOG_FILE` (the training report path has no override).
9. **ML batch.** `ml_predictor.sh batch '["AAPL", "MSFT"]' 5` returns only the first symbol.

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
| Agent `fetch_stock_ohlcv` / `score_stock` | `data_source: "yfinance"` | symbol skipped; CLI exits 1 if none analyzed | `data_source: "synthetic"`, `data_warning`; HTML report banner |
| Backend `/api/backtest` | each result has `data_source`, `synthetic` (`unknown` for files without the field) | — | `synthetic: true` |
| Dashboard | — | Analysis: "ML prediction unavailable … zero weight" | alert + "synthetic" badge (Dashboard, Analysis); Trade History labels each backtest `Data: …` and warns on `synthetic` / `unknown` |

Still not real data (not fixed by this change): OBV score in `score_stock` is a constant 50; the XGBoost model is trained on synthetic samples (`train_ml_model.py`). With no live quote, the Bollinger score now uses the series' last close instead of price 0 (which always scored 100).

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
    │  CLI today: calculate_confluence_score             │
    │    80% technical avg + 20% sentiment               │
    │  Library/tests: calculate_confluence_score_v2      │
    │    15% ML + 35% regime + 30% technical             │
    │    + 20% volume/trend                              │
    └───┬──────────────────────────────────────────────┬─┘
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
├── config.template.sh          (always sourced; config.sh is NOT sourced by the agent)
├── lib/indicators.sh           RSI, MACD, Bollinger, ATR, OBV, Stochastic, Williams %R, SMA, EMA
├── lib/sentiment.sh            Twitter/Reddit/StockTwits placeholders (randomised)
├── lib/scoring.sh              Indicator scores + confluence (resets SCRIPT_DIR, see issue 1)
│   ├── lib/ml_predictor.sh  ── lib/ml_inference.py ── lib/models/xgboost_predictor.pkl
│   ├── lib/regime_weighting.sh
│   │   ├── lib/regime_detector.sh
│   │   │   ├── lib/indicators.sh
│   │   │   ├── lib/trading_thresholds.sh
│   │   │   └── lib/kalman_filter.sh
│   │   └── lib/trading_thresholds.sh
│   └── lib/kalman_filter.sh ── lib/kalman_inference.py
├── lib/html_report.sh          generate_html_report (not found at runtime, issue 1)
├── lib/backtest.sh  ── lib/backtest_engine.py      (--backtest; not found at runtime, issue 1)
├── lib/alpaca_broker.sh | lib/robinhood_broker.sh   (--broker; loaded after arg parsing)
│
│ Not sourced by the agent:
├── lib/strategy_mean_reversion.sh, lib/strategy_trend_follow.sh
│   └── lib/trading_thresholds.sh, risk_management.sh, trade_journal.sh, alpaca_wrappers.sh
├── lib/train_ml_model.py       (run manually)
└── backend/server.js + frontend/  (started manually with npm)
```

---

## Module Structure

### Core Modules (function names verified with `grep '^name()'`)

| Module | File | Language | Key Functions / Entry Points |
|--------|------|----------|------------------------------|
| Main Agent | `StockSwingTrader_Agent.sh` | Bash | `main`, `usage`, `display_version`, `analyze_stock`, `fetch_stock_ohlcv`, `calculate_all_indicators`, `score_stock`, `generate_report`, `init_ml_predictor`, `init_regime_adaptive`, `init_kalman_filter`, `init_dashboard`, `init_all_enhancements`, `load_broker_module` |
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
| Scoring | `lib/scoring.sh` | Bash | `score_rsi`, `score_macd`, `score_bollinger_bands`, `score_stochastic`, `score_williams_r`, `score_obv`, `calculate_confluence_score`, `calculate_confluence_score_v2`, `calc_stop_loss_atr`, `calc_stop_loss_percent`, `calc_take_profit`, `calc_risk_reward_ratio`, `generate_score_summary` |
| Sentiment | `lib/sentiment.sh` | Bash | `parse_twitter_sentiment`, `parse_reddit_sentiment`, `parse_stocktwits_sentiment`, `analyze_news_sentiment`, `aggregate_sentiment`, `sentiment_to_confidence` |
| Risk Management | `lib/risk_management.sh` | Bash | `calculate_position_size`, `calculate_position_qty`, `enforce_stop_loss`, `enforce_take_profit`, `check_max_positions`, `enforce_daily_drawdown_limit`, `monitor_all_positions`, `rebalance_check` |
| Trade Journal | `lib/trade_journal.sh` | Bash | `log_trade_entry`, `close_trade`, `query_trade_journal`, `show_journal`, `export_backtest_data`, `get_strategy_stats` |
| Backtesting | `lib/backtest.sh` | Bash | `backtest_strategy`, `backtest_multi_symbol`, `run_backtest_engine`, `generate_backtest_reports`, `generate_portfolio_summary` (library only, no CLI) |
| Backtest Engine | `lib/backtest_engine.py` | Python | `DataFetcher`, `Indicators`, `MeanReversionStrategy`, `TrendFollowStrategy`, `BacktestEngine`; CLI: `backtest_engine.py CONFIG_JSON` |
| Alpaca Broker | `lib/alpaca_broker.sh` (+ `lib/alpaca_wrappers.sh`) | Bash | `alpaca_init`, `alpaca_get_account`, `alpaca_get_positions`, `alpaca_place_order`, `alpaca_get_order_status`, `alpaca_cancel_order` |
| Robinhood Broker | `lib/robinhood_broker.sh` (+ `robinhood_oauth.sh`, `robinhood_mcp_direct.sh`) | Bash | `robinhood_init`, `robinhood_get_account`, `robinhood_get_positions`, `robinhood_place_order`, `robinhood_get_quote` |
| Reports | `lib/html_report.sh` | Bash | `generate_html_report JSON OUTPUT_FILE` |
| Backend API | `backend/server.js` | Node.js/Express | `/api/health`, `/api/portfolio`, `/api/quotes/:symbol`, `/api/signals/:symbol`, `/api/indicators/:symbol`, `/api/trades`, `/api/stats`, `GET`/`POST /api/settings`, `/api/backtest` |
| Frontend UI | `frontend/src/` | React + TypeScript | Pages: `Dashboard`, `Analysis`, `TradeHistory`, `Watchlist`, `Settings`, `NotFound` |

---

## Data Flow & Pipeline

### What the CLI actually runs today (`--symbols`)

```
Input: --symbols AAPL,MSFT  (or --top-10, --watchlist FILE, or DEFAULT_WATCHLIST)
   │
   ├─▶ fetch_stock_ohlcv       60 daily bars from yfinance (data_source "yfinance");
   │                           random demo bars only on the synthetic opt-in
   │                           (data_source "synthetic"); otherwise skip symbol
   ├─▶ calculate_all_indicators
   │     needs ≥ 30 closes; RSI(14), MACD, Bollinger(20,2), Stochastic(14),
   │     Williams %R(14), ATR(14), OBV
   ├─▶ score_stock
   │     score_rsi / score_macd / score_bollinger_bands / score_stochastic /
   │     score_williams_r ; OBV fixed at 50 ; aggregate_sentiment (news or null)
   │     fetch_current_price (Yahoo quoteSummary via curl, for Bollinger score;
   │     falls back to the series' last close); data_source / data_warning
   ├─▶ calculate_confluence_score (legacy)
   │     technical_avg = mean of 6 indicator scores
   │     final = technical_avg × 0.8 + sentiment × 0.2
   ├─▶ sleep 0.5 between symbols
   └─▶ generate_report → generate_html_report (SYNTHETIC DATA banner when any
         analysis has data_source "synthetic")
```

ML, regime and Kalman are **not** in this path (issues 1–3).

### Library pipeline (`calculate_confluence_score_v2`, used by tests/examples)

```
Inputs: symbol, rsi_score, macd_score, bb_score, obv_score, regime,
        [mr_score=50], [tf_score=50], [kalman_trend=-1|0|1, default 0]
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
   └─▶ recommendation (see Signal Classification)
```

The library pipeline has no sentiment adjustment, no stop-loss/target output and no risk-management step. Stop/target helpers exist separately in `lib/scoring.sh` (`calc_stop_loss_atr`, default multiplier 2; `calc_stop_loss_percent`, default 5%; `calc_take_profit`, default 8%; `calc_risk_reward_ratio`).

### Signal Classification

**Legacy `calculate_confluence_score` (used by the CLI):**

| Final confidence | Signal |
|---|---|
| ≥ 75 | `STRONG_BUY` |
| ≥ 60 | `BUY` |
| ≥ 40 | `HOLD` |
| ≥ 25 | `SELL` |
| < 25 | `STRONG_SELL` |

**`calculate_confluence_score_v2`:** each component votes bullish or bearish. ML votes when confidence > 60 (direction up/down). Regime, technical and volume/trend vote bullish when > 60 and bearish when < 40. `signal_strength` = number of voting components (0–4).

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
1. Feed real prices into `detect_market_regime_kalman` and pass its trend into `calculate_confluence_score_v2` as `kalman_trend`.
2. Adaptive q/r based on residual volatility (future idea).
3. Multi-timeframe filtering (future idea).
4. Test: `bash tests/test_kalman_filter.sh`.

---

## Scoring Pipeline Integration

See [Data Flow & Pipeline](#data-flow--pipeline) for both formulas. Summary:

```
Legacy (CLI):  final = mean(rsi, macd, bb, stoch, williams, obv) × 0.8 + sentiment × 0.2

v2 (library):  confluence = ML × 0.15 + RegimeWeighted × 0.35 + Technical × 0.30 + VolumeTrend × 0.20
  ML           ml_predictor confidence (50–100), or 50 on error/timeout
  Regime       sideways 70/30, trending 30/70, volatile 50/50 × 0.8 (MR/TF)
  Technical    (rsi + macd + bb) / 3
  VolumeTrend  OBV blended with Kalman trend (75 up / 25 down, 20% weight)
```

To wire v2 into the CLI: fix `SCRIPT_DIR` in `lib/scoring.sh` (use a local variable), compute MR/TF scores, regime and Kalman trend in `analyze_stock`, then call `calculate_confluence_score_v2` instead of `calculate_confluence_score`.

---

## Main Agent Flags

From the `case` parser in `main()` and `./StockSwingTrader_Agent.sh --help`:

| Flag | Effect | Works at `532828e`? |
|---|---|---|
| `--symbols A,B` | Analyze listed symbols | Runs on yfinance data; exits 1 if no symbol had data (synthetic only on opt-in) |
| `--watchlist FILE` | Symbols from file | Needs bash 4 (issue 6) |
| `--top-10` | Fixed list `AAPL MSFT GOOGL AMZN TSLA META NFLX CRM ADBE NVDA` | Same as `--symbols` |
| `--output-dir DIR` | Report directory (default `output/reports`) | — |
| `--debug` | `DEBUG_MODE=true` | Yes |
| `--version` | Print version/features | Yes |
| `--help` | Usage | Yes |
| `--ml` | Source `lib/ml_predictor.sh` | Skipped (issue 1) |
| `--regime-adapt` | Source `lib/regime_adaptive.sh` | Skipped, file missing (issue 2) |
| `--kalman` | Source `lib/kalman_filter.sh` | Skipped (issue 1) |
| `--dashboard` | Source `lib/dashboard.sh`, call `start_dashboard_servers` | Skipped, file missing (issue 2) |
| `--full` | `--ml --regime-adapt --kalman --dashboard` | Same as above |
| `--broker alpaca\|robinhood` | Broker choice (default `alpaca`) | — |
| `--check-account`, `--view-positions` | Broker account/positions | Module not found (issue 1) |
| `--buy SYMBOL QTY`, `--sell SYMBOL QTY` | Place order with confirmation | Module not found (issue 1) |
| `--alpaca`, `--place-buy`, `--place-sell`, `--alpaca-status` | Deprecated Alpaca aliases | Same |
| `--backtest SYMBOLS` | Run `backtest_multi_symbol` | Yes (`AGENT_DIR`); non-zero exit without market data |
| `--start DATE`, `--end DATE` | Backtest dates (defaults: 2 years ago, today) | — |
| `--train-pct PCT` | Train split (default 80) | — |

Verified examples:

```bash
./StockSwingTrader_Agent.sh --help
./StockSwingTrader_Agent.sh --version
./StockSwingTrader_Agent.sh --symbols AAPL,MSFT --output-dir /tmp/sst_reports
./StockSwingTrader_Agent.sh --backtest AAPL --start 2023-01-01 --end 2023-12-31   # correct syntax; fails until issue 1 is fixed
```

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
- `config.template.sh` is tracked, has no secrets, and is the only config the agent sources. Its placeholder `API_KEY_ALPHA_VANTAGE`/`API_KEY_FINNHUB`/`API_KEY_NEWSAPI` values override anything exported earlier; Alpaca keys are read from the environment.
- `config.sh` and `config.robinhood.sh` are untracked (in `.gitignore`). Create yours with `cp config.template.sh config.sh` and fill in keys. The backend Settings API and the helper scripts (`RUN_TRADING.sh`, `CHECK_ACCOUNT.sh`, `CHECK_ORDERS.sh`) read `config.sh`.
- To edit `RISK_PER_TRADE`, `MIN_CONFLUENCE_SCORE` and `TRADING_ENABLED` from the dashboard, add `export` lines for them to `config.sh` first.

Environment variables used by the code: `LOG_FILE`, `DEBUG_MODE`, `BROKER_CHOICE`, `ML_TIMEOUT_SECONDS`, `SST_OFFLINE`, `SST_ALLOW_SYNTHETIC`, `REGIME_CACHE_DIR`, `BACKTEST_OUTPUT_DIR`, `DEBUG_BACKTEST`, `PORT`, `SST_BASE_PATH`, `SST_LOG_FILE`, `VITE_API_BASE_URL`.

---

## Development Guidelines

### Code Style & Conventions

1. **Bash:** `#!/bin/bash`, `set -o pipefail` (agent and `backtest.sh`), `UPPERCASE` globals, `lowercase_with_underscores` functions. Library files are sourced, so do not reassign shared globals such as `SCRIPT_DIR` at file scope (that is the cause of issue 1); use a file-specific name. Document functions with a comment block (description, args, returns, example). Remember macOS ships bash 3.2: avoid `mapfile`, associative arrays and `${var,,}`, or require bash 4 explicitly.
2. **Python:** PEP 8, type hints where practical, docstrings.
3. **JSON output:** modules print a JSON object on success and `{"error": "..."}` on failure (there is no common `status`/`code` envelope). Timestamps are ISO 8601 UTC (`date -u +%Y-%m-%dT%H:%M:%SZ`).
4. **Backend:** pass arguments as arrays to `execFile`; validate symbols and settings before use.

### Module Development Workflow

1. Create `lib/my_module.sh`, add a header and functions; if it should run as a script, add a `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` dispatcher like `lib/ml_predictor.sh`.
2. Integrate: `source "$SCRIPT_DIR/lib/my_module.sh"` in the agent, add a flag in the `case` parser in `main()`, document it in `usage()`.
3. Add a test script in `tests/` and register it in `tests/test_runner.sh` with `add_test "Name" "${SCRIPT_DIR}/test_my_module.sh"`.

### Goals (not measured)

These are targets, not verified benchmarks: under 5 s per symbol for the full pipeline, and modules that emit valid JSON, handle errors, time out external calls and are testable on their own.

---

## Testing

`bash tests/test_runner.sh` runs 14 suites offline (`SST_OFFLINE=1`) and writes `.agents/tasks/test-report.md`. Last verified result: **14 suites, 468/468 passing**.

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

`tests/test_no_fake_data.sh` covers the [data-source rules](#data-sources--synthetic-data). It sets `SST_OFFLINE=0` itself and simulates market data with yfinance stubs put first on `PYTHONPATH`: `tests/stubs/yfinance_empty` (no data), `tests/stubs/yfinance_error` (fetch raises) and `tests/stubs/yfinance_fixture` (deterministic real-shaped bars). No network is used.

Other test scripts not in the runner: `tests/test_alpaca_broker.sh`, `tests/test_robinhood_broker.sh`, `tests/test_regime_simple.sh`.

```bash
bash tests/test_runner.sh               # all 14 suites
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
| `WARNING: html_report.sh not found`, `lib/lib/...` in errors | `SCRIPT_DIR` reset in `lib/scoring.sh` | Known issue 1; call modules directly until fixed |
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
| `ml_error: timeout_or_failure` in v2 output | Predictor took longer than `ML_TIMEOUT_SECONDS` (default 5) | Raise `ML_TIMEOUT_SECONDS`; check `ml_predictor.sh status` |

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

**Fix first:** the nine known issues above (path bug, missing `regime_adaptive.sh`/`dashboard.sh`, wire `calculate_confluence_score_v2` into the CLI, real price data, backend sub-commands, `--watchlist` on bash 3.2, configurable paths, ML batch parsing, `VERSION` file).

**Short-term:** real market data for the agent and regime detector; training on real data with a CLI; grid search and stops in the backtester; WebSocket updates instead of polling (`ws` is already a backend dependency but unused).

**Medium-term:** model ensembles or sequence models; walk-forward and Monte Carlo backtests; real sentiment sources; paper-trading auto-execution with P&L tracking; portfolio-level risk (correlation, VaR).

**Long-term:** other asset classes, reinforcement learning, service split/scaling, notification integrations (Slack/Telegram/email).

---

## Deployment & Versioning

**v6.3 adds:** ML predictor, regime detection and weighting, React dashboard + Express backend, backtesting module, Kalman filter (all usable as modules; see known issues for CLI integration).

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
├── lib/                             18 core modules (no indicators_new.sh, trading_thresholds.sh,
│                                    alpaca_wrappers.sh, trade_journal.sh, robinhood_oauth.sh,
│                                    robinhood_mcp_direct.sh)
├── backend/                         server.js, start.sh, package.json
├── frontend/                        src/, vite.config.ts, package.json
└── docs/                            KALMAN_FILTER_GUIDE.md, ROBINHOOD_SETUP.md,
                                     ALPACA_SETUP_GUIDE.html, STEERING_GUIDE.md,
                                     STEERING_DEPLOYMENT_SUMMARY.txt
```

There is no `tests/` directory in the package. Because `trading_thresholds.sh` is missing there, regime and strategy modules in the package run without their threshold constants.

---

## Appendix: File Reference

```
StockSwingTrader-v6.3/
├── StockSwingTrader_Agent.sh         Main agent
├── config.template.sh                Configuration template (tracked)
├── config.sh, config.robinhood.sh    Private configs (untracked)
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
│   ├── alpaca_broker.sh, alpaca_wrappers.sh
│   ├── robinhood_broker.sh, robinhood_oauth.sh, robinhood_mcp_direct.sh
│   └── html_report.sh
├── backend/      server.js, start.sh, package.json
├── frontend/     src/{App.tsx,pages,hooks,utils,components}, vite.config.ts, package.json
├── docs/         STEERING_GUIDE.md (this file), KALMAN_FILTER_GUIDE.md, ROBINHOOD_SETUP.md,
│                 ALPACA_SETUP_GUIDE.html, STEERING_DEPLOYMENT_SUMMARY.txt
├── examples/     ml_scoring_integration_example.sh
├── tests/        test_runner.sh + 14 registered suites (see Testing), broker tests, mock_data.json,
│                 stubs/yfinance_{empty,error,fixture}/ (offline yfinance stand-ins)
├── logs/         agent.log and broker logs (git-ignored)
└── .agents/tasks/test-report.md      Written by tests/test_runner.sh
```

Copies of this guide that must stay identical: `docs/STEERING_GUIDE.md` (canonical), `DEPLOYMENT_PACKAGE/docs/STEERING_GUIDE.md`, `DEPLOYMENT_PACKAGE/STEERING_GUIDE.md`, `DEPLOYMENT_PACKAGE/.kiro/steering/stockswingtrader-v6.3.md`, and the workspace steering file `.kiro/steering/stockswingtrader-v6.3.md`.

---

**Document Last Updated:** 2026-10-30  
**For:** StockSwingTrader v6.3 (commit `532828e`)
