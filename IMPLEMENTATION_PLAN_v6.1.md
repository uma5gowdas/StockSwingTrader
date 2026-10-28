# StockSwingTrader v6.1 Implementation Plan

**Plan Date:** 2025-01-28  
**Target Version:** v6.1 (from v6.0)  
**Status:** Ready for Implementation  
**Design Reference:** design.md (APPROVED)

This plan translates the approved design into concrete, step-by-step implementation work. Each step leaves the codebase in a buildable, testable state.

---

## PHASE 1: Foundation (Centralized Configuration & Wrappers)

### 1. Create lib/trading_thresholds.sh
   **What:** Create centralized configuration file with all trading thresholds, indicator parameters, and risk management constants used across all new v6.1 modules.
   
   **Files:** 
   - Create: `lib/trading_thresholds.sh`
   
   **Verify:** 
   ```bash
   source lib/trading_thresholds.sh
   [[ -z "$MR_RSI_ENTRY_OVERSOLD" ]] && echo "FAILED" || echo "PASSED"
   [[ "$MR_RSI_ENTRY_OVERSOLD" -eq 30 ]] && echo "Value correct"
   ```

### 2. Create lib/alpaca_wrappers.sh
   **What:** Create wrapper functions that map v6.1 design calls (`alpaca_get_account_equity`, `alpaca_get_bracket_order`, etc.) to existing Alpaca API, enabling strategies to use high-level calls. Includes bracket order placement (entry + stop-loss + take-profit atomically).
   
   **Files:** 
   - Create: `lib/alpaca_wrappers.sh`
   
   **Verify:** 
   ```bash
   source lib/alpaca_wrappers.sh
   declare -f alpaca_get_account_equity > /dev/null && echo "PASSED" || echo "FAILED"
   declare -f alpaca_place_bracket_order > /dev/null && echo "PASSED" || echo "FAILED"
   ```

---

## PHASE 2: New Indicators

### 3. Create lib/indicators_new.sh with three new indicators
   **What:** Implement 3 new indicators (RSI Divergence, VWMA, Momentum Oscillator) with all helper functions fully defined. Each indicator outputs JSON with signal/trend classification.
   
   **Key Functions:**
   - `calc_rsi_divergence()` with helpers `is_swing_low()`, `is_swing_high()`, `calc_div_strength()`
   - `calc_vwma()` for volume-weighted moving average with ABOVE/BELOW/AT signal
   - `calc_momentum()` with helper `calc_avg_daily_change()` for momentum trend
   
   **Files:** 
   - Create: `lib/indicators_new.sh` (~400 lines)
   
   **Verify:** 
   ```bash
   cd /Users/P3291917/Builds/6
   bash test/test_indicators_new.sh
   # Should test: RSI divergence detection, VWMA calculation, momentum trend
   # Expected: All 3 indicators produce valid JSON with correct signal fields
   ```

### 4. Integrate new indicators into lib/scoring.sh
   **What:** Add weights for new indicators (RSI_DIV: 10%, VWMA: 10%, MOMENTUM: 10%) to scoring calculation. Modify the confluence scoring function to call the 3 new indicator functions and blend their signals into overall score.
   
   **Files:** 
   - Modify: `lib/scoring.sh`
   - Reference: `lib/trading_thresholds.sh` (for weight constants)
   
   **Verify:** 
   ```bash
   cd /Users/P3291917/Builds/6
   bash test/test_scoring_integration.sh
   # Should verify: 
   # - New indicator weights included in total (sum = 100%)
   # - New indicators contribute to final score
   # - Backward compatible with existing 9 indicators
   ```

---

## PHASE 3: Risk Management

### 5. Create lib/risk_management.sh
   **What:** Implement position sizing (Kelly Criterion), stop-loss/take-profit enforcement, portfolio limits, and daily drawdown monitoring. Core functions: `calculate_position_size()`, `monitor_all_positions()`, `query_trade_journal()` (resolution for MEDIUM-2), and `enforce_daily_drawdown_limit()`.
   
   **Files:** 
   - Create: `lib/risk_management.sh` (~150 lines)
   - Reference: `lib/alpaca_wrappers.sh` (for position queries)
   - Reference: `lib/trade_journal.sh` (will be created in Phase 4)
   
   **Verify:** 
   ```bash
   cd /Users/P3291917/Builds/6
   bash test/test_risk_management.sh
   # Should test:
   # - Position sizing: 2% risk → correct qty calculation
   # - Stop-loss enforcement at threshold
   # - Portfolio limit (max 3 concurrent positions in MODERATE mode)
   ```

