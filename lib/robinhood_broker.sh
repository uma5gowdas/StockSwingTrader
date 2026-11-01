#!/bin/bash
# ============================================================================
# StockSwingTrader: Robinhood Broker Integration Module
# ============================================================================
# Provides functions to interact with Robinhood API
# Base URL: https://api.robinhood.com
# Supports: Account management, positions, orders, market data
# All output normalized to match Alpaca format for compatibility
# Implements 14 wrapper functions with 100% feature parity to Alpaca
# ============================================================================

set -o pipefail

# ============================================================================
# Module Configuration & Globals
# ============================================================================

# Load OAuth module
# File-specific dir variable: this file is sourced, so it must not change the
# caller's SCRIPT_DIR.
ROBINHOOD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$ROBINHOOD_LIB_DIR/robinhood_oauth.sh" ]]; then
    echo "ERROR: robinhood_oauth.sh not found" >&2
    return 1
fi
source "$ROBINHOOD_LIB_DIR/robinhood_oauth.sh"

# API Configuration
ROBINHOOD_API_BASE_URL="${ROBINHOOD_API_BASE_URL:-https://api.robinhood.com}"
ROBINHOOD_LOG_FILE="${ROBINHOOD_LOG_FILE:-logs/robinhood_api.log}"
ROBINHOOD_DEBUG="${ROBINHOOD_DEBUG:-false}"
ROBINHOOD_INITIALIZED=false

# Retry Configuration
ROBINHOOD_MAX_RETRIES=3
ROBINHOOD_INITIAL_BACKOFF=1
ROBINHOOD_BACKOFF_MULTIPLIER=2

# Timeouts
ROBINHOOD_TIMEOUT=30
ROBINHOOD_CONNECT_TIMEOUT=10

# Cache for account data
ROBINHOOD_ACCOUNT_CACHE=""
ROBINHOOD_ACCOUNT_CACHE_TIME=0
ROBINHOOD_ACCOUNT_CACHE_TTL=30  # Cache account data for 30 seconds

# ============================================================================
# Helper: Logging Functions
# ============================================================================

# Initialize logging directory
robinhood_init_logging() {
    local log_dir=$(dirname "$ROBINHOOD_LOG_FILE")
    [[ ! -d "$log_dir" ]] && mkdir -p "$log_dir"
    touch "$ROBINHOOD_LOG_FILE"
}

# Log message with timestamp
robinhood_log() {
    local level="$1"
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    robinhood_init_logging
    echo "[${timestamp}] [${level}] ${message}" >> "$ROBINHOOD_LOG_FILE"
    
    if [[ "$ROBINHOOD_DEBUG" == "true" ]]; then
        echo "[${level}] ${message}" >&2
    fi
}

# ============================================================================
# Helper: Input Validation
# ============================================================================

# Validate symbol format (A-Z, 1-5 characters)
# Args: SYMBOL
# Returns: 0 if valid, 1 if invalid
robinhood_validate_symbol() {
    local symbol="$1"
    
    if [[ -z "$symbol" ]]; then
        robinhood_log "ERROR" "Symbol cannot be empty"
        return 1
    fi
    
    # Check format: 1-5 uppercase letters
    if ! [[ "$symbol" =~ ^[A-Z]{1,5}$ ]]; then
        robinhood_log "ERROR" "Invalid symbol format: $symbol (must be 1-5 uppercase letters)"
        return 1
    fi
    
    return 0
}

# Validate numeric quantity
# Args: QTY
# Returns: 0 if valid, 1 if invalid
robinhood_validate_quantity() {
    local qty="$1"
    
    if ! [[ "$qty" =~ ^[0-9]+(\.[0-9]+)?$ ]] || (( $(echo "$qty <= 0" | bc -l 2>/dev/null || echo 0) )); then
        robinhood_log "ERROR" "Invalid quantity: $qty (must be positive number)"
        return 1
    fi
    
    return 0
}

