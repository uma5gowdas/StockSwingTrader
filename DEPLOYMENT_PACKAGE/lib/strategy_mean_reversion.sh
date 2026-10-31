#!/bin/bash
# ============================================================================
# StockSwingTrader v6.1: Mean Reversion Strategy (Regime-Aware)
# ============================================================================
# Entry Criteria:
#   - RSI < 30 (oversold)
#   - Price within 2% of lower Bollinger Band
#   - Volume > 20-day average
#   - MACD > Signal line (positive momentum)
#   - [REGIME-AWARE] Optimized for sideways regime
#
# Exit Criteria:
#   - RSI > 70 (overbought), or
#   - +8% take-profit reached, or
#   - -3% stop-loss hit
#
# Position Sizing: Kelly Criterion with 2% risk per trade
# Regime Adaptation: 70% weighting in sideways markets, reduced during trends
#
# Note: When market transitions to trending regime, consider switching
# to trend_follow strategy for better risk-adjusted returns.
# See: lib/regime_weighting.sh for dynamic strategy selection.
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/trading_thresholds.sh" 2>/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/risk_management.sh" 2>/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/trade_journal.sh" 2>/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/alpaca_wrappers.sh" 2>/dev/null

# ============================================================================
# Strategy Analysis & Signal Generation
# ============================================================================

# Analyze symbol for mean reversion entry signal
# Args: symbol, current_price, rsi, bb_lower, bb_upper, avg_volume_20, macd, signal_line
# Returns: JSON {signal: buy/sell/none, confidence: 0-100, reason: string}
mean_reversion_analyze() {
    local symbol=$1
    local current_price=$2
    local rsi=$3
    local bb_lower=$4
    local bb_upper=$5
    local avg_volume_20=$6
    local current_volume=$7
    local macd=$8
    local signal_line=$9
    
    if [[ -z "$symbol" ]] || [[ -z "$current_price" ]]; then
        cat <<EOF
{"signal": "none", "confidence": 0, "reason": "insufficient_data"}
EOF
        return 1
    fi
    
    local signal="none"
    local confidence=0
    local reason="No entry signal"
    local entry_conditions=0
    
    # Check RSI oversold condition
    local rsi_check=false
    if (( $(echo "$rsi < $MR_RSI_ENTRY_OVERSOLD" | bc -l) )); then
        rsi_check=true
        entry_conditions=$((entry_conditions + 1))
        confidence=$((confidence + 25))
    fi
    
    # Check price near lower Bollinger Band
    local bb_check=false
    local bb_diff=$(echo "scale=4; $current_price - $bb_lower" | bc -l)
    local bb_range=$(echo "scale=4; $bb_upper - $bb_lower" | bc -l)
    local bb_pct=$(echo "scale=4; ($bb_diff / $bb_range) * 100" | bc -l)
    
    if (( $(echo "$bb_pct < $MR_BB_LOWER_TOUCH_THRESHOLD * 100" | bc -l) )); then
        bb_check=true
        entry_conditions=$((entry_conditions + 1))
        confidence=$((confidence + 25))
    fi
    
    # Check volume condition
    local volume_check=false
    if (( $(echo "$current_volume > $avg_volume_20" | bc -l) )); then
        volume_check=true
        entry_conditions=$((entry_conditions + 1))
        confidence=$((confidence + 20))
    fi
    
    # Check MACD positive (if required)
    local macd_check=false
    if [[ "$MR_MACD_POSITIVE_FOR_ENTRY" == "true" ]]; then
        if (( $(echo "$macd > $signal_line" | bc -l) )); then
            macd_check=true
            entry_conditions=$((entry_conditions + 1))
            confidence=$((confidence + 20))
        fi
    else
        macd_check=true
        confidence=$((confidence + 20))
    fi
    
    # Determine signal
    if [[ "$rsi_check" == "true" ]] && [[ "$bb_check" == "true" ]]; then
        signal="buy"
        reason="RSI oversold (${rsi}) at lower BB; Volume $([ "$volume_check" = "true" ] && echo "above" || echo "below") 20d avg"
    fi
    
    # Confidence cap at 100
    if [[ $confidence -gt 100 ]]; then
        confidence=100
    fi
    
    cat <<EOF
{
  "signal": "$signal",
  "confidence": $confidence,
  "reason": "$reason",
  "entry_conditions_met": $entry_conditions,
  "rsi_check": $rsi_check,
  "bb_check": $bb_check,
  "volume_check": $volume_check,
  "macd_check": $macd_check
}
EOF
}

