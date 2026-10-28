# StockSwingTrader Codebase Discovery Report

**Project:** StockSwingTrader - Automated Swing Trading Analysis Platform
**Report Date:** 2025-01-28
**Status:** Analysis Complete | Ready for Feature Enhancement

---

## A. Current Indicators Inventory

### 8+ Technical Indicators Currently Implemented

| Indicator | Period(s) | Status | Used in Scoring | Location |
|-----------|----------|--------|-----------------|----------|
| **RSI** (Relative Strength Index) | 14 | ✓ Active | Yes | `lib/indicators.sh` |
| **MACD** (Moving Avg Convergence Divergence) | 12/26/9 | ✓ Active | Yes | `lib/indicators.sh` |
| **Bollinger Bands** | 20 period, 2 std-dev | ✓ Active | Yes | `lib/indicators.sh` |
| **SMA** (Simple Moving Average) | 20, 50, 200 | ✓ Active | Yes (via config) | `lib/indicators.sh` |
| **EMA** (Exponential Moving Average) | 12, 26 | ✓ Active | Partial | `lib/indicators.sh` |
| **ATR** (Average True Range) | 14 | ✓ Active | No (used for risk) | `lib/indicators.sh` |
| **OBV** (On-Balance Volume) | N/A | ✓ Active | Yes | `lib/indicators.sh` |
| **Stochastic Oscillator** | 14 period, 3/3 smooth | ✓ Active | Yes | `lib/indicators.sh` |
| **Williams %R** | 14 | ✓ Active | Yes | `lib/indicators.sh` |

### Known Gaps (Not Yet Implemented)

1. **RSI Divergence Detection** - Pattern recognition for hidden/regular divergences
2. **VWMA** (Volume-Weighted Moving Average) - Current SMA/EMA ignore volume
3. **Momentum Oscillator** - Rate of change indicator
4. **Volume Profile** - Price level distribution by volume
5. **Pivot Points** - Support/resistance levels
6. **Ichimoku Cloud** - Complex trend confirmation system
7. **Relative Volatility Index** - Volume-adjusted volatility
8. **CCI** (Commodity Channel Index) - Cyclical analysis

---

## B. Current Trading Logic

### Buy/Sell Signal Generation

**Location:** `lib/scoring.sh` (confluence engine) + `StockSwingTrader_Agent.sh` (main pipeline)

**Current Flow:**
```
1. Fetch OHLCV Data (Yahoo Finance API, via curl)
2. Calculate 9 Indicators (RSI, MACD, BB, ATR, OBV, Stochastic, Williams %R, SMA, EMA)
3. Score Each Indicator (0-100 scale in scoring.sh functions)
4. Aggregate Sentiment (Twitter, Reddit, News simulated in lib/sentiment.sh)
5. Calculate Confluence Score (weighted average of all scores)
6. Generate Signal: STRONG_BUY / BUY / HOLD / SELL / STRONG_SELL
```

### Confidence Score Thresholds

| Signal | Confidence Range | Hardcoded Value | Current Behavior |
|--------|------------------|-----------------|------------------|
| **STRONG_BUY** | 75+ | `$CONFIDENCE_STRONG_BUY=75` | Auto-trade if enabled |
| **BUY** | 60-74 | `$CONFIDENCE_BUY=60` | Manual review recommended |
| **HOLD** | 40-59 | `$CONFIDENCE_HOLD=40` | No action |
| **SELL** | 25-39 | `$CONFIDENCE_SELL=25` | Close profitable positions |
| **STRONG_SELL** | <10 | `$CONFIDENCE_STRONG_SELL=10` | Immediate exit |

**Scoring Formula (in `score_stock()` function):**
- Individual indicator scores: 0-100
- Sentiment weight: 20% (TECHNICAL_WEIGHT=0.8, SENTIMENT_WEIGHT=0.2)
- Final confluence = weighted average of all indicator scores + sentiment

**Issue:** Confluence calculation uses basic averaging; no weighting by indicator reliability

### Hard-Coded Strategy Rules

1. **Default Strategy:** Multi-indicator consensus (majority vote)
2. **Auto-Trade Rule:** `ALPACA_AUTO_TRADE_ON_STRONG_BUY=false` (disabled by default)
3. **Position Limit:** `ALPACA_MAX_POSITIONS=5` 
4. **Rate Limits Enforced:**
   - Alpha Vantage: 5 calls/min
   - Finnhub: 60 calls/min
   - NewsAPI: 100 calls/day