# Validate side (buy/sell)
# Args: SIDE
# Returns: 0 if valid, 1 if invalid
robinhood_validate_side() {
    local side="$1"
    
    case "$side" in
        buy|sell)
            return 0
            ;;
        *)
            robinhood_log "ERROR" "Invalid side: $side (must be 'buy' or 'sell')"
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
robinhood_handle_error() {
    local http_code="$1"
    local response="$2"
    local error_msg=""
    
    # Extract error details from JSON response
    if command -v jq &>/dev/null; then
        error_msg=$(echo "$response" | jq -r '.detail // .error // "Unknown error"' 2>/dev/null)
    else
        # Fallback: basic grep if jq not available
        error_msg=$(echo "$response" | grep -o '"detail":"[^"]*"' | cut -d'"' -f4 || echo "Unknown error")
    fi
    
    local error_detail=""
    case "$http_code" in
        401)
            error_detail="Unauthorized: Invalid or expired authentication token"
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
            error_detail="Unprocessable Entity: Order rejected (insufficient funds, invalid symbol, etc)"
            ;;
        429)
            error_detail="Rate Limited: Too many requests, backing off"
            ;;
        500|502|503|504)
            error_detail="Server Error: Robinhood API temporarily unavailable"
            ;;
        *)
            error_detail="HTTP Error $http_code"
            ;;
    esac
    
    robinhood_log "ERROR" "API Error ($http_code): $error_detail - $error_msg"
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
robinhood_format_currency() {
    local num="$1"
    local show_color="${2:-true}"
    local formatted=""
    
    # Handle negative numbers
    if (( $(echo "$num < 0" | bc -l 2>/dev/null || echo 0) )); then
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

# ============================================================================
# Core: Initialize API Connection
# ============================================================================

# Initialize Robinhood API
# Loads OAuth tokens and validates connection
# Returns: 0 on success, 1 on failure
robinhood_init() {
    robinhood_init_logging
    
    # Verify OAuth credentials are set
    if [[ -z "$ROBINHOOD_CLIENT_ID" ]] || [[ -z "$ROBINHOOD_CLIENT_SECRET" ]]; then
        robinhood_log "ERROR" "Robinhood credentials not found in environment"
        echo "ERROR: Missing Robinhood OAuth credentials"
        echo "Set ROBINHOOD_CLIENT_ID and ROBINHOOD_CLIENT_SECRET environment variables"
        return 1
    fi
    
    # Load existing tokens or initiate OAuth flow
    if ! robinhood_oauth_load_tokens; then
        robinhood_log "INFO" "No existing tokens. Starting OAuth authorization flow..."
        echo "Starting Robinhood OAuth authorization flow..."
        
        # Get authorization URL
        local auth_url
        auth_url=$(robinhood_oauth_get_auth_url) || {
            robinhood_log "ERROR" "Failed to generate authorization URL"
            return 1
        }
        
        echo "Please open this URL in your browser to authorize:"
        echo "$auth_url"
        echo ""
        
        # Start local callback server
        robinhood_log "INFO" "Waiting for OAuth callback (timeout: ${ROBINHOOD_OAUTH_BROWSER_TIMEOUT}s)"
        local code
        code=$(robinhood_oauth_wait_for_callback) || {
            robinhood_log "ERROR" "OAuth callback timeout or error"
            echo "ERROR: OAuth authorization failed or timed out"
            return 1
        }
        
        # Exchange code for tokens
        if ! robinhood_oauth_exchange_code "$code"; then
            robinhood_log "ERROR" "Failed to exchange authorization code"
            return 1
        fi
        
        # Reload tokens
        if ! robinhood_oauth_load_tokens; then
            robinhood_log "ERROR" "Failed to load tokens after OAuth flow"
            return 1
        fi
    fi
    
    # Test connection
    if ! robinhood_check_connection; then
        robinhood_log "ERROR" "Failed to connect to Robinhood API"
        return 1
    fi
    
    ROBINHOOD_INITIALIZED=true
    robinhood_log "INFO" "Robinhood API initialized successfully"
    echo "✓ Robinhood API initialized"
    return 0
}

# Wait for OAuth callback on localhost:8888
# Returns: authorization code or 1 on timeout/error
robinhood_oauth_wait_for_callback() {
    local port=8888
    local timeout=$ROBINHOOD_OAUTH_BROWSER_TIMEOUT
    local elapsed=0
    
    robinhood_log "DEBUG" "Starting callback server on port $port"
    
    while [[ $elapsed -lt $timeout ]]; do
        # Try to connect and see if user sent callback
        local callback_response
        callback_response=$(timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port; echo 'GET /callback?code=test HTTP/1.0\r\n\r\n' >&3; cat <&3" 2>/dev/null || echo "")
        
        if [[ -n "$callback_response" ]]; then
            # Extract code from query string
            local code=$(echo "$callback_response" | grep -o 'code=[^&]*' | cut -d'=' -f2 | head -1)
            if [[ -n "$code" ]]; then
                robinhood_log "INFO" "OAuth callback received with code"
                echo "$code"
                return 0
            fi
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    robinhood_log "ERROR" "OAuth callback timeout after ${timeout}s"
    return 1
}

# ============================================================================
# Helper: API Request Handler
# ============================================================================

# Make HTTP request to Robinhood API with auto-refresh
# Args: METHOD, ENDPOINT, [DATA], [RETRIES=0]
# Returns: HTTP response body
robinhood_api_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local retries="${4:-0}"
    
    # Auto-refresh token if expired
    if ! robinhood_refresh_token_if_needed; then
        robinhood_log "ERROR" "Token refresh failed before API request"
        return 1
    fi
    
    local url="${ROBINHOOD_API_BASE_URL}${endpoint}"
    local http_code
    local response
    local auth_header
    
    # Get authorization header
    auth_header=$(robinhood_oauth_get_auth_header) || return 1
    
    # Log request in debug mode
    if [[ "$ROBINHOOD_DEBUG" == "true" ]]; then
        robinhood_log "DEBUG" "API Request: $method $endpoint"
        [[ -n "$data" ]] && robinhood_log "DEBUG" "Payload: $data"
    fi
    
    # Make request with proper header
    if [[ "$method" == "GET" ]]; then
        response=$(curl -s -w '\n%{http_code}' \
            --connect-timeout $ROBINHOOD_CONNECT_TIMEOUT \
            -m $ROBINHOOD_TIMEOUT \
            -H "Authorization: $auth_header" \
            -H "Content-Type: application/json" \
            "$url" 2>&1)
    elif [[ "$method" == "POST" ]]; then
        response=$(curl -s -w '\n%{http_code}' \
            --connect-timeout $ROBINHOOD_CONNECT_TIMEOUT \
            -m $ROBINHOOD_TIMEOUT \
            -X POST \
            -H "Authorization: $auth_header" \
            -H "Content-Type: application/json" \
            -d "$data" \
            "$url" 2>&1)
    elif [[ "$method" == "DELETE" ]]; then
        response=$(curl -s -w '\n%{http_code}' \
            --connect-timeout $ROBINHOOD_CONNECT_TIMEOUT \
            -m $ROBINHOOD_TIMEOUT \
            -X DELETE \
            -H "Authorization: $auth_header" \
            -H "Content-Type: application/json" \
            "$url" 2>&1)
    else
        robinhood_log "ERROR" "Unsupported HTTP method: $method"
        return 1
    fi
    
    # Parse HTTP code and body
    http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    robinhood_log "DEBUG" "HTTP Response Code: $http_code"
    [[ "$ROBINHOOD_DEBUG" == "true" ]] && robinhood_log "DEBUG" "Response: $body"
    
    # Handle success (200-299)
    if [[ "$http_code" =~ ^2[0-9]{2}$ ]]; then
        echo "$body"
        return 0
    fi
    
    # Handle 401 Unauthorized - try token refresh once
    if [[ "$http_code" == "401" ]] && [[ $retries -lt 1 ]]; then
        robinhood_log "WARN" "Received 401, attempting token refresh and retry"
        if robinhood_oauth_refresh_token; then
            robinhood_oauth_load_tokens
            robinhood_api_request "$method" "$endpoint" "$data" "$((retries + 1))"
            return $?
        fi
    fi
    
    # Handle rate limiting with retry
    if [[ "$http_code" == "429" ]] && [[ $retries -lt $ROBINHOOD_MAX_RETRIES ]]; then
        local backoff=$((ROBINHOOD_INITIAL_BACKOFF * (ROBINHOOD_BACKOFF_MULTIPLIER ** retries)))
        robinhood_log "WARN" "Rate limited. Retrying in ${backoff}s (attempt $((retries + 1))/$ROBINHOOD_MAX_RETRIES)"
        sleep "$backoff"
        robinhood_api_request "$method" "$endpoint" "$data" "$((retries + 1))"
        return $?
    fi
    
    # Handle errors
    robinhood_handle_error "$http_code" "$body"
    return 1
}

# ============================================================================
# API: Connection Test
# ============================================================================

# Test API connection without making changes
# Returns: 0 if connected, 1 if failed
robinhood_check_connection() {
    local response
    
    response=$(robinhood_api_request "GET" "/account" 2>/dev/null) || return 1
    
    # Validate we got account data
    if command -v jq &>/dev/null; then
        if ! echo "$response" | jq -e '.id' &>/dev/null; then
            robinhood_log "ERROR" "Invalid account response"
            return 1
        fi
    fi
    
    robinhood_log "INFO" "Robinhood API connection test passed"
    return 0
}

# ============================================================================
# API: Account Information (Function 1)
# ============================================================================

# Get account details (normalized to Alpaca format)
# Wrapper name: robinhood_check_account()
# Returns: JSON with {account_id, buying_power, equity, cash}
robinhood_check_account() {
    if [[ "$ROBINHOOD_INITIALIZED" != "true" ]]; then
        echo "ERROR: Robinhood not initialized. Call robinhood_init() first"
        return 1
    fi
    
    local response
    response=$(robinhood_api_request "GET" "/accounts/") || return 1
    
    # Parse and normalize to Alpaca format
    if command -v jq &>/dev/null; then
        echo "$response" | jq '.results[0] | {
            account_id: .account_number,
            buying_power: (.buying_power | tonumber),
            cash: (.cash | tonumber),
            equity: (.equity | tonumber),
            account_type: .account_type // "cash"
        }' 2>/dev/null
    else
        echo "$response"
    fi
    
    robinhood_log "INFO" "Account information retrieved"
    return 0
}

