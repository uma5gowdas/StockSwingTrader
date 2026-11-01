#!/bin/bash
# ============================================================================
# Tests: broker commands in StockSwingTrader_Agent.sh
# ============================================================================
# Covers --check-account, --view-positions, --buy, --sell and the deprecated
# --alpaca / --alpaca-status / --place-buy / --place-sell aliases, order
# confirmation (yes / no / EOF), invalid symbol and quantity, --ml / --kalman
# module loading, and that no lib file changes the caller's SCRIPT_DIR.
#
# SAFETY: no real broker is contacted. Alpaca calls go to a local stub
# (tests/stubs/alpaca_stub_server.py on 127.0.0.1) through a stub config file
# (SST_CONFIG_FILE), so the local config.sh and its keys are never used.
# Robinhood is tested with stub shell functions only; its API URLs point at
# an unused local port as a second guard. HOME is a temp dir.
# bash 3.2 compatible; no `timeout` (perl alarm guards each run).
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"
AGENT="$PROJECT_DIR/StockSwingTrader_Agent.sh"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sst_broker_test.XXXXXX")"
STUB_PID=""

cleanup() {
    if [[ -n "$STUB_PID" ]]; then
        kill "$STUB_PID" 2>/dev/null
        wait "$STUB_PID" 2>/dev/null
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

export SST_OFFLINE=1
export HOME="$WORK_DIR/home"
mkdir -p "$HOME"

# ============================================================================
# Test Utilities
# ============================================================================

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓ PASS${NC}: $1"
}

fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗ FAIL${NC}: $1"
    [[ -n "$2" ]] && echo "  $2"
}

assert_equals() {
    local expected=$1 actual=$2 name=$3
    if [[ "$expected" == "$actual" ]]; then
        pass "$name"
    else
        fail "$name" "Expected: '$expected'  Got: '$actual'"
    fi
}

assert_contains() {
    local haystack=$1 needle=$2 name=$3
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$name"
    else
        fail "$name" "Missing: '$needle'"
        echo "$haystack" | tail -8 | sed 's/^/    | /'
    fi
}

assert_not_contains() {
    local haystack=$1 needle=$2 name=$3
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$name"
    else
        fail "$name" "Unexpected: '$needle'"
    fi
}

# Number of lines in a file (0 if missing)
count_lines() {
    if [[ -f "$1" ]]; then
        wc -l < "$1" | tr -d ' '
    else
        echo 0
    fi
}

# All agent output, checked for lib/lib paths at the end
ALL_OUTPUT=""

# run_agent STDIN ARGS... : run the agent in WORK_DIR against the stub config.
# Sets OUT (stdout+stderr) and RC. Killed after 60 s.
run_agent() {
    local input=$1
    shift
    OUT=$(cd "$WORK_DIR" && printf '%s' "$input" | \
        SST_CONFIG_FILE="${RUN_CONFIG:-$STUB_CONFIG}" \
        perl -e 'alarm 60; exec @ARGV' bash "$AGENT" "$@" 2>&1)
    RC=$?
    ALL_OUTPUT="${ALL_OUTPUT}${OUT}"$'\n'
}

# ============================================================================
# Start the local Alpaca stub
# ============================================================================

PORT_FILE="$WORK_DIR/stub.port"
REQ_LOG="$WORK_DIR/requests.log"
ORDER_LOG="$WORK_DIR/orders.log"
: > "$REQ_LOG"
: > "$ORDER_LOG"

python3 "$TEST_DIR/stubs/alpaca_stub_server.py" "$PORT_FILE" "$REQ_LOG" "$ORDER_LOG" &
STUB_PID=$!
for _ in $(seq 1 100); do
    [[ -s "$PORT_FILE" ]] && break
    sleep 0.1
done
STUB_PORT=$(cat "$PORT_FILE" 2>/dev/null)
STUB_URL="http://127.0.0.1:${STUB_PORT}"

echo "=========================================="
echo "  Broker Commands Test Suite"
echo "=========================================="
echo "Alpaca stub: $STUB_URL"

if [[ -z "$STUB_PORT" ]]; then
    fail "Alpaca stub server started" "no port written to $PORT_FILE"
