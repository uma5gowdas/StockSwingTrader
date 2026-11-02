#!/bin/bash
# ============================================================================
# StockSwingTrader: Market Regime Detector
# ============================================================================
# Detects current market regime by analyzing:
#   - ADX (Average Directional Index) for trend strength
#   - Bollinger Bands width for volatility
#   - EMA crossover for trend direction
#
# Regimes:
#   - "sideways": ADX < 25 and low volatility (tight bands)
#   - "trending_bull": ADX > 25 and EMA20 > EMA50 (uptrend)
#   - "trending_bear": ADX > 25 and EMA20 < EMA50 (downtrend)
#   - "volatile": BB width > 2 std devs, high uncertainty
#
# Cache Strategy: 15-minute TTL to avoid recomputation
# ============================================================================

# Source dependencies
REGIME_DETECTOR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${REGIME_DETECTOR_LIB_DIR}/portable.sh"
source "$(dirname "${BASH_SOURCE[0]}")/indicators.sh" 2>/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/trading_thresholds.sh" 2>/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/kalman_filter.sh" 2>/dev/null

# Cache directory setup (override REGIME_CACHE_DIR to isolate, e.g. in tests)
REGIME_CACHE_DIR="${REGIME_CACHE_DIR:-${HOME}/.stockswingtrader/regime_cache}"
REGIME_CACHE_TTL=900  # 15 minutes in seconds

mkdir -p "$REGIME_CACHE_DIR"

# ============================================================================
# Helper: Floating-point math (bash arithmetic is integer-only)
# ============================================================================

# Last value of a JSON number array such as "[0,101.25,102.5]"
_regime_last_value() {
    echo "$1" | tr -d '[] ' | tr ',' '\n' | tail -1
}