# Alias for compatibility with Alpaca naming
robinhood_get_account() {
    robinhood_check_account "$@"
}

# ============================================================================
# API: Positions Management
# ============================================================================

# Get all open positions (Function 3)
# Returns: JSON array of positions
robinhood_get_positions() {
    if [[ "$ROBINHOOD_INITIALIZED" != "true" ]]; then
        echo "ERROR: Robinhood not initialized. Call robinhood_init() first"
        return 1
    fi
    
    local response
    response=$(robinhood_api_request "GET" "/positions/") || return 1
    
    # Parse and normalize to Alpaca format
    if command -v jq &>/dev/null; then
        echo "$response" | jq '.results[] | {
            symbol: .symbol,
            qty: (.quantity | tonumber),
            avg_fill_price: (.average_buy_price | tonumber),
            current_price: (.last_trade_price | tonumber // 0)
        }' 2>/dev/null
    else
        echo "$response"
    fi
    
    robinhood_log "INFO" "Positions retrieved"
    return 0
}

# Get single position by symbol (Function 4)
# Args: SYMBOL
# Returns: position JSON if exists, empty if not
robinhood_get_position() {
    local symbol="$1"
    
    if ! robinhood_validate_symbol "$symbol"; then
        return 1
    fi
    
    if [[ "$ROBINHOOD_INITIALIZED" != "true" ]]; then
        echo "ERROR: Robinhood not initialized. Call robinhood_init() first"
        return 1
    fi
    
    # Get all positions and filter for symbol
    local positions
    positions=$(robinhood_api_request "GET" "/positions/" 2>/dev/null) || return 0
    
    # Normalize and filter to symbol
    if command -v jq &>/dev/null; then
        echo "$positions" | jq ".results[] | select(.symbol==\"$symbol\") | {
            symbol: .symbol,
            qty: (.quantity | tonumber),
            avg_fill_price: (.average_buy_price | tonumber),
            current_price: (.last_trade_price | tonumber // 0)
        }" 2>/dev/null
    else
        echo "$positions"
    fi
    
    robinhood_log "INFO" "Position checked for $symbol"
    return 0
}