---

## PHASE 4: Trade Journal

### 6. Create lib/trade_journal.sh
   **What:** Implement trade logging with entry/exit JSON format, timestamp tracking, strategy attribution, and query functions. Core functions: `log_trade_entry()`, `log_trade_exit()`, `query_trade_journal()`, `export_backtest_data()`. Trade ID format: `T[DATE]_[SYMBOL]_[SEQ]`.
   
   **Files:** 
   - Create: `lib/trade_journal.sh` (~100 lines)
   - Logs output: `logs/trades.json` (auto-created)
   - Backtest export: `logs/backtest_results.json`
   
   **Verify:** 
   ```bash
   cd /Users/P3291917/Builds/6
   bash test/test_trade_journal.sh
   # Should test:
   # - Entry logged to logs/trades.json with correct fields
   # - Exit updates existing trade record
   # - query_trade_journal returns last OPEN trade for symbol
   # - Export produces valid backtest JSON
   ```

---

## PHASE 5: Strategies

### 7. Create lib/strategy_mean_reversion.sh
   **What:** Implement mean reversion strategy with entry/exit logic. Entry: RSI < 30, price near lower Bollinger Band (within 2%), volume > 20-day avg, MACD positive. Exit: RSI > 70, +8% take-profit, -3% stop-loss. Uses `calculate_position_size()` and logs trades via `log_trade_entry()`.
   
   **Files:** 
   - Create: `lib/strategy_mean_reversion.sh` (~200 lines)
   - Reference: `lib/trading_thresholds.sh` (for MR_RSI_ENTRY_OVERSOLD, etc.)
   - Reference: `lib/risk_management.sh` (for position sizing)
   - Reference: `lib/trade_journal.sh` (for logging)
   
   **Verify:** 
   ```bash
   cd /Users/P3291917/Builds/6
   bash test/test_strategy_mean_reversion_cycle.sh
   # Simulate oversold conditions (RSI=28, price near lower BB)
   # Expected: Entry triggered, position logged with stop/target
   ```

### 8. Create lib/strategy_trend_follow.sh
   **What:** Implement trend following strategy with entry/exit logic. Entry: EMA(12) > EMA(26) bullish crossover, price > SMA(50), volume > 30-day avg, price > SMA(200). Exit: EMA crossover reversal, +12% take-profit, stop-loss at entry - (1.5 × ATR). Uses position sizing and trade journal.
   
   **Files:** 
   - Create: `lib/strategy_trend_follow.sh` (~200 lines)
   - Reference: `lib/trading_thresholds.sh` (for TF_EMA_FAST_PERIOD, etc.)
   - Reference: `lib/risk_management.sh` (for position sizing)
   - Reference: `lib/trade_journal.sh` (for logging)
   
   **Verify:** 
   ```bash
   cd /Users/P3291917/Builds/6
   bash test/test_strategy_trend_follow_cycle.sh
   # Simulate bullish trend (EMA crossover, price > SMA(50))
   # Expected: Entry triggered, position logged with ATR-based stop
   ```

---

## PHASE 6: CLI Integration

### 9. Modify StockSwingTrader_Agent.sh - Add CLI flags and strategy selection
   **What:** Add 4 new command-line flags: `--strategy {mean_reversion|trend_follow|both}`, `--risk-level {conservative|moderate|aggressive}`, `--position-risk-pct NUM`, `--max-positions NUM`, `--monitor-positions`. Implement flag validation, precedence logic (explicit > risk_level > config > defaults), and conditional strategy module loading. Update help text.
   
   **Files:** 
   - Modify: `StockSwingTrader_Agent.sh`
   - Reference: `lib/trading_thresholds.sh` (for default constants)
   
   **Verify:** 
   ```bash
   cd /Users/P3291917/Builds/6
   ./StockSwingTrader_Agent.sh --help 2>&1 | grep -c "\-\-strategy" && echo "PASSED" || echo "FAILED"
   ./StockSwingTrader_Agent.sh --strategy mean_reversion --buy 5 AAPL 2>&1 | grep -q "Strategy: mean_reversion" && echo "PASSED"
   ./StockSwingTrader_Agent.sh --risk-level aggressive --info 2>&1 | grep -q "risk_level=aggressive" && echo "PASSED"
   ```

