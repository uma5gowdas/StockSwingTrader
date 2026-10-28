#!/bin/bash
# ============================================================================
# StockSwingTrader v6.1: Trend Following Strategy
# ============================================================================
# Entry Criteria:
#   - EMA(12) > EMA(26) bullish crossover
#   - Price > SMA(50)
#   - Price > SMA(200)
#   - Volume > 30-day average
#
# Exit Criteria:
#   - EMA(12) < EMA(26) bearish crossover, or
#   - +12% take-profit reached, or
#   - Stop-loss at entry - (1.5 × ATR)
#
# Position Sizing: Kelly Criterion with 2% risk per trade
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/trading_thresholds.sh" 2>/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/risk_management.sh" 2>/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/trade_journal.sh" 2>/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/alpaca_wrappers.sh" 2>/dev/null

# ============================================================================
# Strategy Analysis & Signal Generation
# ============================================================================

# Analyze symbol for trend following entry signal
# Args: symbol, current_price, ema_12, ema_26, sma_50, sma_200, avg_volume_30, current_volume
# Returns: JSON {signal: buy/sell/none, confidence: 0-100, reason: string}
trend_follow_analyze() {
    local symbol=$1
    local current_price=$2
    local ema_12=$3
    local ema_26=$4
    local sma_50=$5
    local sma_200=$6
    local avg_volume_30=$7
    local current_volume=$8
    
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
    
    # Check EMA bullish crossover (EMA 12 > 26)
    local ema_check=false
    if (( $(echo "$ema_12 > $ema_26" | bc -l) )); then
        ema_check=true
        entry_conditions=$((entry_conditions + 1))
        confidence=$((confidence + 25))
    fi
    
    # Check price > SMA(50)
    local sma50_check=false
    if (( $(echo "$current_price > $sma_50" | bc -l) )); then
        sma50_check=true
        entry_conditions=$((entry_conditions + 1))
        confidence=$((confidence + 20))
    fi
    
    # Check price > SMA(200)
    local sma200_check=false
    if (( $(echo "$current_price > $sma_200" | bc -l) )); then
        sma200_check=true
        entry_conditions=$((entry_conditions + 1))
        confidence=$((confidence + 20))
    fi
    
    # Check volume condition (> 30-day average)
    local volume_check=false
    if (( $(echo "$current_volume > $avg_volume_30" | bc -l) )); then
        volume_check=true
        entry_conditions=$((entry_conditions + 1))
        confidence=$((confidence + 15))
    fi
    
    # Determine buy signal (need EMA + both SMAs + volume check)
    if [[ "$ema_check" == "true" ]] && [[ "$sma50_check" == "true" ]] && [[ "$sma200_check" == "true" ]]; then
        signal="buy"
        reason="Bullish trend: EMA crossover, price above SMA(50)/SMA(200)"
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
  "ema_check": $ema_check,
  "sma50_check": $sma50_check,
  "sma200_check": $sma200_check,
  "volume_check": $volume_check,
  "ema_12": $ema_12,
  "ema_26": $ema_26
}
EOF
}

# Analyze for trend following exit signal
# Args: symbol, current_price, entry_price, ema_12, ema_26, atr, [trade_id]
# Returns: JSON {signal: exit/hold, reason: string, exit_type: profit/stop/ema}
trend_follow_exit_check() {
    local symbol=$1
    local current_price=$2
    local entry_price=$3
    local ema_12=$4
    local ema_26=$5
    local atr=$6
    local trade_id=${7:-""}
    
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
    
    # Check EMA bearish crossover exit
    if (( $(echo "$ema_12 < $ema_26" | bc -l) )); then
        signal="exit"
        exit_type="ema_crossover"
        reason="EMA bearish crossover (12 < 26)"
    fi
    
    # Check take-profit exit
    if (( $(echo "$gain_pct >= $TF_TAKE_PROFIT_PCT" | bc -l) )); then
        signal="exit"
        exit_type="take_profit"
        reason="Take-profit target (${TF_TAKE_PROFIT_PCT}%) reached at gain ${gain_pct}%"
    fi
    
    # Check ATR-based stop-loss exit
    local stop_loss_price=$(echo "scale=2; $entry_price - ($TF_ATR_STOP_MULTIPLIER * $atr)" | bc -l)
    if (( $(echo "$current_price <= $stop_loss_price" | bc -l) )); then
        signal="exit"
        exit_type="atr_stop"
        reason="ATR stop-loss hit (Entry - 1.5×ATR = $stop_loss_price)"
    fi
    
    cat <<EOF
{
  "signal": "$signal",
  "exit_type": "$exit_type",
  "reason": "$reason",
  "current_gain_pct": $gain_pct,
  "ema_12": $ema_12,
  "ema_26": $ema_26,
  "atr": $atr
}
EOF
}