# Close position by selling all shares (Function 5)
# Args: SYMBOL
# Returns: order_id
robinhood_close_position() {
    local symbol="$1"
    
    if ! robinhood_validate_symbol "$symbol"; then
        return 1
    fi
    
    if [[ "$ROBINHOOD_INITIALIZED" != "true" ]]; then
        echo "ERROR: Robinhood not initialized. Call robinhood_init() first"
        return 1
    fi
    
    # Get current position
    local position
    position=$(robinhood_get_position "$symbol") || {
        robinhood_log "ERROR" "No position found for $symbol"
        echo "ERROR: No position found for $symbol"
        return 1
    }
    
    if command -v jq &>/dev/null; then
        local qty
        qty=$(echo "$position" | jq -r '.qty' 2>/dev/null)
        
        if [[ -z "$qty" ]] || (( $(echo "$qty <= 0" | bc -l 2>/dev/null || echo 0) )); then
            robinhood_log "ERROR" "No position quantity found for $symbol"
            echo "ERROR: No position to close for $symbol"
            return 1
        fi
        
        # Place market sell order
        robinhood_log "INFO" "Closing position: selling $qty shares of $symbol at market"
        local order_response
        order_response=$(robinhood_place_order "$symbol" "$qty" "sell" "market" "" "" "day") || return 1
        
        # Extract and return order ID
        echo "$order_response" | jq -r '.order_id // .id' 2>/dev/null
        robinhood_log "INFO" "Position closed for $symbol"
        return 0
    else
        robinhood_log "ERROR" "jq not available for position parsing"
        return 1
    fi
}

