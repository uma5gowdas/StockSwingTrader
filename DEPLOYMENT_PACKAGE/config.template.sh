#!/bin/bash
# ============================================================================
# StockSwingTrader Configuration Template
# ============================================================================
# Copy this file to config.template.sh and populate with your actual API keys
# For security, use environment variables or external config file (not in git)
#
# API Key Acquisition:
#   - Alpha Vantage: https://www.alphavantage.co/api/
#   - Finnhub: https://finnhub.io/register
#   - NewsAPI: https://newsapi.org/account
#   - Yahoo Finance: No API key needed (public data)
# ============================================================================

# ============================================================================
# API Keys & Credentials
# ============================================================================
# Leave as "demo" for testing; replace with real keys for production
export API_KEY_ALPHA_VANTAGE="YOUR_API_KEY_ALPHA_VANTAGE"
export API_KEY_FINNHUB="YOUR_API_KEY_FINNHUB"
export API_KEY_NEWSAPI="YOUR_API_KEY_NEWSAPI"

# ============================================================================
# Technical Indicator Periods & Thresholds
# ============================================================================
export SMA_PERIODS="20 50 200"
export EMA_PERIODS="12 26"
export RSI_PERIOD=14
export RSI_OVERBOUGHT=70
export RSI_OVERSOLD=30
export MACD_FAST=12
export MACD_SLOW=26
export MACD_SIGNAL=9
export BOLLINGER_PERIOD=20
export BOLLINGER_STD_DEV=2
export ATR_PERIOD=14
export STOCHASTIC_PERIOD=14
export STOCHASTIC_K_SMOOTH=3
export STOCHASTIC_D_SMOOTH=3
export WILLIAMS_R_PERIOD=14

# ============================================================================
# Swing Trading Confidence Thresholds
# ============================================================================
export CONFIDENCE_STRONG_BUY=75          # >= this = strong BUY
export CONFIDENCE_BUY=60                 # 60-74 = BUY
export CONFIDENCE_HOLD=40                # 40-59 = HOLD
export CONFIDENCE_SELL=25                # 25-39 = SELL
export CONFIDENCE_STRONG_SELL=10         # <= this = STRONG SELL

# ============================================================================
# Risk Management Parameters
# ============================================================================
export STOP_LOSS_PERCENT=5               # Exit at 5% loss
export STOP_LOSS_ATR_MULTIPLIER=2        # SL = entry - (2 * ATR)
export TARGET_PROFIT_PERCENT=8           # Exit at 8% gain
export MAX_POSITION_SIZE=2500            # Max investment per trade (demo)

# ============================================================================
# Data Freshness & Caching
# ============================================================================
export CACHE_MAX_AGE_MINUTES=60          # Refresh if older than 60 min
export INTRADAY_DATA_POINTS=60           # Use last 60 5-min candles for recent trends

# ============================================================================
# Sentiment Analysis Weights
# ============================================================================
export SENTIMENT_WEIGHT=0.2              # 20% of confidence score
export TECHNICAL_WEIGHT=0.8              # 80% of confidence score

# ============================================================================
# Data Fetch Preferences
# ============================================================================
export PREFER_YAHOO_FINANCE=true         # Use YF for OHLCV (unlimited, free)
export ENABLE_ALPHA_VANTAGE=true         # Use AV for intraday/historical (5 calls/min)
export ENABLE_FINNHUB=true               # Use Finnhub for real-time quotes (60 calls/min)
export ENABLE_NEWSAPI=true               # Fetch news for sentiment (tier-limited)
export ENABLE_TWITTER_REDDIT=true        # Parse social media sentiment

# ============================================================================
# Output & Reporting
# ============================================================================
export REPORT_TIMEZONE="UTC"             # Timezone for timestamps
export INCLUDE_CHART_IN_REPORT=true      # Generate ASCII/SVG charts in HTML
export INCLUDE_SENTIMENT_DETAILS=true    # Show detailed sentiment breakdown

# ============================================================================
# Logging & Debug
# ============================================================================
export LOG_LEVEL="INFO"                  # DEBUG, INFO, WARN, ERROR
export LOG_FILE="logs/agent.log"
export DEBUG_MODE=false                  # Set to true for verbose output

# ============================================================================
# API Rate Limiting
# ============================================================================
export RATE_LIMIT_ALPHA_VANTAGE_PER_MIN=5      # 5 calls/minute
export RATE_LIMIT_FINNHUB_PER_MIN=60           # 60 calls/minute
export RATE_LIMIT_NEWSAPI_PER_DAY=100          # Depends on tier
export RATE_LIMIT_TWITTER_REDDIT_PER_MIN=1    # Throttle social scraping

