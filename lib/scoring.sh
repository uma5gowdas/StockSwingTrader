#!/bin/bash
# ============================================================================
# StockSwingTrader: Confidence Scoring & Confluence Engine
# ============================================================================
# Scores individual indicators (0-100) and calculates multi-source confidence
# Returns buy/sell/hold recommendations with 0-100 confidence scores
#
# ML Predictor Integration (v6.2):
# - 15% weight: ML confidence (XGBoost direction prediction)
# - 35% weight: Regime-adaptive strategy scores
# - 30% weight: Technical indicators (RSI, MACD, Bollinger)
# - 20% weight: Volume/Trend confirmation (OBV + Kalman filtered)
# ============================================================================

# Source integrated modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ml_predictor.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/regime_weighting.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/kalman_filter.sh" 2>/dev/null || true

# ============================================================================
# Score Individual Technical Indicators
# ============================================================================

# Score RSI indicator
# Args: rsi_value (0-100)
# Returns: score (0-100, where 100=strongest buy, 0=strongest sell)
score_rsi() {
    local rsi=$1
    local score=50  # default neutral
    
    if (( $(echo "$rsi > 70" | bc -l) )); then
        # Overbought: potential pullback (sell signal)
        score=$(echo "100 - (($rsi - 70) * 1.5)" | bc)
        if (($(echo "$score < 0" | bc) )); then score=0; fi
    elif (( $(echo "$rsi < 30" | bc -l) )); then
        # Oversold: potential bounce (buy signal)
        score=$(echo "(30 - $rsi) * 1.5" | bc)
        if (($(echo "$score > 100" | bc) )); then score=100; fi
    else
        # Neutral zone 30-70
        # Map 30→40, 50→50, 70→60
        score=$(echo "40 + ($rsi - 30) * 0.33" | bc)
    fi
    
    printf "%.0f" "$score"
}

# Score MACD indicator
# Args: macd_value, signal_value, histogram
# Returns: score (0-100)
score_macd() {
    local macd=$1
    local signal=$2
    local histogram=$3
    
    local score=50
    
    # Positive histogram = bullish
    if (( $(echo "$histogram > 0" | bc -l) )); then
        if (( $(echo "$macd > $signal" | bc -l) )); then
            # MACD above signal and rising = strong buy
            score=$(echo "50 + (($histogram / (0.1 + $histogram)) * 50)" | bc)
        else
            score=60  # bullish but weakening
        fi
    elif (( $(echo "$histogram < 0" | bc -l) )); then
        if (( $(echo "$macd < $signal" | bc -l) )); then
            # MACD below signal and falling = strong sell
            score=$(echo "50 - (((-$histogram) / (0.1 - $histogram)) * 50)" | bc)
            if (($(echo "$score < 0" | bc) )); then score=0; fi
        else
            score=40  # bearish but weakening
        fi
    fi
    
    # Clamp to 0-100
    if (($(echo "$score > 100" | bc) )); then score=100; fi
    if (($(echo "$score < 0" | bc) )); then score=0; fi
    
    printf "%.0f" "$score"
}

# Score Bollinger Bands
# Args: current_price, upper_band, middle_band, lower_band
# Returns: score (0-100)
score_bollinger_bands() {
    local price=$1
    local upper=$2
    local middle=$3
    local lower=$4
    
    local score=50
    local bb_position=0  # 0-1 scale, 0=at lower, 1=at upper
    
    local bandwidth=$(echo "$upper - $lower" | bc -l)
    if (( $(echo "$bandwidth > 0" | bc -l) )); then
        bb_position=$(echo "($price - $lower) / $bandwidth" | bc -l)
    fi
    
    # Price near lower band (< 0.3) = oversold, strong buy
    if (( $(echo "$bb_position < 0.3" | bc -l) )); then
        score=$(echo "100 - ($bb_position * 100)" | bc)
    # Price near upper band (> 0.7) = overbought, sell
    elif (( $(echo "$bb_position > 0.7" | bc -l) )); then
        score=$(echo "100 - (($bb_position - 0.7) * 100)" | bc)
    else
        # Middle zone: neutral to bullish
        score=$(echo "50 + ($bb_position - 0.5) * 20" | bc)
    fi
    
    # Clamp to 0-100
    if (($(echo "$score > 100" | bc) )); then score=100; fi
    if (($(echo "$score < 0" | bc) )); then score=0; fi
    
    printf "%.0f" "$score"
}