### 10. Modify StockSwingTrader_Agent.sh - Add background position monitoring
   **What:** Implement `--monitor-positions` flag that runs continuous position monitoring loop. Calls `monitor_all_positions()` every 30 seconds, checking stop-loss and take-profit triggers. Can be backgrounded or run via cron/systemd. Add function to gracefully handle SIGINT (Ctrl+C).
   
   **Files:** 
   - Modify: `StockSwingTrader_Agent.sh` (append monitoring function)
   
   **Verify:** 
   ```bash
   cd /Users/P3291917/Builds/6
   timeout 10 ./StockSwingTrader_Agent.sh --monitor-positions 2>&1 | head -20
   # Should show: monitoring started, position checks every 30 sec
   # Should exit cleanly after timeout
   ```

---

## PHASE 7: Testing & Validation

### 11. Run full test suite to verify no regressions
   **What:** Execute all existing v6.0 tests plus new v6.1 tests. Ensure 65+ existing tests still pass, and new indicator/strategy/risk management tests pass. Verify backward compatibility.
   
   **Files:** 
   - Run: `bash test/run_all_tests.sh`
   
   **Verify:** 
   ```bash
   cd /Users/P3291917/Builds/6
   bash test/run_all_tests.sh 2>&1 | tee test_results.log
   # Expected: All tests pass
   # Count: "passed X tests, 0 failed"
   ```

### 12. Backtest both strategies on historical data (paper trading)
   **What:** Run mean_reversion and trend_follow strategies on 4 weeks of AAPL historical data (mock market data). Verify entry/exit triggers, position sizing, stop-loss enforcement. Generate backtest report with win rate, average P&L, drawdown.
   
   **Files:** 
   - Run: `bash test/backtest_mean_reversion.sh` and `bash test/backtest_trend_follow.sh`
   - Reference: `logs/backtest_results.json`
   
   **Verify:** 
   ```bash
   cd /Users/P3291917/Builds/6
   bash test/backtest_mean_reversion.sh
   # Expected: 6-8 trades, 55-65% win rate
   jq '.[] | select(.win == true) | .symbol' logs/backtest_results.json | wc -l
   ```

---

## PHASE 8: Packaging & Deployment

### 13. Update PACKAGE_VERSION.txt to v6.1
   **What:** Update version file from 6.0 to 6.1.
   
   **Files:** 
   - Modify: `PACKAGE_VERSION.txt`
   
   **Verify:** 
   ```bash
   cat PACKAGE_VERSION.txt
   # Expected: "6.1"
   ```

### 14. Create StockSwingTrader_v6.1_Alpaca_Deployable.tar.gz
   **What:** Package all v6.1 files (source, config, tests, README, CHANGELOG) into a single deployable archive. Include all new lib/ files, updated agent, updated docs. Verify tar integrity.
   
   **Files:** 
   - Create: `StockSwingTrader_v6.1_Alpaca_Deployable.tar.gz`
   
   **Verify:** 
   ```bash
   cd /Users/P3291917/Builds/6
   tar -tzf StockSwingTrader_v6.1_Alpaca_Deployable.tar.gz | head -20
   # Should include:
   # - lib/trading_thresholds.sh
   # - lib/alpaca_wrappers.sh
   # - lib/indicators_new.sh
   # - lib/strategy_mean_reversion.sh
   # - lib/strategy_trend_follow.sh
   # - lib/risk_management.sh
   # - lib/trade_journal.sh
   # - StockSwingTrader_Agent.sh
   # - CHANGELOG.md
   ```

