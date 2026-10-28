# StockSwingTrader Agent - Technical Design Document

**Version:** 1.0  
**Date:** 2025-01-10  
**Status:** Final Design  
**Scope:** Swing trade analysis agent for US equities (2-5 day holds)

---

## Executive Summary

The StockSwingTrader agent is a standalone shell script that performs real-time technical and sentiment analysis on US equities to identify swing trading opportunities with 2-5 day hold windows. The agent analyzes the top 10 opportunities daily, synthesizes data from multiple free-tier APIs, calculates 10+ technical indicators, aggregates social sentiment, and generates an HTML report with buy/sell signals and 0-100 confidence scores. The system operates in learning/demo mode with no live trading execution, emphasizing data integrity through live-only fetching with no caching and robust error handling for rate limits.

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    StockSwingTrader Agent                        │
│                      (Main Shell Script)                         │
└────────────┬────────────────────────────────────────────────────┘
             │
    ┌────────┴────────┬──────────────┬──────────────┬──────────────┐
    │                 │              │              │              │
    v                 v              v              v              v
┌──────────┐    ┌──────────┐   ┌─────────┐   ┌──────────┐   ┌─────────┐
│  Stock   │    │   Data   │   │ Tech    │   │Sentiment │   │  HTML   │
│Screening │    │Aggregation   │Indicator │   │Analysis  │   │ Report  │
│Workflow  │    │Pipeline  │   │Engine   │   │Engine    │   │ Generator
└────┬─────┘    └────┬─────┘   └────┬────┘   └────┬─────┘   └────┬────┘
     │               │             │              │             │
     │               │             │              │             │
    API Calls   Market Data    Calculations   Social APIs   Template
     ├─Yahoo        ├─OHLCV      ├─RSI          ├─Twitter/X    Rendering
     ├─Alpha        ├─Volume     ├─MACD         ├─StockTwits
     │ Vantage      ├─TA Lib     ├─Bollinger    ├─Reddit
     ├─Finnhub      │(locally)   ├─MA (SMA/EMA) ├─News API
     └─NewsAPI      └─Intraday   ├─ATR          └─Finnhub
                                  ├─OBV              Sentiment
                                  ├─Stochastic
                                  ├─Williams %R
                                  ├─Supertrend
                                  └─VWAP
```

### Core Components

1. **Stock Screening Workflow** — Identify candidates across US equities, filter for swing-trade potential
2. **Data Aggregation Pipeline** — Real-time fetch from multiple sources with live-only policy
3. **Technical Indicator Engine** — Calculate 10+ indicators with TA-Lib for accuracy
4. **Sentiment Analysis Engine** — Aggregate fundamental, technical, and social signals into scores
5. **Confidence Scoring** — Confluence-based algorithm combining all signals
6. **HTML Report Generator** — Render findings with charts, tables, and actionable signals

---

## 2. API Selection & Integration Strategy

### 2.1 Market Data APIs (Free Tier Prioritized)

| API | Tier | Rate Limit | Use Case | Cost | Priority |
|-----|------|-----------|----------|------|----------|
| **Yahoo Finance** (yfinance Python module) | Free | ~2000 req/hr | OHLCV, Volume, Basic TA | Free | PRIMARY |
| **Alpha Vantage** | Free | 5 req/min | Intraday OHLC, Volume profile | Free | PRIMARY |
| **Finnhub** | Free | 60 req/min | Stock fundamentals, Earnings, News sentiment | Free | PRIMARY |
| **AV News API** | Free | 500 req/day | Market news aggregation | Free | SECONDARY |
| **Twelve Data** | Free | 800 req/day | Alternative OHLCV, splits/dividends | Free | SECONDARY |
| **Alpaca Data API** | Free (limited) | Varies | Market data for brokers | Free | FALLBACK |

### 2.2 Sentiment Data APIs (Free/Freemium)

| Source | Method | Rate Limit | Sentiment Type | Cost |
|--------|--------|-----------|-----------------|------|
| **Twitter/X API** | v2 (Bearer token) | 450K/month (free tier) | Real-time mentions, trends | Free |
| **StockTwits** | Web scrape / API | Reasonable | Retail sentiment, bullish/bearish | Free |
| **Reddit** | PRAW library + OAuth | Rate-limited | Subreddit discussion (r/stocks, r/investing, r/stockmarket, r/options) | Free |
| **Finnhub** | Sentiment endpoint | 60 req/min | News sentiment analysis | Free |
| **NewsAPI** | Free tier | 500 req/day | General news sentiment | Free |
| **MarketWatch** | Web scrape | N/A | Headlines, analyst ratings | Free |

### 2.3 Rate Limit Strategy

**Problem:** Multiple free-tier APIs = rate limit conflicts during high-volume requests.  
**Solution:** Staggered request queuing with per-API rate limiters and exponential backoff.

```bash
# Pseudo-logic for rate limiting:
YAHOO_QUEUE=()      # Max 2000/hr = ~1 req/1.8 sec
ALPHA_QUEUE=()      # 5 req/min = 1 req/12 sec
FINNHUB_QUEUE=()    # 60 req/min = 1 req/sec
TWITTER_QUEUE=()    # 450k/month = ~240 req/day during market hours

