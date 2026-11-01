#!/bin/bash
# ============================================================================
# StockSwingTrader Agent - Swing Trading Analysis Platform
# Version: 6.3 with ML, Regime-Adaptive, Kalman Filter, Dashboard, Backtesting
# ============================================================================
# Purpose: Analyze US stocks for swing trading opportunities using advanced
#          technical indicators, ML predictions, sentiment analysis, and
#          multi-source confluence scoring
# 
# Usage:
#   ./StockSwingTrader_Agent.sh --symbols AAPL,MSFT,GOOGL
#   ./StockSwingTrader_Agent.sh --symbols AAPL,MSFT --ml --regime-adapt
#   ./StockSwingTrader_Agent.sh --backtest AAPL --start 2022-01-01 --end 2024-01-01
#   ./StockSwingTrader_Agent.sh --symbols AAPL,MSFT --phase1
#   ./StockSwingTrader_Agent.sh --dashboard
#   ./StockSwingTrader_Agent.sh --full
#
# Features:
#   - 8+ technical indicators (RSI, MACD, Bollinger Bands, ATR, OBV, Stochastic, Williams %R)
#   - Multi-source sentiment analysis (Twitter, Reddit, StockTwits, News)
#   - XGBoost ML predictor with 15% weight in scoring (+5-10% accuracy)
#   - Regime-adaptive weighting by market conditions (+3-5% win rate)
#   - Kalman filter for price smoothing, fewer false signals
#   - Complete backtesting with parameter tuning & performance analysis
#   - React Dashboard with professional UI
#   - Confidence scoring (0-100) with buy/sell/hold signals
#   - Professional HTML report generation
#   - Rate limit management (Alpha Vantage 5/min, Finnhub 60/min)
#   - Graceful error handling with retry logic
#   - Learning/demo mode (analysis-only, no live trading)
#
# Requirements:
#   - bash 4.0+, curl, bc
#   - jq (optional, for JSON parsing)
#   - Python 3.8+ (for ML modules)
#   - Node.js 14+ (for Dashboard)
#
# ============================================================================

set -o pipefail

# ============================================================================
# Global Configuration
# ============================================================================

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
# Project root. All project paths use AGENT_DIR. Library files keep their own
# file-specific dir variables and do not change SCRIPT_DIR or AGENT_DIR;
# SCRIPT_DIR is kept as an alias for older scripts.
AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$AGENT_DIR"

# Load configuration template
if [[ -f "$AGENT_DIR/config.template.sh" ]]; then
    source "$AGENT_DIR/config.template.sh"
else
    echo "ERROR: config.template.sh not found" >&2
    exit 2
fi

# Load local credentials/overrides (untracked; create with
# `cp config.template.sh config.sh` and fill in your keys).
# Sourced after the template so its values replace the placeholders.
# SST_CONFIG_FILE selects another file (tests point it at a stub config so
# local credentials are never used).
SST_CONFIG_FILE="${SST_CONFIG_FILE:-$AGENT_DIR/config.sh}"
if [[ -f "$SST_CONFIG_FILE" ]]; then
    source "$SST_CONFIG_FILE"
fi

# Load libraries
source "$AGENT_DIR/lib/indicators.sh" 2>/dev/null || echo "WARNING: indicators.sh not found"
source "$AGENT_DIR/lib/sentiment.sh" 2>/dev/null || echo "WARNING: sentiment.sh not found"
source "$AGENT_DIR/lib/scoring.sh" 2>/dev/null || echo "WARNING: scoring.sh not found"
source "$AGENT_DIR/lib/html_report.sh" 2>/dev/null || echo "WARNING: html_report.sh not found"
# Phase 1 (v6.2 port): Kelly sizing + daily risk budget. The MiroFish cache
# adapter is loaded by lib/scoring.sh.
source "$AGENT_DIR/lib/kelly_sizing.sh" 2>/dev/null || echo "WARNING: kelly_sizing.sh not found"
# Live safety (Step 1): pre-trade checks + alerts (loads lib/alerts.sh and
# lib/risk_management.sh). Must be sourced before load_broker_module: it
# loads alpaca_broker.sh, and re-sourcing that resets ALPACA_INITIALIZED.
source "$AGENT_DIR/lib/order_safety.sh" 2>/dev/null || echo "WARNING: order_safety.sh not found"

# Order flow options (set by --order-type, --limit-price, --no-bracket,
# --live, --allow-mismatch)
ORDER_TYPE_OVERRIDE="${ORDER_TYPE_OVERRIDE:-}"
ORDER_LIMIT_PRICE="${ORDER_LIMIT_PRICE:-}"
ORDER_NO_BRACKET="${ORDER_NO_BRACKET:-false}"
ORDER_LIVE_FLAG="${ORDER_LIVE_FLAG:-false}"
RECONCILE_ALLOW_MISMATCH="${RECONCILE_ALLOW_MISMATCH:-false}"

# Broker selection (default: Alpaca for backward compatibility)
BROKER_CHOICE="${BROKER_CHOICE:-alpaca}"
BROKER_PREFIX="alpaca_"
BROKER_INITIALIZED_VAR="ALPACA_INITIALIZED"

# Load broker modules will be done after argument parsing to support --broker flag

# ============================================================================
# Enhancement Module Flags
# ============================================================================

ENABLE_ML_PREDICTOR=false
ENABLE_REGIME_ADAPT=false
ENABLE_KALMAN_FILTER=false
ENABLE_DASHBOARD=false
ENABLE_ALL_ENHANCEMENTS=false
ENABLE_KELLY_SIZING="${KELLY_SIZING_ENABLED:-false}"

# Version info
VERSION="6.3"
VERSION_STRING="StockSwingTrader v${VERSION} with ML, Regime, Kalman, Backtesting, Dashboard"

# ============================================================================
# Logging & Error Handling
# ============================================================================

log_info() {
    local msg="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[INFO] [$timestamp] $msg" | tee -a "${LOG_FILE}"
}

log_error() {
    local msg="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[ERROR] [$timestamp] $msg" | tee -a "${LOG_FILE}" >&2
}

log_debug() {
    if [[ "$DEBUG_MODE" == "true" ]]; then
        local msg="$1"
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        # stderr: debug lines must not end up in captured JSON output
        echo "[DEBUG] [$timestamp] $msg" | tee -a "${LOG_FILE}" >&2
    fi
}

log_warn() {
    local msg="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[WARN] [$timestamp] $msg" | tee -a "${LOG_FILE}"
}

# ============================================================================
# Broker Management Functions
# ============================================================================

# Load the appropriate broker module based on broker choice
load_broker_module() {
    case "$BROKER_CHOICE" in
        alpaca)
            if [[ ! -f "$AGENT_DIR/lib/alpaca_broker.sh" ]]; then
                log_error "Alpaca broker module not found: $AGENT_DIR/lib/alpaca_broker.sh"
                return 1
            fi
            source "$AGENT_DIR/lib/alpaca_broker.sh" || {
                log_error "Failed to load Alpaca broker module"
                return 1
            }
            BROKER_PREFIX="alpaca_"
            BROKER_INITIALIZED_VAR="ALPACA_INITIALIZED"
            log_info "Loaded Alpaca broker module"
            return 0
            ;;
        robinhood)
            if [[ ! -f "$AGENT_DIR/lib/robinhood_broker.sh" ]]; then
                log_error "Robinhood broker module not found: $AGENT_DIR/lib/robinhood_broker.sh"
                return 1
            fi
            source "$AGENT_DIR/lib/robinhood_oauth.sh" || {
                log_error "Failed to load Robinhood OAuth module"
                return 1
            }
            source "$AGENT_DIR/lib/robinhood_broker.sh" || {
                log_error "Failed to load Robinhood broker module"
                return 1
            }
            BROKER_PREFIX="robinhood_"
            BROKER_INITIALIZED_VAR="ROBINHOOD_INITIALIZED"
            log_info "Loaded Robinhood broker module"
            return 0
            ;;
        *)
            log_error "Unknown broker: $BROKER_CHOICE"
            return 1
            ;;
    esac
}

# Initialize broker connection
broker_connect() {
    # Initialize the broker INITIALIZED flag to false
    if [[ "$BROKER_CHOICE" == "alpaca" ]]; then
        ALPACA_INITIALIZED=false
    elif [[ "$BROKER_CHOICE" == "robinhood" ]]; then
        ROBINHOOD_INITIALIZED=false
    fi
    
    local init_func="${BROKER_PREFIX}init"
    
    log_info "Initializing $BROKER_CHOICE broker..."
    
    # Call the init function directly without checking with command -v
    # This ensures it works with functions sourced from modules
    if $init_func; then
        log_info "$BROKER_CHOICE connection successful"
        return 0
    else
        log_error "Failed to initialize $BROKER_CHOICE connection"
        return 1
    fi
}

# Display account status (broker-agnostic)
show_broker_account() {
    # Check the appropriate INITIALIZED flag based on broker
    if [[ "$BROKER_CHOICE" == "alpaca" ]]; then
        if [[ "$ALPACA_INITIALIZED" != "true" ]]; then
            log_error "Broker not initialized"
            return 1
        fi
    elif [[ "$BROKER_CHOICE" == "robinhood" ]]; then
        if [[ "$ROBINHOOD_INITIALIZED" != "true" ]]; then
            log_error "Broker not initialized"
            return 1
        fi
    fi
    
    log_info "Fetching $BROKER_CHOICE account information..."
    
    local get_account_func="${BROKER_PREFIX}get_account"
    local account_data
    if ! account_data=$($get_account_func) || [[ -z "$account_data" ]]; then
        log_error "Failed to retrieve account data"
        [[ -n "$account_data" ]] && echo "$account_data" >&2
        return 1
    fi
    
    echo ""
    echo "============================================"
    echo "$(echo "$BROKER_CHOICE" | tr '[:lower:]' '[:upper:]') ACCOUNT STATUS"
    echo "============================================"
    
    if command -v jq &>/dev/null; then
        # Robinhood has no portfolio_value (uses equity) and Alpaca no
        # account_type (uses status). The account number is not printed.
        echo "Portfolio Value: $(echo "$account_data" | jq -r '.portfolio_value // .equity // 0' | xargs printf '\$%.2f')"
        echo "Cash Balance:    $(echo "$account_data" | jq -r '.cash // 0' | xargs printf '\$%.2f')"
        echo "Buying Power:    $(echo "$account_data" | jq -r '.buying_power // 0' | xargs printf '\$%.2f')"
        echo "Account Type:    $(echo "$account_data" | jq -r '.account_type // .status // "n/a"')"
        echo "============================================"
    else
        echo "$account_data"
        echo "============================================"
    fi
    
    return 0
}

