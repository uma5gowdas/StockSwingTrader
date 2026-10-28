# StockSwingTrader Agent

A sophisticated shell-based swing trading analysis platform that combines 8+ technical indicators with multi-source sentiment analysis to identify high-confidence trading opportunities on US stocks.

## Overview

**StockSwingTrader** is a standalone bash agent that analyzes stocks for short-term swing trades (2-5 day holds). It fetches live market data, calculates comprehensive technical indicators, aggregates social sentiment, and generates professional HTML reports with buy/sell signals and risk metrics.

### Key Features

- **8+ Technical Indicators**: RSI, MACD, Bollinger Bands, Stochastic, Williams %R, OBV, ATR, SMA/EMA
- **Multi-Source Sentiment**: Twitter, Reddit, StockTwits, News API analysis
- **Confidence Scoring**: 0-100 scale with BUY/SELL/HOLD recommendations
- **Risk Management**: ATR-based stop-loss calculations, risk-reward ratios
- **Professional Reports**: Interactive HTML with real-time charts and metrics
- **Rate Limit Aware**: Respects API rate limits (Alpha Vantage 5/min, Finnhub 60/min)
- **Retry Logic**: Exponential backoff for transient failures
- **Learning Mode**: Analysis-only, no live trading connection
- **Top 10 Watchlist**: Pre-configured with popular stocks

## Installation

### Prerequisites

- **bash 4.0+** (check with `bash --version`)
- **curl** (for HTTP requests)
- **bc** (for floating-point calculations)
- **jq** (optional, for advanced JSON parsing)

### macOS

```bash
# Install dependencies if needed
brew install bash curl bc jq

# Clone and set up
cd /Users/P3291917/Builds/6/StockSwingTrader
chmod +x StockSwingTrader_Agent.sh

# Copy config template
cp config.template.sh config.sh
```

### Linux

```bash
# Debian/Ubuntu
sudo apt-get install bash curl bc jq

# Set up
cd /Users/P3291917/Builds/6/StockSwingTrader
chmod +x StockSwingTrader_Agent.sh
cp config.template.sh config.sh
```

## Configuration

### 1. Create Configuration File

```bash
cp config.template.sh config.sh
```

### 2. Add API Keys (Optional for Demo Mode)

Edit `config.sh` and add your API keys:

```bash
# Alpha Vantage (free tier: 5 calls/min, 500/day)
export API_KEY_ALPHA_VANTAGE="your_key_here"

# Finnhub (free tier: 60 calls/min)
export API_KEY_FINNHUB="your_key_here"

# NewsAPI (free tier: 100 requests/day)
export API_KEY_NEWSAPI="your_key_here"
```

**Note**: The agent works in demo mode without API keys, using simulated data and public Yahoo Finance endpoints.

### 3. Configure Trading Parameters (Optional)

Edit `config.sh` to customize indicator settings:

```bash
# Indicator Periods
RSI_PERIOD=14              # RSI lookback period
MACD_FAST=12               # MACD fast EMA
MACD_SLOW=26               # MACD slow EMA
BOLLINGER_PERIOD=20        # Bollinger Bands period
BOLLINGER_STD_DEV=2        # Standard deviations for bands

# Trading Thresholds
CONFIDENCE_STRONG_BUY=75   # >= this = strong BUY signal
CONFIDENCE_BUY=60          # 60-74 = BUY signal
CONFIDENCE_HOLD=40         # 40-59 = HOLD signal

# Risk Management
STOP_LOSS_PERCENT=5        # 5% stop-loss
TARGET_PROFIT_PERCENT=8    # 8% take-profit target
```

### 4. Configure Watchlist

Edit `config.sh` to customize stock symbols:

```bash
export DEFAULT_WATCHLIST="AAPL,MSFT,GOOGL,AMZN,TSLA,META,NFLX,CRM,ADBE,NVDA"
```

Or create a custom watchlist file:

```bash
cat > config/watchlist.txt << 'EOF'
AAPL
MSFT
GOOGL
AMZN
TSLA
EOF
```