# Requests batched and serialized with wait times between APIs
```

**Error Handling:**
- 429 (Rate Limited) → exponential backoff (1s, 2s, 4s, 8s) up to 5 retries
- 503 (Service Unavailable) → mark API as temporarily down, skip for 5 minutes
- 401 (Unauthorized) → log critical error, skip this API
- Timeout (>30s) → abort request, mark API state, continue with other sources

---

## 3. Data Pipeline Architecture

### 3.1 Pipeline Flow

```
START (daily cron or manual trigger)
  │
  ├─→ [INIT] Load config (API keys, symbols, parameters)
  │
  ├─→ [SCREEN] Identify US stock candidates (top 100 by volume + screener)
  │    └─ Query: High volume, liquid, price $3-$500, volatility 15-100%
  │
  ├─→ [FETCH] Real-time data collection (parallel, rate-limited)
  │    ├─ Yahoo Finance: OHLCV for 200-day history + today's intraday
  │    ├─ Alpha Vantage: Intraday 5-min/15-min bars for momentum
  │    ├─ Finnhub: Company fundamentals, earnings surprises
  │    ├─ Twitter/X: Trending symbols in trading context
  │    ├─ StockTwits: Sentiment aggregate (% bullish/bearish)
  │    ├─ Reddit: Post volume, sentiment keywords in r/stocks et al.
  │    └─ NewsAPI: Latest news (past 24h) with source sentiment
  │
  ├─→ [PARSE] Data normalization & validation
  │    ├─ Check timestamps (UTC alignment)
  │    ├─ Validate OHLCV ranges (H >= O,C,L; L <= all)
  │    ├─ Deduplicate sentiment from multiple sources
  │    └─ Reject data if too stale (>5 min for intraday, >1 day for eod)
  │
  ├─→ [ANALYZE] Technical & sentiment calculation
  │    ├─ Compute 10+ technical indicators (TA-Lib)
  │    ├─ Generate buy/sell signals per indicator
  │    ├─ Aggregate sentiment from social + news + fundamentals
  │    └─ Calculate risk parameters (volatility, support/resistance)
  │
  ├─→ [SCORE] Confluence scoring & ranking
  │    ├─ Weight technical signals (40%)
  │    ├─ Weight sentiment signals (30%)
  │    ├─ Weight risk/reward metrics (30%)
  │    └─ Output 0-100 confidence per stock
  │
  ├─→ [RANK] Sort candidates, select top 10
  │    └─ Output: [SYMBOL, SIGNAL, CONFIDENCE, ENTRY, TARGET, STOPLOSS]
  │
  ├─→ [REPORT] Generate HTML report
  │    ├─ Summary dashboard (top 10 picks)
  │    ├─ Per-stock detail pages with charts
  │    ├─ Risk disclosures (learning mode, no trading)
  │    └─ Timestamp & data freshness indicators
  │
  └─→ END (output JSON + HTML, no API calls after this)

```

### 3.2 Data Freshness Rules

- **Real-time intraday data:** Must be < 5 minutes old (reject if > 10 min)
- **OHLCV bars (5-min):** Must be from current or previous day
- **EOD data:** Can be up to 1 day old (use prior close if today's close unavailable)
- **Sentiment:** Cache social sentiment for 4 hours (batch retrieval)
- **Fundamentals:** Cache for 24 hours (earnings, PE ratios don't change intraday)
- **News:** Fetch last 24 hours only; update every 2 hours during market hours

### 3.3 Data Validation Rules

| Data Type | Validation Rule | Action if Invalid |
|-----------|-----------------|-------------------|
| OHLCV | H ≥ max(O,C,L); L ≤ min(O,C,L); all > 0 | Flag stock, skip from analysis |
| Volume | V > 0 and V < max_reasonable | Flag if V=0; cap outliers at 99th percentile |
| Sentiment Score | -100 to +100 | Clamp to range; log if out of bounds |
| Timestamp | ISO 8601, within market hours | Reject if > 5 min stale |
| Price | Consistency check (no gaps > 10% intrabar) | Flag as potentially bad fill, use alert |

---

## 4. Technical Indicator Engine

### 4.1 Indicator Stack (TA-Lib Preferred)

All indicators calculated using **TA-Lib** (Python wrapper around C library) for speed and accuracy. Use 200-bar history for all moving average-based indicators.

| Indicator | Purpose | Calculation | Signal Threshold |
|-----------|---------|-------------|------------------|
| **RSI (14)** | Momentum, overbought/oversold | RSI = 100 - (100/(1+RS)), RS = avg_up/avg_down | BUY: <30; SELL: >70 |
| **MACD** | Trend + momentum | EMA12 - EMA26; Signal = EMA9(MACD); Histogram = MACD - Signal | BUY: MACD > Signal & positive histogram; SELL: opposite |
| **Bollinger Bands (20, 2)** | Volatility, mean reversion | Mid = SMA20; Upper = Mid + 2σ; Lower = Mid - 2σ | BUY: Price < Lower; SELL: Price > Upper |
| **SMA (50, 200)** | Trend confirmation | Simple average of last N periods | BUY: SMA50 > SMA200 (golden cross); SELL: opposite |
| **EMA (12, 26)** | Fast/slow trend | Exponential moving average (α = 2/(N+1)) | BUY: EMA12 > EMA26; SELL: opposite |
| **ATR (14)** | Volatility quantification | TR = max(H-L, abs(H-C_prev), abs(L-C_prev)); ATR = SMA14(TR) | % Stop-loss = 1.5x ATR / Current Price |
| **OBV** | Volume momentum | OBV += V if C > C_prev; OBV -= V if C < C_prev | BUY: OBV rising above SMA20(OBV); SELL: falling below |
| **Stochastic (14, 3, 3)** | Momentum oscillator | %K = 100 * (C - L14) / (H14 - L14); %D = SMA3(%K) | BUY: %K < 20 (oversold); SELL: %K > 80 (overbought) |
| **Williams %R (14)** | Momentum (similar to Stochastic) | %R = -100 * (H14 - C) / (H14 - L14) | BUY: %R < -80; SELL: %R > -20 |
| **Supertrend (10, 3)** | Trend following + support/resistance | Uses HL/2 + ATR bands | BUY: Price > Supertrend; SELL: Price < Supertrend |
| **VWAP** | Volume-weighted average (intraday) | VWAP = Σ(Price × Volume) / Σ(Volume) | BUY: Price < VWAP (reversion); SELL: Price > VWAP significantly |

### 4.2 Indicator Signal Generation

Each indicator produces a **signal code**:
- **+1** = Strong BUY
- **+0.5** = Weak BUY
- **0** = NEUTRAL
- **-0.5** = Weak SELL
- **-1** = Strong SELL

**Examples:**
- RSI < 30 → +1 (strong BUY)
- RSI 30-40 → +0.5 (weak BUY)
- RSI 40-60 → 0 (neutral)
- RSI 60-70 → -0.5 (weak SELL)
- RSI > 70 → -1 (strong SELL)

### 4.3 Implementation Details

```bash
# Pseudo-code in shell (actual calculations in Python subprocess)
calculate_indicators() {
    local symbol=$1
    local ohlcv_data=$2  # JSON array
    
    python3 <<EOF
import talib
import json
import numpy as np

# Parse OHLCV data
data = json.loads('$ohlcv_data')
close = np.array(data['close'])
high = np.array(data['high'])
low = np.array(data['low'])
volume = np.array(data['volume'])

indicators = {}

# RSI(14)
indicators['rsi'] = talib.RSI(close, timeperiod=14)[-1]

# MACD
macd, signal, hist = talib.MACD(close, fastperiod=12, slowperiod=26, signalperiod=9)
indicators['macd'] = {
    'macd': macd[-1],
    'signal': signal[-1],
    'histogram': hist[-1]
}

# Bollinger Bands (20, 2)
upper, middle, lower = talib.BBANDS(close, timeperiod=20, nbdevup=2, nbdevdn=2)
indicators['bbands'] = {
    'upper': upper[-1],
    'middle': middle[-1],
    'lower': lower[-1]
}

# SMA(50, 200)
indicators['sma50'] = talib.SMA(close, timeperiod=50)[-1]
indicators['sma200'] = talib.SMA(close, timeperiod=200)[-1]

# ... (similar for EMA, ATR, OBV, Stochastic, Williams %R, Supertrend, VWAP)

print(json.dumps(indicators))
EOF
}
```

---

## 5. Sentiment Analysis Engine

### 5.1 Sentiment Data Sources & Weights

| Source | Weight | Data Type | Freshness | Collection Method |
|--------|--------|-----------|-----------|-------------------|
| **Technical Indicators** | 30% | Signal consensus | Live | Real-time calculation |
| **Social Media (Twitter/X)** | 15% | Mentions, sentiment tone | 4-hour cache | API v2 (bearer token) |
| **Social Media (StockTwits)** | 10% | % Bullish, conversation volume | 4-hour cache | Web scrape or API |
| **Social Media (Reddit)** | 10% | Post sentiment, upvote ratio | 4-hour cache | PRAW library (OAuth) |
| **News Sentiment** | 15% | Headline tone, analyst action | Live | NewsAPI + Finnhub Sentiment |
| **Fundamentals** | 10% | Earnings surprise, PE ratio, growth | 24-hour cache | Finnhub API |
| **Volume/Liquidity** | 10% | Relative volume, bid-ask spread | Live | Market data APIs |

### 5.2 Sentiment Scoring Methodology

Each source produces a **normalized sentiment score** (-100 to +100):

```
Social Sentiment Score:
  ┌─ Twitter/X:
  │  ├─ Search: symbol + ("buy" OR "bullish" OR "long")
  │  ├─ Count positive vs negative mentions
  │  ├─ Score = (positive_pct - negative_pct) * 100
  │  └─ Weight: 15% of social score
  │
  ├─ StockTwits:
  │  ├─ Fetch % bullish for symbol
  │  ├─ Score = (bullish_pct - bearish_pct) * 100
  │  └─ Weight: 10% of social score
  │
  └─ Reddit:
     ├─ Search r/stocks, r/investing, r/stockmarket, r/options
     ├─ NLP sentiment on posts + upvote momentum
     ├─ Score = avg_sentiment_of_posts * upvote_ratio
     └─ Weight: 10% of social score

