#!/bin/bash
# ============================================================================
# StockSwingTrader: Alpaca Broker Integration Module
# ============================================================================
# Provides functions to interact with Alpaca Paper Trading API
# Base URL: https://paper-api.alpaca.markets/v2
# Supports: Account management, positions, orders (market / limit / bracket,
#           client_order_id lookup after a lost answer), clock, calendar,
#           market data
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

# Timeouts (ALPACA_TIMEOUT_SECONDS from config/env; whole request, seconds)
ALPACA_TIMEOUT="${ALPACA_TIMEOUT_SECONDS:-30}"
ALPACA_CONNECT_TIMEOUT=10

# HTTP code of the last alpaca_api_request ("000" = no answer / transport
# failure). Only visible to the caller when the request ran in the current
# shell (not inside $(...)); alpaca_submit_order relies on that.
ALPACA_LAST_HTTP_CODE=""

# client_order_id lookups after a lost POST answer (attempts, 1 s apart)
ALPACA_LOOKUP_ATTEMPTS="${ALPACA_LOOKUP_ATTEMPTS:-3}"

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
# Returns: HTTP response body (0 on 2xx); sets ALPACA_LAST_HTTP_CODE
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
    [[ "$http_code" =~ ^[0-9]{3}$ ]] || http_code="000"
    ALPACA_LAST_HTTP_CODE="$http_code"
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
# Returns: JSON formatted account information; account_id is masked
#          ("****" + last 4 chars); last_equity (prior close),
#          pattern_day_trader and daytrade_count for loss/PDT checks
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
            account_id: ("****" + ((.id // "") | tostring | .[-4:])),
            equity: (.equity | num),
            last_equity: (.last_equity | num),
            buying_power: (.buying_power | num),
            portfolio_value: (.portfolio_value | num),
            cash: (.cash | num),
            day_trade_buying_power: (.intraday_adjustments // 0 | num),
            status: .status,
            currency: .currency,
            pattern_day_trader: .pattern_day_trader,
            daytrade_count: (.daytrade_count | num)
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

# jq program: Alpaca order -> the order confirmation printed by the place /
# submit functions (legs: bracket take-profit / stop-loss children)
ALPACA_JQ_ORDER="$ALPACA_JQ_NUM"'
def leg: {
    type: (.order_type // .type),
    side: .side,
    status: .status,
    limit_price: (.limit_price | num),
    stop_price: (.stop_price | num)
};
{
    order_id: .id,
    client_order_id: .client_order_id,
    symbol: .symbol,
    quantity: (.qty | num),
    side: .side,
    type: (.order_type // .type),
    order_class: .order_class,
    time_in_force: .time_in_force,
    limit_price: (.limit_price | num),
    stop_price: (.stop_price | num),
    status: .status,
    filled_qty: (.filled_qty | num),
    filled_at: .filled_at,
    filled_avg_price: (.filled_avg_price | num),
    created_at: .created_at,
    legs: [(.legs // [])[] | leg]
}'

# Validate a client_order_id (safe inside the request URL and payload)
# Args: CLIENT_ORDER_ID
# Returns: 0 if valid (1-128 of A-Z a-z 0-9 . _ : -), 1 if invalid
alpaca_validate_client_order_id() {
    [[ "$1" =~ ^[A-Za-z0-9._:-]{1,128}$ ]]
}

# Round a price the way Alpaca accepts it (>= $1: 2 decimals, < $1: 4)
# Args: PRICE (positive number)
# Returns: rounded price string (e.g. 123.456 -> 123.46, 0.12345 -> 0.1235)
# Example: alpaca_round_price 123.456
alpaca_round_price() {
    local price="$1"
    if ! [[ "$price" =~ ^[0-9]+(\.[0-9]+)?$|^\.[0-9]+$ ]]; then
        echo "invalid price: $price" >&2
        return 1
    fi
    LC_ALL=C awk -v p="$price" 'BEGIN {
        if (p + 0 <= 0) exit 1
        if (p + 0 >= 1) printf "%.2f\n", p; else printf "%.4f\n", p
    }'
}

# Print {"error": MESSAGE} (module error convention) and return 1
_alpaca_payload_error() {
    jq -cn --arg e "$1" '{error: $e}'
    alpaca_log "ERROR" "Order payload: $1"
    return 1
}

# Build an Alpaca order payload (pure: no network, no state)
# Args: SYMBOL QTY SIDE TYPE LIMIT_PRICE TIF CLIENT_ORDER_ID [STOP_PRICE] [TAKE_PROFIT_PRICE]
#   TYPE         market | limit | stop (stop: STOP_PRICE is the trigger, no bracket)
#   LIMIT_PRICE  required for limit, ignored for market/stop
#   TIF          empty = market: day, limit: ORDER_TIME_IN_FORCE (day),
#                bracket: BRACKET_TIME_IN_FORCE (gtc), stop: gtc
#   STOP_PRICE + TAKE_PROFIT_PRICE (market/limit) = bracket order
# Returns: compact JSON payload (qty number, prices strings); 1 + {"error":...}
#          on invalid input
# Example: alpaca_build_order_payload AAPL 2 buy limit 123.45 "" sst-1 118 133
alpaca_build_order_payload() {
    local symbol="$1" qty="$2" side="$3" type="${4:-market}" limit_price="${5:-}"
    local tif="${6:-}" client_order_id="${7:-}" stop_price="${8:-}" take_profit="${9:-}"
    local bracket=false

    alpaca_validate_symbol "$symbol" || { _alpaca_payload_error "invalid symbol: $symbol"; return 1; }
    alpaca_validate_quantity "$qty" || { _alpaca_payload_error "invalid quantity: $qty"; return 1; }
    alpaca_validate_side "$side" || { _alpaca_payload_error "invalid side: $side"; return 1; }
    if [[ -n "$client_order_id" ]] && ! alpaca_validate_client_order_id "$client_order_id"; then
        _alpaca_payload_error "invalid client_order_id"
        return 1
    fi

    case "$type" in
        market) limit_price="" ;;
        limit)
            [[ -n "$limit_price" ]] || { _alpaca_payload_error "limit order requires a limit price"; return 1; }
            limit_price=$(alpaca_round_price "$limit_price" 2>/dev/null) || {
                _alpaca_payload_error "invalid limit price: $5"; return 1; }
            ;;
        stop)
            limit_price=""
            [[ -n "$stop_price" ]] || { _alpaca_payload_error "stop order requires a stop price"; return 1; }
            [[ -z "$take_profit" ]] || { _alpaca_payload_error "stop order cannot have a take profit"; return 1; }
            ;;
        *) _alpaca_payload_error "invalid order type: $type (market, limit or stop)"; return 1 ;;
    esac

    if [[ -n "$stop_price" ]]; then
        stop_price=$(alpaca_round_price "$stop_price" 2>/dev/null) || {
            _alpaca_payload_error "invalid stop price: $8"; return 1; }
    fi
    if [[ -n "$take_profit" ]]; then
        take_profit=$(alpaca_round_price "$take_profit" 2>/dev/null) || {
            _alpaca_payload_error "invalid take profit price: $9"; return 1; }
    fi
    if [[ "$type" != "stop" ]]; then
        if [[ -n "$stop_price" && -n "$take_profit" ]]; then
            bracket=true
            # Buy: take profit above the stop; sell: below it
            if ! awk -v s="$side" -v sl="$stop_price" -v tp="$take_profit" \
                'BEGIN { exit !((s == "buy" && tp > sl) || (s == "sell" && tp < sl)) }'; then
                _alpaca_payload_error "bracket $side: take profit $take_profit and stop $stop_price are on the wrong sides"
                return 1
            fi
        elif [[ -n "$stop_price" || -n "$take_profit" ]]; then
            _alpaca_payload_error "bracket order needs both a stop price and a take profit price"
            return 1
        fi
    fi

    if [[ -z "$tif" ]]; then
        if [[ "$bracket" == "true" ]]; then
            tif="${BRACKET_TIME_IN_FORCE:-gtc}"
        elif [[ "$type" == "limit" ]]; then
            tif="${ORDER_TIME_IN_FORCE:-day}"
        elif [[ "$type" == "stop" ]]; then
            tif="gtc"
        else
            tif="day"
        fi
    fi
    case "$tif" in
        day|gtc|opg|cls|ioc|fok) ;;
        *) _alpaca_payload_error "invalid time_in_force: $tif"; return 1 ;;
    esac

    jq -cn --arg symbol "$symbol" --arg qty "$qty" --arg side "$side" --arg type "$type" \
        --arg tif "$tif" --arg limit "$limit_price" --arg coid "$client_order_id" \
        --arg stop "$stop_price" --arg tp "$take_profit" --arg bracket "$bracket" '
        {symbol: $symbol, qty: ($qty | tonumber), side: $side, type: $type, time_in_force: $tif}
        + (if $limit != "" then {limit_price: $limit} else {} end)
        + (if $type == "stop" then {stop_price: $stop} else {} end)
        + (if $bracket == "true"
           then {order_class: "bracket", take_profit: {limit_price: $tp}, stop_loss: {stop_price: $stop}}
           else {} end)
        + (if $coid != "" then {client_order_id: $coid} else {} end)'
}

# Submit an order payload (from alpaca_build_order_payload)
# After a transport failure (no answer / timeout, HTTP 000) or a 5xx the order
# may still have reached Alpaca, so it is looked up by its client_order_id
# (never resubmitted). HTTP 4xx = rejected.
# Args: PAYLOAD_JSON
# Returns: 0 + order confirmation JSON (ALPACA_JQ_ORDER; "confirmed_by":
#          "client_order_id_lookup" when found by lookup); 1 + error text
#          when rejected, refused, or the outcome is unknown
alpaca_submit_order() {
    local payload="$1"

    if [[ "$ALPACA_INITIALIZED" != "true" ]]; then
        echo "ERROR: Alpaca not initialized. Call alpaca_init() first"
        return 1
    fi
    # alpaca_api_request quotes the body as -d '...' inside eval
    if [[ "$payload" == *"'"* ]]; then
        echo "ERROR: order payload refused (contains a single quote)"
        alpaca_log "ERROR" "Order payload refused: single quote"
        return 1
    fi
    if ! echo "$payload" | jq -e 'type == "object" and has("symbol")' >/dev/null 2>&1; then
        echo "ERROR: order payload refused (not a JSON order object)"
        return 1
    fi

    local client_order_id symbol summary
    client_order_id=$(echo "$payload" | jq -r '.client_order_id // ""')
    symbol=$(echo "$payload" | jq -r '.symbol')
    summary=$(echo "$payload" | jq -r '"\(.side) \(.qty) \(.symbol) \(.type) \(.order_class // "simple") \(.time_in_force)"')
    if [[ -n "$client_order_id" ]] && ! alpaca_validate_client_order_id "$client_order_id"; then
        echo "ERROR: order payload refused (invalid client_order_id)"
        return 1
    fi

    alpaca_log "INFO" "Placing order: $summary${client_order_id:+ (client_order_id $client_order_id)}"

    # Run in this shell (not $(...)) so ALPACA_LAST_HTTP_CODE is visible here
    local tmp rc code response
    tmp=$(mktemp "${TMPDIR:-/tmp}/sst_alpaca_order.XXXXXX") || return 1
    ALPACA_LAST_HTTP_CODE=""
    alpaca_api_request "POST" "/orders" "$payload" > "$tmp"
    rc=$?
    code="${ALPACA_LAST_HTTP_CODE:-000}"
    response=$(cat "$tmp")
    rm -f "$tmp"

    if [[ $rc -eq 0 ]]; then
        echo "$response" | jq "$ALPACA_JQ_ORDER"
        alpaca_log "INFO" "Order placed successfully: $symbol"
        return 0
    fi

    if [[ "$code" == "000" || "$code" =~ ^5[0-9][0-9]$ ]]; then
        alpaca_log "WARN" "Order POST failed (HTTP $code); checking client_order_id before anything else"
        if [[ -z "$client_order_id" ]]; then
            echo "$response"
            echo "ERROR: order outcome unknown (HTTP $code, no client_order_id to look up). Check open orders before retrying."
            return 1
        fi
        local attempt=1 found=""
        while [[ $attempt -le $ALPACA_LOOKUP_ATTEMPTS ]]; do
            found=$(alpaca_api_request "GET" "/orders:by_client_order_id?client_order_id=$client_order_id" 2>/dev/null) && \
                echo "$found" | jq -e '.id' >/dev/null 2>&1 && break
            found=""
            [[ $attempt -lt $ALPACA_LOOKUP_ATTEMPTS ]] && sleep 1
            attempt=$((attempt + 1))
        done
        if [[ -n "$found" ]]; then
            echo "$found" | jq "$ALPACA_JQ_ORDER"' + {confirmed_by: "client_order_id_lookup"}'
            alpaca_log "INFO" "Order confirmed by client_order_id lookup: $client_order_id"
            return 0
        fi
        echo "$response"
        echo "ERROR: order outcome unknown (HTTP $code; client_order_id $client_order_id not found). Check open orders before retrying."
        alpaca_log "ERROR" "Order outcome unknown: $client_order_id"
        return 1
    fi

    # 4xx: rejected. Pass the API error text (e.g. "ERROR: Unprocessable Entity") on
    echo "$response"
    return 1
}

# Place an order (market by default)
# Args: SYMBOL, QTY, SIDE (buy/sell), [TYPE=market], [LIMIT_PRICE],
#       [CLIENT_ORDER_ID], [TIF] (defaults: see alpaca_build_order_payload)
# Returns: Order confirmation (ID, status, etc); the 3-argument call sends
#          {symbol, qty, side, type: market, time_in_force: day}
alpaca_place_order() {
    local symbol="$1" qty="$2" side="$3" type="${4:-market}" limit_price="${5:-}"
    local client_order_id="${6:-}" tif="${7:-}"
    local payload

    if [[ "$ALPACA_INITIALIZED" != "true" ]]; then
        echo "ERROR: Alpaca not initialized. Call alpaca_init() first"
        return 1
    fi

    payload=$(alpaca_build_order_payload "$symbol" "$qty" "$side" "$type" "$limit_price" "$tif" "$client_order_id") || {
        echo "$payload"; return 1; }
    alpaca_submit_order "$payload"
}

# Place a bracket order: entry + take-profit limit + stop-loss stop (Alpaca
# order_class bracket; the legs inherit the time in force)
# Args: SYMBOL QTY SIDE LIMIT_PRICE STOP_PRICE TAKE_PROFIT [CLIENT_ORDER_ID]
#       [TYPE=limit] [TIF=${BRACKET_TIME_IN_FORCE:-gtc}]
# Returns: order confirmation JSON with legs; 1 on error
# Example: alpaca_place_bracket_order AAPL 2 buy 123.70 117.50 133.60 sst-AAPL-b-...
alpaca_place_bracket_order() {
    local symbol="$1" qty="$2" side="$3" limit_price="$4" stop_price="$5" take_profit="$6"
    local client_order_id="${7:-}" type="${8:-limit}" tif="${9:-${BRACKET_TIME_IN_FORCE:-gtc}}"
    local payload

    if [[ "$ALPACA_INITIALIZED" != "true" ]]; then
        echo "ERROR: Alpaca not initialized. Call alpaca_init() first"
        return 1
    fi
    if [[ -z "$stop_price" || -z "$take_profit" ]]; then
        _alpaca_payload_error "bracket order needs both a stop price and a take profit price"
        return 1
    fi

    payload=$(alpaca_build_order_payload "$symbol" "$qty" "$side" "$type" "$limit_price" "$tif" \
        "$client_order_id" "$stop_price" "$take_profit") || { echo "$payload"; return 1; }
    alpaca_submit_order "$payload"
}

# Open orders (top level, bracket legs nested)
# Args: [SYMBOL]
# Returns: JSON array of raw Alpaca orders
alpaca_get_open_orders() {
    local symbol="${1:-}" endpoint="/orders?status=open&nested=true&limit=500"

    if [[ "$ALPACA_INITIALIZED" != "true" ]]; then
        echo "ERROR: Alpaca not initialized. Call alpaca_init() first"
        return 1
    fi
    if [[ -n "$symbol" ]]; then
        alpaca_validate_symbol "$symbol" || { echo "ERROR: invalid symbol"; return 1; }
        endpoint="${endpoint}&symbols=$symbol"
    fi

    local response
    response=$(alpaca_api_request "GET" "$endpoint") || { echo "$response"; return 1; }
    echo "$response" | jq -ce 'if type == "array" then . else error("not an array") end' || return 1
}

# All orders (any status) created after a timestamp, oldest first
# Args: ISO_TS (e.g. 2026-10-31T13:30:00Z or 2026-10-31)
# Returns: JSON array of raw Alpaca orders (bracket legs nested)
alpaca_get_orders_since() {
    local ts="$1"

    if [[ "$ALPACA_INITIALIZED" != "true" ]]; then
        echo "ERROR: Alpaca not initialized. Call alpaca_init() first"
        return 1
    fi
    if ! [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(Z|[+-][0-9]{2}:[0-9]{2})?)?$ ]]; then
        echo "ERROR: invalid timestamp: $ts (ISO-8601 expected)"
        return 1
    fi
    ts="${ts//+/%2B}"

    local response
    response=$(alpaca_api_request "GET" "/orders?status=all&after=${ts}&nested=true&direction=asc&limit=500") || {
        echo "$response"; return 1; }
    echo "$response" | jq -ce 'if type == "array" then . else error("not an array") end' || return 1
}

