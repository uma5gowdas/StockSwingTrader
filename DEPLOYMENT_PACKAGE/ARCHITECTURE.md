# StockSwingTrader v6.3 - Architecture Guide

**Version:** 6.3  
**Last Updated:** October 30, 2024

---

## System Architecture

### High-Level Overview

```
┌─────────────────────────────────────────────────────────────────┐
│               StockSwingTrader v6.3 System Architecture         │
└─────────────────────────────────────────────────────────────────┘
                              │
                    ┌─────────┴─────────┐
                    │                   │
           ┌────────▼────────┐   ┌─────▼────────┐
           │  Command Line   │   │  Dashboard   │
           │   Interface     │   │   UI (React) │
           └────────┬────────┘   └─────┬────────┘
                    │                   │
                    │      ┌────────────┤
                    │      │            │
           ┌────────▼──────▼──┐    ┌────▼─────────┐
           │  Main Agent      │    │  Backend API │
           │  Orchestrator    │    │  (Node.js)   │
           └────────┬─────────┘    └──────────────┘
                    │
        ┌───────────┼───────────┐
        │           │           │
    ┌───▼──┐   ┌────▼────┐ ┌───▼────┐
    │Data  │   │Analysis │ │Output  │
    │Fetch │   │Engine   │ │Modules │
    └───┬──┘   └────┬────┘ └───┬────┘
        │           │          │
        │    ┌──────▼──────┐   │
        └────►│ Scoring    ├───┘
             │ Pipeline   │
             └────────────┘
```

### Module Layers

```
┌─────────────────────────────────────────────────────────────┐
│                    Presentation Layer                       │
│  ┌──────────────────┐            ┌──────────────────────┐  │
│  │  CLI Interface   │            │  React Dashboard     │  │
│  │  Commands        │            │  REST API Client     │  │
│  └──────────────────┘            └──────────────────────┘  │
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│                 Application Layer                           │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Main Agent (StockSwingTrader_Agent.sh)               │ │
│  │  - Orchestration                                      │ │
│  │  - Argument parsing                                   │ │
│  │  - Pipeline execution                                │ │
│  └────────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Backend API (Node.js/Express)                         │ │
│  │  - REST endpoints                                      │ │
│  │  - Shell command execution                             │ │
│  │  - Result caching                                      │ │
│  └────────────────────────────────────────────────────────┘ │
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│                   Analysis Layer                            │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │ Data        │  │ Indicators   │  │ Strategies   │       │
│  │ Acquisition │  │ Calculation  │  │ Signals      │       │
│  └─────────────┘  └──────────────┘  └──────────────┘       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │ ML/AI       │  │ Regime       │  │ Sentiment    │       │
│  │ Predictions │  │ Detection    │  │ Analysis     │       │
│  └──────────────┘  └──────────────┘  └──────────────┘       │
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│                  Integration Layer                          │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Scoring Pipeline (Confluence Calculation)             │ │
│  │  - Weight individual signals                            │ │
│  │  - Normalize scores                                     │ │
│  │  - Generate final signal                               │ │
│  └────────────────────────────────────────────────────────┘ │
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│                   Output Layer                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  JSON Results  │  HTML Reports  │  CSV Export       │   │
│  └─────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Broker Integration (Alpaca / Robinhood)            │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## Component Dependencies

### Module Dependency Graph

```
StockSwingTrader_Agent.sh (Main Orchestrator)
│
├── config.sh (Configuration)
│
├── lib/indicators.sh ◄─── Technical Indicator Calculations
│   └─ Calculates: RSI, MACD, Bollinger, ATR, OBV, Stochastic, EMA
│
├── lib/kalman_filter.sh ◄─── Price Smoothing
│   └─ lib/kalman_inference.py
│
├── lib/regime_detector.sh ◄─── Market Condition Classification
│   ├─ Uses: ATR, ADX, EMA trends
│   └─ Output: Regime classification
│
├── lib/regime_weighting.sh ◄─── Adaptive Strategy Weights
│   └─ Uses: Regime classification
│
├── lib/strategy_mean_reversion.sh ◄─── MR Strategy Signals
│   └─ Uses: RSI, Bollinger Band signals
│
├── lib/strategy_trend_follow.sh ◄─── TF Strategy Signals
│   └─ Uses: EMA crossovers, MACD signals
│
├── lib/ml_predictor.sh ◄─── ML Model Predictions
│   ├─ lib/ml_inference.py
│   └─ lib/models/xgboost_predictor.pkl
│
├── lib/sentiment.sh ◄─── Social & News Sentiment
│   └─ Uses: Twitter, StockTwits, NewsAPI
│
├── lib/scoring.sh ◄─── Confluence Score Calculation
│   ├─ Uses: All indicator scores
│   └─ Weights: Technical(30%), ML(15%), Regime(35%), Volume(20%)
│
├── lib/risk_management.sh ◄─── Risk Calculations
│   └─ Calculates: Stop-loss, Profit targets
│
├── lib/html_report.sh ◄─── Report Generation
│
├── lib/backtest.sh ◄─── Backtesting Framework
│   └─ lib/backtest_engine.py
│
├── lib/alpaca_broker.sh ◄─── Alpaca Integration
│   └─ Trade execution, account management
│
└── lib/robinhood_broker.sh ◄─── Robinhood Integration
    └─ Trade execution, account management
