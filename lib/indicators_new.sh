#!/bin/bash
# ============================================================================
# StockSwingTrader v6.1: New Technical Indicators
# ============================================================================
# Implements: RSI Divergence, VWMA (Volume-Weighted MA), Momentum Oscillator
# All calculations use floating-point precision via bc
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/trading_thresholds.sh" 2>/dev/null

# ============================================================================
# Helper: Math Utilities (Extended)
# ============================================================================

# Calculate mean of array
calc_mean_new() {
    local -a arr=($@)
    local sum=0
    local count=${#arr[@]}
    if [[ $count -eq 0 ]]; then
        echo "0"
        return
    fi
    for val in "${arr[@]}"; do
        sum=$(echo "$sum + $val" | bc -l)
    done
    echo "scale=4; $sum / $count" | bc -l
}

# Calculate min with return status
calc_min_new() {
    local -a arr=($@)
    if [[ ${#arr[@]} -eq 0 ]]; then
        return 1
    fi
    local min=${arr[0]}
    for val in "${arr[@]}"; do
        if (( $(echo "$val < $min" | bc -l) )); then
            min=$val
        fi
    done
    echo "$min"
}

# Calculate max with return status
calc_max_new() {
    local -a arr=($@)
    if [[ ${#arr[@]} -eq 0 ]]; then
        return 1
    fi
    local max=${arr[0]}
    for val in "${arr[@]}"; do
        if (( $(echo "$val > $max" | bc -l) )); then
            max=$val
        fi
    done
    echo "$max"
}

# ============================================================================
# RSI Divergence Detection
# ============================================================================
# Detects bullish and bearish divergences between price and RSI
# Bullish divergence: Price makes lower low, RSI makes higher low (potential reversal up)
# Bearish divergence: Price makes higher high, RSI makes lower high (potential reversal down)

# Helper: Detect if a value is a swing low
# Args: idx (index), price_array (prices at each bar), lookback (bars to check)
# Returns: 1 if swing low, 0 if not
is_swing_low() {
    local idx=$1
    shift
    local -a prices=($@)
    local lookback=${RSI_DIV_LOOKBACK_PERIODS:-5}
    
    local max_idx=$((${#prices[@]} - lookback))
    if [[ $idx -lt $lookback ]] || [[ $idx -ge $max_idx ]]; then
        return 1
    fi
    
    local current=${prices[$idx]}
    local is_low=1
    
    # Check if lower than neighbors
    for ((i = idx - lookback; i <= idx + lookback; i++)); do
        if [[ $i -ne $idx ]]; then
            if (( $(echo "${prices[$i]} < $current" | bc -l) )); then
                is_low=0
                break
            fi
        fi
    done
    
    return $((1 - is_low))
}

# Helper: Detect if a value is a swing high
# Args: idx (index), price_array (prices at each bar), lookback (bars to check)
# Returns: 1 if swing high, 0 if not
is_swing_high() {
    local idx=$1
    shift
    local -a prices=($@)
    local lookback=${RSI_DIV_LOOKBACK_PERIODS:-5}
    
    local max_idx=$((${#prices[@]} - lookback))
    if [[ $idx -lt $lookback ]] || [[ $idx -ge $max_idx ]]; then
        return 1
    fi
    
    local current=${prices[$idx]}
    local is_high=1
    
    # Check if higher than neighbors
    for ((i = idx - lookback; i <= idx + lookback; i++)); do
        if [[ $i -ne $idx ]]; then
            if (( $(echo "${prices[$i]} > $current" | bc -l) )); then
                is_high=0
                break
            fi
        fi
    done
    
    return $((1 - is_high))
}

# Helper: Calculate divergence strength (0-100)
# Args: price_change, rsi_change
# Returns: Strength value
calc_div_strength() {
    local price_change=$1
    local rsi_change=$2
    
    # Divergence strength increases with price/RSI divergence
    local abs_price=$(echo "$price_change" | sed 's/-//')
    local abs_rsi=$(echo "$rsi_change" | sed 's/-//')
    
    # Scale to 0-100, max divergence would be both price/RSI moving 100 points opposite
    local strength=$(echo "scale=0; ($abs_rsi * 100) / 100" | bc -l)
    
    if [[ $strength -gt 100 ]]; then
        echo "100"
    else
        echo "$strength"
    fi
}

# Main: Detect RSI divergence
# Args: price_array (space-separated prices), rsi_array (space-separated RSI values)
# Returns: JSON object with divergence signals
# Example: result=$(calc_rsi_divergence "100 99 98 97 96" "45 40 35 32 28")
calc_rsi_divergence() {
    local -a prices=($1)
    local -a rsi_vals=($2)
    
    if [[ ${#prices[@]} -lt 10 ]] || [[ ${#rsi_vals[@]} -lt 10 ]]; then
        cat <<EOF
{"signal": "insufficient_data", "bullish_div": false, "bearish_div": false, "strength": 0}
EOF
        return
    fi
    
    # Initialize divergence tracking
    local bullish_div=false
    local bearish_div=false
    local strength=0
    local divergence_type="none"
    
    # Look for recent divergence in last 10 bars
    local lookback_idx=$((${#prices[@]} - 6))
    if [[ $lookback_idx -lt 5 ]]; then
        lookback_idx=5
    fi
    
    # Check for bullish divergence (price lower low, RSI higher low)
    if is_swing_low $lookback_idx "${prices[@]}"; then
        local prev_swing_idx=$((lookback_idx - 5))
        if [[ $prev_swing_idx -ge 0 ]] && is_swing_low $prev_swing_idx "${prices[@]}"; then
            local price_low_diff=$(echo "${prices[$lookback_idx]} - ${prices[$prev_swing_idx]}" | bc -l)
            local rsi_low_diff=$(echo "${rsi_vals[$lookback_idx]} - ${rsi_vals[$prev_swing_idx]}" | bc -l)
            
            # Bullish divergence: price makes lower low, RSI makes higher low
            if (( $(echo "$price_low_diff < 0 && $rsi_low_diff > 0" | bc -l) )); then
                bullish_div=true
                divergence_type="bullish"
                strength=$(calc_div_strength "$price_low_diff" "$rsi_low_diff")
            fi
        fi
    fi
    
    # Check for bearish divergence (price higher high, RSI lower high)
    if is_swing_high $lookback_idx "${prices[@]}"; then
        local prev_swing_idx=$((lookback_idx - 5))
        if [[ $prev_swing_idx -ge 0 ]] && is_swing_high $prev_swing_idx "${prices[@]}"; then
            local price_high_diff=$(echo "${prices[$lookback_idx]} - ${prices[$prev_swing_idx]}" | bc -l)
            local rsi_high_diff=$(echo "${rsi_vals[$lookback_idx]} - ${rsi_vals[$prev_swing_idx]}" | bc -l)
            
            # Bearish divergence: price makes higher high, RSI makes lower high
            if (( $(echo "$price_high_diff > 0 && $rsi_high_diff < 0" | bc -l) )); then
                bearish_div=true
                divergence_type="bearish"
                strength=$(calc_div_strength "$price_high_diff" "$rsi_high_diff")
            fi
        fi
    fi
    
    # Determine signal based on divergence
    local signal="neutral"
    if [[ "$bullish_div" == "true" ]]; then
        signal="buy"
    elif [[ "$bearish_div" == "true" ]]; then
        signal="sell"
    fi
    
    # Output JSON
    cat <<EOF
{
  "signal": "$signal",
  "divergence_type": "$divergence_type",
  "bullish_divergence": $bullish_div,
  "bearish_divergence": $bearish_div,
  "strength": $strength,
  "confidence": $strength
}
EOF
}

# ============================================================================
# VWMA (Volume-Weighted Moving Average)
# ============================================================================
# Calculates a volume-weighted MA where higher-volume bars have more weight
# Formula: VWMA = SUM(Price * Volume) / SUM(Volume)

# Main: Calculate volume-weighted moving average
# Args: prices (space-separated), volumes (space-separated), period
# Returns: JSON with VWMA value and signal
# Example: result=$(calc_vwma "100 101 102 103 104" "1000000 1100000 1050000 1200000 950000" 20)
calc_vwma() {
    local price_str="$1"
    local volume_str="$2"
    local period=${3:-$VWMA_PERIOD}
    
    # Split into arrays
    local -a prices=($price_str)
    local -a volumes=($volume_str)
    
    if [[ ${#prices[@]} -ne ${#volumes[@]} ]]; then
        cat <<EOF
{"signal": "error", "vwma": 0, "status": "price_volume_mismatch"}
EOF
        return 1
    fi
    
    if [[ ${#prices[@]} -lt $period ]]; then
        # Not enough data
        cat <<EOF
{"signal": "insufficient_data", "vwma": 0, "status": "need_more_bars"}
EOF
        return
    fi
    
    # Use most recent 'period' bars for VWMA calculation
    local start_idx=$((${#prices[@]} - period))
    local pv_sum=0
    local v_sum=0
    
    for ((i = start_idx; i < ${#prices[@]}; i++)); do
        local pv=$(echo "${prices[$i]} * ${volumes[$i]}" | bc -l)
        pv_sum=$(echo "$pv_sum + $pv" | bc -l)
        v_sum=$(echo "$v_sum + ${volumes[$i]}" | bc -l)
    done
    
    # Calculate VWMA
    if (( $(echo "$v_sum == 0" | bc -l) )); then
        cat <<EOF
{"signal": "error", "vwma": 0, "status": "zero_volume"}
EOF
        return 1
    fi
    
    local vwma=$(echo "scale=2; $pv_sum / $v_sum" | bc -l)
    local current_price=${prices[-1]}
    
    # Determine signal based on price position relative to VWMA
    local signal="at"
    local diff=$(echo "$current_price - $vwma" | bc -l)
    local diff_pct=$(echo "scale=4; ($diff / $vwma) * 100" | bc -l)
    
    if (( $(echo "$diff_pct > 1" | bc -l) )); then
        signal="above"
    elif (( $(echo "$diff_pct < -1" | bc -l) )); then
        signal="below"
    fi
    
    cat <<EOF
{
  "signal": "$signal",
  "vwma": $vwma,
  "current_price": $current_price,
  "difference_pct": $diff_pct,
  "status": "ok"
}
EOF
}

# ============================================================================
# Momentum Oscillator
# ============================================================================
# Measures the rate of change of price (momentum = current price - price N periods ago)
# Positive momentum = price going up, negative = price going down

# Helper: Calculate average daily change
# Args: price_array (space-separated prices)
# Returns: Average change between consecutive bars
calc_avg_daily_change() {
    local -a prices=($1)
    
    if [[ ${#prices[@]} -lt 2 ]]; then
        echo "0"
        return
    fi
    
    local changes_sum=0
    for ((i = 1; i < ${#prices[@]}; i++)); do
        local change=$(echo "${prices[$i]} - ${prices[$((i-1))]}" | bc -l)
        changes_sum=$(echo "$changes_sum + $change" | bc -l)
    done
    
    local avg=$(echo "scale=4; $changes_sum / (${#prices[@]} - 1)" | bc -l)
    echo "$avg"
}

# Main: Calculate momentum oscillator
# Args: price_array (space-separated prices), period (default 12)
# Returns: JSON with momentum value and trend
# Example: result=$(calc_momentum "100 101 102 103 104 105 106 107 108 109 110 111 112" 12)
calc_momentum() {
    local price_str="$1"
    local period=${2:-$MOMENTUM_PERIOD}
    
    local -a prices=($price_str)
    
    if [[ ${#prices[@]} -lt $period ]]; then
        cat <<EOF
{"signal": "insufficient_data", "momentum": 0, "trend": "unknown", "status": "need_more_bars"}
EOF
        return
    fi
    
    # Momentum = current price - price N periods ago
    local current_price=${prices[-1]}
    local prev_price=${prices[$((${#prices[@]} - period - 1))]}
    
    local momentum=$(echo "scale=4; $current_price - $prev_price" | bc -l)
    
    # Calculate momentum as percentage change
    local momentum_pct=$(echo "scale=4; ($momentum / $prev_price) * 100" | bc -l)
    
    # Determine trend based on momentum
    local trend="neutral"
    if (( $(echo "$momentum > 0" | bc -l) )); then
        trend="bullish"
    elif (( $(echo "$momentum < 0" | bc -l) )); then
        trend="bearish"
    fi
    
    # Calculate trend strength (0-100)
    local strength=$(echo "$momentum_pct" | sed 's/-//')
    if (( $(echo "$strength > 100" | bc -l) )); then
        strength=100
    fi
    strength=$(echo "scale=0; $strength" | bc -l)
    
    # Determine buy/sell signal based on momentum
    local signal="hold"
    if (( $(echo "$momentum > 0" | bc -l) )); then
        signal="buy"
    elif (( $(echo "$momentum < 0" | bc -l) )); then
        signal="sell"
    fi
    
    # Calculate average change for context
    local avg_change=$(calc_avg_daily_change "$price_str")
    
    cat <<EOF
{
  "signal": "$signal",
  "momentum": $momentum,
  "momentum_pct": $momentum_pct,
  "trend": "$trend",
  "strength": $strength,
  "avg_daily_change": $avg_change,
  "status": "ok"
}
EOF
}

# ============================================================================
# Composite: All New Indicators as One
# ============================================================================

# Calculate all three new indicators for a symbol
# Args: symbol, prices, volumes, rsi_values
# Returns: JSON object with all three indicators
calc_all_new_indicators() {
    local symbol=$1
    local prices_str="$2"
    local volumes_str="$3"
    local rsi_str="$4"
    
    if [[ -z "$prices_str" ]] || [[ -z "$volumes_str" ]] || [[ -z "$rsi_str" ]]; then
        cat <<EOF
{"symbol": "$symbol", "status": "insufficient_inputs"}
EOF
        return 1
    fi
    
    local rsi_div=$(calc_rsi_divergence "$prices_str" "$rsi_str")
    local vwma=$(calc_vwma "$prices_str" "$volumes_str" "$VWMA_PERIOD")
    local momentum=$(calc_momentum "$prices_str" "$MOMENTUM_PERIOD")
    
    cat <<EOF
{
  "symbol": "$symbol",
  "rsi_divergence": $rsi_div,
  "vwma": $vwma,
  "momentum": $momentum,
  "status": "ok"
}
EOF
}
