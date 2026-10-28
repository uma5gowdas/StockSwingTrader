#!/bin/bash
# ============================================================================
# StockSwingTrader v6.1: Trade Journal Module
# ============================================================================
# Purpose: Track all trades (entry/exit), attribute to strategies,
#          log with timestamps, and enable backtest analysis
# ============================================================================

# Source dependencies
source "$(dirname "${BASH_SOURCE[0]}")/trading_thresholds.sh" 2>/dev/null

# ============================================================================
# Broker Selection Support
# ============================================================================
# Global BROKER variable (set from main script)
# Values: "alpaca" or "robinhood"
# Trade journal logs both entry and exit with broker field for audit trail
BROKER="${BROKER:-alpaca}"

# ============================================================================
# Initialization
# ============================================================================

# Initialize trade journal (create logs directory if needed)
_init_trade_journal() {
    mkdir -p "${LOG_DIR:=logs}" 2>/dev/null
    
    # Create trades.json if it doesn't exist
    if [[ ! -f "$TRADE_JOURNAL_FILE" ]]; then
        echo "[]" > "$TRADE_JOURNAL_FILE"
    fi
}

# Generate trade ID
# Format: T[YYYYMMDD]_[SYMBOL]_[SEQ]
# Args: symbol
# Returns: Trade ID string
_generate_trade_id() {
    local symbol=$1
    local date=$(date +%Y%m%d)
    
    # Count existing trades for this symbol today
    local count=0
    if [[ -f "$TRADE_JOURNAL_FILE" ]]; then
        count=$(jq "[.[] | select(.symbol == \"$symbol\" and .date_open | startswith(\"$date\"))] | length" "$TRADE_JOURNAL_FILE" 2>/dev/null || echo "0")
    fi
    
    local seq=$((count + 1))
    printf "T%s_%s_%03d" "$date" "$symbol" "$seq"
}

# ============================================================================
# Trade Entry Logging
# ============================================================================

# Log a trade entry
# Args: symbol, entry_price, qty, strategy, reason, [stop_price], [target_price]
# Returns: Trade ID
# Note: Broker field is automatically added from global BROKER variable
log_trade_entry() {
    local symbol=$1
    local entry_price=$2
    local qty=$3
    local strategy=$4
    local reason=$5
    local stop_price=${6:-0}
    local target_price=${7:-0}
    
    if [[ -z "$symbol" ]] || [[ -z "$entry_price" ]] || [[ -z "$qty" ]] || [[ -z "$strategy" ]]; then
        return 1
    fi
    
    _init_trade_journal
    
    # Generate trade ID
    local trade_id=$(_generate_trade_id "$symbol")
    
    # Create trade record with broker field
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local trade_record=$(cat <<EOF
{
  "trade_id": "$trade_id",
  "symbol": "$symbol",
  "strategy": "$strategy",
  "broker": "$BROKER",
  "date_open": "$timestamp",
  "entry_price": $entry_price,
  "quantity": $qty,
  "stop_loss_price": $stop_price,
  "take_profit_price": $target_price,
  "entry_reason": "$reason",
  "status": "open",
  "entry_value": $(echo "scale=2; $entry_price * $qty" | bc -l)
}
EOF
)
    
    # Append to trades.json
    local updated_json=$(jq ". += [$trade_record]" "$TRADE_JOURNAL_FILE" 2>/dev/null)
    if [[ -n "$updated_json" ]]; then
        echo "$updated_json" > "$TRADE_JOURNAL_FILE"
    fi
    
    echo "$trade_id"
}

# ============================================================================
# Trade Exit Logging
# ============================================================================