# Display all open positions (broker-agnostic)
show_broker_positions() {
    # Check the appropriate INITIALIZED flag based on broker
    if [[ "$BROKER_CHOICE" == "alpaca" ]]; then
        if [[ "$ALPACA_INITIALIZED" != "true" ]]; then
            log_error "Broker not initialized"
            return 1
        fi
    elif [[ "$BROKER_CHOICE" == "robinhood" ]]; then
        if [[ "$ROBINHOOD_INITIALIZED" != "true" ]]; then
            log_error "Broker not initialized"
            return 1
        fi
    fi
    
    log_info "Fetching open positions from $BROKER_CHOICE..."
    
    local get_positions_func="${BROKER_PREFIX}get_positions"
    local positions
    if ! positions=$($get_positions_func); then
        log_error "Failed to retrieve positions"
        [[ -n "$positions" ]] && echo "$positions" >&2
        return 1
    fi
    
    # Alpaca returns a JSON array, Robinhood a stream of objects: flatten both
    # into one array. Field names differ (quantity/qty, entry_price/avg_fill_price).
    if command -v jq &>/dev/null; then
        positions=$(echo "$positions" | jq -c -s '[.[] | if type == "array" then .[] else . end]' 2>/dev/null) || {
            log_error "Unexpected positions response"
            return 1
        }
    fi
    
    if [[ -z "$positions" || "$positions" == "[]" ]]; then
        log_warn "No open positions"
        return 0
    fi
    
    echo ""
    echo "============================================"
    echo "OPEN POSITIONS ($(echo "$BROKER_CHOICE" | tr '[:lower:]' '[:upper:]'))"
    echo "============================================"
    
    if command -v jq &>/dev/null; then
        echo "$positions" | jq -r '.[] | "\(.symbol): \(.quantity // .qty) shares @ $\(.entry_price // .avg_fill_price // .avg_entry_price)"'
    else
        echo "$positions"
    fi
    
    echo "============================================"
    return 0
}

# Validate order arguments before anything is sent to a broker
# Args: SYMBOL QTY
# Returns: 0 if valid; 1 (with an error) for a symbol that is not 1-5
#          uppercase letters or a quantity that is not a positive number
validate_order_args() {
    local symbol="$1"
    local qty="$2"
    
    if ! [[ "$symbol" =~ ^[A-Z]{1,5}$ ]]; then
        log_error "Invalid symbol: '$symbol' (must be 1-5 uppercase letters, e.g. AAPL)"
        return 1
    fi
    if ! [[ "$qty" =~ ^[0-9]+(\.[0-9]+)?$ ]] || [[ "$(echo "$qty > 0" | bc -l)" != "1" ]]; then
        log_error "Invalid quantity: '$qty' (must be a positive number)"
        return 1
    fi
    return 0
}

# Current price for an order confirmation: the broker's quote
# (${BROKER_PREFIX}get_quote .last_price), else fetch_current_price
# Args: SYMBOL
# Returns: price, or 0 when no price is available
get_order_price() {
    local symbol="$1"
    local quote_func="${BROKER_PREFIX}get_quote"
    local price=""
    
    if declare -F "$quote_func" >/dev/null && command -v jq &>/dev/null; then
        price=$($quote_func "$symbol" 2>/dev/null | jq -r '.last_price // empty' 2>/dev/null)
    fi
    if [[ "$price" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ "$(echo "$price > 0" | bc -l)" == "1" ]]; then
        echo "$price"
        return 0
    fi
    fetch_current_price "$symbol"
}

# Endpoint mode of the selected broker (paper | local | live); also sets and
# exports SST_ENDPOINT_MODE (used in alert lines)
current_endpoint_mode() {
    SST_ENDPOINT_MODE=$(broker_endpoint_mode "$BROKER_CHOICE" "${ALPACA_BASE_URL:-}")
    export SST_ENDPOINT_MODE
    echo "$SST_ENDPOINT_MODE"
}

# Refuse broker commands when the endpoint is live and the active config file
# is tracked in git (config.sh must stay on paper)
# Returns: 0 ok; 1 + error
check_live_config_guard() {
    current_endpoint_mode >/dev/null
    if [[ "$SST_ENDPOINT_MODE" == "live" ]] && config_file_is_tracked "$SST_CONFIG_FILE"; then
        log_error "LIVE endpoint refused: $(basename "$SST_CONFIG_FILE") is tracked in git and must stay on paper; put live keys in an untracked file (e.g. config.live.sh) and select it with SST_CONFIG_FILE"
        send_alert critical error "Live endpoint with a git-tracked config refused" \
            "$(jq -cn --arg f "$(basename "$SST_CONFIG_FILE")" '{config_file:$f}')"
        return 1
    fi
    return 0
}