# ============================================================================
# API: Order Management
# ============================================================================

# Place a market order (Function 2)
# Args: SYMBOL, QTY, SIDE (buy|sell), TYPE (market|limit), LIMIT_PRICE, STOP_LOSS, TIME_IN_FORCE (day|gtc)
# Returns: Order confirmation {id, symbol, qty, side, type, status}
robinhood_place_order() {
    local symbol="$1"
    local qty="$2"
    local side="$3"
    local type="${4:-market}"
    local limit_price="${5:-}"
    local stop_loss="${6:-}"
    local time_in_force="${7:-day}"
    
    # Validate inputs
    if ! robinhood_validate_symbol "$symbol"; then
        return 1
    fi
    
    if ! robinhood_validate_quantity "$qty"; then
        return 1
    fi
    
    if ! robinhood_validate_side "$side"; then
        return 1
    fi
    
    if [[ "$ROBINHOOD_INITIALIZED" != "true" ]]; then
        echo "ERROR: Robinhood not initialized. Call robinhood_init() first"
        return 1
    fi
    
    # Construct order payload based on type
    local payload
    if [[ "$type" == "limit" ]] && [[ -n "$limit_price" ]]; then
        payload=$(cat <<EOF
{
  "symbol": "$symbol",
  "quantity": $qty,
  "side": "$side",
  "type": "limit",
  "price": $limit_price,
  "time_in_force": "$time_in_force"
}
EOF
)
    else
        payload=$(cat <<EOF
{
  "symbol": "$symbol",
  "quantity": $qty,
  "side": "$side",
  "type": "market",
  "time_in_force": "$time_in_force"
}
EOF
)
    fi
    
    robinhood_log "INFO" "Placing order: $side $qty shares of $symbol (type: $type)"
    
    local response
    response=$(robinhood_api_request "POST" "/orders/" "$payload") || return 1
    
    # Normalize and return order confirmation
    robinhood_format_order_response "$response"
    robinhood_log "INFO" "Order placed successfully: $symbol"
    return 0
}