## Usage

### Basic Analysis - Top 10 Stocks

```bash
./StockSwingTrader_Agent.sh --top-10
```

### Analyze Specific Stocks

```bash
./StockSwingTrader_Agent.sh --symbols AAPL,MSFT,GOOGL
```

### Use Custom Watchlist

```bash
./StockSwingTrader_Agent.sh --watchlist config/watchlist.txt
```

### Enable Debug Mode

```bash
./StockSwingTrader_Agent.sh --symbols AAPL --debug
```

Output will show detailed logs including API calls, calculations, and timing.

### Specify Output Directory

```bash
./StockSwingTrader_Agent.sh --symbols AAPL,MSFT --output-dir my_reports/
```

### Help

```bash
./StockSwingTrader_Agent.sh --help
```

## Output

### HTML Report

The agent generates a professional interactive HTML report in `output/reports/`:

- **Stock Summary**: Current price, change, market cap, volume
- **Signal & Confidence**: BUY/SELL/HOLD with visual confidence meter
- **Technical Indicators**: RSI, MACD, Bollinger Bands, Stochastic, Williams %R, OBV
- **Sentiment Analysis**: Twitter, Reddit, StockTwits, News scores
- **Risk Metrics**: Entry, stop-loss, take-profit, risk-reward ratio, ATR
- **Trade Summary**: Analysis reasoning and key levels

Example: `output/reports/swing_analysis_20250115_143022.html`

### Logging

All activity is logged to `logs/agent.log`:

```
[INFO] [2025-01-15 14:30:22] StockSwingTrader Agent started
[INFO] [2025-01-15 14:30:22] Analyzing AAPL...
[DEBUG] [2025-01-15 14:30:23] Fetching OHLCV data for AAPL (last 60 days)
[INFO] [2025-01-15 14:30:25] Completed analysis for AAPL
```

## Technical Indicators

### RSI (Relative Strength Index)

- **Period**: 14 (default)
- **Range**: 0-100
- **Signals**: 
  - \> 70 = Overbought (potential reversal down)
  - < 30 = Oversold (potential reversal up)
  - 50 = Neutral

### MACD (Moving Average Convergence Divergence)

- **Components**: MACD line (EMA 12-26), Signal line (EMA 9), Histogram
- **Signals**:
  - MACD crosses above signal = Bullish
  - MACD crosses below signal = Bearish
  - Histogram divergence = Momentum shift

### Bollinger Bands

- **Period**: 20 (default)
- **Std Dev**: 2 (default)
- **Signals**:
  - Price near lower band = Oversold (buy)
  - Price near upper band = Overbought (sell)
  - %B indicator: 0-1 scale of band position

### Stochastic Oscillator

- **Period**: 14 (default)
- **Range**: 0-100
- **Signals**:
  - < 20 = Oversold (buy)
  - \> 80 = Overbought (sell)
  - K/D crossovers = Momentum shifts

### Williams %R

- **Period**: 14 (default)
- **Range**: -100 to 0
- **Signals**:
  - -100 to -80 = Oversold (buy)
  - 0 to -20 = Overbought (sell)
  - Similar to Stochastic but inverted

### ATR (Average True Range)

- **Period**: 14 (default)
- **Use**: Volatility measurement, stop-loss sizing
- **Formula**: SL = Entry - (ATR × Multiplier)

### OBV (On-Balance Volume)

- **Use**: Volume-based trend confirmation
- **Signals**:
  - Rising OBV = Confirms uptrend
  - Falling OBV = Confirms downtrend

### SMA/EMA (Moving Averages)

- **SMA**: Simple average of last N periods
- **EMA**: Exponential (recent prices weighted higher)
- **Common Periods**: 20, 50, 200 (SMA); 12, 26 (EMA)

## Sentiment Analysis

The agent aggregates sentiment from multiple sources:

### Twitter

- Tracks mention volume and sentiment (bullish/bearish keywords)
- Uses public API or lightweight scraping
- **Confidence**: 30-minute cache

