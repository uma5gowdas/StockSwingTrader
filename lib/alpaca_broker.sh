#!/bin/bash
# ============================================================================
# StockSwingTrader: Alpaca Broker Integration Module
# ============================================================================
# Provides functions to interact with Alpaca Paper Trading API
# Base URL: https://paper-api.alpaca.markets/v2
# Supports: Account management, positions, orders, market data
# ============================================================================

# No `set -o errexit`: this file is sourced, and errexit would leak into the
# caller (the agent) and abort it on any failing command.
set -o pipefail

# ============================================================================
# Module Configuration & Globals
# ============================================================================

# API Configuration
ALPACA_API_BASE_URL="${ALPACA_BASE_URL:-https://paper-api.alpaca.markets}/v2"
ALPACA_API_KEY="${ALPACA_API_KEY:-${APCA_API_KEY_ID:-}}"
ALPACA_SECRET_KEY="${ALPACA_SECRET_KEY:-${APCA_API_SECRET_KEY:-}}"
ALPACA_OAUTH_TOKEN="${ALPACA_OAUTH_TOKEN:-${APCA_API_OAUTH_TOKEN:-}}"

# Market data API (latest trade price for order confirmations)
ALPACA_DATA_API_BASE_URL="${ALPACA_DATA_URL:-https://data.alpaca.markets}/v2"
ALPACA_DATA_FEED="${ALPACA_DATA_FEED:-iex}"

# jq helper: numeric strings to numbers, null stays null (tonumber fails on null)
ALPACA_JQ_NUM='def num: if . == null then null else tonumber end;'

# Logging & Debug
ALPACA_LOG_FILE="${ALPACA_LOG_FILE:-logs/alpaca.log}"
ALPACA_DEBUG="${ALPACA_DEBUG:-false}"
ALPACA_INITIALIZED=false

# Retry Configuration
ALPACA_MAX_RETRIES=3
ALPACA_INITIAL_BACKOFF=1
ALPACA_BACKOFF_MULTIPLIER=2

# Timeouts
ALPACA_TIMEOUT=30
ALPACA_CONNECT_TIMEOUT=10

# ============================================================================
# Helper: Logging Functions
# ============================================================================

# Initialize logging directory
alpaca_init_logging() {
    local log_dir=$(dirname "$ALPACA_LOG_FILE")
    [[ ! -d "$log_dir" ]] && mkdir -p "$log_dir"
    touch "$ALPACA_LOG_FILE"
}

# Log message with timestamp
alpaca_log() {
    local level="$1"
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    alpaca_init_logging
    echo "[${timestamp}] [${level}] ${message}" >> "$ALPACA_LOG_FILE"
    
    if [[ "$ALPACA_DEBUG" == "true" ]]; then
        echo "[${level}] ${message}" >&2
    fi
}

# ============================================================================
# Helper: Input Validation
# ============================================================================

# Validate symbol format (A-Z, 1-5 characters)
# Args: SYMBOL
# Returns: 0 if valid, 1 if invalid
alpaca_validate_symbol() {
    local symbol="$1"
    
    if [[ -z "$symbol" ]]; then
        alpaca_log "ERROR" "Symbol cannot be empty"
        return 1
    fi
    
    # Check format: 1-5 uppercase letters
    if ! [[ "$symbol" =~ ^[A-Z]{1,5}$ ]]; then
        alpaca_log "ERROR" "Invalid symbol format: $symbol (must be 1-5 uppercase letters)"
        return 1
    fi
    
    return 0
}

# Validate numeric quantity
# Args: QTY
# Returns: 0 if valid, 1 if invalid
alpaca_validate_quantity() {
    local qty="$1"
    
    if ! [[ "$qty" =~ ^[0-9]+(\.[0-9]+)?$ ]] || (( $(echo "$qty <= 0" | bc -l) )); then
        alpaca_log "ERROR" "Invalid quantity: $qty (must be positive number)"
        return 1
    fi
    
    return 0
}

# Validate side (buy/sell)
# Args: SIDE
# Returns: 0 if valid, 1 if invalid
alpaca_validate_side() {
    local side="$1"
    
    case "$side" in
        buy|sell)
            return 0
            ;;
        *)
            alpaca_log "ERROR" "Invalid side: $side (must be 'buy' or 'sell')"
            return 1
            ;;
    esac
}

# ============================================================================
# Helper: Error Handling
# ============================================================================

