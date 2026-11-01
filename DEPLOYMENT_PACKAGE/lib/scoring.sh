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

# Source integrated modules. This file is sourced by the agent and by tests,
# so it uses its own dir variable and never touches the caller's SCRIPT_DIR.
# calculate_confluence_score_v2 runs "$SCORING_LIB_DIR/ml_predictor.sh".
SCORING_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCORING_LIB_DIR}/ml_predictor.sh" 2>/dev/null || true
source "${SCORING_LIB_DIR}/regime_weighting.sh" 2>/dev/null || true
source "${SCORING_LIB_DIR}/kalman_filter.sh" 2>/dev/null || true
# Optional MiroFish cache adapter (Phase 1 port)
source "${SCORING_LIB_DIR}/mirofish_adapter.sh" 2>/dev/null || true

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

# Map a legacy confluence score to signal and reasoning (75/60/40/25 thresholds)
# Args: score
# Returns: "SIGNAL|reasoning"
_confluence_signal_for() {
    local final_confidence=$1
    if (( $(echo "$final_confidence >= 75" | bc -l) )); then
        echo "STRONG_BUY|Multiple indicators aligned bullish; high confidence entry point"
    elif (( $(echo "$final_confidence >= 60" | bc -l) )); then
        echo "BUY|Most indicators bullish; good entry opportunity"
    elif (( $(echo "$final_confidence >= 40" | bc -l) )); then
        echo "HOLD|Mixed signals; monitor for clearer direction"
    elif (( $(echo "$final_confidence >= 25" | bc -l) )); then
        echo "SELL|Most indicators bearish; consider exiting positions"
    else
        echo "STRONG_SELL|Multiple indicators aligned bearish; high conviction short"
    fi
}
# Calculate final confidence score from all signals (Legacy - use calculate_confluence_score_v2)
# Args: rsi_score, macd_score, bb_score, stochastic_score, williams_r_score, obv_score, sentiment_score
#   sentiment_score may be "na", "null" or "unavailable": sentiment then gets
#   0 weight (final = technical average) and sentiment_contribution is null.
# Returns: JSON with final_confidence, signal (BUY/SELL/HOLD), reasoning
calculate_confluence_score() {
    local rsi_score=${1:-50}
    local macd_score=${2:-50}
    local bb_score=${3:-50}
    local stoch_score=${4:-50}
    local williams_score=${5:-50}
    local obv_score=${6:-50}
    local sentiment_score=${7:-50}
    
    local sentiment_available=true
    case "$sentiment_score" in
        na|null|unavailable) sentiment_available=false ;;
    esac
    # Weighted confluence (sentiment is 20% of total, technical is 80%;
    # technical is 100% when sentiment is unavailable)
    local technical_avg=$(( (rsi_score + macd_score + bb_score + stoch_score + williams_score + obv_score) / 6 ))
    local final_confidence
    if [[ "$sentiment_available" == "true" ]]; then
        final_confidence=$(echo "(${technical_avg} * 0.8) + (${sentiment_score} * 0.2)" | bc)
    else
        final_confidence=$technical_avg
    fi

    # Determine signal based on confluence thresholds
    local signal_and_reason signal reasoning
    signal_and_reason=$(_confluence_signal_for "$final_confidence")
    signal="${signal_and_reason%%|*}"
    reasoning="${signal_and_reason#*|}"

    final_confidence=$(printf "%.0f" "$final_confidence")

    if [[ "$sentiment_available" == "true" ]]; then
        echo "{\"final_confidence\":${final_confidence},\"signal\":\"${signal}\",\"reasoning\":\"${reasoning}\",\"technical_avg\":${technical_avg},\"sentiment_contribution\":${sentiment_score},\"sentiment_available\":true}"
    else
        echo "{\"final_confidence\":${final_confidence},\"signal\":\"${signal}\",\"reasoning\":\"${reasoning}\",\"technical_avg\":${technical_avg},\"sentiment_contribution\":null,\"sentiment_available\":false}"
    fi
}