# Score Stochastic Oscillator
# Args: k_line (0-100)
# Returns: score (0-100)
score_stochastic() {
    local k_line=$1
    
    local score=50
    
    if (( $(echo "$k_line > 80" | bc -l) )); then
        # Overbought: potential pullback
        score=$(echo "100 - (($k_line - 80) * 2.5)" | bc)
    elif (( $(echo "$k_line < 20" | bc -l) )); then
        # Oversold: potential bounce
        score=$(echo "($k_line) * 2.5" | bc)
    else
        # Neutral zone 20-80
        score=$(echo "25 + ($k_line - 20) * 0.625" | bc)
    fi
    
    # Clamp to 0-100
    if (($(echo "$score > 100" | bc) )); then score=100; fi
    if (($(echo "$score < 0" | bc) )); then score=0; fi
    
    printf "%.0f" "$score"
}

# Score Williams %R
# Args: williams_r_value (-100 to 0)
# Returns: score (0-100)
score_williams_r() {
    local williams_r=$1
    
    # Convert from -100 to 0 scale to 0 to 100 scale
    local score=$(echo "($williams_r + 100)" | bc)
    
    if (($(echo "$score < 0" | bc) )); then score=0; fi
    if (($(echo "$score > 100" | bc) )); then score=100; fi
    
    printf "%.0f" "$score"
}

# Score OBV Trend
# Args: current_obv, previous_obv (from array)
# Returns: score (0-100, 100=strong uptrend, 0=strong downtrend)
score_obv() {
    local current_obv=$1
    local previous_obv=$2
    
    local score=50
    
    if (( $(echo "$current_obv > $previous_obv" | bc -l) )); then
        # Rising OBV = bullish confirmation
        local change_pct=$(echo "(($current_obv - $previous_obv) / ($previous_obv + 1)) * 100" | bc -l)
        score=$(echo "50 + ($change_pct * 0.3)" | bc)
    else
        # Falling OBV = bearish
        local change_pct=$(echo "(($previous_obv - $current_obv) / ($previous_obv + 1)) * 100" | bc -l)
        score=$(echo "50 - ($change_pct * 0.3)" | bc)
    fi
    
    # Clamp to 0-100
    if (($(echo "$score > 100" | bc) )); then score=100; fi
    if (($(echo "$score < 0" | bc) )); then score=0; fi
    
    printf "%.0f" "$score"
}

# ============================================================================
# Confluence Engine: Multi-Source Scoring
# ============================================================================

# Calculate final confidence score from all signals (Legacy - use calculate_confluence_score_v2)
# Args: rsi_score, macd_score, bb_score, stochastic_score, williams_r_score, obv_score, sentiment_score
# Returns: JSON with final_confidence, signal (BUY/SELL/HOLD), reasoning
calculate_confluence_score() {
    local rsi_score=${1:-50}
    local macd_score=${2:-50}
    local bb_score=${3:-50}
    local stoch_score=${4:-50}
    local williams_score=${5:-50}
    local obv_score=${6:-50}
    local sentiment_score=${7:-50}
    
    # Weighted confluence (sentiment is 20% of total, technical is 80%)
    local technical_avg=$(( (rsi_score + macd_score + bb_score + stoch_score + williams_score + obv_score) / 6 ))
    local final_confidence=$(echo "(${technical_avg} * 0.8) + (${sentiment_score} * 0.2)" | bc)
    
    # Determine signal based on confluence thresholds
    local signal="HOLD"
    local reasoning=""
    
    if (( $(echo "$final_confidence >= 75" | bc -l) )); then
        signal="STRONG_BUY"
        reasoning="Multiple indicators aligned bullish; high confidence entry point"
    elif (( $(echo "$final_confidence >= 60" | bc -l) )); then
        signal="BUY"
        reasoning="Most indicators bullish; good entry opportunity"
    elif (( $(echo "$final_confidence >= 40" | bc -l) )); then
        signal="HOLD"
        reasoning="Mixed signals; monitor for clearer direction"
    elif (( $(echo "$final_confidence >= 25" | bc -l) )); then
        signal="SELL"
        reasoning="Most indicators bearish; consider exiting positions"
    else
        signal="STRONG_SELL"
        reasoning="Multiple indicators aligned bearish; high conviction short"
    fi
    
    final_confidence=$(printf "%.0f" "$final_confidence")
    
    echo "{\"final_confidence\":${final_confidence},\"signal\":\"${signal}\",\"reasoning\":\"${reasoning}\",\"technical_avg\":${technical_avg},\"sentiment_contribution\":${sentiment_score}}"
}

