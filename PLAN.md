# StockSwingTrader Agent Implementation Plan

## Project Overview

**Agent Name:** StockSwingTrader_Agent.sh  
**Purpose:** Analyze 2-5 day swing trades on US stocks using multi-source data (live stock prices, technical indicators, sentiment analysis)  
**Output Format:** HTML reports with buy/sell signals, confidence scores, and risk metrics  
**Execution Model:** Standalone shell script (learning/demo phase, analysis-only)  
**Data Sources:** Yahoo Finance (free, unlimited), Alpha Vantage (5 calls/min), Finnhub (60 calls/min), NewsAPI (free tier), Twitter/Reddit sentiment  

---

## Project Structure & Directory Layout

```
/Users/P3291917/Builds/6/StockSwingTrader/
├── PLAN.md                                    # This file
├── StockSwingTrader_Agent.sh                  # Main entry point (executable)
├── config/
│   ├── api_keys.conf                          # API credentials (API_KEY_ALPHA_VANTAGE, etc.)
│   ├── parameters.conf                        # Trading parameters (RSI_OVERBOUGHT=70, ATR_PERIOD=14, etc.)
│   └── watchlist.txt                          # Symbols to analyze (top 10 by market cap or screened)
├── src/
│   ├── lib/
│   │   ├── config_loader.sh                   # Load and validate config files
│   │   ├── error_handler.sh                   # Unified error logging and exit codes
│   │   └── rate_limiter.sh                    # Rate limit tracking per API source
│   ├── data/
│   │   ├── yahoo_finance_fetcher.sh           # Fetch OHLCV data, live prices (unlimited)
│   │   ├── alpha_vantage_fetcher.sh           # Fetch 20+ year history, intraday data (5 calls/min)
│   │   ├── finnhub_fetcher.sh                 # Real-time stock data, company info (60 calls/min)
│   │   ├── newsapi_fetcher.sh                 # Fetch news articles for sentiment (free tier limits)
│   │   └── cache_manager.sh                   # Local cache (JSON) to reduce live fetches
│   ├── indicators/
│   │   ├── sma_ema_calculator.sh              # Simple/Exponential Moving Averages
│   │   ├── rsi_calculator.sh                  # Relative Strength Index
│   │   ├── macd_calculator.sh                 # MACD + Signal + Histogram
│   │   ├── bollinger_bands_calculator.sh      # Bollinger Bands (20-SMA, 2-std dev)
│   │   ├── atr_calculator.sh                  # Average True Range (volatility)
│   │   ├── obv_calculator.sh                  # On-Balance Volume
│   │   ├── stochastic_calculator.sh           # Stochastic Oscillator (%K, %D)
│   │   └── williams_r_calculator.sh           # Williams %R
│   ├── sentiment/
│   │   ├── twitter_reddit_parser.sh           # Parse tweets/Reddit for mentions
│   │   ├── news_sentiment_analyzer.sh         # Analyze news article tone (positive/negative/neutral)
│   │   └── sentiment_aggregator.sh            # Combine all sentiment signals
│   ├── scoring/
│   │   ├── signal_scorer.sh                   # Score individual indicators (0-100 per signal)
│   │   └── confluence_engine.sh               # Multi-source confluence confidence (0-100 final)
│   ├── reporting/
│   │   ├── html_report_generator.sh           # Generate HTML report template
│   │   ├── chart_builder.sh                   # ASCII/SVG chart generation for HTML
│   │   └── signal_formatter.sh                # Format buy/sell signals for display
│   └── utils/
│       ├── math_utils.sh                      # EMA, SMA, std dev calculations
│       ├── date_time_utils.sh                 # Epoch/date conversion, trading hours check
│       ├── json_parser.sh                     # Parse API JSON responses
│       └── retry_handler.sh                   # Exponential backoff retry logic
├── tests/
│   ├── unit_tests.sh                          # Unit tests for individual modules
│   ├── integration_tests.sh                   # End-to-end test flow
│   ├── data/
│   │   ├── sample_response_yahoo.json         # Sample Yahoo Finance response
│   │   ├── sample_response_alpha_vantage.json # Sample Alpha Vantage response
│   │   └── sample_response_finnhub.json       # Sample Finnhub response
│   └── expected_outputs/
│       └── example_report.html                # Expected HTML report structure
├── logs/
│   └── agent.log                              # Runtime logs (cleared daily)
├── cache/
│   └── data/
│       └── stock_data_TIMESTAMP.json          # Cached live data to avoid re-fetching
├── output/
│   └── reports/
│       └── swing_analysis_TIMESTAMP.html      # Generated HTML report
└── README.md                                   # Setup, usage, and troubleshooting guide
```

