# API Setup Guide

This guide shows how to acquire and configure API keys for StockSwingTrader.

## Optional: The Agent Works Without API Keys!

StockSwingTrader can run in **demo mode** using free public data:
- Yahoo Finance (unlimited, no key required)
- Simulated sentiment data
- Full technical analysis

To use API keys for enhanced features, follow the steps below.

## Alpha Vantage (Free Tier)

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

Once you have API keys, edit `config.template.sh`:

```bash
#!/bin/bash

# Copy this file and set your API keys
export API_KEY_ALPHA_VANTAGE="your_alpha_vantage_key"
export API_KEY_FINNHUB="your_finnhub_key"
export API_KEY_NEWSAPI="your_newsapi_key"

# All other settings (indicator periods, thresholds, etc.)
# ... (rest of config)
```

Then run the agent:

```bash
source config.template.sh
./StockSwingTrader_Agent.sh --symbols AAPL,MSFT
```

## Security Best Practices

### DO:
- ✅ Store API keys in `config.template.sh` (not in git)
- ✅ Use environment variables: `export API_KEY_FINNHUB="xxx"`
- ✅ Rotate keys regularly
- ✅ Use API key restrictions (e.g., IP whitelisting)
- ✅ Monitor API usage in provider dashboards

### DO NOT:
- ❌ Commit API keys to git/GitHub
- ❌ Share keys via email or chat
- ❌ Use production keys in test scripts
- ❌ Log API keys to files
- ❌ Hardcode keys in the agent script

## Free Tier vs Paid

| Service | Free Tier | Cost | Use Case |
|---------|-----------|------|----------|
| **Yahoo Finance** | Unlimited | Free | OHLCV, quotes, fundamentals |
| **Alpha Vantage** | 500/day | $30/mo+ | Technical indicators, intraday |
| **Finnhub** | 60/min | $100/mo+ | Real-time quotes, news |
| **NewsAPI** | 100/day | $45/mo+ | Financial news aggregation |
| **Twitter API** | Limited | $100/mo+ | Social sentiment (advanced) |
| **Reddit** | Free | Free | Social sentiment via PRAW |

**Recommendation**: Start with **free tier** (Yahoo Finance + NewsAPI) for 100+ daily analyses.

## Testing API Keys

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

### Issue: "Invalid API key"

- Verify key is correct (copy from provider dashboard)
- Check for extra spaces or characters
- Ensure you're using the right API (not admin/secret key)

### Issue: "Rate limit exceeded"

- Wait before making more requests
- Consider upgrading to paid tier
- Reduce number of stocks analyzed

### Issue: "Unauthorized (401)"

- Key is invalid or expired
- Key for wrong API (Finnhub key in Alpha Vantage field)
- Account suspended

### Issue: "Forbidden (403)"

- API key restrictions blocking your IP
- Service tier doesn't include this endpoint
- Contact API provider support

### Issue: Agent works without API keys but data is incomplete

- This is normal! Agent degrades gracefully
- Historical data from Yahoo Finance only
- Sentiment is simulated/cached
- Intraday data unavailable

To get complete data: add API keys

## Next Steps

1. Decide which APIs you need (free tier is fine to start)
2. Get API keys from provider websites
3. Add keys to `config.template.sh`
4. Run agent: `./StockSwingTrader_Agent.sh --symbols AAPL`
5. Check logs: `tail -f logs/agent.log`

For more details, see [README.md](README.md).