# ============================================================================
# ML-Integrated Scoring Pipeline (v6.2)
# ============================================================================

# Calculate composite confidence score with ML predictor integration
# Args:
#   symbol: Stock symbol (e.g., "AAPL")
#   rsi_score: RSI indicator score (0-100)
#   macd_score: MACD indicator score (0-100)
#   bb_score: Bollinger Bands score (0-100)
#   obv_score: On-Balance Volume score (0-100)
#   regime: Market regime (sideways|trending_bull|trending_bear|volatile)
#   [mr_score]: Mean reversion strategy score (0-100, optional)
#   [tf_score]: Trend following strategy score (0-100, optional)
#   [kalman_trend]: Kalman-filtered trend direction (-1|0|1, optional)
#
# Returns: JSON with {
#   "confluence_score": 0-100,
#   "recommendation": "STRONG_BUY"|"BUY"|"HOLD"|"SELL"|"STRONG_SELL",
#   "components": {
#     "ml_confidence": (%, 15 weight),
#     "regime_score": (%, 35 weight),
#     "technical_score": (%, 30 weight),
#     "volume_trend_score": (%, 20 weight)
#   },
#   "signal_strength": 0-5 (# of components in agreement),
#   "breakdown": {...detailed scores...},
#   "timestamp": ISO8601
# }
calculate_confluence_score_v2() {
    local symbol=$1
    local rsi_score=${2:-50}
    local macd_score=${3:-50}
    local bb_score=${4:-50}
    local obv_score=${5:-50}
    local regime=${6:-"sideways"}
    local mr_score=${7:-50}
    local tf_score=${8:-50}
    local kalman_trend=${9:-0}
    
    local start_time=$(date +%s%N)
    
    # ========================================================================
    # Component 1: ML Predictor (15% weight) - 5 second timeout
    # ========================================================================
    local ml_confidence=50
    local ml_direction="neutral"
    local ml_error=""
    
    if command -v ml_predict_direction &>/dev/null; then
        local ml_result
        ml_result=$(timeout 5 ml_predict_direction "$symbol" 5 2>/dev/null || echo "{\"error\": \"timeout\"}")
        
        if [[ ! "$ml_result" =~ "error" ]]; then
            ml_confidence=$(echo "$ml_result" | jq -r '.confidence // 50' 2>/dev/null || echo "50")
            ml_direction=$(echo "$ml_result" | jq -r '.direction // "neutral"' 2>/dev/null || echo "neutral")
        else
            ml_error=$(echo "$ml_result" | jq -r '.error // "unknown"' 2>/dev/null)
        fi
    fi
    
    # ========================================================================
    # Component 2: Regime-Adaptive Strategy Score (35% weight)
    # ========================================================================
    local regime_score=50
    local regime_weights_json
    
    # Determine regime weights
    case "$regime" in
        "sideways")
            # Favor mean reversion: 70% MR + 30% TF
            regime_score=$(echo "scale=2; ($mr_score * 0.7) + ($tf_score * 0.3)" | bc)
            ;;
        "trending_bull"|"trending_bear")
            # Favor trend following: 30% MR + 70% TF
            regime_score=$(echo "scale=2; ($mr_score * 0.3) + ($tf_score * 0.7)" | bc)
            ;;
        "volatile")
            # Equal weighting with reduced confidence: 50% MR + 50% TF - 20%
            regime_score=$(echo "scale=2; (($mr_score * 0.5) + ($tf_score * 0.5)) * 0.8" | bc)
            ;;
        *)
            # Default neutral: 50% each
            regime_score=$(echo "scale=2; ($mr_score * 0.5) + ($tf_score * 0.5)" | bc)
            ;;
    esac
    
    regime_score=$(printf "%.0f" "$regime_score")
    
    # ========================================================================
    # Component 3: Technical Indicators Score (30% weight)
    # ========================================================================
    local technical_score
    technical_score=$(echo "scale=2; ($rsi_score + $macd_score + $bb_score) / 3" | bc)
    technical_score=$(printf "%.0f" "$technical_score")
    
    # ========================================================================
    # Component 4: Volume/Trend Confirmation (20% weight)
    # ========================================================================
    # Combine OBV score with Kalman-filtered trend direction
    local volume_trend_score
    if [[ "$kalman_trend" == "1" ]]; then
        # Uptrend confirmed by Kalman filter
        volume_trend_score=$(echo "scale=2; ($obv_score * 0.8) + (75 * 0.2)" | bc)
    elif [[ "$kalman_trend" == "-1" ]]; then
        # Downtrend confirmed by Kalman filter
        volume_trend_score=$(echo "scale=2; ($obv_score * 0.8) + (25 * 0.2)" | bc)
    else
        # Neutral Kalman signal
        volume_trend_score=$obv_score
    fi
    
    volume_trend_score=$(printf "%.0f" "$volume_trend_score")
    
    # ========================================================================
    # Calculate Composite Confluence Score
    # ========================================================================
    local confluence_score
    confluence_score=$(echo "scale=2; \
        ($ml_confidence * 0.15) + \
        ($regime_score * 0.35) + \
        ($technical_score * 0.30) + \
        ($volume_trend_score * 0.20)" | bc)
    
    confluence_score=$(printf "%.0f" "$confluence_score")
    
    # ========================================================================
    # Determine Signal Strength (agreement level)
    # ========================================================================
    local signal_agreement=0
    local bullish_signals=0
    local bearish_signals=0
    
    # ML signal
    if [[ "$ml_direction" == "up" && "$ml_confidence" -gt 60 ]]; then
        ((bullish_signals++))
    elif [[ "$ml_direction" == "down" && "$ml_confidence" -gt 60 ]]; then
        ((bearish_signals++))
    fi
    
    # Regime signal
    if [[ "$regime_score" -gt 60 ]]; then
        ((bullish_signals++))
    elif [[ "$regime_score" -lt 40 ]]; then
        ((bearish_signals++))
    fi
    
    # Technical signal
    if [[ "$technical_score" -gt 60 ]]; then
        ((bullish_signals++))
    elif [[ "$technical_score" -lt 40 ]]; then
        ((bearish_signals++))
    fi
    
    # Volume/Trend signal
    if [[ "$volume_trend_score" -gt 60 ]]; then
        ((bullish_signals++))
    elif [[ "$volume_trend_score" -lt 40 ]]; then
        ((bearish_signals++))
    fi
    
    signal_agreement=$((bullish_signals + bearish_signals))
    
    # ========================================================================
    # Generate Recommendation with Signal Validation
    # ========================================================================
    local recommendation="HOLD"
    local confidence_note=""
    
    # Require at least 3 components in agreement for strong signals
    if [[ "$signal_agreement" -ge 3 ]]; then
        if [[ "$bullish_signals" -ge 3 && "$bearish_signals" -eq 0 ]]; then
            if [[ "$confluence_score" -gt 70 ]]; then
                recommendation="STRONG_BUY"
                confidence_note="Strong consensus across all indicators"
            elif [[ "$confluence_score" -gt 55 ]]; then
                recommendation="BUY"
                confidence_note="Multiple bullish signals confirmed"
            fi
        elif [[ "$bearish_signals" -ge 3 && "$bullish_signals" -eq 0 ]]; then
            if [[ "$confluence_score" -lt 30 ]]; then
                recommendation="STRONG_SELL"
                confidence_note="Strong consensus across all indicators"
            elif [[ "$confluence_score" -lt 45 ]]; then
                recommendation="SELL"
                confidence_note="Multiple bearish signals confirmed"
            fi
        fi
    else
        # Mixed or weak signals
        if [[ "$confluence_score" -gt 60 ]]; then
            recommendation="BUY"
            confidence_note="Moderately bullish; some conflicting signals"
        elif [[ "$confluence_score" -lt 40 ]]; then
            recommendation="SELL"
            confidence_note="Moderately bearish; some conflicting signals"
        else
            recommendation="HOLD"
            confidence_note="Mixed signals; await clearer direction"
        fi
    fi
    
    # ========================================================================
    # Calculate latency
    # ========================================================================
    local end_time=$(date +%s%N)
    local latency_ms=$(( (end_time - start_time) / 1000000 ))
    
    # ========================================================================
    # Generate JSON Output
    # ========================================================================
    cat <<EOF
{
  "confluence_score": ${confluence_score},
  "recommendation": "${recommendation}",
  "signal_strength": ${signal_agreement},
  "components": {
    "ml_confidence": {
      "score": ${ml_confidence},
      "direction": "${ml_direction}",
      "weight_percent": 15
    },
    "regime_score": {
      "score": ${regime_score},
      "regime": "${regime}",
      "weight_percent": 35
    },
    "technical_score": {
      "score": ${technical_score},
      "weight_percent": 30
    },
    "volume_trend_score": {
      "score": ${volume_trend_score},
      "weight_percent": 20
    }
  },
  "breakdown": {
    "symbol": "${symbol}",
    "individual_scores": {
      "rsi": ${rsi_score},
      "macd": ${macd_score},
      "bollinger_bands": ${bb_score},
      "obv": ${obv_score},
      "mean_reversion": ${mr_score},
      "trend_following": ${tf_score},
      "kalman_trend": ${kalman_trend}
    },
    "signal_counts": {
      "bullish_signals": ${bullish_signals},
      "bearish_signals": ${bearish_signals},
      "total_agreement": ${signal_agreement}
    }
  },
  "metadata": {
    "confidence_note": "${confidence_note}",
    "ml_error": "${ml_error}",
    "latency_ms": ${latency_ms},
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }
}
EOF
}

