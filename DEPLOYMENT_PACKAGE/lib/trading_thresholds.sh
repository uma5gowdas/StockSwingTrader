#!/bin/bash
# ============================================================================
# StockSwingTrader v6.1: Centralized Trading Thresholds & Constants
# ============================================================================
# Purpose: Single source of truth for all trading parameters, indicator 
#          settings, risk management thresholds, and strategy parameters
# ============================================================================

# ============================================================================
# MEAN REVERSION STRATEGY THRESHOLDS
# ============================================================================
export MR_RSI_ENTRY_OVERSOLD=30
export MR_RSI_EXIT_OVERBOUGHT=70
export MR_BB_LOWER_TOUCH_THRESHOLD=0.02  # 2% from lower band
export MR_VOLUME_THRESHOLD_DAYS=20       # 20-day average volume
export MR_MACD_POSITIVE_FOR_ENTRY=true   # Require MACD > signal for entry
export MR_TAKE_PROFIT_PCT=8
export MR_STOP_LOSS_PCT=3
export MR_MAX_POSITION_RISK_PCT=2

# ============================================================================
# TREND FOLLOWING STRATEGY THRESHOLDS
# ============================================================================
export TF_EMA_FAST_PERIOD=12
export TF_EMA_SLOW_PERIOD=26
export TF_SMA_MID_PERIOD=50
export TF_SMA_LONG_PERIOD=200
export TF_VOLUME_THRESHOLD_DAYS=30      # 30-day average volume
export TF_TAKE_PROFIT_PCT=12
export TF_ATR_STOP_MULTIPLIER=1.5       # Stop = Entry - (1.5 × ATR)
export TF_MAX_POSITION_RISK_PCT=2
export TF_ATR_PERIOD=14

# ============================================================================
# INDICATOR PARAMETERS
# ============================================================================
export RSI_PERIOD=14
export RSI_OVERBOUGHT=70
export RSI_OVERSOLD=30
export RSI_DIV_LOOKBACK_PERIODS=10       # For RSI divergence detection

export MACD_FAST_PERIOD=12
export MACD_SLOW_PERIOD=26
export MACD_SIGNAL_PERIOD=9

export BOLLINGER_BAND_PERIOD=20
export BOLLINGER_STD_DEV=2

export VWMA_PERIOD=20                    # Volume-weighted MA period

export MOMENTUM_PERIOD=12

export SMA_PERIODS="20 50 200"
export EMA_PERIODS="12 26"
export ATR_PERIOD=14

# ============================================================================
# RISK MANAGEMENT CONSTANTS
# ============================================================================
# Kelly Criterion position sizing
export KELLY_CRITERION_DIVISOR=4         # Use Kelly/4 for conservative sizing
export MIN_ACCOUNT_EQUITY_FOR_TRADE=5000  # Don't trade if account < 5k

# Position sizing
export KELLY_WIN_RATE=0.55               # Assumed win rate for position sizing
export KELLY_WIN_LOSS_RATIO=1.5          # Avg win / avg loss ratio

# Portfolio limits
export MAX_CONCURRENT_POSITIONS_CONSERVATIVE=1
export MAX_CONCURRENT_POSITIONS_MODERATE=3
export MAX_CONCURRENT_POSITIONS_AGGRESSIVE=5

# Risk levels map position limits and default position size
export RISK_LEVEL_CONSERVATIVE_LIMIT=1
export RISK_LEVEL_MODERATE_LIMIT=3
export RISK_LEVEL_AGGRESSIVE_LIMIT=5

export RISK_LEVEL_CONSERVATIVE_RISK_PCT=1    # 1% risk per trade
export RISK_LEVEL_MODERATE_RISK_PCT=2        # 2% risk per trade
export RISK_LEVEL_AGGRESSIVE_RISK_PCT=3      # 3% risk per trade

# Daily drawdown monitoring
export DAILY_LOSS_LIMIT_CONSERVATIVE_PCT=2   # Stop trading if 2% loss in a day
export DAILY_LOSS_LIMIT_MODERATE_PCT=5       # Stop trading if 5% loss in a day
export DAILY_LOSS_LIMIT_AGGRESSIVE_PCT=10    # Stop trading if 10% loss in a day

# ============================================================================
# SCORING & CONFLUENCE WEIGHTS
# ============================================================================
# Technical Indicator Weights (should sum to 100%)
export SCORE_WEIGHT_RSI=12
export SCORE_WEIGHT_MACD=12
export SCORE_WEIGHT_BOLLINGER=12
export SCORE_WEIGHT_SMA=12
export SCORE_WEIGHT_EMA=12
export SCORE_WEIGHT_ATR=10
export SCORE_WEIGHT_OBV=10
export SCORE_WEIGHT_STOCHASTIC=8
export SCORE_WEIGHT_WILLIAMS_R=4

# New v6.1 Indicator Weights
export SCORE_WEIGHT_RSI_DIVERGENCE=10
export SCORE_WEIGHT_VWMA=10
export SCORE_WEIGHT_MOMENTUM=10

# Sentiment weights (if using sentiment analysis)
export SCORE_WEIGHT_SENTIMENT_TWITTER=5
export SCORE_WEIGHT_SENTIMENT_REDDIT=5
export SCORE_WEIGHT_SENTIMENT_NEWS=5

# ============================================================================
# SIGNAL CONFIDENCE THRESHOLDS
# ============================================================================
export CONFIDENCE_STRONG_BUY=75
export CONFIDENCE_BUY=60
export CONFIDENCE_HOLD=40
export CONFIDENCE_SELL=25
export CONFIDENCE_STRONG_SELL=10

# ============================================================================
# API & RATE LIMITING
# ============================================================================
export ALPACA_API_TIMEOUT=30
export ALPACA_RATE_LIMIT_DELAY=1         # Seconds between API calls
export DATA_CACHE_TTL=300                # Cache data for 5 minutes

# ============================================================================
# MONITORING & LOGGING
# ============================================================================
export POSITION_MONITOR_INTERVAL=30      # Check positions every 30 seconds
export LOG_DIR="logs"
export TRADE_JOURNAL_FILE="logs/trades.json"
export BACKTEST_RESULTS_FILE="logs/backtest_results.json"

# ============================================================================
# STRATEGY DEFAULTS
# ============================================================================
export DEFAULT_STRATEGY="mean_reversion"
export DEFAULT_RISK_LEVEL="moderate"
export SUPPORTED_STRATEGIES="mean_reversion trend_follow both"
export SUPPORTED_RISK_LEVELS="conservative moderate aggressive"