---

## Core Implementation Steps

### Phase 1: Foundation & Configuration

- [ ] **1.1 Create StockSwingTrader_Agent.sh main entry point**  
  - Argument parsing: `--symbols AAPL,MSFT,GOOGL` or `--top-10` (auto-fetch top 10)  
  - Usage: `./StockSwingTrader_Agent.sh --symbols AAPL,MSFT --output-dir ./output`  
  - Option flags: `--live-fetch` (always fetch), `--cache-only` (use cache if available), `--debug` (verbose logging)  
  - Source all modules and orchestrate execution flow  
  - **Files:** `StockSwingTrader_Agent.sh`  
  - **Verify:** `bash -n StockSwingTrader_Agent.sh` (syntax check) and `./StockSwingTrader_Agent.sh --help` produces usage output

- [ ] **1.2 Create configuration loader module (config_loader.sh)**  
  - Load `config/api_keys.conf` (API_KEY_ALPHA_VANTAGE, API_KEY_FINNHUB, etc.)  
  - Load `config/parameters.conf` (RSI_PERIOD=14, MACD_FAST=12, BOLLINGER_STD=2, etc.)  
  - Validate required API keys present; fail early if missing  
  - Export all config as environment variables  
  - **Files:** `src/lib/config_loader.sh`  
  - **Verify:** `source src/lib/config_loader.sh && load_config && [ -n "$API_KEY_ALPHA_VANTAGE" ]` exits 0

- [ ] **1.3 Create error handler module (error_handler.sh)**  
  - Unified logging function: `log_error()`, `log_info()`, `log_debug()`  
  - Write to `logs/agent.log` with timestamp, level, message  
  - Exit code standardization (0=success, 1=general, 2=config, 3=data fetch, 4=rate limit)  
  - **Files:** `src/lib/error_handler.sh`  
  - **Verify:** Source file and call `log_error "test"` writes to log file

- [ ] **1.4 Create rate limiter module (rate_limiter.sh)**  
  - Track calls per API source: Alpha Vantage (5/min), Finnhub (60/min), NewsAPI (varies by tier)  
  - Store call timestamps in temp JSON: `{ "alpha_vantage": [1729... , 1729...], ... }`  
  - Before each API call, check rate limit; sleep if needed  
  - **Files:** `src/lib/rate_limiter.sh`  
  - **Verify:** Verify rate limit check prevents exceeding limits in a test run

- [ ] **1.5 Create sample config files (api_keys.conf, parameters.conf, watchlist.txt)**  
  - `config/api_keys.conf`: `API_KEY_ALPHA_VANTAGE=demo`, `API_KEY_FINNHUB=demo` (with comments on where to get real keys)  
  - `config/parameters.conf`: All indicator periods and thresholds as variables  
  - `config/watchlist.txt`: 10 symbols, one per line (AAPL, MSFT, GOOGL, AMZN, TSLA, META, NFLX, CRM, ADBE, NVDA)  
  - **Files:** `config/api_keys.conf`, `config/parameters.conf`, `config/watchlist.txt`  
  - **Verify:** Files exist and can be sourced without errors

---

### Phase 2: Data Fetchers

- [ ] **2.1 Create Yahoo Finance fetcher (yahoo_finance_fetcher.sh)**  
  - **Function:** `fetch_yahoo_ohlcv(symbol, days_back=30)` → JSON: `{ "symbol": "AAPL", "ohlcv": [ {date, open, high, low, close, volume}, ... ] }`  
  - Use public Yahoo Finance endpoint (no auth); curl with retry (3x with exponential backoff)  
  - Fallback to `yfinance` Python library if available  
  - Cache result in `cache/data/stock_data_<symbol>_<date>.json` (valid 1 hour)  
  - **Files:** `src/data/yahoo_finance_fetcher.sh`  
  - **Verify:** Call with `fetch_yahoo_ohlcv AAPL` and confirm JSON output with `jq` validation