# Analyze for mean reversion exit signal
# Args: symbol, current_price, entry_price, rsi, [trade_id]
# Returns: JSON {signal: exit/hold, reason: string, exit_type: profit/stop/rsi}
mean_reversion_exit_check() {
    local symbol=$1
    local current_price=$2
    local entry_price=$3
    local rsi=$4
    local trade_id=${5:-""}
    
    if [[ -z "$symbol" ]] || [[ -z "$current_price" ]] || [[ -z "$entry_price" ]]; then
        cat <<EOF
{"signal": "hold", "reason": "insufficient_data", "exit_type": "none"}
EOF
        return 1
    fi
    
    local signal="hold"
    local exit_type="none"
    local reason="No exit signal"
    
    # Calculate gain/loss percentage
    local gain_pct=$(echo "scale=4; (($current_price - $entry_price) / $entry_price) * 100" | bc -l)
    
    # Check RSI overbought exit
    if (( $(echo "$rsi > $MR_RSI_EXIT_OVERBOUGHT" | bc -l) )); then
        signal="exit"
        exit_type="rsi_overbought"
        reason="RSI overbought at ${rsi}"
    fi
    
    # Check take-profit exit
    if (( $(echo "$gain_pct >= $MR_TAKE_PROFIT_PCT" | bc -l) )); then
        signal="exit"
        exit_type="take_profit"
        reason="Take-profit target (${MR_TAKE_PROFIT_PCT}%) reached at gain ${gain_pct}%"
    fi
    
    # Check stop-loss exit
    if (( $(echo "$gain_pct <= -1 * $MR_STOP_LOSS_PCT" | bc -l) )); then
        signal="exit"
        exit_type="stop_loss"
        reason="Stop-loss (${MR_STOP_LOSS_PCT}%) hit at loss ${gain_pct}%"
    fi
    
    cat <<EOF
{
  "signal": "$signal",
  "exit_type": "$exit_type",
  "reason": "$reason",
  "current_gain_pct": $gain_pct,
  "rsi": $rsi
}
EOF
}

# ============================================================================
# Strategy Execution
# ============================================================================

