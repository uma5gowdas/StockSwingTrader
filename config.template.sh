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
export API_KEY_ALPHA_VANTAGE="${API_KEY_ALPHA_VANTAGE:-demo}"
export API_KEY_FINNHUB="${API_KEY_FINNHUB:-demo}"
export API_KEY_NEWSAPI="${API_KEY_NEWSAPI:-demo}"

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

# Note: Source this file from StockSwingTrader_Agent.sh to load all configuration