- [ ] **2.2 Create Alpha Vantage fetcher (alpha_vantage_fetcher.sh)**  
  - **Function:** `fetch_alpha_vantage_intraday(symbol, interval=5min)` → Returns 60+ data points  
  - Respect 5 calls/min rate limit via rate_limiter.sh  
  - Parse JSON response and extract OHLCV for technical analysis  
  - Cache same as Yahoo  
  - **Files:** `src/data/alpha_vantage_fetcher.sh`  
  - **Verify:** Rate limit enforced; second call within 60s waits as expected

- [ ] **2.3 Create Finnhub fetcher (finnhub_fetcher.sh)**  
  - **Function:** `fetch_finnhub_quote(symbol)` → Returns bid, ask, last price, change, volume  
  - Respect 60 calls/min rate limit  
  - Also fetch company profile for fundamental context  
  - **Files:** `src/data/finnhub_fetcher.sh`  
  - **Verify:** Call succeeds and returns valid JSON with price fields

- [ ] **2.4 Create NewsAPI fetcher (newsapi_fetcher.sh)**  
  - **Function:** `fetch_news_articles(symbol, days_back=7)` → Returns array of articles with titles, descriptions, URLs  
  - Filter for financial/tech news sources  
  - Handle free tier limits (< 100 requests/day)  
  - **Files:** `src/data/newsapi_fetcher.sh`  
  - **Verify:** Call returns news articles relevant to stock symbol

- [ ] **2.5 Create cache manager module (cache_manager.sh)**  
  - **Functions:** `get_from_cache(symbol, max_age_minutes)`, `write_to_cache(symbol, data)`  
  - Cache file format: `cache/data/<symbol>_<source>.json` with timestamp  
  - Clean up stale cache entries (> 24 hours old) daily  
  - **Files:** `src/data/cache_manager.sh`  
  - **Verify:** Write to cache, read back, verify timestamp is recent

---

### Phase 3: Technical Indicators

- [ ] **3.1 Create SMA/EMA calculator (sma_ema_calculator.sh)**  
  - **Function:** `calc_sma(data_array, period)` → Returns array of SMA values  
  - **Function:** `calc_ema(data_array, period)` → Returns array of EMA values  
  - Input: OHLCV array, Output: indicator values  
  - Typical periods: SMA 20, 50, 200; EMA 12, 26  
  - **Files:** `src/indicators/sma_ema_calculator.sh`  
  - **Verify:** Test with known data (e.g., [1,2,3,4,5] with period 2 should produce expected SMA/EMA)

- [ ] **3.2 Create RSI calculator (rsi_calculator.sh)**  
  - **Function:** `calc_rsi(data_array, period=14)` → Returns RSI value (0-100)  
  - Formula: RSI = 100 - (100 / (1 + (avg_gain / avg_loss)))  
  - Signals: > 70 = overbought, < 30 = oversold  
  - **Files:** `src/indicators/rsi_calculator.sh`  
  - **Verify:** Test RSI calculation with sample data; validate output is 0-100

- [ ] **3.3 Create MACD calculator (macd_calculator.sh)**  
  - **Function:** `calc_macd(data_array)` → Returns { macd, signal, histogram }  
  - MACD = EMA(12) - EMA(26)  
  - Signal = EMA(9) of MACD  
  - Histogram = MACD - Signal  
  - Signals: MACD crosses above signal = bullish, below = bearish  
  - **Files:** `src/indicators/macd_calculator.sh`  
  - **Verify:** Output contains macd, signal, histogram fields

- [ ] **3.4 Create Bollinger Bands calculator (bollinger_bands_calculator.sh)**  
  - **Function:** `calc_bollinger_bands(data_array, period=20, std_dev=2)` → Returns { upper, middle, lower, %b }  
  - Middle = SMA(20), Upper = SMA + (2 * StdDev), Lower = SMA - (2 * StdDev)  
  - Signals: Price near lower band = oversold, near upper = overbought  
  - **Files:** `src/indicators/bollinger_bands_calculator.sh`  
  - **Verify:** Upper > middle > lower; %b between 0-1