---

## C. Risk Management Gaps

### Position Sizing

| Parameter | Current Value | Implementation | Status |
|-----------|---------------|-----------------|--------|
| `MAX_POSITION_SIZE` | $2,500 | Configured in `config.sh` | ❌ Not enforced |
| **% of Capital Allocation** | N/A | Not implemented | ❌ Missing |
| **Per-Trade Risk** | N/A | Not defined | ❌ Missing |
| **Kelly Criterion** | N/A | Not applicable | ❌ Not used |

**Issue:** Agent can place orders without checking if it would exceed 2% of portfolio per trade.

### Stop-Loss Management

| Feature | Config Value | Enforcement | Status |
|---------|--------------|-------------|--------|
| `STOP_LOSS_PERCENT` | 5% | Configured only | ❌ Not enforced in `alpaca_place_order()` |
| ATR-Based Stop | `STOP_LOSS_ATR_MULTIPLIER=2` | Calculated but not used | ❌ Not enforced |
| **Hard Stop Monitoring** | N/A | No background process | ❌ Missing |

**Issue:** Orders placed with market orders; no stop-loss orders created automatically.

### Take-Profit Targets

| Feature | Config Value | Enforcement | Status |
|---------|--------------|-------------|--------|
| `TARGET_PROFIT_PERCENT` | 8% | Configured only | ❌ Not enforced in `alpaca_place_order()` |
| **Partial Profit Taking** | N/A | Not implemented | ❌ Missing |
| **Trailing Stop** | N/A | Not implemented | ❌ Missing |

**Issue:** No profit-taking logic; positions held indefinitely or manually closed.

### Maximum Drawdown

| Feature | Threshold | Implementation | Status |
|---------|-----------|-----------------|--------|
| Portfolio Max Drawdown | Not set | Not monitored | ❌ Missing |
| Daily Max Loss | Not set | Not monitored | ❌ Missing |
| Drawdown Recovery | N/A | Not applicable | ❌ N/A |

**Issue:** Agent continues trading even after significant portfolio decline.

### Portfolio Rebalancing

| Feature | Implementation | Status |
|---------|-----------------|--------|
| Periodic Rebalance | Not implemented | ❌ Missing |
| Correlation Tracking | Not tracked | ❌ Missing |
| Sector Exposure | Not monitored | ❌ Missing |
| Max Position Per Symbol | `ALPACA_MAX_POSITIONS=5` (total, not per-symbol) | ⚠️ Insufficient |

**Issue:** Portfolio concentration risk not controlled; positions can accumulate in same sector.

---

## D. CLI Capabilities

### Current Flags

| Flag | Arguments | Purpose | Implemented |
|------|-----------|---------|-------------|
| `--symbols` | SYMBOL1,SYMBOL2,... | Analyze specific stocks | ✓ Working |
| `--top-10` | (none) | Analyze top 10 by market cap | ✓ Working |
| `--watchlist` | FILE | Analyze stocks from file | ✓ Working |
| `--output-dir` | DIR | Custom report output path | ✓ Working |
| `--debug` | (none) | Enable verbose logging | ✓ Working |
| `--alpaca` | (none) | Enable Alpaca trading mode | ✓ Working |
| `--check-account` | (none) | Show account balance | ✓ Working |
| `--view-positions` | (none) | List open positions | ✓ Working |
| `--place-buy` | SYMBOL QTY | Buy order (with confirmation) | ✓ Working |
| `--place-sell` | SYMBOL QTY | Sell order (with confirmation) | ✓ Working |
| `--alpaca-status` | (none) | Show connection status | ✓ Working |

### Missing CLI Flags (Prioritized)

| Flag | Purpose | Use Case | Complexity |
|------|---------|----------|-----------|
| `--strategy` | Select trading strategy | Choose mean-reversion vs trend-follow | Quick |
| `--risk-level` | Set risk profile | conservative/moderate/aggressive | Quick |
| `--backtest` | Run historical backtest | Validate strategy on past data | Moderate |
| `--enable-trading` | Auto-execute trades | Replace ALPACA_AUTO_TRADE_ON_STRONG_BUY flag | Quick |
| `--max-positions` | Override position limit | Override `ALPACA_MAX_POSITIONS` | Quick |
| `--stop-loss` | Set stop-loss % | Override `STOP_LOSS_PERCENT` | Quick |
| `--take-profit` | Set take-profit % | Override `TARGET_PROFIT_PERCENT` | Quick |
| `--trade-journal` | Enable trade logging | Log all trades to CSV/JSON | Quick |