# Order checks that need no broker contact (run before the broker is loaded
# and again inside place_guarded_order)
# Args: SIDE SYMBOL QTY
# Returns: 0 ok; 1 + error (arguments, --limit-price, kill switch, live
#          guard, MAX_ORDER_QTY)
order_prechecks() {
    local side="$1" symbol="$2" qty="$3" ks mode

    if [[ -z "$symbol" ]] || [[ -z "$qty" ]]; then
        log_error "Usage: place_${side}_order SYMBOL QTY"
        return 1
    fi
    validate_order_args "$symbol" "$qty" || return 1
    if [[ -n "$ORDER_LIMIT_PRICE" ]]; then
        if ! [[ "$ORDER_LIMIT_PRICE" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! _os_gt "$ORDER_LIMIT_PRICE" 0; then
            log_error "Invalid --limit-price: '$ORDER_LIMIT_PRICE' (must be a number > 0)"
            return 1
        fi
    fi

    if ks=$(kill_switch_active); then
        log_error "KILL SWITCH ACTIVE since $(echo "$ks" | jq -r '.ts // "?"'): $(echo "$ks" | jq -r '.reason // ""'). No new orders. Run --resume to clear."
        send_alert warn halt "Order refused by the kill switch: $side $qty $symbol" "$ks"
        return 1
    fi

    current_endpoint_mode >/dev/null
    mode="$SST_ENDPOINT_MODE"
    if [[ "$mode" == "live" ]]; then
        check_live_config_guard || return 1
        if [[ "$ORDER_LIVE_FLAG" != "true" ]]; then
            log_error "LIVE endpoint ($BROKER_CHOICE): orders need --live and a typed confirmation. Refused: $side $qty $symbol"
            send_alert warn error "Live order refused (no --live): $side $qty $symbol" ""
            return 1
        fi
    fi

    local reason
    if ! reason=$(check_order_qty_cap "$qty" "$symbol" "$side"); then
        log_error "$reason"
        return 1
    fi
    return 0
}

# Place an order through every pre-trade check (broker-agnostic)
# Order of checks (first failure returns 1): arguments, kill switch, live
# guard, MAX_ORDER_QTY (no broker contact); then for Alpaca market hours,
# reconciliation (unless --allow-mismatch), daily loss halt; positions (caps,
# no short), duplicates (ledger + open orders), reference price, limit price,
# daily notional, PDT warning, bracket levels (buys). Then the confirmation
# ("yes"; LIVE: type "SYMBOL QTY") and, under the order lock, ledger +
# submit + alerts.
# Args: SIDE (buy|sell) SYMBOL QTY
# Returns: 0 placed or cancelled; 1 refused / failed
place_guarded_order() {
    local side="$1" symbol="$2" qty="$3"
    local side_uc broker_uc mode mode_label reason
    side_uc=$(echo "$side" | tr '[:lower:]' '[:upper:]')
    broker_uc=$(echo "$BROKER_CHOICE" | tr '[:lower:]' '[:upper:]')

    order_prechecks "$side" "$symbol" "$qty" || return 1
    current_endpoint_mode >/dev/null
    mode="$SST_ENDPOINT_MODE"
    mode_label=$(endpoint_mode_label "$mode")

    # Check the appropriate INITIALIZED flag based on broker
    if [[ "$BROKER_CHOICE" == "alpaca" ]]; then
        if [[ "$ALPACA_INITIALIZED" != "true" ]]; then
            log_error "Broker not initialized"
            return 1
        fi
    elif [[ "$BROKER_CHOICE" == "robinhood" ]]; then
        if [[ "$ROBINHOOD_INITIALIZED" != "true" ]]; then
            log_error "Broker not initialized"
            return 1
        fi
    fi

    local account="" open_orders="[]" orders_today="[]"
    if [[ "$BROKER_CHOICE" == "alpaca" ]]; then
        if ! reason=$(check_market_hours); then
            log_error "$reason"
            return 1
        fi
        [[ -n "$reason" ]] && echo "$reason"

        if [[ "${RECONCILE_ON_STARTUP:-true}" == "true" ]]; then
            local report rrc
            report=$(reconcile_with_broker)
            rrc=$?
            if [[ $rrc -ne 0 ]]; then
                echo "$report"
                if [[ "$RECONCILE_ALLOW_MISMATCH" == "true" ]]; then
                    log_warn "Reconciliation mismatch overridden with --allow-mismatch; continuing"
                    send_alert warn reconcile_mismatch "Order continues despite a reconciliation mismatch (--allow-mismatch): $side $qty $symbol" ""
                else
                    log_error "Order refused: broker state does not match the local baseline + order ledger. Review with --reconcile, adopt with --reconcile-accept, or override once with --allow-mismatch"
                    return 1
                fi
            fi
        fi

        if ! account=$(alpaca_get_account 2>/dev/null) || ! echo "$account" | jq -e . >/dev/null 2>&1; then
            log_error "Order refused: could not read the account"
            return 1
        fi
        if ! reason=$(check_daily_loss_halt "$account" "$side"); then
            log_error "$reason"
            return 1
        fi
        [[ -n "$reason" ]] && echo "$reason"
    else
        echo "NOTICE: market hours, reconciliation, daily loss and PDT checks are not available for $BROKER_CHOICE (skipped)"
        account=$(${BROKER_PREFIX}get_account 2>/dev/null)
    fi

    local positions
    if ! positions=$(${BROKER_PREFIX}get_positions 2>/dev/null); then
        log_error "Order refused: could not read positions"
        return 1
    fi

    if [[ "$BROKER_CHOICE" == "alpaca" ]]; then
        if ! open_orders=$(alpaca_get_open_orders 2>/dev/null); then
            log_error "Order refused: could not read open orders"
            return 1
        fi
    fi
    if ! reason=$(check_duplicate_order "$symbol" "$side" "$open_orders"); then
        log_error "$reason"
        return 1
    fi
    if [[ "$side" == "sell" ]] && echo "$open_orders" | jq -e --arg s "$symbol" \
        'any(.[]; .symbol == $s and any((.legs // [])[]; .side == "sell"))' >/dev/null 2>&1; then
        log_warn "Open bracket legs (take profit / stop loss) hold $symbol shares; this sell may be rejected until they are cancelled"
    fi

    # Get current price for cost estimate
    local current_price=$(get_order_price "$symbol")
    if [[ -z "$current_price" || "$current_price" == "0" ]]; then
        log_error "Failed to get current price for $symbol"
        return 1
    fi

    # Order type and prices
    local order_type="${ORDER_TYPE_OVERRIDE:-${ORDER_TYPE:-limit}}" limit_price="" tif=""
    if [[ "$BROKER_CHOICE" != "alpaca" && "$order_type" != "market" ]]; then
        echo "NOTICE: $BROKER_CHOICE orders are sent as market orders (limit/bracket not supported here)"
        order_type="market"
    fi
    if [[ "$order_type" == "limit" ]]; then
        if [[ -n "$ORDER_LIMIT_PRICE" ]]; then
            limit_price=$(_os_round "$ORDER_LIMIT_PRICE")
        else
            limit_price=$(compute_limit_price "$side" "$current_price")
        fi
        if [[ -z "$limit_price" ]]; then
            log_error "Could not compute a limit price for $symbol"
            return 1
        fi
    fi
    local cap_price="${limit_price:-$current_price}"
    if ! reason=$(check_order_caps "$side" "$symbol" "$qty" "$cap_price" "$positions"); then
        log_error "$reason"
        return 1
    fi
    local notional
    notional=$(echo "$reason" | jq -r '.notional // 0' 2>/dev/null)

    # Bracket (buys): stop / take profit from ATR+regime (real bars) or percent
    local bracket=false stop_price="" take_profit="" stop_info=""
    if [[ "$BROKER_CHOICE" == "alpaca" && "$side" == "buy" && "${ORDER_BRACKET:-true}" == "true" && "$ORDER_NO_BRACKET" != "true" ]]; then
        local levels
        levels=$(order_bracket_levels "$symbol" "$cap_price" buy)
        stop_price=$(echo "$levels" | jq -r '.stop_price // empty' 2>/dev/null)
        take_profit=$(echo "$levels" | jq -r '.take_profit_price // empty' 2>/dev/null)
        if [[ -z "$stop_price" || -z "$take_profit" ]]; then
            log_error "Could not compute bracket levels for $symbol (use --no-bracket to send a plain order)"
            return 1
        fi
        stop_info=$(echo "$levels" | jq -r '"\(.stop_pct)%, \(.method)" + (if .regime then ", regime \(.regime)" else "" end)')
        bracket=true
    fi

    if [[ "$BROKER_CHOICE" == "alpaca" ]]; then
        if [[ "$bracket" == "true" ]]; then
            tif="${BRACKET_TIME_IN_FORCE:-gtc}"
        elif [[ "$order_type" == "limit" ]]; then
            tif="${ORDER_TIME_IN_FORCE:-day}"
        else
            tif="day"
        fi
        if ! orders_today=$(alpaca_get_orders_since "$(_os_trading_day)" 2>/dev/null); then
            orders_today="[]"
        fi
        check_pdt_warning "$side" "$symbol" "$account" "$orders_today" "$bracket"
    fi

    local client_order_id
    client_order_id=$(generate_client_order_id "$symbol" "$side")

    local estimated=$(echo "$qty * $current_price" | bc)
    local limit_txt="n/a (market)" stop_txt="none" tp_txt="none"
    [[ -n "$limit_price" ]] && limit_txt="\$$limit_price"
    [[ -n "$stop_price" ]] && stop_txt="\$$stop_price ($stop_info)"
    [[ -n "$take_profit" ]] && tp_txt="\$$take_profit"
    echo ""
    echo "============================================"
    echo "${side_uc} ORDER CONFIRMATION (${broker_uc})"
    echo "============================================"
    if [[ "$side" == "buy" ]]; then
        echo "Symbol:          $symbol"
        echo "Quantity:        $qty shares"
        echo "Current Price:   \$$current_price"
        echo "Estimated Cost:  \$$estimated"
        echo "Order Type:      $order_type$( [[ "$bracket" == "true" ]] && echo " (bracket)")"
        echo "Limit Price:     $limit_txt"
        echo "Stop Loss:       $stop_txt"
        echo "Take Profit:     $tp_txt"
        echo "Time in Force:   ${tif:-n/a}"
        echo "Client Order ID: $client_order_id"
        echo "Mode:            $mode_label"
    else
        echo "Symbol:             $symbol"
        echo "Quantity:           $qty shares"
        echo "Current Price:      \$$current_price"
        echo "Estimated Proceeds: \$$estimated"
        echo "Order Type:         $order_type"
        echo "Limit Price:        $limit_txt"
        echo "Stop Loss:          none"
        echo "Take Profit:        none"
        echo "Time in Force:      ${tif:-n/a}"
        echo "Client Order ID:    $client_order_id"
        echo "Mode:               $mode_label"
    fi
    echo "============================================"
    echo ""
    local confirmation=""
    if [[ "$mode" == "live" ]]; then
        echo "LIVE ORDER: real money."
        echo "Type the symbol and quantity to confirm (e.g. $symbol $qty):"
        read -r confirmation
        if [[ "$confirmation" != "$symbol $qty" ]]; then
            log_info "${side_uc} order cancelled (typed confirmation did not match)"
            echo "Order cancelled"
            return 0
        fi
    else
        echo "Proceed with order? (yes/no)"
        read -r confirmation
        if [[ "$confirmation" != "yes" ]]; then
            log_info "$(echo "${side:0:1}" | tr '[:lower:]' '[:upper:]')${side:1} order cancelled"
            echo "Order cancelled"
            return 0
        fi
    fi

    if ! reason=$(order_lock_acquire); then
        log_error "$reason"
        return 1
    fi

    order_ledger_append "$(jq -cn --argjson e "$(date +%s)" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg day "$(_os_trading_day)" --arg cid "$client_order_id" --arg b "$BROKER_CHOICE" --arg m "$mode" \
        --arg s "$symbol" --arg side "$side" --arg q "$qty" --arg t "$order_type" --arg lp "$limit_price" \
        --arg sp "$stop_price" --arg tp "$take_profit" --arg n "${notional:-0}" '
        {ts_epoch: $e, ts: $ts, trading_day: $day, client_order_id: $cid, broker: $b, mode: $m,
         symbol: $s, side: $side, qty: ($q | tonumber), type: $t,
         limit_price: (if $lp == "" then null else $lp end),
         stop_price: (if $sp == "" then null else $sp end),
         take_profit_price: (if $tp == "" then null else $tp end),
         notional: ($n | tonumber), status: "submitted", broker_order_id: null}')"

    log_info "Placing $side order via $BROKER_CHOICE: $qty shares of $symbol ($order_type, bracket $bracket, client order id $client_order_id)"

    local order rc=0
    if [[ "$BROKER_CHOICE" == "alpaca" ]]; then
        if [[ "$bracket" == "true" ]]; then
            order=$(alpaca_place_bracket_order "$symbol" "$qty" "$side" "$limit_price" "$stop_price" "$take_profit" \
                "$client_order_id" "$order_type" "$tif") || rc=$?
        else
            order=$(alpaca_place_order "$symbol" "$qty" "$side" "$order_type" "$limit_price" "$client_order_id" \
                "$( [[ "$order_type" == "limit" ]] && echo "$tif")") || rc=$?
        fi
    else
        order=$(${BROKER_PREFIX}place_order "$symbol" "$qty" "$side") || rc=$?
    fi
    [[ $rc -eq 0 && -z "$order" ]] && rc=1

    local details
    details=$(jq -cn --arg cid "$client_order_id" --arg s "$symbol" --arg side "$side" --arg q "$qty" \
        --arg t "$order_type" --arg lp "$limit_price" --arg sp "$stop_price" --arg tp "$take_profit" \
        '{client_order_id:$cid, symbol:$s, side:$side, qty:($q|tonumber), type:$t, limit_price:$lp, stop_price:$sp, take_profit_price:$tp}')

    if [[ $rc -eq 0 ]]; then
        local status broker_id ledger_status=accepted
        status=$(echo "$order" | jq -r '.status // empty' 2>/dev/null | head -1)
        broker_id=$(echo "$order" | jq -r '.order_id // .id // empty' 2>/dev/null | head -1)
        [[ "$status" == "filled" ]] && ledger_status=filled
        order_ledger_update "$client_order_id" "$ledger_status" "$broker_id"
        order_lock_release
        send_alert info order_placed "$side_uc $qty $symbol placed ($order_type, $client_order_id)" "$details"
        [[ "$ledger_status" == "filled" ]] && \
            send_alert info order_filled "$side_uc $qty $symbol filled ($client_order_id)" "$details"
        log_info "$(echo "${side:0:1}" | tr '[:lower:]' '[:upper:]')${side:1} order placed successfully"
        echo ""
        echo "✓ ${side_uc} ORDER PLACED (${broker_uc})"
        echo "$order"
        return 0
    fi

    # The broker prints its error (e.g. "ERROR: Unprocessable Entity") on stdout
    [[ -n "$order" ]] && echo "$order" >&2
    if [[ "$order" == *"outcome unknown"* ]]; then
        order_ledger_update "$client_order_id" unknown
        send_alert critical error "$side_uc $qty $symbol: order outcome unknown ($client_order_id); check open orders" "$details"
    else
        order_ledger_update "$client_order_id" rejected
        send_alert warn order_rejected "$side_uc $qty $symbol rejected ($client_order_id)" "$details"
    fi
    order_lock_release
    log_error "Failed to place $side order"
    return 1
}

# Place a buy order with confirmation (broker-agnostic; see place_guarded_order)
# Args: SYMBOL QTY
place_buy_order() {
    if [[ -z "$1" ]] || [[ -z "$2" ]]; then
        log_error "Usage: place_buy_order SYMBOL QTY"
        return 1
    fi
    place_guarded_order buy "$1" "$2"
}

# Place a sell order with confirmation (broker-agnostic; see place_guarded_order)
# Args: SYMBOL QTY
place_sell_order() {
    if [[ -z "$1" ]] || [[ -z "$2" ]]; then
        log_error "Usage: place_sell_order SYMBOL QTY"
        return 1
    fi
    place_guarded_order sell "$1" "$2"
}

# Startup reconciliation for read-only Alpaca commands (warning only)
# Returns: 0 always
startup_reconcile_warning() {
    [[ "$BROKER_CHOICE" == "alpaca" && "${RECONCILE_ON_STARTUP:-true}" == "true" ]] || return 0
    local report
    if ! report=$(reconcile_with_broker); then
        echo "$report"
        log_warn "Reconciliation mismatch (warning only for this command); review with --reconcile"
    fi
    return 0
}

# --reconcile: report; exit code 0 match, 3 mismatch, 1 broker data unavailable
run_reconcile_command() {
    local rc
    reconcile_with_broker
    rc=$?
    case $rc in
        0) return 0 ;;
        1) return 3 ;;
        *) return 1 ;;
    esac
}