- [ ] **3.5 Create ATR calculator (atr_calculator.sh)**  
  - **Function:** `calc_atr(data_array, period=14)` → Returns ATR (volatility measure)  
  - Used for stop-loss sizing (e.g., SL = entry - 2*ATR)  
  - True Range = max(high - low, abs(high - close_prev), abs(low - close_prev))  
  - **Files:** `src/indicators/atr_calculator.sh`  
  - **Verify:** ATR > 0; test with known high-volatility data

- [ ] **3.6 Create OBV calculator (obv_calculator.sh)**  
  - **Function:** `calc_obv(data_array)` → Returns OBV array  
  - On-Balance Volume = cumulative (volume if close > prev_close, -volume if close < prev_close)  
  - Signals: Rising OBV confirms uptrend  
  - **Files:** `src/indicators/obv_calculator.sh`  
  - **Verify:** OBV increases/decreases with volume-confirmed price moves

- [ ] **3.7 Create Stochastic calculator (stochastic_calculator.sh)**  
  - **Function:** `calc_stochastic(data_array, period=14, smooth=3)` → Returns { k_line, d_line }  
  - %K = 100 * (close - lowest_low) / (highest_high - lowest_low)  
  - %D = SMA(%K, 3)  
  - Signals: < 20 = oversold, > 80 = overbought, crossovers indicate reversals  
  - **Files:** `src/indicators/stochastic_calculator.sh`  
  - **Verify:** %K and %D between 0-100

- [ ] **3.8 Create Williams %R calculator (williams_r_calculator.sh)**  
  - **Function:** `calc_williams_r(data_array, period=14)` → Returns Williams %R (-100 to 0)  
  - Similar to Stochastic but inverted: -20 to 0 = overbought, -80 to -100 = oversold  
  - **Files:** `src/indicators/williams_r_calculator.sh`  
  - **Verify:** Output range -100 to 0

- [ ] **3.9 Create math utilities (math_utils.sh)**  
  - **Functions:** `calc_stddev(array)`, `calc_mean(array)`, `calc_min_max(array)`, `ema_value(value, prev_ema, period)`  
  - Use `bc` or `awk` for floating-point math  
  - **Files:** `src/utils/math_utils.sh`  
  - **Verify:** Test std dev and mean calculations with known data

---

### Phase 4: Sentiment Analysis

- [ ] **4.1 Create Twitter/Reddit parser (twitter_reddit_parser.sh)**  
  - **Function:** `parse_twitter_sentiment(symbol)` → Returns count of recent tweets, sentiment summary  
  - Lightweight scraping using `curl` + `jq` (not full API; focus on accessible data)  
  - Parse Reddit r/stocks, r/investing, r/wallstreetbets for mentions  
  - Extract mention count, tone (bullish/bearish keywords)  
  - Cache results 30 minutes  
  - **Files:** `src/sentiment/twitter_reddit_parser.sh`  
  - **Verify:** Returns JSON with mention_count and sentiment_score fields

- [ ] **4.2 Create news sentiment analyzer (news_sentiment_analyzer.sh)**  
  - **Function:** `analyze_news_sentiment(articles_json)` → Returns { positive_count, negative_count, neutral_count, score (-1 to 1) }  
  - Simple keyword matching: positive (bull, surge, rally, outperform) vs. negative (crash, fall, downgrade, miss)  
  - Aggregate sentiment across articles fetched from NewsAPI  
  - **Files:** `src/sentiment/news_sentiment_analyzer.sh`  
  - **Verify:** Returns aggregated sentiment score

- [ ] **4.3 Create sentiment aggregator (sentiment_aggregator.sh)**  
  - **Function:** `aggregate_sentiment(twitter_score, reddit_score, news_score)` → Returns final sentiment (-1 to 1) with confidence  
  - Weight each source equally or by reliability  
  - Convert to 0-100 scale for confluence scoring  
  - **Files:** `src/sentiment/sentiment_aggregator.sh`  
  - **Verify:** Output is 0-100 scale representing bullish/bearish consensus