```

---

## Data Flow Pipeline

### Complete Analysis Flow

```
INPUT: Symbol(s)
   │
   ├─ [1] RATE LIMIT CHECK
   │       └─ Check API call limits
   │
   ├─ [2] FETCH PRICE DATA
   │       ├─ Alpha Vantage: Intraday (5-min) + Daily (90 days)
   │       ├─ Cache results
   │       └─ Output: OHLCV data
   │
   ├─ [3] KALMAN FILTER (if --kalman enabled)
   │       ├─ Input: Raw prices
   │       ├─ Process: Apply Kalman equations
   │       └─ Output: Smoothed prices + volatility
   │
   ├─ [4] REGIME DETECTION
   │       ├─ Input: Smoothed prices
   │       ├─ Calculate: ADX, volatility metrics
   │       └─ Output: Regime classification
   │           ├─ SIDEWAYS
   │           ├─ TRENDING_BULL
   │           ├─ TRENDING_BEAR
   │           └─ VOLATILE
   │
   ├─ [5] CALCULATE INDICATORS (Parallel)
   │       ├─ RSI(14)
   │       ├─ MACD(12,26,9)
   │       ├─ Bollinger(20,2)
   │       ├─ ATR(14)
   │       ├─ OBV
   │       ├─ Stochastic(14,3,3)
   │       ├─ Williams %R
   │       └─ EMA(20), EMA(50)
   │
   ├─ [6] STRATEGY SIGNALS
   │       ├─ Mean Reversion Strategy
   │       │   ├─ Buy: RSI < 30, Price < BB_Lower
   │       │   ├─ Sell: RSI > 70
   │       │   └─ Score: 0-100
   │       │
   │       └─ Trend Following Strategy
   │           ├─ Buy: Price > EMA(50), MACD > 0
   │           ├─ Sell: Price < EMA(20)
   │           └─ Score: 0-100
   │
   ├─ [7] SENTIMENT ANALYSIS (if enabled)
   │       ├─ Twitter/X: Tweet sentiment
   │       ├─ StockTwits: Community sentiment
   │       ├─ News: Headline sentiment
   │       └─ Output: -100 to +100 score
   │
   ├─ [8] ML PREDICTION (if --ml enabled)
   │       ├─ Features: 8 indicators
   │       ├─ Model: XGBoost binary classifier
   │       ├─ Output: Direction (up/down)
   │       └─ Confidence: 0-100
   │
   ├─ [9] REGIME-ADAPTIVE WEIGHTING (if --regime-adapt enabled)
   │       ├─ Look up regime
   │       ├─ Apply strategy weights:
   │       │   ├─ Sideways: 70% MR + 30% TF
   │       │   ├─ Trending: 30% MR + 70% TF
   │       │   └─ Volatile: 50% MR + 50% TF
   │       └─ Output: Weighted score
   │
   ├─ [10] CONFLUENCE SCORING
   │       ├─ Technical Score (30%):
   │       │   └─ Count aligned indicators
   │       ├─ ML Score (15%):
   │       │   └─ XGBoost confidence
   │       ├─ Regime-Weighted Score (35%):
   │       │   └─ Strategy weights applied
   │       ├─ Volume/Trend Score (20%):
   │       │   └─ OBV + Volume confirmation
   │       │
   │       └─ Final Score = Weighted Average
   │           └─ 0-100 scale
   │
   ├─ [11] SIGNAL CLASSIFICATION
   │       ├─ STRONG BUY: Score ≥ 75 + multiple confirmations
   │       ├─ BUY: Score ≥ 60 + main trend aligned
   │       ├─ HOLD: 45 ≤ Score < 60
   │       ├─ SELL: Score < 45
   │       └─ STRONG SELL: Score ≤ 25 + multiple warnings
   │
   ├─ [12] SENTIMENT INTEGRATION
   │       ├─ Adjust score ±5 points
   │       ├─ Sentiment > +50: +5 to score
   │       ├─ Sentiment < -50: -5 to score
   │       └─ Store sentiment breakdown
   │
   ├─ [13] RISK MANAGEMENT
   │       ├─ Calculate Stop-Loss:
   │       │   └─ Entry - (ATR × 2)
   │       ├─ Calculate Profit Target:
   │       │   └─ Entry + (ATR × 2 × 2) [2:1 RRR]
   │       └─ Adjust for volatility
   │
   ├─ [14] OUTPUT GENERATION
   │       ├─ JSON: Full analysis results
   │       ├─ HTML: Visual report with charts
   │       ├─ CSV: For spreadsheet import
   │       └─ Dashboard: Real-time display
   │
   └─ OUTPUT: Complete Analysis with Signals & Metrics