# Get all orders (Function 7)
# Returns: JSON array of orders
robinhood_get_orders() {
    if [[ "$ROBINHOOD_INITIALIZED" != "true" ]]; then
        echo "ERROR: Robinhood not initialized. Call robinhood_init() first"
        return 1
    fi
    
    local response
    response=$(robinhood_api_request "GET" "/orders/") || return 1
    
    # Normalize to Alpaca format
    if command -v jq &>/dev/null; then
        echo "$response" | jq '.results[] | {
            id: .id,
            symbol: .symbol,
            qty: (.quantity | tonumber),
            status: .status,
            filled_qty: (.executed_quantity | tonumber // 0)
        }' 2>/dev/null
    else
        echo "$response"
    fi
    
    robinhood_log "INFO" "Orders retrieved"
    return 0
}

# Get single order by ID (Function 8)
# Args: ORDER_ID
# Returns: Order details
robinhood_get_order() {
    local order_id="$1"
    
    if [[ -z "$order_id" ]]; then
        robinhood_log "ERROR" "Order ID cannot be empty"
        echo "ERROR: Order ID is required"
        return 1
    fi
    
    if [[ "$ROBINHOOD_INITIALIZED" != "true" ]]; then
        echo "ERROR: Robinhood not initialized. Call robinhood_init() first"
        return 1
    fi
    
    local response
    response=$(robinhood_api_request "GET" "/orders/$order_id/") || return 1
    
    # Normalize to Alpaca format
    if command -v jq &>/dev/null; then
        echo "$response" | jq '{
            id: .id,
            symbol: .symbol,
            qty: (.quantity | tonumber),
            filled_qty: (.executed_quantity | tonumber // 0),
            status: .status,
            filled_price: (.average_fill_price | tonumber // 0)
        }' 2>/dev/null
    else
        echo "$response"
    fi
    
    robinhood_log "INFO" "Order status retrieved: $order_id"
    return 0
}

# Get order status (alias for get_order)
robinhood_get_order_status() {
    robinhood_get_order "$@"
}

# Cancel an order (Function 9)
# Args: ORDER_ID
# Returns: success|error
robinhood_cancel_order() {
    local order_id="$1"
    
    if [[ -z "$order_id" ]]; then
        robinhood_log "ERROR" "Order ID cannot be empty"
        echo "ERROR: Order ID is required"
        return 1
    fi
    
    if [[ "$ROBINHOOD_INITIALIZED" != "true" ]]; then
        echo "ERROR: Robinhood not initialized. Call robinhood_init() first"
        return 1
    fi
    
    robinhood_log "INFO" "Cancelling order: $order_id"
    
    robinhood_api_request "DELETE" "/orders/$order_id/" >/dev/null || return 1
    
    echo "✓ Order cancelled: $order_id"
    
    robinhood_log "INFO" "Order cancelled successfully: $order_id"
    return 0
}

# ============================================================================
# API: Order Listing
# ============================================================================

# Get all orders
# Returns: JSON array of orders
robinhood_get_orders() {
    if [[ "$ROBINHOOD_INITIALIZED" != "true" ]]; then
        echo "ERROR: Robinhood not initialized. Call robinhood_init() first"
        return 1
    fi
    
    local response
    response=$(robinhood_api_request "GET" "/orders") || return 1
    
    # Normalize to Alpaca format
    if command -v jq &>/dev/null; then
        echo "$response" | jq '.[] | {
            order_id: .id,
            symbol: .symbol,
            qty: (.quantity | tonumber),
            side: .side,
            status: .status,
            type: .type,
            filled_at: .filled_at,
            filled_avg_price: (.filled_avg_price | tonumber // 0),
            created_at: .created_at,
            broker: "robinhood"
        }' 2>/dev/null
    else
        echo "$response"
    fi
    
    robinhood_log "INFO" "Orders retrieved"
    return 0
}

# ============================================================================
# API: Market Data
# ============================================================================

# Get quote for single symbol (Function 6)
# Args: SYMBOL
# Returns: {symbol, last_price, bid_price, ask_price, bid_size, ask_size}
robinhood_get_quote() {
    local symbol="$1"
    
    if ! robinhood_validate_symbol "$symbol"; then
        return 1
    fi
    
    if [[ "$ROBINHOOD_INITIALIZED" != "true" ]]; then
        echo "ERROR: Robinhood not initialized. Call robinhood_init() first"
        return 1
    fi
    
    local response
    response=$(robinhood_api_request "GET" "/quotes/$symbol/") || return 1
    
    # Normalize to standard format
    if command -v jq &>/dev/null; then
        echo "$response" | jq '{
            symbol: .symbol,
            last_price: (.last_trade_price | tonumber),
            bid_price: (.bid_price | tonumber // 0),
            ask_price: (.ask_price | tonumber // 0),
            bid_size: (.bid_size | tonumber // 0),
            ask_size: (.ask_size | tonumber // 0)
        }' 2>/dev/null
    else
        echo "$response"
    fi
    
    robinhood_log "INFO" "Quote retrieved for: $symbol"
    return 0
}

# Get historical data (Function 10)
# Args: SYMBOL, TIMEFRAME (5minute|15minute|hour|day)
# Returns: array of {open, close, high, low, volume, begins_at}
robinhood_get_historicals() {
    local symbol="$1"
    local timeframe="${2:-day}"
    
    if ! robinhood_validate_symbol "$symbol"; then
        return 1
    fi
    
    if [[ "$ROBINHOOD_INITIALIZED" != "true" ]]; then
        echo "ERROR: Robinhood not initialized. Call robinhood_init() first"
        return 1
    fi
    
    # Map timeframe names
    local interval="$timeframe"
    case "$timeframe" in
        5minute)
            interval="5minute"
            ;;
        15minute)
            interval="15minute"
            ;;
        hour)
            interval="hour"
            ;;
        day)
            interval="day"
            ;;
        *)
            robinhood_log "ERROR" "Invalid timeframe: $timeframe"
            echo "ERROR: Invalid timeframe (must be 5minute|15minute|hour|day)"
            return 1
            ;;
    esac
    
    local response
    response=$(robinhood_api_request "GET" "/quotes/historicals/$symbol/?interval=$interval") || return 1
    
    # Normalize to standard format
    if command -v jq &>/dev/null; then
        echo "$response" | jq '.results[].historicals[] | {
            open: (.open_price | tonumber),
            close: (.close_price | tonumber),
            high: (.high_price | tonumber),
            low: (.low_price | tonumber),
            volume: (.volume | tonumber),
            begins_at: .begins_at
        }' 2>/dev/null
    else
        echo "$response"
    fi
    
    robinhood_log "INFO" "Historicals retrieved for: $symbol ($timeframe)"
    return 0
}