---

### Phase 5: Scoring & Confluence Engine

- [ ] **5.1 Create signal scorer (signal_scorer.sh)**  
  - **Function:** `score_indicator(indicator_name, indicator_value, threshold_config)` → Returns 0-100 score  
  - RSI: 30-50 = 0 (bearish), 50-70 = 50 (neutral), > 70 = 0 (overbought); < 30 = 100 (oversold)  
  - MACD: Positive histogram above signal = 75 (bullish), cross = 50, below = 25  
  - Bollinger: Price near lower band = 75 (buy signal), upper = 25 (sell signal)  
  - ATR: Used for risk calculation only, not direct score  
  - Sentiment: 0-100 directly maps to score  
  - **Files:** `src/scoring/signal_scorer.sh`  
  - **Verify:** All indicators score 0-100; threshold-based transitions work correctly

- [ ] **5.2 Create confluence engine (confluence_engine.sh)**  
  - **Function:** `calculate_confluence_score(rsi_score, macd_score, bb_score, sentiment_score, ...)` → Returns confidence 0-100  
  - Count how many signals agree (buy vs. sell)  
  - Confidence = (agreeing_signals / total_signals) * 100  
  - Example: 6 signals bullish, 2 neutral = 75% confidence buy  
  - Also output: "BUY" / "SELL" / "HOLD" recommendation  
  - **Files:** `src/scoring/confluence_engine.sh`  
  - **Verify:** Test with 5 buy signals = 100 confidence BUY; mixed = lower confidence HOLD

- [ ] **5.3 Create stop-loss calculator**  
  - Integrate into confluence engine or signal formatter  
  - SL = entry_price - (2 * ATR)  
  - Risk = (entry - SL) / entry * 100  
  - Display in report  
  - **Files:** Inline in `src/scoring/confluence_engine.sh` or `src/reporting/signal_formatter.sh`

---

### Phase 6: HTML Report Generation

- [ ] **6.1 Create HTML report generator template (html_report_generator.sh)**  
  - **Function:** `generate_html_report(stock_data_json, output_file)` → Writes HTML file  
  - Template includes:
    - Header: Analysis date/time, data freshness, disclaimer
    - Stock Info: Symbol, price, change %, market cap, volume
    - Signals Section: Buy/Sell/Hold with confidence meter (0-100 visual bar)
    - Indicator Table: RSI, MACD, Bollinger Bands, Stochastic values
    - Sentiment Summary: Twitter/Reddit/News sentiment with counts
    - Risk Analysis: ATR, stop-loss, risk-reward ratio
    - Charts: ASCII or SVG price chart + indicator sparklines
    - Footer: Data sources, limitations, disclaimer
  - **Files:** `src/reporting/html_report_generator.sh`  
  - **Verify:** Generate sample report and validate HTML structure with `htmllint` if available, or manual check

- [ ] **6.2 Create chart builder (chart_builder.sh)**  
  - **Function:** `build_price_chart(ohlcv_data, width=50, height=20)` → Returns ASCII or SVG chart  
  - For ASCII: Use Unicode box-drawing characters for candlesticks or line chart  
  - For SVG: Generate inline SVG with proper scaling  
  - Include simple moving averages overlay (20-day line)  
  - **Files:** `src/reporting/chart_builder.sh`  
  - **Verify:** Chart renders correctly in HTML (test in browser)

- [ ] **6.3 Create signal formatter (signal_formatter.sh)**  
  - **Function:** `format_buy_sell_signal(symbol, signal, confidence, rsi, macd, sentiment, atr)` → Returns HTML snippet  
  - Color-code: Green = strong buy, Yellow = hold, Red = strong sell  
  - Display confidence as visual meter or percentage  
  - Show reasoning: "MACD bullish cross + RSI rising + positive sentiment"  
  - **Files:** `src/reporting/signal_formatter.sh`  
  - **Verify:** Signal HTML renders inline in report with proper styling

---

### Phase 7: Error Handling, Rate Limiting & Retry

