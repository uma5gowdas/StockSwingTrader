# Quick Start Guide

Get StockSwingTrader running in 5 minutes.

## 1. Setup (2 minutes)

```bash
# Navigate to project directory
cd /Users/P3291917/Builds/6/StockSwingTrader

# Make agent executable
chmod +x StockSwingTrader_Agent.sh

# Verify dependencies
bash -c 'command -v bash curl bc' && echo "All dependencies installed ✓"
```

## 2. Run (1 minute)

### Analyze Top 10 Stocks

```bash
./StockSwingTrader_Agent.sh --top-10
```

### Analyze Specific Stocks

```bash
./StockSwingTrader_Agent.sh --symbols AAPL,MSFT,GOOGL
```

### Debug Mode (see detailed logs)

```bash
./StockSwingTrader_Agent.sh --symbols AAPL --debug
```

## 3. View Results

After the agent completes, you'll see:

```
============================================
Analysis Complete!
Report: output/reports/swing_analysis_20250115_143022.html
============================================
```

**Open the HTML file in your browser:**

```bash
open output/reports/swing_analysis_*.html
```

Or copy the full path and open in your favorite browser.

## 4. Understanding the Report

### Signal Section

- **STRONG BUY** (Green) = Multiple indicators agree, high confidence
- **BUY** (Light Green) = Most signals bullish, good entry
- **HOLD** (Yellow) = Mixed signals, wait for clarity
- **SELL** (Orange) = Most signals bearish, consider exit
- **STRONG SELL** (Red) = Multiple indicators agree bearish

### Confidence Meter

Shows 0-100 score:
- 0 = Bearish
- 50 = Neutral
- 100 = Bullish

### Technical Indicators

- **RSI**: > 70 = overbought, < 30 = oversold
- **MACD**: Positive = bullish, negative = bearish
- **Bollinger Bands**: Price near lower = buy, upper = sell
- **Stochastic**: > 80 = overbought, < 20 = oversold

### Sentiment Section

Aggregated from Twitter, Reddit, StockTwits, and News API.

### Risk Management

- **Stop Loss**: Exit point if trade goes against you (5% below entry)
- **Take Profit**: Exit point when trade reaches profit target (8% above entry)
- **Risk/Reward**: Ratio of risk to potential profit

## 5. Configure (Optional)

For advanced features, add API keys:

```bash
# Copy config template
cp config.template.sh config.sh

# Edit to add your API keys
# Then run with:
source config.sh
./StockSwingTrader_Agent.sh --symbols AAPL
```

See [API_SETUP_GUIDE.md](API_SETUP_GUIDE.md) for details on getting free API keys.

## Common Commands

```bash
# Get help
./StockSwingTrader_Agent.sh --help

# View logs
tail -f logs/agent.log

# Analyze with custom symbols
./StockSwingTrader_Agent.sh --symbols TSLA,META,NFLX

# Use custom watchlist
./StockSwingTrader_Agent.sh --watchlist config/watchlist.txt

# Save reports to custom directory
./StockSwingTrader_Agent.sh --symbols AAPL --output-dir my_reports/

# Run with verbose debug output
./StockSwingTrader_Agent.sh --symbols AAPL --debug 2>&1 | tee detailed_output.log
```

## Example Workflow

```bash
# 1. Run analysis
./StockSwingTrader_Agent.sh --top-10 --debug

# 2. Monitor logs
tail -f logs/agent.log

# 3. Check latest report
ls -ltr output/reports/ | tail -1

# 4. Open in browser
open output/reports/$(ls -t output/reports/ | head -1)

# 5. Review signals and confidence scores
# Look for STRONG BUY signals with > 75 confidence
```

## Interpreting Results

### Strong Buy Signal (Score 75+)

Best entry opportunity:
- Multiple technical indicators aligned
- Bullish sentiment
- Price at support levels
- Risk/reward favorable (>= 1:2)

**Action**: Consider entering position with:
- Stop loss at calculated level
- Take profit at or above 8% gain
- Size position appropriately (risk only what you can afford)

### Buy Signal (Score 60-74)

Good entry opportunity:
- Most indicators bullish
- Reasonable risk/reward
- Sentiment positive

**Action**: Monitor for entry on pullback or breakout.

### Hold Signal (Score 40-59)

Indecision in market:
- Mixed technical signals
- Need more confirmation
- Wait for stronger signal

**Action**: Hold existing positions, don't add. Wait for BUY or SELL.

### Sell Signal (Score 25-39)

Weakness emerging:
- Most indicators bearish
- Downside risk rising

**Action**: Consider taking profits on long positions.

### Strong Sell Signal (Score 0-24)

Downtrend forming:
- Multiple indicators aligned bearish
- High conviction

**Action**: Exit positions, consider shorting (if permitted).

## Tips for Success

1. **Don't trade every signal** - Wait for STRONG BUY/SELL (>75 or <25 confidence)

2. **Use stop-losses** - Always! The report shows recommended levels.

3. **Check multiple sources** - Use the sentiment data + technical indicators

4. **Paper trade first** - Try the signals with fake money before using real capital

5. **Manage position size** - Never risk more than 2% of account per trade

6. **Review results** - Keep records of successful vs unsuccessful signals to learn

7. **Update watchlist** - Add/remove stocks based on your interest

## Troubleshooting

### Script won't run

```bash
# Make executable
chmod +x StockSwingTrader_Agent.sh

# Or run with bash explicitly
bash StockSwingTrader_Agent.sh --symbols AAPL
```

### Missing curl or bc

```bash
# macOS
brew install curl bc

# Ubuntu/Debian
sudo apt-get install curl bc

# Then retry
./StockSwingTrader_Agent.sh --top-10
```

### No internet connection

The agent needs internet to:
- Fetch stock data
- Aggregate sentiment
- Generate reports

Check your connection and retry.

### HTML report looks blank

Open the file directly in your browser instead of email client:

```bash
open output/reports/swing_analysis_*.html
```

## Next Steps

1. **Run analysis**: `./StockSwingTrader_Agent.sh --top-10`
2. **View report**: Open generated HTML in browser
3. **Add API keys** (optional): Follow [API_SETUP_GUIDE.md](API_SETUP_GUIDE.md)
4. **Customize settings**: Edit `config.template.sh`
5. **Create watchlist**: Add your favorite stocks to `config/watchlist.txt`
6. **Run daily**: Schedule with cron: `0 9 * * MON-FRI ~/path/StockSwingTrader_Agent.sh --top-10`

## Important Reminders

⚠️ **This is analysis only, not financial advice**

- Not connected to live trading
- Past performance ≠ future results  
- Always do your own research
- Consult a financial advisor
- Never risk money you can't afford to lose
- Markets are unpredictable

## Getting Help

- Check [README.md](README.md) for detailed documentation
- View logs: `tail logs/agent.log`
- Run with `--debug` flag for verbose output
- Verify API keys if getting data errors
- Ensure bash 4.0+ installed: `bash --version`

---

**That's it!** You're ready to analyze swing trades. Happy trading! 📈