else
    pass "Alpaca stub server started on 127.0.0.1"
fi

STUB_CONFIG="$WORK_DIR/config.stub.sh"
cat > "$STUB_CONFIG" <<EOF
export ALPACA_API_KEY="stub-key-id"
export ALPACA_SECRET_KEY="stub-secret"
export ALPACA_OAUTH_TOKEN=""
export ALPACA_BASE_URL="$STUB_URL"
export ALPACA_DATA_URL="$STUB_URL"
export ROBINHOOD_API_BASE_URL="http://127.0.0.1:9"
export ROBINHOOD_OAUTH_BASE_URL="http://127.0.0.1:9"
export SST_STATE_DIR="$WORK_DIR/state"
export ALERT_LOG_FILE="$WORK_DIR/alerts.log"
EOF

NOCRED_CONFIG="$WORK_DIR/config.nocred.sh"
cat > "$NOCRED_CONFIG" <<EOF
export ALPACA_API_KEY=""
export ALPACA_SECRET_KEY=""
export ALPACA_OAUTH_TOKEN=""
export APCA_API_KEY_ID=""
export APCA_API_SECRET_KEY=""
export APCA_API_OAUTH_TOKEN=""
export ALPACA_BASE_URL="$STUB_URL"
export ALPACA_DATA_URL="$STUB_URL"
export SST_STATE_DIR="$WORK_DIR/state"
export ALERT_LOG_FILE="$WORK_DIR/alerts.log"
EOF

# ============================================================================
# Library files do not change the caller's SCRIPT_DIR
# ============================================================================

echo ""
echo "--- Library files keep the caller's SCRIPT_DIR ---"