# Blend the optional MiroFish cache signal into a legacy confluence JSON
# Args: confluence_json (from calculate_confluence_score), symbol
# Returns: the input unchanged when MiroFish is disabled (or on jq failure);
#   otherwise the input plus a "mirofish" block. When the cache status is OK
#   and MIROFISH_WEIGHT > 0, final_confidence = round(final*(1-w) + mf*w)
#   and signal/reasoning are recomputed with the same thresholds.
apply_mirofish_to_confluence() {
    local confluence=$1
    local symbol=$2
    if [[ "${MIROFISH_ENABLED:-false}" != "true" ]] || ! declare -f mirofish_get_prediction >/dev/null; then
        echo "$confluence"
        return 0
    fi
    local mf mf_status mf_score w final new_final sr out
    mf=$(mirofish_get_prediction "$symbol")
    mf_status=$(echo "$mf" | jq -r '.status' 2>/dev/null)
    mf_score=$(echo "$mf" | jq -r '.score // "null"' 2>/dev/null)
    w=$(mirofish_effective_weight)
    final=$(echo "$confluence" | jq -r '.final_confidence' 2>/dev/null)
    if [[ "$mf_status" == "OK" && "$mf_score" != "null" && "$final" =~ ^-?[0-9]+$ ]] \
        && awk -v w="$w" 'BEGIN { exit !(w > 0) }'; then
        new_final=$(mirofish_blend_score "$final" "$mf_score" "$w")
        sr=$(_confluence_signal_for "$new_final")
        out=$(echo "$confluence" | jq -c --argjson mf "$mf" --argjson w "$w" --argjson f "$new_final" \
            --arg sig "${sr%%|*}" --arg rsn "${sr#*|}" \
            '. + {final_confidence:$f, signal:$sig, reasoning:$rsn,
                  mirofish:{status:$mf.status, prediction:$mf.prediction, score:$mf.score, weight:$w, applied:true}}' 2>/dev/null)
    else
        out=$(echo "$confluence" | jq -c --argjson mf "$mf" --argjson w "$w" \
            '. + {mirofish:{status:$mf.status, prediction:$mf.prediction, score:$mf.score, weight:$w, applied:false}}' 2>/dev/null)
    fi
    if [[ -z "$out" ]]; then
        echo "$confluence"
    else
        echo "$out"
    fi
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
#   [sentiment_score]: optional 10th arg, 0-100 or na/null/unavailable/"".
#     Only when this arg is passed: components.sentiment is added; a numeric
#     score with V2_SENTIMENT_WEIGHT (default 0.10, 0..0.5) > 0 gives
#     final = core*(1-ws) + sentiment*ws (core = unrounded score incl.
#     MiroFish) and every other weight_percent scales by (1-ws). Sentiment
#     casts no vote. With <= 9 args the output is unchanged.
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
#   (ML unavailable, i.e. predictor returned {"available": false}: ML score
#    null, weight 0, the other weights renormalized to 41.2/35.3/23.5 and
#    metadata.ml_available false. A synthetic ML result is marked
#    components.ml_confidence.data_source "synthetic" + metadata.data_warning.)
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
    # Optional sentiment component (arg 10): see the header comment
    local sent_passed=false sent_available=false sent_applied=false sent_score="null" sent_w=0
    if [[ $# -ge 10 ]]; then
        sent_passed=true
        if [[ "${10}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
            sent_available=true
            sent_score=$(awk -v s="${10}" 'BEGIN { print s + 0 }')
            sent_w=$(awk -v w="${V2_SENTIMENT_WEIGHT:-0.10}" 'BEGIN {
                if (w !~ /^[0-9]*\.?[0-9]+$/) w = 0.10
                if (w > 0.5) w = 0.5
                print w + 0 }')
            awk -v w="$sent_w" 'BEGIN { exit !(w > 0) }' && sent_applied=true
        fi
    fi
    
    local start_time=$(date +%s%N)
    
    # ========================================================================
    # Component 1: ML Predictor (15% weight) - 5 second timeout
    # ========================================================================
    local ml_confidence=50
    local ml_direction="neutral"
    local ml_error=""
    # ML availability: false when the predictor reports {"available": false}
    # (no real market data). ML then gets 0 weight and the other four weights
    # are renormalized, like unavailable sentiment/MiroFish.
    local ml_available=true
    local ml_reason=""
    local ml_data_source=""
    
    if command -v ml_predict_direction &>/dev/null; then
        local ml_result
        # macOS has no coreutils `timeout`; this perl helper runs the predictor
        # CLI in its own process group and kills the whole group (bash + python)
        # when ML_TIMEOUT_SECONDS (default 5) elapses.
        ml_result=$(perl -e '
            my $t = shift;
            my $pid = fork() // exit 125;
            if ($pid == 0) { setpgrp(0, 0); exec @ARGV or exit 127; }
            $SIG{ALRM} = sub { kill "TERM", -$pid; kill "TERM", $pid; exit 124; };
            alarm $t;
            waitpid($pid, 0);
            exit($? >> 8);' "${ML_TIMEOUT_SECONDS:-5}" \
            bash "${SCORING_LIB_DIR}/ml_predictor.sh" predict "$symbol" 5 </dev/null 2>/dev/null \
            || echo "{\"error\": \"timeout_or_failure\"}")
        
        if ! echo "$ml_result" | jq -e 'type == "object"' >/dev/null 2>&1; then
            ml_error="invalid_predictor_output"
        elif echo "$ml_result" | jq -e 'has("error")' >/dev/null 2>&1; then
            ml_error=$(echo "$ml_result" | jq -r '.error // "unknown"' 2>/dev/null)
        elif echo "$ml_result" | jq -e '.available == false' >/dev/null 2>&1; then
            ml_available=false
            ml_direction="unavailable"
            ml_reason=$(echo "$ml_result" | jq -r '.reason // "no market data"' 2>/dev/null)
        else
            ml_confidence=$(echo "$ml_result" | jq -r '.confidence // 50' 2>/dev/null || echo "50")
            ml_direction=$(echo "$ml_result" | jq -r '.direction // "neutral"' 2>/dev/null || echo "neutral")
            ml_data_source=$(echo "$ml_result" | jq -r '.data_source // "unknown"' 2>/dev/null)
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
    # Optional MiroFish cache component (Phase 1 port; cache read only, no
    # network). Applied only when enabled, status OK and weight > 0; then the
    # four weights above scale by (1 - w).
    local mf_json="" mf_status="" mf_score="null" mf_pred="null" mf_w=0 mf_applied=false
    if [[ "${MIROFISH_ENABLED:-false}" == "true" ]] && declare -f mirofish_get_prediction >/dev/null; then
        mf_json=$(mirofish_get_prediction "$symbol")
        mf_status=$(echo "$mf_json" | jq -r '.status' 2>/dev/null)
        mf_score=$(echo "$mf_json" | jq -r '.score // "null"' 2>/dev/null)
        mf_pred=$(echo "$mf_json" | jq -c '.prediction' 2>/dev/null)
        mf_w=$(mirofish_effective_weight)
        if [[ "$mf_status" == "OK" && "$mf_score" != "null" ]] && awk -v w="$mf_w" 'BEGIN { exit !(w > 0) }'; then
            mf_applied=true
        fi
    fi
    local confluence_score
    if [[ "$ml_available" != "true" ]]; then
        # ML unavailable: 0 weight, regime/technical/volume renormalized to
        # 35/85, 30/85, 20/85 (then scaled by 1 - w when MiroFish applies).
        local mf_part=0 mf_scale=1
        if [[ "$mf_applied" == "true" ]]; then
            mf_part="$mf_score * $mf_w"
            mf_scale="(1 - $mf_w)"
        fi
        confluence_score=$(echo "scale=4; \
            (($regime_score * 35) + \
            ($technical_score * 30) + \
            ($volume_trend_score * 20)) / 85 * $mf_scale + \
            $mf_part" | bc)
    elif [[ "$mf_applied" == "true" ]]; then
        confluence_score=$(echo "scale=4; \
            (($ml_confidence * 0.15) + \
            ($regime_score * 0.35) + \
            ($technical_score * 0.30) + \
            ($volume_trend_score * 0.20)) * (1 - $mf_w) + \
            ($mf_score * $mf_w)" | bc)
    else
        confluence_score=$(echo "scale=2; \
            ($ml_confidence * 0.15) + \
            ($regime_score * 0.35) + \
            ($technical_score * 0.30) + \
            ($volume_trend_score * 0.20)" | bc)
    fi
    if [[ "$sent_applied" == "true" ]]; then
        # Blend sentiment on the unrounded core score (MiroFish included)
        confluence_score=$(awk -v c="$confluence_score" -v s="$sent_score" -v w="$sent_w" \
            'BEGIN { printf "%.4f", c * (1 - w) + s * w }')
    fi
    confluence_score=$(printf "%.0f" "$confluence_score")
    local wp_ml=15 wp_regime=35 wp_tech=30 wp_vt=20 mirofish_component=""
    if [[ "$ml_available" != "true" ]]; then
        local wscale=1
        [[ "$mf_applied" == "true" ]] && wscale=$(awk -v w="$mf_w" 'BEGIN { print 1 - w }')
        wp_ml=0
        wp_regime=$(awk -v s="$wscale" 'BEGIN { printf "%.1f", 3500 / 85 * s }')
        wp_tech=$(awk -v s="$wscale" 'BEGIN { printf "%.1f", 3000 / 85 * s }')
        wp_vt=$(awk -v s="$wscale" 'BEGIN { printf "%.1f", 2000 / 85 * s }')
    elif [[ "$mf_applied" == "true" ]]; then
        wp_ml=$(awk -v w="$mf_w" 'BEGIN { printf "%.1f", 15 * (1 - w) }')
        wp_regime=$(awk -v w="$mf_w" 'BEGIN { printf "%.1f", 35 * (1 - w) }')
        wp_tech=$(awk -v w="$mf_w" 'BEGIN { printf "%.1f", 30 * (1 - w) }')
        wp_vt=$(awk -v w="$mf_w" 'BEGIN { printf "%.1f", 20 * (1 - w) }')
    fi
    if [[ "$sent_applied" == "true" ]]; then
        # Sentiment takes ws; every other weight scales by (1 - ws), computed
        # from the unrounded base weights
        local base_scale=1
        [[ "$mf_applied" == "true" ]] && base_scale=$(awk -v w="$mf_w" 'BEGIN { print 1 - w }')
        if [[ "$ml_available" != "true" ]]; then
            wp_regime=$(awk -v s="$base_scale" -v w="$sent_w" 'BEGIN { printf "%.1f", 3500 / 85 * s * (1 - w) }')
            wp_tech=$(awk -v s="$base_scale" -v w="$sent_w" 'BEGIN { printf "%.1f", 3000 / 85 * s * (1 - w) }')
            wp_vt=$(awk -v s="$base_scale" -v w="$sent_w" 'BEGIN { printf "%.1f", 2000 / 85 * s * (1 - w) }')
        else
            wp_ml=$(awk -v s="$base_scale" -v w="$sent_w" 'BEGIN { printf "%.1f", 15 * s * (1 - w) }')
            wp_regime=$(awk -v s="$base_scale" -v w="$sent_w" 'BEGIN { printf "%.1f", 35 * s * (1 - w) }')
            wp_tech=$(awk -v s="$base_scale" -v w="$sent_w" 'BEGIN { printf "%.1f", 30 * s * (1 - w) }')
            wp_vt=$(awk -v s="$base_scale" -v w="$sent_w" 'BEGIN { printf "%.1f", 20 * s * (1 - w) }')
        fi
    fi
    # JSON fragments for the ML component's availability / data source
    local ml_score_json="$ml_confidence" ml_extra="" data_warning=""
    if [[ "$ml_available" != "true" ]]; then
        ml_score_json="null"
        ml_extra=",
      \"available\": false,
      \"reason\": $(jq -Rn --arg r "$ml_reason" '$r'),
      \"data_source\": null"
    elif [[ -n "$ml_data_source" ]]; then
        ml_extra=",
      \"available\": true,
      \"data_source\": \"${ml_data_source}\""
        if [[ "$ml_data_source" == "synthetic" ]]; then
            data_warning="ML component used SYNTHETIC features (demo/test mode); not market data"
        fi
    fi
    if [[ -n "$mf_json" ]]; then
        local mf_wp="0"
        [[ "$mf_applied" == "true" ]] && mf_wp=$(awk -v w="$mf_w" 'BEGIN { printf "%.1f", 100 * w }')
        if [[ "$mf_applied" == "true" && "$sent_applied" == "true" ]]; then
            mf_wp=$(awk -v w="$mf_w" -v ws="$sent_w" 'BEGIN { printf "%.1f", 100 * w * (1 - ws) }')
        fi
        mirofish_component=",
    \"mirofish\": {
      \"score\": ${mf_score},
      \"status\": \"${mf_status}\",
      \"prediction\": ${mf_pred:-null},
      \"weight_percent\": ${mf_wp}
    }"
    fi
    local sentiment_component=""
    if [[ "$sent_passed" == "true" ]]; then
        local sent_wp=0
        [[ "$sent_applied" == "true" ]] && sent_wp=$(awk -v w="$sent_w" 'BEGIN { printf "%.1f", 100 * w }')
        sentiment_component=",
    \"sentiment\": {
      \"score\": ${sent_score},
      \"available\": ${sent_available},
      \"weight_percent\": ${sent_wp}
    }"
    fi
    
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
      "score": ${ml_score_json},
      "direction": "${ml_direction}",
      "weight_percent": ${wp_ml}${ml_extra}
    },
    "regime_score": {
      "score": ${regime_score},
      "regime": "${regime}",
      "weight_percent": ${wp_regime}
    },
    "technical_score": {
      "score": ${technical_score},
      "weight_percent": ${wp_tech}
    },
    "volume_trend_score": {
      "score": ${volume_trend_score},
      "weight_percent": ${wp_vt}
    }${mirofish_component}${sentiment_component}
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
    "ml_available": ${ml_available},
    "data_warning": "${data_warning}",
    "latency_ms": ${latency_ms},
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }
}
EOF
}

