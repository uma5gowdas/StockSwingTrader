#!/bin/bash
# ============================================================================
# StockSwingTrader v6.1: Risk Management Module
# ============================================================================
# Purpose: Position sizing (Kelly Criterion), stop-loss/take-profit enforcement,
#          portfolio limits, daily drawdown monitoring, and position tracking
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/trading_thresholds.sh" 2>/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/alpaca_wrappers.sh" 2>/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/trade_journal.sh" 2>/dev/null

# ============================================================================
# Position Sizing - Kelly Criterion
# ============================================================================

# Calculate position size using Kelly Criterion
# Args: capital (account equity), risk_pct (% of capital at risk per trade)
# Returns: Position size in dollars
# Formula: f* = (bp - q) / b where f* = fraction to risk, b = odds, p = win %, q = loss %
# Simplified: position_size = capital * risk_pct * (win_rate * win_loss_ratio - (1 - win_rate)) / win_loss_ratio
calculate_position_size() {
    local capital=$1
    local risk_pct=$2
    
    if [[ -z "$capital" ]] || [[ -z "$risk_pct" ]]; then
        echo "0"
        return 1
    fi
    
    # Use conservative Kelly: Kelly / 4
    local kelly_fraction=$(echo "scale=4; (($KELLY_WIN_RATE * $KELLY_WIN_LOSS_RATIO - (1 - $KELLY_WIN_RATE)) / $KELLY_WIN_LOSS_RATIO) / $KELLY_CRITERION_DIVISOR" | bc -l)
    
    # Ensure fraction is between 0 and max risk percentage
    if (( $(echo "$kelly_fraction < 0" | bc -l) )); then
        kelly_fraction="0"
    fi
    
    if (( $(echo "$kelly_fraction > (1.0 - $(echo "scale=4; $risk_pct / 100" | bc -l))" | bc -l) )); then
        kelly_fraction=$(echo "scale=4; $risk_pct / 100" | bc -l)
    fi
    
    # Position size = capital * kelly_fraction
    local position_size=$(echo "scale=2; $capital * $kelly_fraction" | bc -l)
    echo "$position_size"
}

# Calculate position quantity based on entry and stop-loss prices
# Args: entry_price, stop_loss_price, position_size_dollars
# Returns: Quantity to buy
calculate_position_qty() {
    local entry_price=$1
    local stop_loss_price=$2
    local position_size=$3
    
    if [[ -z "$entry_price" ]] || [[ -z "$stop_loss_price" ]] || [[ -z "$position_size" ]]; then
        echo "0"
        return 1
    fi
    
    # Risk per share = entry - stop
    local risk_per_share=$(echo "scale=4; $entry_price - $stop_loss_price" | bc -l)
    
    if (( $(echo "$risk_per_share <= 0" | bc -l) )); then
        echo "0"
        return 1
    fi
    
    # Quantity = position_size / risk_per_share
    local qty=$(echo "scale=0; $position_size / $risk_per_share" | bc -l)
    
    # Floor to nearest integer
    echo "$qty"
}

# ============================================================================
# Stop-Loss & Take-Profit Enforcement
# ============================================================================

# Check if stop-loss has been hit
# Args: entry_price, current_price, stop_loss_pct
# Returns: JSON {hit: true/false, current_loss_pct: X}
enforce_stop_loss() {
    local entry_price=$1
    local current_price=$2
    local stop_loss_pct=$3
    
    if [[ -z "$entry_price" ]] || [[ -z "$current_price" ]] || [[ -z "$stop_loss_pct" ]]; then
        cat <<EOF
{"hit": false, "error": "missing_args"}
EOF
        return 1
    fi
    
    # Calculate loss percentage
    local loss_pct=$(echo "scale=4; (($current_price - $entry_price) / $entry_price) * 100" | bc -l)
    local stop_loss_threshold=$(echo "scale=4; -1 * $stop_loss_pct" | bc -l)
    
    # Check if loss exceeds stop-loss threshold
    local hit=false
    if (( $(echo "$loss_pct <= $stop_loss_threshold" | bc -l) )); then
        hit=true
    fi
    
    cat <<EOF
{
  "hit": $hit,
  "current_loss_pct": $loss_pct,
  "stop_loss_threshold": $stop_loss_threshold,
  "stop_price": $(echo "scale=2; $entry_price - ($entry_price * $stop_loss_pct / 100)" | bc -l)
}
EOF
}

# Check if take-profit target has been reached
# Args: entry_price, current_price, target_pct
# Returns: JSON {reached: true/false, current_gain_pct: X}
enforce_take_profit() {
    local entry_price=$1
    local current_price=$2
    local target_pct=$3
    
    if [[ -z "$entry_price" ]] || [[ -z "$current_price" ]] || [[ -z "$target_pct" ]]; then
        cat <<EOF
{"reached": false, "error": "missing_args"}
EOF
        return 1
    fi
    
    # Calculate gain percentage
    local gain_pct=$(echo "scale=4; (($current_price - $entry_price) / $entry_price) * 100" | bc -l)
    
    # Check if gain reaches target threshold
    local reached=false
    if (( $(echo "$gain_pct >= $target_pct" | bc -l) )); then
        reached=true
    fi
    
    cat <<EOF
{
  "reached": $reached,
  "current_gain_pct": $gain_pct,
  "target_threshold": $target_pct,
  "target_price": $(echo "scale=2; $entry_price + ($entry_price * $target_pct / 100)" | bc -l)
}
EOF
}