- [ ] **7.1 Integrate retry handler (retry_handler.sh)**  
  - **Function:** `retry_api_call(url, max_retries=3, backoff_multiplier=2)` → Executes curl with exponential backoff  
  - Retry on 429 (rate limit), 503 (service unavailable), network timeouts  
  - Don't retry on 401 (auth), 403 (forbidden)  
  - Wait: 1s, then 2s, then 4s  
  - **Files:** `src/utils/retry_handler.sh`  
  - **Verify:** Simulate API rate limit (429) response and confirm retry with wait

- [ ] **7.2 Implement graceful degradation**  
  - If one data source fails, continue with others  
  - If Finnhub fails, use Yahoo Finance data instead  
  - If sentiment unavailable, mark as N/A but don't block analysis  
  - Log warnings but don't exit (exit only on critical failures)  
  - **Files:** Modify all fetchers to use error_handler.sh with non-critical error levels  
  - **Verify:** Run agent with one API key invalid; should still generate partial report

- [ ] **7.3 Add input validation & sanitization**  
  - Validate stock symbols: 1-5 uppercase letters + numbers  
  - Validate API keys: non-empty, reasonable length  
  - Validate parameters: numeric ranges (RSI_PERIOD > 0, ATR_PERIOD > 0)  
  - **Files:** `src/lib/config_loader.sh` (extend with validation)  
  - **Verify:** Invalid symbol rejected; valid symbols accepted

---

### Phase 8: Testing & Validation

- [ ] **8.1 Create unit tests (tests/unit_tests.sh)**  
  - Test each indicator calculator with known inputs/outputs  
  - Test math_utils functions with edge cases (empty array, single value)  
  - Test config loader with missing/invalid config  
  - Test rate limiter prevents exceeding limits  
  - **Files:** `tests/unit_tests.sh`  
  - **Verify:** Run `bash tests/unit_tests.sh` and confirm all tests pass

- [ ] **8.2 Create integration tests (tests/integration_tests.sh)**  
  - End-to-end flow: fetch data, calculate indicators, score, generate report  
  - Use sample API responses (mock data) to avoid live API calls  
  - Verify report HTML is valid  
  - **Files:** `tests/integration_tests.sh`, `tests/data/sample_response_*.json`  
  - **Verify:** Run `bash tests/integration_tests.sh` and confirm generated report is valid HTML

- [ ] **8.3 Create sample data files (tests/data/)**  
  - `sample_response_yahoo.json`: Example OHLCV response  
  - `sample_response_alpha_vantage.json`: Example intraday data  
  - `sample_response_finnhub.json`: Example quote response  
  - **Files:** `tests/data/sample_response_*.json`  
  - **Verify:** Each sample file is valid JSON

- [ ] **8.4 Create expected output file (tests/expected_outputs/example_report.html)**  
  - Skeleton HTML with all sections for reference  
  - Use to validate generated reports have expected structure  
  - **Files:** `tests/expected_outputs/example_report.html`  
  - **Verify:** Structure matches generated report (use `diff` or HTML parser)

---

### Phase 9: Documentation

- [ ] **9.1 Create comprehensive README (README.md)**  
  - **Sections:**
    - Overview & Features (list all indicators, data sources, output format)
    - Prerequisites (curl, jq, bash 4+, optional: Python, yfinance)
    - Installation: Clone, set API keys, run `chmod +x StockSwingTrader_Agent.sh`
    - Configuration: Explain config/api_keys.conf, config/parameters.conf, watchlist.txt
    - Usage Examples: `./StockSwingTrader_Agent.sh --symbols AAPL,MSFT`, `--top-10`, `--debug`
    - Output: Point to generated HTML report in output/reports/
    - Troubleshooting: Common issues (rate limits, missing API keys, network errors)
    - Rate Limits: Summary of each API source's limits
    - Disclaimer: Analysis-only, not financial advice, paper trading only
  - **Files:** `README.md`  
  - **Verify:** README covers setup, usage, and troubleshooting; no broken links