# Parse and display API error response
# Args: HTTP_CODE, RESPONSE_BODY
# Returns: error message
alpaca_handle_error() {
    local http_code="$1"
    local response="$2"
    local error_msg=""
    
    # Extract error details from JSON response
    if command -v jq &>/dev/null; then
        error_msg=$(echo "$response" | jq -r '.message // .error // "Unknown error"' 2>/dev/null)
    else
        # Fallback: basic grep if jq not available
        error_msg=$(echo "$response" | grep -o '"message":"[^"]*"' | cut -d'"' -f4 || echo "Unknown error")
    fi
    
    local error_detail=""
    case "$http_code" in
        401)
            error_detail="Unauthorized: Invalid or missing API credentials"
            ;;
        403)
            error_detail="Forbidden: Insufficient permissions for this operation"
            ;;
        400)
            error_detail="Bad Request: Invalid parameters or malformed request"
            ;;
        404)
            error_detail="Not Found: Resource does not exist"
            ;;
        422)
            error_detail="Unprocessable Entity: Order rejected (insufficient buying power, invalid symbol, etc)"
            ;;
        429)
            error_detail="Rate Limited: Too many requests, backing off"
            ;;
        500|502|503|504)
            error_detail="Server Error: Alpaca API temporarily unavailable"
            ;;
        *)
            error_detail="HTTP Error $http_code"
            ;;
    esac
    
    alpaca_log "ERROR" "API Error ($http_code): $error_detail - $error_msg"
    echo "ERROR: $error_detail"
    [[ -n "$error_msg" ]] && echo "Details: $error_msg"
    
    return 1
}

# ============================================================================
# Helper: Currency Formatting
# ============================================================================

# Format number as currency with color
# Args: NUMBER, [SHOW_COLOR=true]
# Returns: formatted currency string
alpaca_format_currency() {
    local num="$1"
    local show_color="${2:-true}"
    local formatted=""
    
    # Handle negative numbers
    if (( $(echo "$num < 0" | bc -l) )); then
        formatted=$(printf "%.2f" "$num")
        if [[ "$show_color" == "true" ]]; then
            echo -e "\033[91m-\$$formatted\033[0m"  # Red for negative
        else
            echo "-\$$formatted"
        fi
    else
        formatted=$(printf "%.2f" "$num")
        if [[ "$show_color" == "true" ]]; then
            echo -e "\033[92m\$$formatted\033[0m"   # Green for positive
        else
            echo "\$$formatted"
        fi
    fi
}

# Format percentage change with color
# Args: PERCENT
# Returns: formatted percentage string
alpaca_format_percent() {
    local percent="$1"
    local formatted=$(printf "%.2f" "$percent")
    
    if (( $(echo "$percent < 0" | bc -l) )); then
        echo -e "\033[91m${formatted}%\033[0m"     # Red
    elif (( $(echo "$percent > 0" | bc -l) )); then
        echo -e "\033[92m${formatted}%\033[0m"     # Green
    else
        echo "${formatted}%"
    fi
}

# ============================================================================
# Core: Initialize API Connection
# ============================================================================

# Initialize Alpaca API
# Loads credentials and validates connection
# Returns: 0 on success, 1 on failure
alpaca_init() {
    alpaca_init_logging
    
    # Load credentials from environment (check both naming conventions)
    ALPACA_API_KEY="${ALPACA_API_KEY:-${APCA_API_KEY_ID:-}}"
    ALPACA_SECRET_KEY="${ALPACA_SECRET_KEY:-${APCA_API_SECRET_KEY:-}}"
    ALPACA_OAUTH_TOKEN="${ALPACA_OAUTH_TOKEN:-${APCA_API_OAUTH_TOKEN:-}}"
    
    # Validate we have either key/secret or oauth token
    if [[ -z "$ALPACA_API_KEY" ]] || [[ -z "$ALPACA_SECRET_KEY" ]]; then
        if [[ -z "$ALPACA_OAUTH_TOKEN" ]]; then
            alpaca_log "ERROR" "Alpaca credentials not found in environment variables"
            echo "ERROR: Missing Alpaca API credentials"
            echo "Set ALPACA_API_KEY and ALPACA_SECRET_KEY (or ALPACA_OAUTH_TOKEN) environment variables"
            return 1
        fi
    fi
    
    # Test connection
    if ! alpaca_check_connection; then
        alpaca_log "ERROR" "Failed to connect to Alpaca API"
        return 1
    fi
    
    ALPACA_INITIALIZED=true
    alpaca_log "INFO" "Alpaca API initialized successfully"
    echo "✓ Alpaca API initialized (Paper Trading)"
    return 0
}