# ============================================================================
# Portfolio Limits
# ============================================================================

# Check if adding a new position would exceed portfolio limit
# Args: positions_list (JSON array), max_allowed_positions
# Returns: JSON {can_add: true/false, current_count: X, max: Y}
check_max_positions() {
    local positions_json=$1
    local max_allowed=$2
    
    if [[ -z "$positions_json" ]] || [[ -z "$max_allowed" ]]; then
        cat <<EOF
{"can_add": false, "error": "missing_args"}
EOF
        return 1
    fi
    
    # Parse position count
    local current_count=0
    if [[ "$positions_json" != "[]" ]] && [[ "$positions_json" != "null" ]]; then
        current_count=$(echo "$positions_json" | jq 'length' 2>/dev/null || echo "0")
    fi
    
    local can_add=true
    if [[ $current_count -ge $max_allowed ]]; then
        can_add=false
    fi
    
    cat <<EOF
{
  "can_add": $can_add,
  "current_count": $current_count,
  "max_allowed": $max_allowed,
  "remaining_slots": $((max_allowed - current_count))
}
EOF
}

# ============================================================================
# Daily Drawdown Monitoring
# ============================================================================

# Check if daily loss limit has been exceeded
# Args: starting_equity, current_equity, daily_loss_limit_pct
# Returns: JSON {limit_exceeded: true/false, current_loss_pct: X}
enforce_daily_drawdown_limit() {
    local starting_equity=$1
    local current_equity=$2
    local daily_loss_limit_pct=$3
    
    if [[ -z "$starting_equity" ]] || [[ -z "$current_equity" ]] || [[ -z "$daily_loss_limit_pct" ]]; then
        cat <<EOF
{"limit_exceeded": false, "error": "missing_args"}
EOF
        return 1
    fi
    
    # Calculate daily loss percentage
    local daily_loss_pct=$(echo "scale=4; (($starting_equity - $current_equity) / $starting_equity) * 100" | bc -l)
    
    # Check if loss exceeds limit
    local limit_exceeded=false
    if (( $(echo "$daily_loss_pct >= $daily_loss_limit_pct" | bc -l) )); then
        limit_exceeded=true
    fi
    
    cat <<EOF
{
  "limit_exceeded": $limit_exceeded,
  "current_loss_pct": $daily_loss_pct,
  "daily_loss_limit": $daily_loss_limit_pct,
  "status": "$([ "$limit_exceeded" = true ] && echo 'STOP_TRADING' || echo 'OK')"
}
EOF
}

# ============================================================================
# Position Monitoring
# ============================================================================

