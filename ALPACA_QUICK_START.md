# Alpaca Integration - Quick Start Guide

## ✅ Integration Complete

Your StockSwingTrader now has full Alpaca paper trading support!

### What's Installed

1. **Alpaca Broker Module** (`lib/alpaca_broker.sh`)
   - 7 core functions for account & position management
   - 7 helper functions for validation & formatting
   - Full error handling with retry logic

2. **Agent Integration** (`StockSwingTrader_Agent.sh`)
   - 6 new command-line flags for Alpaca operations
   - Seamless signal-to-trade workflow
   - Account status displays in reports

3. **Configuration** (`config.sh`)
   - Your API credentials stored securely
   - Paper trading mode enabled
   - Risk parameters pre-configured

4. **Documentation** (`API_SETUP_GUIDE.md`)
   - 792 lines of comprehensive guides
   - 8 sections covering setup through advanced trading
   - Troubleshooting and best practices

### Your Account Status

```
Account Number:    PA3V0PY54
Status:            ACTIVE ✅
Cash Balance:      $100,000
Buying Power:      $400,000
Portfolio Value:   $100,000
Trading Mode:      Paper (Safe for testing)
```

### Immediate Commands

#### 1. Check Account Status
```bash
cd /Users/P3291917/Builds/6/StockSwingTrader
./StockSwingTrader_Agent.sh --check-account
```

#### 2. View Open Positions
```bash
./StockSwingTrader_Agent.sh --view-positions
```

#### 3. Analyze Stocks with Alpaca Connection
```bash
./StockSwingTrader_Agent.sh --symbols AAPL,MSFT,TSLA --alpaca
```

#### 4. Check Specific Position
```bash
./StockSwingTrader_Agent.sh --check-position AAPL
```

#### 5. Place a Paper Trade (requires confirmation)
```bash
# Buy 10 shares of Apple
./StockSwingTrader_Agent.sh --buy 10 AAPL

# Sell 5 shares of Microsoft
./StockSwingTrader_Agent.sh --sell 5 MSFT
```

### Advanced Usage

#### Generate Report with Account Summary
```bash
./StockSwingTrader_Agent.sh --symbols AAPL --alpaca --include-account-summary
```

#### Auto-Trade on Strong Signals (disabled by default)
```bash
# Only works if ALPACA_AUTO_TRADE_ON_STRONG_BUY=true in config.sh
# Not recommended for beginners - enable at your own risk
```

#### Get Detailed Trading Help
```bash
./StockSwingTrader_Agent.sh --help
```

### Security Notes

✅ **Best Practices:**
- API credentials stored in `config.sh` (not in git)
- Paper trading mode (virtual money only)
- All trades require explicit user confirmation
- Rate limiting built-in to prevent API abuse

⚠️ **Important:**
- Never commit `config.sh` to version control
- Never share your API keys
- Paper trading ≠ Real trading (practice first!)
- Markets can be unpredictable - risk management is critical

### Next Steps

1. **Test the Connection**
   ```bash
   ./test_account.sh
   ```

2. **Try a Quick Analysis**
   ```bash
   ./StockSwingTrader_Agent.sh --symbols AAPL --alpaca --debug
   ```

3. **Review the Full Documentation**
   - See `API_SETUP_GUIDE.md` for detailed guides
   - See `docs/ALPACA_SETUP_GUIDE.html` for visual setup

4. **Read About Risk Management**
   - Check `API_SETUP_GUIDE.md` → Trading Guide section
   - Understand stop-loss, take-profit, position sizing

### Troubleshooting

**Error: "Missing Alpaca API credentials"**
- Make sure `config.sh` is sourced before running commands
- Verify credentials in `config.sh` are correct

**Error: "Alpaca API connection test passed" but account shows empty**
- Paper trading mode takes a moment to initialize
- Wait 30 seconds and try again

**Error: "Insufficient buying power"**
- Check your cash balance: `./StockSwingTrader_Agent.sh --check-account`
- You have $100,000 starting capital
- Each trade uses buying power based on position size

**Can't see positions after placing a trade**
- Market must be open for orders to fill
- Paper trading fills orders at current market price
- Check status with: `./StockSwingTrader_Agent.sh --view-positions`

### Support & Documentation

For more details:
- **Setup Guide**: `docs/ALPACA_SETUP_GUIDE.html` (open in browser)
- **Full Docs**: `API_SETUP_GUIDE.md` (792 lines)
- **README**: `README.md` (overview & general info)
- **Config Template**: `config.template.sh` (all options explained)

---

**Status**: ✅ READY FOR TRADING  
**Created**: 2026-10-28  
**Version**: 1.0  
**Account**: Paper Trading (PA3V0PY54)

