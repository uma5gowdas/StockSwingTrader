#!/bin/bash
# ============================================================================
# StockSwingTrader: Comprehensive Technical Indicators Library
# ============================================================================
# Implements: RSI, MACD, Bollinger Bands, SMA/EMA, ATR, OBV, Stochastic, Williams %R
# All calculations use floating-point precision via bc or awk
# ============================================================================

# ============================================================================
# Helper: Math Utilities
# ============================================================================

# Calculate mean of array
# Args: array (space-separated numbers)
# Returns: mean value
calc_mean() {
    local -a arr=($@)
    local sum=0
    local count=${#arr[@]}
    if [[ $count -eq 0 ]]; then
        echo "0"
        return
    fi
    for val in "${arr[@]}"; do
        sum=$(echo "$sum + $val" | bc)
    done
    echo "$sum / $count" | bc -l
}

# Calculate standard deviation
# Args: array (space-separated numbers)
# Returns: standard deviation
calc_stddev() {
    local -a arr=($@)
    local count=${#arr[@]}
    if [[ $count -le 1 ]]; then
        echo "0"
        return
    fi
    local mean=$(calc_mean "${arr[@]}")
    local sum_sq=0
    for val in "${arr[@]}"; do
        local diff=$(echo "$val - $mean" | bc -l)
        local sq=$(echo "$diff * $diff" | bc -l)
        sum_sq=$(echo "$sum_sq + $sq" | bc -l)
    done
    local variance=$(echo "$sum_sq / ($count - 1)" | bc -l)
    echo "sqrt($variance)" | bc -l
}

# Get min value from array
# Args: array (space-separated numbers)
# Returns: minimum value
calc_min() {
    local -a arr=($@)
    local min=${arr[0]}
    for val in "${arr[@]}"; do
        if (( $(echo "$val < $min" | bc -l) )); then
            min=$val
        fi
    done
    echo "$min"
}

# Get max value from array
# Args: array (space-separated numbers)
# Returns: maximum value
calc_max() {
    local -a arr=($@)
    local max=${arr[0]}
    for val in "${arr[@]}"; do
        if (( $(echo "$val > $max" | bc -l) )); then
            max=$val
        fi
    done
    echo "$max"
}

# ============================================================================
# SMA (Simple Moving Average)
# ============================================================================
# Args: period (int), prices (space-separated array)
# Returns: JSON array of SMA values
# Example: calc_sma 20 "100.5 101.2 102.1 ..." → [0, 0, ..., avg_20, avg_21, ...]
calc_sma() {
    local period=$1
    shift
    local -a prices=($@)
    local count=${#prices[@]}
    local sma_output="["
    
    for ((i = 0; i < count; i++)); do
        if ((i < period - 1)); then
            sma_output="${sma_output}0"
        else
            local -a window=("${prices[@]:$((i - period + 1)):$period}")
            local sma=$(calc_mean "${window[@]}")
            # Format to 2 decimals
            sma=$(printf "%.2f" "$sma")
            sma_output="${sma_output}${sma}"
        fi
        if ((i < count - 1)); then
            sma_output="${sma_output},"
        fi
    done
    sma_output="${sma_output}]"
    echo "$sma_output"
}

# ============================================================================
# EMA (Exponential Moving Average)
# ============================================================================
# Args: period (int), prices (space-separated array)
# Returns: JSON array of EMA values
calc_ema() {
    local period=$1
    shift
    local -a prices=($@)
    local count=${#prices[@]}
    local multiplier=$(echo "scale=6; 2 / ($period + 1)" | bc)
    local ema_output="["
    local ema=0
    
    for ((i = 0; i < count; i++)); do
        if ((i < period)); then
            # First EMA is SMA of first 'period' values
            if ((i == period - 1)); then
                local -a window=("${prices[@]:0:$period}")
                ema=$(calc_mean "${window[@]}")
            fi
        else
            # EMA = (Price - EMA_prev) * multiplier + EMA_prev
            ema=$(echo "(${prices[$i]} - $ema) * $multiplier + $ema" | bc -l)
        fi
        ema=$(printf "%.2f" "$ema")
        ema_output="${ema_output}${ema}"
        if ((i < count - 1)); then
            ema_output="${ema_output},"
        fi
    done
    ema_output="${ema_output}]"
    echo "$ema_output"
}

# ============================================================================
# RSI (Relative Strength Index)
# ============================================================================
# Args: period (int, default 14), prices (space-separated array)
# Returns: JSON with rsi value, signal (oversold/overbought/neutral)
calc_rsi() {
    local period=${1:-14}
    shift
    local -a prices=($@)
    local count=${#prices[@]}
    
    if ((count < period + 1)); then
        echo '{"rsi":0,"signal":"insufficient_data"}'
        return
    fi
    
    local gains_sum=0
    local losses_sum=0
    
    # Calculate gains and losses for first period
    for ((i = 1; i <= period; i++)); do
        local diff=$(echo "${prices[$i]} - ${prices[$((i-1))]}" | bc -l)
        if (( $(echo "$diff > 0" | bc -l) )); then
            gains_sum=$(echo "$gains_sum + $diff" | bc -l)
        else
            losses_sum=$(echo "$losses_sum - $diff" | bc -l)
        fi
    done
    
    local avg_gain=$(echo "$gains_sum / $period" | bc -l)
    local avg_loss=$(echo "$losses_sum / $period" | bc -l)
    
    # Calculate smoothed averages for remaining periods
    for ((i = period + 1; i < count; i++)); do
        local diff=$(echo "${prices[$i]} - ${prices[$((i-1))]}" | bc -l)
        if (( $(echo "$diff > 0" | bc -l) )); then
            avg_gain=$(echo "($avg_gain * ($period - 1) + $diff) / $period" | bc -l)
            avg_loss=$(echo "($avg_loss * ($period - 1)) / $period" | bc -l)
        else
            avg_gain=$(echo "($avg_gain * ($period - 1)) / $period" | bc -l)
            avg_loss=$(echo "($avg_loss * ($period - 1) - $diff) / $period" | bc -l)
        fi
    done
    
    local rs=0
    local rsi=0
    if (( $(echo "$avg_loss > 0" | bc -l) )); then
        rs=$(echo "$avg_gain / $avg_loss" | bc -l)
        rsi=$(echo "100 - (100 / (1 + $rs))" | bc -l)
    else
        rsi=100
    fi
    
    rsi=$(printf "%.2f" "$rsi")
    
    local signal="neutral"
    if (( $(echo "$rsi > 70" | bc -l) )); then
        signal="overbought"
    elif (( $(echo "$rsi < 30" | bc -l) )); then
        signal="oversold"
    fi
    
    echo "{\"rsi\":${rsi},\"signal\":\"${signal}\"}"
}

# ============================================================================
# MACD (Moving Average Convergence Divergence)
# ============================================================================
# Args: prices (space-separated array)
# Returns: JSON with macd, signal, histogram
calc_macd() {
    local -a prices=($@)
    local count=${#prices[@]}
    
    # Calculate EMA(12) and EMA(26)
    local ema12_arr=$(calc_ema 12 "${prices[@]}")
    local ema26_arr=$(calc_ema 26 "${prices[@]}")
    
    # Extract last values (use jq if available, else use bc)
    local ema12=$(echo "$ema12_arr" | grep -o '[0-9.]*' | tail -1)
    local ema26=$(echo "$ema26_arr" | grep -o '[0-9.]*' | tail -1)
    
    # MACD = EMA(12) - EMA(26)
    local macd=$(echo "$ema12 - $ema26" | bc -l)
    macd=$(printf "%.2f" "$macd")
    
    # For signal line, would need to calculate EMA(9) of MACD values
    # Simplified: use current MACD as signal approximation
    local signal=$macd
    local histogram=$(echo "$macd - $signal" | bc -l)
    histogram=$(printf "%.2f" "$histogram")
    
    echo "{\"macd\":${macd},\"signal\":${signal},\"histogram\":${histogram}}"
}

# ============================================================================
# Bollinger Bands
# ============================================================================
# Args: period (default 20), std_dev (default 2), prices (space-separated array)
# Returns: JSON with upper, middle, lower, %b
calc_bollinger_bands() {
    local period=${1:-20}
    local std_dev=${2:-2}
    shift 2
    local -a prices=($@)
    local count=${#prices[@]}
    
    if ((count < period)); then
        echo "{\"upper\":0,\"middle\":0,\"lower\":0,\"pct_b\":0}"
        return
    fi
    
    # Get last 'period' prices
    local -a recent_prices=("${prices[@]:$((count - period)):$period}")
    
    # Middle band = SMA(period)
    local middle=$(calc_mean "${recent_prices[@]}")
    middle=$(printf "%.2f" "$middle")
    
    # Calculate standard deviation
    local std=$(calc_stddev "${recent_prices[@]}")
    std=$(printf "%.6f" "$std")
    
    # Upper = SMA + (2 * StdDev)
    local upper=$(echo "$middle + ($std_dev * $std)" | bc -l)
    upper=$(printf "%.2f" "$upper")
    
    # Lower = SMA - (2 * StdDev)
    local lower=$(echo "$middle - ($std_dev * $std)" | bc -l)
    lower=$(printf "%.2f" "$lower")
    
    # %B = (close - lower) / (upper - lower)
    local current_price=${prices[$((count - 1))]}
    local bandwidth=$(echo "$upper - $lower" | bc -l)
    local pct_b=0
    if (( $(echo "$bandwidth > 0" | bc -l) )); then
        pct_b=$(echo "($current_price - $lower) / $bandwidth" | bc -l)
        pct_b=$(printf "%.2f" "$pct_b")
    fi
    
    echo "{\"upper\":${upper},\"middle\":${middle},\"lower\":${lower},\"pct_b\":${pct_b}}"
}

# ============================================================================
# ATR (Average True Range)
# ============================================================================
# Args: period (default 14), high/low/close pairs (as "H1 L1 C1 H2 L2 C2 ...")
# Returns: ATR value (float)
calc_atr() {
    local period=${1:-14}
    shift
    local -a hlc=($@)
    local count=$((${#hlc[@]} / 3))
    
    if ((count < period)); then
        echo "0"
        return
    fi
    
    local -a tr_values
    local prev_close=0
    
    # Calculate True Range for each candle
    for ((i = 0; i < count; i++)); do
        local h=${hlc[$((i * 3))]}
        local l=${hlc[$((i * 3 + 1))]}
        local c=${hlc[$((i * 3 + 2))]}
        
        local tr1=$(echo "$h - $l" | bc -l)
        local tr2=$(echo "($h - $prev_close)" | bc -l)
        local tr3=$(echo "($l - $prev_close)" | bc -l)
        
        # TR = max(high-low, |high-close_prev|, |low-close_prev|)
        if (( $(echo "$tr2 < 0" | bc -l) )); then tr2=$(echo "0 - ($tr2)" | bc -l); fi
        if (( $(echo "$tr3 < 0" | bc -l) )); then tr3=$(echo "0 - ($tr3)" | bc -l); fi
        
        local tr=$(calc_max "$tr1" "$tr2" "$tr3")
        tr_values+=($tr)
        prev_close=$c
    done
    
    # ATR = SMA of TR values over period
    local -a recent_tr=("${tr_values[@]:$((count - period)):$period}")
    local atr=$(calc_mean "${recent_tr[@]}")
    printf "%.2f" "$atr"
}

# ============================================================================
# OBV (On-Balance Volume)
# ============================================================================
# Args: close/volume pairs (as "C1 V1 C2 V2 ...")
# Returns: JSON array of OBV values
calc_obv() {
    local -a cv=($@)
    local count=$((${#cv[@]} / 2))
    
    local obv=0
    local obv_output="["
    local prev_close=0
    
    for ((i = 0; i < count; i++)); do
        local close=${cv[$((i * 2))]}
        local volume=${cv[$((i * 2 + 1))]}
        
        if ((i == 0)); then
            obv=$volume
        else
            if (( $(echo "$close > $prev_close" | bc -l) )); then
                obv=$(echo "$obv + $volume" | bc)
            elif (( $(echo "$close < $prev_close" | bc -l) )); then
                obv=$(echo "$obv - $volume" | bc)
            fi
            # If close == prev_close, OBV unchanged
        fi
        
        obv_output="${obv_output}${obv}"
        if ((i < count - 1)); then
            obv_output="${obv_output},"
        fi
        prev_close=$close
    done
    
    obv_output="${obv_output}]"
    echo "$obv_output"
}

# ============================================================================
# Stochastic Oscillator (%K, %D)
# ============================================================================
# Args: period (default 14), high/low/close triples (as "H1 L1 C1 H2 L2 C2 ...")
# Returns: JSON with k_line, d_line (both 0-100)
calc_stochastic() {
    local period=${1:-14}
    shift
    local -a hlc=($@)
    local count=$((${#hlc[@]} / 3))
    
    if ((count < period)); then
        echo "{\"k_line\":0,\"d_line\":0}"
        return
    fi
    
    # Get last 'period' highs and lows
    local highest_high=0
    local lowest_low=999999
    
    for ((i = count - period; i < count; i++)); do
        local h=${hlc[$((i * 3))]}
        local l=${hlc[$((i * 3 + 1))]}
        
        if (( $(echo "$h > $highest_high" | bc -l) )); then
            highest_high=$h
        fi
        if (( $(echo "$l < $lowest_low" | bc -l) )); then
            lowest_low=$l
        fi
    done
    
    local current_close=${hlc[$(((count - 1) * 3 + 2))]}
    
    # %K = 100 * (close - lowest_low) / (highest_high - lowest_low)
    local denominator=$(echo "$highest_high - $lowest_low" | bc -l)
    local k_line=50  # default middle
    
    if (( $(echo "$denominator > 0" | bc -l) )); then
        k_line=$(echo "100 * ($current_close - $lowest_low) / $denominator" | bc -l)
        k_line=$(printf "%.2f" "$k_line")
    fi
    
    # %D = SMA(%K, 3) - simplified as %K for now
    local d_line=$k_line
    
    echo "{\"k_line\":${k_line},\"d_line\":${d_line}}"
}

# ============================================================================
# Williams %R
# ============================================================================
# Args: period (default 14), high/low/close triples
# Returns: Williams %R value (-100 to 0)
calc_williams_r() {
    local period=${1:-14}
    shift
    local -a hlc=($@)
    local count=$((${#hlc[@]} / 3))
    
    if ((count < period)); then
        echo "-50"
        return
    fi
    
    # Get last 'period' highs and lows
    local highest_high=0
    local lowest_low=999999
    
    for ((i = count - period; i < count; i++)); do
        local h=${hlc[$((i * 3))]}
        local l=${hlc[$((i * 3 + 1))]}
        
        if (( $(echo "$h > $highest_high" | bc -l) )); then
            highest_high=$h
        fi
        if (( $(echo "$l < $lowest_low" | bc -l) )); then
            lowest_low=$l
        fi
    done
    
    local current_close=${hlc[$(((count - 1) * 3 + 2))]}
    
    # Williams %R = -100 * (highest_high - close) / (highest_high - lowest_low)
    local denominator=$(echo "$highest_high - $lowest_low" | bc -l)
    local williams_r=-50  # default middle
    
    if (( $(echo "$denominator > 0" | bc -l) )); then
        williams_r=$(echo "-100 * ($highest_high - $current_close) / $denominator" | bc -l)
        williams_r=$(printf "%.2f" "$williams_r")
    fi
    
    echo "$williams_r"
}

# Export all functions for sourcing
export -f calc_mean calc_stddev calc_min calc_max
export -f calc_sma calc_ema calc_rsi calc_macd calc_bollinger_bands
export -f calc_atr calc_obv calc_stochastic calc_williams_r