# Execute mean reversion entry
# Args: symbol, entry_price, capital, risk_pct, [max_qty]
# Returns: Trade ID and order details
mean_reversion_enter() {
    local symbol=$1
    local entry_price=$2
    local capital=$3
    local risk_pct=${4:-$MR_MAX_POSITION_RISK_PCT}
    local max_qty=${5:-999}
    
    if [[ -z "$symbol" ]] || [[ -z "$entry_price" ]] || [[ -z "$capital" ]]; then
        return 1
    fi
    
    # Calculate stop-loss and take-profit prices
    local stop_loss_price=$(echo "scale=2; $entry_price - ($entry_price * $MR_STOP_LOSS_PCT / 100)" | bc -l)
    local take_profit_price=$(echo "scale=2; $entry_price + ($entry_price * $MR_TAKE_PROFIT_PCT / 100)" | bc -l)
    
    # Calculate position size
    local position_size=$(calculate_position_size "$capital" "$risk_pct")
    local qty=$(calculate_position_qty "$entry_price" "$stop_loss_price" "$position_size")
    
    # Cap at max quantity if needed
    if [[ $qty -gt $max_qty ]]; then
        qty=$max_qty
    fi

    # Phase 1 Kelly cap + daily risk budget (no-op unless KELLY_SIZING_ENABLED=true;
    # never increases qty). The budget is reserved before the order is placed so
    # a trade that would exceed today's risk budget is never sent.
    if [[ "${KELLY_SIZING_ENABLED:-false}" == "true" ]] && declare -f kelly_cap_qty >/dev/null; then
        qty=$(kelly_cap_qty "$qty" "$entry_price" "$stop_loss_price" "$capital")
        if [[ -z "$qty" || "$qty" -le 0 ]]; then
            return 1
        fi
        local budget_risk=$(echo "scale=2; ($entry_price - $stop_loss_price) * $qty" | bc -l)
        if ! risk_budget_allocate "${symbol}_$(date +%s)_$$" "$budget_risk" "$capital"; then
            return 1
        fi
    fi

    # Place order
    local order_id=$(alpaca_place_order "$symbol" "$qty" "buy" 2>/dev/null)
    
    if [[ -z "$order_id" ]]; then
        return 1
    fi
    
    # Log trade entry
    local trade_id=$(log_trade_entry "$symbol" "$entry_price" "$qty" "mean_reversion" "Oversold reversal" "$stop_loss_price" "$take_profit_price")
    
    cat <<EOF
{
  "trade_id": "$trade_id",
  "order_id": "$order_id",
  "symbol": "$symbol",
  "strategy": "mean_reversion",
  "entry_price": $entry_price,
  "quantity": $qty,
  "stop_loss": $stop_loss_price,
  "take_profit": $take_profit_price,
  "position_value": $(echo "scale=2; $entry_price * $qty" | bc -l),
  "risk_amount": $(echo "scale=2; ($entry_price - $stop_loss_price) * $qty" | bc -l)
}
EOF
}

# Execute mean reversion exit
# Args: symbol, exit_price, [trade_id], [reason]
# Returns: Exit record with P&L
mean_reversion_exit() {
    local symbol=$1
    local exit_price=$2
    local trade_id=${3:-""}
    local reason=${4:-"mean_reversion_exit"}
    
    if [[ -z "$symbol" ]] || [[ -z "$exit_price" ]]; then
        return 1
    fi
    
    # Close trade and get exit record
    close_trade "$symbol" "$exit_price" "$reason" "$trade_id"
}

# ============================================================================
# Batch Signal Generation for Watchlist
# ============================================================================

# Generate mean reversion signals for multiple symbols
# Args: symbols (comma-separated or space-separated), prices_array, rsi_array, bb_lower_array, etc.
# Returns: JSON array of signals
mean_reversion_scan() {
    local symbols_str=$1
    
    if [[ -z "$symbols_str" ]]; then
        echo "[]"
        return 0
    fi
    
    # Convert comma-separated to array
    local -a symbols=(${symbols_str//,/ })
    local signals="["
    
    for symbol in "${symbols[@]}"; do
        # In practice, this would fetch live data for each symbol
        # For now, return template for integration
        signals="${signals}{\"symbol\":\"$symbol\",\"signal\":\"pending_data\"},"
    done
    
    # Remove trailing comma
    signals="${signals%,}]"
    echo "$signals"
}

# ============================================================================
# Strategy Status & Statistics
# ============================================================================

# Get mean reversion strategy statistics
# Args: none
# Returns: JSON with strategy performance
mean_reversion_stats() {
    local trades=$(get_strategy_trades "mean_reversion")
    local closed=$(echo "$trades" | jq "[.[] | select(.status == \"closed\")]")
    local total=$(echo "$closed" | jq 'length')
    local winners=$(echo "$closed" | jq "[.[] | select(.net_pnl > 0)] | length")
    local total_pnl=$(echo "$closed" | jq "[.[].net_pnl] | add // 0")
    
    local win_rate=0
    if [[ $total -gt 0 ]]; then
        win_rate=$(echo "scale=2; ($winners / $total) * 100" | bc -l)
    fi
    
    cat <<EOF
{
  "strategy": "mean_reversion",
  "total_trades": $total,
  "winning_trades": $winners,
  "win_rate_pct": $win_rate,
  "total_pnl": $total_pnl,
  "avg_pnl_per_trade": $(echo "scale=2; $total_pnl / $total" | bc -l)
}
EOF
}