# Close a trade (log exit)
# Args: symbol, exit_price, reason, [trade_id]
# Returns: Exit record with P&L and broker information
# Note: Broker field is preserved from entry, exit_reason added
close_trade() {
    local symbol=$1
    local exit_price=$2
    local reason=${3:-"manual_close"}
    local trade_id=${4:-""}
    
    if [[ -z "$symbol" ]] || [[ -z "$exit_price" ]]; then
        return 1
    fi
    
    _init_trade_journal
    
    # If no trade_id provided, use the most recent OPEN trade for the symbol
    if [[ -z "$trade_id" ]]; then
        trade_id=$(jq -r ".[] | select(.symbol == \"$symbol\" and .status == \"open\") | .trade_id" "$TRADE_JOURNAL_FILE" 2>/dev/null | tail -1)
    fi
    
    if [[ -z "$trade_id" ]]; then
        return 1
    fi
    
    # Update trade record with exit info
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local exit_value=$(jq -r ".[] | select(.trade_id == \"$trade_id\") | .quantity" "$TRADE_JOURNAL_FILE" 2>/dev/null | xargs echo "scale=2; $exit_price *" | bc -l)
    local entry_price=$(jq -r ".[] | select(.trade_id == \"$trade_id\") | .entry_price" "$TRADE_JOURNAL_FILE" 2>/dev/null)
    local qty=$(jq -r ".[] | select(.trade_id == \"$trade_id\") | .quantity" "$TRADE_JOURNAL_FILE" 2>/dev/null)
    
    local gross_pnl=$(echo "scale=2; ($exit_price - $entry_price) * $qty" | bc -l)
    local pnl_pct=$(echo "scale=4; (($exit_price - $entry_price) / $entry_price) * 100" | bc -l)
    
    # Assume 0.1% commission (standard interactive broker fee)
    local commission=$(echo "scale=2; ($exit_value * 0.001)" | bc -l)
    local net_pnl=$(echo "scale=2; $gross_pnl - $commission" | bc -l)
    
    # Update record
    local updated_json=$(jq --arg id "$trade_id" \
        --arg ts "$timestamp" \
        --arg ep "$exit_price" \
        --arg gp "$gross_pnl" \
        --arg pp "$pnl_pct" \
        --arg np "$net_pnl" \
        --arg com "$commission" \
        --arg rsn "$reason" \
        '(.[] | select(.trade_id == $id)) |= .+
        {
          "date_close": $ts,
          "exit_price": ($ep | tonumber),
          "gross_pnl": ($gp | tonumber),
          "pnl_pct": ($pp | tonumber),
          "net_pnl": ($np | tonumber),
          "commission": ($com | tonumber),
          "exit_reason": $rsn,
          "exit_value": ($ep | tonumber) * .quantity,
          "status": "closed"
        }' "$TRADE_JOURNAL_FILE" 2>/dev/null)
    
    if [[ -n "$updated_json" ]]; then
        echo "$updated_json" > "$TRADE_JOURNAL_FILE"
    fi
    
    # Return exit record
    jq ".[] | select(.trade_id == \"$trade_id\")" "$TRADE_JOURNAL_FILE" 2>/dev/null
}

# ============================================================================
# Trade Journal Queries
# ============================================================================

# Query most recent open trade for a symbol
# Args: symbol
# Returns: Trade record (JSON)
query_trade_journal() {
    local symbol=$1
    
    if [[ -z "$symbol" ]]; then
        return 1
    fi
    
    if [[ ! -f "$TRADE_JOURNAL_FILE" ]]; then
        return 1
    fi
    
    jq ".[] | select(.symbol == \"$symbol\" and .status == \"open\") | sort_by(.date_open) | .[-1]" "$TRADE_JOURNAL_FILE" 2>/dev/null
}

# Get all trades for a symbol
# Args: symbol
# Returns: JSON array of all trades for the symbol
get_symbol_trades() {
    local symbol=$1
    
    if [[ -z "$symbol" ]]; then
        return 1
    fi
    
    if [[ ! -f "$TRADE_JOURNAL_FILE" ]]; then
        echo "[]"
        return 0
    fi
    
    jq "[.[] | select(.symbol == \"$symbol\")]" "$TRADE_JOURNAL_FILE" 2>/dev/null || echo "[]"
}

# Get all trades for a strategy
# Args: strategy_name
# Returns: JSON array of all trades from the strategy
get_strategy_trades() {
    local strategy=$1
    
    if [[ -z "$strategy" ]]; then
        return 1
    fi
    
    if [[ ! -f "$TRADE_JOURNAL_FILE" ]]; then
        echo "[]"
        return 0
    fi
    
    jq "[.[] | select(.strategy == \"$strategy\")]" "$TRADE_JOURNAL_FILE" 2>/dev/null || echo "[]"
}

# ============================================================================
# Journal Display & Analysis
# ============================================================================

# Show trade journal - summary of all trades
# Args: [format] (json|table|summary)
# Returns: Formatted trade list
show_journal() {
    local format=${1:-table}
    
    if [[ ! -f "$TRADE_JOURNAL_FILE" ]]; then
        echo "No trades logged"
        return 0
    fi
    
    case "$format" in
        json)
            jq '.' "$TRADE_JOURNAL_FILE"
            ;;
        table)
            echo "=== TRADE JOURNAL ==="
            jq -r '.[] | "\(.trade_id) | \(.symbol) | \(.strategy) | Entry: $\(.entry_price | tostring) | Qty: \(.quantity | tostring) | Status: \(.status)"' "$TRADE_JOURNAL_FILE"
            ;;
        summary)
            local total_trades=$(jq 'length' "$TRADE_JOURNAL_FILE")
            local closed_trades=$(jq "[.[] | select(.status == \"closed\")] | length" "$TRADE_JOURNAL_FILE")
            local open_trades=$(jq "[.[] | select(.status == \"open\")] | length" "$TRADE_JOURNAL_FILE")
            local total_pnl=$(jq "[.[] | select(.status == \"closed\") | .net_pnl] | add" "$TRADE_JOURNAL_FILE")
            local win_trades=$(jq "[.[] | select(.status == \"closed\" and .net_pnl > 0)] | length" "$TRADE_JOURNAL_FILE")
            
            cat <<EOF