### 15. Update README.md with v6.1 features
   **What:** Add documentation for new flags (`--strategy`, `--risk-level`, etc.), new indicators (RSI Divergence, VWMA, Momentum), new strategies (Mean Reversion, Trend Following), risk management features. Include usage examples.
   
   **Files:** 
   - Modify: `README.md`
   
   **Verify:** 
   ```bash
   grep -q "RSI Divergence" README.md && echo "PASSED"
   grep -q "\-\-strategy" README.md && echo "PASSED"
   grep -q "Mean Reversion" README.md && echo "PASSED"
   ```

### 16. Update CHANGELOG.md with v6.1 changes
   **What:** Document all new features, bug fixes, and improvements. Include section for v6.1 (from v6.0) with dates, items, and known limitations.
   
   **Files:** 
   - Modify: `CHANGELOG.md`
   
   **Verify:** 
   ```bash
   grep -A 5 "^## v6.1" CHANGELOG.md && echo "PASSED"
   ```

---

## Implementation Order & Dependencies

**Sequential (no parallelization):**

1. Phase 1 (Foundation): Steps 1–2 — Config & wrappers must exist before any other module
2. Phase 2 (Indicators): Steps 3–4 — Indicators needed for strategy entry logic
3. Phase 3 (Risk Mgmt): Step 5 — Uses trade journal (creates dependency, but can stub for now)
4. Phase 4 (Trade Journal): Step 6 — Needed by risk management and strategies
5. Phase 5 (Strategies): Steps 7–8 — Both depend on all of above
6. Phase 6 (CLI): Steps 9–10 — Integration after strategies work
7. Phase 7 (Testing): Steps 11–12 — After all code complete
8. Phase 8 (Packaging): Steps 13–16 — After all testing passes

**Dependency Graph:**
```
trading_thresholds.sh (1)
      ↓
alpaca_wrappers.sh (2)
      ↓
indicators_new.sh (3) → scoring.sh (4)
      ↓
risk_management.sh (5)
      ↓
trade_journal.sh (6)
      ↓
strategy_mean_reversion.sh (7)
strategy_trend_follow.sh (8)
      ↓
CLI integration (9–10)
      ↓
Testing (11–12)
      ↓
Packaging (13–16)
```

---

## Build & Test Commands

**Build:** No compilation needed (bash scripts), but verify syntax:
```bash
bash -n lib/trading_thresholds.sh
bash -n lib/alpaca_wrappers.sh
bash -n lib/indicators_new.sh
# ... repeat for all new files
```

**Test Individual Module:**
```bash
bash test/test_indicators_new.sh
bash test/test_risk_management.sh
bash test/test_strategy_mean_reversion_cycle.sh
```

**Test All:**
```bash
bash test/run_all_tests.sh
```

**Package:**
```bash
tar -czf StockSwingTrader_v6.1_Alpaca_Deployable.tar.gz \
  StockSwingTrader_Agent.sh \
  lib/*.sh \
  config.sh \
  test/ \
  README.md \
  CHANGELOG.md \
  PACKAGE_VERSION.txt
```

---

## Success Criteria

- [ ] All 16 steps completed and verified
- [ ] No regressions: 65+ existing tests pass
- [ ] New tests pass: indicators, strategies, risk management, trade journal
- [ ] Both strategies backtest with expected win rates (MR: 55–65%, TF: 60–70%)
- [ ] `--strategy` and `--risk-level` flags working
- [ ] Background monitoring (`--monitor-positions`) runs without error
- [ ] v6.1 deployable archive created and contains all files
- [ ] README and CHANGELOG updated
- [ ] Can execute: `./StockSwingTrader_Agent.sh --strategy mean_reversion --buy 5 AAPL` without errors

---

## Known Constraints

- **No API downtime:** Alpaca wrappers assume Alpaca is reachable; tests use mock data
- **Bash 4+:** Scripts use associative arrays and advanced features (declare -A)
- **jq and bc:** Required for JSON parsing and float arithmetic; install if missing
- **Logs directory:** Scripts auto-create `logs/` but require write permission
- **Background monitor:** Cron/systemd integration is optional; can run manually

---

## Rollback Plan

If any step fails:
1. Revert changed files to v6.0 tag via git
2. Re-run existing v6.0 tests to confirm system stable
3. Identify root cause in failed step
4. Fix and re-integrate