```

---

## API Endpoints

### Backend REST API (Node.js/Express)

**Base URL:** `http://localhost:3001`

```
┌─────────────────────────────────────────────────────┐
│              Backend API Endpoints                  │
└─────────────────────────────────────────────────────┘

Health & Monitoring:
  GET  /health                      Server health check
  GET  /api/status                  System status

Analysis:
  GET  /api/analysis/:symbol        Get analysis for symbol
  POST /api/analysis                Analyze multiple symbols
  GET  /api/analysis/:symbol/history Historical analysis

Watchlist:
  GET  /api/watchlist               Get all watchlist items
  POST /api/watchlist               Add symbol to watchlist
  GET  /api/watchlist/:symbol       Get watchlist item details
  PUT  /api/watchlist/:symbol       Update watchlist item
  DELETE /api/watchlist/:symbol     Remove from watchlist

Trading:
  GET  /api/trades                  Get trade history
  GET  /api/trades/:tradeId         Get specific trade
  POST /api/trades                  Create new trade record
  PUT  /api/trades/:tradeId         Update trade record

Portfolio:
  GET  /api/portfolio               Portfolio overview
  GET  /api/portfolio/stats         Portfolio statistics
  GET  /api/portfolio/performance   Performance metrics
  GET  /api/portfolio/allocation    Asset allocation

Backtesting:
  POST /api/backtest                Start backtest
  GET  /api/backtest/:backTestId    Get backtest results
  GET  /api/backtest/:backTestId/optimize Optimization results

Settings:
  GET  /api/settings                Get current settings
  PUT  /api/settings                Update settings
  POST /api/settings/reset          Reset to defaults
```

### Request/Response Format

**Success Response (200 OK):**
```json
{
  "success": true,
  "data": {
    "symbol": "AAPL",
    "price": 235.45,
    "score": 71,
    "signal": "BUY"
  },
  "timestamp": "2024-10-30T14:30:00Z"
}
```

**Error Response (4xx/5xx):**
```json
{
  "success": false,
  "error": "Error message describing what went wrong",
  "code": "ERROR_CODE",
  "details": "Additional error details if available",
  "timestamp": "2024-10-30T14:30:00Z"
}
```

---

## Data Models

### Analysis Result Schema

```json
{
  "symbol": "AAPL",
  "timestamp": "2024-10-30T14:30:00Z",
  "price": {
    "current": 235.45,
    "open": 234.10,
    "high": 236.50,
    "low": 234.05,
    "change": 1.35,
    "change_percent": 0.57
  },
  "indicators": {
    "rsi": {
      "value": 55.23,
      "signal": "neutral",
      "overbought": 70,
      "oversold": 30
    },
    "macd": {
      "macd_line": 0.85,
      "signal_line": 0.62,
      "histogram": 0.23,
      "signal": "bullish"
    },
    "bollinger": {
      "upper": 240.20,
      "middle": 237.15,
      "lower": 234.10,
      "position": 0.68
    }
  },
  "strategies": {
    "mean_reversion": {
      "signal": "buy",
      "score": 65
    },
    "trend_following": {
      "signal": "buy",
      "score": 72
    }
  },
  "regime": {
    "current": "trending_bull",
    "adr": 0.75,
    "volatility": "normal"
  },
  "ml_prediction": {
    "direction": "up",
    "confidence": 78
  },
  "sentiment": {
    "overall": 62,
    "twitter": 58,
    "stocktwits": 65
  },
  "confluence": {
    "technical_score": 68,
    "ml_score": 78,
    "weighted_score": 71,
    "final_score": 71
  },
  "signal": "BUY",
  "confidence_level": "HIGH",
  "risk_management": {
    "entry_price": 235.45,
    "stop_loss": 233.10,
    "profit_target": 239.80,
    "risk_reward_ratio": 2.0
  }
}
```

