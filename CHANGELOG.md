# StockSwingTrader Changelog

All notable changes to StockSwingTrader are documented in this file.

## [6.1] - 2025-10-28

### Added (v6.1)

#### Alpaca Paper Trading Integration
- **alpaca_broker.sh**: Full Alpaca API integration module
  - Account management (balance, buying power, equity)
  - Order placement (buy/sell with validation)
  - Position tracking and monitoring
  - Real-time account status
  - Retry logic with exponential backoff
  - Error handling and recovery

- **alpaca_wrappers.sh**: Convenience wrapper functions
  - Simplified API calls for common operations
  - Error handling and logging
  - Environment variable support (APCA_API_KEY_ID, APCA_API_SECRET_KEY, APCA_API_OAUTH_TOKEN)

- CLI Flags for Trading:
  - `--alpaca`: Enable Alpaca trading mode
  - `--check-account`: Display account balance and details
  - `--view-positions`: List all open positions with quantities
  - `--place-buy SYMBOL QTY`: Place buy orders with confirmation
  - `--place-sell SYMBOL QTY`: Place sell orders with confirmation
  - `--alpaca-status`: Verify connection and show status

#### Risk Management Module
- **risk_management.sh**: Advanced risk calculations
  - Position sizing based on Kelly criterion
  - Risk-reward ratio optimization
  - Dynamic stop-loss adjustment using ATR
  - Max loss per trade enforcement
  - Portfolio heat (risk concentration)
  - Volatility-adjusted position sizing

#### Trade Journal System
- **trade_journal.sh**: Trade tracking and logging
  - Automatic trade entry logging
  - Entry/exit tracking
  - Profit/loss calculation
  - Win rate and return statistics
  - CSV export for analysis
  - Trade performance analytics

#### Multiple Trading Strategies
- **strategy_mean_reversion.sh**: Mean Reversion Strategy
  - Bollinger Bands breakout detection
  - RSI oversold/overbought signals
  - Entry on rejection of extremes
  - Exit on mean crossover
  - Configurable thresholds

- **strategy_trend_follow.sh**: Trend Following Strategy
  - EMA/SMA crossover signals
  - MACD momentum confirmation
  - ADX trend strength filter
  - Break above resistance entry
  - Trail stop exit mechanism

#### Trading Thresholds Module
- **trading_thresholds.sh**: Dynamic threshold management
  - Symbol-specific parameter tuning
  - Time-based (intraday/swing/position)
  - Volatility regime adaptation
  - Backtest-optimized defaults
  - Override capabilities for manual adjustment

### Enhanced (v6.1)

- **Main Agent (StockSwingTrader_Agent.sh)**:
  - Integrated Alpaca trading commands
  - Strategy selection support
  - Paper trading workflow
  - Combined analysis + trading modes
  - Improved error messages for trading failures

- **indicators_new.sh**: Additional technical indicators
  - ADX (Average Directional Index) for trend strength
  - Volume Price Trend (VPT)
  - Money Flow Index (MFI)
  - Enhanced signal combinations

- **Test Suite Expanded**:
  - 65+ automated tests (all passing)
  - Alpaca broker integration tests
  - Paper trading verification
  - Order placement simulation
  - Error handling validation
  - Environment variable tests

### Fixed (v6.1)

- Position tracking now accurately reflects Alpaca paper trading account
- API credential handling with proper environment variable support
- Order confirmation flow prevents accidental duplicate orders
- Rate limiting respects Alpaca API constraints (200 orders/minute)
- Error recovery from temporary API failures

### Documentation (v6.1)

- Updated README.md with Alpaca integration examples
- Added Alpaca Configuration section to setup guide
- Created CHANGELOG.md (this file)
- Added trading strategy documentation
- Paper trading workflow guides
- Troubleshooting for common Alpaca issues

### Breaking Changes

None. v6.1 is backward compatible with v6.0 analysis-only mode.

### Migration Guide

To upgrade from v6.0 to v6.1:

1. **Extract new package**:
   ```bash
   tar -xzf StockSwingTrader_v6.1_Alpaca_Deployable.tar.gz
   cd StockSwingTrader
   ```

2. **Run test suite** (verify all 65 tests pass):
   ```bash
   bash tests/test_alpaca_broker.sh
   ```

3. **Set Alpaca credentials** (if using trading features):
   ```bash
   export APCA_API_KEY_ID="your_key_id"
   export APCA_API_SECRET_KEY="your_secret"
   ```

4. **Test trading commands**:
   ```bash
   ./StockSwingTrader_Agent.sh --alpaca --check-account
   ```

### Known Limitations

- Paper trading only (no live trading connections)
- Alpaca broker required for trading features
- Analysis functions work without Alpaca
- Historical backtesting not included in v6.1
- Max order size limited by account equity

### Performance Impact

- No performance degradation for analysis-only mode
- Trading commands add ~1-2 second latency (API calls)
- Trade journal operations: <100ms per trade
- Memory footprint: <100MB typical usage

### Testing & Quality Assurance

✓ All 65 tests passing
✓ Syntax validation complete
✓ No shell errors detected
✓ API integration tested
✓ Environment variable handling verified
✓ Error recovery tested
✓ Rate limiting validated

## [6.0] - 2025-10-20

### Initial Release

- Technical indicator analysis (8+ indicators)
- Multi-source sentiment analysis
- Confidence scoring engine
- HTML report generation
- Rate limiting and retry logic
- Top-10 watchlist
- Demo/learning mode

---

## Future Roadmap

### v7.0 (Planned)
- Multi-broker support (Interactive Brokers, TD Ameritrade)
- Live trading mode
- Portfolio-level risk management
- Advanced backtesting engine
- Machine learning signal enhancement

### v7.1 (Planned)
- Real-time alerts (email, SMS, Slack)
- Web dashboard
- Mobile app support
- Collaborative paper trading

### v8.0 (Planned)
- AI-powered strategy optimization
- Advanced derivatives support (options)
- Statistical arbitrage strategies
- Deployment to cloud platforms

---

## Version Support

| Version | Release Date | Status | Support Until |
|---------|-------------|--------|-----------------|
| 6.1 | 2025-10-28 | Active | 2026-10-28 |
| 6.0 | 2025-10-20 | Maintained | 2026-04-20 |
| < 6.0 | N/A | Unsupported | N/A |

---

## Contributors

Built with focus on:
- Production-ready bash scripting
- Robust error handling
- Clear documentation
- Comprehensive testing
- User experience

---

**Note**: All versions are for educational and paper trading use only. Always validate signals with your own analysis before making real trading decisions.