# ============================================================================
# Calculate Stop-Loss and Risk Metrics
# ============================================================================

# Calculate stop-loss based on ATR (ATR method)
# Args: entry_price, atr_value, multiplier (default 2)
# Returns: stop_loss_price
calc_stop_loss_atr() {
    local entry=$1
    local atr=$2
    local multiplier=${3:-2}
    
    local sl=$(echo "$entry - ($atr * $multiplier)" | bc -l)
    printf "%.2f" "$sl"
}

# Calculate stop-loss as percentage
# Args: entry_price, stop_loss_percent (default 5)
# Returns: stop_loss_price
calc_stop_loss_percent() {
    local entry=$1
    local percent=${2:-5}
    
    local sl=$(echo "$entry * (1 - $percent / 100)" | bc -l)
    printf "%.2f" "$sl"
}

# Calculate take-profit target
# Args: entry_price, target_percent (default 8)
# Returns: take_profit_price
calc_take_profit() {
    local entry=$1
    local percent=${2:-8}
    
    local tp=$(echo "$entry * (1 + $percent / 100)" | bc -l)
    printf "%.2f" "$tp"
}

# Calculate risk-reward ratio
# Args: entry_price, stop_loss, take_profit
# Returns: ratio (e.g., "1:2.5" means risk $1 to make $2.50)
calc_risk_reward_ratio() {
    local entry=$1
    local sl=$2
    local tp=$3
    
    local risk=$(echo "$entry - $sl" | bc -l)
    local reward=$(echo "$tp - $entry" | bc -l)
    
    if (( $(echo "$risk > 0" | bc -l) )); then
        local ratio=$(echo "$reward / $risk" | bc -l)
        printf "%.1f" "$ratio"
    else
        echo "0"
    fi
}