# ============================================================================
# v2 inputs from fetched bars (Step 1: CLI uses calculate_confluence_score_v2)
# ============================================================================
# All helpers are pure (awk/jq on the data already fetched); no network.

# Score the OBV trend over the last LOOKBACK bars
# Args: obv_json (JSON array, calc_obv output), volumes_json (JSON array),
#       [lookback] (default OBV_LOOKBACK or 10)
# Returns: {"obv_score","obv_available","obv_change","obv_lookback"}
#   delta = obv[-1] - obv[-1-N]; ratio = delta / (N * mean(volume[-N:]))
#   clamped to [-1,1]; score = round(50 + 50*ratio). All-up bars -> 100,
#   all-down -> 0, flat -> 50. Fewer than N+1 points -> 50, obv_available false.
# Example: score_obv_trend '[1,2,3]' '[1,1,1]' 2   # -> obv_score 100
score_obv_trend() {
    local obv_json=${1:-[]}
    local volumes_json=${2:-[]}
    local lookback=${3:-${OBV_LOOKBACK:-10}}
    [[ "$lookback" =~ ^[0-9]+$ && "$lookback" -ge 1 ]] || lookback=10
    jq -c -n --argjson o "$obv_json" --argjson v "$volumes_json" --argjson n "$lookback" '
        if ($o | type) != "array" or ($v | type) != "array"
           or ($o | length) < ($n + 1) or ($v | length) < $n then
            {obv_score: 50, obv_available: false, obv_change: null, obv_lookback: $n}
        else
            ($o[-1] - $o[-1 - $n]) as $d
            | (($v[-$n:] | add) / $n) as $mv
            | (if $mv > 0 then $d / ($n * $mv) else 0 end) as $r
            | ([[$r, 1] | min, -1] | max) as $rc
            | {obv_score: ((50 + 50 * $rc) + 0.5 | floor), obv_available: true,
               obv_change: $d, obv_lookback: $n}
        end' 2>/dev/null \
        || echo "{\"obv_score\":50,\"obv_available\":false,\"obv_change\":null,\"obv_lookback\":${lookback}}"
}