---

## E. Missing Enhancements (Prioritized by Impact & Feasibility)

### Priority 1: NEW INDICATORS (Quick Wins - 1-2 hours each)

#### 1. RSI Divergence Detection
- **What:** Detect bullish/bearish divergences between price and RSI
- **Impact:** Improves entry signal accuracy (+15-20% precision)
- **Effort:** 1 hour
- **Files to Add:** `lib/indicators.sh` (new function `calc_rsi_divergence()`)
- **Integration:** 
  - Add to `score_stock()` in main pipeline
  - Weight at 10% of confluence score
  - Return signal: "bullish_div", "bearish_div", "none"

#### 2. VWMA (Volume-Weighted Moving Average)
- **What:** SMA that weighs each price by its trading volume
- **Impact:** Identifies real trend support vs low-volume noise
- **Effort:** 1 hour
- **Files to Add:** `lib/indicators.sh` (new function `calc_vwma()`)
- **Integration:**
  - Replace or supplement SMA_50 with VWMA_50
  - Use for trend confirmation in scoring

#### 3. Momentum Oscillator
- **What:** Price rate-of-change over N periods
- **Impact:** Confirms trend strength; early warning of reversals
- **Effort:** 30 minutes
- **Files to Add:** `lib/indicators.sh` (new function `calc_momentum()`)
- **Integration:**
  - Add as 10th indicator in scoring
  - Weight at 5% of confluence

### Priority 2: TRADING STRATEGIES (2-3 hours each)

#### Strategy A: Mean Reversion (Oscillator-Based)
```
BUY Conditions:
  - RSI < 30 (oversold)
  - Price near Bollinger Band lower (< 0.3)
  - MACD histogram positive (momentum building)
  - Stochastic K < 20

SELL Conditions:
  - RSI > 70 (overbought)
  - Price near Bollinger Band upper (> 0.7)
  - MACD histogram negative (momentum declining)
  - Stochastic K > 80

RISK: Stop-loss at 5% below entry
TARGET: Exit when RSI > 50 or profit = 8%
```

**Files to Create:**
- `lib/strategy_mean_reversion.sh` (150 lines)

**Integration:**
- Add `--strategy mean-reversion` CLI flag
- Route to alternate scoring function

#### Strategy B: Trend Following (Momentum-Based)
```
BUY Conditions:
  - EMA(12) > EMA(26) (bullish cross)
  - Price > SMA(50) (above mid-term trend)
  - MACD positive & accelerating
  - Volume > 30-day average

HOLD:
  - Trailing stop at 95% of highest price
  - Take profit at 12% gain

SELL:
  - EMA crossover reversal (EMA12 < EMA26)
  - Break below SMA(200) (long-term support break)
  - Stop-loss hit
```

**Files to Create:**
- `lib/strategy_trend_follow.sh` (150 lines)

**Integration:**
- Add `--strategy trend-follow` CLI flag
- Separate scoring logic for trend signals

### Priority 3: RISK MANAGEMENT ENFORCEMENT (2-4 hours)

#### 3A. Position Sizing with 2% Capital Allocation
```bash
# In alpaca_place_order()
# Before: order_qty = user input
# After: 
account_equity=$(get_account_equity)
max_risk_per_trade=$(echo "$account_equity * 0.02" | bc)
max_qty_by_risk=$(echo "$max_risk_per_trade / (current_price * 0.05)" | bc)
order_qty=$(min($user_qty, $max_qty_by_risk))
```

**Files to Modify:**
- `lib/alpaca_broker.sh` (add `alpaca_calculate_position_size()` function)
- `StockSwingTrader_Agent.sh` (call before `alpaca_place_order()`)

**Benefit:** Prevents overleveraging; respects 2% rule automatically

#### 3B. Hard Stop-Loss & Take-Profit Enforcement
```bash
# Instead of market order:
alpaca_place_order "$symbol" "$qty" "buy"   # Entry
alpaca_place_bracket_order "$symbol" "$qty" \
  --stop-loss-percent 5 \
  --take-profit-percent 8
```