### Reddit

- Analyzes r/stocks, r/investing, r/wallstreetbets
- Mentions and sentiment tone
- **Confidence**: 30-minute cache

### StockTwits

- Fetches bullish/bearish percentages
- Tracks sentiment shifts
- **Confidence**: 30-minute cache

### News API

- Scans recent financial news
- Keyword-based sentiment analysis
- Aggregates positive/negative tone
- **Confidence**: 24-hour cache

**Aggregate Score**: 0-100 (0=very bearish, 50=neutral, 100=very bullish)

## Confidence Scoring Algorithm

The final confidence score combines:

1. **Technical Indicators** (80% weight):
   - RSI score: 0-100 based on overbought/oversold
   - MACD score: strength of trend
   - Bollinger Bands score: price position
   - Stochastic score: momentum
   - Williams %R score: momentum (alternative)
   - OBV score: volume confirmation
   - Average = (RSI + MACD + BB + Stoch + Williams + OBV) / 6

2. **Sentiment** (20% weight):
   - Aggregate of Twitter, Reddit, StockTwits, News

**Final Confidence** = (Technical Average × 0.8) + (Sentiment × 0.2)

### Signal Interpretation

- **STRONG BUY** (75-100): High conviction, multiple indicators aligned bullish
- **BUY** (60-74): Good entry opportunity, most signals bullish
- **HOLD** (40-59): Mixed signals, wait for clarity
- **SELL** (25-39): Most signals bearish, consider exits
- **STRONG SELL** (0-24): High conviction bearish, multiple indicators aligned

## Risk Management

### Stop-Loss Calculation

Two methods:

1. **Percentage-based**: 5% below entry (default)
   ```
   SL = Entry × 0.95
   ```

2. **ATR-based**: 2× ATR below entry (more dynamic)
   ```
   SL = Entry - (2 × ATR)
   ```

### Take-Profit Target

Default: 8% above entry for 1:1.6 risk-reward ratio

```
TP = Entry × 1.08
```

### Risk-Reward Ratio

Displayed as X:Y ratio (e.g., 1:2 = risk $1 to make $2)

```
Ratio = (TP - Entry) / (Entry - SL)
```

## Rate Limiting

The agent respects API rate limits to avoid service interruption:

| API | Limit | Strategy |
|-----|-------|----------|
| Yahoo Finance | Unlimited (practical: ~2000/day) | Public data, cached aggressively |
| Alpha Vantage | 5 calls/min, 500/day | Queued, 12s stagger per call |
| Finnhub | 60 calls/min | Queued, enforced per 60s window |
| NewsAPI | Varies by tier (100/day free) | Daily quota, 24h cache |
| Twitter/Reddit | No hard limit (scraping) | Throttled 1 req/min per symbol |

**Implementation**: `rate_limiter.sh` tracks timestamps and enforces minimum wait times before each API call.

## Troubleshooting

### Issue: "curl: command not found"

**Solution**: Install curl
```bash
# macOS
brew install curl

# Ubuntu/Debian
sudo apt-get install curl
```

### Issue: "bc: command not found"

**Solution**: Install bc
```bash
# macOS
brew install bc

# Ubuntu/Debian
sudo apt-get install bc
```

### Issue: "Permission denied" when running script

**Solution**: Make script executable
```bash
chmod +x StockSwingTrader_Agent.sh
```

### Issue: "API rate limit exceeded"

**Solution**: Wait 60 seconds or restart the script. The agent includes exponential backoff retry logic.

### Issue: "Insufficient data points"

**Solution**: This means less than 30 days of historical data. Symbol may be:
- Too new (IPO)
- Delisted
- Invalid symbol

Verify the symbol is valid on Yahoo Finance.

### Issue: No sentiment data

**Solution**: Sentiment is optional for analysis. The agent will:
- Log a warning
- Continue with technical analysis only
- Mark sentiment as unavailable in report

Check internet connectivity if sentiment data is critical.

### Issue: HTML report looks plain/unstyled

