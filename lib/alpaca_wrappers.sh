#!/bin/bash
# ============================================================================
# StockSwingTrader v6.1: Alpaca API Wrappers
# ============================================================================
# Purpose: High-level wrapper functions that map v6.1 strategy calls to the
#          underlying Alpaca broker functions (alpaca_broker.sh). It never
#          redefines a broker function; orders, brackets, status and cancel
#          live in alpaca_broker.sh.
# ============================================================================

# Source dependencies (only when the broker module is not loaded yet, so an
# initialized connection, ALPACA_INITIALIZED, is kept)
if ! declare -F alpaca_submit_order >/dev/null 2>&1; then
    source "$(dirname "${BASH_SOURCE[0]}")/alpaca_broker.sh" 2>/dev/null || {
        echo "ERROR: alpaca_broker.sh not found" >&2
        return 1
    }
fi

# ============================================================================
# Account & Position Information
# ============================================================================

# Get current account equity
# Args: none
# Returns: Account equity in dollars
# Example: equity=$(alpaca_get_account_equity); echo $equity
alpaca_get_account_equity() {
    if ! command -v alpaca_get_account &>/dev/null; then
        echo "0"
        return 1
    fi
    
    local account_json=$(alpaca_get_account)
    if [[ -z "$account_json" ]]; then
        return 1
    fi
    
    # Parse equity from account JSON
    echo "$account_json" | jq -r '.equity // 0' 2>/dev/null || echo "0"
}

# Get specific position by symbol
# Args: symbol (e.g., AAPL)
# Returns: Position JSON object or empty if not found
alpaca_get_position() {
    local symbol=$1
    if [[ -z "$symbol" ]]; then
        return 1
    fi
    
    local positions=$(alpaca_get_positions)
    echo "$positions" | jq --arg sym "$symbol" '.[] | select(.symbol == $sym)' 2>/dev/null
}

# Get current price for a symbol
# Args: symbol (e.g., AAPL)
# Returns: Current price
alpaca_get_current_price() {
    local symbol=$1
    if [[ -z "$symbol" ]]; then
        return 1
    fi
    
    if ! command -v alpaca_get_quote &>/dev/null; then
        return 1
    fi
    
    local quote=$(alpaca_get_quote "$symbol")
    echo "$quote" | jq -r '.last_price // 0' 2>/dev/null || echo "0"
}

# ============================================================================
# Order Placement
# ============================================================================
# alpaca_place_order, alpaca_place_bracket_order, alpaca_get_order_status and
# alpaca_cancel_order come from alpaca_broker.sh (not redefined here).

# Place a stop-loss order (sell stop, good till cancelled)
# Args: symbol, qty, stop_price
# Returns: Order ID (1 on error)
# Example: order_id=$(alpaca_place_stop_loss "AAPL" 10 97.50)
alpaca_place_stop_loss() {
    local symbol=$1
    local qty=$2
    local stop_price=$3
    local payload order

    if [[ -z "$symbol" ]] || [[ -z "$qty" ]] || [[ -z "$stop_price" ]]; then
        return 1
    fi

    payload=$(alpaca_build_order_payload "$symbol" "$qty" "sell" "stop" "" "gtc" "" "$stop_price") || return 1
    order=$(alpaca_submit_order "$payload") || return 1
    echo "$order" | jq -r '.order_id // empty' 2>/dev/null
}

# Place a take-profit order (sell limit, good till cancelled)
# Args: symbol, qty, limit_price
# Returns: Order ID (1 on error)
# Example: order_id=$(alpaca_place_take_profit "AAPL" 10 108)
alpaca_place_take_profit() {
    local symbol=$1
    local qty=$2
    local limit_price=$3
    local payload order

    if [[ -z "$symbol" ]] || [[ -z "$qty" ]] || [[ -z "$limit_price" ]]; then
        return 1
    fi

    payload=$(alpaca_build_order_payload "$symbol" "$qty" "sell" "limit" "$limit_price" "gtc" "") || return 1
    order=$(alpaca_submit_order "$payload") || return 1
    echo "$order" | jq -r '.order_id // empty' 2>/dev/null
}

