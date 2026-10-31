#!/bin/bash
# ============================================================================
# StockSwingTrader: Kalman Filter for Price Smoothing
# ============================================================================
# Implements 1D Kalman filter to smooth price data and reduce noise
# 
# Kalman Filter Benefits:
#   - Reduces false signals from market noise
#   - Provides state estimation with uncertainty quantification
#   - Optimal for linear systems (prices tend to be locally linear)
#   - Low computational overhead
#
# Parameters:
#   - q (process noise): 0.01 (default) - how much prices can change naturally
#   - r (measurement noise): 0.1 (default) - how much we trust price measurements
#
# Lower q = trust price changes less, smoother output but lag
# Higher r = trust price measurements less, smoother output but higher lag
# ============================================================================

# ============================================================================
# 1D Kalman Filter Implementation (Python-backed for precision)
# ============================================================================

# Apply Kalman filter to price array
# Args: 
#   - price_array: space-separated prices
#   - q: process noise (default 0.01)
#   - r: measurement noise (default 0.1)
# Returns: JSON {"filtered_prices": [...], "state": final_state, "covariance": final_covariance, "residuals": [...]}
apply_kalman_filter() {
    local -a prices=()
    local q=0.01
    local r=0.1
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -q|--process-noise)
                q="$2"
                shift 2
                ;;
            -r|--measurement-noise)
                r="$2"
                shift 2
                ;;
            *)
                prices+=("$1")
                shift
                ;;
        esac
    done
    
    if [[ ${#prices[@]} -eq 0 ]]; then
        echo '{"filtered_prices": [], "state": 0, "covariance": 0, "residuals": [], "error": "empty_input"}'
        return 1
    fi
    
    # Use Python for accurate floating-point calculations
    if command -v python3 &>/dev/null; then
        local price_json=$(printf '[%s]' "$(IFS=,; echo "${prices[*]}")")
        local result=$(echo "$price_json" | python3 "$(dirname "${BASH_SOURCE[0]}")/kalman_inference.py" "$q" "$r" 2>/dev/null)
        if [[ $? -eq 0 && -n "$result" ]]; then
            echo "$result"
            return 0
        fi
    fi
    
    # Fallback: simple Kalman implementation in bash (less precision)
    local x=${prices[0]}
    local p=1.0
    local -a filtered=()
    local -a residuals=()
    
    filtered+=("${prices[0]}")
    residuals+=("0")
    
    for ((i = 1; i < ${#prices[@]}; i++)); do
        local z=${prices[$i]}
        local x_pred=$x
        local p_pred=$(echo "$p + $q" | awk '{printf "%.6f", $0}')
        local y=$(echo "$z - $x_pred" | awk '{printf "%.6f", $0}')
        local s=$(echo "$p_pred + $r" | awk '{printf "%.6f", $0}')
        local k=$(echo "$p_pred / $s" | awk '{printf "%.6f", $0}')
        x=$(echo "$x_pred + $k * $y" | awk '{printf "%.6f", $0}')
        p=$(echo "(1 - $k) * $p_pred" | awk '{printf "%.6f", $0}')
        
        filtered+=("$x")
        residuals+=("$y")
    done
    
    # Build JSON output
    local json_filtered=$(IFS=, ; printf '%s' "${filtered[*]}")
    local json_residuals=$(IFS=, ; printf '%s' "${residuals[*]}")
    
    cat <<EOF
{
  "filtered_prices": [$json_filtered],
  "state": $x,
  "covariance": $p,
  "residuals": [$json_residuals],
  "q": $q,
  "r": $r,
  "count": ${#prices[@]}
}
EOF
}

# ============================================================================
# Kalman Filter Utilities
# ============================================================================

# Calculate volatility from residuals
# Args: residuals (space-separated)
# Returns: volatility (standard deviation of residuals)
calc_residual_volatility() {
    local -a residuals=($@)
    
    if [[ ${#residuals[@]} -lt 2 ]]; then
        echo "0"
        return
    fi
    
    # Use awk for accurate calculation
    awk -v data="${residuals[*]}" 'BEGIN {
        n = split(data, arr, " ")
        sum = 0
        for (i = 1; i <= n; i++) {
            val = arr[i]
            if (val < 0) val = -val
            sum += val
        }
        mean = sum / n
        sum_sq = 0
        for (i = 1; i <= n; i++) {
            val = arr[i]
            if (val < 0) val = -val
            diff = val - mean
            sum_sq += diff * diff
        }
        variance = sum_sq / (n - 1)
        printf "%.6f\n", sqrt(variance)
    }'
}

# Compare smoothness: raw prices vs filtered prices
# Args: raw_prices (array), filtered_prices (array)
# Returns: improvement percentage
compare_smoothness() {
    awk 'BEGIN {
        # Not implemented in bash - use Python version
        print "0"
    }'
}

# ============================================================================
# Batch Processing with Python Accelerator
# ============================================================================

# Apply Kalman filter with Python backend for better performance
# Args: 
#   - price_json: JSON array of prices
#   - q: process noise (default 0.01)
#   - r: measurement noise (default 0.1)
# Returns: JSON result (same as apply_kalman_filter)
apply_kalman_filter_fast() {
    local price_json=$1
    local q=${2:-0.01}
    local r=${3:-0.1}
    
    # Try to use Python backend if available
    if command -v python3 &>/dev/null && [[ -f "$(dirname "${BASH_SOURCE[0]}")/kalman_inference.py" ]]; then
        echo "$price_json" | python3 "$(dirname "${BASH_SOURCE[0]}")/kalman_inference.py" "$q" "$r" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            return 0
        fi
    fi
    
    # Fall back to bash implementation
    local -a prices=()
    
    # Extract numbers from JSON array [n1, n2, n3, ...]
    prices=($(echo "$price_json" | grep -oE '[0-9]+(\.[0-9]+)?' | tr '\n' ' '))
    
    if [[ ${#prices[@]} -eq 0 ]]; then
        echo '{"filtered_prices": [], "state": 0, "covariance": 0, "residuals": [], "error": "invalid_json"}'
        return 1
    fi
    
    apply_kalman_filter "${prices[@]}" -q "$q" -r "$r"
}

# ============================================================================
# Integration with Regime Detection
# ============================================================================

# Get Kalman-filtered prices for regime detection
# Args: symbol, lookback_days (default 30)
# Returns: JSON with filtered prices and residuals
#   There is no market data source here: the random-walk demo series is only
#   generated when synthetic data is allowed (SST_ALLOW_SYNTHETIC=1 or
#   SST_OFFLINE=1) and the output is marked "data_source": "synthetic".
#   Otherwise prints {"available": false, ...} and returns 1. For real data,
#   call apply_kalman_filter with the prices directly.
get_kalman_filtered_prices() {
    local symbol=$1
    local lookback_days=${2:-30}
    
    if [[ "${SST_OFFLINE:-0}" != "1" && "${SST_ALLOW_SYNTHETIC:-0}" != "1" ]]; then
        echo "{\"symbol\": \"${symbol}\", \"available\": false, \"reason\": \"no market data source; pass prices to apply_kalman_filter or set SST_ALLOW_SYNTHETIC=1 for demo data\", \"data_source\": null}"
        return 1
    fi
    
    # Synthetic random walk (explicitly allowed demo data)
    local -a synthetic_prices=()
    local base_price=100
    
    for ((i = 0; i < lookback_days * 24; i++)); do
        # Random walk with drift
        local change=$(echo "scale=2; (${RANDOM} / 32768 - 0.5) * 0.5" | bc -l)
        base_price=$(echo "$base_price + $change" | bc -l)
        synthetic_prices+=("$base_price")
    done
    
    # Apply Kalman filter and mark the output as synthetic
    apply_kalman_filter "${synthetic_prices[@]}" -q 0.01 -r 0.1 \
        | jq -c '. + {data_source: "synthetic", warning: "Filtered a SYNTHETIC random-walk series, not market data"}'
}

# ============================================================================
# Export functions
# ============================================================================

export -f apply_kalman_filter apply_kalman_filter_fast
export -f calc_residual_volatility compare_smoothness
export -f get_kalman_filtered_prices