# ============================================================================
# Retry & Timeout Configuration
# ============================================================================
export MAX_RETRIES=3
export INITIAL_BACKOFF_SECONDS=1
export BACKOFF_MULTIPLIER=2
export API_TIMEOUT_SECONDS=15
export CURL_CONNECT_TIMEOUT=10

# ============================================================================
# Data Sources & Watchlist
# ============================================================================
export DEFAULT_WATCHLIST="AAPL,MSFT,GOOGL,AMZN,TSLA,META,NFLX,CRM,ADBE,NVDA"
export MAX_STOCKS_TO_ANALYZE=10

# ============================================================================
# Output & Status Reporting (Extended)
# ============================================================================
export INCLUDE_ALPACA_STATUS=true        # Show Alpaca trading status in reports

# ============================================================================
# Logging (Extended)
# ============================================================================
export ALPACA_LOG_FILE="logs/alpaca.log"

# ============================================================================
# Alpaca Paper Trading Configuration
# ============================================================================
# Get API credentials from: https://app.alpaca.markets/paper/settings/api
# Paper Trading URL: https://paper-api.alpaca.markets/v2
# Live Trading URL: https://api.alpaca.markets/v2 (use with caution!)
#
# SECURITY BEST PRACTICES:
#   - NEVER commit API keys to version control
#   - Store credentials in environment variables or external config file
#   - Use paper trading account for testing and development
#   - Rotate API keys regularly
#   - Use API keys with minimal required permissions
#   - For production use, consider using IAM roles or credential providers
#
# SETUP INSTRUCTIONS:
#   1. Generate Alpaca API key from https://app.alpaca.markets/paper/settings/api
#   2. Set environment variables in your shell profile or .env file:
#      export ALPACA_API_KEY="your_key_here"
#      export ALPACA_SECRET_KEY="your_secret_here"
#   3. OR create config/api_keys.sh (NOT tracked in git):
#      source config/api_keys.sh before running start_paper.sh
#   4. Example config/api_keys.sh:
#      #!/bin/bash
#      export ALPACA_API_KEY="PK1234567890ABCDEF"
#      export ALPACA_SECRET_KEY="your_secret_key_here"
#      chmod 600 config/api_keys.sh  # Restrict permissions
#   5. Add config/api_keys.sh to .gitignore (already protected)
#
# IMPORTANT: This template file contains NO real credentials. It's safe to commit.
# Keep config/api_keys.sh private and out of version control.

export ALPACA_ENABLED="${ALPACA_ENABLED:-false}"
export ALPACA_API_KEY="${ALPACA_API_KEY:-}"
export ALPACA_SECRET_KEY="${ALPACA_SECRET_KEY:-}"
export ALPACA_BASE_URL="${ALPACA_BASE_URL:-https://paper-api.alpaca.markets}"
export ALPACA_MODE="paper"               # paper or live (paper recommended for testing)
export ALPACA_TIMEOUT_SECONDS=15
export ALPACA_MAX_RETRIES=3

# ============================================================================
# Alpaca Trading Rules & Parameters
# ============================================================================
export ALPACA_MIN_POSITION_SIZE=100      # Minimum shares to hold
export ALPACA_MAX_POSITION_SIZE=1000     # Maximum shares per trade
export ALPACA_AUTO_TRADE=false           # Auto-execute on strong signals?
export ALPACA_STRONG_BUY_THRESHOLD=80    # Confluence score to auto-buy
export ALPACA_STRONG_SELL_THRESHOLD=20   # Confluence score to auto-sell
export ALPACA_LOG_ALL_TRADES=true        # Log every trade attempt

# Note: Source this file from StockSwingTrader_Agent.sh to load all configuration

# Robinhood Broker Configuration (NEW in v6.2)
# Update with your Robinhood developer credentials
ROBINHOOD_CLIENT_ID="your_app_id"
ROBINHOOD_CLIENT_SECRET="your_client_secret"
ROBINHOOD_REDIRECT_URI="http://localhost:8000"

# Token management is auto-handled via OAuth flow.
# Tokens stored in ~/.robinhood_tokens.json (created during first setup)
# Run: ./lib/robinhood_oauth.sh --setup to authenticate
# Tokens auto-refresh in background before expiration
