# StockSwingTrader v6.3 Steering Guide
## Comprehensive Documentation for AI-Enhanced Development

**Version:** 6.3  
**Last Updated:** October 30, 2024  
**Purpose:** Complete guide for future AI agents to understand, enhance, and maintain the codebase

---

## Table of Contents
1. [Architecture Overview](#architecture-overview)
2. [Module Structure](#module-structure)
3. [Data Flow & Pipeline](#data-flow--pipeline)
4. [Enhancement Modules](#enhancement-modules)
5. [API Documentation](#api-documentation)
6. [Development Guidelines](#development-guidelines)
7. [Testing Checklist](#testing-checklist)
8. [Troubleshooting](#troubleshooting)
9. [Future Enhancement Ideas](#future-enhancement-ideas)

---

## Architecture Overview

### System Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                   StockSwingTrader v6.3                         │
│          AI-Powered Swing Trading Analysis Platform             │
└─────────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
    ┌───▼────┐          ┌────▼─────┐         ┌────▼────┐
    │  Data  │          │ Analysis  │         │ Output  │
    │ Sources│          │ Engine    │         │ Modules │
    └───┬────┘          └────┬─────┘         └────┬────┘
        │                    │                     │
    ┌───▼────────────────────▼─────────────────────▼────┐
    │                                                    │
    │  Scoring Pipeline & Integration Layer             │
    │  - Technical Indicators (30%)                      │
    │  - ML Predictor (15%)                              │
    │  - Regime Weighting (35%)                          │
    │  - Volume/Trend (20%)                              │
    │                                                    │
    └───┬──────────────────────────────────────────────┬─┘
        │                                              │
    ┌───▼──────────────┐                    ┌─────────▼──┐
    │  Dashboard UI    │                    │  Reports   │
    │  (React/Vite)    │                    │  & Export  │
    └──────────────────┘                    └────────────┘
```

### Module Dependency Graph

```
StockSwingTrader_Agent.sh (Main Orchestrator)
│
├── config.template.sh (Configuration)
│
├── lib/indicators.sh (Technical Indicators)
│   ├── RSI(14), MACD, Bollinger Bands
│   ├── ATR, OBV, Stochastic, Williams %R
│   └── EMA(20), EMA(50)
│
├── lib/kalman_filter.sh (Price Smoothing)
│   └── lib/kalman_inference.py
│
├── lib/regime_detector.sh (Market Regime Detection)
│   └── Uses Kalman filter output
│
├── lib/regime_weighting.sh (Adaptive Weights)
│   └── Uses regime classification
│
├── lib/ml_predictor.sh (XGBoost Predictions)
│   ├── lib/ml_inference.py
│   ├── lib/train_ml_model.py
│   └── lib/models/xgboost_predictor.pkl
│
├── lib/strategy_mean_reversion.sh (MR Strategy)
│
├── lib/strategy_trend_follow.sh (TF Strategy)
│
├── lib/scoring.sh (Confluence Scoring)
│   └── Integrates all signals
│
├── lib/sentiment.sh (Sentiment Analysis)
│   ├── Twitter/Social signals
│   ├── StockTwits
│   └── News feeds
│
├── lib/backtest.sh (Backtesting)
│   └── lib/backtest_engine.py
│
├── lib/alpaca_broker.sh OR lib/robinhood_broker.sh
│   ├── Order execution
│   └── Account management
│
├── lib/html_report.sh (Report Generation)
│
└── backend/server.js + frontend/ (Dashboard)
    ├── React/TypeScript UI
    ├── Recharts for visualization
    └── Tailwind CSS styling
```

---

## Module Structure

### Core Modules

| Module | File | Purpose | Language | Key Functions |
|--------|------|---------|----------|----------------|
| Main Agent | `StockSwingTrader_Agent.sh` | Orchestrates all analysis | Bash | parse_args, run_analysis, main |
| Indicators | `lib/indicators.sh` | Technical analysis | Bash | calc_rsi, calc_macd, calc_bollinger, calc_atr |
| Kalman Filter | `lib/kalman_filter.sh` | Price smoothing | Bash | apply_kalman_filter, kalman_init |
| Kalman Inference | `lib/kalman_inference.py` | Kalman computations | Python | filter_prices, estimate_volatility |
| Regime Detector | `lib/regime_detector.sh` | Market condition detection | Bash | detect_regime, classify_market |
| Regime Weighting | `lib/regime_weighting.sh` | Adaptive strategy weights | Bash | get_regime_weights, apply_weights |
| ML Predictor | `lib/ml_predictor.sh` | XGBoost predictions | Bash | ml_predict_direction |
| ML Inference | `lib/ml_inference.py` | Model inference logic | Python | predict, load_model, feature_engineering |
| ML Training | `lib/train_ml_model.py` | Model training pipeline | Python | train, validate, save_model |
| Mean Reversion | `lib/strategy_mean_reversion.sh` | MR strategy signals | Bash | mr_signals, mr_score |
| Trend Following | `lib/strategy_trend_follow.sh` | TF strategy signals | Bash | tf_signals, tf_score |
| Scoring | `lib/scoring.sh` | Confluence calculation | Bash | calculate_confluence_score |
| Sentiment | `lib/sentiment.sh` | Social/news sentiment | Bash | get_sentiment_score |
| Risk Management | `lib/risk_management.sh` | Stop-loss & profit targets | Bash | calculate_stops, calculate_targets |
| Backtesting | `lib/backtest.sh` | Backtest framework | Bash | run_backtest |
| Backtest Engine | `lib/backtest_engine.py` | Backtest logic | Python | backtest_strategy, optimize_params |
| Alpaca Broker | `lib/alpaca_broker.sh` | Alpaca integration | Bash | submit_order, get_positions |
| RH Broker | `lib/robinhood_broker.sh` | Robinhood integration | Bash | submit_order, get_positions |
| Reports | `lib/html_report.sh` | HTML reports | Bash | generate_report |
| Backend API | `backend/server.js` | REST API server | Node.js | /api/analysis, /api/watchlist |
| Frontend UI | `frontend/src/` | React dashboard | TypeScript | Dashboard, Analysis, Watchlist |

---

## Data Flow & Pipeline

### Complete Analysis Pipeline

```
Input: Symbol List (e.g., AAPL,MSFT,GOOGL)
   │
   ├─▶ [RATE LIMIT CHECK]
   │   └─ Alpha Vantage: 5 req/min
   │   └─ Finnhub: 60 req/min
   │
   ├─▶ [FETCH PRICE DATA]
   │   ├─ Intraday (5-min candles)
   │   ├─ Daily candles (90 days)
   │   └─ Store in cache
   │
   ├─▶ [KALMAN FILTER]
   │   ├─ Input: Raw price data
   │   ├─ Parameters: q=0.01, r=0.1
   │   └─ Output: Smoothed prices, volatility estimate
   │
   ├─▶ [REGIME DETECTION]
   │   ├─ Input: Smoothed prices (Kalman output)
   │   ├─ Detect: sideways / trending_bull / trending_bear / volatile
   │   └─ Thresholds: ADX > 25 (trending), volatility metrics
   │
   ├─▶ [CALCULATE INDICATORS] (Parallel for all indicators)
   │   ├─ RSI(14), MACD(12,26,9), Bollinger(20,2)
   │   ├─ ATR(14), OBV, Stochastic(14,3,3)
   │   ├─ Williams %R, EMA(20), EMA(50)
   │   └─ Output: JSON with all values
   │
   ├─▶ [STRATEGY SIGNALS]
   │   ├─ Mean Reversion Strategy
   │   │  └─ Scores: Buy (RSI<30, Price<BB_Lower), Sell (RSI>70)
   │   └─ Trend Following Strategy
   │      └─ Scores: Buy (Price>EMA50, MACD>0), Sell (Price<EMA20)
   │
   ├─▶ [SENTIMENT ANALYSIS]
   │   ├─ Twitter/Social: -100 to +100
   │   ├─ StockTwits: Sentiment score
   │   ├─ News: Positive/negative keywords
   │   └─ Combined: Weighted average
   │
   ├─▶ [ML PREDICTION] (if --ml flag)
   │   ├─ Features: RSI, MACD, Bollinger, ATR, Stochastic, EMA(20), EMA(50), Volume
   │   ├─ Model: XGBoost binary classifier (up/down next 5 periods)
   │   ├─ Output: {direction: "up"/"down", confidence: 0-100}
   │   └─ Weight in scoring: 15%
   │
   ├─▶ [REGIME-ADAPTIVE WEIGHTING] (if --regime-adapt flag)
   │   ├─ Sideways regime: 70% MeanReversion + 30% TrendFollow
   │   ├─ Trending regime: 30% MeanReversion + 70% TrendFollow
   │   ├─ Volatile regime: -20% score adjustment, +2% stop-loss
   │   └─ Apply to confluence calculation
   │
   ├─▶ [CONFLUENCE SCORING]
   │   ├─ Formula:
   │   │  └─ Score = (Technical × 0.30) +
   │   │            (ML × 0.15) +
   │   │            (RegimeWeighted × 0.35) +
   │   │            (VolumeTrend × 0.20)
   │   ├─ Technical: 0-100 (confluence of multiple indicators)
   │   ├─ ML: 0-100 (confidence from XGBoost, min=35 for signal)
   │   ├─ Volume/Trend: 0-100 (OBV, volume relative to avg)
   │   └─ Final Score: 0-100
   │
   ├─▶ [RISK MANAGEMENT]
   │   ├─ Calculate stop-loss (based on ATR)
   │   ├─ Calculate profit target (risk/reward ratio 1:2)
   │   └─ Adjust for volatility
   │
   ├─▶ [SIGNAL CLASSIFICATION]
   │   ├─ STRONG BUY: score ≥ 75 + multiple confirmations
   │   ├─ BUY: score ≥ 60 + main trend aligned
   │   ├─ HOLD: 45 ≤ score < 60
   │   ├─ SELL: score < 45
   │   └─ STRONG SELL: score ≤ 25 + multiple warnings
   │
   ├─▶ [SENTIMENT INTEGRATION]
   │   ├─ Adjust score ±5 points based on sentiment
   │   ├─ Sentiment > +50: +5 to score
   │   ├─ Sentiment < -50: -5 to score
   │   └─ Store sentiment breakdown
   │
   ├─▶ [OUTPUT GENERATION]
   │   ├─ JSON: Complete analysis result
   │   ├─ HTML Report: Visual with charts
   │   ├─ CSV: For spreadsheet import
   │   └─ Dashboard: Real-time display
   │
   └─▶ Output: Complete analysis with signals, scores, risk metrics

```

### JSON Output Format

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
      "overbought_level": 70,
      "oversold_level": 30
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
      "position": 0.68,
      "signal": "above_middle"
    },
    "atr": {
      "value": 2.35,
      "stop_loss": 233.10,
      "profit_target": 239.80
    },
    "stochastic": {
      "k": 62.50,
      "d": 58.30,
      "signal": "bullish"
    },
    "ema": {
      "ema_20": 236.40,
      "ema_50": 234.80,
      "signal": "bullish"
    }
  },
  "kalman_filter": {
    "filtered_price": 235.43,
    "state": [235.43, 0.02],
    "covariance": [[1.2, 0.0], [0.0, 0.1]],
    "residuals": 0.02,
    "volatility_estimate": 1.85
  },
  "regime": {
    "current": "trending_bull",
    "adr": 0.68,
    "volatility": "normal",
    "trend_strength": "strong"
  },
  "ml_prediction": {
    "direction": "up",
    "confidence": 78,
    "probability": 0.78,
    "model_version": "xgboost_v2.0",
    "features_used": ["rsi", "macd", "bollinger", "atr", "stochastic", "ema_20", "ema_50", "volume"]
  },
  "strategies": {
    "mean_reversion": {
      "signal": "buy",
      "score": 65,
      "reasoning": "RSI below 40, price above BB lower"
    },
    "trend_following": {
      "signal": "buy",
      "score": 72,
      "reasoning": "Price above EMA50, MACD positive"
    }
  },
  "regime_weights": {
    "mean_reversion_weight": 0.30,
    "trend_follow_weight": 0.70,
    "applied": true
  },
  "sentiment": {
    "overall": 62,
    "twitter": 58,
    "stocktwits": 65,
    "news": 63,
    "signal": "bullish"
  },
  "confluence": {
    "technical_score": 68,
    "ml_score": 78,
    "weighted_score": 72,
    "final_score": 71,
    "components": {
      "technical": 0.30,
      "ml": 0.15,
      "regime_weighted": 0.35,
      "volume_trend": 0.20
    }
  },
  "signal": "BUY",
  "confidence_level": "HIGH",
  "risk_management": {
    "entry_price": 235.45,
    "stop_loss": 233.10,
    "profit_target": 239.80,
    "risk_reward_ratio": 2.0,
    "stop_loss_percent": -0.99,
    "profit_target_percent": 1.85,
    "recommended_position_size": 100
  },
  "watchlist": {
    "on_watchlist": true,
    "days_on_list": 5,
    "previous_signals": ["HOLD", "HOLD", "BUY"],
    "action_items": ["Monitor for breakout"]
  }
}
```

---

## Enhancement Modules

### Enhancement 1: XGBoost ML Predictor

**Purpose:** Binary classification of stock direction for next 5 periods (+5-10% accuracy improvement)

**Files:**
- `lib/ml_predictor.sh` - Bash wrapper for inference
- `lib/ml_inference.py` - Inference engine
- `lib/train_ml_model.py` - Training pipeline
- `lib/models/xgboost_predictor.pkl` - Trained model (binary)

**Features:**
- Input: 8 technical indicators (RSI, MACD, Bollinger, ATR, Stochastic, EMA20, EMA50, Volume)
- Target: Binary classification (up=1, down=0) for next 5 trading periods
- Model: XGBoost with gradient boosting
- Output: Direction, confidence (0-100), probability (0.0-1.0)

**How to Use:**

```bash
# Run inference on a symbol
./lib/ml_predictor.sh AAPL 5

# Expected output:
# {
#   "direction": "up",
#   "confidence": 78,
#   "probability": 0.78,
#   "model_version": "xgboost_v2.0"
# }
```

**How to Enhance:**

1. **Retrain with new symbols:**
   ```bash
   python lib/train_ml_model.py --symbols AAPL,MSFT,GOOGL --train-days 252 --test-days 60
   ```

2. **Adjust hyperparameters** in `lib/train_ml_model.py`:
   - `max_depth`: 3-7 (lower = simpler model, less overfitting)
   - `learning_rate`: 0.01-0.3 (lower = slower training, better generalization)
   - `n_estimators`: 100-500 (more trees = better but slower)
   - `subsample`: 0.6-1.0 (ratio of training instances)

3. **Add more features:**
   - Modify `engineer_features()` in `lib/ml_inference.py`
   - Add features like: Fibonacci levels, Ichimoku, ADX, CMF
   - Retrain model with new feature set

4. **Testing:**
   ```bash
   # Test inference output format
   bash lib/ml_predictor.sh AAPL 5 | jq .
   
   # Verify confidence threshold
   bash lib/ml_predictor.sh AAPL 5 | jq '.confidence >= 60'
   ```

**JSON Schema - Input (Features):**
```json
{
  "symbol": "AAPL",
  "timestamp": "2024-10-30T14:30:00Z",
  "features": {
    "rsi_14": 55.23,
    "macd_diff": 0.23,
    "bb_position": 0.68,
    "atr_14": 2.35,
    "stochastic_k": 62.50,
    "ema_20": 236.40,
    "ema_50": 234.80,
    "volume_sma_ratio": 1.15
  }
}
```

**JSON Schema - Output:**
```json
{
  "symbol": "AAPL",
  "direction": "up|down",
  "confidence": 0-100,
  "probability": 0.0-1.0,
  "model_version": "xgboost_v2.0",
  "training_accuracy": 0.58,
  "features_used": ["rsi_14", "macd_diff", ...],
  "timestamp": "2024-10-30T14:30:00Z"
}
```

---

### Enhancement 2: Regime-Adaptive Weighting

**Purpose:** Dynamically weight trading strategies based on market regime (+3-5% win rate improvement)

**Files:**
- `lib/regime_detector.sh` - Market regime classification
- `lib/regime_weighting.sh` - Apply adaptive weights

**Regimes:**
1. **Sideways:** ADX < 20, low volatility
   - Weights: 70% MeanReversion + 30% TrendFollow
   - Rationale: Mean reversion works better in range-bound markets

2. **Trending (Bullish):** ADX > 25, uptrend
   - Weights: 30% MeanReversion + 70% TrendFollow
   - Rationale: Follow the trend in strong uptrends

3. **Trending (Bearish):** ADX > 25, downtrend
   - Weights: 30% MeanReversion + 70% TrendFollow
   - Rationale: Follow the trend down

4. **Volatile:** High volatility, ADX neutral
   - Adjustment: -20% to overall score
   - Stop-loss adjustment: +2% (wider stops)
   - Rationale: Reduce position sizing in uncertainty

**How to Use:**

```bash
# Detect market regime
source lib/regime_detector.sh
detect_regime "AAPL"

# Expected output:
# {
#   "regime": "trending_bull",
#   "adr": 0.75,
#   "volatility": "normal",
#   "trend_strength": "strong"
# }

# Apply adaptive weights
source lib/regime_weighting.sh
apply_regime_weights "trending_bull" 65 72

# Output: {"weighted_score": 71.4, "mr_weight": 0.30, "tf_weight": 0.70}
```

**How to Enhance:**

1. **Adjust regime thresholds** in `lib/regime_detector.sh`:
   ```bash
   ADX_TRENDING=25        # Adjust trend strength threshold
   ADX_STRONG=40          # Strong trend threshold
   VOLATILITY_THRESHOLD=2.5  # Volatility cutoff
   ```

2. **Modify weight distribution** in `lib/regime_weighting.sh`:
   ```bash
   # Current: sideways = 70/30, trending = 30/70
   # Try: sideways = 75/25, trending = 25/75 (more aggressive)
   ```

3. **Add new regimes:**
   - Add regime classification logic in `detect_regime()`
   - Define new weight distributions
   - Test on historical data

4. **Testing:**
   ```bash
   # Mock market conditions
   bash tests/test_regime_detector.sh
   bash tests/test_regime_weighting.sh
   
   # Verify weight application
   source lib/regime_weighting.sh
   apply_regime_weights "sideways" 60 60  # Should favor MR
   apply_regime_weights "trending_bull" 60 60  # Should favor TF
   ```

**JSON Schema:**
```json
{
  "regime": {
    "current": "trending_bull|trending_bear|sideways|volatile",
    "adr": 0.75,
    "volatility": "normal|high|low",
    "trend_strength": "weak|normal|strong",
    "adx": 32.5,
    "volatility_index": 18.5
  },
  "weights": {
    "mean_reversion_weight": 0.30,
    "trend_follow_weight": 0.70,
    "applied": true,
    "score_adjustment": 0
  }
}
```

---

### Enhancement 3: React Dashboard

**Purpose:** Professional UI for real-time analysis and trade management

**Frontend Stack:**
- React 18+ with TypeScript
- Vite for bundling
- Recharts for data visualization
- Tailwind CSS for styling
- TanStack Query for data fetching

**Backend Stack:**
- Node.js + Express
- RESTful API endpoints
- 5-second polling interval

**Files:**
- `frontend/src/` - React components
- `backend/server.js` - Express API server
- `backend/package.json` - Dependencies

**Pages:**

1. **Dashboard** (`/`)
   - Real-time watchlist with scores
   - Heat map of buy/sell signals
   - Portfolio overview
   - Quick stats (signals count, avg confidence)

2. **Analysis** (`/analysis`)
   - Deep dive into single symbol
   - Full indicator breakdown
   - Historical signals
   - Regime & ML prediction details

3. **TradeHistory** (`/trades`)
   - Past trades with P&L
   - Win rate, Sharpe ratio
   - Filter by date, symbol, outcome

4. **Watchlist** (`/watchlist`)
   - Manage symbol watchlist
   - Add/remove symbols
   - Set alerts (price, score thresholds)

5. **Settings** (`/settings`)
   - Configure polling interval
   - Indicator weights
   - Risk management parameters
   - API credentials

**How to Use:**

```bash
# Start backend server
cd backend && npm install && npm start
# Server runs on http://localhost:3001

# Start frontend (in another terminal)
cd frontend && npm install && npm run dev
# Frontend runs on http://localhost:5173

# Access dashboard at http://localhost:5173
```

**How to Enhance:**

1. **Add new page:**
   ```bash
   # Create component in frontend/src/pages/NewPage.tsx
   # Add route in frontend/src/App.tsx
   # Add API endpoint in backend/server.js
   ```

2. **Add new API endpoint:**
   ```javascript
   // In backend/server.js
   app.get('/api/new-endpoint', async (req, res) => {
     // Call trading system via shell
     // Return JSON response
   });
   ```

3. **Update polling interval:**
   ```typescript
   // In frontend/src/utils/api.ts
   const POLLING_INTERVAL = 5000;  // Change from 5s to desired value
   ```

4. **Add chart visualization:**
   - Use Recharts components
   - Reference existing charts for style consistency
   - Test data flow from backend

**Testing:**
```bash
# Backend API tests
npm test --prefix backend

# Frontend component tests
npm test --prefix frontend

# E2E tests (if configured)
npm run e2e --prefix frontend
```

**JSON Schema - Dashboard API:**
```json
{
  "watchlist": [
    {
      "symbol": "AAPL",
      "price": 235.45,
      "score": 71,
      "signal": "BUY",
      "confidence": "HIGH",
      "timestamp": "2024-10-30T14:30:00Z"
    }
  ],
  "stats": {
    "total_signals": 15,
    "buy_signals": 7,
    "sell_signals": 3,
    "hold_signals": 5,
    "avg_confidence": 72.5
  }
}
```

---

### Enhancement 4: Complete Backtesting Module

**Purpose:** Validate strategies with parameter optimization and performance analysis

**Files:**
- `lib/backtest.sh` - Bash backtesting framework
- `lib/backtest_engine.py` - Python backtesting engine
- Output: `.agents/tasks/backtest_results/` directory

**Features:**
- Train/test split: 80/20 by default
- Grid search optimization for:
  - RSI thresholds: 20-40 (oversold), 60-80 (overbought)
  - Bollinger Band periods: 15-25
  - Stop-loss: 1-3% of ATR
  - Profit target: 1-3x risk
- Performance metrics:
  - Win rate (%)
  - Sharpe ratio
  - Max drawdown
  - Payoff ratio (avg win / avg loss)
  - Profit factor (gross profit / gross loss)
  - Total return (%)

**How to Use:**

```bash
# Run backtest on historical data
./lib/backtest.sh --symbol AAPL --start 2022-01-01 --end 2024-01-01

# Run with parameter optimization
./lib/backtest.sh --symbol AAPL --start 2022-01-01 --end 2024-01-01 --optimize

# Expected output files:
# .agents/tasks/backtest_results/AAPL_backtest_results.json
# .agents/tasks/backtest_results/AAPL_backtest_report.html
# .agents/tasks/backtest_results/AAPL_trades.csv
```

**How to Enhance:**

1. **Add new parameter ranges:**
   ```python
   # In lib/backtest_engine.py
   PARAM_GRID = {
       'rsi_oversold': [20, 25, 30, 35, 40],
       'rsi_overbought': [60, 65, 70, 75, 80],
       'bb_period': [15, 20, 25],
       'stop_loss_pct': [0.01, 0.02, 0.03],
       'profit_target_mult': [1.0, 1.5, 2.0, 2.5, 3.0]
   }
   ```

2. **Add new metrics:**
   ```python
   def calculate_custom_metric(trades):
       """Custom performance metric"""
       return metric_value
   
   results['custom_metric'] = calculate_custom_metric(trades)
   ```

3. **Modify backtest engine:**
   - Change order execution logic
   - Add slippage/commission modeling
   - Implement position sizing rules

4. **Testing:**
   ```bash
   # Test on known historical periods
   ./lib/backtest.sh --symbol AAPL --start 2023-01-01 --end 2023-12-31
   
   # Verify results match manual calculations
   jq . .agents/tasks/backtest_results/AAPL_backtest_results.json
   ```

**Output Schema:**
```json
{
  "symbol": "AAPL",
  "period": {
    "start": "2022-01-01",
    "end": "2024-01-01",
    "days": 730
  },
  "parameters": {
    "rsi_oversold": 30,
    "rsi_overbought": 70,
    "bb_period": 20,
    "stop_loss_pct": 0.02,
    "profit_target_mult": 2.0
  },
  "performance": {
    "total_trades": 45,
    "winning_trades": 28,
    "losing_trades": 17,
    "win_rate": 0.622,
    "avg_win": 245.50,
    "avg_loss": -152.30,
    "profit_factor": 1.85,
    "payoff_ratio": 1.61,
    "sharpe_ratio": 1.42,
    "max_drawdown": -0.157,
    "total_return_pct": 24.5,
    "annual_return_pct": 11.2
  },
  "optimization": {
    "best_parameters": {...},
    "optimization_iterations": 125,
    "best_sharpe": 1.68
  }
}
```

---

### Enhancement 5: Kalman Filter

**Purpose:** Smooth price data to reduce false signals and estimate volatility

**Files:**
- `lib/kalman_filter.sh` - Bash wrapper
- `lib/kalman_inference.py` - Kalman filter implementation

**Parameters:**
- `q` (process noise): 0.01 (lower = smoother but slower to react)
- `r` (measurement noise): 0.1 (lower = trusts observed price more)
- Output: Filtered prices, state estimate, covariance, residuals, volatility

**How to Use:**

```bash
# Apply Kalman filter to price data
source lib/kalman_filter.sh
apply_kalman_filter "AAPL" "prices.json"

# Expected output:
# {
#   "filtered_prices": [234.10, 234.15, 234.25, ...],
#   "state": [235.43, 0.02],
#   "covariance": [[1.2, 0.0], [0.0, 0.1]],
#   "residuals": 0.02,
#   "volatility_estimate": 1.85
# }
```

**How to Enhance:**

1. **Tune parameters for different market conditions:**
   ```bash
   # High volatility markets: increase q, decrease r
   q=0.05  # More responsive to price changes
   r=0.05  # Trust observed prices more
   
   # Stable markets: decrease q, increase r
   q=0.005  # Smoother filtering
   r=0.2    # Less sensitive to noise
   ```

2. **Add multi-scale Kalman (multi-timeframe):**
   - Apply separate Kalman filters for 5-min and daily candles
   - Compare smoothed price trends across timeframes
   - Improve signal confidence

3. **Implement adaptive Kalman:**
   - Adjust q/r based on market volatility
   - Higher volatility → increase q (less smoothing)
   - Lower volatility → decrease q (more smoothing)

4. **Testing:**
   ```bash
   # Test on noisy data
   python lib/kalman_inference.py test --noise 2.0
   
   # Measure whipsaw reduction
   # Compare signals before/after Kalman filtering
   ```

**JSON Schema:**
```json
{
  "kalman_filter": {
    "parameters": {
      "q": 0.01,
      "r": 0.1
    },
    "prices": {
      "raw": [234.10, 234.50, 233.90, 235.20],
      "filtered": [234.12, 234.35, 234.10, 234.80]
    },
    "state": [235.43, 0.02],
    "covariance": [[1.2, 0.0], [0.0, 0.1]],
    "residuals": 0.02,
    "volatility_estimate": 1.85
  }
}
```

---

## Scoring Pipeline Integration

### Confluence Score Calculation

```
Final Score = (Technical × 0.30) + (ML × 0.15) + (RegimeWeighted × 0.35) + (VolumeTrend × 0.20)

Where:
  Technical Score (0-100):
    - Confluence of RSI, MACD, Bollinger, Stochastic signals
    - Example: 3 out of 4 indicators bullish = 75 points
  
  ML Score (0-100):
    - XGBoost confidence (0-100)
    - Minimum 35 to generate signal
  
  Regime-Weighted Score (0-100):
    - Base scores from Mean Reversion & Trend Following strategies
    - Weighted by detected market regime
    - Sideways: 70% MR + 30% TF
    - Trending: 30% MR + 70% TF
  
  Volume/Trend Score (0-100):
    - OBV trend confirmation
    - Volume relative to 20-day average
    - EMA crossovers (20/50)

Regime Adjustments:
  - Volatile: -20 to final score, +2% to stop-loss
  - Strong trend: +5 to confidence if aligned
```

### Main Agent Flags

```bash
# Basic analysis (technical + sentiment)
./StockSwingTrader_Agent.sh --symbols AAPL,MSFT

# Add ML predictions (15% weight)
./StockSwingTrader_Agent.sh --symbols AAPL,MSFT --ml

# Add regime-adaptive weighting (35% weight)
./StockSwingTrader_Agent.sh --symbols AAPL,MSFT --regime-adapt

# Add Kalman filter for smoothing
./StockSwingTrader_Agent.sh --symbols AAPL,MSFT --kalman

# Run backtesting
./StockSwingTrader_Agent.sh --backtest AAPL 2022-01-01 2024-01-01

# Start dashboard
./StockSwingTrader_Agent.sh --dashboard

# Enable ALL enhancements
./StockSwingTrader_Agent.sh --symbols AAPL,MSFT --full
```

---

## Development Guidelines

### Code Style & Conventions

1. **Bash Scripts:**
   - Use `#!/bin/bash` shebang
   - Set `set -o pipefail` at top
   - Use `UPPERCASE` for constants/globals
   - Use `lowercase_with_underscores` for functions/variables
   - Document functions with comment block:
     ```bash
     ##############################################################################
     # Function: my_function
     # Description: What this does
     # Arguments: $1 - arg1 description, $2 - arg2 description
     # Returns: JSON object or error message
     # Example: my_function "value" "another"
     ##############################################################################
     ```

2. **Python Scripts:**
   - Follow PEP 8 style guide
   - Type hints for function signatures
   - Docstrings for all functions:
     ```python
     def my_function(arg1: str, arg2: int) -> dict:
         """
         Brief description.
         
         Args:
             arg1: Description
             arg2: Description
         
         Returns:
             dict: Description of return value
         """
     ```

3. **JSON Output:**
   - Always return valid JSON or error JSON
   - Success: `{"data": {...}, "status": "success"}`
   - Error: `{"error": "message", "code": "ERROR_CODE"}`
   - Use ISO 8601 timestamps: `2024-10-30T14:30:00Z`

### Module Development Workflow

1. **Create new module:**
   ```bash
   # Create file in lib/
   touch lib/my_new_module.sh
   chmod +x lib/my_new_module.sh
   
   # Add header documentation
   # Implement functions
   # Add to main agent
   ```

2. **Integration with main agent:**
   ```bash
   # Source the module
   source "$SCRIPT_DIR/lib/my_new_module.sh"
   
   # Add command-line flag
   # Call function in analysis pipeline
   ```

3. **Error handling:**
   - Always check for required files/dependencies
   - Return JSON error format on failure
   - Log errors to LOG_FILE
   - Exit with code 1 on fatal errors

### Performance Targets

- **Latency:** < 5 seconds per symbol for full pipeline
  - Data fetch: < 1s
  - Indicators: < 1s
  - ML prediction: < 0.5s
  - Regime detection: < 0.5s
  - Scoring: < 0.5s
  - Report generation: < 1s

- **Memory:** < 500MB for single symbol analysis
- **Accuracy:** Track prediction accuracy in backtests

### All Modules Must

- [ ] Output valid JSON (success or error format)
- [ ] Have proper error handling
- [ ] Include timeout mechanisms
- [ ] Log to LOG_FILE
- [ ] Have documentation comments
- [ ] Be testable independently
- [ ] Support dry-run/demo mode

---

## Testing Checklist

- [ ] **Unit Tests**
  - Each module tests independently
  - Test success and error paths
  - Mock external API calls
  - Run: `bash tests/test_indicators.sh`

- [ ] **Integration Tests**
  - Full pipeline end-to-end
  - Test with real market data (5-day history)
  - Verify JSON schema compliance
  - Run: `bash tests/test_ml_scoring_integration.sh`

- [ ] **Backtesting Validation**
  - Compare results against known outcomes
  - Verify parameter optimization works
  - Check performance metrics accuracy
  - Run: `./lib/backtest.sh --symbol AAPL --start 2023-01-01 --end 2023-12-31`

- [ ] **Dashboard UI Tests**
  - All pages load without errors
  - 5-second refresh works
  - Data updates in real-time
  - Run: `npm test --prefix frontend`

- [ ] **Performance Benchmarks**
  - Single symbol analysis < 5s
  - Batch analysis (10 symbols) < 30s
  - Dashboard refresh < 1s
  - Run: `time ./StockSwingTrader_Agent.sh --symbols AAPL,MSFT,GOOGL --full`

- [ ] **Deployment Package**
  - All files present in DEPLOYMENT_PACKAGE/
  - Configuration template complete
  - README and guides updated
  - Model files (.pkl) included
  - Run: `bash DEPLOYMENT_PACKAGE/verify.sh`

- [ ] **Data Validation**
  - Price data sanity checks (OHLC relationships)
  - Indicator calculations verified
  - No NaN/Inf values in outputs
  - Edge cases handled (gaps, limit down/up)

---

## Troubleshooting

### Common Issues & Solutions

| Issue | Root Cause | Solution |
|-------|-----------|----------|
| "Model file not found" | ML model not trained | Run `python lib/train_ml_model.py --symbols AAPL` |
| "Rate limit exceeded" | Too many API calls | Add delay between requests or upgrade API tier |
| "Invalid JSON output" | Module error not caught | Check module logs, add proper error handling |
| "Dashboard not loading" | Backend not running | Start backend: `cd backend && npm start` |
| "Score calculation NaN" | Missing indicator value | Check data fetch, verify OHLC validity |
| "Kalman filter divergence" | q/r parameters wrong | Adjust q (process noise) and r (measurement noise) |
| "Regime misclassification" | ADX thresholds too strict | Lower ADX threshold from 25 to 20 |
| "Backtest hangs" | Too many parameter combinations | Reduce parameter ranges or grid size |
| "Wrong broker messages" | Broker not selected | Use `--broker alpaca` or `--broker robinhood` flag |
| "Configuration not loaded" | config.template.sh missing | Create from config.template.sh or config.sh |

### Debug Mode

```bash
# Enable debug logging
export DEBUG_MODE=true
./StockSwingTrader_Agent.sh --symbols AAPL

# Check logs
tail -f logs/trading_$(date +%Y%m%d).log

# Verbose output
set -x
source lib/ml_predictor.sh
ml_predict_direction "AAPL" 5
set +x
```

### Verification Scripts

```bash
# Verify all dependencies
bash DEPLOYMENT_PACKAGE/verify_dependencies.sh

# Test API connectivity
bash tests/test_alpaca_broker.sh

# Validate configuration
bash tests/validate_config.sh

# Check model integrity
python -c "import joblib; m = joblib.load('lib/models/xgboost_predictor.pkl'); print(f'Model loaded: {type(m)}')"
```

---

## Future Enhancement Ideas

### Short-term (1-2 months)

1. **Real-time WebSocket Integration**
   - Replace 5-second polling with WebSocket
   - Live price updates
   - Reduced latency, lower server load
   - Use `ws` package in Node.js backend

2. **Deep Learning Models**
   - LSTM (Long Short-Term Memory) for time series
   - Train on multi-timeframe data
   - Potential +10-15% accuracy improvement
   - Use TensorFlow/PyTorch

3. **Advanced Risk Management**
   - Portfolio-level hedging
   - Correlation tracking across symbols
   - Dynamic position sizing
   - VaR (Value at Risk) calculations

4. **Multi-timeframe Analysis**
   - Analyze 5-min, 15-min, hourly, daily, weekly
   - Confluence across timeframes
   - Filter noise at lower timeframes
   - Higher confidence signals

### Medium-term (2-6 months)

5. **Machine Learning Ensemble**
   - Combine multiple models (XGBoost, LSTM, Random Forest)
   - Weighted voting for final prediction
   - Reduce overfit, improve robustness

6. **Live Broker Integration**
   - Paper trading mode first
   - Auto-execution on signals
   - Position management
   - P&L tracking in real-time

7. **Advanced Backtesting**
   - Walk-forward optimization
   - Monte Carlo simulation
   - Out-of-sample testing
   - Stress testing

8. **Natural Language Processing**
   - Parse earnings transcripts
   - Sector sentiment trends
   - Key phrase extraction
   - Fundamental + technical fusion

### Long-term (6+ months)

9. **Multi-market Support**
   - Crypto (Bitcoin, Ethereum)
   - Forex pairs
   - Futures contracts
   - Options strategies

10. **Reinforcement Learning**
    - Agent learns optimal trading strategy
    - Adapts to market changes
    - Continuous improvement
    - Reward function optimization

11. **Distributed System**
    - Microservices architecture
    - Horizontal scaling
    - Fault tolerance
    - Kubernetes deployment

12. **Advanced Visualization**
    - 3D charts for multi-dimensional data
    - Interactive strategy backtester
    - Heatmaps for correlation
    - Real-time market scanner

### Integration Ideas

- **TradingView API:** Alerts and chart analysis
- **Discord/Slack Bot:** Trade notifications
- **Telegram Notifications:** Mobile alerts
- **Email Reports:** Daily market summaries
- **Google Sheets:** Portfolio sync
- **Plotly Dashboards:** Advanced charting

---

## Deployment & Versioning

### Current Version: v6.3

**What's New:**
- XGBoost ML predictor (Enhancement 1)
- Regime-adaptive weighting (Enhancement 2)
- React dashboard with Vite (Enhancement 3)
- Complete backtesting module (Enhancement 4)
- Kalman filter integration (Enhancement 5)

**Previous Versions:**
- v6.2: Added Robinhood integration
- v6.1: Backend API + Node.js server
- v6.0: Alpaca broker support
- v5.0+: Initial feature set (indicators, sentiment, scoring)

### How to Check Version

```bash
cat VERSION
# Output: 6.3

# Or programmatically
source StockSwingTrader_Agent.sh
echo $VERSION_STRING
```

### Deployment Package Contents

```
DEPLOYMENT_PACKAGE/
├── StockSwingTrader_Agent.sh        (Main executable)
├── config.template.sh                (Configuration template)
├── setup-alpaca.sh                   (Alpaca setup guide)
├── setup-robinhood.sh                (RH setup guide)
├── lib/                              (All modules)
├── backend/                          (API server)
├── frontend/                         (React dashboard)
├── docs/                             (Documentation)
├── tests/                            (Test suite)
└── README.md                         (Quick start)
```

---

## Appendix: File Reference

### Key File Locations

```
StockSwingTrader-v6.3/
│
├── StockSwingTrader_Agent.sh         Main agent (orchestrator)
├── config.template.sh                 Configuration template
│
├── lib/                               Core modules
│   ├── indicators.sh                  Technical indicators
│   ├── kalman_filter.sh              Price smoothing
│   ├── kalman_inference.py           Kalman implementation
│   ├── regime_detector.sh            Market regime detection
│   ├── regime_weighting.sh           Adaptive strategy weights
│   ├── ml_predictor.sh               ML inference wrapper
│   ├── ml_inference.py               ML inference engine
│   ├── train_ml_model.py             ML training pipeline
│   ├── strategy_mean_reversion.sh    MR strategy signals
│   ├── strategy_trend_follow.sh      TF strategy signals
│   ├── scoring.sh                     Confluence scoring
│   ├── sentiment.sh                   Sentiment analysis
│   ├── risk_management.sh             Stop-loss, profit targets
│   ├── backtest.sh                    Backtest framework
│   ├── backtest_engine.py             Backtest engine
│   ├── alpaca_broker.sh               Alpaca integration
│   ├── robinhood_broker.sh            Robinhood integration
│   ├── html_report.sh                 Report generation
│   └── models/                        Trained ML models
│       └── xgboost_predictor.pkl      XGBoost binary classifier
│
├── backend/                          API server (Node.js)
│   ├── server.js                      Express API
│   └── package.json                   Dependencies
│
├── frontend/                         React dashboard
│   ├── src/                           React components
│   ├── vite.config.ts                 Vite configuration
│   └── package.json                   Dependencies
│
├── docs/                             Documentation
│   ├── STEERING_GUIDE.md              This file
│   ├── KALMAN_FILTER_GUIDE.md        Kalman filter details
│   └── ROBINHOOD_SETUP.md            Robinhood setup
│
├── tests/                            Test suite
│   ├── test_ml_scoring_integration.sh Integration tests
│   ├── test_regime_detector.sh       Regime detection tests
│   ├── test_kalman_filter.sh         Kalman filter tests
│   └── ...
│
└── .agents/tasks/                    Output directory
    └── backtest_results/              Backtest outputs
```

---

## Contact & Support

For questions or issues with enhancement modules:

1. **Check logs:** `tail -f logs/trading_$(date +%Y%m%d).log`
2. **Run tests:** `bash tests/test_[module_name].sh`
3. **Enable debug:** `export DEBUG_MODE=true`
4. **Review documentation:** Check docs/ directory
5. **Check GitHub issues:** Stock of errors and solutions

---

**Document Last Updated:** October 30, 2024  
**For:** StockSwingTrader v6.3  
**Created for:** Future AI enhancement and maintenance