# ============================================================================
# API Fetching Functions
# ============================================================================

# Synthetic data is opt-in: SST_ALLOW_SYNTHETIC=1 (real data first, demo
# fallback) or SST_OFFLINE=1 (no network, demo data only)
synthetic_data_allowed() {
    [[ "${SST_OFFLINE:-0}" == "1" || "${SST_ALLOW_SYNTHETIC:-0}" == "1" ]]
}

# Fetch real daily OHLCV from Yahoo Finance via yfinance (no API key needed)
# Args: symbol, bars
# Returns: {"symbol","data_source":"yfinance","ohlcv":[...]} or nothing (exit 1)
fetch_stock_ohlcv_yfinance() {
    local symbol=$1
    local bars=${2:-60}
    python3 - "$symbol" "$bars" 2>/dev/null <<'PY'
import json, sys
import pandas as pd
import yfinance as yf
symbol, bars = sys.argv[1], int(sys.argv[2])
df = yf.download(symbol, period='1y', interval='1d', progress=False)
if df is None or df.empty:
    sys.exit(1)
if isinstance(df.columns, pd.MultiIndex):
    df.columns = df.columns.get_level_values(0)
df = df.dropna().tail(bars)
rows = [{"date": idx.strftime('%Y-%m-%d'), "open": round(float(r['Open']), 4),
         "high": round(float(r['High']), 4), "low": round(float(r['Low']), 4),
         "close": round(float(r['Close']), 4), "volume": int(r['Volume'])}
        for idx, r in df.iterrows()]
if len(rows) < 30:
    sys.exit(1)
print(json.dumps({"symbol": symbol, "data_source": "yfinance", "ohlcv": rows}, separators=(',', ':')))
PY
}

# Fetch historical OHLCV data. Real data (yfinance) unless offline; the
# random demo series is generated only when synthetic data is explicitly
# allowed and is marked "data_source":"synthetic". Without real data and
# without the opt-in, prints nothing and returns 1 (the symbol is skipped).
fetch_stock_ohlcv() {
    local symbol=$1
    local days_back=${2:-30}
    
    log_debug "Fetching OHLCV data for $symbol (last $days_back days)"
    
    if [[ "${SST_OFFLINE:-0}" != "1" ]]; then
        local real
        if real=$(fetch_stock_ohlcv_yfinance "$symbol" "$days_back") && [[ -n "$real" ]]; then
            log_debug "Fetched real OHLCV data for $symbol (yfinance)" >&2
            echo "$real"
            return 0
        fi
        if ! synthetic_data_allowed; then
            log_error "No market data for $symbol (yfinance unavailable or empty). Set SST_ALLOW_SYNTHETIC=1 for clearly marked demo data."
            return 1
        fi
    fi
    log_warn "Using SYNTHETIC demo prices for $symbol (SST_OFFLINE/SST_ALLOW_SYNTHETIC); results are not market analysis" >&2
    
    # Demo data (explicitly allowed): random walk around $150
    local json_output="{"
    json_output="${json_output}\"symbol\":\"${symbol}\","
    json_output="${json_output}\"data_source\":\"synthetic\","
    json_output="${json_output}\"ohlcv\":["
    
    # Generate sample prices around $150 with realistic variation
    local base_price=150
    for ((i=0; i<60; i++)); do
        # Integer step of -3..+3 (bc with scale=2 made "%" a non-integer
        # remainder, so prices drifted ~-19 per bar and went negative)
        local variation=$(( (RANDOM % 7) - 3 ))
local open=$(echo "$base_price + $variation" | bc)
        local high=$(echo "$open + 3" | bc)
        local low=$(echo "$open - 3" | bc)
        local close=$(echo "$open + (($RANDOM % 5) - 2)" | bc)
        local volume=$((1000000 + RANDOM % 900000))
        local date="2025-01-$((15 - i/2))"
        
        if ((i > 0)); then
            json_output="${json_output},"
        fi
        
        json_output="${json_output}{\"date\":\"${date}\",\"open\":${open},\"high\":${high},\"low\":${low},\"close\":${close},\"volume\":${volume}}"
        
        # Update base for next iteration
        base_price=$close
    done
    
    json_output="${json_output}]}"
    
    log_debug "Generated synthetic OHLCV data for $symbol"
    echo "$json_output"
}

# Fetch current price from multiple sources (with fallback)
fetch_current_price() {
    local symbol=$1
    
    log_debug "Fetching current price for $symbol"

    # Offline/test runs: no network call (callers already handle "0")
    if [[ "${SST_OFFLINE:-0}" == "1" ]]; then
        echo "0"
        return 1
    fi

    # Try Yahoo Finance quote endpoint first
    local url="https://query1.finance.yahoo.com/v10/finance/quoteSummary/${symbol}?modules=price"
    local response=$(curl -s --max-time 10 "$url" 2>/dev/null)
    
    if [[ -n "$response" && "$response" != *"null"* ]]; then
        # Extract price from JSON
        local price=$(echo "$response" | grep -o '"regularMarketPrice":[0-9.]*' | grep -o '[0-9.]*')
        if [[ -n "$price" ]]; then
            echo "$price"
            return 0
        fi
    fi
    
    log_error "Failed to fetch current price for $symbol"
    echo "0"
    return 1
}

# ============================================================================
# Data Processing
# ============================================================================

# Extract close prices from OHLCV data
extract_closes() {
    local ohlcv_json=$1
    
    # Simple extraction (in production, use jq if available)
    local closes=$(echo "$ohlcv_json" | grep -o '"close":[0-9.]*' | grep -o '[0-9.]*')
    echo "$closes"
}