# Graded mean-reversion setup score (mirrors mean_reversion_analyze criteria)
# Args: rsi, close, bb_upper, bb_lower, last_volume, avg_volume_20, macd, signal
# Returns: score 0-100
#   rsi_term = clamp((50-RSI)/20,-1,1)*25; bb_term = clamp((0.5-bbfrac)/0.5,-1,1)*15
#   with bbfrac = (close-lower)/(upper-lower) (0.5 when the band is empty);
#   vol_mult = 1.2 if last_volume > avg_volume_20 else 1.0;
#   macd_term = +5 if macd > signal, -5 if macd < signal, 0 when equal
#   MR = clamp(round(50 + vol_mult*(rsi_term+bb_term) + macd_term), 0, 100)
score_mean_reversion_setup() {
    awk -v rsi="${1:-50}" -v c="${2:-0}" -v u="${3:-0}" -v l="${4:-0}" \
        -v lv="${5:-0}" -v av="${6:-0}" -v m="${7:-0}" -v s="${8:-0}" 'BEGIN {
        rt = (50 - rsi) / 20; if (rt > 1) rt = 1; if (rt < -1) rt = -1; rt *= 25
        f = 0.5; if (u - l > 0) f = (c - l) / (u - l)
        bt = (0.5 - f) / 0.5; if (bt > 1) bt = 1; if (bt < -1) bt = -1; bt *= 15
        vm = (lv + 0 > av + 0) ? 1.2 : 1.0
        mt = 0; if (m + 0 > s + 0) mt = 5; else if (m + 0 < s + 0) mt = -5
        x = int(50 + vm * (rt + bt) + mt + 0.5 + 1000) - 1000
        if (x < 0) x = 0; if (x > 100) x = 100
        print x }'
}