---

## Performance Characteristics

### Timing Analysis

```
Operation                      | Time    | Target
-------------------------------|---------|--------
Single symbol analysis         | 3-4s    | < 5s ✓
10 symbols (parallel)          | 20-25s  | < 30s ✓
ML prediction inference        | 200ms   | < 500ms ✓
Regime detection              | 100-150ms| < 500ms ✓
Full scoring pipeline         | 300-400ms| < 1s ✓
API response (analysis)       | 300-500ms| < 1s ✓
Dashboard load                | 1-1.5s  | < 2s ✓
Backtest (1 year, 250 days)  | 60-90s  | < 2 min ✓
Grid search (125 combos)      | 2-3 min | < 5 min ✓
```

### Resource Usage

```
Memory:
  Single analysis:        50-100MB
  Dashboard running:      150-200MB
  Backtest (in-progress): 300-500MB
  
CPU:
  Single analysis:        15-25% (single core)
  Dashboard API:          5-10%
  Backtest:              50-80% (all cores)
  
Disk:
  Installation:           500MB
  Logs (per day):         10-50MB
  Backtest results:       5-20MB per run
```

### Scalability

```
Symbols per batch:      1-100 (tested)
Concurrent requests:    10-20 (typical)
Historical data:        Up to 5 years
Refresh rate:           5 seconds (configurable)
```

---

## Deployment Architecture

### Development Setup

```
Developer Workstation
├── Git repository (local)
├── Python venv
├── Node.js installed
└── Configuration (config.sh)

Structure:
  StockSwingTrader/
  ├── .git/
  ├── venv/
  ├── lib/
  ├── backend/
  ├── frontend/
  └── docs/
```

### Production Deployment

```
┌─────────────────────────────────────────┐
│       Load Balancer (Optional)          │
│  (nginx / HAProxy / AWS ALB)            │
└──────────────────┬──────────────────────┘
                   │
        ┌──────────┴──────────┐
        │                     │
┌───────▼──────┐      ┌──────▼───────┐
│ Backend API  │      │   Frontend   │
│ (Node.js)    │      │  (React SPA) │
│ Port 3001    │      │  Port 5173   │
└───────┬──────┘      └──────┬───────┘
        │                     │
        └──────────┬──────────┘
                   │
        ┌──────────▼──────────┐
        │  Main Agent        │
        │  (Orchestrator)    │
        │  Cron / Scheduler  │
        └─────────────────────┘
        
        External Services:
        ├─ Alpha Vantage (Market Data)
        ├─ Finnhub (Alternative Data)
        ├─ Alpaca (Trading Broker)
        ├─ Robinhood (Broker)
        ├─ Twitter API (Sentiment)
        └─ NewsAPI (News Sentiment)
```

### Container Deployment (Docker)

```dockerfile
# Optional future enhancement
FROM node:18-alpine

RUN apk add --no-cache bash python3 pip

WORKDIR /app

COPY . .

RUN pip install -r requirements.txt
RUN npm install --prefix backend
RUN npm install --prefix frontend

EXPOSE 3001 5173

CMD ["bash", "-c", \
  "npm start --prefix backend & \
   npm run dev --prefix frontend & \
   wait"]
```

---

## Error Handling Flow

```
Error Occurs
  │
  ├─ Identify Error Type
  │   ├─ API Error (rate limit, invalid key)
  │   ├─ Data Error (missing OHLC, NaN values)
  │   ├─ Calculation Error (division by zero)
  │   └─ System Error (file not found, permission)
  │
  ├─ Log Error
  │   ├─ Timestamp
  │   ├─ Error message
  │   ├─ Stack trace
  │   └─ Context (symbol, operation)
  │
  ├─ Determine Recovery Strategy
  │   ├─ Retry? (transient errors)
  │   ├─ Use Cache? (stale data)
  │   ├─ Skip? (symbol-specific error)
  │   └─ Fail? (critical errors)
  │
  └─ Return Error Response
      ├─ JSON with error details
      ├─ HTTP status code
      └─ User-friendly message
```

---

**For implementation details, refer to individual module documentation and source code comments.**