# Calculate all technical indicators for a stock
calculate_all_indicators() {
    local symbol=$1
    local ohlcv_json=$2
    
    log_debug "Calculating indicators for $symbol"
    
    # Extract close prices
    local closes=$(extract_closes "$ohlcv_json")
    local close_array=($closes)
    
    if [[ ${#close_array[@]} -lt 30 ]]; then
        log_error "Insufficient data points for $symbol (${#close_array[@]} < 30)"
        return 1
    fi
    
    # Calculate indicators
    local rsi=$(calc_rsi 14 "${close_array[@]}")
    local rsi_value=$(echo "$rsi" | grep -o '"rsi":[0-9.]*' | grep -o '[0-9.]*')
    
    local macd=$(calc_macd "${close_array[@]}")
    
    local bb=$(calc_bollinger_bands 20 2 "${close_array[@]}")
    
    local stoch=$(calc_stochastic 14 "${close_array[@]}")
    
    local williams=$(calc_williams_r 14 "${close_array[@]}")
    
    # Extract high/low/close for ATR
    local highs=$(echo "$ohlcv_json" | grep -o '"high":[0-9.]*' | grep -o '[0-9.]*')
    local lows=$(echo "$ohlcv_json" | grep -o '"low":[0-9.]*' | grep -o '[0-9.]*')
    
    local high_array=($highs)
    local low_array=($lows)
    
    # Build HLC triples for ATR
    local hlc_input=""
    for ((i = 0; i < ${#close_array[@]}; i++)); do
        hlc_input="${hlc_input}${high_array[$i]} ${low_array[$i]} ${close_array[$i]} "
    done
    
    local atr=$(calc_atr 14 $hlc_input)
    
    # OBV (volume-based)
    local volumes=$(echo "$ohlcv_json" | grep -o '"volume":[0-9]*' | grep -o '[0-9]*')
    local volume_array=($volumes)
    
    local cv_input=""
    for ((i = 0; i < ${#close_array[@]}; i++)); do
        cv_input="${cv_input}${close_array[$i]} ${volume_array[$i]} "
    done
    
    local obv=$(calc_obv $cv_input)
    
    # Where the prices came from ("yfinance" or "synthetic"; "unknown" if the
    # series does not say) and the last close (Bollinger fallback price)
    local data_source
    data_source=$(echo "$ohlcv_json" | jq -r '.data_source // "unknown"' 2>/dev/null)
    [[ -z "$data_source" ]] && data_source="unknown"
    local last_close="${close_array[${#close_array[@]}-1]}"

    # v2 scoring inputs (OBV trend, MR/TF setup scores, Kalman trend, regime)
    # from these same bars; no extra network calls
    local v2_inputs="null"
    if declare -f build_v2_inputs >/dev/null; then
        local closes_json volumes_json macd_v signal_v bb_u bb_l
        closes_json=$(jq -c -n '$ARGS.positional | map(tonumber)' --args "${close_array[@]}" 2>/dev/null)
        volumes_json=$(jq -c -n '$ARGS.positional | map(tonumber)' --args "${volume_array[@]}" 2>/dev/null)
        IFS='|' read -r macd_v signal_v <<< "$(echo "$macd" | jq -r '"\(.macd // 0)|\(.signal // 0)"' 2>/dev/null)"
        IFS='|' read -r bb_u bb_l <<< "$(echo "$bb" | jq -r '"\(.upper // 0)|\(.lower // 0)"' 2>/dev/null)"
        v2_inputs=$(build_v2_inputs "$symbol" "${closes_json:-[]}" "${volumes_json:-[]}" "${obv:-[]}" \
            "${rsi_value:-50}" "${macd_v:-0}" "${signal_v:-0}" "${bb_u:-0}" "${bb_l:-0}" 2>/dev/null)
        [[ -z "$v2_inputs" ]] && v2_inputs="null"
    fi

    # Output all indicators as JSON
    echo "{
        \"symbol\":\"${symbol}\",
        \"data_source\":\"${data_source}\",
        \"last_close\":${last_close},
        \"indicators\": {
            \"rsi\": ${rsi},
            \"macd\": ${macd},
            \"bollinger_bands\": ${bb},
            \"stochastic\": ${stoch},
            \"williams_r\": ${williams},
            \"atr\": ${atr}
        },
        \"v2_inputs\": ${v2_inputs}
    }"
}

# Score indicators and calculate confluence
score_stock() {
    local symbol=$1
    local indicators_json=$2
    
    log_debug "Scoring indicators for $symbol"
    
    # Extract individual indicator values and score them
    local rsi=$(echo "$indicators_json" | grep -o '"rsi":[^}]*' | head -1)
    local rsi_value=$(echo "$rsi" | grep -o '[0-9.]*' | head -1)
    local rsi_score=$(score_rsi "$rsi_value")
    
    local macd=$(echo "$indicators_json" | grep -o '"macd":[^}]*' | head -1)
    local macd_value=$(echo "$macd" | grep -o '"macd":[0-9.]*' | grep -o '[0-9.]*')
    local signal_value=$(echo "$macd" | grep -o '"signal":[0-9.]*' | grep -o '[0-9.]*')
    local histogram=$(echo "$macd" | grep -o '"histogram":[0-9.]*' | grep -o '[0-9.]*')
    local macd_score=$(score_macd "${macd_value}" "${signal_value}" "${histogram}")
    
    local bb=$(echo "$indicators_json" | grep -o '"bollinger_bands":[^}]*}' | head -1)
    local bb_upper=$(echo "$bb" | grep -o '"upper":[0-9.]*' | grep -o '[0-9.]*')
    local bb_middle=$(echo "$bb" | grep -o '"middle":[0-9.]*' | grep -o '[0-9.]*')
    local bb_lower=$(echo "$bb" | grep -o '"lower":[0-9.]*' | grep -o '[0-9.]*')
    local current_price=$(fetch_current_price "$symbol")
    # No live quote (offline / fetch failed): use the series' last close
    # instead of 0, which scored every symbol as maximally oversold (100).
    if [[ -z "$current_price" ]] || awk -v p="$current_price" 'BEGIN { exit !(p + 0 <= 0) }'; then
        current_price=$(echo "$indicators_json" | jq -r '.last_close // empty' 2>/dev/null)
    fi
    local bb_score=$(score_bollinger_bands "${current_price:-0}" "$bb_upper" "$bb_middle" "$bb_lower")
    local data_source=$(echo "$indicators_json" | jq -r '.data_source // "unknown"' 2>/dev/null)
    [[ -z "$data_source" ]] && data_source="unknown"
    local data_warning=""
    if [[ "$data_source" == "synthetic" ]]; then
        data_warning="SYNTHETIC demo prices (SST_OFFLINE/SST_ALLOW_SYNTHETIC): scores are not market analysis"
    fi
    
    local stoch=$(echo "$indicators_json" | grep -o '"stochastic":[^}]*}' | head -1)
    local k_line=$(echo "$stoch" | grep -o '"k_line":[0-9.]*' | grep -o '[0-9.]*')
    local stoch_score=$(score_stochastic "$k_line")
    
    local williams=$(echo "$indicators_json" | grep -o '"williams_r": *-\{0,1\}[0-9.]*' | grep -o -- '-\{0,1\}[0-9.]*$')
    local williams_score=$(score_williams_r "$williams")
    
    local atr=$(echo "$indicators_json" | grep -o '"atr":"[0-9.]*' | grep -o '[0-9.]*')
    
    # Sentiment score
    local sentiment=$(aggregate_sentiment "$symbol")
    # "na" when no source is available: sentiment then gets 0 weight
    local sentiment_score=$(echo "$sentiment" | jq -r '.aggregate_sentiment_score // "na"' 2>/dev/null)
    [[ -z "$sentiment_score" || "$sentiment_score" == "null" ]] && sentiment_score="na"

    # v2 inputs computed from the bars by calculate_all_indicators. Missing
    # (old or hand-made indicator JSON): neutral 50 / 0 / unknown.
    local v2_inputs v2_inputs_available=true
    v2_inputs=$(echo "$indicators_json" | jq -c '.v2_inputs // empty | select(type == "object")' 2>/dev/null)
    if [[ -z "$v2_inputs" ]]; then
        v2_inputs_available=false
        v2_inputs='{"obv_score":50,"obv_available":false,"mr_score":50,"tf_score":50,"kalman_trend":0,"kalman_available":false,"regime":"unknown"}'
    fi
    local obv_score mr_score tf_score kalman_trend regime
    IFS='|' read -r obv_score mr_score tf_score kalman_trend regime <<< "$(echo "$v2_inputs" | jq -r \
        '"\(.obv_score // 50)|\(.mr_score // 50)|\(.tf_score // 50)|\(.kalman_trend // 0)|\(.regime // "unknown")"' 2>/dev/null)"
    [[ "$obv_score" =~ ^[0-9]+$ ]] || obv_score=50
    [[ "$mr_score" =~ ^[0-9]+$ ]] || mr_score=50
    [[ "$tf_score" =~ ^[0-9]+$ ]] || tf_score=50
    [[ "$kalman_trend" =~ ^-?[01]$ ]] || kalman_trend=0
    [[ -n "$regime" ]] || regime="unknown"

    local sentiment_json="$sentiment_score"
    [[ "$sentiment_score" == "na" ]] && sentiment_json="null"

    local scoring_model="${SCORING_MODE:-v2}"
    [[ "$scoring_model" == "legacy" ]] || scoring_model="v2"

    local confluence confluence_v2="null"
    if [[ "$scoring_model" == "legacy" ]]; then
        # Legacy: 80% technical average + 20% sentiment, MiroFish blended after
        confluence=$(calculate_confluence_score "$rsi_score" "$macd_score" "$bb_score" "$stoch_score" "$williams_score" "$obv_score" "$sentiment_score")
        # Optional MiroFish cache blend (no-op unless MIROFISH_ENABLED=true; no network)
        if declare -f apply_mirofish_to_confluence >/dev/null; then
            confluence=$(apply_mirofish_to_confluence "$confluence" "$symbol")
        fi
    else
        # v2: ML + regime-weighted MR/TF + technical + volume/trend; MiroFish
        # is applied inside v2 and sentiment enters once (arg 10), so
        # apply_mirofish_to_confluence is NOT called here.
        confluence_v2=$(calculate_confluence_score_v2 "$symbol" "$rsi_score" "$macd_score" "$bb_score" \
            "$obv_score" "$regime" "$mr_score" "$tf_score" "$kalman_trend" "$sentiment_score" </dev/null 2>/dev/null \
            | jq -c . 2>/dev/null)
        if [[ -z "$confluence_v2" ]]; then
            log_error "v2 scoring failed for $symbol"
            return 1
        fi
        confluence=$(echo "$confluence_v2" | jq -c '{
            model: "v2",
            final_confidence: .confluence_score,
            signal: .recommendation,
            reasoning: .metadata.confidence_note,
            sentiment_available: (.components.sentiment.available // false),
            sentiment_contribution: (.components.sentiment.score // null)
        } + (if .components.mirofish then {mirofish: .components.mirofish} else {} end)')
    fi

    # Generate output (one line, so callers can pick it out with grep '^{')
    jq -c -n --arg symbol "$symbol" --arg ds "$data_source" --arg dw "$data_warning" \
        --arg model "$scoring_model" \
        --argjson rsi "$rsi_score" --argjson macd "$macd_score" --argjson bb "$bb_score" \
        --argjson stoch "$stoch_score" --argjson will "$williams_score" --argjson obv "$obv_score" \
        --argjson sent "$sentiment_json" --argjson conf "$confluence" --argjson c2 "$confluence_v2" \
        --argjson v2in "$v2_inputs" --argjson v2ok "$v2_inputs_available" \
        --argjson ind "$indicators_json" '
        {symbol: $symbol, data_source: $ds, data_warning: $dw, scoring_model: $model,
         scores: {rsi: $rsi, macd: $macd, bollinger_bands: $bb, stochastic: $stoch,
                  williams_r: $will, obv: $obv, sentiment: $sent},
         confluence: $conf}
        + (if $c2 != null then {confluence_v2: $c2} else {} end)
        + {v2_inputs: $v2in, v2_inputs_available: $v2ok, indicators: $ind}'
}

# ============================================================================
# Analysis Pipeline
# ============================================================================

analyze_stock() {
    local symbol=$1
    
    log_info "Analyzing $symbol..."
    
    # Fetch OHLCV data
    local ohlcv
    if ! ohlcv=$(fetch_stock_ohlcv "$symbol" 60) || [[ "$ohlcv" != *'"ohlcv":'* ]]; then
        log_error "Skipping $symbol - unable to fetch data"
        return 1
    fi
    
    # Calculate indicators
    local indicators
    if ! indicators=$(calculate_all_indicators "$symbol" "$ohlcv") || [[ -z "$indicators" ]]; then
        log_error "Skipping $symbol - insufficient data"
        return 1
    fi
    
    # Score and calculate confluence
    local analysis
    if ! analysis=$(score_stock "$symbol" "$indicators") || [[ -z "$analysis" ]]; then
        log_error "Skipping $symbol - scoring failed"
        return 1
    fi

    # Phase 1 Kelly position plan (analysis only; never allocates budget).
    # Entry = last close of the fetched series, stop = STOP_LOSS_PERCENT below.
    if [[ "${KELLY_SIZING_ENABLED:-false}" == "true" ]] && declare -f kelly_position_plan >/dev/null; then
        local entry stop conf plan kelly_regime
        entry=$(extract_closes "$ohlcv" | tail -1)
        stop=$(calc_stop_loss_percent "$entry" "${STOP_LOSS_PERCENT:-5}")
        conf=$(echo "$analysis" | jq -r '.confluence.final_confidence // 50' 2>/dev/null)
        # v2 mode: size with the detected regime (legacy has none: unknown)
        kelly_regime=$(echo "$analysis" | jq -r '.confluence_v2.components.regime_score.regime // "unknown"' 2>/dev/null)
        plan=$(kelly_position_plan "${ACCOUNT_EQUITY:-10000}" "$entry" "$stop" "${conf:-50}" "${kelly_regime:-unknown}")
        if [[ -n "$plan" ]]; then
            analysis=$(echo "$analysis" | jq -c --argjson p "$plan" '. + {position_sizing:$p}' 2>/dev/null || echo "$analysis")
        fi
    fi

    echo "$analysis"
    log_info "Completed analysis for $symbol"
    return 0
}

# ============================================================================
# Report Generation
# ============================================================================

generate_report() {
    local analysis_json=$1
    local output_dir=${2:-"output/reports"}
    
    mkdir -p "$output_dir"
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local report_file="${output_dir}/swing_analysis_${timestamp}.html"
    
    log_info "Generating HTML report: $report_file" >&2
    
    # Machine-readable copy: array of the analysis JSON lines (log lines and
    # "---" separators dropped)
    local json_file="${output_dir}/swing_analysis_${timestamp}.json"
    if echo "$analysis_json" | grep '^{' | jq -s '.' > "$json_file" 2>/dev/null; then
        log_info "JSON report: $json_file" >&2
    else
        rm -f "$json_file"
        log_warn "Could not write JSON report: $json_file" >&2
    fi

    generate_html_report "$analysis_json" "$report_file"
    
    if [[ -f "$report_file" ]]; then
        log_info "Report generated successfully: $report_file" >&2
        echo "$report_file"
        return 0
    else
        log_error "Failed to generate report"
        return 1
    fi
}

# Print one score breakdown line per analysis to stdout
# Args: analysis output (log lines, "---" separators and one JSON line per symbol)
# Returns: 0; prints a "SCORE BREAKDOWN (v2: ...)" or "(legacy: ...)" block
print_score_breakdown() {
    local results=$1
    local header="v2: 15% ML + 35% regime-weighted MR/TF + 30% technical + 20% OBV/Kalman volume-trend; sentiment ${V2_SENTIMENT_WEIGHT:-0.10} when available"
    [[ "${SCORING_MODE:-v2}" == "legacy" ]] && header="legacy: 80% technical average + 20% sentiment"
    echo ""
    echo "============================================"
    echo "SCORE BREAKDOWN (${header})"
    echo "============================================"
    echo "$results" | grep '^{' | jq -r '
        def num: if . == null then "n/a" else tostring end;
        def pct: if . == null then "0" else tostring end;
        . as $a
        | if .confluence_v2 then
            (.confluence_v2.components) as $c
            | "\($a.symbol)  score \($a.confluence.final_confidence) \($a.confluence.signal)"
              + " | ML \($c.ml_confidence.score | num)"
              + (if $c.ml_confidence.score != null then " \($c.ml_confidence.direction)" else "" end)
              + " (\($c.ml_confidence.weight_percent | pct)%)"
              + " | Regime \($c.regime_score.score) \($c.regime_score.regime) (\($c.regime_score.weight_percent)%)"
              + " | Technical \($c.technical_score.score) (\($c.technical_score.weight_percent)%)"
              + " | Volume/Trend \($c.volume_trend_score.score) (\($c.volume_trend_score.weight_percent)%)"
              + " | Sentiment \(($c.sentiment.score // null) | num) (\(($c.sentiment.weight_percent // 0) | pct)%)"
              + (if $c.mirofish then " | MiroFish \($c.mirofish.score | num) \($c.mirofish.status) (\($c.mirofish.weight_percent)%)" else "" end)
              + " | OBV \($a.scores.obv) | data \($a.data_source)"
          else
            "\($a.symbol)  score \($a.confluence.final_confidence) \($a.confluence.signal)"
              + " | Technical avg \($a.confluence.technical_avg | num)"
              + " (\(if $a.confluence.sentiment_available then "80" else "100" end)%)"
              + " | Sentiment \($a.confluence.sentiment_contribution | num)"
              + " (\(if $a.confluence.sentiment_available then "20" else "0" end)%)"
              + (if $a.confluence.mirofish then " | MiroFish \($a.confluence.mirofish.score | num) \($a.confluence.mirofish.status)" else "" end)
              + " | OBV \($a.scores.obv) | data \($a.data_source)"
          end' 2>/dev/null
    return 0
}

# ============================================================================
# Enhancement Module Management
# ============================================================================

# Initialize ML predictor module (XGBoost, 15% weight in scoring)
init_ml_predictor() {
    if [[ "$ENABLE_ML_PREDICTOR" != "true" ]]; then
        return 0
    fi
    
    log_info "Initializing ML predictor module (XGBoost, 15% weight)"
    
    if [[ ! -f "$AGENT_DIR/lib/ml_predictor.sh" ]]; then
        log_warn "ML predictor module not found: $AGENT_DIR/lib/ml_predictor.sh"
        log_info "ML predictor will be skipped (+5-10% accuracy improvement unavailable)"
        return 1
    fi
    
    source "$AGENT_DIR/lib/ml_predictor.sh" || {
        log_warn "Failed to load ML predictor module"
        return 1
    }
    
    log_info "✓ ML predictor module loaded (lib/ml_predictor.sh; v2 scoring (default) always runs the ML predictor; --legacy-score does not use it)"
    return 0
}

# Initialize regime-adaptive weighting module
init_regime_adaptive() {
    if [[ "$ENABLE_REGIME_ADAPT" != "true" ]]; then
        return 0
    fi
    
    log_info "Initializing regime-adaptive weighting module"
    
    if [[ ! -f "$AGENT_DIR/lib/regime_adaptive.sh" ]]; then
        log_warn "Regime-adaptive module not found: $AGENT_DIR/lib/regime_adaptive.sh"
        log_info "Regime-adaptive weighting will be skipped (+3-5% win rate improvement unavailable)"
        return 1
    fi
    
    source "$AGENT_DIR/lib/regime_adaptive.sh" || {
        log_warn "Failed to load regime-adaptive module"
        return 1
    }
    
    log_info "✓ Regime-adaptive weighting initialized (+3-5% win rate improvement)"
    return 0
}

# Initialize Kalman filter for price smoothing
init_kalman_filter() {
    if [[ "$ENABLE_KALMAN_FILTER" != "true" ]]; then
        return 0
    fi
    
    log_info "Initializing Kalman filter for price smoothing"
    
    if [[ ! -f "$AGENT_DIR/lib/kalman_filter.sh" ]]; then
        log_warn "Kalman filter module not found: $AGENT_DIR/lib/kalman_filter.sh"
        log_info "Kalman filter will be skipped (better price smoothing unavailable)"
        return 1
    fi
    
    source "$AGENT_DIR/lib/kalman_filter.sh" || {
        log_warn "Failed to load Kalman filter module"
        return 1
    }
    
    log_info "✓ Kalman filter module loaded (lib/kalman_filter.sh; v2 scoring (default) always uses the Kalman trend; --legacy-score does not use it)"
    return 0
}

# Initialize dashboard backend and frontend servers
init_dashboard() {
    if [[ "$ENABLE_DASHBOARD" != "true" ]]; then
        return 0
    fi
    
    log_info "Initializing React Dashboard"
    
    if [[ ! -f "$AGENT_DIR/lib/dashboard.sh" ]]; then
        log_warn "Dashboard module not found: $AGENT_DIR/lib/dashboard.sh"
        log_info "Dashboard will be skipped (UI unavailable)"
        return 1
    fi
    
    source "$AGENT_DIR/lib/dashboard.sh" || {
        log_warn "Failed to load dashboard module"
        return 1
    }
    
    log_info "Starting dashboard backend and frontend servers..."
    start_dashboard_servers || {
        log_warn "Dashboard servers may not have started correctly"
        return 1
    }
    
    log_info "✓ Dashboard initialized (React UI, real-time updates)"
    return 0
}

# Initialize all enhancements (--full flag)
init_all_enhancements() {
    log_info "Enabling all v6.3 enhancements (--full)"
    
    ENABLE_ML_PREDICTOR=true
    ENABLE_REGIME_ADAPT=true
    ENABLE_KALMAN_FILTER=true
    ENABLE_DASHBOARD=true
    
    init_ml_predictor
    init_regime_adaptive
    init_kalman_filter
    init_dashboard
    
    log_info "✓ All enhancements enabled"
}

# Display version and features
display_version() {
    cat << 'EOF'

============================================
StockSwingTrader v6.3
Advanced Swing Trading Analysis Platform
============================================

FEATURES:
  Core Analysis:
    • 8+ technical indicators (RSI, MACD, Bollinger Bands, ATR, OBV, Stochastic, Williams %R)
    • Multi-source sentiment analysis (Twitter, Reddit, StockTwits, News)
    • Confidence scoring (0-100) with buy/sell/hold signals
    • v2 confluence scoring by default (ML, regime-weighted MR/TF, technical,
      OBV/Kalman volume-trend, optional sentiment); --legacy-score for the old formula
    • Professional HTML reports with risk metrics

  v6.3 Enhancements:
    • XGBoost ML Predictor (+5-10% accuracy improvement)
    • Regime-Adaptive Weighting (+3-5% win rate improvement)
    • Kalman Filter Price Smoothing (fewer false signals)
    • Complete Backtesting Module (parameter tuning, performance analysis)
    • React Dashboard (professional UI, real-time updates)

  Phase 1 (from v6.2):
    • Fractional (quarter) Kelly position sizing with daily risk budget (--kelly)
    • Deterministic news sentiment (Finnhub/NewsAPI keyword classifier)
    • Optional MiroFish scan-cache signal, default off, no network (--mirofish)

  Broker Integration:
    • Alpaca Securities and Robinhood Markets
    • Account management, position tracking, order placement
    • Rate limiting and retry logic

  Order Safety (live safety, Step 1):
    • Limit orders with bracket stop loss / take profit by default, client order ids
    • Kill switch (--halt / --resume), hard caps, daily loss halt, duplicate guard
    • Reconciliation against a local baseline + order ledger (--reconcile)
    • Market hours policy, PDT warning, paper/live guard (--live + typed confirmation)
    • Alerts to logs/alerts.log, optional Slack / email

VERSION: 6.3
STATUS: Production-ready with optional enhancements

Use --help for usage information
Use --full to enable all enhancements
Use individual flags: --ml, --regime-adapt, --kalman, --dashboard, --kelly, --mirofish, --phase1

============================================

EOF
}

# ============================================================================
# Top Stocks Selection
# ============================================================================

get_top_10_stocks() {
    # Use default watchlist or fetch top performers
    # For demo: use popular stocks
    echo "AAPL MSFT GOOGL AMZN TSLA META NFLX CRM ADBE NVDA"
}

# ============================================================================
# Main Entry Point
# ============================================================================

usage() {
    cat << 'EOF'
StockSwingTrader Agent v6.3 - Advanced Swing Trading Analysis Platform

Usage: ./StockSwingTrader_Agent.sh [OPTIONS]

=== CORE ANALYSIS OPTIONS ===

    --symbols SYMBOL1,SYMBOL2,...    Analyze specific stocks (comma-separated)
    --watchlist FILE                 Analyze stocks from file (one per line)
    --top-10                         Analyze top 10 stocks by market cap
    --output-dir DIR                 Output directory for reports (default: output/reports)
    --debug                          Enable verbose debug logging
    --version                        Display version and feature information
    --legacy-score                   Use the legacy score (80% technical average + 20% sentiment)
                                     instead of v2 (default: 15% ML + 35% regime-weighted MR/TF
                                     + 30% technical + 20% OBV/Kalman volume-trend; sentiment
                                     V2_SENTIMENT_WEIGHT when available). Also: SCORING_MODE=legacy

=== ENHANCEMENT FLAGS (v6.3) ===

    --ml                             Load the ML predictor module (v2 scoring, the default,
                                     always runs the ML predictor: XGBoost, 15% weight)
    
    --regime-adapt                   Enable regime-adaptive weighting by market conditions
                                     (+3-5% win rate improvement)
    
    --kalman                         Load the Kalman filter module (v2 scoring, the default,
                                     always uses the Kalman trend in volume/trend)
    
    --dashboard                      Start dashboard backend and frontend servers
                                     (React UI, professional interface, real-time updates)
    
    --full                           Enable ALL v6.3 enhancements (equivalent to:
                                     --ml --regime-adapt --kalman --dashboard)

=== PHASE 1 FLAGS (ported from v6.2) ===
    --kelly                          Fractional (quarter) Kelly position sizing with daily risk budget;
                                     never exceeds MAX_POSITION_SIZE / KELLY_MAX_POSITION_PCT / daily loss limit
    --mirofish                       Use MiroFish scan cache (cache/mirofish/<SYMBOL>.json) if fresh (<36h);
                                     no network calls; skipped instantly when absent (also: MIROFISH_ENABLED=true)
    --phase1                         Enable --kelly and --mirofish (--full does not include them)

=== BROKER & TRADING OPTIONS ===

    --broker {alpaca|robinhood}      Choose broker for trading (default: alpaca)
                                     * alpaca   : Alpaca Securities
                                     * robinhood: Robinhood Markets
    
    --check-account                  Display account balance and details
    --view-positions                 List all open positions
    --buy SYMBOL QTY                 Place a buy order with confirmation (default: limit order
                                     + bracket stop loss / take profit; see ORDER SAFETY)
    --sell SYMBOL QTY                Place a sell order with confirmation (limit by default)

=== ORDER SAFETY (live safety, Step 1) ===

    Every --buy/--sell passes: kill switch, live guard, MAX_ORDER_QTY (before any
    broker contact), market hours, reconciliation, daily loss halt, position and
    notional caps (no short selling), duplicate guard, PDT warning. Blocks are
    written to logs/alerts.log (Slack / email optional, off by default).

    --order-type limit|market        Order type (default ORDER_TYPE=limit: reference price
                                     +/- LIMIT_OFFSET_PCT 0.2%)
    --limit-price PRICE              Explicit limit price (limit orders)
    --no-bracket                     Send a plain order without the bracket stop loss /
                                     take profit (default ORDER_BRACKET=true, buys, gtc)
    --live                           Required for orders on a LIVE endpoint (anything but
                                     paper-api.alpaca.markets or 127.0.0.1; Robinhood is
                                     always live); you then type "SYMBOL QTY" to confirm.
                                     Refused when the active config file is tracked in git.
    --allow-mismatch                 Place the order even if reconciliation found a mismatch
                                     (prints a warning and sends an alert)
    --halt [REASON]                  Engage the kill switch: no new orders (no broker call)
    --resume                         Release the kill switch
    --safety-status                  Show mode, kill switch, caps, today's notional, ledger,
                                     baseline and alert channels (no broker call)
    --reconcile                      Compare broker positions / open orders with the local
                                     baseline + order ledger (exit 0 match, 3 mismatch)
    --reconcile-accept               Adopt the broker's current positions as the baseline

    Config caps (config.template.sh "Live safety"): MAX_ORDER_QTY=100,
    MAX_ORDER_NOTIONAL=2500, MAX_DAILY_NOTIONAL=10000, MAX_OPEN_POSITIONS=5,
    DAILY_LOSS_LIMIT_PCT (empty = DEFAULT_RISK_LEVEL 2/5/10%),
    DUPLICATE_ORDER_WINDOW_SECONDS=300, OUTSIDE_HOURS_POLICY=refuse|queue,
    PDT_EQUITY_THRESHOLD=25000, RECONCILE_ON_STARTUP=true, SST_STATE_DIR (.state/)

=== BACKTESTING OPTIONS ===

    --backtest SYMBOLS               Run backtest (comma-separated); use with --start/--end/--train-pct
--start START_DATE               Backtest start date (YYYY-MM-DD, default: 2 years ago)
    --end END_DATE                   Backtest end date (YYYY-MM-DD, default: today)
    --train-pct PCT                  Train/test split percentage (default: 80)

=== HELP ===

    --help                           Show this help message

=== QUICK EXAMPLES ===

Basic Analysis:
    ./StockSwingTrader_Agent.sh --symbols AAPL,MSFT,GOOGL
    ./StockSwingTrader_Agent.sh --top-10 --debug
    ./StockSwingTrader_Agent.sh --watchlist config/watchlist.txt

With Enhancements:
    ./StockSwingTrader_Agent.sh --symbols AAPL,MSFT --ml --regime-adapt
    ./StockSwingTrader_Agent.sh --symbols AAPL --kalman
    ./StockSwingTrader_Agent.sh --symbols AAPL,MSFT,GOOGL --full
    ./StockSwingTrader_Agent.sh --top-10 --full --debug
    ./StockSwingTrader_Agent.sh --symbols AAPL,MSFT --phase1

Backtesting:
    ./StockSwingTrader_Agent.sh --backtest AAPL --start 2022-01-01 --end 2024-01-01
./StockSwingTrader_Agent.sh --backtest AAPL,MSFT,GOOGL --train-pct 80

Dashboard:
    ./StockSwingTrader_Agent.sh --dashboard
    ./StockSwingTrader_Agent.sh --symbols AAPL,MSFT --dashboard

Broker Trading:
    ./StockSwingTrader_Agent.sh --check-account
    ./StockSwingTrader_Agent.sh --buy AAPL 10
    ./StockSwingTrader_Agent.sh --sell MSFT 5
    ./StockSwingTrader_Agent.sh --broker robinhood --check-account
    ./StockSwingTrader_Agent.sh --broker robinhood --buy AAPL 10 --live
    ./StockSwingTrader_Agent.sh --buy AAPL 2 --order-type market --no-bracket
    ./StockSwingTrader_Agent.sh --reconcile-accept
    ./StockSwingTrader_Agent.sh --halt "news event"
    ./StockSwingTrader_Agent.sh --safety-status

EOF
}

main() {
    local symbols=""
    local watchlist_file=""
    local use_top_10=false
    local output_dir="output/reports"
    
    # Trading flags
    local broker_trading_mode=false
    local trading_check_account=false
    local trading_view_positions=false
    local trading_buy_symbol=""
    local trading_buy_qty=""
    local trading_sell_symbol=""
    local trading_sell_qty=""
    local trading_buy_requested=false
    local trading_sell_requested=false
    local trading_reconcile=false
    local trading_reconcile_accept=false
    
    # Local safety commands (no broker): halt | resume | safety-status
    local local_command=""
    local local_halt_reason=""
    
    # Backtest flags
    local backtest_symbols=""
    local backtest_start_date=""
    local backtest_end_date=""
    local backtest_train_pct="80"
    
    # Parse command-line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)
                display_version
                exit 0
                ;;
            --ml)
                ENABLE_ML_PREDICTOR=true
                log_info "ML predictor enhancement enabled (--ml)"
                shift
                ;;
            --regime-adapt)
                ENABLE_REGIME_ADAPT=true
                log_info "Regime-adaptive weighting enhancement enabled (--regime-adapt)"
                shift
                ;;
            --kalman)
                ENABLE_KALMAN_FILTER=true
                log_info "Kalman filter enhancement enabled (--kalman)"
                shift
                ;;
            --dashboard)
                ENABLE_DASHBOARD=true
                log_info "Dashboard enhancement enabled (--dashboard)"
                shift
                ;;
            --kelly)
                KELLY_SIZING_ENABLED=true
                ENABLE_KELLY_SIZING=true
                export KELLY_SIZING_ENABLED
                log_info "Kelly position sizing enabled (--kelly)"
                shift
                ;;
            --mirofish)
                MIROFISH_ENABLED=true
                export MIROFISH_ENABLED
                log_info "MiroFish cache signal enabled (--mirofish; cache only, no network)"
                shift
                ;;
            --phase1)
                KELLY_SIZING_ENABLED=true
                ENABLE_KELLY_SIZING=true
                MIROFISH_ENABLED=true
                export KELLY_SIZING_ENABLED MIROFISH_ENABLED
                log_info "Phase 1 enabled (--phase1: Kelly sizing, MiroFish cache)"
                shift
                ;;
            --full)
                ENABLE_ALL_ENHANCEMENTS=true
                log_info "All v6.3 enhancements enabled (--full: ML, Regime, Kalman, Dashboard)"
                shift
                ;;
            --broker)
                BROKER_CHOICE="$2"
                # Validate broker choice
                if ! [[ "$BROKER_CHOICE" =~ ^(alpaca|robinhood)$ ]]; then
                    log_error "Invalid broker: $BROKER_CHOICE. Use 'alpaca' or 'robinhood'."
                    exit 1
                fi
                shift 2
                ;;
            --symbols)
                symbols="$2"
                shift 2
                ;;
            --watchlist)
                watchlist_file="$2"
                shift 2
                ;;
            --top-10)
                use_top_10=true
                shift
                ;;
            --output-dir)
                output_dir="$2"
                shift 2
                ;;
            --debug)
                DEBUG_MODE=true
                shift
                ;;
            --legacy-score)
                SCORING_MODE=legacy
                export SCORING_MODE
                log_info "Legacy scoring enabled (--legacy-score: 80% technical average + 20% sentiment)"
                shift
                ;;
            --order-type)
                ORDER_TYPE_OVERRIDE="$2"
                if ! [[ "$ORDER_TYPE_OVERRIDE" =~ ^(limit|market)$ ]]; then
                    log_error "Invalid --order-type: '${2:-}' (use limit or market)"
                    exit 1
                fi
                shift 2
                ;;
            --limit-price)
                ORDER_LIMIT_PRICE="$2"
                if ! [[ "$ORDER_LIMIT_PRICE" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! _os_gt "$ORDER_LIMIT_PRICE" 0; then
                    log_error "Invalid --limit-price: '${2:-}' (must be a number > 0)"
                    exit 1
                fi
                shift 2
                ;;
            --no-bracket)
                ORDER_NO_BRACKET=true
                shift
                ;;
            --live)
                ORDER_LIVE_FLAG=true
                shift
                ;;
            --allow-mismatch)
                RECONCILE_ALLOW_MISMATCH=true
                shift
                ;;
            --halt)
                local_command="halt"
                if [[ $# -ge 2 && "$2" != --* ]]; then
                    local_halt_reason="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            --resume)
                local_command="resume"
                shift
                ;;
            --safety-status)
                local_command="safety-status"
                shift
                ;;
            --reconcile)
                trading_reconcile=true
                broker_trading_mode=true
                shift
                ;;
            --reconcile-accept)
                trading_reconcile_accept=true
                broker_trading_mode=true
                shift
                ;;
            --check-account)
                trading_check_account=true
                broker_trading_mode=true
                shift
                ;;
            --view-positions)
                trading_view_positions=true
                broker_trading_mode=true
                shift
                ;;
            --buy)
                trading_buy_requested=true
                trading_buy_symbol="$2"
                trading_buy_qty="$3"
                broker_trading_mode=true
                # Missing SYMBOL/QTY: shift what is there (plain `shift 3`
                # fails without shifting and the parser loops forever)
                shift $(( $# < 3 ? $# : 3 ))
                ;;
            --sell)
                trading_sell_requested=true
                trading_sell_symbol="$2"
                trading_sell_qty="$3"
                broker_trading_mode=true
                # Missing SYMBOL/QTY: shift what is there (plain `shift 3`
                # fails without shifting and the parser loops forever)
                shift $(( $# < 3 ? $# : 3 ))
                ;;
            # Legacy Alpaca compatibility flags (deprecated but still supported)
            --alpaca)
                BROKER_CHOICE="alpaca"
                broker_trading_mode=true
                shift
                ;;
            --place-buy)
                trading_buy_requested=true
                trading_buy_symbol="$2"
                trading_buy_qty="$3"
                BROKER_CHOICE="alpaca"
                broker_trading_mode=true
                # Missing SYMBOL/QTY: shift what is there (plain `shift 3`
                # fails without shifting and the parser loops forever)
                shift $(( $# < 3 ? $# : 3 ))
                ;;
            --place-sell)
                trading_sell_requested=true
                trading_sell_symbol="$2"
                trading_sell_qty="$3"
                BROKER_CHOICE="alpaca"
                broker_trading_mode=true
                # Missing SYMBOL/QTY: shift what is there (plain `shift 3`
                # fails without shifting and the parser loops forever)
                shift $(( $# < 3 ? $# : 3 ))
                ;;
            --alpaca-status)
                trading_check_account=true
                BROKER_CHOICE="alpaca"
                broker_trading_mode=true
                shift
                ;;
            --backtest)
                backtest_symbols="$2"
                shift 2
                ;;
            --start)
                backtest_start_date="$2"
                shift 2
                ;;
            --end)
                backtest_end_date="$2"
                shift 2
                ;;
            --train-pct)
                backtest_train_pct="$2"
                shift 2
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage
                exit 1
                ;;
        esac
    done
    
    # Initialize logging
    mkdir -p logs
    log_info "=========================================="
    log_info "$VERSION_STRING"
    log_info "=========================================="
    log_info "StockSwingTrader Agent started"
    log_info "Broker: $BROKER_CHOICE"
    log_info "Debug mode: $DEBUG_MODE"
    
    # Local safety commands: no broker is loaded or contacted
    if [[ -n "$local_command" ]]; then
        current_endpoint_mode >/dev/null
        case "$local_command" in
            halt)
                kill_switch_engage "${local_halt_reason:-manual halt (--halt)}" >/dev/null || {
                    log_error "Could not write the kill switch file: $(kill_switch_file)"
                    exit 1
                }
                echo "KILL SWITCH ENGAGED: ${local_halt_reason:-manual halt (--halt)}"
                echo "No new orders until --resume ($(kill_switch_file))"
                exit 0
                ;;
            resume)
                if kill_switch_active >/dev/null; then
                    kill_switch_release >/dev/null || exit 1
                    echo "Kill switch released; orders are allowed again"
                else
                    echo "Kill switch was not active"
                fi
                exit 0
                ;;
            safety-status)
                if [[ "$BROKER_CHOICE" == "alpaca" ]]; then
                    safety_status_report "$BROKER_CHOICE" "${ALPACA_BASE_URL:-}"
                else
                    safety_status_report "$BROKER_CHOICE" ""
                fi
                exit 0
                ;;
        esac
    fi
    
    # Initialize enabled enhancements
    if [[ "$ENABLE_ALL_ENHANCEMENTS" == "true" ]]; then
        init_all_enhancements
    else
        [[ "$ENABLE_ML_PREDICTOR" == "true" ]] && init_ml_predictor
        [[ "$ENABLE_REGIME_ADAPT" == "true" ]] && init_regime_adaptive
        [[ "$ENABLE_KALMAN_FILTER" == "true" ]] && init_kalman_filter
        [[ "$ENABLE_DASHBOARD" == "true" ]] && init_dashboard
    fi
    
    # Handle backtest mode
    if [[ -n "$backtest_symbols" ]]; then
        log_info "Backtest mode enabled"
        
        # Load backtest module
        if [[ ! -f "$AGENT_DIR/lib/backtest.sh" ]]; then
            log_error "Backtest module not found: $AGENT_DIR/lib/backtest.sh"
            exit 1
        fi
        source "$AGENT_DIR/lib/backtest.sh"
        
        # Set default dates if not provided
        if [[ -z "$backtest_start_date" ]]; then
            backtest_start_date=$(date -u -d "2 years ago" +%Y-%m-%d 2>/dev/null || date -u -v-2y +%Y-%m-%d)
        fi
        if [[ -z "$backtest_end_date" ]]; then
            backtest_end_date=$(date +%Y-%m-%d)
        fi
        
        log_info "Backtesting: $backtest_symbols ($backtest_start_date to $backtest_end_date)"
        
        # Run backtest
        backtest_multi_symbol "$backtest_symbols" "$backtest_start_date" "$backtest_end_date" "$backtest_train_pct"
        exit $?
    fi
    
    # Handle broker trading commands
    if [[ "$broker_trading_mode" == "true" ]]; then
        log_info "$BROKER_CHOICE broker mode enabled"
        
        # Reject bad order arguments before contacting the broker
        if [[ "$trading_buy_requested" == "true" ]]; then
            if [[ -z "$trading_buy_symbol" || -z "$trading_buy_qty" ]]; then
                log_error "Usage: --buy SYMBOL QTY"
                exit 1
            fi
            validate_order_args "$trading_buy_symbol" "$trading_buy_qty" || exit 1
        fi
        if [[ "$trading_sell_requested" == "true" ]]; then
            if [[ -z "$trading_sell_symbol" || -z "$trading_sell_qty" ]]; then
                log_error "Usage: --sell SYMBOL QTY"
                exit 1
            fi
            validate_order_args "$trading_sell_symbol" "$trading_sell_qty" || exit 1
        fi
        
        # Endpoint mode, printed once; a LIVE endpoint with a git-tracked
        # config file is refused for every broker command
        current_endpoint_mode >/dev/null
        echo "Mode: $(endpoint_mode_label "$SST_ENDPOINT_MODE") ($BROKER_CHOICE)"
        check_live_config_guard || exit 1
        
        # Order checks that need no broker (kill switch, live guard,
        # MAX_ORDER_QTY) run before the broker is contacted
        if [[ "$trading_buy_requested" == "true" ]]; then
            order_prechecks buy "$trading_buy_symbol" "$trading_buy_qty" || exit 1
        fi
        if [[ "$trading_sell_requested" == "true" ]]; then
            order_prechecks sell "$trading_sell_symbol" "$trading_sell_qty" || exit 1
        fi
        
        # Load and initialize broker
        if ! load_broker_module; then
            log_error "Failed to load $BROKER_CHOICE broker module"
            exit 1
        fi
        
        # Initialize broker connection
        if ! broker_connect; then
            log_error "Failed to connect to $BROKER_CHOICE. Check your credentials."
            exit 1
        fi
        
        # Handle individual trading commands
        if [[ "$trading_reconcile_accept" == "true" ]]; then
            reconcile_accept
            return $?
        fi
        
        if [[ "$trading_reconcile" == "true" ]]; then
            run_reconcile_command
            return $?
        fi
        
        if [[ "$trading_check_account" == "true" ]]; then
            startup_reconcile_warning
            show_broker_account
            return $?
        fi
        
        if [[ "$trading_view_positions" == "true" ]]; then
            startup_reconcile_warning
            show_broker_positions
            return $?
        fi
        
        if [[ -n "$trading_buy_symbol" ]] && [[ -n "$trading_buy_qty" ]]; then
            place_buy_order "$trading_buy_symbol" "$trading_buy_qty"
            return $?
        fi
        
        if [[ -n "$trading_sell_symbol" ]] && [[ -n "$trading_sell_qty" ]]; then
            place_sell_order "$trading_sell_symbol" "$trading_sell_qty"
            return $?
        fi
        
        # If no specific command, show account and positions
        startup_reconcile_warning
        show_broker_account
        echo ""
        show_broker_positions
        return $?
    fi
    
    # Determine stocks to analyze
    local stocks_to_analyze=()
    
    if [[ -n "$symbols" ]]; then
        IFS=',' read -ra stocks_to_analyze <<< "$symbols"
    elif [[ -n "$watchlist_file" && -f "$watchlist_file" ]]; then
        mapfile -t stocks_to_analyze < "$watchlist_file"
    elif [[ "$use_top_10" == "true" ]]; then
        IFS=' ' read -ra stocks_to_analyze <<< "$(get_top_10_stocks)"
    else
        # Default watchlist
        IFS=',' read -ra stocks_to_analyze <<< "$DEFAULT_WATCHLIST"
    fi
    
    log_info "Analyzing ${#stocks_to_analyze[@]} stock(s)"
    
    # Analyze each stock
    local all_results=""
    local analyzed_count=0
    
    for symbol in "${stocks_to_analyze[@]}"; do
        symbol=$(echo "$symbol" | xargs)  # Trim whitespace
        
        if [[ -z "$symbol" ]]; then
            continue
        fi
        
        local result
        # Count a symbol only when analyze_stock succeeded (its log lines
        # alone are not an analysis, e.g. when there is no market data)
        if result=$(analyze_stock "$symbol") && [[ -n "$result" ]]; then
            if [[ -z "$all_results" ]]; then
                all_results="$result"
            else
                all_results="${all_results}
---
${result}"
            fi
            ((analyzed_count++))
        fi
        
        # Rate limiting
        sleep 0.5
    done
    
    log_info "Successfully analyzed $analyzed_count out of ${#stocks_to_analyze[@]} stock(s)"
    
    if [[ -n "$all_results" ]]; then
        # Generate reports
        local report_file=$(generate_report "$all_results" "$output_dir")
        
        print_score_breakdown "$all_results"

        if [[ -n "$report_file" ]]; then
            log_info "Analysis complete. Open report in browser: $report_file"
            echo ""
            echo "============================================"
            echo "Analysis Complete!"
            echo "Report: $report_file"
            echo "============================================"
            return 0
        fi
    else
        log_error "No stocks analyzed successfully"
        return 1
    fi
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