# Graded trend-following setup score (mirrors trend_follow_analyze criteria)
# Args: close, ema12, ema26, sma50|'' , sma200|'', last_volume, avg_volume_30
# Returns: score 0-100
#   ema_term = +-15 (EMA12 vs EMA26), sma50_term = +-15 (close vs SMA50, 0
#   when empty), sma200_term = +-10 (close vs SMA200, 0 when empty);
#   vol_mult = 1.2 if last_volume > avg_volume_30;
#   TF = clamp(round(50 + vol_mult*sum), 0, 100). Equal values give 0.
score_trend_follow_setup() {
    awk -v c="${1:-0}" -v e12="${2:-0}" -v e26="${3:-0}" -v s50="${4:-}" -v s200="${5:-}" \
        -v lv="${6:-0}" -v av="${7:-0}" 'BEGIN {
        t = 0
        if (e12 + 0 > e26 + 0) t += 15; else if (e12 + 0 < e26 + 0) t -= 15
        if (s50 != "") { if (c + 0 > s50 + 0) t += 15; else if (c + 0 < s50 + 0) t -= 15 }
        if (s200 != "") { if (c + 0 > s200 + 0) t += 10; else if (c + 0 < s200 + 0) t -= 10 }
        vm = (lv + 0 > av + 0) ? 1.2 : 1.0
        x = int(50 + vm * t + 0.5 + 1000) - 1000
        if (x < 0) x = 0; if (x > 100) x = 100
        print x }'
}