Fundamental Sentiment Score:
  ├─ Earnings Surprise: (actual - estimate) / estimate → score -100 to +100
  ├─ PE Ratio vs sector: If PE < sector median → +25, else -25
  ├─ Growth rate (YoY): If growth > sector median → +25, else -25
  └─ Score = avg(earnings, pe, growth)

News Sentiment Score:
  ├─ Finnhub sentiment API: positive/negative/neutral counts
  ├─ Score = (positive_count - negative_count) / total_count * 100
  ├─ Weight recent news (last 24h = 100%, yesterday = 50%)
  └─ Final = weighted_avg(all news items)
```

### 5.3 Aggregated Sentiment Formula

```
SENTIMENT_SCORE = 
    0.30 * TECHNICAL_SIGNAL_SCORE +
    0.15 * TWITTER_SCORE +
    0.10 * STOCKTWITS_SCORE +
    0.10 * REDDIT_SCORE +
    0.15 * NEWS_SENTIMENT_SCORE +
    0.10 * FUNDAMENTAL_SCORE +
    0.10 * VOLUME_MOMENTUM_SCORE

Result: -100 (very bearish) to +100 (very bullish)

Category Mapping:
  ≥ +70: STRONG BUY
  +40 to +70: BUY
  -40 to +40: NEUTRAL
  -70 to -40: SELL
  ≤ -70: STRONG SELL
```

### 5.4 Implementation Strategy

```bash
# Sentiment aggregation pseudocode
aggregate_sentiment() {
    local symbol=$1
    
    # Parallel collection to reduce latency
    social_score=$(fetch_twitter_sentiment "$symbol" & \
                   fetch_stocktwits_sentiment "$symbol" & \
                   fetch_reddit_sentiment "$symbol" &) \
                   | awk '{print ($1 + $2 + $3) / 3}'
    
    news_score=$(fetch_finnhub_sentiment "$symbol")
    fundamental_score=$(fetch_fundamental_sentiment "$symbol")
    
    # Weighted aggregation
    final_sentiment=$( \
        echo "scale=2; 0.30*${technical_score} + 0.35*${social_score} + \
              0.15*${news_score} + 0.20*${fundamental_score}" | bc)
    
    echo "$final_sentiment"
}
```

---

## 6. Confidence Scoring Algorithm

### 6.1 Confluence-Based Scoring

Confidence score (0-100) reflects agreement across multiple signal categories:

```
CONFIDENCE_SCORE = Base_Score × Confluence_Multiplier × Risk_Adjustment

Where:

Base_Score (60 points max):
  ├─ Technical Indicator Consensus (30 pts)
  │  └─ Score = (count_of_bullish_signals / total_indicators) * 30
  │     Example: 7 out of 10 indicators bullish = 21 pts
  │
  ├─ Sentiment Agreement (20 pts)
  │  └─ If SENTIMENT_SCORE > +40: +20 pts
  │     If SENTIMENT_SCORE 0 to +40: +10 pts
  │     If SENTIMENT_SCORE -40 to 0: +5 pts
  │     If SENTIMENT_SCORE < -40: +0 pts
  │
  └─ Trend Confirmation (10 pts)
     └─ If SMA50 > SMA200 (uptrend): +10 pts
        Else if SMA50 < SMA200 (downtrend): +0 pts
        Else (consolidation): +5 pts

Confluence_Multiplier (0.8 to 1.3):
  ├─ If multiple signal categories agree (tech + sentiment + trend):
  │  └─ Multiplier = 1.3 (strong confluence)
  ├─ If two categories agree:
  │  └─ Multiplier = 1.0 (normal)
  └─ If categories conflict:
     └─ Multiplier = 0.8 (weak confluence, reduce confidence)

Risk_Adjustment (0.7 to 1.0):
  ├─ Stock volatility > 60%: adjustment = 0.7 (risky)
  ├─ Stock volatility 30-60%: adjustment = 0.85 (moderate)
  ├─ Stock volatility < 30%: adjustment = 1.0 (stable)
  └─ If RSI > 80 or RSI < 20: additional × 0.85 (overextended)