# ============================================================================
# Position Queries
# ============================================================================

# Get position quantity for a symbol
# Args: symbol
# Returns: Quantity (positive for long, negative for short)
alpaca_get_position_qty() {
    local symbol=$1
    if [[ -z "$symbol" ]]; then
        return 1
    fi
    
    local position=$(alpaca_get_position "$symbol")
    if [[ -z "$position" ]]; then
        echo "0"
        return 0
    fi
    
    echo "$position" | jq -r '.qty // 0' 2>/dev/null || echo "0"
}

# Get average entry price for a position
# Args: symbol
# Returns: Average entry price
alpaca_get_position_avg_price() {
    local symbol=$1
    if [[ -z "$symbol" ]]; then
        return 1
    fi
    
    local position=$(alpaca_get_position "$symbol")
    if [[ -z "$position" ]]; then
        echo "0"
        return 0
    fi
    
    echo "$position" | jq -r '.avg_fill_price // 0' 2>/dev/null || echo "0"
}

# Get unrealized P&L for a position
# Args: symbol
# Returns: Unrealized P&L in dollars
alpaca_get_position_unrealized_pnl() {
    local symbol=$1
    if [[ -z "$symbol" ]]; then
        return 1
    fi
    
    local position=$(alpaca_get_position "$symbol")
    if [[ -z "$position" ]]; then
        echo "0"
        return 0
    fi
    
    echo "$position" | jq -r '.unrealized_pl // 0' 2>/dev/null || echo "0"
}

# ============================================================================
# Portfolio Queries
# ============================================================================

# Get total unrealized P&L for all positions
# Args: none
# Returns: Total unrealized P&L in dollars
alpaca_get_total_unrealized_pnl() {
    local positions=$(alpaca_get_positions)
    if [[ -z "$positions" ]] || [[ "$positions" == "[]" ]]; then
        echo "0"
        return 0
    fi
    
    echo "$positions" | jq '[.[].unrealized_pl] | add' 2>/dev/null || echo "0"
}

# Get number of open positions
# Args: none
# Returns: Count of open positions
alpaca_get_position_count() {
    local positions=$(alpaca_get_positions)
    if [[ -z "$positions" ]] || [[ "$positions" == "[]" ]]; then
        echo "0"
        return 0
    fi
    
    echo "$positions" | jq 'length' 2>/dev/null || echo "0"
}

# ============================================================================
# Historical Data
# ============================================================================

# Get historical bar data for a symbol
# Args: symbol, timeframe (1m, 5m, 15m, 1h, 1d), limit (default 100)
# Returns: JSON array of bars
alpaca_get_bars() {
    local symbol=$1
    local timeframe=$2
    local limit=${3:-100}
    
    if [[ -z "$symbol" ]] || [[ -z "$timeframe" ]]; then
        return 1
    fi
    
    if ! command -v alpaca_get_historical_bars &>/dev/null; then
        echo "[]"
        return 1
    fi
    
    alpaca_get_historical_bars "$symbol" "$timeframe" "$limit" 2>/dev/null || echo "[]"
}

# Get most recent bar for a symbol
# Args: symbol
# Returns: Bar JSON object (open, high, low, close, volume, etc.)
alpaca_get_latest_bar() {
    local symbol=$1
    if [[ -z "$symbol" ]]; then
        return 1
    fi
    
    local bars=$(alpaca_get_bars "$symbol" "1d" 1)
    echo "$bars" | jq '.[0] // empty' 2>/dev/null
}

# ============================================================================
# Connection Management
# ============================================================================

# Initialize wrapper (verify Alpaca connection)
# Args: none
# Returns: 0 if connected, 1 if failed
alpaca_wrapper_init() {
    if ! command -v alpaca_init &>/dev/null; then
        return 1
    fi
    
    alpaca_init && return 0 || return 1
}

# Get connection status
# Args: none
# Returns: "connected" or "disconnected"
alpaca_wrapper_status() {
    if alpaca_get_account &>/dev/null; then
        echo "connected"
        return 0
    else
        echo "disconnected"
        return 1
    fi
}