# Kalman trend direction from closes
# Args: closes_json (JSON array, oldest first)
# Returns: {"kalman_trend": -1|0|1, "kalman_slope_pct", "kalman_available"}
#   slope_pct = (f[-1]-f[-6])/f[-6]*100 on apply_kalman_filter_fast output;
#   > KALMAN_TREND_THRESHOLD_PCT (default 0.5) -> 1, < -threshold -> -1.
#   Failure or < 6 filtered prices -> 0 with kalman_available false.
kalman_trend_from_closes() {
    local closes_json=${1:-[]}
    local threshold=${KALMAN_TREND_THRESHOLD_PCT:-0.5}
    local filtered=""
    if declare -f apply_kalman_filter_fast >/dev/null; then
        filtered=$(apply_kalman_filter_fast "$closes_json" 2>/dev/null)
    fi
    echo "$filtered" | jq -c --argjson t "$threshold" '
        (.filtered_prices // []) as $f
        | if ($f | length) < 6 or ($f[-6] // 0) == 0 then error("short") else
            (($f[-1] - $f[-6]) / $f[-6] * 100) as $s
            | {kalman_trend: (if $s > $t then 1 elif $s < -$t then -1 else 0 end),
               kalman_slope_pct: (($s * 10000 | round) / 10000), kalman_available: true}
          end' 2>/dev/null \
        || echo '{"kalman_trend":0,"kalman_slope_pct":null,"kalman_available":false}'
}

# Build every v2 input from the bars already fetched by the agent
# Args: symbol, closes_json, volumes_json, obv_json, rsi, macd, signal,
#       bb_upper, bb_lower
# Returns: one-line JSON {obv_score, obv_available, obv_change, obv_lookback,
#   mr_score, tf_score, kalman_trend, kalman_slope_pct, kalman_available,
#   regime, regime_detail, ema_12, ema_26, sma_50, sma_200, last_volume,
#   avg_volume_20, avg_volume_30, closes_count}
#   regime comes from detect_market_regime on the passed closes
#   (data_source "caller"); unavailable -> "unknown". sma_50/sma_200 are null
#   with fewer than 50/200 closes (their trend terms are then 0).
build_v2_inputs() {
    local symbol=$1 closes_json=${2:-[]} volumes_json=${3:-[]} obv_json=${4:-[]}
    local rsi=${5:-50} macd=${6:-0} signal=${7:-0} bb_upper=${8:-0} bb_lower=${9:-0}

    # EMA12/EMA26 (SMA seed, like calc_ema), SMA50/200, volume averages
    local stats
    stats=$(jq -c -n --argjson c "$closes_json" --argjson v "$volumes_json" '
        def ema($p): if ($c | length) < $p then null else
            reduce $c[$p:][] as $x ((($c[0:$p] | add) / $p); ($x - .) * (2 / ($p + 1)) + .) end;
        def tailmean($a; $n): if ($a | length) < $n or $n == 0 then null else ($a[-$n:] | add) / $n end;
        def r4: if . == null then null else (. * 10000 | round) / 10000 end;
        {ema_12: (ema(12) | r4), ema_26: (ema(26) | r4),
         sma_50: (tailmean($c; 50) | r4), sma_200: (tailmean($c; 200) | r4),
         last_close: ($c[-1] // null), last_volume: ($v[-1] // null),
         avg_volume_20: (tailmean($v; 20) | r4), avg_volume_30: (tailmean($v; 30) | r4),
         closes_count: ($c | length)}' 2>/dev/null)
    [[ -z "$stats" ]] && stats='{"closes_count":0}'
    local close ema12 ema26 sma50 sma200 lastv av20 av30 count
    IFS='|' read -r close ema12 ema26 sma50 sma200 lastv av20 av30 count <<< "$(echo "$stats" | jq -r \
        '[.last_close, .ema_12, .ema_26, .sma_50, .sma_200, .last_volume, .avg_volume_20, .avg_volume_30, .closes_count]
         | map(if . == null then "" else tostring end) | join("|")')"

    local obv mr tf kal
    obv=$(score_obv_trend "$obv_json" "$volumes_json")
    mr=$(score_mean_reversion_setup "$rsi" "${close:-0}" "$bb_upper" "$bb_lower" "${lastv:-0}" "${av20:-0}" "$macd" "$signal")
    tf=$(score_trend_follow_setup "${close:-0}" "${ema12:-0}" "${ema26:-0}" "$sma50" "$sma200" "${lastv:-0}" "${av30:-0}")
    kal=$(kalman_trend_from_closes "$closes_json")

    local regime="unknown" regime_detail="null"
    if declare -f detect_market_regime >/dev/null && [[ "${count:-0}" -ge 20 ]]; then
        local -a closes_arr=()
        closes_arr=($(echo "$closes_json" | jq -r '.[]' 2>/dev/null))
        local rd
        rd=$(detect_market_regime "$symbol" "${#closes_arr[@]}" "${closes_arr[@]}" 2>/dev/null | jq -c . 2>/dev/null)
        if [[ -n "$rd" ]]; then
            regime_detail="$rd"
            if echo "$rd" | jq -e '.available != false and .data_source == "caller"' >/dev/null 2>&1; then
                regime=$(echo "$rd" | jq -r '.regime // "unknown"')
            fi
        fi
    fi

    jq -c -n --argjson s "$stats" --argjson o "$obv" --argjson k "$kal" \
        --argjson mr "${mr:-50}" --argjson tf "${tf:-50}" --arg rg "$regime" --argjson rd "$regime_detail" '
        $o + {mr_score: $mr, tf_score: $tf} + $k
        + {regime: $rg, regime_detail: $rd,
           ema_12: $s.ema_12, ema_26: $s.ema_26, sma_50: $s.sma_50, sma_200: $s.sma_200,
           last_volume: $s.last_volume, avg_volume_20: $s.avg_volume_20,
           avg_volume_30: $s.avg_volume_30, closes_count: ($s.closes_count // 0)}'
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
export -f _confluence_signal_for apply_mirofish_to_confluence
export -f calc_stop_loss_atr calc_stop_loss_percent calc_take_profit
export -f calc_risk_reward_ratio generate_score_summary
export -f score_obv_trend score_mean_reversion_setup score_trend_follow_setup
export -f kalman_trend_from_closes build_v2_inputs