# ============================================================================
# Helper: API Request Handler
# ============================================================================

# Make HTTP request to Alpaca API with retry logic
# Args: METHOD, ENDPOINT, [DATA], [RETRIES=0], [BASE_URL=ALPACA_API_BASE_URL]
# Returns: HTTP response body
alpaca_api_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local retries="${4:-0}"
    local base_url="${5:-$ALPACA_API_BASE_URL}"
    
    local url="${base_url}${endpoint}"
    local http_code
    local response
    local headers=""
    
    # Build headers
    if [[ -n "$ALPACA_API_KEY" ]] && [[ -n "$ALPACA_SECRET_KEY" ]]; then
        headers="-H 'APCA-API-KEY-ID: $ALPACA_API_KEY' -H 'APCA-API-SECRET-KEY: $ALPACA_SECRET_KEY'"
    elif [[ -n "$ALPACA_OAUTH_TOKEN" ]]; then
        headers="-H 'Authorization: Bearer $ALPACA_OAUTH_TOKEN'"
    fi
    
    headers="$headers -H 'Content-Type: application/json'"
    
    # Log request in debug mode
    if [[ "$ALPACA_DEBUG" == "true" ]]; then
        alpaca_log "DEBUG" "API Request: $method $endpoint"
        [[ -n "$data" ]] && alpaca_log "DEBUG" "Payload: $data"
    fi
    
    # Make request
    if [[ "$method" == "GET" ]]; then
        response=$(eval "curl -s -w '\n%{http_code}' \
            --connect-timeout $ALPACA_CONNECT_TIMEOUT \
            -m $ALPACA_TIMEOUT \
            $headers \
            '$url'")
    elif [[ "$method" == "POST" ]]; then
        response=$(eval "curl -s -w '\n%{http_code}' \
            --connect-timeout $ALPACA_CONNECT_TIMEOUT \
            -m $ALPACA_TIMEOUT \
            -X POST \
            $headers \
            -d '$data' \
            '$url'")
    elif [[ "$method" == "DELETE" ]]; then
        response=$(eval "curl -s -w '\n%{http_code}' \
            --connect-timeout $ALPACA_CONNECT_TIMEOUT \
            -m $ALPACA_TIMEOUT \
            -X DELETE \
            $headers \
            '$url'")
    else
        alpaca_log "ERROR" "Unsupported HTTP method: $method"
        return 1
    fi
    
    # Parse HTTP code and body
    http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    alpaca_log "DEBUG" "HTTP Response Code: $http_code"
    [[ "$ALPACA_DEBUG" == "true" ]] && alpaca_log "DEBUG" "Response: $body"
    
    # Handle success (200-299)
    if [[ "$http_code" =~ ^2[0-9]{2}$ ]]; then
        echo "$body"
        return 0
    fi
    
    # Handle rate limiting with retry
    if [[ "$http_code" == "429" ]] && [[ $retries -lt $ALPACA_MAX_RETRIES ]]; then
        local backoff=$((ALPACA_INITIAL_BACKOFF * (ALPACA_BACKOFF_MULTIPLIER ** retries)))
        alpaca_log "WARN" "Rate limited. Retrying in ${backoff}s (attempt $((retries + 1))/$ALPACA_MAX_RETRIES)"
        sleep "$backoff"
        alpaca_api_request "$method" "$endpoint" "$data" "$((retries + 1))" "$base_url"
        return $?
    fi
    
    # Handle errors
    alpaca_handle_error "$http_code" "$body"
    return 1
}

# ============================================================================
# API: Connection Test
# ============================================================================

# Test API connection without making changes
# Returns: 0 if connected, 1 if failed
alpaca_check_connection() {
    local response
    
    response=$(alpaca_api_request "GET" "/account" 2>/dev/null) || return 1
    
    # Validate we got account data
    if command -v jq &>/dev/null; then
        if ! echo "$response" | jq -e '.id' &>/dev/null; then
            alpaca_log "ERROR" "Invalid account response"
            return 1
        fi
    fi
    
    alpaca_log "INFO" "Alpaca API connection test passed"
    return 0
}

# ============================================================================
# API: Account Information
# ============================================================================