- [ ] **9.2 Create inline code documentation**  
  - Add function headers to all .sh files with: purpose, inputs, outputs, example usage  
  - Document configuration variables in config/parameters.conf with comments  
  - **Files:** All src/**/*.sh files  
  - **Verify:** Each function has documented purpose and parameters

---

### Phase 10: Example Output Generation

- [ ] **10.1 Create example report with live data (one-time run)**  
  - Run agent against AAPL, MSFT, GOOGL with `--live-fetch` (or mock if API limits)  
  - Generate `output/reports/swing_analysis_EXAMPLE_2025-01-15.html`  
  - Commit to repo as reference for users  
  - **Files:** `output/reports/example_report_TIMESTAMP.html`  
  - **Verify:** Report displays correctly in browser (Chrome, Firefox); all signals visible

- [ ] **10.2 Create example log output (logs/example.log)**  
  - Show typical debug output with `--debug` flag  
  - Include rate limit messages, cache hits, indicator calculations  
  - **Files:** `logs/example.log`  
  - **Verify:** Log shows step-by-step execution flow

---

## Implementation Architecture

### Data Flow Diagram

```
┌─────────────────────────────────────────────────────────┐
│           StockSwingTrader_Agent.sh (Main)              │
│  ┌────────────────────────────────────────────────────┐ │
│  │ 1. Load Config & Watchlist                         │ │
│  │ 2. For each symbol:                                │ │
│  │    - Fetch OHLCV (Yahoo/Alpha Vantage)            │ │
│  │    - Fetch Live Price (Finnhub)                    │ │
│  │    - Fetch News (NewsAPI)                          │ │
│  │    - Parse Sentiment (Twitter/Reddit)             │ │
│  │    - Calculate Indicators (RSI, MACD, BB, etc.)   │ │
│  │    - Score Each Signal                            │ │
│  │    - Calculate Confluence                         │ │
│  │ 3. Generate HTML Report                            │ │
│  └────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
        ↓                    ↓                    ↓
   ┌─────────┐          ┌────────┐          ┌──────────┐
   │ Cache   │          │ Logs   │          │ Reports  │
   │ Manager │          │ (JSON) │          │ (HTML)   │
   └─────────┘          └────────┘          └──────────┘
```

### Module Dependencies

```
StockSwingTrader_Agent.sh
├── config_loader.sh
├── error_handler.sh
├── rate_limiter.sh
├── yahoo_finance_fetcher.sh → cache_manager.sh, retry_handler.sh
├── alpha_vantage_fetcher.sh → cache_manager.sh, retry_handler.sh, rate_limiter.sh
├── finnhub_fetcher.sh → retry_handler.sh, rate_limiter.sh
├── newsapi_fetcher.sh → retry_handler.sh, rate_limiter.sh
├── sma_ema_calculator.sh → math_utils.sh
├── rsi_calculator.sh → math_utils.sh
├── macd_calculator.sh → math_utils.sh, sma_ema_calculator.sh
├── bollinger_bands_calculator.sh → math_utils.sh, sma_ema_calculator.sh
├── atr_calculator.sh → math_utils.sh
├── obv_calculator.sh
├── stochastic_calculator.sh → math_utils.sh
├── williams_r_calculator.sh → math_utils.sh
├── twitter_reddit_parser.sh → cache_manager.sh, retry_handler.sh
├── news_sentiment_analyzer.sh
├── sentiment_aggregator.sh
├── signal_scorer.sh
├── confluence_engine.sh → signal_scorer.sh, atr_calculator.sh
├── html_report_generator.sh → chart_builder.sh, signal_formatter.sh
├── chart_builder.sh
└── signal_formatter.sh
```

---

## Configuration Parameters (config/parameters.conf)

