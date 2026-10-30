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
source "$(dirname "${BASH_SOURCE[0]}")/indicators.sh" 2>/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/trading_thresholds.sh" 2>/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/kalman_filter.sh" 2>/dev/null

# Cache directory setup
REGIME_CACHE_DIR="${HOME}/.stockswingtrader/regime_cache"
REGIME_CACHE_TTL=900  # 15 minutes in seconds

mkdir -p "$REGIME_CACHE_DIR"

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
    
    local file_age=$(($(date +%s) - $(stat -f%m "$cache_file" 2>/dev/null || stat -c%Y "$cache_file" 2>/dev/null || echo 0)))
    
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
    
    # Calculate simple trend strength based on EMA separation
    local diff=$((ema_20 - ema_50))
    
    # Avoid negative, use absolute value
    if [[ $diff -lt 0 ]]; then
        diff=$((-diff))
    fi
    
    # Scale to 0-100: higher EMA separation = stronger trend
    # Basic scaling: multiply by a factor and cap at 100
    local trend_strength=$((diff * 10))
    
    if [[ $trend_strength -gt 100 ]]; then
        echo "100"
    else
        echo "$trend_strength"
    fi
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
# Args: symbol, lookback_days (default 30)
# Returns: JSON {regime, adx, trend, volatility, timestamp}
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
    
    # Check cache first
    if is_regime_cache_valid "$symbol"; then
        load_regime_from_cache "$symbol"
        return 0
    fi
    
    # In production, would fetch real OHLC data via API
    # For now, use mock data structure
    
    # Mock data setup (in production, fetch from broker API)
    # This allows testing the regime logic
    local -a mock_closes=(100.5 101.2 100.8 101.5 102.0 101.8 102.5 103.0 102.8 103.5
                          104.0 103.2 103.8 104.5 105.0 104.8 105.5 106.0 105.8 106.5
                          107.0 106.8 107.5 108.0 107.8 108.5 109.0 108.8 109.5 110.0)
    
    # Calculate indicators
    local ema_20_str=$(calc_ema 20 "${mock_closes[@]}")
    local ema_50_str=$(calc_ema 50 "${mock_closes[@]}" 2>/dev/null || echo "[$(printf ',0%.0s' {1..49})0]")
    
    # Extract last EMA values
    local ema_20=$(echo "$ema_20_str" | grep -o '[0-9.]*' | tail -1)
    local ema_50=$(echo "$ema_50_str" | grep -o '[0-9.]*' | tail -1)
    
    if [[ -z "$ema_20" ]] || [[ -z "$ema_50" ]]; then
        ema_20=100
        ema_50=100
    fi
    
    # Get Bollinger Bands
    local bb_json=$(calc_bollinger_bands 20 2 "${mock_closes[@]}")
    local bb_upper=$(echo "$bb_json" | grep -o '"upper":[0-9.]*' | cut -d: -f2)
    local bb_middle=$(echo "$bb_json" | grep -o '"middle":[0-9.]*' | cut -d: -f2)
    local bb_lower=$(echo "$bb_json" | grep -o '"lower":[0-9.]*' | cut -d: -f2)
    
    if [[ -z "$bb_middle" ]]; then
        bb_middle=100
        bb_upper=110
        bb_lower=90
    fi
    
    # Calculate ADX approximation (simplified)
    local adx=50  # Default middle value
    local diff=$((ema_20 - ema_50))
    if [[ $diff -lt 0 ]]; then
        diff=$((-diff))
    fi
    adx=$((diff * 10))
    if [[ $adx -gt 100 ]]; then
        adx=100
    fi
    
    # Calculate BB width percentage (simplified)
    local volatility=50  # Default middle value
    if [[ -n "$bb_middle" && "$bb_middle" != "0" ]]; then
        local bb_width=$((bb_upper - bb_lower))
        volatility=$((bb_width * 100 / bb_middle))
        if [[ $volatility -gt 100 ]]; then
            volatility=100
        fi
    fi
    
    # Detect trend direction
    local trend=$(detect_trend_direction "$ema_20" "$ema_50")
    
    # Determine regime type
    local regime="sideways"
    
    # Check for high volatility first (overrides other regimes)
    if [[ $volatility -gt 20 ]]; then
        regime="volatile"
    # Check for trending conditions
    elif [[ $adx -gt 25 ]]; then
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
    
    # Check cache first
    if is_regime_cache_valid "$symbol"; then
        load_regime_from_cache "$symbol"
        return 0
    fi
    
    # Apply Kalman filter to prices
    local kalman_result=$(apply_kalman_filter "${prices[@]}" -q 0.01 -r 0.1)
    
    # Extract filtered prices
    local filtered_json=$(echo "$kalman_result" | grep -oP '"filtered_prices":\s*\K\[[^\]]*\]')
    local -a filtered_prices=($(echo "$filtered_json" | grep -oE '[0-9]+(\.[0-9]+)?' | tr '\n' ' '))
    
    # Extract residuals for noise level
    local residuals_json=$(echo "$kalman_result" | grep -oP '"residuals":\s*\K\[[^\]]*\]')
    local -a residuals=($(echo "$residuals_json" | grep -oE '-?[0-9]+(\.[0-9]+)?' | tr '\n' ' '))
    
    # Calculate noise level (volatility of residuals)
    local noise_level=0
    if [[ ${#residuals[@]} -gt 1 ]]; then
        noise_level=$(calc_residual_volatility "${residuals[@]}")
    fi
    
    # Calculate EMAs on raw prices
    local ema_20_raw_str=$(calc_ema 20 "${prices[@]}")
    local ema_50_raw_str=$(calc_ema 50 "${prices[@]}" 2>/dev/null || echo "[0]")
    
    # Extract EMA values
    local ema_20_raw=$(echo "$ema_20_raw_str" | grep -o '[0-9.]*' | tail -1)
    local ema_50_raw=$(echo "$ema_50_raw_str" | grep -o '[0-9.]*' | tail -1)
    
    # Calculate EMAs on filtered prices
    local ema_20_filtered_str=$(calc_ema 20 "${filtered_prices[@]}")
    local ema_50_filtered_str=$(calc_ema 50 "${filtered_prices[@]}" 2>/dev/null || echo "[0]")
    
    # Extract filtered EMA values
    local ema_20_filtered=$(echo "$ema_20_filtered_str" | grep -o '[0-9.]*' | tail -1)
    local ema_50_filtered=$(echo "$ema_50_filtered_str" | grep -o '[0-9.]*' | tail -1)
    
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
    
    # Calculate ADX from EMAs
    local adx=$((10 * ((ema_20_raw - ema_50_raw) / 10)))
    if [[ $adx -lt 0 ]]; then
        adx=$((-adx))
    fi
    if [[ $adx -gt 100 ]]; then
        adx=100
    fi
    
    # Determine regime using Kalman-filtered trend (more reliable)
    local regime="sideways"
    local volatility=50
    
    if [[ $(echo "$noise_level > 2" | bc -l) -eq 1 ]]; then
        regime="volatile"
    elif [[ $adx -gt 25 ]]; then
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