# Get account details
# Returns: JSON formatted account information
alpaca_get_account() {
    if [[ "$ALPACA_INITIALIZED" != "true" ]]; then
        echo "ERROR: Alpaca not initialized. Call alpaca_init() first"
        return 1
    fi
    
    local response
    response=$(alpaca_api_request "GET" "/account") || { echo "$response"; return 1; }
    
    # Parse and display account info
    if command -v jq &>/dev/null; then
        echo "$response" | jq "$ALPACA_JQ_NUM"'{
            account_id: .id,
            equity: (.equity | num),
            buying_power: (.buying_power | num),
            portfolio_value: (.portfolio_value | num),
            cash: (.cash | num),
            day_trade_buying_power: (.intraday_adjustments // 0 | num),
            status: .status,
            currency: .currency
        }'
    else
        echo "$response"
    fi
    
    alpaca_log "INFO" "Account information retrieved"
    return 0
}

# ============================================================================
# API: Positions Management
# ============================================================================

# Get all open positions
# Returns: JSON array of positions
alpaca_get_positions() {
    if [[ "$ALPACA_INITIALIZED" != "true" ]]; then
        echo "ERROR: Alpaca not initialized. Call alpaca_init() first"
        return 1
    fi
    
    local response
    response=$(alpaca_api_request "GET" "/positions") || { echo "$response"; return 1; }
    
    # Parse and format positions (JSON array, [] when there are none)
    if command -v jq &>/dev/null; then
        echo "$response" | jq "$ALPACA_JQ_NUM"'[.[] | {
            symbol: .symbol,
            quantity: (.qty | num),
            entry_price: (.avg_entry_price // .avg_fill_price | num),
            current_price: (.current_price | num),
            market_value: (.market_value | num),
            unrealized_pl: (.unrealized_pl | num),
            unrealized_plpc: (.unrealized_plpc | num)
        }]'
    else
        echo "$response"
    fi
    
    alpaca_log "INFO" "Positions retrieved"
    return 0
}

# Check if position exists for symbol
# Args: SYMBOL
# Returns: position JSON if exists, empty if not
alpaca_check_position() {
    local symbol="$1"
    
    if ! alpaca_validate_symbol "$symbol"; then
        return 1
    fi
    
    if [[ "$ALPACA_INITIALIZED" != "true" ]]; then
        echo "ERROR: Alpaca not initialized. Call alpaca_init() first"
        return 1
    fi
    
    local response
    response=$(alpaca_api_request "GET" "/positions/$symbol" 2>/dev/null) || return 0
    
    if command -v jq &>/dev/null; then
        echo "$response" | jq "$ALPACA_JQ_NUM"'{
            symbol: .symbol,
            quantity: (.qty | num),
            entry_price: (.avg_entry_price // .avg_fill_price | num),
            current_price: (.current_price | num),
            market_value: (.market_value | num),
            unrealized_pl: (.unrealized_pl | num),
            unrealized_plpc: (.unrealized_plpc | num)
        }'
    else
        echo "$response"
    fi
    
    alpaca_log "INFO" "Position checked for $symbol"
    return 0
}

# ============================================================================
# API: Order Management
# ============================================================================

# Place a market order
# Args: SYMBOL, QTY, SIDE (buy/sell)
# Returns: Order confirmation (ID, status, etc)
alpaca_place_order() {
    local symbol="$1"
    local qty="$2"
    local side="$3"
    
    # Validate inputs
    if ! alpaca_validate_symbol "$symbol"; then
        return 1
    fi
    
    if ! alpaca_validate_quantity "$qty"; then
        return 1
    fi
    
    if ! alpaca_validate_side "$side"; then
        return 1
    fi
    
    if [[ "$ALPACA_INITIALIZED" != "true" ]]; then
        echo "ERROR: Alpaca not initialized. Call alpaca_init() first"
        return 1
    fi
    
    # Construct order payload
    local payload=$(cat <<EOF
{
  "symbol": "$symbol",
  "qty": $qty,
  "side": "$side",
  "type": "market",
  "time_in_force": "day"
}
EOF
)
    
    alpaca_log "INFO" "Placing order: $side $qty shares of $symbol"
    
    local response
    # On failure, pass the API error text (e.g. "ERROR: Unprocessable Entity") to the caller
    response=$(alpaca_api_request "POST" "/orders" "$payload") || { echo "$response"; return 1; }
    
    # Format and return order confirmation
    if command -v jq &>/dev/null; then
        echo "$response" | jq "$ALPACA_JQ_NUM"'{
            order_id: .id,
            symbol: .symbol,
            quantity: (.qty | num),
            side: .side,
            type: .order_type,
            status: .status,
            filled_at: .filled_at,
            filled_avg_price: (.filled_avg_price | num),
            created_at: .created_at
        }'
    else
        echo "$response"
    fi
    
    alpaca_log "INFO" "Order placed successfully: $symbol"
    return 0
}