```bash
# Indicator Periods
SMA_PERIODS="20 50 200"
EMA_PERIODS="12 26"
RSI_PERIOD=14
RSI_OVERBOUGHT=70
RSI_OVERSOLD=30
MACD_FAST=12
MACD_SLOW=26
MACD_SIGNAL=9
BOLLINGER_PERIOD=20
BOLLINGER_STD_DEV=2
ATR_PERIOD=14
STOCHASTIC_PERIOD=14
STOCHASTIC_K_SMOOTH=3
STOCHASTIC_D_SMOOTH=3
WILLIAMS_R_PERIOD=14

# Swing Trading Thresholds (2-5 day holds)
CONFIDENCE_STRONG_BUY=75      # ≥ this = strong buy
CONFIDENCE_BUY=60             # 60-74 = buy
CONFIDENCE_HOLD=40            # 40-59 = hold
CONFIDENCE_SELL=25            # 25-39 = sell (consider exit)
CONFIDENCE_STRONG_SELL=10     # ≤ this = strong sell

# Risk Management
STOP_LOSS_PERCENT=5           # Exit if loss reaches 5%
STOP_LOSS_ATR_MULTIPLIER=2    # SL = entry - (2 * ATR)
TARGET_PROFIT_PERCENT=8       # Exit at 8% gain

# Data Freshness
CACHE_MAX_AGE_MINUTES=60      # Refresh if > 60 min old
INTRADAY_DATA_POINTS=60       # Use last 60 5-min candles

# Sentiment Weights
SENTIMENT_WEIGHT=0.2          # 20% of total score
TECHNICAL_WEIGHT=0.8          # 80% of total score
```

---

## Rate Limit Management

| Source | Limit | Strategy |
|--------|-------|----------|
| Yahoo Finance | Unlimited (but practical ~2000/day) | Fetch once, cache aggressively |
| Alpha Vantage | 5 calls/min, 500/day | Queue requests, stagger by 12s per call |
| Finnhub | 60 calls/min | Queue requests, sleep if needed |
| NewsAPI | Depends on tier; typically 100/day | Fetch once daily, cache 24h |
| Twitter/Reddit | No hard limit (scraping) | Throttle to 1 req/min per symbol |

**Implementation:** `rate_limiter.sh` tracks last call timestamp per API and enforces minimum wait time.

---

## Error Handling Strategy

| Scenario | Action | Exit Code |
|----------|--------|-----------|
| Missing API key | Log warning, skip that data source, continue | 0 (non-fatal) |
| Rate limit hit | Wait & retry (up to 3x), log delay | 0 (recoverable) |
| Network timeout | Retry with exponential backoff | 3 (data fetch error) |
| Invalid stock symbol | Log error, skip symbol, continue with others | 0 (non-fatal) |
| Config parse error | Log error, exit immediately | 2 (config error) |
| Out of memory (unlikely) | Log error, exit | 1 (general error) |

---

## Testing Approach

### Unit Tests
- Verify each calculator module with hardcoded test cases
- Test math edge cases (empty data, NaN, division by zero)
- Validate config loader and error handler functions

### Integration Tests
- Mock API responses from `tests/data/sample_response_*.json`
- Run full pipeline: data → indicators → score → report
- Validate HTML report structure and content

### Manual Smoke Tests
- Run against 1 symbol (AAPL) with `--live-fetch` (after setting real API keys)
- Verify HTML report renders in browser
- Check logs for errors or warnings

---

## Success Criteria

1. ✅ **All 8 technical indicators calculate correctly** (verified by unit tests)
2. ✅ **Confidence scoring algorithm produces 0-100 output** with BUY/SELL/HOLD signals
3. ✅ **HTML report generates without errors** and displays correctly in browser
4. ✅ **Rate limits never exceeded** (tracked via rate_limiter.sh logs)
5. ✅ **Graceful degradation** if one data source fails (report still generates)
6. ✅ **Cache reduces API calls** by reusing data within TTL
7. ✅ **Documentation is complete** (README covers setup, usage, troubleshooting)
8. ✅ **Example reports generated** and included in repo

---

## Next Steps (Post-Implementation)

- Add more stocks to watchlist (auto-detect top gainers/losers via Finnhub)
- Implement backtesting to validate signal accuracy historically
- Add email/Slack alerts for strong buy/sell signals
- Create web dashboard frontend (separate from shell agent)
- Integrate with paper trading API (e.g., Alpaca) for simulated trades
- Add machine learning confidence calibration (track signal accuracy over time)

---

**Last Updated:** 2025-01-15  
**Status:** Ready for implementation (Phases 1-10)  
**Estimated Effort:** 40-60 hours for full implementation + testing