# ============================================================================
# Generate Score Summary
# ============================================================================

# Create detailed score breakdown
# Args: symbol, rsi_score, macd_score, bb_score, stochastic_score, williams_r_score, obv_score, sentiment_score
generate_score_summary() {
    local symbol=$1
    local rsi_score=$2
    local macd_score=$3
    local bb_score=$4
    local stochastic_score=$5
    local williams_r_score=$6
    local obv_score=$7
    local sentiment_score=$8
    
    echo "{
        \"symbol\": \"${symbol}\",
        \"scores\": {
            \"rsi\": ${rsi_score},
            \"macd\": ${macd_score},
            \"bollinger_bands\": ${bb_score},
            \"stochastic\": ${stochastic_score},
            \"williams_r\": ${williams_r_score},
            \"obv\": ${obv_score},
            \"sentiment\": ${sentiment_score}
        },
        \"average\": $(( (rsi_score + macd_score + bb_score + stochastic_score + williams_r_score + obv_score) / 6 )),
        \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
    }"
}

# Export all functions
export -f score_rsi score_macd score_bollinger_bands score_stochastic
export -f score_williams_r score_obv calculate_confluence_score calculate_confluence_score_v2
export -f calc_stop_loss_atr calc_stop_loss_percent calc_take_profit
export -f calc_risk_reward_ratio generate_score_summary