for lib in "$PROJECT_DIR"/lib/*.sh; do
    name=$(basename "$lib")
    result=$(cd "$WORK_DIR" && perl -e 'alarm 30; exec @ARGV' bash -c '
        SCRIPT_DIR=/sentinel/script_dir
        LIB_DIR=/sentinel/lib_dir
        AGENT_DIR=/sentinel/agent_dir
        source "$1" >/dev/null 2>&1 </dev/null
        case "$-" in *e*) e=errexit ;; *) e=no_errexit ;; esac
        echo "$SCRIPT_DIR|$LIB_DIR|$AGENT_DIR|$e"
    ' _ "$lib")
    assert_equals "/sentinel/script_dir|/sentinel/lib_dir|/sentinel/agent_dir|no_errexit" "$result" \
        "sourcing lib/$name keeps SCRIPT_DIR/LIB_DIR/AGENT_DIR and does not enable errexit"
done

agent_dirs=$(cd "$WORK_DIR" && SST_CONFIG_FILE="$STUB_CONFIG" bash -c '
    source "$1" >/dev/null 2>&1 </dev/null
    echo "$SCRIPT_DIR|$AGENT_DIR"
' _ "$AGENT")
assert_equals "$PROJECT_DIR|$PROJECT_DIR" "$agent_dirs" \
    "after sourcing the agent (all libs loaded) SCRIPT_DIR and AGENT_DIR are the project root"

# ============================================================================
# Broker module loading (sourced agent)
# ============================================================================

echo ""
echo "--- Broker module loading ---"

alpaca_load=$(cd "$WORK_DIR" && SST_CONFIG_FILE="$STUB_CONFIG" bash -c '
    source "$1" >/dev/null 2>&1 </dev/null
    BROKER_CHOICE=alpaca
    load_broker_module >/dev/null 2>&1; rc=$?
    funcs=ok
    for f in alpaca_init alpaca_get_account alpaca_get_positions alpaca_place_order alpaca_get_quote; do
        declare -F "$f" >/dev/null || funcs="missing:$f"
    done
    case "$-" in *e*) e=errexit ;; *) e=no_errexit ;; esac
    echo "$rc|$BROKER_PREFIX|$funcs|$SCRIPT_DIR|$e"
' _ "$AGENT")
assert_equals "0|alpaca_|ok|$PROJECT_DIR|no_errexit" "$alpaca_load" \
    "load_broker_module alpaca: loads, defines alpaca_* functions, keeps SCRIPT_DIR, no errexit"

rh_load=$(cd "$WORK_DIR" && SST_CONFIG_FILE="$STUB_CONFIG" bash -c '
    source "$1" >/dev/null 2>&1 </dev/null
    BROKER_CHOICE=robinhood
    load_broker_module >/dev/null 2>&1; rc=$?
    funcs=ok
    for f in robinhood_init robinhood_get_account robinhood_get_positions robinhood_place_order robinhood_get_quote robinhood_oauth_load_tokens; do
        declare -F "$f" >/dev/null || funcs="missing:$f"
    done
    echo "$rc|$BROKER_PREFIX|$BROKER_INITIALIZED_VAR|$funcs|$SCRIPT_DIR"
' _ "$AGENT")
assert_equals "0|robinhood_|ROBINHOOD_INITIALIZED|ok|$PROJECT_DIR" "$rh_load" \
    "load_broker_module robinhood: loads OAuth + broker modules, defines robinhood_* functions"

# Robinhood flow with stub functions (no Robinhood network call is possible:
# every function that would make one is replaced before use)
# Robinhood is always a LIVE endpoint: orders need ORDER_LIVE_FLAG=true
# (--live) and a typed "SYMBOL QTY" confirmation. Arg 3 "nolive" leaves the
# flag unset.
rh_flow() {
    local input=$1 action=$2 live=${3:-live}
    (cd "$WORK_DIR" && printf '%s' "$input" | SST_CONFIG_FILE="$STUB_CONFIG" \
        perl -e 'alarm 30; exec @ARGV' bash -c '
        source "$1" >/dev/null 2>&1 </dev/null
        BROKER_CHOICE=robinhood
        [[ "$4" == "live" ]] && ORDER_LIVE_FLAG=true
        load_broker_module >/dev/null 2>&1 || exit 90
        RH_ORDERS="$2/rh_orders.log"
        robinhood_api_request() { echo "UNEXPECTED_NETWORK_CALL" >&2; return 1; }
        robinhood_init() { ROBINHOOD_INITIALIZED=true; echo "stub robinhood_init"; }
        robinhood_get_account() { echo "{\"account_id\":\"RH0000STUB\",\"buying_power\":500.5,\"cash\":400.25,\"equity\":900.75,\"account_type\":\"cash\"}"; }
        robinhood_get_positions() { printf "%s\n%s\n" "{\"symbol\":\"MSFT\",\"qty\":3,\"avg_fill_price\":300.5,\"current_price\":310}" "{\"symbol\":\"AAPL\",\"qty\":1,\"avg_fill_price\":150,\"current_price\":151}"; }
        robinhood_get_quote() { echo "{\"symbol\":\"$1\",\"last_price\":50.5}"; }
        robinhood_place_order() { echo "$*" >> "$RH_ORDERS"; echo "{\"order_id\":\"rh-stub-1\",\"symbol\":\"$1\",\"side\":\"$3\"}"; }
        broker_connect || exit 91
        case "$3" in
            account) show_broker_account ;;
            positions) show_broker_positions ;;
            buy) place_buy_order AAPL 2 ;;
            sell) place_sell_order MSFT 1 ;;
        esac
    ' _ "$AGENT" "$WORK_DIR" "$action" "$live" 2>&1)
}

RH_ORDERS="$WORK_DIR/rh_orders.log"

out=$(rh_flow "" account)
ALL_OUTPUT="${ALL_OUTPUT}${out}"$'\n'
assert_contains "$out" "ROBINHOOD ACCOUNT STATUS" "robinhood (stubbed) account status shown"
assert_contains "$out" 'Portfolio Value: $900.75' "robinhood portfolio value falls back to equity"
assert_contains "$out" 'Account Type:    cash' "robinhood account type shown"
assert_not_contains "$out" "RH0000STUB" "robinhood account number is not printed"
assert_not_contains "$out" "UNEXPECTED_NETWORK_CALL" "robinhood stub flow makes no API request"

out=$(rh_flow "" positions)
ALL_OUTPUT="${ALL_OUTPUT}${out}"$'\n'
assert_contains "$out" 'MSFT: 3 shares @ $300.5' "robinhood (stubbed) positions listed (object stream)"
assert_contains "$out" 'AAPL: 1 shares @ $150' "robinhood second position listed"

out=$(rh_flow "AAPL 2"$'\n' buy nolive)
ALL_OUTPUT="${ALL_OUTPUT}${out}"$'\n'
assert_contains "$out" "orders need --live" "robinhood buy without --live (ORDER_LIVE_FLAG): refused"
assert_equals "0" "$(count_lines "$RH_ORDERS")" "robinhood buy without --live: robinhood_place_order not called"

out=$(rh_flow "no"$'\n' buy)
ALL_OUTPUT="${ALL_OUTPUT}${out}"$'\n'
assert_contains "$out" "Order cancelled" "robinhood buy + 'no': cancelled"
assert_equals "0" "$(count_lines "$RH_ORDERS")" "robinhood buy + 'no': robinhood_place_order not called"

out=$(rh_flow "AAPL 2"$'\n' buy)
ALL_OUTPUT="${ALL_OUTPUT}${out}"$'\n'
assert_contains "$out" 'Current Price:   $50.5' "robinhood buy: price from robinhood_get_quote"
assert_contains "$out" "BUY ORDER PLACED (ROBINHOOD)" "robinhood buy + 'yes': order placed via stub"
assert_equals "AAPL 2 buy" "$(cat "$RH_ORDERS" 2>/dev/null)" "robinhood buy + 'yes': stub got AAPL 2 buy"

out=$(rh_flow "MSFT 1"$'\n' sell)
ALL_OUTPUT="${ALL_OUTPUT}${out}"$'\n'
assert_contains "$out" "SELL ORDER PLACED (ROBINHOOD)" "robinhood sell + 'yes': order placed via stub"
assert_equals "MSFT 1 sell" "$(tail -1 "$RH_ORDERS" 2>/dev/null)" "robinhood sell + 'yes': stub got MSFT 1 sell"

# ============================================================================
# Alpaca CLI commands against the local stub
# ============================================================================

echo ""
echo "--- Alpaca CLI commands (local stub) ---"

# Adopt the stub's positions as the reconciliation baseline (orders are
# blocked on a reconciliation mismatch)
run_agent "" --reconcile-accept
assert_equals "0" "$RC" "--reconcile-accept exits 0"
if [[ -f "$WORK_DIR/state/positions_baseline.json" ]]; then
    pass "--reconcile-accept creates the baseline file in SST_STATE_DIR"
else
    fail "--reconcile-accept creates the baseline file in SST_STATE_DIR" "missing $WORK_DIR/state/positions_baseline.json"
fi

run_agent "" --check-account
assert_equals "0" "$RC" "--check-account exits 0"
assert_contains "$OUT" "Loaded Alpaca broker module" "--check-account loads the Alpaca module"
assert_contains "$OUT" "ALPACA ACCOUNT STATUS" "--check-account shows account status"
assert_contains "$OUT" 'Portfolio Value: $2503.75' "--check-account portfolio value"
assert_contains "$OUT" 'Cash Balance:    $1000.50' "--check-account cash"
assert_contains "$OUT" 'Buying Power:    $2001.00' "--check-account buying power"
assert_contains "$OUT" 'Account Type:    ACTIVE' "--check-account account status"
assert_not_contains "$OUT" "PA0000STUB01" "--check-account does not print the account number"
assert_not_contains "$OUT" "stub-key-id" "--check-account does not print the API key"
assert_not_contains "$OUT" "module not found" "--check-account: no 'module not found'"
assert_contains "$(cat "$REQ_LOG")" "GET /v2/account" "--check-account calls GET /v2/account on the stub"

run_agent "" --view-positions
assert_equals "0" "$RC" "--view-positions exits 0"
assert_contains "$OUT" "OPEN POSITIONS (ALPACA)" "--view-positions header"
assert_contains "$OUT" 'AAPL: 10 shares @ $150.25' "--view-positions lists the stub position"
assert_contains "$(cat "$REQ_LOG")" "GET /v2/positions" "--view-positions calls GET /v2/positions"

run_agent "" --alpaca-status
assert_equals "0" "$RC" "--alpaca-status (deprecated) exits 0"
assert_contains "$OUT" "ALPACA ACCOUNT STATUS" "--alpaca-status shows account status"

run_agent "" --alpaca
assert_equals "0" "$RC" "--alpaca (deprecated) exits 0"
assert_contains "$OUT" "ALPACA ACCOUNT STATUS" "--alpaca shows account status"
assert_contains "$OUT" 'AAPL: 10 shares @ $150.25' "--alpaca shows positions"

# --- orders: confirmation 'no' / EOF sends nothing ---
orders_before=$(count_lines "$ORDER_LOG")
run_agent "no"$'\n' --buy AAPL 2
assert_equals "0" "$RC" "--buy + 'no' exits 0"
assert_contains "$OUT" "BUY ORDER CONFIRMATION (ALPACA)" "--buy shows the confirmation"
assert_contains "$OUT" 'Current Price:   $123.45' "--buy price comes from the Alpaca quote"
assert_contains "$OUT" 'Estimated Cost:  $246.90' "--buy estimated cost"
assert_contains "$OUT" "Proceed with order? (yes/no)" "--buy asks for confirmation"
assert_contains "$OUT" "Order cancelled" "--buy + 'no' cancels"
assert_equals "$orders_before" "$(count_lines "$ORDER_LOG")" "--buy + 'no': no order sent"

run_agent "" --sell AAPL 1
assert_equals "0" "$RC" "--sell + EOF exits 0"
assert_contains "$OUT" "Order cancelled" "--sell + EOF (no answer) cancels"
assert_equals "$orders_before" "$(count_lines "$ORDER_LOG")" "--sell + EOF: no order sent"

run_agent "y"$'\n' --sell AAPL 1
assert_contains "$OUT" "Order cancelled" "--sell + 'y' (not 'yes') cancels"
assert_equals "$orders_before" "$(count_lines "$ORDER_LOG")" "--sell + 'y': no order sent"
assert_not_contains "$(cat "$REQ_LOG")" "POST" "no POST request reached the stub before any 'yes'"

# --- orders: confirmation 'yes' sends exactly one order ---
run_agent "yes"$'\n' --buy AAPL 2 --order-type market --no-bracket
assert_equals "0" "$RC" "--buy + 'yes' exits 0"
assert_contains "$OUT" "BUY ORDER PLACED (ALPACA)" "--buy + 'yes': order placed"
assert_contains "$OUT" '"order_id": "stub-order-0001"' "--buy + 'yes': order id shown"
assert_equals "$((orders_before + 1))" "$(count_lines "$ORDER_LOG")" "--buy + 'yes': exactly one order sent"
assert_equals "AAPL|2|buy|market|day" \
    "$(tail -1 "$ORDER_LOG" | jq -r '"\(.symbol)|\(.qty)|\(.side)|\(.type)|\(.time_in_force)"')" \
    "--buy + 'yes': order payload AAPL 2 buy market day"

run_agent "yes"$'\n' --sell MSFT 3
assert_equals "0" "$RC" "--sell + 'yes' exits 0"
assert_contains "$OUT" "SELL ORDER CONFIRMATION (ALPACA)" "--sell shows the confirmation"
assert_contains "$OUT" 'Estimated Proceeds: $370.35' "--sell estimated proceeds"
assert_contains "$OUT" "SELL ORDER PLACED (ALPACA)" "--sell + 'yes': order placed"
assert_equals "MSFT|3|sell" "$(tail -1 "$ORDER_LOG" | jq -r '"\(.symbol)|\(.qty)|\(.side)"')" \
    "--sell + 'yes': order payload MSFT 3 sell"

run_agent "yes"$'\n' --place-buy NVDA 1
assert_contains "$OUT" "BUY ORDER PLACED (ALPACA)" "--place-buy (deprecated) places a buy via the stub"
assert_equals "NVDA|1|buy" "$(tail -1 "$ORDER_LOG" | jq -r '"\(.symbol)|\(.qty)|\(.side)"')" \
    "--place-buy payload NVDA 1 buy"

run_agent "yes"$'\n' --place-sell NVDA 1
assert_contains "$OUT" "SELL ORDER PLACED (ALPACA)" "--place-sell (deprecated) places a sell via the stub"
assert_equals "NVDA|1|sell" "$(tail -1 "$ORDER_LOG" | jq -r '"\(.symbol)|\(.qty)|\(.side)"')" \
    "--place-sell payload NVDA 1 sell"

orders_before=$(count_lines "$ORDER_LOG")
run_agent "no"$'\n' --place-sell AAPL 1
assert_contains "$OUT" "Order cancelled" "--place-sell + 'no' cancels"
assert_equals "$orders_before" "$(count_lines "$ORDER_LOG")" "--place-sell + 'no': no order sent"

# --- broker rejects the order ---
run_agent "yes"$'\n' --buy REJ 1
assert_equals "1" "$RC" "--buy rejected by the broker (422) exits 1"
assert_contains "$OUT" "Failed to place buy order" "--buy rejected: failure reported"
assert_contains "$OUT" "Unprocessable Entity" "--buy rejected: broker error shown"
assert_not_contains "$OUT" "BUY ORDER PLACED" "--buy rejected: not reported as placed"

# ============================================================================
# Invalid input is rejected before the broker is contacted
# ============================================================================

echo ""
echo "--- Invalid symbol / quantity ---"

check_rejected() {
    local expect=$1
    shift
    local req_before order_before
    req_before=$(count_lines "$REQ_LOG")
    order_before=$(count_lines "$ORDER_LOG")
    run_agent "yes"$'\n' "$@"
    assert_equals "1" "$RC" "$* exits 1"
    assert_contains "$OUT" "$expect" "$* reports '$expect'"
    assert_equals "$req_before|$order_before" "$(count_lines "$REQ_LOG")|$(count_lines "$ORDER_LOG")" \
        "$*: no request reached the broker"
}

check_rejected "Invalid symbol" --buy aapl 1
check_rejected "Invalid symbol" --buy TOOLONG 1
check_rejected "Invalid symbol" --sell 'A;B' 1
check_rejected "Invalid quantity" --buy AAPL 0
check_rejected "Invalid quantity" --buy AAPL -5
check_rejected "Invalid quantity" --sell AAPL abc
check_rejected "Invalid quantity" --place-buy AAPL 1x
check_rejected "Usage: --buy SYMBOL QTY" --buy AAPL
check_rejected "Usage: --sell SYMBOL QTY" --sell

# ============================================================================
# Missing credentials fail cleanly (no hang, no request with empty keys)
# ============================================================================

echo ""
echo "--- Missing credentials ---"

req_before=$(count_lines "$REQ_LOG")
RUN_CONFIG="$NOCRED_CONFIG" run_agent "" --check-account
assert_equals "1" "$RC" "--check-account without credentials exits 1"
assert_contains "$OUT" "Missing Alpaca API credentials" "--check-account without credentials explains why"
assert_equals "$req_before" "$(count_lines "$REQ_LOG")" "--check-account without credentials sends no request"

# ============================================================================
# --ml / --kalman load their modules
# ============================================================================

echo ""
echo "--- --ml / --kalman module loading ---"

run_agent "" --ml --check-account
assert_equals "0" "$RC" "--ml --check-account exits 0"
assert_contains "$OUT" "ML predictor module loaded" "--ml loads lib/ml_predictor.sh"
assert_not_contains "$OUT" "module not found" "--ml: no 'module not found'"

run_agent "" --kalman --check-account
assert_equals "0" "$RC" "--kalman --check-account exits 0"
assert_contains "$OUT" "Kalman filter module loaded" "--kalman loads lib/kalman_filter.sh"
assert_not_contains "$OUT" "module not found" "--kalman: no 'module not found'"

# ============================================================================
# No lib/lib paths anywhere
# ============================================================================

assert_not_contains "$ALL_OUTPUT" "lib/lib" "no 'lib/lib' path in any agent output"

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "=========================================="
echo "  Test Summary"
echo "=========================================="
echo "Total Tests:  $TESTS_RUN"
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "\n${GREEN}All tests passed!${NC}"
    exit 0
fi
echo -e "\n${RED}Some tests failed.${NC}"
exit 1