# Monitor all open positions and check stop-loss/take-profit
# Args: none (queries from alpaca_wrappers)
# Returns: JSON with monitoring results
monitor_all_positions() {
    local positions_json=$(alpaca_get_positions 2>/dev/null)
    
    if [[ -z "$positions_json" ]] || [[ "$positions_json" == "[]" ]]; then
        cat <<EOF
{
  "status": "no_positions",
  "positions_monitored": 0,
  "triggered": []
}
EOF
        return 0
    fi
    
    local triggered=()
    local position_count=$(echo "$positions_json" | jq 'length' 2>/dev/null)
    
    # Loop through each position
    for ((i = 0; i < position_count; i++)); do
        local symbol=$(echo "$positions_json" | jq -r ".[$i].symbol" 2>/dev/null)
        local qty=$(echo "$positions_json" | jq -r ".[$i].qty" 2>/dev/null)
        local entry_price=$(echo "$positions_json" | jq -r ".[$i].avg_fill_price" 2>/dev/null)
        local current_price=$(alpaca_get_current_price "$symbol" 2>/dev/null)
        
        # Query trade journal for stop/profit levels
        local trade_record=$(query_trade_journal "$symbol" 2>/dev/null)
        local stop_loss=$(echo "$trade_record" | jq -r '.stop_loss_price // empty' 2>/dev/null)
        local take_profit=$(echo "$trade_record" | jq -r '.take_profit_price // empty' 2>/dev/null)
        
        # Check stop-loss
        if [[ -n "$stop_loss" ]] && (( $(echo "$current_price <= $stop_loss" | bc -l) )); then
            triggered+=("{\"symbol\":\"$symbol\",\"type\":\"stop_loss\",\"price\":$current_price}")
        fi
        
        # Check take-profit
        if [[ -n "$take_profit" ]] && (( $(echo "$current_price >= $take_profit" | bc -l) )); then
            triggered+=("{\"symbol\":\"$symbol\",\"type\":\"take_profit\",\"price\":$current_price}")
        fi
    done
    
    # Output JSON with triggered positions
    local triggered_json="["
    for ((i = 0; i < ${#triggered[@]}; i++)); do
        triggered_json="${triggered_json}${triggered[$i]}"
        if [[ $((i + 1)) -lt ${#triggered[@]} ]]; then
            triggered_json="${triggered_json},"
        fi
    done
    triggered_json="${triggered_json}]"
    
    cat <<EOF
{
  "status": "ok",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "positions_monitored": $position_count,
  "triggered": $triggered_json
}
EOF
}

# ============================================================================
# Risk Level Configuration
# ============================================================================

# Get max positions based on risk level
# Args: risk_level (conservative|moderate|aggressive)
# Returns: Maximum allowed positions
get_max_positions_for_risk_level() {
    local risk_level=$1
    
    case "$risk_level" in
        conservative)
            echo $RISK_LEVEL_CONSERVATIVE_LIMIT
            ;;
        moderate)
            echo $RISK_LEVEL_MODERATE_LIMIT
            ;;
        aggressive)
            echo $RISK_LEVEL_AGGRESSIVE_LIMIT
            ;;
        *)
            echo $RISK_LEVEL_MODERATE_LIMIT
            ;;
    esac
}

# Get position risk percentage based on risk level
# Args: risk_level (conservative|moderate|aggressive)
# Returns: Risk percentage per trade
get_position_risk_pct_for_risk_level() {
    local risk_level=$1
    
    case "$risk_level" in
        conservative)
            echo $RISK_LEVEL_CONSERVATIVE_RISK_PCT
            ;;
        moderate)
            echo $RISK_LEVEL_MODERATE_RISK_PCT
            ;;
        aggressive)
            echo $RISK_LEVEL_AGGRESSIVE_RISK_PCT
            ;;
        *)
            echo $RISK_LEVEL_MODERATE_RISK_PCT
            ;;
    esac
}

# Get daily loss limit based on risk level
# Args: risk_level (conservative|moderate|aggressive)
# Returns: Daily loss limit percentage
get_daily_loss_limit_for_risk_level() {
    local risk_level=$1
    
    case "$risk_level" in
        conservative)
            echo $DAILY_LOSS_LIMIT_CONSERVATIVE_PCT
            ;;
        moderate)
            echo $DAILY_LOSS_LIMIT_MODERATE_PCT
            ;;
        aggressive)
            echo $DAILY_LOSS_LIMIT_AGGRESSIVE_PCT
            ;;
        *)
            echo $DAILY_LOSS_LIMIT_MODERATE_PCT
            ;;
    esac
}

# ============================================================================
# Rebalancing Check
# ============================================================================

# Check if portfolio should be rebalanced
# Args: positions_list (JSON array), threshold_pct (% deviation threshold)
# Returns: JSON {rebalance_needed: true/false, deviations: [...]}
rebalance_check() {
    local positions_json=$1
    local threshold_pct=${2:-5}
    
    if [[ -z "$positions_json" ]] || [[ "$positions_json" == "[]" ]]; then
        cat <<EOF
{"rebalance_needed": false, "reason": "no_positions"}
EOF
        return 0
    fi
    
    # Get total portfolio value
    local position_count=$(echo "$positions_json" | jq 'length' 2>/dev/null)
    local total_value=0
    
    for ((i = 0; i < position_count; i++)); do
        local position_value=$(echo "$positions_json" | jq -r ".[$i].market_value" 2>/dev/null)
        total_value=$(echo "$total_value + $position_value" | bc -l)
    done
    
    # Check each position's weight
    local rebalance_needed=false
    local deviations="["
    
    for ((i = 0; i < position_count; i++)); do
        local symbol=$(echo "$positions_json" | jq -r ".[$i].symbol" 2>/dev/null)
        local position_value=$(echo "$positions_json" | jq -r ".[$i].market_value" 2>/dev/null)
        local weight=$(echo "scale=2; ($position_value / $total_value) * 100" | bc -l)
        local target_weight=$(echo "scale=2; 100 / $position_count" | bc -l)
        local deviation=$(echo "scale=2; $weight - $target_weight" | bc -l)
        
        # Check if deviation exceeds threshold
        local abs_deviation=$(echo "$deviation" | sed 's/-//')
        if (( $(echo "$abs_deviation > $threshold_pct" | bc -l) )); then
            rebalance_needed=true
        fi
        
        deviations="${deviations}{\"symbol\":\"$symbol\",\"weight\":$weight,\"target\":$target_weight,\"deviation\":$deviation},"
    done
    
    # Remove trailing comma
    deviations="${deviations%,}]"
    
    cat <<EOF
{
  "rebalance_needed": $rebalance_needed,
  "total_positions": $position_count,
  "threshold_pct": $threshold_pct,
  "deviations": $deviations
}
EOF
}