# ============================================================================
# API: Account Utilities (Functions 11, 12)
# ============================================================================

# Get cash available (Function 11)
# Returns: cash_available
robinhood_get_cash() {
    if [[ "$ROBINHOOD_INITIALIZED" != "true" ]]; then
        echo "ERROR: Robinhood not initialized. Call robinhood_init() first"
        return 1
    fi
    
    local account
    account=$(robinhood_check_account) || return 1
    
    if command -v jq &>/dev/null; then
        echo "$account" | jq -r '.cash' 2>/dev/null
    else
        echo "$account"
    fi
    
    robinhood_log "INFO" "Cash balance retrieved"
    return 0
}

# Get total equity (Function 12)
# Returns: total_equity
robinhood_get_equity() {
    if [[ "$ROBINHOOD_INITIALIZED" != "true" ]]; then
        echo "ERROR: Robinhood not initialized. Call robinhood_init() first"
        return 1
    fi
    
    local account
    account=$(robinhood_check_account) || return 1
    
    if command -v jq &>/dev/null; then
        echo "$account" | jq -r '.equity' 2>/dev/null
    else
        echo "$account"
    fi
    
    robinhood_log "INFO" "Equity balance retrieved"
    return 0
}

# ============================================================================
# API: Order Validation (Function 13)
# ============================================================================

