# StockSwingTrader v6.3 Steering Guide
## Code-Verified Reference for AI-Assisted Development

**Version:** 6.3 (`VERSION="6.3"` in `StockSwingTrader_Agent.sh`; the separate `VERSION` file still says v6.2)  
**Last Updated:** 2026-11-01 (agent layer Phase 0-2: Quant Research Agent)  
**Verified against:** commit `75ea040` on `main`, re-checked at `26c44ba` (config.sh untracked, docs/guides added) (agent layer Phase 0-2: `agents/` Python package incl. `agents/quant/` (Qlib) and `agents/signals/quant.py`, `lib/agent_adapter.sh`, Technical, Strategy Validation and Quant Research agents). The quant parts ([Quant Research Agent](#quant-research-agent-phase-2) and the quant rows elsewhere) were checked at `75ea040`; the other agent-layer parts ([Agent Layer](#agent-layer-phase-0-1), agent rows in [Current State](#current-state-at-a-glance), [Data Sources](#data-sources--synthetic-data), [Module Structure](#module-structure), [Setup & Configuration](#setup--configuration), [Testing](#testing), [Troubleshooting](#troubleshooting)) at `d626d6b` and re-checked where Phase 2 touched them. Step 1 sections were verified at `5a7abc0`; earlier sections at `532828e`.  
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
   - [Agent Layer (Phase 0-1)](#agent-layer-phase-0-1)
   - [Quant Research Agent (Phase 2)](#quant-research-agent-phase-2)
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
11. **Scan stochastic / Williams %R get closes only** (pre-existing, unchanged). `calculate_all_indicators` passes the closes, not high/low/close triples, to `calc_stochastic` / `calc_williams_r`, so %K can leave 0..100 (a negative %K is then dropped by the grep extraction and `score_stochastic('')` gives 12). These two scores do not feed v2; changing them would change legacy output, so the quirk is kept and ported as-is by `agents/technical/bash_compat.py`.
12. **bash MACD signal == MACD line.** `calc_macd` returns signal = macd and histogram 0, so the scan's MACD score is always 50. The Technical agent uses the standard TA-Lib signal line; parity tests pin the bash behaviour.
13. **Regime ADX is an approximation.** `detect_market_regime` uses `min(100, |EMA20 − EMA50| × 10)`. The Technical agent computes a real ADX14 (`regime_adx`, same rules); the scan uses it only with `AGENTS_ENABLED=true AGENT_TECHNICAL_ENABLED=true` and an OK agent cache (see [Agent Layer](#agent-layer-phase-0-1)). Default: unchanged.

**Agent layer (Phase 0-1, `0d945a6`..`d626d6b`).** A separate Python 3.12 package `agents/` (own venv `.venv-agents`) adds a Technical agent (TA-Lib features, real-ADX regime) and a Strategy Validation agent (vectorbt walk-forward, DSR, PBO, gates). The bash scan never runs Python; it reads the agents' cache through `lib/agent_adapter.sh`. Agents are off by default (`AGENTS_ENABLED=false`): v2 output is byte-identical to `970af57`; with `AGENTS_ENABLED=true` and all weights 0 only a `components.agents` shadow block is added. The real Phase 1 gate run (Alpaca SIP bars, 2016 → last session) is in `.agents/tasks/phase1-gate-report.md` (outside the repo); see [Agent Layer](#agent-layer-phase-0-1) for the result. Fundamental, Market and Portfolio agents are not implemented (`run` exits 1 `not_implemented`; `quant run` too, the quant agent uses its own commands).

**Quant Research Agent (Phase 2, `afd07d5`..`75ea040`, `agents.__version__` 0.2.0).** `agents/quant/` trains Microsoft Qlib models (LightGBM on Alpha158 + the 14 legacy ML features; XGBoost baselines) on a fixed 153-stock universe of Alpaca SIP daily bars (2016 → last session), writes nightly rank envelopes `cache/agents/quant/<as_of>/<SYM>.json` and evaluates them (IC, three walk-forward gates, go/no-go). Real run 2026-11-01: **NO-GO**. LightGBM OOS Rank-IC 0.0087 (Newey-West t 1.95; needs ≥ 0.02 and ≥ 2); all three gates (`xgb_topk`, `quant_topk`, `quant_rank`) failed; `quant_topk` beat `xgb_topk` in 42.9 % of folds (needs 60 %). Consequence: `AGENT_QUANT_WEIGHT` stays 0 (default in `config.template.sh`), no weight is proposed, `lib/ml_predictor.sh` and `lib/models/` are unchanged. The bash scan is unchanged (it only reads the cache; the quant weight cannot apply until the `quant_rank` gate passes). Details: [Quant Research Agent (Phase 2)](#quant-research-agent-phase-2); full report `.agents/tasks/phase2-quant-report.md` / `.html` (outside the repo).

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
| Agent layer bars (`agents.data.load_bars`) | Alpaca `GET /v2/stocks/bars` (1Day, `adjustment=all`, feed `sip`, end clamped to now − 20 min; 403 → one retry with `iex`): `data_source` `alpaca:sip` / `alpaca:iex`. Rejected as stale when the newest bar is more than `AGENT_MAX_BAR_STALENESS_DAYS` (3) business days before the expected last session | `Unavailable(reason)`; agents write `available: false` envelopes; `validate gate` exits 2 `market_data_unavailable` and writes no gate | Offline (`SST_OFFLINE=1` / `--offline`): generated fixtures `tests/fixtures/agents/bars/` (AAA, BBB, CCC, SPY), `data_source: "fixture"`, `synthetic: true` + warning. yfinance only with `AGENT_DATA_FALLBACK=yfinance` (labeled `yfinance` + warning) |
| Agent envelopes (`cache/agents/<agent>/<date>/<SYM>.json`) | `data_sources`, `synthetic: false` | `available: false`, score/direction/confidence null, reason | `synthetic: true` + `warning`; the adapter gives them weight 0 unless `SST_OFFLINE=1` |
| Validation gates (`cache/agents/gates/<signal>.json`) | `data_sources` list (`alpaca:*`), `passed` per criteria | no gate written (exit 2) | `synthetic: true`, `passed: false`, reason `synthetic_data` (a synthetic gate can never pass; the adapter reads it as `SYNTHETIC`) |
| Quant raw store (`cache/agents/quant/raw/<SYM>.csv` + `.meta.json`) | Alpaca bars with `vwap` (`include_vwap=True`), meta `data_source` `alpaca:sip` / `alpaca:iex`, `synthetic: false` | symbol listed in `unavailable` (e.g. `stale_data`); `quant ingest` exits 2 `market_data_unavailable` when no rank symbol has bars (store untouched) | Offline: fixtures QAA..QLL + SPY, meta `data_source: "fixture"`, `adjustment: "fixture"`, `synthetic: true` + warning |
| Quant Qlib store (`cache/agents/quant/qlib_data/`, `store_meta.json`) | `data_sources` per symbol copied from the raw meta | `quant train` / `predict` exit 2 `store_unavailable` | `synthetic: true` in `store_meta.json`; train manifest `synthetic: true` + warning |
| Quant OOS predictions (`cache/agents/quant/predictions/<arm>.parquet`) | from the real store (manifest `mode: "real"`) | `validate gate` with quant signals exits 2 `quant_predictions_unavailable` | manifest `mode: "offline"`, `synthetic: true` |
| Quant envelopes (`cache/agents/quant/<as_of>/<SYM>.json`) | score = rank percentile, `data_sources` from the raw meta, `synthetic: false` | `available: false` with `not_in_quant_universe` / `no_features_at_as_of` / `stale_data` / `universe_too_small` | `synthetic: true` + warning (adapter weight 0 unless `SST_OFFLINE=1`) |
| Quant gates (`cache/agents/gates/{xgb_topk,quant_topk,quant_rank}.json`) and eval report (`cache/agents/quant/eval/<run_id>/`) | `data_sources` `alpaca:*`, `synthetic: false` | exit 2 (`quant_store_unavailable` / `quant_predictions_unavailable`), no gate written | `synthetic: true`, `passed: false`, go = false (`real_data` criterion), HTML SYNTHETIC banner |

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

    Agent layer (Phase 0-2, run by hand / nightly; the scan never runs Python):
    ┌──────────────────────────────┐  writes   ┌───────────────────────────┐
    │ python -m agents ...         │──────────▶│ cache/agents/             │
    │ (.venv-agents, Python 3.12)  │           │  technical/<date>/<SYM>   │
    │  technical: TA-Lib, ADX14    │           │  quant/<date>/<SYM>       │
    │  validate: vectorbt WF gate  │           │  quant/{raw,qlib_data,    │
    │  quant: Qlib + LightGBM /    │           │   models,predictions,     │
    │    XGBoost, IC, gates        │           │   mlruns,eval}/           │
    │  data: Alpaca bars GET only  │           │  gates/<signal>.json      │
    └──────────────────────────────┘           │  validate/ (reports, ...) │
                                               └─────────────┬─────────────┘
                                                             │ reads (jq, no network)
                                               ┌─────────────▼─────────────┐
                                               │ lib/agent_adapter.sh      │
                                               │ → scoring.sh (weights 0)  │
                                               │ → scan regime hook (opt-in)│
                                               └───────────────────────────┘
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
│   ├── lib/kalman_filter.sh ── lib/kalman_inference.py
│   ├── lib/mirofish_adapter.sh   (--mirofish cache reader)
│   └── lib/agent_adapter.sh      agent cache + gate reader (own dir var _AGENT_ADAPTER_LIB_DIR;
│                                 jq only, no network); also used by the scan regime hook
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
├── backend/server.js + frontend/  (started manually with npm)
└── agents/  (python -m agents, .venv-agents; run manually, writes cache/agents/)
    ├── cli.py, config.py (reads config.template.sh + config.sh via bash; assert_paper),
    │   envelope.py + schemas/, cache.py, fixtures.py, llm/ (NoneProvider default, $0 budget)
    ├── data/  alpaca.py (GET-only bars client) ── bars.py (load_bars) ── yf_fallback.py (opt-in)
    ├── technical/  talib_features.py, agent.py, bash_compat.py (exact port of the bash v2 scan)
    ├── signals/    v2_confluence (uses bash_compat), mean_reversion, trend_follow,
    │               quant.py (xgb_topk, quant_topk, quant_rank; read quant/predictions)
    ├── validate/   engine.py (vectorbt), walkforward, stats, benchmarks, trials, gate, report,
    │               universe, agent.py (also imports lib/backtest_engine.py for legacy parity)
    └── quant/      universe.py + universe.txt, raw.py (data/alpaca.py, include_vwap), store.py
                    (Qlib bin writer), legacy_features.py (imports lib/ml_inference.py by path),
                    qlib_env.py (init_qlib), handler.py, folds.py, train.py (qlib, lightgbm,
                    xgboost, mlflow), metrics.py, predict.py, evaluate.py (validate.agent.run_gate),
                    agent.py (CLI handlers)
```

---

## Module Structure

### Core Modules (function names verified with `grep '^name()'`)

| Module | File | Language | Key Functions / Entry Points |
|--------|------|----------|------------------------------|
| Main Agent | `StockSwingTrader_Agent.sh` | Bash | `main`, `usage`, `display_version`, `analyze_stock`, `fetch_stock_ohlcv`, `calculate_all_indicators`, `score_stock`, `generate_report`, `print_score_breakdown`, `init_ml_predictor`, `init_regime_adaptive`, `init_kalman_filter`, `init_dashboard`, `init_all_enhancements`, `load_broker_module`, `broker_connect`, `show_broker_account`, `show_broker_positions`, `validate_order_args`, `get_order_price`, `current_endpoint_mode` (sets `SST_ENDPOINT_MODE`; call without `$(...)`), `check_live_config_guard`, `order_prechecks`, `place_guarded_order`, `place_buy_order` / `place_sell_order` (thin wrappers), `startup_reconcile_warning`, `run_reconcile_command`, `apply_technical_agent_regime SYMBOL V2_INPUTS` (opt-in scan hook; echoes the input unchanged when disabled) |
| Agent Adapter | `lib/agent_adapter.sh` | Bash | `agent_cache_dir`, `agent_cache_file AGENT SYMBOL [DATE]`, `agent_get AGENT SYMBOL` (`DISABLED`/`MISSING`/`INVALID`/`STALE`/`UNAVAILABLE`/`OK`), `agent_gate_get SIGNAL` (`MISSING`/`INVALID`/`SYNTHETIC`/`EXPIRED`/`FAILED`/`PASSED`), `agent_effective_weight AGENT`, `agent_max_total_weight`, `agent_components_json SYMBOL` (used by `calculate_confluence_score_v2`). jq only, no network, no Python |
| Agents CLI | `agents/cli.py` (+ `__main__.py`) | Python 3.12 | `python -m agents <agent> <command>`; agents `market`, `fundamental`, `technical`, `quant`, `validate`, `portfolio`; commands `run`, `status`, `train`, `gate` (+ `validate parity`, `quant ingest|train|predict|evaluate|status`; options `--refresh`, `--arms`). Exit 0 ok, 1 error / `not_implemented`, 2 data unavailable. `HANDLERS` maps (agent, command) to a handler (looked up before the `COMMANDS` check) |
| Agents core | `agents/config.py`, `envelope.py`, `cache.py`, `fixtures.py`, `schemas/*.json` | Python | `load_config` (whitelisted keys, masked repr), `assert_paper`, `endpoint_mode`; `make_envelope`, `unavailable_envelope`, `validate_envelope`; `cache_root`, `cache_path`, `gate_path`, `atomic_write_json`, `write_envelope`; `load_fixture_bars` |
| Agents data | `agents/data/{alpaca,bars,yf_fallback}.py` | Python | `AlpacaBarsClient.fetch` (GET only, host whitelist, paper asserted, pagination, 403 sip → iex, stale rejection, disk cache), `expected_last_session`, `load_bars(symbols, start, end, as_of)` → `BarsResult` / `Unavailable` |
| Agents LLM | `agents/llm/{base,providers,budget}.py` | Python | `get_provider` (`LLM_PROVIDER` none (default) / fake / ollama / openai), `BudgetLedger` ($0 budget refuses paid calls before any HTTP request). Not used by any agent yet |
| Technical Agent | `agents/technical/{talib_features,agent,bash_compat}.py` | Python | `compute_features`, `compute_series` (RSI, EMA, SMA, MACD, Bollinger, ATR (Wilder), ADX14/DI, Stochastic, Williams %R, OBV, Donchian, `trend_state`, `regime_adx`); `run`, `cli_run`, `cli_status`; `bash_compat.v2_from_bars` (exact port of the bash v2 scan, quirks included) |
| Signals | `agents/signals/{base,mean_reversion,trend_follow,v2_confluence,quant}.py` | Python | `get_signals()` → `v2_confluence`, `v2_confluence_adx`, `mr_only`, `tf_only` (`SignalSpec.grid()`, `build(df, params, symbol)`); `get_signals(include_quant=True)` adds `xgb_topk`, `quant_topk`, `quant_rank` (`quant.py`: `predictions_file`, `load_ranks`, `percentiles`, `rebalance_dates`, `top_sets`, `topk_builder`, `compute_v2_core`, `v2_core`, `blend_recommendations`, `quant_rank_builder`) |
| Validation Agent | `agents/validate/{agent,engine,walkforward,stats,benchmarks,trials,gate,report,universe}.py` | Python | `run_gate` (also `bars_res=`, `include_parity=`), `run_parity`, `status`, `order_signals`, `quant_inputs`, `quant_gate_inputs`, `needed_arms`, `default_quant_symbols`; `gate_backtest` (opt-in `sizing` = slots), `legacy_parity_backtest`; `calendar_folds`, `bar_folds`; `sharpe`, `max_drawdown`, `cagr`, `psr`, `dsr`, `pbo_cscv`; `spy_buy_hold`, `equal_weight_buy_hold`; `n_trials`; `thresholds`, `evaluate_criteria`, `decide`, `write_gate`, `read_gates`; `render_html`, `write_report` |
| Quant Agent | `agents/quant/{universe,raw,store,legacy_features,qlib_env,handler,folds,train,metrics,predict,evaluate,agent}.py` + `universe.txt` | Python | `load_universe`, `rank_universe`, `benchmarks`, `all_symbols`; `ingest`, `load_raw`, `raw_status`, `read_meta`, `raw_dir`; `build_store`, `read_store_meta`, `store_dir`, `instrument_dirname`; `legacy_feature_frame`, `legacy_features_at`, `load_ml_inference`; `init_qlib`, `quiet`, `n_jobs`, `mlruns_dir`, `reset`; `make_handler`, `feature_count`; `Segment`, `yearly_folds`, `live_segment`, `bar_folds_offline`; `run_train`, `parse_arms`, `arm_params`, `read_latest`, `load_model`, `models_dir`, `predictions_dir`; `daily_ic`, `newey_west_t`, `naive_t`, `summarize_ic`, `per_year`, `topk_spread`, `quintile_spread`, `evaluate_arm`; `run_predict`, `rank_predictions`, `direction_for`, `gate_passed`, `ttl_hours`; `run_evaluate`, `go_decision`, `render_eval_html`, `write_eval_report`, `latest_evaluation`; `ingest_and_build`, `status`, `cli_ingest`, `cli_train`, `cli_predict`, `cli_evaluate`, `cli_status` |
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
- LIVE while the active config file (`SST_CONFIG_FILE`, default `config.sh`) is tracked in git → refused (`config.sh is tracked in git and must stay on paper …`; since `26c44ba` `config.sh` itself is untracked, so this only fires for a tracked file). Live keys go in an untracked file, e.g. `config.live.sh` (gitignored), selected with `SST_CONFIG_FILE=$PWD/config.live.sh … --live`.
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

## Agent Layer (Phase 0-1)

**Files:** `agents/` (Python 3.12 package), `requirements-agents.txt`, `lib/agent_adapter.sh`, the agent block in `config.template.sh`, the agents part of `calculate_confluence_score_v2` (`lib/scoring.sh`) and `apply_technical_agent_regime` (`StockSwingTrader_Agent.sh`). Commits `0d945a6`, `5e87e5d`, `fe1ce7a`, `b395530`, `bebc2ca`, `2d2fd71`, `d626d6b`. Phase 0-1 of `.agents/tasks/six-agent-integration-plan.md` (outside the repo): scaffold, Technical agent, Strategy Validation agent. No paid service, no LLM call ($0).

### Setup (own venv)

```bash
cd StockSwingTrader-v6.3
/opt/homebrew/bin/python3.12 -m venv .venv-agents      # gitignored
.venv-agents/bin/pip install -r requirements-agents.txt
.venv-agents/bin/pip check                             # "No broken requirements."
.venv-agents/bin/python -m agents status               # endpoint_mode PAPER, has_* booleans
```

Pins (`requirements-agents.txt`, all resolved on Python 3.12.12 arm64): vectorbt 1.2.0, numba 0.68.1, llvmlite 0.50.0, pandas 3.1.0, numpy 2.5.4, scipy 1.16.3, TA-Lib 0.8.3 (wheel, no brew `ta-lib` needed), jsonschema 4.26.0, requests 2.34.2. Phase 2 adds pyqlib, lightgbm, xgboost, mlflow, pyarrow, joblib, python-dateutil (see [Quant Research Agent](#quant-research-agent-phase-2)); later-phase pins (openbb, PyPortfolioOpt) are commented out; `openbb-yfinance` is never installed; yfinance is not in the venv. The repo `requirements.txt` does not install on 3.12; never use it for the agents. Run `python -m agents` from the repo root (the package is not installed). The first `import vectorbt` compiles numba (~30-40 s).

### CLI

| Command | Effect | Exit |
|---|---|---|
| `python -m agents status` | Version, venv python, `endpoint_mode` (PAPER/LOCAL/LIVE), `offline`, `agents_enabled`, `llm_provider`, `cache_dir`, `has_alpaca_api_key`, `has_alpaca_secret_key`, `has_api_key_finnhub`, `has_api_key_newsapi`, `has_fred_api_key`, `has_sec_user_agent` (booleans; never a value) | 0 |
| `python -m agents technical run --symbols AAPL,MSFT [--as-of DATE] [--offline]` | One envelope per symbol in `cache/agents/technical/<as_of>/<SYM>.json` (unavailable ones too, `available: false`) | 0 if ≥ 1 available, 2 none, 1 bad args |
| `python -m agents technical status` | Cache summary | 0 |
| `python -m agents validate gate [--signals ...] [--symbols ...] [--benchmark SPY] [--start 2016-01-01] [--end DATE] [--offline] [--report-dir DIR]` | Walk-forward gate per signal: `cache/agents/gates/<signal>.json` + `report.html` / `report.json` | 0 (also when the gate fails), 2 data unavailable (nothing written), 1 bad args |
| `python -m agents validate parity [--offline] [--symbols ...]` | vectorbt legacy mode vs `lib/backtest_engine.py` per symbol × {mean_reversion, trend_follow} | 0 match, 1 mismatch, 2 no data |
| `python -m agents validate status` | Gate files: `signal_id`, `passed`, `synthetic`, `age_days`, `data_sources`, `run_id`, `reasons` | 0 |
| `python -m agents quant\|fundamental\|market\|portfolio run` | Not implemented (the quant agent has its own `ingest`/`train`/`predict`/`evaluate`/`status` commands, see [Quant Research Agent](#quant-research-agent-phase-2)) | 1 `not_implemented` |

Config (`agents/config.py`): a bash subprocess sources `config.template.sh` then `${SST_CONFIG_FILE:-config.sh}` and returns only whitelisted names; non-empty file values win, the environment is the fallback. `assert_paper()` requires the `ALPACA_BASE_URL` host to be `paper-api.alpaca.markets` before any Alpaca client is built; the bars client only sends GET to `data.alpaca.markets` (loopback for tests). Nothing in `agents/` can place, cancel or modify an order or call Robinhood.

### Envelope and cache

`cache/agents/` (gitignored; `AGENT_CACHE_DIR` overrides, relative = project root):

```
cache/agents/<agent>/<YYYY-MM-DD>/<SYM>.json   envelope (agents/schemas/envelope.schema.json)
cache/agents/gates/<signal_id>.json            gate (agents/schemas/gate.schema.json)
cache/agents/validate/reports/<run_id>/        report.html, report.json
cache/agents/validate/signals/<signal>/        v2 signal cache, <SYM>_<sha256(bars)[:12]>.csv
cache/agents/validate/trials.jsonl             every evaluated config (DSR trial count)
cache/agents/data/alpaca/                      bars disk cache
cache/agents/llm/ledger.jsonl                  LLM budget ledger (unused while LLM_PROVIDER=none)
cache/agents/validate/signals/v2_core/         quant_rank v2 core cache (conf, bull, bear per bar)
cache/agents/quant/{raw,qlib_data,qlib_data.prev,models,predictions,mlruns,eval}/   quant agent (Phase 2)
```

Quant envelopes use `ttl_hours` 84 (`QUANT_TTL_HOURS`) instead of 36.

Envelope fields: `agent`, `symbol`, `as_of`, `generated_at` (second-precision `Z`), `ttl_hours` (36), `available`, `score` (0..100 or null), `direction`, `confidence`, `data_sources`, `synthetic`, `warning`, `reason`, `features`, `evidence`, `veto`, `llm`, `validation`. Rules: `available: false` → score/direction/confidence null, `data_sources: []`, non-empty `reason`; `synthetic: true` needs a `warning`.

### Scoring wiring (zero-weight identity)

`calculate_confluence_score_v2` calls `agent_components_json` after the ML/MiroFish core and before sentiment (blend order: core → agents `× (1 − Σw) + Σ score·w` → sentiment). Additive agents and their gates: `quant` (`quant_rank`, `AGENT_QUANT_WEIGHT`), `fundamental` (`fundamental_quality`, `AGENT_FUNDAMENTAL_WEIGHT`), `market` (`market_news_score`, `AGENT_MARKET_WEIGHT`). Each weight defaults to 0, is clamped to [0, 0.30], the total is capped by `AGENT_MAX_TOTAL_WEIGHT` (0.30). A weight applies only if the envelope is OK (fresh, available), not synthetic (except `SST_OFFLINE=1`) and the gate is `PASSED` and ≤ `AGENT_GATE_MAX_AGE_DAYS` (45) old. Agents cast no signal votes.

- `AGENTS_ENABLED=false` (default): v2 JSON byte-identical to `970af57` (goldens in `tests/fixtures/agents/v2_golden/`, captured before any lib change; only `latency_ms`/timestamps differ).
- `AGENTS_ENABLED=true`, all weights 0: same scores, recommendation and weights; a `components.agents` shadow block is added: `{applied_weight_percent, quant|fundamental|market: {score, status, weight_percent, applied, reason}}`. Reasons in order: `disabled` / `missing` / `invalid` / `stale` / `unavailable` → `synthetic` → `no_gate` → `gate_failed` / `gate_expired` / `gate_synthetic` → `shadow` (eligible, weight 0) → `applied`.
- Phase 2 adds the first producer (quant, `cache/agents/quant/<date>/`). Its gate `quant_rank` failed on real data, so the quant entry stays at most `gate_failed` and nothing can be applied; no fundamental/market producer exists yet.

### Technical Agent

TA-Lib features on Alpaca daily bars (`compute_features` / `compute_series`): close, RSI14, EMA 12/26/20/50, SMA 50/200, MACD/signal/hist (standard signal line), Bollinger (population and sample), ATR14 (Wilder), TRANGE, NATR, ADX14, +DI/−DI, Stochastic slow/fast, Williams %R, OBV, Donchian 20, `trend_state`, `regime_adx` (the bash regime rules with a real ADX14) and `regime_bash`. The score uses the bash scorers on the TA-Lib values (bc quirks included). Needs ≥ 60 bars.

Scan hook (D14): with `AGENTS_ENABLED=true AGENT_TECHNICAL_ENABLED=true` and an OK, non-synthetic technical envelope (newest `<as_of>` dir ≤ today, America/New_York; fresh = `generated_at` within `ttl_hours`), `calculate_all_indicators` replaces `v2_inputs.regime` with the agent's `regime_adx` (adds `regime_source: "technical_agent"`, `regime_bash`). Otherwise it adds `regime_source: "bash"` and `technical_agent_status`: the `agent_get` statuses plus `SYNTHETIC` and `NO_REGIME`. Disabled (default): the input is returned unchanged. Run the agent nightly yourself (`python -m agents technical run --symbols ...`); the bash scan never runs Python.

`agents/technical/bash_compat.py` is an exact Python port of the bash v2 scan (bc scale rules, `printf` rounding, grep extraction that drops negative numbers, `calc_macd` signal == macd, sample-std Bollinger, closes-only stochastic/Williams). On 65 fixture windows the port matches bash exactly (components, confluence and the full JSON, 65/65). TA-Lib vs bash on matching definitions: RSI ≤ 0.005, EMA ≤ 0.018, MACD line ≤ 0.02, BB ≤ 0.008, ATR vs SMA(TRANGE) ≤ 0.005, Stochastic/Williams ≤ 0.005, OBV exact; Wilder ATR differs by up to 0.63 (reported, not hidden).

### Strategy Validation Agent and gate

Signals (`agents/signals`): `v2_confluence` (rolling 60-bar windows through `bash_compat`, ML unavailable → renormalised 35/30/20 over 85, sentiment `na`, Bollinger price = last close, MiroFish/agents off; BUY/STRONG_BUY enter, SELL/STRONG_SELL exit), `v2_confluence_adx` (same with the real-ADX regime), `mr_only` (RSI < rsi_buy and close < lower BB → buy; RSI > 70 and close > upper → sell), `tf_only` (EMA fast/slow crosses). Grids: MR rsi_buy {25,30,35} × bb_std {1.5,2,2.5}; TF (fast,slow) {(8,21),(12,26),(20,50)}; every signal × stop {1.5,2,3}×ATR14 × take profit {5,8,12}% (grid sizes v2 9, v2_adx 9, MR 81, TF 27).

Engine (`agents/validate/engine.py`, vectorbt 1.2.0, `freq="1D"`): long-only, signals shifted one bar and filled at the next open, stop = mult × ATR14 / close clamped to 1–15% (5% when ATR is undefined), take profit tp%, gap through a stop exits at the open, slippage 10 bp per side (`AGENT_GATE_SLIPPAGE` 0.001), commission 0 (`AGENT_GATE_FEES`), integer shares, equal capital per symbol, no stop check on the entry bar, stop first when a stop and a signal exit share a bar.

Walk-forward: real runs 2 y train / 6 m test / 6 m step from `--start` (150 calendar days of warm-up loaded before it), last test window truncated (kept if ≥ 21 bars); offline 252/126 bars, 2 folds anchored at the end. Each fold picks the max train Sharpe config and runs it out of sample. Benchmarks: SPY buy-and-hold and an equal-weight universe buy-and-hold per fold, same slippage. DSR (Bailey & López de Prado) uses N = max(grid size, distinct config hashes ever logged for the signal in `trials.jsonl`); PBO = CSCV with S = 16 (8 offline or when < 320 rows).

Gate criteria (§5.6 defaults, env-overridable; non-numeric → default):

| Criterion | Rule | Env |
|---|---|---|
| `min_oos_sharpe` | OOS Sharpe ≥ 0.5 | `GATE_MIN_OOS_SHARPE` |
| `vs_spy_sharpe` | OOS Sharpe ≥ SPY Sharpe − 0.1 | `GATE_SPY_SHARPE_MARGIN` |
| `min_dsr` | DSR ≥ 0.95 | `GATE_MIN_DSR` |
| `max_pbo` | PBO ≤ 0.30 | `GATE_MAX_PBO` |
| `max_drawdown_vs_spy` | OOS max DD ≤ 1.2 × SPY max DD | `GATE_MAX_DD_MULT` |
| `min_oos_trades` | OOS trades ≥ 100 | `GATE_MIN_OOS_TRADES` |
| `min_positive_folds` | share of folds with OOS return > 0 ≥ 0.60 | `GATE_MIN_POSITIVE_FOLDS` |
| `baseline_improvement` | `not_applicable` for the 4 base signals (not counted); for a spec with a baseline (Phase 2: `quant_topk` → `xgb_topk`, `quant_rank` → `v2_confluence`) share of folds whose OOS return beats the baseline's ≥ 0.60 | `GATE_MIN_BASELINE_FOLDS` |

`passed` = every applicable criterion passes AND the run is not synthetic AND every symbol and the benchmark have a real source (`alpaca:*` or `yfinance`). A failed gate is a valid result (exit 0, `reasons` lists each failure as `<criterion>: <value> <op> <threshold>`); missing data exits 2 and writes no gate. The gate run also runs the legacy parity on the same bars (`legacy_parity` in report.json). The HTML report is self-contained (no JS/CDN, inline SVG equity curves, HTML-escaped) and shows a SYNTHETIC banner on fixture runs.

How to read the report: the summary table has one row per signal with OOS Sharpe, SPY and equal-weight Sharpe, CAGR, max DD vs SPY DD, trades, % positive folds, DSR, PSR, PBO and PASS/FAIL per criterion; the fold table shows each fold's train/test dates, chosen params and OOS vs SPY return. Only a gate with `passed: true`, real data and age ≤ 45 days lets an agent weight above 0 count (`agent_gate_get` → `PASSED`). The four Phase 1 signals are base signals: their gates are evidence about the existing scoring, not switches.

Legacy parity (D21): vectorbt in legacy mode (same-bar close fills, 95% cash integer shares replayed from the legacy cash rule, 0.1% slippage, 0.01% commission) matches `lib/backtest_engine.py` exactly: fixtures 6/6 (59 trades, P&L diff 0.00); real Alpaca SIP bars 2016 → last session, 20 symbols: 40/40, MR 167/167 trades, TF 896/896, P&L diff 0.00. `lib/backtest_engine.py` and `--backtest` are unchanged.

**Phase 1 real gate run** (run `20261101T081120Z-e85ff8`, Alpaca SIP daily bars, `adjustment=all`, 2016-01-04 → 2026-10-30, 20 symbols + SPY, 18 folds, 10 min 28 s): **no signal passes; all agent weights stay 0 and no live money.** Full report: `.agents/tasks/phase1-gate-report.md` / `.html` (outside the repo).

| Signal | OOS Sharpe | SPY Sharpe | OOS CAGR | OOS max DD (SPY 33.8%) | Trades | Positive folds | DSR | PBO | Failed criteria |
|---|---|---|---|---|---|---|---|---|---|
| `v2_confluence` | 0.55 | 0.78 | 3.2% | 9.4% | 910 | 72% | 0.862 | 0.274 | `vs_spy_sharpe`, `min_dsr` |
| `v2_confluence_adx` | 0.40 | 0.78 | 2.2% | 14.1% | 970 | 50% | 0.731 | 0.291 | `min_oos_sharpe`, `vs_spy_sharpe`, `min_dsr`, `min_positive_folds` |
| `mr_only` | 0.20 | 0.78 | 0.9% | 10.6% | 278 | 67% | 0.331 | 0.467 | `min_oos_sharpe`, `vs_spy_sharpe`, `min_dsr`, `max_pbo` |
| `tf_only` | 0.36 | 0.78 | 1.1% | 6.7% | 593 | 72% | 0.571 | 0.523 | `min_oos_sharpe`, `vs_spy_sharpe`, `min_dsr`, `max_pbo` |

The real-ADX regime did worse than the bash approximation on this run, so `AGENT_TECHNICAL_ENABLED` stays off. Caveats: survivorship bias (fixed current universe), ML and sentiment excluded from the replay, next-open fills, 10 bp slippage. vectorbt is Apache 2.0 + Commons Clause (free to use, not to sell). Reproduce: `.venv-agents/bin/python -m agents validate gate --signals v2_confluence,v2_confluence_adx,mr_only,tf_only --start 2016-01-01 --end 2026-10-30`.

### LLM

`LLM_PROVIDER=none` (default): no LLM is called. `fake` is for tests; `ollama` (`LLM_BASE_URL` default `http://127.0.0.1:11434`, `LLM_MODEL`) and `openai` (OpenAI-compatible, `LLM_API_KEY`) exist but no agent uses them in Phase 0-1 or Phase 2. `BudgetLedger` authorises every call before any HTTP request; with `LLM_MONTHLY_BUDGET_USD` 0 (default) every cloud call is refused.

---

## Quant Research Agent (Phase 2)

**Files:** `agents/quant/` (12 modules + `universe.txt`), `agents/signals/quant.py`, the Phase 2 block of `requirements-agents.txt`, quant additions in `agents/validate/` (slot sizing, baseline criterion, `bars_res`), `agents/technical/bash_compat.py` (`agent_blend`, `recommend`; parity unchanged), `agents/data/alpaca.py` (`include_vwap`). Commits `afd07d5`, `91835c3`, `7023129`, `09aec78`, `dbc0c90`, `e67d323`, `3edf3b6`, `7a42bb7`, `ea9b81a`, `75ea040`. No change to `config.template.sh`, `lib/scoring.sh`, `lib/agent_adapter.sh`, `lib/ml_predictor.sh`, `lib/models/` or any order/broker lib. FinRL is not used. No LLM, no paid service.

### Setup

Same venv as Phase 0-1 (`.venv-agents`, Python 3.12). Phase 2 pins (`requirements-agents.txt`): pyqlib 0.9.7, lightgbm 4.7.0, xgboost 3.4.1 (the version the legacy `lib/models/xgboost_predictor.pkl` was trained with), mlflow 3.17.2, pyarrow 25.0.1, joblib 1.6.0, python-dateutil 2.9.0.post0 (pyqlib needs < 3; pip downgraded 3.0.0; no Phase 0-1 pin changed). Installed with `pip install pyqlib==0.9.7 lightgbm==4.7.0 xgboost==3.4.1 -c <Phase 0-1 pins>`; `pip check` clean. pyqlib also pulls jupyter, cvxpy, gym, fire, loguru, redis, pymongo (not imported by our code). Venv size 1.2 GB. `import qlib` (+ lightgbm, xgboost, mlflow, pyarrow) takes ~12 s; `python -m agents status` and `quant status` import none of them.

```bash
.venv-agents/bin/pip install -r requirements-agents.txt && .venv-agents/bin/pip check
```

### Universe

`agents/quant/universe.txt` (sections `# rank` and `# benchmark`, read by `load_universe`): 153 liquid US large caps (all GICS sectors, common stock, no dotted tickers, includes the 20 Phase 1 symbols) + benchmarks SPY, QQQ, IWM (ingested, never ranked). Pruned after the first real ingest: LIN (first SIP bar 2018-10-31), MMC (stale, last bar 2026-01-13), BK (stale, last bar 2026-05-20). **Survivorship bias:** a fixed list of today's large caps; delisted/acquired names are missing, which flatters every result. Offline: QAA..QLL + AAA, BBB, CCC (15 rank) and SPY from `tests/fixtures/agents/bars/` (generated random walks, synthetic).

### Data: raw store and Qlib store

`quant ingest` fetches daily bars through `AlpacaBarsClient` (paper asserted, GET only, host whitelist, `include_vwap=True`, batches of 25, 403 sip → iex) from `--start` (default 2016-01-01) to the expected last session, and writes `cache/agents/quant/raw/<SYM>.csv` (open, high, low, close, volume, vwap) + `<SYM>.meta.json` (`data_source`, `synthetic`, `adjustment`, `feed`, `start`, `end`, `rows`, `fetched_at`, ...). Full history per symbol (adjustment `all` re-bases on every dividend, so appending would mix bases). Resume: a symbol whose meta has the same start, end and adjustment (rows > 0) is skipped unless `--refresh`.

Then `build_store` writes the Qlib bin store `cache/agents/quant/qlib_data/` (built in a temp dir, swapped in, old kept as `qlib_data.prev`): `calendars/day.txt`, `instruments/{all,sst_us}.txt` (`sst_us` = rank symbols), `features/<sym>/<field>.day.bin` (little-endian float32, first value = calendar start index) for open, high, low, close, volume, vwap, factor (1.0; prices already adjusted) and the 14 legacy ML features `sst_*` (computed with the functions of `lib/ml_inference.py`, imported by path; equal to `extract_features_from_data` on every prefix from bar 49), plus `store_meta.json` (`rank_symbols`, `benchmarks`, `spans`, `data_sources`, `bars_sha12`, `missing_sessions`, calendar range, `synthetic`).

Real store (2026-11-01): 153 rank + 3 benchmark symbols, all `alpaca:sip`, `synthetic: false`, 2,723 sessions 2016-01-04 → 2026-10-30, every symbol complete (0 missing sessions), 424,788 bars. Disk: raw 23 MB, qlib_data 38 MB (+ prev 38 MB), models 9.2 MB, predictions 11 MB, mlruns 25 MB; `cache/agents/quant` 146 MB. First ingest 30 s (45 GETs), resume 10 s (0 GETs).

### Model: handler, label, folds, arms

- Handler (`make_handler`): `alpha158_sst14` = Qlib Alpha158 (158 features) + the 14 `$sst_*` fields = 172 features; `sst14` = the 14 legacy features only. Learn processors `DropnaLabel`, `CSZScoreNorm(label)`; no feature normalisation.
- Label `LABEL0 = Ref($open, -6) / Ref($open, -1) - 1`: open t+1 → open t+6, the 5-day return tradable after a close-t decision.
- Folds (`yearly_folds`): test year Y = 2018 … last (partial) year; expanding train from `calendar[60]`; valid = year Y-1; 7-session embargo before each segment boundary (`end + 7 < next start`). Live model (`live_segment`): valid = last 252 sessions, train before it minus the embargo. Offline: 2 bar folds of 126.
- Arms (`train.ARMS`), no hyperparameter search (trial count 1):

| Arm | Model | Features | Params | Role |
|---|---|---|---|---|
| `lgbm` | LightGBM | alpha158_sst14 (172) | Qlib Alpha158 benchmark: loss mse, lr 0.2, num_leaves 210, max_depth 8, colsample 0.8879, subsample 0.8789, lambda_l1 205.6999, lambda_l2 580.9768, early stopping 50, ≤ 1000 rounds, seed 42 | the quant model (predict default) |
| `xgb14` | XGBoost | sst14 (14) | legacy: max_depth 6, eta 0.1, reg:squarederror, 100 rounds, seed 42 | baseline = today's ML path on real data |
| `xgb_full` | XGBoost | alpha158_sst14 (172) | legacy params | IC diagnostic only |

- CPU: `init_qlib` runs `qlib.init(provider_uri=store, region=REG_US, kernels=1, expression_cache=None, dataset_cache=None)` and sets `MLFLOW_ALLOW_FILE_STORE=true`, `MLFLOW_DISABLE_AGENT_HINT=1`, `MLFLOW_DISABLE_TELEMETRY=true`, `DO_NOT_TRACK=true` before importing qlib (MLflow 3.17 otherwise sends usage telemetry). `QUANT_N_JOBS` (default 4) = LightGBM `num_threads` / XGBoost `nthread`. Start long real runs with `nice -n 10`. `QUANT_TEST_FAST=1` (tests) caps rounds at 20.
- Artefacts: `cache/agents/quant/models/<train_run_id>/<arm>/{fold_<Y>,live}/model.pkl`, `models/<train_run_id>/train_manifest.json`, `models/latest.json` (pointer), `predictions/<arm>.parquet` (datetime, instrument, score, label (raw open-to-open), fold); Qlib recorder (MLflow file store) `cache/agents/quant/mlruns`, experiment `sst_quant`, one recorder per arm × fold (`<arm>_<fold>`, `<arm>_live`). `.gitignore` also ignores `mlruns/`.

Real training run `20261101T192518Z-1003ab`: 2 min 8 s wall (handler build 20.5 s / 7.4 s; lgbm 42.5 s, xgb14 10.3 s, xgb_full 37.7 s), 9 yearly folds 2018..2026 + live per arm, 339,660 OOS prediction rows per arm (2018-01-02 → 2026-10-30), fold train sizes 28,305 → 336,141 rows, live train 367,812. LightGBM early-stops at 1-13 trees per fold (live 2) with these fixed params; reported as-is.

### Predict and envelopes

`quant predict` (real mode) first refreshes the raw + Qlib store (resume: current symbols are not refetched), loads the live model of `--arms` (default `lgbm`) from `models/latest.json`, builds the handler over the last 130 sessions ending at the feature date (last store session ≤ `--as-of`; default = expected last session, offline = store end) and ranks the rank universe:

- `score` = percentile `100 × (rank_asc − 1) / (n − 1)`, 1 decimal (100 = best; ties by symbol order); `direction` bullish ≥ 80, bearish ≤ 20, else neutral; `confidence` = |pct − 50| / 50.
- `features`: `prediction`, `rank` (1 = best), `universe_size`, `percentile`, `arm`, `model_id`, `model_train_end`, `model_age_days`, `label`, `feature_set`, `feature_date`. `data_sources` from the raw meta. `validation` = `{gate_id: "quant_rank", passed}` from the gate file. `ttl_hours` 84 (`QUANT_TTL_HOURS`: a Friday prediction is still fresh on Monday or after a holiday). Model older than 400 days → warning.
- Unavailable: `not_in_quant_universe` (requested symbols outside the rank list, incl. SPY), `no_features_at_as_of`, `stale_data` (store end before the staleness cutoff), `universe_too_small`.

Real run (as of 2026-10-30): 153 envelopes in `cache/agents/quant/2026-10-30/`, 60 s; `agent_get quant AAPL` → OK, score 37.5 (rank 96/153). Nightly (after the close, on weekdays):

```bash
# crontab -e   (22:30 local time, Mon-Fri; quant predict refreshes the data itself)
30 22 * * 1-5 cd /path/to/StockSwingTrader-v6.3 && nice -n 10 .venv-agents/bin/python -m agents quant predict >> logs/quant_predict.log 2>&1
```

### Evaluate, gates and the go rule

`quant evaluate` computes per arm on the pooled OOS predictions (`metrics.evaluate_arm`): daily IC and Rank-IC (Spearman, ≥ 5 names), mean, std, ICIR, naive t, **Newey-West t (lag 4)**, non-overlapping (every 5th day) t, per-year table, top-k (5/10/20) excess over the universe mean (per 5 days, annualised × 252/5, NW t), Q5 − Q1 spread. Then two gate runs through `validate.agent.run_gate` (walk-forward 2 y / 6 m / 6 m from 2018-01-01, 14 folds, same criteria as Phase 1):

| Gate | Signal | Universe | Grid | Baseline |
|---|---|---|---|---|
| `xgb_topk` | every 5 sessions hold the k best `xgb14` names, slot sizing (k slots of cash/k) | rank universe | k {5,10,20} × risk grid = 27 | — |
| `quant_topk` | same with `lgbm` | rank universe | 27 | `xgb_topk` |
| `quant_rank` | bash v2 replay with the quant percentile blended like an applied agent (`core × (1 − 0.15) + q × 0.15` before rounding; agents cast no votes; no quant → plain v2) | 20 Phase 1 symbols | risk grid = 9 | `v2_confluence` (in memory, no gate file) |

Go (all required): lgbm Rank-IC mean ≥ 0.02 AND NW t ≥ 2; `quant_rank` gate passed; `quant_topk` beats `xgb_topk` in ≥ 60 % of folds; real data. Go only *proposes* `AGENT_QUANT_WEIGHT=0.15` in the report; the config default stays 0 either way. Report: `cache/agents/quant/eval/<run_id>/quant_report.{json,html}` (copied to `--report-dir`); HTML sections run, data, training, ic, spreads, gates, baselines, go, decision, caveats (+ proposal on go, SYNTHETIC banner offline).

**Phase 2 real result** (eval `20261101T194304Z-cda1ae`, 12 min 20 s; full report `.agents/tasks/phase2-quant-report.md` / `.html`, outside the repo): **NO-GO.**

| Arm | IC | Rank-IC | NW t (Rank-IC) | Non-overlap t | % days > 0 |
|---|---|---|---|---|---|
| `lgbm` | 0.0129 | 0.0087 | 1.95 | 1.29 | 51.6 % |
| `xgb14` | 0.0107 | 0.0068 | 1.78 | 0.74 | 50.6 % |
| `xgb_full` | 0.0200 | 0.0144 | 3.04 | 1.95 | 54.3 % |

| Gate | OOS Sharpe (SPY 0.77) | CAGR | Max DD (SPY 33.8 %) | Trades | Positive folds | DSR | PBO | Failed criteria |
|---|---|---|---|---|---|---|---|---|
| `xgb_topk` | 0.53 | 9.7 % | 34.8 % | 2128 | 64.3 % | 0.834 | 0.391 | `vs_spy_sharpe`, `min_dsr`, `max_pbo` |
| `quant_topk` | 0.58 | 11.1 % | 41.7 % | 1769 | 78.6 % | 0.828 | 0.422 | `vs_spy_sharpe`, `min_dsr`, `max_pbo`, `max_drawdown_vs_spy`, `baseline_improvement` (42.9 %) |
| `quant_rank` | 0.64 | 4.0 % | 13.2 % | 931 | 78.6 % | 0.879 | 0.348 | `vs_spy_sharpe` (0.6418 < 0.6718), `min_dsr`, `max_pbo` (baseline 64.3 %: pass) |

lgbm top-5 excess 0.28 % per 5 days (NW t 3.35); Q5 − Q1 0.09 % (t 1.60). Every go criterion except `real_data` failed. Consequence: `AGENT_QUANT_WEIGHT` stays 0, `agent_gate_get quant_rank` → `FAILED`, the quant component in v2 can at most be a `components.agents` shadow entry (`gate_failed`). Phase 1 gate files were not changed. Observation (not acted on): `xgb_full` had the strongest IC; any retune must be a new pre-registered run with its trials counted in the DSR.

### Scoring wiring

Nothing new in bash: `agent_components_json` already reads `cache/agents/quant/<date>/<SYM>.json` `.score` with gate `quant_rank` and weight `AGENT_QUANT_WEIGHT` (see [Scoring wiring](#scoring-wiring-zero-weight-identity)). The quant cache subdirectories (`raw/`, `qlib_data/`, ...) are ignored by the adapter (it only globs `YYYY-MM-DD` dirs). `tests/test_agents_quant_blend.sh` proves the Python `quant_rank` replay equals `calculate_confluence_score_v2` with an applied quant agent (whole JSON), and the pipeline suite proves the 13 v2 goldens stay identical with `AGENTS_ENABLED=true AGENT_QUANT_WEIGHT=0`.

### CLI

| Command | Effect | Exit |
|---|---|---|
| `quant ingest [--symbols ...] [--start] [--end] [--refresh] [--offline]` | raw store + Qlib store (with `--symbols`: rank = given non-benchmarks) | 0; 2 `market_data_unavailable` (store untouched) |
| `quant train [--arms lgbm,xgb14,xgb_full] [--offline]` | yearly folds + live model per arm, OOS predictions, manifest | 0; 2 `store_unavailable`; 1 `invalid_arms` |
| `quant predict [--as-of] [--symbols] [--arms lgbm] [--offline]` | envelopes `cache/agents/quant/<as_of>/` | 0; 2 `predictions_unavailable` / `store_unavailable` / none available |
| `quant evaluate [--offline] [--report-dir DIR] [--start]` | IC, three gates, go/no-go report | 0 (also on no-go); 2 data/predictions missing |
| `quant status` | raw, store, models, predictions, envelopes, evaluation, quant gates (null when absent) | 0 |
| `validate gate --signals quant_topk,...` | quant gates directly (bars from the quant raw store) | 2 `quant_predictions_unavailable` / `quant_store_unavailable`; 1 `mixed_universes` |

`train`, `predict` and `evaluate` send Qlib/LightGBM chatter to stderr so stdout stays one JSON document. Real pipeline on this Mac (10 cores, load ~8, `QUANT_N_JOBS=4`, nice 10): ingest 30 s, train ~2 min, predict 60 s, evaluate ~12 min.

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

# Agent layer (optional, separate venv; see Agent Layer):
/opt/homebrew/bin/python3.12 -m venv .venv-agents
.venv-agents/bin/pip install -r requirements-agents.txt && .venv-agents/bin/pip check
```

Configuration:
- `config.template.sh` is tracked and has no secrets. The agent sources it, then `config.sh` (or `SST_CONFIG_FILE`) if present, whose values win. Its placeholder `API_KEY_ALPHA_VANTAGE`/`API_KEY_FINNHUB`/`API_KEY_NEWSAPI` values override anything exported earlier; Alpaca keys are read from the environment when `config.sh` does not set them.
- `config.sh` is **untracked** again since `a64f234` / `26c44ba` (2026-11-01: listed in `.gitignore`, removed from the index; it was tracked from `52516c3` to `26c44ba`, so older commits still contain it). Each user creates their own (`cp config.template.sh config.sh`) with the Alpaca **paper** keys, `ALPACA_BASE_URL="https://paper-api.alpaca.markets"`, the Finnhub and NewsAPI keys, `FRED_API_KEY` and `SEC_USER_AGENT` (read by the agent layer only as `has_*` booleans until the Phase 3 clients exist). To change a key: edit `config.sh` and run `./StockSwingTrader_Agent.sh --check-account`. Keep it on paper: the tracked-config live guard (`config_file_is_tracked`) no longer fires for an untracked `config.sh`, so a live URL there is stopped only by `--live` + the typed confirmation. Regenerate any key that was exposed outside the private repo.
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

Agent layer config variables (`config.template.sh` "Agent layer" block, all `${VAR:-default}`; Python-only ones are read from the environment). `python -m agents` exports the effective values of the variables this block defines (`TEMPLATE_SETTINGS` in `agents/config.py`) to its own environment at start, so a value set in `config.sh` (e.g. `AGENT_CACHE_DIR`) is used by the Python writer and by `lib/agent_adapter.sh` alike:

| Variable | Default | Meaning |
|---|---|---|
| `AGENTS_ENABLED` | `false` | `true` adds the `components.agents` block to v2 and lets eligible weights apply |
| `AGENT_CACHE_DIR` | `cache/agents` | Cache root (relative = project root) |
| `AGENT_MAX_AGE_HOURS` | `36` | Envelope max age when the file has no `ttl_hours` |
| `AGENT_GATE_MAX_AGE_DAYS` | `45` | Older gate = `EXPIRED` (weight 0) |
| `AGENT_MAX_TOTAL_WEIGHT` | `0.30` | Cap on the sum of agent weights (clamped 0..0.5) |
| `AGENT_QUANT_WEIGHT`, `AGENT_FUNDAMENTAL_WEIGHT`, `AGENT_MARKET_WEIGHT` | `0` | Per-agent weight (0..0.30); keep 0 until a gate passes |
| `AGENT_TECHNICAL_ENABLED` | `false` | Scan uses the Technical agent's `regime_adx` (needs `AGENTS_ENABLED=true`) |
| `AGENT_BARS_FEED` | `sip` | `sip` (403 → `iex` retry) \| `iex` |
| `AGENT_BARS_ADJUSTMENT` | `all` | `raw` \| `split` \| `dividend` \| `all` |
| `AGENT_DATA_FALLBACK` | `none` | `none` \| `yfinance` (labeled fallback; install yfinance yourself) |
| `AGENT_MAX_BAR_STALENESS_DAYS` | `3` | Business days the newest bar may lag the expected last session |
| `AGENT_GATE_SLIPPAGE`, `AGENT_GATE_FEES` | `0.001`, `0` | Gate engine costs per side (environment only) |
| `GATE_MIN_OOS_SHARPE` … `GATE_MIN_POSITIVE_FOLDS` | see [gate criteria](#strategy-validation-agent-and-gate) | Gate thresholds (environment only) |
| `LLM_PROVIDER`, `LLM_BASE_URL`, `LLM_MODEL`, `LLM_API_KEY`, `LLM_MONTHLY_BUDGET_USD`, `LLM_MAX_CALLS_PER_RUN` | `none`, …, `0` | LLM abstraction (unused in Phase 0-2; environment only) |
| `GATE_MIN_BASELINE_FOLDS` | `0.60` | `baseline_improvement` threshold (environment only, Phase 2) |
| `QUANT_N_JOBS` | `4` | LightGBM `num_threads` / XGBoost `nthread` (environment only) |
| `QUANT_TTL_HOURS` | `84` | `ttl_hours` of quant envelopes (environment only) |
| `QUANT_TEST_FAST` | unset | `1` caps boosting rounds at 20 (tests only) |
| `SST_AGENTS_VENV` | `<project>/.venv-agents` | Venv the test runner uses for agent suites (`/nonexistent` simulates no venv) |

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

`bash tests/test_runner.sh` runs 29 suites offline (`SST_OFFLINE=1`) and writes `.agents/tasks/test-report.md`. Last verified result (agent layer Phase 2, `75ea040`): **29 suites, 1878/1879** with the venv (28 suites passed; exit 1 only because of the pre-existing timing assertion `MiroFish step for 5 symbols takes < 1000 ms` in Phase 1 Integration (CLI), 1115 ms; 2559 s; the 18 pre-existing suites 961 tests with 960 passing, the 11 agent suites 918: Contract 26, Data Clients 20, Adapter 83, Scoring + Agents 90, Technical 21, Parity 322, Validation 40, CLI 23, Quant 46, Quant pipeline 89, Quant blend 158) and **29 suites (20 passed, 9 skipped), 1134/1134** with `SST_AGENTS_VENV=/nonexistent` (exit 0, 1784 s), on `main` at `75ea040` plus the Phase 2 docs (the runs overlapped the docs/config commits `fee5d80`..`26c44ba`, which change no code). The same assertion failed in both with-venv runs, in the first without-venv run and in a separate rerun of that suite (1115-1406 ms); the second without-venv run passed it. No other test failed in any run. Phase 0-1: 26 suites, 1582/1582 with the venv (1443 s) and 1134/1134 without (1244 s). Timing assertions are pre-existing and can fail when the Mac is under heavy load (endpoint-security scanning of every process spawn pushed the load to 12-21 on 10 cores during the Phase 2 runs): `MiroFish step for 5 symbols takes < 1000 ms` in Phase 1 Integration (CLI) measured 1115-1406 ms there (no lib or agent code changed since `ee15c75`, where it passed); they are not weakened. Nine suites need the agent venv (`add_test NAME FILE venv`): when `${SST_AGENTS_VENV:-.venv-agents}/bin/python` is missing they print `[SKIP]` with the setup command and do not count as failures; `SST_AGENTS_VENV=/nonexistent bash tests/test_runner.sh` simulates that without deleting the venv. The runner unsets `AGENTS_ENABLED`, `AGENT_CACHE_DIR`, `AGENT_TECHNICAL_ENABLED` and the `AGENT_*_WEIGHT` variables at start. Before the agent layer: **18 suites, 960/960 passing** at `5a7abc0` (live-safety Step 1, about 13.5 min; run with no `SST_CONFIG_FILE` exported and `HOME` set to the real home; Broker Commands is now 137 because it checks the new `lib/agent_adapter.sh` too). Earlier: 15 suites, 598/598 after the broker/path fix; 14 suites, 468/468 before it (also on a fresh clone that trained its own model with `python3 lib/train_ml_model.py`, xgboost 3.4.1 / numpy 2.5.4). The ML Scoring Integration suite does not depend on what the trained model predicts: it checks the predictor's contract (schema, confidence range, determinism) and runs the STRONG_BUY/STRONG_SELL threshold tests with a stub predictor.

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
| Agents: Contract | `tests/test_agents_contract.py` | `.venv-agents` python (SKIP without venv) |
| Agents: Data Clients | `tests/test_agents_data.py` | `.venv-agents` python (SKIP without venv) |
| Agent Adapter (bash) | `tests/test_agent_adapter.sh` | bash |
| Scoring + Agents (zero-weight identity) | `tests/test_scoring_agents.sh` | bash |
| Agents: Technical | `tests/test_agents_technical.py` | `.venv-agents` python (SKIP without venv) |
| Agents: Parity vs bash | `tests/test_agents_parity.sh` | bash + `.venv-agents` (SKIP without venv) |
| Agents: Validation | `tests/test_agents_validate.py` | `.venv-agents` python (SKIP without venv) |
| Agents: CLI (offline) | `tests/test_agents_cli.sh` | bash + `.venv-agents` (SKIP without venv) |
| Agents: Quant | `tests/test_agents_quant.py` | `.venv-agents` python (SKIP without venv) |
| Agents: Quant pipeline (offline) | `tests/test_agents_quant_pipeline.sh` | bash + `.venv-agents` (SKIP without venv) |
| Agents: Quant blend parity (bash) | `tests/test_agents_quant_blend.sh` | bash + `.venv-agents` (SKIP without venv) |

Agent suites (all offline: fixtures in `tests/fixtures/agents/`, `SST_OFFLINE=1`, 127.0.0.1 stubs, no network): `test_agents_contract.py` (26) envelope schema + rules, atomic cache writes, path guards, config masking, config.sh agent settings reaching the CLI, `assert_paper`, LLM providers + $0 budget, CLI exit codes; `test_agents_data.py` (20) the Alpaca bars client against a 127.0.0.1 stub (pagination, GET only, host whitelist, sip → iex, retry, stale, timeout, cache), fixtures, yfinance fallback off; `test_agent_adapter.sh` (83) every `agent_get` / `agent_gate_get` status, weights, clamps and caps, no network; `test_scoring_agents.sh` (90) v2 goldens byte-identical with agents off, shadow block with weights 0, weight math, the scan hook; `test_agents_technical.py` (21) features, envelopes, CLI; `test_agents_parity.sh` (322, ~105 s) TA-Lib vs bash tolerances, `bash_compat` vs bash exact, v2 port vs 65 bash goldens, 3 live bash recomputes; `test_agents_validate.py` (40) signals, engine, walk-forward, stats, gates, report, slot sizing; `test_agents_cli.sh` (23) `validate gate|parity|status --offline`, the bash `agent_gate_get` contract on the gates written, a socket guard that refuses every connect, no key value in stdout; `test_agents_quant.py` (46, ~2 min) universe, raw ingest against a 127.0.0.1 stub, Qlib bin store round trip, legacy features vs `lib/ml_inference.py`, folds/embargo, training on fixtures (planted-signal IC), metrics, predict envelopes, quant signals, go rule, `quant_rank` at weight 0; `test_agents_quant_pipeline.sh` (89, ~2.5 min) offline `quant ingest → train → predict → evaluate → status` with a socket guard, exit codes, envelopes read by `agent_get`, the 13 v2 goldens identical with `AGENTS_ENABLED=true AGENT_QUANT_WEIGHT=0`, a synthetic evaluate gate read as `SYNTHETIC`; `test_agents_quant_blend.sh` (158, ~2 min) the Python `quant_rank` blend (`bash_compat` with `agent_blend`) equals bash `calculate_confluence_score_v2` with an applied quant agent (whole JSON). Python agent suites use `tests/agents_unittest.py`, which prints `Tests Passed:` / `Tests Failed:` for the runner. Fixture generators: `tests/fixtures/agents/make_fixtures.py` (bars, byte-identical on re-run), `v2_golden/generate_goldens.sh` (captured at `970af57`), `parity/gen_bash_v2_goldens.sh` (~9 min).

`tests/test_v2_cli_scoring.sh` (81 tests) covers the OBV trend score (all up 100, all down 0, flat 50, deterministic), MR/TF/Kalman helpers, the 10th sentiment arg, `analyze_stock` in v2 and legacy mode, MiroFish applied once in v2, the JSON + HTML score breakdown and `--help`. `tests/test_order_execution.sh` (81) covers payload shapes (market/day, limit, bracket gtc, rounding, client order id), bracket orders, duplicate client order id → 422, timeout → lookup with exactly one POST, clock/calendar/open orders, account id masking and that the wrappers no longer shadow broker functions. `tests/test_live_safety.sh` (188, ~2.5 min, one stub per scenario) covers the default limit+bracket buy, every cap, no short selling, kill switch / `--halt` / `--resume`, duplicates, reconciliation (`--reconcile` exit 3, `--reconcile-accept`, fills, unknown open orders, `--allow-mismatch`), market closed / holiday / `queue`, PDT, the live guard (no `--live`, wrong confirmation, typed confirmation, tracked config), that the real `config.sh` points at paper (value check only), Robinhood without `--live`, alerts (log, Slack to the stub `/hooks/slack`, email via a stub sendmail) and `--safety-status`.

`tests/test_no_fake_data.sh` covers the [data-source rules](#data-sources--synthetic-data). It sets `SST_OFFLINE=0` itself and simulates market data with yfinance stubs put first on `PYTHONPATH`: `tests/stubs/yfinance_empty` (no data), `tests/stubs/yfinance_error` (fetch raises) and `tests/stubs/yfinance_fixture` (deterministic real-shaped bars). No network is used.

`tests/test_broker_commands.sh` never contacts a real broker: Alpaca calls go to `tests/stubs/alpaca_stub_server.py` on 127.0.0.1 through a stub config (`SST_CONFIG_FILE`, with temp `SST_STATE_DIR`/`ALERT_LOG_FILE`), Robinhood is exercised with stub functions, and `HOME` is a temp dir. It covers all broker flags and aliases, `yes`/`no`/EOF confirmation (no order on anything but `yes`), invalid symbol/qty, a broker rejection, missing credentials, `--ml`/`--kalman` loading, and that no `lib/*.sh` changes the caller's `SCRIPT_DIR`/`LIB_DIR`/`AGENT_DIR` or enables `errexit`. Step 1 changed only invocations: the Alpaca section first runs `--reconcile-accept`; the market-payload assertion runs `--buy AAPL 2 --order-type market --no-bracket`; Robinhood orders pass `ORDER_LIVE_FLAG=true` with a typed `AAPL 2` / `MSFT 1` (plus a new check that Robinhood without `--live` is refused); the `--place-sell` + `no` case uses AAPL instead of NVDA (an NVDA sell placed just before would now be refused by the duplicate guard before the prompt).

The stub (`alpaca_stub_server.py PORT_FILE REQ_LOG ORDER_LOG [STATE_FILE]`, `ThreadingHTTPServer` on 127.0.0.1) serves account (with `last_equity`, `pattern_day_trader`, `daytrade_count`), positions (AAPL 10, MSFT 5, NVDA 2), latest trade, `GET/POST /v2/orders`, `/v2/orders:by_client_order_id`, `/v2/orders/<id>`, `/v2/clock`, `/v2/calendar` and `POST /hooks/<name>`; symbol `REJ` and a reused client order id → 422, `TMO` answers after `STUB_SLOW_SECONDS` (3), `FIL` fills immediately; `STATE_FILE` (JSON, re-read per request) overrides account/positions/clock/calendar/orders.

Other test scripts not in the runner: `tests/test_alpaca_broker.sh`, `tests/test_robinhood_broker.sh`, `tests/test_regime_simple.sh`.

```bash
bash tests/test_runner.sh               # all 29 suites (~40 min with the venv on a loaded Mac)
SST_AGENTS_VENV=/nonexistent bash tests/test_runner.sh   # 9 agent suites SKIP
.venv-agents/bin/python tests/test_agents_quant.py       # quant unit tests (~2 min)
bash tests/test_agents_quant_pipeline.sh                 # offline quant CLI pipeline
.venv-agents/bin/python tests/test_agents_validate.py    # one python agent suite
bash tests/test_agents_parity.sh        # TA-Lib / bash_compat / v2 port vs bash (~105 s)
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
| `[SKIP] Agents: …: agent venv not found` in the runner | `.venv-agents` missing (or `SST_AGENTS_VENV` points elsewhere) | `/opt/homebrew/bin/python3.12 -m venv .venv-agents && .venv-agents/bin/pip install -r requirements-agents.txt` |
| `No module named agents` | `python -m agents` run outside the repo root | `cd` to the repo root (the package is not installed) |
| First `validate` / `import vectorbt` takes ~30-40 s | numba compiles on first import | Normal; later imports use the numba cache |
| vectorbt `freq` errors / NaN Sharpe | pandas 3 + vectorbt 1.2.0 cannot infer the frequency | Pass `freq="1D"` (the engine always does) |
| Agent bars `stale_data` / `Unavailable` | Newest Alpaca bar older than `AGENT_MAX_BAR_STALENESS_DAYS` business days before the expected last session | Check the symbol / Alpaca data status; raise the limit deliberately |
| Bars labeled `alpaca:iex` | SIP request refused with 403 (plan or recent-data rule); one retry on IEX | Expected on some accounts; IEX volume is a subset of consolidated volume |
| `validate gate` exits 2 `market_data_unavailable` | A universe symbol or the benchmark had no data (or < 60 bars) | Check the `unavailable` map; nothing was written. `AGENT_DATA_FALLBACK=yfinance` only as a labeled second run |
| `SafetyError` / `endpoint_mode` LIVE in `agents status` | `ALPACA_BASE_URL` host is not `paper-api.alpaca.markets` | Restore the paper URL; the agent layer refuses to build an Alpaca client otherwise |
| Gate `passed: false`, reason `synthetic_data` | Run on fixtures (`--offline`) | Expected; only real-data runs can pass |
| Agent weight stays 0 although `AGENT_*_WEIGHT` > 0 | Envelope not OK/fresh, synthetic, or gate not `PASSED` (≤ 45 days) | Read `components.agents.<agent>.reason` in the v2 JSON |
| Qlib hangs or spawns many processes | Qlib code run outside `if __name__ == "__main__"` or with `kernels` > 1 (joblib/multiprocessing on macOS) | Use `python -m agents quant ...` (guarded, `init_qlib` sets kernels=1); in your own scripts call `agents.quant.qlib_env.init_qlib()` under a `__main__` guard |
| MLflow error about the file store / telemetry requests | MLflow 3.17 refuses the file store without `MLFLOW_ALLOW_FILE_STORE=true` and sends telemetry by default | `init_qlib` sets `MLFLOW_ALLOW_FILE_STORE`, `MLFLOW_DISABLE_TELEMETRY`, `DO_NOT_TRACK` before importing qlib; do not `import qlib` before it |
| `quant train` / `predict` exit 2 `store_unavailable` | No Qlib store (`cache/agents/quant/qlib_data/` missing) | `python -m agents quant ingest` first |
| `quant predict` exit 2 `predictions_unavailable`; `validate gate` exit 2 `quant_predictions_unavailable` | No trained model / OOS predictions for the arm (`models/latest.json`, `predictions/<arm>.parquet`) | `python -m agents quant train` (quant_topk needs `xgb14` too) |
| Quant envelopes `stale_data` | Store end before the staleness cutoff (ingest not run, or Alpaca returned old bars) | `quant ingest` (or let `quant predict` refresh); check `quant status` |
| A universe symbol missing / `unavailable` in ingest | Late listing, delisting or stale SIP bars | Remove it from `agents/quant/universe.txt` (header documents the pruning rule) and re-ingest; `validate gate` exits 2 `quant_store_unavailable` when a gate symbol is missing |

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

**Deferred from the agent layer Phase 0-1:** Finnhub / SEC / FRED clients and the Market + Fundamental agents (Phase 3; keys are only plumbed through as `has_*`); vetoes and overlays (Phase 3); Portfolio agent with PyPortfolioOpt (Phase 4); backend `/api/agents` routes; running the Technical agent inside the scan as a batch; supertrend; ML on real data; the scan stochastic/Williams closes-only quirk (issue 11); Robinhood stays untouched by the agents.

**Deferred from Phase 2 (quant):** a survivorship-free universe (point-in-time index membership incl. delisted names); a pre-registered hyperparameter search (LightGBM early-stops at 1-13 trees with the fixed Qlib params) with every trial counted in the DSR; XGBoost/feature ablations (`xgb_full` had the best IC); Qlib's own backtest / portfolio strategy; intraday data; running `quant predict` from the bash scan (today: a cron line); replacing `lib/ml_predictor.sh` (only on a go); FinRL (skipped: no reinforcement learning at $0 / CPU budget).

**Short-term:** real market data for the agent and regime detector; training on real data with a CLI; grid search and stops in the backtester; WebSocket updates instead of polling (`ws` is already a backend dependency but unused).

**Medium-term:** model ensembles or sequence models; walk-forward and Monte Carlo backtests; more sentiment sources; paper-trading auto-execution with P&L tracking (on top of `place_guarded_order`); portfolio-level risk (correlation, VaR).

**Long-term:** other asset classes, reinforcement learning, service split/scaling, notification integrations (Slack/Telegram/email).

---

## Deployment & Versioning

**v6.3 adds:** ML predictor, regime detection and weighting, React dashboard + Express backend, backtesting module, Kalman filter. **Live-safety Step 1** (`4c621fb`, `daf1bca`, `5a7abc0`; `VERSION` unchanged): v2 scoring in the CLI with a real OBV score and score breakdown in reports; Alpaca limit/bracket orders with client order ids; order safety (caps, kill switch, loss halt, duplicate guard, reconciliation, market hours, PDT warning, live guard, alerts). **Agent layer Phase 0-1** (`0d945a6` … `d626d6b`; `VERSION` unchanged, `agents.__version__` 0.1.0): `agents/` package, `lib/agent_adapter.sh` (weights 0), Technical agent, Strategy Validation agent with gates. **Agent layer Phase 2** (`afd07d5` … `75ea040`; `VERSION` unchanged, `agents.__version__` 0.2.0): Quant Research Agent (`agents/quant/`, Qlib + LightGBM + XGBoost baseline), quant gate signals, baseline criterion; real result NO-GO, `AGENT_QUANT_WEIGHT` stays 0.

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
├── .gitignore                       byte-identical to the repo (.state/, config.live.sh, .venv-agents/, mlruns/)
├── requirements-agents.txt          agent layer venv pins (Python 3.12; Phase 2 block: pyqlib, lightgbm,
│                                    xgboost, mlflow, pyarrow, joblib, python-dateutil)
├── agents/                          agent layer package (no __pycache__), byte-identical to the repo,
│                                    incl. agents/quant/ (+ universe.txt) and agents/signals/quant.py
├── lib/                             26 modules + models/: Step 1 synced the agent, config.template.sh,
│                                    scoring.sh, html_report.sh, alpaca_broker.sh, alpaca_wrappers.sh,
│                                    order_safety.sh, alerts.sh, risk_management.sh, trade_journal.sh,
│                                    trading_thresholds.sh; Phase 0-1 added agent_adapter.sh and re-synced
│                                    scoring.sh, the agent and config.template.sh (byte-identical to the
│                                    repo). Still missing: indicators_new.sh, robinhood_oauth.sh,
│                                    robinhood_mcp_direct.sh
├── backend/                         server.js, start.sh, package.json
├── frontend/                        src/, vite.config.ts, package.json
└── docs/                            KALMAN_FILTER_GUIDE.md, ROBINHOOD_SETUP.md,
                                     ALPACA_SETUP_GUIDE.html, STEERING_GUIDE.md,
                                     STEERING_DEPLOYMENT_SUMMARY.txt
```

There is no `tests/` directory (so no fixtures: `python -m agents ... --offline`, including `quant ... --offline`, needs the repo) and no `config.sh` in the package (create one from `config.template.sh`; keep it on paper). `trading_thresholds.sh` is now included, so the regime and strategy modules get their threshold constants. `--broker robinhood` fails to load in the package because `robinhood_oauth.sh` is missing.

---

## Appendix: File Reference

```
StockSwingTrader-v6.3/
├── StockSwingTrader_Agent.sh         Main agent
├── config.template.sh                Configuration template (tracked)
├── config.sh                         Local per-user config, gitignored (untracked since 26c44ba): Alpaca paper, Finnhub, NewsAPI, FRED keys, SEC user agent
├── config.robinhood.sh, config.live.sh   Untracked (gitignored); live keys only in config.live.sh
├── .state/                           Gitignored: orders.jsonl, positions_baseline.json, KILL_SWITCH, order.lock
├── requirements.txt                  Python dependencies (legacy lib/*.py, Python ≤ 3.11 pins)
├── requirements-agents.txt           Agent layer pins (Python 3.12, .venv-agents)
├── .venv-agents/                     Gitignored agent venv
├── agents/                           Agent layer package: cli, config, envelope, cache, fixtures, schemas/,
│                                     llm/, data/, technical/, signals/ (incl. quant.py), validate/,
│                                     quant/ (Qlib quant agent + universe.txt)
├── cache/agents/                     Gitignored: envelopes, gates/, validate/ (reports, signals, trials.jsonl),
│                                     data/alpaca/, llm/, quant/ (raw, qlib_data, models, predictions,
│                                     mlruns, eval, <date>/ envelopes)
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
│   ├── kelly_sizing.sh, mirofish_adapter.sh, agent_adapter.sh
│   ├── order_safety.sh, alerts.sh   (live-safety Step 1)
│   ├── alpaca_broker.sh, alpaca_wrappers.sh
│   ├── robinhood_broker.sh, robinhood_oauth.sh, robinhood_mcp_direct.sh
│   └── html_report.sh
├── backend/      server.js, start.sh, package.json
├── frontend/     src/{App.tsx,pages,hooks,utils,components}, vite.config.ts, package.json
├── docs/         STEERING_GUIDE.md (this file), KALMAN_FILTER_GUIDE.md, ROBINHOOD_SETUP.md,
│                 ALPACA_SETUP_GUIDE.html, STEERING_DEPLOYMENT_SUMMARY.txt,
│                 guides/ (LOCAL_SETUP_GUIDE.html = copy of the Desktop local setup guide,
│                 PLATFORM_INTEGRATIONS_GUIDE.html, README.md; added in fee5d80)
├── examples/     ml_scoring_integration_example.sh
├── tests/        test_runner.sh + 29 registered suites (see Testing), broker tests, mock_data.json,
│                 agents_unittest.py, stubs/yfinance_{empty,error,fixture}/ (offline yfinance stand-ins),
│                 stubs/alpaca_stub_server.py (local Alpaca API stand-in, 127.0.0.1),
│                 fixtures/agents/ (bars/ incl. quant panel QAA..QLL, alpaca/, v2_golden/, parity/;
│                 generated, synthetic)
├── logs/         agent.log, alerts.log, trades.json and broker logs (git-ignored)
└── .agents/tasks/test-report.md      Written by tests/test_runner.sh
```

Copies of this guide that must stay identical: `docs/STEERING_GUIDE.md` (canonical), `DEPLOYMENT_PACKAGE/docs/STEERING_GUIDE.md`, `DEPLOYMENT_PACKAGE/STEERING_GUIDE.md`, `DEPLOYMENT_PACKAGE/.kiro/steering/stockswingtrader-v6.3.md`, and the workspace steering file `.kiro/steering/stockswingtrader-v6.3.md`.

---

**Document Last Updated:** 2026-11-01 (agent layer Phase 0-2: Quant Research Agent)  
**For:** StockSwingTrader v6.3 (commit `75ea040`)