Final_Confidence = min(100, max(0, CONFIDENCE_SCORE))
```

### 6.2 Signal Classification

```
SIGNAL = 
  IF Base_Score ≥ 45 AND Confluence_Multiplier ≥ 1.0: "STRONG_BUY"
  ELSE IF Base_Score ≥ 35 AND Confluence_Multiplier ≥ 0.9: "BUY"
  ELSE IF Base_Score ≥ 20 AND Base_Score < 40: "ACCUMULATE"
  ELSE IF Base_Score ≥ 10 AND Base_Score < 20: "HOLD"
  ELSE IF Base_Score < 10: "SELL"
  
  Additionally:
  IF SENTIMENT_SCORE < -60 AND confidence ≥ 50: "STRONG_SELL"
  IF SENTIMENT_SCORE < -40 AND confidence ≥ 40: "SELL"
```

### 6.3 Entry & Target Calculation

```
ENTRY_PRICE = Current_Price
  └─ Adjusted for intraday momentum:
     If Stochastic < 30 (oversold): Entry = Current - 0.5 * ATR
     If Stochastic > 70 (overbought): Entry = Current (wait for pullback)
     Else: Entry = Current

TARGET_PRICE = Entry + (2 × Risk)
  ├─ Risk = Entry × Volatility_Ratio × 0.02  (2% of entry)
  └─ Volatility_Ratio = (ATR / Current_Price)
     Example: ATR=2, Price=100 → Risk = 100 × 0.02 × 0.02 = $0.04 (doesn't apply; use ATR directly)
  
  Better formula:
  TARGET_PRICE = Entry + (2.0 × ATR)  [Risk = ATR, Reward = 2×ATR, 1:2 RR]

STOPLOSS = Entry - (1.5 × ATR)  [5% nominal on $100 stock]
  └─ Example: Entry $100, ATR $3 → Stop = $95.50 (1.5% loss)
  └─ Absolute max: Entry × 0.95 (hard 5% limit per requirements)
```

### 6.4 Example Scoring Breakdown

```
Symbol: AAPL
Current Price: $185.50
ATR: $3.20
Volatility: 18%

Technical Signals:
  ├─ RSI(14): 42 → Neutral (0 pts)
  ├─ MACD: Bullish crossover → +1
  ├─ Bollinger Bands: Price near middle → Neutral (0 pts)
  ├─ SMA: 50 > 200 → +1 (uptrend)
  ├─ Stochastic: 65 → Weak sell (-0.5)
  ├─ OBV: Rising → +1
  ├─ Williams %R: -35 → Neutral (0 pts)
  ├─ Supertrend: Bullish → +1
  ├─ VWAP: Price > VWAP → +1
  └─ EMA: 12 > 26 → +1
  
  Bullish Signals: 7/10 = 70%
  Base Technical Score: 0.70 × 30 = 21 pts

Sentiment: +55 (positive news, moderate social)
  Sentiment Score: 20 pts

Trend: SMA50 (184) > SMA200 (178)
  Trend Score: 10 pts

Base Score: 21 + 20 + 10 = 51 pts

Confluence: Tech + Sentiment + Trend all agree → 1.3x
Confluence-adjusted: 51 × 1.3 = 66.3 pts

Risk Adjustment: 18% volatility (normal) = 1.0x
Final Confidence: min(100, 66.3) = 66

Signal: BUY (confidence 66/100)
Entry: $185.50
Target: $185.50 + (2 × $3.20) = $191.90
Stop-loss: $185.50 - (1.5 × $3.20) = $180.70
Risk/Reward: $4.80 / $6.40 = 1:1.33
```

---

## 7. HTML Report Generation

### 7.1 Report Structure

```
StockSwingTrader_Report_YYYYMMDD.html
├─ Header Section
│  ├─ Title: "Stock Swing Trader Daily Report"
│  ├─ Date/Time of execution
│  ├─ Data freshness indicators
│  └─ Disclaimer (learning/demo mode, not trading advice)
│
├─ Executive Summary
│  ├─ Top 10 picks table:
│  │  ├─ Rank | Symbol | Signal | Confidence | Entry | Target | Stop-Loss | RR Ratio
│  │  ├─ Color coding: Green (BUY), Red (SELL), Gray (NEUTRAL)
│  │  └─ Clickable rows → expand to detail view
│  │
│  └─ Market overview
│     ├─ SPY, QQQ, IWM daily performance
│     └─ Market breadth (advance/decline ratio)
│
├─ Per-Stock Detail Pages (10 max)
│  ├─ Stock header (symbol, price, % change, market cap)
│  │
│  ├─ Technical Analysis Section
│  │  ├─ 4-hour chart (candlestick + moving averages)
│  │  ├─ Indicator panel:
│  │  │  ├─ RSI gauge (0-100)
│  │  │  ├─ MACD histogram
│  │  │  ├─ Stochastic oscillator
│  │  │  ├─ Bollinger Bands (current position)
│  │  │  ├─ Volume analysis
│  │  │  └─ Support/resistance levels
│  │  │
│  │  └─ Signal table:
│  │     ├─ Indicator | Value | Signal | Confidence Weight
│  │     └─ Row coloring by signal strength
│  │
│  ├─ Sentiment Analysis Section
│  │  ├─ Sentiment score gauge (-100 to +100)
│  │  ├─ Source breakdown (pie chart):
│  │  │  ├─ Technical (30%)
│  │  │  ├─ Social (35%)
│  │  │  ├─ News (15%)
│  │  │  └─ Fundamentals (20%)
│  │  │
│  │  ├─ Social Media Sentiment:
│  │  │  ├─ Twitter/X: Latest mentions, trend direction
│  │  │  ├─ StockTwits: % Bullish/Bearish
│  │  │  ├─ Reddit: Post volume, upvote sentiment
│  │  │  └─ News: Top 3 headlines with sentiment labels
│  │  │
│  │  └─ Fundamental data (snapshot):
│  │     ├─ PE Ratio vs sector average
│  │     ├─ Earnings surprise (if recent)
│  │     ├─ Revenue growth (YoY)
│  │     └─ Dividend yield (if applicable)
│  │
│  ├─ Trade Plan Section
│  │  ├─ Recommended Entry Price: $XXX.XX
│  │  ├─ Target Price: $XXX.XX (+X.X%)
│  │  ├─ Stop-Loss: $XXX.XX (-X.X%)
│  │  ├─ Risk/Reward Ratio: 1:X.X
│  │  ├─ Holding Period: 2-5 days
│  │  ├─ Position Size: Suggested allocation (informational)
│  │  └─ Risk Level: Low/Moderate/High
│  │
│  └─ Analysis Timestamp & Data Sources
│     └─ [Last updated: 2025-01-10 14:32:15 UTC]
│        [Data sources: Yahoo Finance (300s), Alpha Vantage (120s), Finnhub (95s), ...]
│
└─ Footer
   ├─ Disclaimer (learning mode, no trading advice, consult advisors)
   ├─ Generated by: StockSwingTrader Agent v1.0
   └─ Next update: [scheduled time]
```

### 7.2 Chart Generation

Use **Chart.js** (JavaScript library, no dependencies) for client-side rendering:

```html
<script src="https://cdn.jsdelivr.net/npm/chart.js@3.9.1/dist/chart.min.js"></script>

<!-- Candlestick chart data embedded in HTML -->
<canvas id="priceChart"></canvas>
<script>
  // Data embedded as JSON from analysis phase
  const chartData = {
    labels: ['09:30', '10:00', '10:30', ...],
    datasets: [
      { label: 'Close', data: [...] },
      { label: 'SMA50', data: [...] },
      { label: 'SMA200', data: [...] }
    ]
  };
  new Chart(document.getElementById('priceChart'), {
    type: 'line',
    data: chartData,
    options: { responsive: true, maintainAspectRatio: true }
  });
</script>
```

### 7.3 Color Coding & Visual Hierarchy

| Element | Green (Bullish) | Red (Bearish) | Gray (Neutral) | Yellow (Alert) |
|---------|-----------------|---------------|---|---|
| Signal Button | STRONG_BUY, BUY | SELL, STRONG_SELL | HOLD, NEUTRAL | ACCUMULATE, oversold/overbought |
| Confidence Badge | ≥70 | ≤30 | 30-70 | N/A |
| Indicator Value | Above signal threshold | Below signal threshold | Within neutral range | Extreme reading |
| Sentiment Gauge | +40 to +100 | -100 to -40 | -40 to +40 | N/A |

---

## 8. Error Handling & Resilience

### 8.1 API Failure Handling

| Failure Type | HTTP Code | Recoverable | Handling |
|--------------|-----------|-------------|----------|
| **Rate Limited** | 429 | Yes | Exponential backoff (1s → 2s → 4s → 8s), max 5 retries |
| **Service Down** | 503 | Yes | Mark API down for 5 min, skip for this run, continue with others |
| **Unauthorized** | 401 | No | Log critical error, skip API, continue |
| **Not Found** | 404 | No | Symbol doesn't exist or delisted; skip stock |
| **Timeout** | SIGALRM / 30s | Yes | Abort request, mark API state, continue (no retry) |
| **DNS Failure** | N/A | Yes | Retry DNS resolution up to 3 times, then skip |
| **SSL/TLS Error** | N/A | No | Log & skip; likely certificate issue or network filter |
| **Bad Response** | 200 (invalid JSON) | No | Log response sample, skip data source |
| **Missing Fields** | 200 (incomplete data) | No | Flag as stale/incomplete, use fallback or skip |

### 8.2 Retry Strategy

```bash
retry_with_backoff() {
    local max_retries=5
    local timeout=30  # seconds
    local backoff=1
    
    for attempt in $(seq 1 $max_retries); do
        if timeout $timeout curl -s "$url" 2>/dev/null; then
            return 0
        else
            local exit_code=$?
            if [[ $exit_code -eq 124 ]]; then
                echo "Timeout on attempt $attempt" >&2
                # Don't retry timeouts, just continue
                return 124
            fi
        fi
        
        if [[ $attempt -lt $max_retries ]]; then
            sleep $backoff
            backoff=$((backoff * 2))
            if [[ $backoff -gt 8 ]]; then
                backoff=8
            fi
        fi
    done
    
    return 1  # All retries exhausted
}
```

### 8.3 Data Validation & Fallback

```bash
validate_and_fallback() {
    local symbol=$1
    local data_source=$2
    
    # Validate OHLCV
    if [[ ! $high -ge $low ]] || [[ ! $close -gt 0 ]]; then
        log_warning "Invalid OHLCV for $symbol from $data_source"
        return 1
    fi
    
    # Check freshness
    local age_minutes=$(( ($(date +%s) - $timestamp) / 60 ))
    if [[ $age_minutes -gt 5 ]]; then
        log_warning "Data too stale ($age_minutes min) for $symbol"
        return 1
    fi
    
    # Fall back to alternate source if primary fails
    if [[ $data_source == "alpha_vantage" ]]; then
        # Try Yahoo Finance as fallback
        fetch_yahoo_data "$symbol"
    fi
}
```

### 8.4 Logging & Diagnostics

```bash
# Log levels: DEBUG, INFO, WARN, ERROR, CRITICAL
log() {
    local level=$1
    shift
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $@" >> $LOG_FILE
    if [[ $level == "ERROR" ]] || [[ $level == "CRITICAL" ]]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $@" >&2
    fi
}

# Diagnostic report
generate_diagnostic_report() {
    cat > diagnostic.json <<EOF
{
  "run_timestamp": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')",
  "stocks_analyzed": $stock_count,
  "stocks_successful": $success_count,
  "api_calls": {
    "yahoo_finance": $yahoo_calls,
    "alpha_vantage": $av_calls,
    "finnhub": $finnhub_calls,
    "twitter": $twitter_calls,
    "stocktwits": $stocktwits_calls,
    "reddit": $reddit_calls
  },
  "api_failures": {
    "429_rate_limited": $count_429,
    "503_unavailable": $count_503,
    "401_unauthorized": $count_401,
    "timeout": $count_timeout
  },
  "execution_time_seconds": $elapsed,
  "data_freshness": {
    "ohlcv_max_age_minutes": $max_age_ohlcv,
    "sentiment_max_age_minutes": $max_age_sentiment
  },
  "top_10_picks": [ ... ]
}
EOF
}
```

---

## 9. Script Structure & Modularity

### 9.1 Directory Layout

```
StockSwingTrader/
├─ StockSwingTrader.sh              # Main script (entry point)
├─ config/
│  ├─ api_keys.conf                 # API keys (sourced, not committed)
│  ├─ default_params.conf            # Symbol lists, indicator params
│  └─ environment.conf               # Paths, logging, output settings
├─ lib/
│  ├─ data_fetcher.sh               # API calls (Yahoo, Alpha, Finnhub, etc.)
│  ├─ indicator_calculator.sh        # TA-Lib wrapper functions
│  ├─ sentiment_analyzer.sh          # Social + News sentiment aggregation
│  ├─ signal_generator.sh            # Buy/sell signal logic
│  ├─ confidence_scorer.sh           # Confluence & confidence calculation
│  ├─ html_generator.sh              # HTML report builder
│  ├─ error_handler.sh               # Retry, logging, fallback logic
│  └─ utilities.sh                   # Common functions (JSON parsing, etc.)
├─ python/
│  ├─ ta_lib_wrapper.py             # TA-Lib calculations (called from shell)
│  ├─ nlp_sentiment.py               # NLP for sentiment from text
│  └─ data_parser.py                 # JSON/CSV parsing helpers
├─ output/
│  ├─ reports/                       # HTML reports (timestamped)
│  ├─ data/                          # JSON cache (not used, live-only)
│  └─ logs/                          # Log files (rotated)
└─ README.md                         # Usage documentation
```

### 9.2 Main Script Flow

```bash
#!/bin/bash
# StockSwingTrader.sh - Main Agent

set -e  # Exit on error
trap cleanup EXIT

# 1. Load configuration
source config/environment.conf
source config/api_keys.conf
source lib/utilities.sh

# 2. Initialize
init_logging
log "INFO" "Starting StockSwingTrader analysis"

# 3. Stock screening
symbols_to_analyze=$(screen_stocks | head -20)  # Get 20, analyze top 10

# 4. Fetch data (parallel)
fetch_market_data "$symbols_to_analyze" &
fetch_sentiment_data "$symbols_to_analyze" &
wait  # Wait for parallel jobs

# 5. Calculate indicators
for symbol in $symbols_to_analyze; do
    calculate_technical_indicators "$symbol"
done

# 6. Aggregate sentiment
for symbol in $symbols_to_analyze; do
    aggregate_sentiment_score "$symbol"
done

# 7. Generate signals & confidence scores
generate_confluence_signals "$symbols_to_analyze"

# 8. Rank top 10 & select
top_10=$(rank_by_confidence | head -10)

# 9. Generate HTML report
generate_html_report "$top_10"

# 10. Output diagnostics
generate_diagnostic_report

log "INFO" "Analysis complete. Report: $OUTPUT_HTML"
echo "Output: $OUTPUT_HTML"
```

### 9.3 Module Interfaces

Each module exports key functions:

**data_fetcher.sh:**
```bash
fetch_yahoo_ohlcv(symbol, period)       # Returns JSON
fetch_alpha_vantage_intraday(symbol)    # Returns JSON
fetch_finnhub_quote(symbol)             # Returns JSON
fetch_news_articles(symbol)             # Returns JSON
fetch_twitter_sentiment(symbol, hours)  # Returns JSON
fetch_stocktwits_sentiment(symbol)      # Returns JSON
fetch_reddit_sentiment(symbol, subreddits)  # Returns JSON
```

**indicator_calculator.sh:**
```bash
calculate_rsi(close_prices, period)     # Returns float
calculate_macd(close_prices)            # Returns JSON {macd, signal, hist}
calculate_bbands(close_prices, period)  # Returns JSON {upper, mid, lower}
calculate_atr(high, low, close, period) # Returns float
# ... etc for all indicators
```

**signal_generator.sh:**
```bash
generate_rsi_signal(rsi_value)          # Returns -1, -0.5, 0, 0.5, or 1
generate_macd_signal(macd, signal, hist)  # Returns signal strength
aggregate_indicator_signals(indicators_obj)  # Returns consensus signal
```

**confidence_scorer.sh:**
```bash
calculate_base_score(tech_signals, sentiment, trend)  # Returns 0-60
calculate_confluence_multiplier(signal_agreement)   # Returns 0.8-1.3
calculate_risk_adjustment(volatility, rsi)  # Returns 0.7-1.0
calculate_final_confidence(base, confluence, risk)  # Returns 0-100
classify_signal(confidence_score)       # Returns signal name
```

---

## 10. Configuration File Format

### 10.1 api_keys.conf (Sourced at runtime, NOT committed to git)

```bash
# API Keys - Load from environment or .conf file
# NEVER commit this file with real keys

export YAHOO_FINANCE_KEY=""              # yfinance doesn't require key
export ALPHA_VANTAGE_KEY="${ALPHA_KEY:-}"  # Free tier: 5 req/min
export FINNHUB_KEY="${FINNHUB_KEY:-}"    # Free tier: 60 req/min
export NEWSAPI_KEY="${NEWSAPI_KEY:-}"    # Free tier: 500 req/day

export TWITTER_API_KEY="${TWITTER_KEY:-}"  # v2 Bearer token
export TWITTER_SECRET="${TWITTER_SECRET:-}"
export REDDIT_CLIENT_ID="${REDDIT_ID:-}"
export REDDIT_CLIENT_SECRET="${REDDIT_SECRET:-}"
export REDDIT_USER_AGENT="StockSwingTrader/1.0"

# Validate keys at startup
validate_api_keys() {
    if [[ -z "$ALPHA_VANTAGE_KEY" ]]; then
        log "WARN" "ALPHA_VANTAGE_KEY not set; Alpha Vantage will be skipped"
    fi
}
```

### 10.2 default_params.conf

```bash
# Stock Screening Parameters
SCREENING_CRITERIA="volume_min:1000000 price_min:3 price_max:500 volatility_min:15"
STOCKS_TO_SCREEN=100       # Top 100 by volume, then filter
TOP_N_STOCKS=10            # Final output: top 10

# Technical Indicator Parameters
RSI_PERIOD=14
RSI_OVERBOUGHT=70
RSI_OVERSOLD=30

MACD_FAST=12
MACD_SLOW=26
MACD_SIGNAL=9

BBANDS_PERIOD=20
BBANDS_STDDEV=2

SMA_SHORT=50
SMA_LONG=200

ATR_PERIOD=14
ATR_MULTIPLIER_STOPLOSS=1.5
ATR_MULTIPLIER_TARGET=2.0

# Sentiment Weights (must sum to 1.0)
WEIGHT_TECHNICAL=0.30
WEIGHT_SOCIAL=0.35
WEIGHT_NEWS=0.15
WEIGHT_FUNDAMENTAL=0.20

# Confidence Thresholds
CONFIDENCE_STRONG_BUY=70
CONFIDENCE_BUY=50
CONFIDENCE_NEUTRAL=40

# Risk Management
MAX_STOP_LOSS_PCT=5          # Hard limit: 5% per requirements
HOLDING_PERIOD_DAYS=5        # Swing trade window
MARKET_HOURS="09:30-16:00"   # EST
```

### 10.3 environment.conf

```bash
# Environment Setup
export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CONFIG_DIR="$SCRIPT_DIR/config"
export LIB_DIR="$SCRIPT_DIR/lib"
export PYTHON_DIR="$SCRIPT_DIR/python"
export OUTPUT_DIR="$SCRIPT_DIR/output"
export LOG_DIR="$OUTPUT_DIR/logs"
export REPORT_DIR="$OUTPUT_DIR/reports"
export DATA_DIR="$OUTPUT_DIR/data"

# Create directories if not exists
mkdir -p "$LOG_DIR" "$REPORT_DIR" "$DATA_DIR"

# Logging
export LOG_FILE="$LOG_DIR/stocktrader_$(date +%Y%m%d).log"
export LOG_LEVEL="INFO"  # DEBUG, INFO, WARN, ERROR
export LOG_MAX_SIZE=10485760  # 10MB

# Execution
export PARALLEL_JOBS=4       # API fetch parallelism
export FETCH_TIMEOUT=30      # seconds per API call
export MARKET_TZ="America/New_York"

# Python environment
export PYTHONPATH="$PYTHON_DIR:$PYTHONPATH"
```

---

## 11. Data Flow Diagrams

### 11.1 Real-Time Data Pipeline

```
[Trigger: Daily 09:30 EDT or Manual]
  │
  ├─→ Parallel fetch workers (max 4):
  │    ├─ Worker 1: Yahoo Finance (2000 req/hr) → rate limit check
  │    ├─ Worker 2: Alpha Vantage (5 req/min) → queue management
  │    ├─ Worker 3: Finnhub (60 req/min) → quota tracking
  │    └─ Worker 4: News + Sentiment (Twitter, Reddit, StockTwits)
  │
  ├─→ Data normalization:
  │    ├─ Parse JSON responses
  │    ├─ Align timestamps (UTC)
  │    ├─ Validate OHLCV
  │    ├─ Check freshness (< 5 min)
  │    └─ Aggregate duplicate records
  │
  ├─→ Python subprocess (TA-Lib):
  │    ├─ Import OHLCV data
  │    ├─ Calculate 10+ indicators
  │    └─ Return JSON with all values
  │
  ├─→ Signal generation:
  │    ├─ Classify each indicator (BUY/SELL/NEUTRAL)
  │    ├─ Weight by confidence
  │    └─ Aggregate into consensus signal
  │
  ├─→ Sentiment aggregation:
  │    ├─ Score social media (-100 to +100)
  │    ├─ Score news sentiment
  │    ├─ Score fundamentals
  │    └─ Weighted average = SENTIMENT_SCORE
  │
  ├─→ Confluence scoring:
  │    ├─ Base score (60 pts max)
  │    ├─ Confluence multiplier (0.8-1.3)
  │    ├─ Risk adjustment (0.7-1.0)
  │    └─ Final confidence (0-100)
  │
  ├─→ Ranking:
  │    ├─ Sort by confidence descending
  │    ├─ Select top 10
  │    └─ Calculate entry/target/stoploss
  │
  └─→ HTML report generation + output
```

### 11.2 Sentiment Score Aggregation

```
Twitter/X                 StockTwits              Reddit
Mention sentiment    +     Bullish %         +    Sentiment
   (↓ to ±100)           (↓ to ±100)             (↓ to ±100)
        │                       │                      │
        └─ Weight: 15% ─────────┴──────────────────────┘
                                  │
                          Social Score (±100)
                                  │
                              Weight: 35%
                                  │
     ┌──────────────────────────────┴──────────────────────────────┐
     │                                                              │
     v                                                              v
News Sentiment (+NewsAPI, +Finnhub)                    Fundamental Sentiment
    ├─ Positive count                                      ├─ Earnings surprise
    ├─ Negative count                                      ├─ PE vs sector
    └─ Score = (pos - neg) / total * 100                  ├─ Growth rate
         Weight: 15%                                       └─ Score = avg
                                                                Weight: 20%
                │                                                │
                └────────────────────────┬────────────────────────┘
                                         │
                    FINAL SENTIMENT = 0.30*Tech + 0.35*Social 
                                    + 0.15*News + 0.20*Fundamental
                    
                    Result: -100 (bearish) to +100 (bullish)
```

---

## 12. Implementation Roadmap

### Phase 1: Foundation (Week 1)
- [x] Design document (this file)
- [ ] Setup project structure & directories
- [ ] Implement error handling framework
- [ ] Build data fetcher module (Yahoo Finance only)
- [ ] Create logging & diagnostic functions
- [ ] Configuration file templates

### Phase 2: Core Analysis (Week 2)
- [ ] Integrate TA-Lib Python wrapper
- [ ] Implement technical indicator calculations (all 10)
- [ ] Build signal generator (indicator consensus)
- [ ] Implement basic HTML report template
- [ ] Integrate Alpha Vantage & Finnhub APIs

### Phase 3: Sentiment & Scoring (Week 3)
- [ ] Integrate Twitter/X API v2
- [ ] Integrate StockTwits & Reddit scrapers
- [ ] Build sentiment aggregation engine
- [ ] Implement confidence scoring algorithm
- [ ] Build news sentiment integration (NewsAPI, Finnhub)

### Phase 4: Polish & Testing (Week 4)
- [ ] Enhanced HTML report with charts (Chart.js)
- [ ] Rate limit handling & retry logic
- [ ] End-to-end testing with sample data
- [ ] Performance optimization
- [ ] Documentation & usage guide
- [ ] Cron job setup for daily runs

### Phase 5: Deployment & Monitoring (Week 5)
- [ ] Containerization (optional Docker)
- [ ] Scheduling (cron / systemd timer)
- [ ] Monitoring & alerting
- [ ] Historical backtesting module (future)
- [ ] ML model integration (future)

---

## 13. Technology Stack

| Component | Technology | Rationale |
|-----------|-----------|-----------|
| **Shell/CLI** | Bash 5+ | Standalone, no Python dependency for main script |
| **Data Fetching** | curl, jq | Lightweight, standard on most systems |
| **Technical Indicators** | TA-Lib (C) + Python wrapper | Industry standard, C performance, Python interface |
| **JSON Processing** | jq, Python json | Cross-platform, robust |
| **Sentiment NLP** | Python VADER / TextBlob | Lightweight, pre-trained for financial sentiment |
| **API Libraries** | PRAW (Reddit), requests (Python), curl | Free, well-documented |
| **HTML Generation** | Bash string templates + Chart.js | No server-side rendering needed, client-side charts |
| **Logging** | Bash functions + text files | Simple, no dependencies |
| **Scheduling** | cron or systemd timer | Standard on Linux/macOS |
| **Testing** | bats (Bash Automated Testing) | Bash-native testing framework |

---

## 14. Edge Cases & Assumptions

### 14.1 Edge Cases

| Edge Case | Handling |
|-----------|----------|
| **Stock delisted or halted** | 404 from API; log & skip; mark in report |
| **After-hours trading** | Use last close price; note in timestamp |
| **Earnings announcement** | High volatility spike; flag in risk adjustment |
| **Stock split** | Adjust historical prices if provided by API |
| **Dividend ex-date** | Noted in fundamental data; no price adjustment needed |
| **Pre-market anomalies** | Only process official market hours (09:30-16:00 EST) |
| **API key rotated** | Graceful degradation; skip that API, continue |
| **No sentiment data available** | Use technical + fundamental only; reduce weight |
| **All indicators bearish** | Confidence score floor at 15 (not zero) |
| **Extreme volatility (>150%)** | Flag as risky; risk adjustment = 0.6 (instead of 0.7-1.0) |
| **Frozen/illiquid stock** | Skip if volume < minimum threshold |
| **Symbol ambiguity** | Use primary ticker (e.g., BRK.B not BRK); verify with market data |

### 14.2 Assumptions

- **Market Hours:** Analysis runs during or after market hours (09:30-16:00 EST)
- **Data Latency:** Accept 5-minute data staleness (best effort, not real-time trading)
- **API Availability:** Assume ≥80% of primary APIs available (not all required)
- **Fundamentals:** Earnings & PE data change daily at most; 24-hour cache acceptable
- **Social Sentiment:** Real-time collection not feasible; 4-hour cache acceptable
- **User Base:** Individual traders, not institutional; learning/demo mode only
- **Regulatory:** No trading execution, no advice offered; disclaimer covers liability
- **Performance:** Acceptable latency ~60 seconds per analysis run for 10 stocks
- **Scale:** Starting with top 100 US equities; can expand to 1000+ with optimization
- **Accuracy:** Indicators calculated per standard definitions (RSI = Wilder's), not proprietary

---

## 15. Success Criteria & Metrics

### 15.1 Functional Success Criteria

- [ ] Daily report generated with top 10 swing trade opportunities
- [ ] All 10 technical indicators calculated & displayed per stock
- [ ] Sentiment scores aggregated from ≥3 sources (social + news + fundamental)
- [ ] Confidence scores 0-100 with transparent calculation breakdown
- [ ] Entry/target/stop-loss prices calculated per ATR + 5% hard limit
- [ ] HTML report renders without JavaScript errors
- [ ] Buy/sell signals match expected technical analysis (manual spot checks)
- [ ] Report updates available within 60 seconds of execution
- [ ] Zero false positive crashes on invalid API responses

### 15.2 Performance Metrics

- **Execution Time:** < 90 seconds for 10-stock analysis
- **API Call Efficiency:** < 30 total API calls per run (batched where possible)
- **Report File Size:** < 5MB (no embedded images, use Chart.js)
- **Rate Limit Hits:** < 5% of runs (well within API quotas)
- **Data Freshness:** 95% of indicators < 5 minutes old
- **Uptime:** 99% successful runs (tolerate 1 failure per 100 runs)

### 15.3 Accuracy Metrics (Post-Launch Learning)

- [ ] Backtesting: Compare historical signals to actual price movements
- [ ] Win Rate: % of BUY signals that move to target within 5 days
- [ ] Correlation: Confidence score vs actual price movement (Pearson r > 0.6)
- [ ] False Positive Rate: % of STRONG_BUY signals that reverse within 1 day

---

## 16. Future Enhancements (Out of Scope for v1.0)

- **ML Models:** LSTM/Transformer for price prediction, trading signal optimization
- **Backtesting Engine:** Historical simulation with metrics (Sharpe ratio, drawdown, etc.)
- **Portfolio Optimization:** Multi-stock position sizing for maximum Sharpe ratio
- **Options Analysis:** Greeks, IV rank, spread recommendations
- **Blockchain/Crypto:** Extend to major cryptocurrencies (BTC, ETH, etc.)
- **Live Trading Integration:** Connect to brokers (Alpaca, TD Ameritrade APIs)
- **Notifications:** Email/Slack alerts for STRONG_BUY or price target hits
- **Web Dashboard:** Real-time visualization of portfolio + signals
- **Collaborative Filtering:** Learn from user feedback (if buy signal led to profit)
- **Regulatory Compliance:** SEC Form 4 insider trading alerts, short squeeze detection

---

## 17. Design Review Responses

**No prior design review conducted; this is the initial design.**

If future reviews raise findings, they will be addressed here per the following template:

> **Finding [N]:** [Description of concern]  
> **Response:** [Accept / Backlog (reason) / Justify (reasoning)]

---

## Appendix: API Reference Summary

### Yahoo Finance (yfinance)
```bash
# Pull OHLCV + volume for symbol, period
curl "https://query1.finance.yahoo.com/v8/finance/chart/$symbol?interval=1d&range=1y"
```

### Alpha Vantage
```bash
# Intraday 5-min bars
https://www.alphavantage.co/query?function=TIME_SERIES_INTRADAY&symbol=$symbol&interval=5min&apikey=$KEY
```

### Finnhub
```bash
# Quote (price, change, etc.)
https://finnhub.io/api/v1/quote?symbol=$symbol&token=$FINNHUB_KEY

# News (last 24h)
https://finnhub.io/api/v1/company-news?symbol=$symbol&from=2025-01-10&to=2025-01-11&token=$KEY

# Sentiment
https://finnhub.io/api/v1/news-sentiment?symbol=$symbol&token=$KEY
```

### Twitter/X API v2
```bash
# Search recent tweets with bearer token
curl -X GET "https://api.twitter.com/2/tweets/search/recent?query=$symbol" \
  -H "Authorization: Bearer $TWITTER_BEARER_TOKEN"
```

### NewsAPI
```bash
# Search news
https://newsapi.org/v2/everything?q=$symbol&sortBy=publishedAt&pageSize=20&apiKey=$NEWSAPI_KEY
```

### VADER Sentiment (Python)
```python
from nltk.sentiment import SentimentIntensityAnalyzer
sia = SentimentIntensityAnalyzer()
score = sia.polarity_scores("Stock XYZ to the moon!")['compound']  # -1 to +1
```

---

**Document Status:** FINAL DESIGN  
**Next Step:** Phase 1 Implementation  
**Review:** Design readiness confirmed by architecture review board  
**Approval:** Ready for development sprint