Trade Journal Summary:
  Total Trades: $total_trades
  Closed: $closed_trades
  Open: $open_trades
  Total P&L: \$$total_pnl
  Winning Trades: $win_trades
  Win Rate: $(echo "scale=1; ($win_trades / $closed_trades) * 100" | bc -l)%
EOF
            ;;
        *)
            jq '.' "$TRADE_JOURNAL_FILE"
            ;;
    esac
}

# ============================================================================
# Backtest Data Export
# ============================================================================

# Export trade journal as backtest results
# Args: [output_file]
# Returns: Backtest results JSON
export_backtest_data() {
    local output_file=${1:-$BACKTEST_RESULTS_FILE}
    
    if [[ ! -f "$TRADE_JOURNAL_FILE" ]]; then
        echo "[]" > "$output_file"
        return 0
    fi
    
    mkdir -p "$(dirname "$output_file")" 2>/dev/null
    
    # Calculate backtest metrics
    local closed=$(jq "[.[] | select(.status == \"closed\")]" "$TRADE_JOURNAL_FILE")
    local total=$(echo "$closed" | jq 'length')
    local winners=$(echo "$closed" | jq "[.[] | select(.net_pnl > 0)] | length")
    local losers=$(echo "$closed" | jq "[.[] | select(.net_pnl <= 0)] | length")
    local total_pnl=$(echo "$closed" | jq "[.[].net_pnl] | add")
    local avg_win=$(echo "$closed" | jq "[.[] | select(.net_pnl > 0) | .net_pnl] | add / length")
    local avg_loss=$(echo "$closed" | jq "[.[] | select(.net_pnl < 0) | .net_pnl] | add / length")
    
    local win_rate=0
    if [[ $total -gt 0 ]]; then
        win_rate=$(echo "scale=4; ($winners / $total) * 100" | bc -l)
    fi
    
    # Create backtest summary
    local backtest_json=$(cat <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "backtest_name": "TradeJournal_Export",
  "summary": {
    "total_trades": $total,
    "winning_trades": $winners,
    "losing_trades": $losers,
    "win_rate_pct": $win_rate,
    "total_pnl": $total_pnl,
    "avg_win": $avg_win,
    "avg_loss": $avg_loss,
    "profit_factor": $(echo "scale=2; ((-1 * $winners * $avg_win) / ($losers * $avg_loss))" | bc -l)
  },
  "trades": $closed
}
EOF
)
    
    echo "$backtest_json" > "$output_file"
    echo "$backtest_json"
}

# ============================================================================
# Trade Statistics
# ============================================================================

# Get trade statistics by strategy
# Args: strategy_name
# Returns: JSON with statistics
get_strategy_stats() {
    local strategy=$1
    
    if [[ -z "$strategy" ]]; then
        return 1
    fi
    
    local trades=$(get_strategy_trades "$strategy")
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
  "strategy": "$strategy",
  "total_trades": $total,
  "winners": $winners,
  "win_rate_pct": $win_rate,
  "total_pnl": $total_pnl
}
EOF
}

# Initialize on source
_init_trade_journal