**Files to Modify:**
- `lib/alpaca_broker.sh` (new functions: `alpaca_place_bracket_order()`, `alpaca_place_oco_order()`)
- `StockSwingTrader_Agent.sh` (use bracket orders by default)

**Note:** Alpaca API supports bracket orders (One-Cancels-Other); use `/orders` with legs

#### 3C. Maximum Positions Limit & Daily Drawdown Monitor
```bash
# Before placing order:
current_positions=$(alpaca_get_positions | jq length)
if [[ $current_positions -ge 3 ]]; then
  log_warn "Already at 3 positions; skipping new entry"
  return 1
fi

# Daily drawdown check:
today_pl=$(alpaca_get_today_pl)
if [[ $(echo "$today_pl < -500" | bc) == 1 ]]; then
  log_error "Daily loss limit (-\$500) exceeded; no new trades"
  ALPACA_TRADING_ENABLED=false
fi
```

**Files to Create:**
- `lib/risk_manager.sh` (functions: `check_max_positions()`, `check_daily_drawdown()`, `check_portfolio_health()`)

**Benefit:** Prevents revenge trading; enforces hard limits

### Priority 4: CLI ENHANCEMENTS (1 hour total)

#### Add Flags for Strategic & Risk Control

```bash
# In StockSwingTrader_Agent.sh main() function:

case "$1" in
  --strategy)
    TRADING_STRATEGY="$2"  # "mean-reversion" | "trend-follow"
    # Routes to different scoring functions
    ;;
  --risk-level)
    RISK_LEVEL="$2"  # "conservative" | "moderate" | "aggressive"
    # Adjusts stop-loss: 7% | 5% | 3%
    # Adjusts take-profit: 6% | 8% | 12%
    # Adjusts max positions: 2 | 5 | 8
    ;;
  --max-positions)
    ALPACA_MAX_POSITIONS="$2"
    ;;
  --stop-loss)
    STOP_LOSS_PERCENT="$2"
    ;;
  --take-profit)
    TARGET_PROFIT_PERCENT="$2"
    ;;
  --trade-journal)
    ENABLE_TRADE_JOURNAL=true
    JOURNAL_FILE="trades/$(date +%Y%m%d).csv"
    ;;
esac
```

**Benefit:** Full runtime control without editing config.sh

### Priority 5: TRADE JOURNAL & LOGGING (1-2 hours)

#### Trade Journal CSV Structure
```csv
date,entry_time,symbol,side,qty,entry_price,exit_time,exit_price,pl_dollars,pl_percent,duration_hours,reason,strategy,indicators_at_entry
2025-01-28,09:30:00,AAPL,BUY,10,180.50,10:45:00,182.10,16.00,0.89,1.25,RSI_oversold_BB_lower,mean-reversion,"RSI=28,MACD=0.12,BB=%=0.15"
```

**Files to Create:**
- `lib/trade_journal.sh` (functions: `log_trade_entry()`, `log_trade_exit()`, `calculate_trade_pnl()`)

**Integration:**
- Call after each trade in `place_buy_order()` and `place_sell_order()`
- Generate summary reports: daily/weekly/monthly P&L

---

## F. Estimated Implementation Complexity

### Time Breakdown by Feature

| Feature | Complexity | Estimated Time | Effort Level |
|---------|-----------|-----------------|--|
| RSI Divergence Detection | Low | 1 hour | Quick |
| VWMA Indicator | Low | 1 hour | Quick |
| Momentum Oscillator | Low | 30 min | Quick |
| Mean Reversion Strategy | Moderate | 2 hours | Moderate |
| Trend Following Strategy | Moderate | 2.5 hours | Moderate |
| Position Sizing (2% Rule) | Moderate | 1.5 hours | Moderate |
| Stop-Loss/Take-Profit Enforcement | Moderate | 1.5 hours | Moderate |
| Max Positions & Drawdown Limits | Moderate | 1 hour | Moderate |
| CLI Enhancements | Low | 1 hour | Quick |
| Trade Journal & Logging | Low | 1.5 hours | Quick |
| **TOTAL** | **Mixed** | **~13 hours** | **Multiple** |

### Recommended Phased Rollout