# Last EMA(period) value, or the mean of all prices when there are fewer
# prices than the period (calc_ema emits zeros until it has enough data).
# Args: period, prices...
_regime_ema_or_mean() {
    local period=$1
    shift
    if [[ $# -eq 0 ]]; then
        echo ""
        return
    fi
    if [[ $# -lt $period ]]; then
        printf "%.2f" "$(calc_mean "$@")"
        return
    fi
    _regime_last_value "$(calc_ema "$period" "$@")"
}

# ADX approximation from EMA separation: min(100, |ema_20 - ema_50| * 10)
_regime_adx_from_emas() {
    awk -v a="$1" -v b="$2" 'BEGIN { d = a - b; if (d < 0) d = -d; d = d * 10; if (d > 100) d = 100; printf "%.2f", d }'
}

# Floating-point comparison: _regime_gt a b  -> exit 0 when a > b
_regime_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'
}

# ============================================================================
# Helper: Cache Management
# ============================================================================

# Get cache file path for symbol
# Args: symbol
# Returns: path to cache file
get_regime_cache_file() {
    local symbol=$1
    echo "${REGIME_CACHE_DIR}/${symbol}.regime"
}

# Check if cache is still valid (within TTL)
# Args: symbol
# Returns: 0 if valid, 1 if expired or missing
is_regime_cache_valid() {
    local symbol=$1
    local cache_file=$(get_regime_cache_file "$symbol")
    
    if [[ ! -f "$cache_file" ]]; then
        return 1
    fi
    
    local file_age=$(($(date +%s) - $(sst_file_mtime "$cache_file")))
    
    if [[ $file_age -lt $REGIME_CACHE_TTL ]]; then
        return 0
    fi
    return 1
}

# Save regime to cache
# Args: symbol, regime_json
# Returns: void
cache_regime() {
    local symbol=$1
    local regime_json=$2
    local cache_file=$(get_regime_cache_file "$symbol")
    
    echo "$regime_json" > "$cache_file"
}

# Synthetic data is opt-in: SST_ALLOW_SYNTHETIC=1 or SST_OFFLINE=1
_regime_synthetic_allowed() {
    [[ "${SST_OFFLINE:-0}" == "1" || "${SST_ALLOW_SYNTHETIC:-0}" == "1" ]]
}

# Print the cached regime and return 0 when the cache is fresh and usable:
# a result computed from the synthetic demo series (or an old entry without
# a data_source) is only reused while synthetic data is allowed.
# Args: symbol
_regime_load_cache_if_ok() {
    local symbol=$1
    is_regime_cache_valid "$symbol" || return 1
    local cached
    cached=$(load_regime_from_cache "$symbol")
    if [[ "$(echo "$cached" | jq -r '.data_source // "synthetic"' 2>/dev/null)" == "synthetic" ]] \
        && ! _regime_synthetic_allowed; then
        return 1
    fi
    echo "$cached"
}

# Load regime from cache
# Args: symbol
# Returns: cached regime JSON or empty string
load_regime_from_cache() {
    local symbol=$1
    local cache_file=$(get_regime_cache_file "$symbol")
    
    if [[ -f "$cache_file" ]]; then
        cat "$cache_file"
    else
        echo ""
    fi
}

# ============================================================================
# ADX Calculation (Average Directional Index)
# ============================================================================

# Calculate ADX from high/low/close data
# Args: high prices (space-separated), low prices (space-separated), close prices (space-separated), period (default 14)
# Returns: ADX value (0-100)
calc_adx() {
    local -a highs=()
    local -a lows=()
    local -a closes=()
    local period=${1:-14}
    
    # Parse arguments - expect them as high_array low_array close_array
    # Usage: calc_adx 14 "${highs[@]}" "${lows[@]}" "${closes[@]}"
    shift  # Remove period
    
    # Remaining args are packed as: all highs, then all lows, then all closes
    # For simplicity, this is called with specific data
    # Note: Simplified ADX calculation
    
    echo "0"  # Placeholder - would require full DI+ and DI- calculation
}

# Simplified ADX approximation using trend strength
# Args: ema_20, ema_50, price_array (space-separated)
# Returns: ADX approximation (0-100)
calc_adx_approx() {
    local ema_20=${1:-100}
    local ema_50=${2:-100}
    shift 2
    local -a prices=($@)
    
    if [[ ${#prices[@]} -lt 2 ]]; then
        echo "25"
        return
    fi
    
    # Trend strength from EMA separation, scaled x10 and capped at 100.
    # Computed with awk because EMAs are decimals (e.g. 100.2).
    awk -v a="$ema_20" -v b="$ema_50" 'BEGIN { d = a - b; if (d < 0) d = -d; d = d * 10; if (d > 100) d = 100; printf "%.0f", d }'
}

# ============================================================================
# Bollinger Bands Volatility Analysis
# ============================================================================

# Calculate BB width as percentage of middle band
# Args: bb_upper, bb_middle, bb_lower
# Returns: BB width percentage
calc_bb_width_pct() {
    local bb_upper=$1
    local bb_middle=$2
    local bb_lower=$3
    
    local bb_width=$(echo "$bb_upper - $bb_lower" | bc -l)
    local bb_width_pct=$(echo "scale=4; ($bb_width / $bb_middle) * 100" | bc -l)
    
    printf "%.2f" "$bb_width_pct"
}

# ============================================================================
# Trend Direction Detection
# ============================================================================

# Determine trend direction from EMAs
# Args: ema_20, ema_50
# Returns: "up", "down", or "neutral"
detect_trend_direction() {
    local ema_20=${1:-100}
    local ema_50=${2:-100}
    
    # Convert to integers by removing decimal part if needed
    ema_20=$(printf "%.0f" "$ema_20")
    ema_50=$(printf "%.0f" "$ema_50")
    
    # Use integer arithmetic
    if (( ema_20 > ema_50 )); then
        echo "up"
    elif (( ema_20 < ema_50 )); then
        echo "down"
    else
        echo "neutral"
    fi
}

# ============================================================================
# Main Regime Detection
# ============================================================================

# Detect current market regime for a symbol
# Args: symbol, lookback_days (default 30), [closes...]
#   closes: real closing prices (oldest first, >= 20). Without them there is
#   no market data source here: the built-in 30-price demo series is used
#   only when synthetic data is allowed (SST_ALLOW_SYNTHETIC=1 or
#   SST_OFFLINE=1) and the result is marked "data_source": "synthetic" with a
#   "warning"; otherwise the result is
#   {"regime": "unknown", "available": false, "reason": ..., "data_source": null}.
# Returns: JSON {regime, adx, trend, volatility, data_source, timestamp}
#
# Regimes:
#   - "sideways": ADX < 25 and BB_width < 15%
#   - "trending_bull": ADX > 25 and trend direction = "up"
#   - "trending_bear": ADX > 25 and trend direction = "down"
#   - "volatile": BB_width > 20% (regardless of ADX)
detect_market_regime() {
    local symbol=$1
    local lookback_days=${2:-30}
    
    if [[ -z "$symbol" ]]; then
        cat <<EOF
{"regime": "unknown", "adx": 0, "trend": "neutral", "volatility": 0, "error": "missing_symbol"}
EOF
        return 1
    fi
    
    shift 2 2>/dev/null || shift $#
    local -a closes=("$@")
    local data_source warning=""
    
    if [[ ${#closes[@]} -gt 0 ]]; then
        if [[ ${#closes[@]} -lt 20 ]]; then
            cat <<EOF
{"regime": "unknown", "available": false, "reason": "need at least 20 closing prices, got ${#closes[@]}", "data_source": null, "symbol": "$symbol", "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
            return 0
        fi
        data_source="caller"
    else
        # Check cache first (synthetic entries only while synthetic is allowed)
        if _regime_load_cache_if_ok "$symbol"; then
            return 0
        fi
        if ! _regime_synthetic_allowed; then
            cat <<EOF
{"regime": "unknown", "available": false, "reason": "no market data: pass closing prices, or set SST_ALLOW_SYNTHETIC=1 for the demo series", "data_source": null, "symbol": "$symbol", "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
            return 0
        fi
        # Built-in demo series (explicitly allowed synthetic data)
        closes=(100.5 101.2 100.8 101.5 102.0 101.8 102.5 103.0 102.8 103.5
                104.0 103.2 103.8 104.5 105.0 104.8 105.5 106.0 105.8 106.5
                107.0 106.8 107.5 108.0 107.8 108.5 109.0 108.8 109.5 110.0)
        data_source="synthetic"
        warning=",
  \"warning\": \"Regime computed from a SYNTHETIC demo price series, not market data\""
    fi
    
    # Calculate indicators (EMA50 falls back to the mean when < 50 prices)
    local ema_20=$(_regime_ema_or_mean 20 "${closes[@]}")
    local ema_50=$(_regime_ema_or_mean 50 "${closes[@]}")
    
    if [[ -z "$ema_20" ]] || [[ -z "$ema_50" ]]; then
        ema_20=100
        ema_50=100
    fi
    
    # Get Bollinger Bands
    local bb_json=$(calc_bollinger_bands 20 2 "${closes[@]}")
    local bb_upper=$(echo "$bb_json" | grep -o '"upper":[0-9.]*' | cut -d: -f2)
    local bb_middle=$(echo "$bb_json" | grep -o '"middle":[0-9.]*' | cut -d: -f2)
    local bb_lower=$(echo "$bb_json" | grep -o '"lower":[0-9.]*' | cut -d: -f2)
    
    if [[ -z "$bb_middle" ]]; then
        bb_middle=100
        bb_upper=110
        bb_lower=90
    fi
    
    # Calculate ADX approximation (simplified, float-safe)
    local adx=$(_regime_adx_from_emas "$ema_20" "$ema_50")
    
    # Calculate BB width percentage (simplified, float-safe, capped at 100)
    local volatility=50  # Default middle value
    if [[ -n "$bb_middle" ]] && _regime_gt "$bb_middle" 0; then
        volatility=$(awk -v u="$bb_upper" -v l="$bb_lower" -v m="$bb_middle" \
            'BEGIN { v = (u - l) * 100 / m; if (v > 100) v = 100; printf "%.2f", v }')
    fi
    
    # Detect trend direction
    local trend=$(detect_trend_direction "$ema_20" "$ema_50")
    
    # Determine regime type
    local regime="sideways"
    
    # Check for high volatility first (overrides other regimes)
    if _regime_gt "$volatility" 20; then
        regime="volatile"
    # Check for trending conditions
    elif _regime_gt "$adx" 25; then
        if [[ "$trend" == "up" ]]; then
            regime="trending_bull"
        elif [[ "$trend" == "down" ]]; then
            regime="trending_bear"
        fi
    else
        # Low ADX and low volatility = sideways
        regime="sideways"
    fi
    
    # Build JSON output - ensure safe values
    local adx_safe=$(printf "%.2f" "${adx:-0}")
    local volatility_safe=$(printf "%.2f" "${volatility:-50}")
    local ema_20_safe=$(printf "%.2f" "${ema_20:-100}")
    local ema_50_safe=$(printf "%.2f" "${ema_50:-100}")
    local bb_upper_safe=$(printf "%.2f" "${bb_upper:-110}")
    local bb_middle_safe=$(printf "%.2f" "${bb_middle:-100}")
    local bb_lower_safe=$(printf "%.2f" "${bb_lower:-90}")
    
    local regime_json=$(cat <<EOF
{
  "regime": "$regime",
  "adx": $adx_safe,
  "trend": "$trend",
  "volatility": $volatility_safe,
  "ema_20": $ema_20_safe,
  "ema_50": $ema_50_safe,
  "bb_upper": $bb_upper_safe,
  "bb_middle": $bb_middle_safe,
  "bb_lower": $bb_lower_safe,
  "data_source": "$data_source",
  "symbol": "$symbol",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"${warning}
}
EOF
)
    
    # Cache the result
    cache_regime "$symbol" "$regime_json"
    
    echo "$regime_json"
}

# ============================================================================
# Kalman-Enhanced Regime Detection
# ============================================================================

# Detect market regime using Kalman-filtered prices
# Args: symbol, prices (space-separated), lookback_days (default 30)
# Returns: JSON {regime, adx, trend, volatility, raw_trend, kalman_trend, noise_level, timestamp}
#
# Compares raw trend vs Kalman-filtered trend to reduce false breakouts
detect_market_regime_kalman() {
    local symbol=$1
    shift
    local -a prices=($@)
    
    if [[ -z "$symbol" ]] || [[ ${#prices[@]} -eq 0 ]]; then
        cat <<EOF
{"regime": "unknown", "adx": 0, "trend": "neutral", "volatility": 0, "error": "missing_input"}
EOF
        return 1
    fi
    
    # Check cache first (never reuse a synthetic result unless allowed)
    if _regime_load_cache_if_ok "$symbol"; then
        return 0
    fi
    
    # Apply Kalman filter to prices
    local kalman_result=$(apply_kalman_filter "${prices[@]}" -q 0.01 -r 0.1)
    
    # Extract filtered prices and residuals. The Python backend emits
    # multi-line JSON, so parse with jq (grep -P is unavailable on macOS).
    local -a filtered_prices=($(echo "$kalman_result" | jq -r '(.filtered_prices // [])[]' 2>/dev/null))
    local -a residuals=($(echo "$kalman_result" | jq -r '(.residuals // [])[]' 2>/dev/null))
    
    # Calculate noise level (volatility of residuals)
    local noise_level=0
    if [[ ${#residuals[@]} -gt 1 ]]; then
        noise_level=$(calc_residual_volatility "${residuals[@]}")
    fi
    
    # EMAs on raw and filtered prices (mean fallback when data is short)
    local ema_20_raw=$(_regime_ema_or_mean 20 "${prices[@]}")
    local ema_50_raw=$(_regime_ema_or_mean 50 "${prices[@]}")
    local ema_20_filtered=$(_regime_ema_or_mean 20 "${filtered_prices[@]}")
    local ema_50_filtered=$(_regime_ema_or_mean 50 "${filtered_prices[@]}")
    
    # Set defaults if empty
    if [[ -z "$ema_20_raw" ]] || [[ -z "$ema_50_raw" ]]; then
        ema_20_raw=100
        ema_50_raw=100
    fi
    
    if [[ -z "$ema_20_filtered" ]] || [[ -z "$ema_50_filtered" ]]; then
        ema_20_filtered=100
        ema_50_filtered=100
    fi
    
    # Detect trends from both raw and filtered prices
    local raw_trend=$(detect_trend_direction "$ema_20_raw" "$ema_50_raw")
    local filtered_trend=$(detect_trend_direction "$ema_20_filtered" "$ema_50_filtered")
    
    # Calculate ADX from EMAs (same approximation as detect_market_regime)
    local adx=$(_regime_adx_from_emas "$ema_20_raw" "$ema_50_raw")
    
    # Determine regime using Kalman-filtered trend (more reliable)
    local regime="sideways"
    
    if _regime_gt "$noise_level" 2; then
        regime="volatile"
    elif _regime_gt "$adx" 25; then
        if [[ "$filtered_trend" == "up" ]]; then
            regime="trending_bull"
        elif [[ "$filtered_trend" == "down" ]]; then
            regime="trending_bear"
        fi
    else
        regime="sideways"
    fi
    
    # Format output
    local adx_safe=$(printf "%.2f" "${adx:-0}")
    local noise_safe=$(printf "%.6f" "${noise_level:-0}")
    local ema_20_raw_safe=$(printf "%.2f" "${ema_20_raw:-100}")
    local ema_50_raw_safe=$(printf "%.2f" "${ema_50_raw:-100}")
    local ema_20_filtered_safe=$(printf "%.2f" "${ema_20_filtered:-100}")
    local ema_50_filtered_safe=$(printf "%.2f" "${ema_50_filtered:-100}")
    
    local regime_json=$(cat <<EOF
{
  "regime": "$regime",
  "adx": $adx_safe,
  "trend": "$filtered_trend",
  "raw_trend": "$raw_trend",
  "kalman_trend": "$filtered_trend",
  "volatility": $noise_safe,
  "ema_20_raw": $ema_20_raw_safe,
  "ema_50_raw": $ema_50_raw_safe,
  "ema_20_filtered": $ema_20_filtered_safe,
  "ema_50_filtered": $ema_50_filtered_safe,
  "noise_level": $noise_safe,
  "price_count": ${#prices[@]},
  "data_source": "caller",
  "symbol": "$symbol",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)
    
    # Cache the result
    cache_regime "$symbol" "$regime_json"
    
    echo "$regime_json"
}

# ============================================================================
# Batch Regime Detection
# ============================================================================

# Detect regimes for multiple symbols
# Args: symbols (comma or space-separated)
# Returns: JSON array of regime data
detect_regimes_batch() {
    local symbols_str=$1
    
    if [[ -z "$symbols_str" ]]; then
        echo "[]"
        return 0
    fi
    
    # Convert comma-separated to array
    local -a symbols=(${symbols_str//,/ })
    local regimes="["
    
    for symbol in "${symbols[@]}"; do
        local regime=$(detect_market_regime "$symbol")
        regimes="${regimes}${regime},"
    done
    
    # Remove trailing comma
    regimes="${regimes%,}]"
    echo "$regimes"
}

# ============================================================================
# Cache Management Utilities
# ============================================================================

# Clear regime cache for a symbol
# Args: symbol (optional; clears all if empty)
# Returns: void
clear_regime_cache() {
    local symbol=$1
    
    if [[ -z "$symbol" ]]; then
        rm -f "$REGIME_CACHE_DIR"/*.regime 2>/dev/null
    else
        rm -f "$(get_regime_cache_file "$symbol")" 2>/dev/null
    fi
}

# Export functions
export -f detect_market_regime detect_regimes_batch detect_market_regime_kalman
export -f calc_adx_approx calc_bb_width_pct detect_trend_direction
export -f cache_regime load_regime_from_cache is_regime_cache_valid clear_regime_cache