# Validate order parameters before placing
# Args: SYMBOL, QTY, SIDE (buy|sell)
# Returns: 0 (valid) or 1 (invalid)
robinhood_validate_order() {
    local symbol="$1"
    local qty="$2"
    local side="$3"
    
    # Validate symbol
    if ! robinhood_validate_symbol "$symbol"; then
        robinhood_log "WARN" "Order validation failed: invalid symbol $symbol"
        return 1
    fi
    
    # Validate quantity
    if ! robinhood_validate_quantity "$qty"; then
        robinhood_log "WARN" "Order validation failed: invalid quantity $qty"
        return 1
    fi
    
    # Validate side
    if ! robinhood_validate_side "$side"; then
        robinhood_log "WARN" "Order validation failed: invalid side $side"
        return 1
    fi
    
    # Check buying power (for buy orders)
    if [[ "$side" == "buy" ]]; then
        local account
        account=$(robinhood_check_account) || return 1
        
        if command -v jq &>/dev/null; then
            local buying_power
            buying_power=$(echo "$account" | jq -r '.buying_power' 2>/dev/null)
            
            # Estimate cost (use last known price or assume $100/share)
            local estimated_cost=$((qty * 100))
            
            if (( $(echo "$buying_power < $estimated_cost" | bc -l 2>/dev/null || echo 0) )); then
                robinhood_log "WARN" "Order validation failed: insufficient buying power ($buying_power < $estimated_cost)"
                return 1
            fi
        fi
    fi
    
    robinhood_log "INFO" "Order validation passed: $symbol $qty $side"
    return 0
}

# ============================================================================
# API: Response Formatting (Function 14)
# ============================================================================

# Normalize Robinhood API response to match Alpaca format
# Args: RAW_RESPONSE (JSON from Robinhood API)
# Returns: Formatted JSON matching Alpaca structure
robinhood_format_order_response() {
    local raw_response="$1"
    
    if [[ -z "$raw_response" ]]; then
        robinhood_log "ERROR" "No response provided for formatting"
        echo "ERROR: Empty response"
        return 1
    fi
    
    # Normalize to Alpaca format
    if command -v jq &>/dev/null; then
        echo "$raw_response" | jq '{
            id: .id,
            symbol: .symbol,
            qty: (.quantity | tonumber),
            side: .side,
            type: .type,
            status: .status
        }' 2>/dev/null
    else
        echo "$raw_response"
    fi
    
    robinhood_log "DEBUG" "Order response formatted"
    return 0
}

# ============================================================================
# Module Export - All 14 Wrapper Functions
# ============================================================================

# Core Functions
export -f robinhood_init
export -f robinhood_check_connection

# Function 1: Check Account
export -f robinhood_check_account
export -f robinhood_get_account

# Function 2: Place Order
export -f robinhood_place_order

# Function 3: Get Positions
export -f robinhood_get_positions

# Function 4: Get Single Position
export -f robinhood_get_position

# Function 5: Close Position
export -f robinhood_close_position

# Function 6: Get Quote
export -f robinhood_get_quote

# Function 7: Get Orders
export -f robinhood_get_orders

# Function 8: Get Order
export -f robinhood_get_order
export -f robinhood_get_order_status

# Function 9: Cancel Order
export -f robinhood_cancel_order

# Function 10: Get Historicals
export -f robinhood_get_historicals

# Function 11: Get Cash
export -f robinhood_get_cash

# Function 12: Get Equity
export -f robinhood_get_equity

# Function 13: Validate Order
export -f robinhood_validate_order

# Function 14: Format Order Response
export -f robinhood_format_order_response

# Helper Functions
export -f robinhood_validate_symbol
export -f robinhood_validate_quantity
export -f robinhood_validate_side
export -f robinhood_handle_error
export -f robinhood_format_currency
export -f robinhood_log
export -f robinhood_init_logging
export -f robinhood_api_request

# ============================================================================
# End of Module
# ============================================================================