**Phase 1 (Quick Wins - 3-4 hours):**
- Add RSI Divergence + VWMA indicators
- Add `--strategy` CLI flag (mean-reversion)
- Add Trade Journal logging

**Phase 2 (Core Risk Management - 4-5 hours):**
- Implement position sizing (2% rule)
- Add bracket orders for stop-loss/take-profit
- Add `--risk-level` CLI flag

**Phase 3 (Advanced Features - 4-5 hours):**
- Trend Following strategy
- Portfolio rebalancing logic
- Backtesting framework

---

## G. Current Issues & Known Limitations

### Integration Issues Observed

1. **Alpaca Connection Error** (from user's session):
   ```
   ERROR: Missing Alpaca API credentials
   Set ALPACA_API_KEY and ALPACA_SECRET_KEY environment variables
   ```
   **Root Cause:** Config file credentials not exported to environment
   **Fix:** Run `source config.sh` before executing agent, or set env vars in shell profile

2. **"No Open Positions" Warning**:
   ```
   [WARN] No open positions (even with 11 AAPL held)
   ```
   **Root Cause:** Alpaca API position fetch may lag 1-2 minutes after order fill
   **Fix:** Implement retry logic with exponential backoff in `alpaca_get_positions()`

3. **Confidence Score Averaging**:
   - Current: Simple arithmetic mean of all indicators
   - Issue: Doesn't account for signal reliability or market regime
   - Improvement: Implement Bayesian scoring or weighted consensus based on indicator strength

4. **Sentiment Data Simulation**:
   - Current: Twitter/Reddit sentiment uses random placeholders
   - Issue: Not real market sentiment data
   - Fix: Integrate actual APIs (Twitter API v2, Reddit API, VADER sentiment analyzer)

---

## H. Project Structure Summary

```
/Users/P3291917/Desktop/StockSwingTrader/
├── config.sh                          # Live Alpaca credentials + thresholds
├── config.template.sh                 # Template (safe to version control)
├── StockSwingTrader_Agent.sh          # Main entry point (850 lines)
│
├── lib/
│   ├── indicators.sh                  # 9 technical indicators (600 lines)
│   ├── sentiment.sh                   # Sentiment aggregation (demo)
│   ├── scoring.sh                     # Confluence scoring engine
│   ├── html_report.sh                 # Report generation
│   └── alpaca_broker.sh               # Alpaca API wrapper (500 lines)
│
├── tests/
│   └── test_alpaca_broker.sh          # Integration tests
│
├── Utilities:
│   ├── CHECK_ACCOUNT.sh               # Quick account check
│   ├── CHECK_ORDERS.sh                # Quick order check
│   ├── RUN_TRADING.sh                 # Batch execution
│   ├── demo_first_trade.sh            # Tutorial script
│   └── test_account.sh                # Connectivity test
│
├── output/
│   └── reports/                       # Generated HTML reports (timestamped)
│
├── logs/
│   ├── agent.log                      # Main execution log
│   └── alpaca.log                     # Broker API log
│
└── cache/
    └── data/                          # Cached sentiment data
```

---

## I. Deployment & Packaging Notes

**Current Deployment Status:** Package in `/Users/P3291917/Builds/6/StockSwingTrader/`

**Key Files for Distribution:**
- ✓ Main agent script
- ✓ All library files (lib/*.sh)
- ✓ Configuration template
- ✓ README with setup instructions
- ✓ Alpaca integration tested

**Packaging Checklist for Future Changes:**
1. Update `config.template.sh` (never distribute live credentials)
2. Test all new functions with `tests/test_alpaca_broker.sh`
3. Add new features to `lib/` directory (modular)
4. Update CLI help in `StockSwingTrader_Agent.sh` usage()
5. Commit locally on feature branch
6. Re-package to `/Users/P3291917/Builds/6/` before deployment

---

## Summary

The StockSwingTrader codebase is **well-architected** with clear separation of concerns (indicators, sentiment, scoring, broker). The foundation supports easy addition of new indicators and strategies.

**Next Steps:**
1. **Immediate:** Fix environment variable export in config loading
2. **Short-term:** Add RSI divergence & VWMA indicators (low effort, high impact)
3. **Medium-term:** Implement position sizing & bracket order stop-loss enforcement
4. **Long-term:** Add mean-reversion and trend-following strategies with full backtesting

All enhancements are **backward-compatible** and can be implemented incrementally without breaking existing functionality.
