# Alpaca Paper Trading Integration Guide

## Table of Contents

1. [Quick Start (5 minutes)](#quick-start-5-minutes)
2. [Account Setup (detailed)](#account-setup-detailed)
3. [API Configuration](#api-configuration)
4. [Using with StockSwingTrader](#using-with-stockswingtrader)
5. [Trading Guide](#trading-guide)
6. [Troubleshooting](#troubleshooting)
7. [Advanced Topics](#advanced-topics)
8. [Data Source APIs](#data-source-apis)

---

## Quick Start (5 minutes)

Get trading in 5 minutes:

1. **Sign up**: Visit https://alpaca.markets and create an account
2. **Generate API key**: Log into https://app.alpaca.markets → Settings > API Keys → Generate New Key
3. **Export environment variables**:
   ```bash
   export ALPACA_API_KEY="your_api_key_here"
   export ALPACA_SECRET_KEY="your_secret_key_here"
   ```
4. **Test**: 
   ```bash
   ./StockSwingTrader_Agent.sh --alpaca --check-account
   ```
5. **Analyze stocks**: 
   ```bash
   ./StockSwingTrader_Agent.sh --alpaca --symbols AAPL,MSFT
   ```

---

## Account Setup (Detailed)

### Creating an Alpaca Account

1. **Visit**: https://alpaca.markets
2. **Click**: "Sign Up"
3. **Enter**: Email address, password, and full name
4. **Verify**: Check your email for verification link and click it
5. **Complete KYC**: Provide government-issued ID
   - Upload photo of ID front and back
   - Verify identity
   - Takes 5-10 minutes
6. **Account Ready**: You can now trade with simulated money

### Paper Trading vs Live Trading

**Paper Trading** (Recommended)
- Uses simulated $100,000
- No real money involved
- Perfect for learning and testing
- Full API access
- Zero risk

**Live Trading**
- Uses your real money
- Minimum $500 required
- Real market execution
- Settlement and tax implications
- StockSwingTrader supports live trading but we recommend paper mode first

**Default Mode**: StockSwingTrader uses paper trading by default (safe and recommended).

### Generating API Keys

**Important**: Keep your Secret Key safe! Never share it.

1. **Log in**: https://app.alpaca.markets
2. **Navigate**: Settings → API Keys
3. **Click**: "Generate New Key"
4. **Copy both values**:
   - **API Key ID** (public, safe to use in config)
   - **Secret Key** (keep secret, like a password)
5. **Note the URLs**:
   - Paper Trading: `https://paper-api.alpaca.markets`
   - Live Trading: `https://api.alpaca.markets`

**Example API Key** (format only):
```
API Key ID:    PK1234567890ABCDEF
Secret Key:    1a2b3c4d5e6f7g8h9i0j1k2l3m4n5o6p
```

---

## API Configuration

### Method 1: Environment Variables (Recommended)

Best for security and simplicity:

```bash
# Add to ~/.bashrc, ~/.zshrc, or run before StockSwingTrader
export ALPACA_API_KEY="your_api_key_id_here"
export ALPACA_SECRET_KEY="your_secret_key_here"

# Then run:
./StockSwingTrader_Agent.sh --alpaca --check-account
```

### Method 2: Config File

Create `config/api_keys.sh`:

```bash
#!/bin/bash
# config/api_keys.sh
export ALPACA_API_KEY="your_api_key_id_here"
export ALPACA_SECRET_KEY="your_secret_key_here"
```

Run:
```bash
source config/api_keys.sh
./StockSwingTrader_Agent.sh --alpaca --check-account
```

### Method 3: .env File

Create `.env` in project root:

```
ALPACA_API_KEY=your_api_key_id_here
ALPACA_SECRET_KEY=your_secret_key_here
```

### Security: Protecting API Keys

**Add to .gitignore** (already included):
```
config/api_keys.sh
.env
.env.local
secrets/
```

**Verify**:
```bash
grep "api_keys.sh" .gitignore
```

**Check no keys are committed**:
```bash
git log -p | grep -i "ALPACA_"
```

---

## Using with StockSwingTrader

### Check Account Status

Display your account balance, buying power, positions, and portfolio value:

```bash
./StockSwingTrader_Agent.sh --alpaca --check-account
```

**Output shows**:
- Account balance (cash available)
- Buying power (cash + margin)
- Current open positions with quantity
- Portfolio total value
- Account status (active/restricted)

### Analyze & Check Account

Analyze technical indicators and compare to current positions:

```bash
./StockSwingTrader_Agent.sh --alpaca --symbols AAPL,MSFT
```

**This will**:
1. Analyze technical indicators for AAPL, MSFT
2. Generate signals (BUY/SELL/HOLD)
3. Show your current positions
4. Compare signals to open trades
5. Show potential opportunities

### View Open Positions

See all current trades with profit/loss:

```bash
./StockSwingTrader_Agent.sh --alpaca --view-positions
```

**Shows**:
- Symbol and quantity held
- Entry price and current price
- Unrealized P&L and percentage
- Current market value

### Place Orders

#### Buy Shares

```bash
# Buy 10 shares of AAPL
./StockSwingTrader_Agent.sh --alpaca --place-buy AAPL 10

# Buy at market (executes immediately)
./StockSwingTrader_Agent.sh --alpaca --buy AAPL 5 --qty 5
```

#### Sell Shares

```bash
# Sell 5 shares of MSFT
./StockSwingTrader_Agent.sh --alpaca --place-sell MSFT 5

# Sell at market (executes immediately)
./StockSwingTrader_Agent.sh --alpaca --sell MSFT --qty 3
```

**Order Types**:
- **Market Orders**: Execute immediately at market price
- **Limit Orders**: Set a specific price (advanced)
- **Stop Loss**: Trigger when price drops (advanced)

---

## Trading Guide

### Understanding Trading Signals

Signal scores range from 0-100:

| Signal | Score | Meaning | Action |
|--------|-------|---------|--------|
| **Strong Buy** | 80-100 | High confidence, multiple indicators aligned | Consider buying |
| **Buy** | 60-79 | Good opportunity, most indicators positive | Good entry point |
| **Hold** | 40-59 | No clear direction, mixed signals | Wait for better setup |
| **Sell** | 20-39 | Negative signals accumulating | Consider selling |
| **Strong Sell** | 0-19 | Multiple bearish indicators | Reduce position |

### Risk Management Best Practices

1. **Never risk more than 2% per trade**
   - Example: $100k account → max $2k loss per trade

2. **Use stop losses**
   - Automatically exit if trade goes against you
   - Currently manual in StockSwingTrader
   - Set at 5-10% below entry price

3. **Take profits at 8% gains**
   - Lock in wins at reasonable levels
   - Prevents holding winners too long
   - Maintains consistent wins

4. **Max 10 open positions**
   - Conservative diversification
   - Reduces risk concentration
   - Easier to manage and monitor

5. **Only trade during market hours**
   - 9:30 AM - 4:00 PM ET (regular hours)
   - Extended hours: 4:00 AM - 8:00 PM ET (advanced)

### Paper Trading Practice

**Why use paper trading first?**
- Zero financial risk
- Learn how markets work
- Test strategies safely
- Build confidence before using real money

**Effective practice**:
1. Start with small simulated positions (10-20 shares)
2. Test different stock sectors
3. Track wins and losses in a journal
4. Notice patterns in your trades
5. Aim for 55%+ win rate before going live

**Track these metrics**:
- Win rate (% of profitable trades)
- Average win vs average loss
- Total return per month
- Number of trades
- Time in position

---

## Troubleshooting

### 401 Unauthorized

**Problem**: Invalid API credentials

**Fixes**:
1. Verify API key matches dashboard exactly (copy/paste, not manual)
2. Check for typos or extra spaces
3. Ensure using API Key ID, not Secret Key in the public field
4. If uncertain, regenerate a new key:
   - Settings → API Keys → Delete old key → Generate New Key
5. Test credentials:
   ```bash
   curl -H "Authorization: Bearer $ALPACA_API_KEY" \
     https://paper-api.alpaca.markets/v2/account
   ```

### Connection Timeout

**Problem**: Network issue or Alpaca server down

**Fixes**:
1. Check internet connection: `ping 8.8.8.8`
2. Test Alpaca directly:
   ```bash
   curl https://paper-api.alpaca.markets/v2/account
   ```
3. Check Alpaca status: https://status.alpaca.markets
4. Try again in a few minutes
5. Check firewall/VPN blocking

### Insufficient Buying Power

**Problem**: Not enough cash to buy shares

**Fixes**:
1. Check account balance: `./StockSwingTrader_Agent.sh --alpaca --check-account`
2. Close existing positions to free up cash
3. Reduce order size
4. In paper trading, balance resets to $100k if needed

### Invalid Symbol

**Problem**: Symbol not found or not tradeable

**Fixes**:
1. Verify ticker symbol is correct (AAPL, not APPLE)
2. Check symbol is a US equity (Alpaca supports US stocks)
3. Some symbols require exact matches (class A vs B: BRK.A vs BRK.B)
4. Test symbol: `curl https://api.alpaca.markets/v1/assets?symbol=AAPL`

### Rate Limiting

**Problem**: "Rate limit exceeded" error

**Fixes**:
1. Alpaca allows 200 requests/minute
2. StockSwingTrader throttles automatically
3. If still limited, wait 1-2 minutes
4. Reduce frequency of API calls
5. For heavy usage, contact Alpaca sales

### Orders Not Executing

**Problem**: Order placed but not filled

**Reasons**:
1. Market closed (after 4:00 PM ET)
   - Orders queue until market open
   - Execute at 9:30 AM ET
2. Insufficient buying power
3. Price movement (especially limit orders)

**Solutions**:
1. Check market hours: https://www.nyse.com/publicdocs/nyse/trading/holidays_and_hours.html
2. Check account buying power
3. Use market orders (execute immediately)

---

## Advanced Topics

### Rate Limiting

**Alpaca API Limits**:
- 200 requests per minute
- Applies to all API calls (quotes, orders, positions)

**How StockSwingTrader handles it**:
- Automatic request throttling
- Caches data to reduce calls
- Batches multiple symbols

**If you hit limits**:
1. Wait 1-2 minutes
2. Retry request
3. Reduce number of symbols analyzed
4. Upgrade account tier for higher limits

### Market Hours

**Regular Trading Hours**: 9:30 AM - 4:00 PM ET
- Full market liquidity
- Best for most orders
- Optimal for swing trading

**Extended Hours Trading**: 4:00 AM - 8:00 PM ET
- Pre-market: 4:00 AM - 9:30 AM ET
- After-market: 4:00 PM - 8:00 PM ET
- Lower volume, higher spreads
- Requires permissions in paper account

**Market Closed**:
- Weekends (Saturday, Sunday)
- Holidays (check NYSE calendar)
- Orders placed after hours queue for next open

**Checking market hours**:
```bash
curl https://paper-api.alpaca.markets/v2/clock
```

### Account Restrictions

**Pattern Day Trader (PDT) Rule**:
- If 3+ day trades in rolling 5 days → requires $25,000+ minimum
- Day trade = buying and selling same security same day
- **Paper trading has NO PDT restrictions** (advantage!)

**Recommendation**:
- Use paper mode to learn without PDT limits
- Once profitable with $25k+, consider live trading
- StockSwingTrader is designed for swing trading (1-5 day holds)

### Monitoring Trades

**Alpaca Dashboard**:
1. Visit: https://app.alpaca.markets/paper/dashboard
2. View all orders and positions
3. Monitor account value in real-time
4. See P&L updates

**Via API**:
```bash
# Get account summary
curl -H "Authorization: Bearer $ALPACA_API_KEY" \
  https://paper-api.alpaca.markets/v2/account

# Get all positions
curl -H "Authorization: Bearer $ALPACA_API_KEY" \
  https://paper-api.alpaca.markets/v2/positions

# Get order history
curl -H "Authorization: Bearer $ALPACA_API_KEY" \
  https://paper-api.alpaca.markets/v2/orders
```

---

## Data Source APIs

### Demo Mode Option

StockSwingTrader can run in **demo mode** using free public data (without Alpaca):
- Yahoo Finance (unlimited, no key required)
- Simulated sentiment data
- Full technical analysis

To analyze stocks with Alpaca, follow the Alpaca setup above. To use data source APIs only, continue below.

---

## Data Source APIs

These APIs provide market data, technical indicators, news, and sentiment.

### Alpha Vantage (Free Tier)

### Get API Key

1. Visit https://www.alphavantage.co/
2. Click "Get Free API Key"
3. Enter your email address
4. Your API key will be sent via email
5. Save the key: `WDYX48XXXXXXXXXXXX`

### Rate Limits

- **Free Tier**: 5 calls/minute, 500 calls/day
- **Premium**: Higher limits available

### Add to Config

```bash
# In config.template.sh
export API_KEY_ALPHA_VANTAGE="WDYX48XXXXXXXXXXXX"
```

### Supported Data

- Intraday OHLCV (5-minute candles)
- Daily/weekly/monthly history
- Technical indicators (RSI, MACD, etc.)
- Moving averages

## Finnhub (Free Tier)

### Get API Key

1. Visit https://finnhub.io/register
2. Create a free account
3. Confirm email
4. Login to dashboard
5. Copy your API key from profile
6. Save the key: `c7kh3g8f_YOUR_KEY_HERE`

### Rate Limits

- **Free Tier**: 60 calls/minute
- **Pro**: Higher limits, more data

### Add to Config

```bash
# In config.template.sh
export API_KEY_FINNHUB="c7kh3g8f_YOUR_KEY_HERE"
```

### Supported Data

- Real-time stock quotes
- Company profile and fundamentals
- Earnings calendar
- News aggregation
- Indices data

## NewsAPI (Free Tier)

### Get API Key

1. Visit https://newsapi.org/account
2. Create a free account
3. Verify email
4. Copy API key from dashboard
5. Save the key: `a1b2c3d4e5f6g7h8i9j0k1l2m3`

### Rate Limits

- **Free Tier**: 100 requests/day
- **Developer**: 1,000 requests/day
- **Business**: Higher limits + commercial use

### Add to Config

```bash
# In config.template.sh
export API_KEY_NEWSAPI="a1b2c3d4e5f6g7h8i9j0k1l2m3"
```

### Supported Data

- Financial news articles
- Market news
- Company-specific news
- Filters by source, sentiment, date

## Yahoo Finance (No API Key - Free!)

**Already built-in!** Yahoo Finance data is free and doesn't require registration:

- Historical OHLCV data
- Real-time quotes
- Company fundamentals
- No rate limiting (practical limit ~2000/day)

### No Configuration Needed

Yahoo Finance is automatically used for:
- Historical price data (last 60 days)
- Technical indicator calculations
- Sentiment analysis fallback

## Twitter API (Optional)

### For Advanced Sentiment Analysis

1. Apply for Twitter API access: https://developer.twitter.com/
2. Get approved (may take a few days)
3. Create an app and generate keys/tokens
4. (Future enhancement - not yet integrated)

## Reddit API (Optional)

### For Advanced Sentiment Analysis

1. Create a Reddit account: https://reddit.com/register
2. Visit https://old.reddit.com/prefs/apps
3. Create an app ("script")
4. Copy client_id and client_secret
5. (Future enhancement - not yet integrated)

## Complete Configuration

Once you have all API keys (Alpaca + optional data sources), edit `config/api_keys.sh`:

```bash
#!/bin/bash

# === ALPACA (REQUIRED FOR TRADING) ===
export ALPACA_API_KEY="PK1234567890ABCDEF"
export ALPACA_SECRET_KEY="1a2b3c4d5e6f7g8h9i0j1k2l3m4n5o6p"

# === DATA SOURCES (OPTIONAL, ENHANCES ANALYSIS) ===
export API_KEY_ALPHA_VANTAGE="your_alpha_vantage_key"
export API_KEY_FINNHUB="your_finnhub_key"
export API_KEY_NEWSAPI="your_newsapi_key"

# === TRADING PARAMETERS ===
export TRADING_MODE="paper"  # or "live"
export MAX_POSITION_SIZE="100"  # shares per position
export MAX_OPEN_POSITIONS="10"
```

Then run the agent:

```bash
source config/api_keys.sh
./StockSwingTrader_Agent.sh --alpaca --symbols AAPL,MSFT
```

## Security Best Practices

### DO:
- ✅ Store API keys in `config/api_keys.sh` (not in git)
- ✅ Use environment variables: `export ALPACA_API_KEY="xxx"`
- ✅ Rotate keys regularly (regenerate every 3-6 months)
- ✅ Use API key restrictions in provider dashboards (e.g., IP whitelisting)
- ✅ Monitor API usage in provider dashboards
- ✅ Keep Secret Key as secret as a password
- ✅ Verify .gitignore includes config/api_keys.sh and .env

### DO NOT:
- ❌ Commit API keys to git/GitHub
- ❌ Share keys via email, chat, or Slack
- ❌ Use production keys in test scripts
- ❌ Log API keys to files
- ❌ Hardcode keys in the agent script
- ❌ Include config/api_keys.sh in version control
- ❌ Share your Secret Key with anyone

### Verify Keys Are Protected

```bash
# Check .gitignore includes api_keys.sh
grep "api_keys.sh" .gitignore

# Verify keys are not committed
git log -p | grep -i "ALPACA_API_KEY"

# Ensure config file not tracked
git status config/

## Free Tier vs Paid

| Service | Free Tier | Cost | Use Case |
|---------|-----------|------|----------|
| **Alpaca Paper Trading** | $100k simulated | Free | Learn & test strategies safely |
| **Alpaca Live Trading** | $500+ minimum | Free | Real money trading |
| **Yahoo Finance** | Unlimited | Free | OHLCV, quotes, fundamentals |
| **Alpha Vantage** | 500/day | $30/mo+ | Technical indicators, intraday |
| **Finnhub** | 60/min | $100/mo+ | Real-time quotes, news |
| **NewsAPI** | 100/day | $45/mo+ | Financial news aggregation |

**Recommendation**: 
- **Start**: Paper trading with Yahoo Finance (completely free)
- **Enhance**: Add Alpha Vantage or Finnhub for better signals ($30-100/mo)
- **Analyze 100+ stocks daily**: Use data source APIs

## Testing API Keys

### Test Alpaca Connection

```bash
# Test with API key
curl -H "Authorization: Bearer $ALPACA_API_KEY" \
  https://paper-api.alpaca.markets/v2/account
```

**Expected response** (JSON with account details):
```json
{
  "id": "account_id",
  "account_number": "PA12345678",
  "status": "ACTIVE",
  "cash": "100000.00",
  "portfolio_value": "100000.00"
}
```

### Test Alpha Vantage

```bash
curl "https://www.alphavantage.co/query?function=RSI&symbol=AAPL&interval=daily&time_period=14&apikey=YOUR_KEY"
```

### Test Finnhub

```bash
curl "https://finnhub.io/api/v1/quote?symbol=AAPL&token=YOUR_KEY"
```

### Test NewsAPI

```bash
curl "https://newsapi.org/v2/everything?q=apple&apiKey=YOUR_KEY"
```

## Troubleshooting

### Alpaca Issues

See [Advanced Troubleshooting](#troubleshooting) section above.

### Data Source Issues

### Issue: "Invalid API key"

- Verify key is correct (copy from provider dashboard, don't type)
- Check for extra spaces or characters
- Ensure you're using the right API endpoint
- Not using admin key/secret in place of regular API key

### Issue: "Rate limit exceeded"

- Free tier has limited requests
- Consider upgrading to paid tier
- Reduce number of stocks analyzed per request
- Add delays between requests

### Issue: "Unauthorized (401)"

- API key is invalid or expired
- Using wrong API (Finnhub key in Alpha Vantage field)
- Account suspended or API access disabled

### Issue: "Forbidden (403)"

- API key restrictions blocking your IP
- Service tier doesn't include this endpoint
- Contact API provider support to enable access

### Issue: Agent works without API keys but data is incomplete

This is normal! Agent degrades gracefully:
- Historical data: Retrieved from Yahoo Finance only
- Sentiment: Simulated or cached
- Intraday data: Unavailable without Alpha Vantage

**Solution**: Add API keys to enhance analysis

---

## Next Steps

1. **Start with Alpaca**:
   - Create account at https://alpaca.markets
   - Generate API keys
   - Set environment variables
   - Test with `--alpaca --check-account`

2. **Add Data Sources** (optional):
   - Get API keys from Alpha Vantage, Finnhub, NewsAPI
   - Add to config/api_keys.sh
   - Improves analysis quality

3. **Practice on Paper**:
   - Analyze stocks with `--alpaca --symbols AAPL,MSFT`
   - Paper trade to learn strategies
   - Build confidence before live trading

4. **Monitor & Optimize**:
   - Check logs: `tail -f logs/agent.log`
   - Review trades: `./StockSwingTrader_Agent.sh --alpaca --view-positions`
   - Track performance metrics

5. **Go Live** (optional, requires $500+):
   - Update config to `TRADING_MODE="live"`
   - Start with small positions
   - Use stop losses always

---

## Resources

- **Alpaca Official Docs**: https://alpaca.markets/docs/
- **Alpaca API Reference**: https://alpaca.markets/docs/api-references/
- **Market Hours**: https://www.nyse.com/publicdocs/nyse/trading/holidays_and_hours.html
- **Alpaca Status**: https://status.alpaca.markets
- **StockSwingTrader Docs**: See [README.md](README.md)
- **Trading Strategy**: See [DESIGN.md](DESIGN.md)