# Get order status
# Args: ORDER_ID
# Returns: Order details
alpaca_get_order_status() {
    local order_id="$1"
    
    if [[ -z "$order_id" ]]; then
        alpaca_log "ERROR" "Order ID cannot be empty"
        echo "ERROR: Order ID is required"
        return 1
    fi
    
    if [[ "$ALPACA_INITIALIZED" != "true" ]]; then
        echo "ERROR: Alpaca not initialized. Call alpaca_init() first"
        return 1
    fi
    
    local response
    response=$(alpaca_api_request "GET" "/orders/$order_id") || return 1
    
    if command -v jq &>/dev/null; then
        echo "$response" | jq "$ALPACA_JQ_NUM"'{
            order_id: .id,
            symbol: .symbol,
            quantity: (.qty | num),
            side: .side,
            status: .status,
            type: .order_type,
            filled_at: .filled_at,
            filled_avg_price: (.filled_avg_price | num),
            created_at: .created_at,
            updated_at: .updated_at
        }'
    else
        echo "$response"
    fi
    
    alpaca_log "INFO" "Order status retrieved: $order_id"
    return 0
}

# Cancel an order
# Args: ORDER_ID
# Returns: Cancellation status
alpaca_cancel_order() {
    local order_id="$1"
    
    if [[ -z "$order_id" ]]; then
        alpaca_log "ERROR" "Order ID cannot be empty"
        echo "ERROR: Order ID is required"
        return 1
    fi
    
    if [[ "$ALPACA_INITIALIZED" != "true" ]]; then
        echo "ERROR: Alpaca not initialized. Call alpaca_init() first"
        return 1
    fi
    
    alpaca_log "INFO" "Cancelling order: $order_id"
    
    local response
    response=$(alpaca_api_request "DELETE" "/orders/$order_id") || return 1
    
    echo "✓ Order cancelled: $order_id"
    
    alpaca_log "INFO" "Order cancelled successfully: $order_id"
    return 0
}

# ============================================================================
# API: Market Data
# ============================================================================

# Get the latest trade price for a symbol (Alpaca market data API,
# ALPACA_DATA_URL, feed ALPACA_DATA_FEED; default iex works on free accounts)
# Args: SYMBOL
# Returns: JSON {symbol, last_price, timestamp} (same last_price field as
#          robinhood_get_quote)
alpaca_get_quote() {
    local symbol="$1"
    
    if ! alpaca_validate_symbol "$symbol"; then
        return 1
    fi
    
    if [[ "$ALPACA_INITIALIZED" != "true" ]]; then
        echo "ERROR: Alpaca not initialized. Call alpaca_init() first"
        return 1
    fi
    
    local response
    response=$(alpaca_api_request "GET" "/stocks/$symbol/trades/latest?feed=$ALPACA_DATA_FEED" "" 0 "$ALPACA_DATA_API_BASE_URL") || return 1
    
    if command -v jq &>/dev/null; then
        echo "$response" | jq -e --arg sym "$symbol" '{
            symbol: (.symbol // $sym),
            last_price: .trade.p,
            timestamp: .trade.t
        } | select(.last_price != null)' || return 1
    else
        echo "$response"
    fi
    
    alpaca_log "INFO" "Quote retrieved for: $symbol"
    return 0
}

# ============================================================================
# Module Export
# ============================================================================

# Export all functions as public API
export -f alpaca_init
export -f alpaca_check_connection
export -f alpaca_get_account
export -f alpaca_get_positions
export -f alpaca_check_position
export -f alpaca_place_order
export -f alpaca_get_quote
export -f alpaca_get_order_status
export -f alpaca_cancel_order
export -f alpaca_validate_symbol
export -f alpaca_validate_quantity
export -f alpaca_validate_side
export -f alpaca_handle_error
export -f alpaca_format_currency
export -f alpaca_format_percent
export -f alpaca_log

# ============================================================================
# End of Module
# ============================================================================