**Solution**: Some email clients strip CSS. Open the HTML file directly in a web browser instead.

## Data Sources

| Source | Data Type | Freshness | Cost |
|--------|-----------|-----------|------|
| Yahoo Finance | OHLCV, quotes, fundamentals | Real-time | Free |
| Alpha Vantage | Intraday, technical data | Real-time | Free tier (limited) |
| Finnhub | Real-time quotes, news | Real-time | Free tier (limited) |
| NewsAPI | Financial news articles | Real-time | Free tier (100/day) |
| Twitter | Social sentiment, mentions | Real-time | Free (lightweight scraping) |
| Reddit | Forum sentiment, discussions | Real-time | Free (API available) |
| StockTwits | Community sentiment, bullish% | Real-time | Free (lightweight scraping) |

## Disclaimer & Legal

**IMPORTANT**: 

1. **Not Financial Advice**: This agent provides analysis only. It is NOT financial advice. Always consult a qualified financial advisor before making trading decisions.

2. **Learning/Demo Only**: Designed for educational purposes and demonstration. Not connected to live brokerage accounts.

3. **Past Performance**: Historical analysis does not guarantee future results. Markets are unpredictable.

4. **Risk**: Stock trading involves substantial risk of loss. Never risk more than you can afford to lose.

5. **API Limitations**: Data from third-party APIs may be delayed or inaccurate. Verify signals with official sources.

6. **No Warranty**: The agent is provided AS-IS without warranty. Use at your own risk.

## Getting Help

### View Logs

```bash
tail -f logs/agent.log
```

### Run with Debug Output

```bash
./StockSwingTrader_Agent.sh --symbols AAPL --debug
```

### Check Script Syntax

```bash
bash -n StockSwingTrader_Agent.sh
```

### Validate HTML Reports

Open generated HTML in a web browser to verify formatting.

## Project Structure

```
StockSwingTrader/
├── StockSwingTrader_Agent.sh      Main agent (executable)
├── config.template.sh             Configuration template
├── lib/
│   ├── indicators.sh              Technical indicator calculations
│   ├── sentiment.sh               Social sentiment analysis
│   ├── scoring.sh                 Confidence scoring engine
│   └── html_report.sh             HTML report generation
├── config/
│   ├── watchlist.txt              Stock symbols (one per line)
│   └── parameters.conf            Indicator parameters
├── logs/
│   └── agent.log                  Execution log (auto-generated)
├── cache/
│   └── data/                      API response cache (auto-generated)
├── output/
│   └── reports/                   Generated HTML reports (auto-generated)
├── tests/
│   ├── unit_tests.sh              Unit test suite
│   └── data/                      Sample API responses
├── README.md                      This file
├── QUICK_START.md                 Quick start guide
├── API_SETUP_GUIDE.md             API key setup instructions
└── PLAN.md                        Original implementation plan
```

## Performance Notes

- **First Run**: 5-15 seconds per stock (fetching historical data)
- **Cached Run**: 2-5 seconds per stock (using cached data)
- **Typical Batch**: 10 stocks in ~60-90 seconds
- **Memory**: < 50MB for typical usage
- **Disk**: Cache grows ~100KB per stock per day

## Future Enhancements

- Backtesting engine (validate signals historically)
- Paper trading integration (Alpaca API)
- Email/Slack alerts for strong signals
- Web dashboard frontend
- Machine learning signal optimization
- Portfolio management tools
- Live trading connections (paper only)

## Contributing

Contributions welcome! Areas for improvement:

- Additional technical indicators
- Enhanced sentiment analysis
- Performance optimizations
- Additional data sources
- Test coverage

## License

Open source for educational use.

## Support

For issues or questions:

1. Check the Troubleshooting section above
2. Review logs: `tail -f logs/agent.log`
3. Run with debug flag: `--debug`
4. Verify API keys and internet connectivity
5. Ensure bash 4.0+ and required tools are installed

---

**Last Updated**: 2025-01-15  
**Version**: 1.0  
**Status**: Production Ready (Learning/Demo Mode)