# Look an order up by its client_order_id
# Args: CLIENT_ORDER_ID
# Returns: raw Alpaca order JSON; 1 when not found
alpaca_get_order_by_client_id() {
    local client_order_id="$1"

    if [[ "$ALPACA_INITIALIZED" != "true" ]]; then
        echo "ERROR: Alpaca not initialized. Call alpaca_init() first"
        return 1
    fi
    alpaca_validate_client_order_id "$client_order_id" || { echo "ERROR: invalid client_order_id"; return 1; }

    local response
    response=$(alpaca_api_request "GET" "/orders:by_client_order_id?client_order_id=$client_order_id") || {
        echo "$response"; return 1; }
    echo "$response" | jq -c '.'
}

# Market clock
# Returns: raw JSON {is_open, timestamp, next_open, next_close}
alpaca_get_clock() {
    if [[ "$ALPACA_INITIALIZED" != "true" ]]; then
        echo "ERROR: Alpaca not initialized. Call alpaca_init() first"
        return 1
    fi

    local response
    response=$(alpaca_api_request "GET" "/clock") || { echo "$response"; return 1; }
    echo "$response" | jq -ce 'if has("is_open") then . else error("no is_open") end' || return 1
}

# Trading calendar (market days with open/close times)
# Args: START END (YYYY-MM-DD)
# Returns: raw JSON array [{date, open, close, ...}] (empty on non-trading days)
alpaca_get_calendar() {
    local start="$1" end="$2"

    if [[ "$ALPACA_INITIALIZED" != "true" ]]; then
        echo "ERROR: Alpaca not initialized. Call alpaca_init() first"
        return 1
    fi
    if ! [[ "$start" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$end" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "ERROR: calendar dates must be YYYY-MM-DD"
        return 1
    fi

    local response
    response=$(alpaca_api_request "GET" "/calendar?start=${start}&end=${end}") || { echo "$response"; return 1; }
    echo "$response" | jq -ce 'if type == "array" then . else error("not an array") end' || return 1
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
export -f alpaca_validate_client_order_id
export -f alpaca_round_price
export -f _alpaca_payload_error
export -f alpaca_build_order_payload
export -f alpaca_submit_order
export -f alpaca_place_bracket_order
export -f alpaca_get_open_orders
export -f alpaca_get_orders_since
export -f alpaca_get_order_by_client_id
export -f alpaca_get_clock
export -f alpaca_get_calendar
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