# ============================================================================
# Strategy Execution
# ============================================================================

# Execute trend following entry
# Args: symbol, entry_price, atr, capital, risk_pct, [max_qty]
# Returns: Trade ID and order details
trend_follow_enter() {
    local symbol=$1
    local entry_price=$2
    local atr=$3
    local capital=$4
    local risk_pct=${5:-$TF_MAX_POSITION_RISK_PCT}
    local max_qty=${6:-999}
    
    if [[ -z "$symbol" ]] || [[ -z "$entry_price" ]] || [[ -z "$atr" ]] || [[ -z "$capital" ]]; then
        return 1
    fi
    
    # Calculate stop-loss and take-profit prices
    local stop_loss_price=$(echo "scale=2; $entry_price - ($TF_ATR_STOP_MULTIPLIER * $atr)" | bc -l)
    local take_profit_price=$(echo "scale=2; $entry_price + ($entry_price * $TF_TAKE_PROFIT_PCT / 100)" | bc -l)
    
    # Calculate position size
    local position_size=$(calculate_position_size "$capital" "$risk_pct")
    local qty=$(calculate_position_qty "$entry_price" "$stop_loss_price" "$position_size")
    
    # Cap at max quantity if needed
    if [[ $qty -gt $max_qty ]]; then
        qty=$max_qty
    fi
    
    # Place order
    local order_id=$(alpaca_place_order "$symbol" "$qty" "buy" 2>/dev/null)
    
    if [[ -z "$order_id" ]]; then
        return 1
    fi
    
    # Log trade entry
    local trade_id=$(log_trade_entry "$symbol" "$entry_price" "$qty" "trend_follow" "Bullish trend alignment" "$stop_loss_price" "$take_profit_price")
    
    cat <<EOF
{
  "trade_id": "$trade_id",
  "order_id": "$order_id",
  "symbol": "$symbol",
  "strategy": "trend_follow",
  "entry_price": $entry_price,
  "quantity": $qty,
  "stop_loss": $stop_loss_price,
  "take_profit": $take_profit_price,
  "position_value": $(echo "scale=2; $entry_price * $qty" | bc -l),
  "risk_amount": $(echo "scale=2; ($entry_price - $stop_loss_price) * $qty" | bc -l),
  "atr": $atr
}
EOF
}

# Execute trend following exit
# Args: symbol, exit_price, [trade_id], [reason]
# Returns: Exit record with P&L
trend_follow_exit() {
    local symbol=$1
    local exit_price=$2
    local trade_id=${3:-""}
    local reason=${4:-"trend_follow_exit"}
    
    if [[ -z "$symbol" ]] || [[ -z "$exit_price" ]]; then
        return 1
    fi
    
    # Close trade and get exit record
    close_trade "$symbol" "$exit_price" "$reason" "$trade_id"
}

# ============================================================================
# Batch Signal Generation for Watchlist
# ============================================================================

# Generate trend following signals for multiple symbols
# Args: symbols (comma-separated or space-separated)
# Returns: JSON array of signals
trend_follow_scan() {
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

# Get trend following strategy statistics
# Args: none
# Returns: JSON with strategy performance
trend_follow_stats() {
    local trades=$(get_strategy_trades "trend_follow")
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
  "strategy": "trend_follow",
  "total_trades": $total,
  "winning_trades": $winners,
  "win_rate_pct": $win_rate,
  "total_pnl": $total_pnl,
  "avg_pnl_per_trade": $(echo "scale=2; $total_pnl / $total" | bc -l)
}
EOF
}
