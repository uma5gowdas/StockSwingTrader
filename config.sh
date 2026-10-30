#!/bin/bash
# ============================================================================
# StockSwingTrader Configuration - ALPACA INTEGRATION
# ============================================================================
# Security: Keep this file private! Add to .gitignore if using version control

# ============================================================================
# ALPACA API CREDENTIALS (Paper Trading)
# ============================================================================
export ALPACA_API_KEY="PK76WBZRA3WVIRGIZTD6SVVOTB"
export ALPACA_SECRET_KEY="Hgio83rdZWCzGqRZF8ABqvQgFmnL5xREsj6hw2ecQMxj"
export ALPACA_BASE_URL="https://paper-api.alpaca.markets"  # Paper trading
# export ALPACA_BASE_URL="https://api.alpaca.markets"      # Live trading (use with caution!)

# ============================================================================
# Data Source API Keys (Optional - for enhanced signals)
# ============================================================================
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
export CONFIDENCE_STRONG_BUY=75
export CONFIDENCE_BUY=60
export CONFIDENCE_HOLD=40
export CONFIDENCE_SELL=25
export CONFIDENCE_STRONG_SELL=10

# ============================================================================
# Risk Management Parameters
# ============================================================================
export STOP_LOSS_PERCENT=5
export STOP_LOSS_ATR_MULTIPLIER=2
export TARGET_PROFIT_PERCENT=8
export MAX_POSITION_SIZE=2500

# ============================================================================
# Data Freshness & Caching
# ============================================================================
export CACHE_MAX_AGE_MINUTES=60
export INTRADAY_DATA_POINTS=60

# ============================================================================
# Sentiment Analysis Weights
# ============================================================================
export SENTIMENT_WEIGHT=0.2
export TECHNICAL_WEIGHT=0.8

# ============================================================================
# Data Fetch Preferences
# ============================================================================
export PREFER_YAHOO_FINANCE=true
export ENABLE_ALPHA_VANTAGE=true
export ENABLE_FINNHUB=true
export ENABLE_NEWSAPI=true
export ENABLE_TWITTER_REDDIT=true

# ============================================================================
# Alpaca Trading Settings
# ============================================================================
export ALPACA_TRADING_ENABLED=true              # Enable placing orders
export ALPACA_AUTO_TRADE_ON_STRONG_BUY=false   # Auto-trade on signals (careful!)
export ALPACA_MAX_POSITIONS=5                   # Max simultaneous positions
export ALPACA_CHECK_BEFORE_TRADE=true           # Verify account health before orders

# ============================================================================
# Output & Reporting
# ============================================================================
export REPORT_TIMEZONE="UTC"
export INCLUDE_CHART_IN_REPORT=true
export INCLUDE_SENTIMENT_DETAILS=true

# ============================================================================
# Logging & Debug
# ============================================================================
export LOG_LEVEL="INFO"
export LOG_FILE="logs/agent.log"
export DEBUG_MODE=false

# ============================================================================
# API Rate Limiting
# ============================================================================
export RATE_LIMIT_ALPHA_VANTAGE_PER_MIN=5
export RATE_LIMIT_FINNHUB_PER_MIN=60
export RATE_LIMIT_NEWSAPI_PER_DAY=100
export RATE_LIMIT_TWITTER_REDDIT_PER_MIN=1

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

# Configuration loaded successfully

# ============================================================================
# v6.1 Strategy & Risk Management Defaults
# ============================================================================
export DEFAULT_STRATEGY="mean_reversion"
export DEFAULT_RISK_LEVEL="moderate"
export SUPPORTED_STRATEGIES="mean_reversion trend_follow both"
export SUPPORTED_RISK_LEVELS="conservative moderate aggressive"
