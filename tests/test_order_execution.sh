#!/bin/bash
# ============================================================================
# Tests: Alpaca order primitives (lib/alpaca_broker.sh, lib/alpaca_wrappers.sh)
# ============================================================================
# Covers the order payload builder (market / limit / bracket, price rounding,
# client_order_id), bracket orders, rejected reused client_order_id, a lost
# POST answer resolved by client_order_id lookup (never resubmitted), open
# orders / orders since / order by client id / clock / calendar, the masked
# account id, and that alpaca_wrappers.sh does not redefine broker functions.
#
# SAFETY: no real broker is contacted. Every call goes to the local stub
# (tests/stubs/alpaca_stub_server.py on 127.0.0.1) through a stub config file
# (SST_CONFIG_FILE), so config.sh and its keys are never used. HOME,
# SST_STATE_DIR and ALERT_LOG_FILE are temp paths.
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
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sst_order_test.XXXXXX")"
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
export SST_STATE_DIR="$WORK_DIR/state"
export ALERT_LOG_FILE="$WORK_DIR/alerts.log"
mkdir -p "$HOME" "$SST_STATE_DIR" "$WORK_DIR/logs"

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

# Number of ORDER_LOG lines (POST bodies) with a given client_order_id
count_posts_for() {
    jq -r --arg id "$1" 'select(.client_order_id == $id) | .client_order_id' "$ORDER_LOG" 2>/dev/null | wc -l | tr -d ' '
}

# lib_call SCRIPT : source the agent (stub config), load the Alpaca module,
# connect (unless NO_CONNECT=1), then run SCRIPT (bash code) in that shell.
# T_TIMEOUT sets ALPACA_TIMEOUT_SECONDS before the module loads.
# Sets OUT (stdout+stderr of SCRIPT only) and RC. Killed after ${T_ALARM:-30} s.
lib_call() {
    local script=$1
    OUT=$(cd "$WORK_DIR" && SST_CONFIG_FILE="$STUB_CONFIG" \
        perl -e "alarm ${T_ALARM:-30}; exec @ARGV" bash -c '
        source "$1" >/dev/null 2>&1 </dev/null
        BROKER_CHOICE=alpaca
        [[ -n "$T_TIMEOUT" ]] && export ALPACA_TIMEOUT_SECONDS="$T_TIMEOUT"
        load_broker_module >/dev/null 2>&1 || { echo "LOAD_FAILED"; exit 90; }
        if [[ "$NO_CONNECT" != "1" ]]; then
            broker_connect >/dev/null 2>&1 || { echo "CONNECT_FAILED"; exit 91; }
        fi
        eval "$2"
    ' _ "$AGENT" "$script" 2>&1)
    RC=$?
}

# ============================================================================
# Start the local Alpaca stub (with a scenario state file)
# ============================================================================

PORT_FILE="$WORK_DIR/stub.port"
REQ_LOG="$WORK_DIR/requests.log"
ORDER_LOG="$WORK_DIR/orders.log"
STATE_FILE="$WORK_DIR/stub_state.json"
: > "$REQ_LOG"
: > "$ORDER_LOG"

STUB_SLOW_SECONDS=3 python3 "$TEST_DIR/stubs/alpaca_stub_server.py" \
    "$PORT_FILE" "$REQ_LOG" "$ORDER_LOG" "$STATE_FILE" &
STUB_PID=$!
for _ in $(seq 1 100); do
    [[ -s "$PORT_FILE" ]] && break
    sleep 0.1
done
STUB_PORT=$(cat "$PORT_FILE" 2>/dev/null)
STUB_URL="http://127.0.0.1:${STUB_PORT}"

echo "=========================================="
echo "  Order Execution Test Suite"
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
export SST_STATE_DIR="$SST_STATE_DIR"
export ALERT_LOG_FILE="$ALERT_LOG_FILE"
EOF

# ============================================================================
# Payload builder (pure, no network)
# ============================================================================

echo ""
echo "--- Payload builder ---"

req_before=$(count_lines "$REQ_LOG")

NO_CONNECT=1 lib_call 'alpaca_build_order_payload AAPL 2 buy market "" "" ""'
assert_equals "0" "$RC" "market payload: builder returns 0"
assert_equals "AAPL|2|number|buy|market|day|null|null|null" \
    "$(echo "$OUT" | jq -r '"\(.symbol)|\(.qty)|\(.qty|type)|\(.side)|\(.type)|\(.time_in_force)|\(.limit_price)|\(.client_order_id)|\(.order_class)"')" \
    "market payload: AAPL 2 (number) buy market day, no limit price / client id / class"

NO_CONNECT=1 lib_call 'alpaca_build_order_payload AAPL 3 sell limit 123.45 "" sst-AAPL-s-1'
assert_equals "limit|day|123.45|string|sst-AAPL-s-1" \
    "$(echo "$OUT" | jq -r '"\(.type)|\(.time_in_force)|\(.limit_price)|\(.limit_price|type)|\(.client_order_id)"')" \
    "limit payload: limit/day, limit_price is the string 123.45, client_order_id present"

NO_CONNECT=1 lib_call 'ORDER_TIME_IN_FORCE=gtc alpaca_build_order_payload AAPL 1 buy limit 50 "" ""'
assert_equals "gtc" "$(echo "$OUT" | jq -r '.time_in_force')" "limit payload: ORDER_TIME_IN_FORCE sets the default TIF"

NO_CONNECT=1 lib_call 'alpaca_build_order_payload AAPL 2 buy limit 123.70 "" sst-AAPL-b-1 117.5 133.6'
assert_equals "bracket|gtc|limit|123.70|133.60|117.50|sst-AAPL-b-1" \
    "$(echo "$OUT" | jq -r '"\(.order_class)|\(.time_in_force)|\(.type)|\(.limit_price)|\(.take_profit.limit_price)|\(.stop_loss.stop_price)|\(.client_order_id)"')" \
    "bracket payload: order_class bracket, gtc, take_profit.limit_price, stop_loss.stop_price"

NO_CONNECT=1 lib_call 'BRACKET_TIME_IN_FORCE=day alpaca_build_order_payload AAPL 2 buy limit 123.70 "" "" 117.5 133.6'
assert_equals "day" "$(echo "$OUT" | jq -r '.time_in_force')" "bracket payload: BRACKET_TIME_IN_FORCE sets the default TIF"

NO_CONNECT=1 lib_call 'alpaca_build_order_payload AAPL 1 buy limit 123.456 "" ""'
assert_equals "123.46" "$(echo "$OUT" | jq -r '.limit_price')" "rounding: 123.456 -> '123.46' (>= \$1: 2 decimals)"

NO_CONNECT=1 lib_call 'alpaca_build_order_payload AAPL 1 buy limit 0.12345 "" ""'
assert_equals "0.1235" "$(echo "$OUT" | jq -r '.limit_price')" "rounding: 0.12345 -> '0.1235' (< \$1: 4 decimals)"

NO_CONNECT=1 lib_call 'alpaca_round_price 123.456; alpaca_round_price 0.12345; alpaca_round_price 5'
assert_equals "123.46 0.1235 5.00" "$(echo $OUT)" "alpaca_round_price 123.456 / 0.12345 / 5"

NO_CONNECT=1 lib_call 'alpaca_build_order_payload AAPL 1 buy limit "" "" ""'
assert_equals "1" "$RC" "limit without a price: returns 1"
assert_contains "$(echo "$OUT" | jq -r '.error')" "limit price" "limit without a price: {\"error\": ...limit price...}"

NO_CONNECT=1 lib_call 'alpaca_build_order_payload aapl 1 buy market "" "" ""'
assert_equals "1|invalid symbol: aapl" "$RC|$(echo "$OUT" | jq -r '.error')" "invalid symbol: error JSON, returns 1"

NO_CONNECT=1 lib_call 'alpaca_build_order_payload AAPL 0 buy market "" "" ""'
assert_equals "1|invalid quantity: 0" "$RC|$(echo "$OUT" | jq -r '.error')" "invalid quantity: error JSON, returns 1"

NO_CONNECT=1 lib_call 'alpaca_build_order_payload AAPL 1 short market "" "" ""'
assert_equals "1|invalid side: short" "$RC|$(echo "$OUT" | jq -r '.error')" "invalid side: error JSON, returns 1"

NO_CONNECT=1 lib_call 'alpaca_build_order_payload AAPL 1 buy limit 100 "" "" 95'
assert_equals "1" "$RC" "stop without take profit: returns 1"
assert_contains "$OUT" "needs both a stop price and a take profit" "stop without take profit: explained"

NO_CONNECT=1 lib_call 'alpaca_build_order_payload AAPL 1 buy limit 100 "" "" 110 95'
assert_equals "1" "$RC" "buy bracket with take profit below the stop: returns 1"

NO_CONNECT=1 lib_call "alpaca_build_order_payload AAPL 1 buy market '' '' \"x'y\""
assert_equals "1|invalid client_order_id" "$RC|$(echo "$OUT" | jq -r '.error')" "client_order_id with a quote: refused"

assert_equals "$req_before" "$(count_lines "$REQ_LOG")" "payload builder makes no request"

# ============================================================================
# Orders against the stub
# ============================================================================

echo ""
echo "--- Orders (local stub) ---"

lib_call 'alpaca_place_order AAPL 2 buy'
assert_equals "0" "$RC" "3-arg alpaca_place_order: returns 0"
assert_equals "qty,side,symbol,time_in_force,type|AAPL|2|buy|market|day" \
    "$(tail -1 "$ORDER_LOG" | jq -r '"\(keys | join(","))|\(.symbol)|\(.qty)|\(.side)|\(.type)|\(.time_in_force)"')" \
    "3-arg alpaca_place_order: payload is exactly {symbol, qty, side, type market, time_in_force day}"
assert_contains "$OUT" '"order_id": "stub-order-0001"' "3-arg alpaca_place_order: first stub order id"

lib_call 'alpaca_place_bracket_order AAPL 2 buy 123.70 117.5 133.6 sst-AAPL-b-0001'
BRACKET_OUT=$OUT
assert_equals "0" "$RC" "alpaca_place_bracket_order: returns 0"
assert_equals "bracket|limit|gtc|123.70|133.60|117.50|sst-AAPL-b-0001" \
    "$(tail -1 "$ORDER_LOG" | jq -r '"\(.order_class)|\(.type)|\(.time_in_force)|\(.limit_price)|\(.take_profit.limit_price)|\(.stop_loss.stop_price)|\(.client_order_id)"')" \
    "bracket sent: order_class bracket, limit, gtc, take_profit.limit_price, stop_loss.stop_price, client_order_id"
assert_equals "sst-AAPL-b-0001|bracket|gtc|accepted|2" \
    "$(echo "$BRACKET_OUT" | jq -r '"\(.client_order_id)|\(.order_class)|\(.time_in_force)|\(.status)|\(.legs | length)"')" \
    "bracket confirmation: client id, class, TIF, status, 2 legs"
assert_equals "limit:sell:133.6:held|stop:sell:117.5:held" \
    "$(echo "$BRACKET_OUT" | jq -r '[.legs[] | "\(.type):\(.side):\((.limit_price // .stop_price) * 1):\(.status)"] | join("|")')" \
    "bracket legs: take-profit limit sell 133.60 + stop sell 117.50, held"

lib_call 'alpaca_place_bracket_order AAPL 2 buy 123.70 117.5 133.6 sst-AAPL-b-0001'
assert_equals "1" "$RC" "reused client_order_id: returns 1"
assert_contains "$OUT" "Unprocessable Entity" "reused client_order_id: 422 reported as rejected"
assert_not_contains "$OUT" "client_order_id_lookup" "reused client_order_id: 4xx is not looked up"

lib_call 'alpaca_place_bracket_order AAPL 2 buy 123.70 117.5 "" sst-AAPL-b-0002'
assert_equals "1" "$RC" "bracket without take profit: returns 1"
assert_equals "0" "$(count_posts_for sst-AAPL-b-0002)" "bracket without take profit: nothing sent"

lib_call 'alpaca_place_order FIL 4 buy limit 20 sst-FIL-b-0001'
assert_equals "0|filled|4" "$RC|$(echo "$OUT" | jq -r '"\(.status)|\(.filled_qty)"')" "FIL order: status filled, filled_qty = qty"

lib_call 'alpaca_place_order REJ 1 buy limit 20 sst-REJ-b-0001'
assert_equals "1" "$RC" "REJ order: returns 1"
assert_contains "$OUT" "insufficient buying power" "REJ order: broker error text shown"

# Lost answer: the stub stores the order, then answers after 3 s; the client
# gives up after 1 s and must find the order by client_order_id.
posts_before=$(count_lines "$ORDER_LOG")
T_TIMEOUT=1 lib_call 'echo "timeout=$ALPACA_TIMEOUT"; alpaca_place_order TMO 1 buy limit 10 sst-TMO-b-0001'
assert_equals "0" "$RC" "timed-out POST: returns 0 (order found)"
assert_contains "$OUT" "timeout=1" "ALPACA_TIMEOUT_SECONDS sets ALPACA_TIMEOUT"
assert_equals "client_order_id_lookup|sst-TMO-b-0001|accepted" \
    "$(echo "$OUT" | sed -n '/^{/,$p' | jq -r '"\(.confirmed_by)|\(.client_order_id)|\(.status)"')" \
    "timed-out POST: confirmed_by client_order_id_lookup"
assert_equals "1" "$(count_posts_for sst-TMO-b-0001)" "timed-out POST: exactly one POST for that client id (never resubmitted)"
assert_equals "$((posts_before + 1))" "$(count_lines "$ORDER_LOG")" "timed-out POST: no other order sent"
assert_contains "$(cat "$REQ_LOG")" "GET /v2/orders:by_client_order_id?client_order_id=sst-TMO-b-0001" \
    "timed-out POST: looked up via GET /v2/orders:by_client_order_id"

T_TIMEOUT=1 lib_call 'alpaca_place_order TMO 1 buy limit 10'
assert_equals "1" "$RC" "timed-out POST without client id: returns 1"
assert_contains "$OUT" "order outcome unknown" "timed-out POST without client id: outcome unknown reported"

lib_call "alpaca_submit_order '{\"symbol\":\"AAPL\",\"qty\":1,\"side\":\"buy\",\"type\":\"market\",\"time_in_force\":\"day\",\"client_order_id\":\"a'\\''b\"}'"
assert_equals "1" "$RC" "payload with a single quote: refused"
assert_contains "$OUT" "single quote" "payload with a single quote: reason shown"

# ============================================================================
# Orders / clock / calendar / account queries
# ============================================================================

echo ""
echo "--- Queries (local stub) ---"

lib_call 'alpaca_get_open_orders'
assert_equals "0" "$RC" "alpaca_get_open_orders: returns 0"
assert_equals "true" "$(echo "$OUT" | jq -r 'type == "array" and length >= 3 and all(.[]; .status != "filled")')" \
    "alpaca_get_open_orders: array of open orders (filled FIL excluded)"
assert_equals "2" "$(echo "$OUT" | jq -r '[.[] | select(.client_order_id == "sst-AAPL-b-0001")][0].legs | length')" \
    "alpaca_get_open_orders: bracket legs nested"
assert_contains "$(cat "$REQ_LOG")" "GET /v2/orders?status=open&nested=true&limit=500" \
    "alpaca_get_open_orders: GET /v2/orders?status=open&nested=true&limit=500"

lib_call 'alpaca_get_open_orders AAPL'
assert_equals "true" "$(echo "$OUT" | jq -r 'length >= 2 and all(.[]; .symbol == "AAPL")')" \
    "alpaca_get_open_orders AAPL: only AAPL orders"
assert_contains "$(cat "$REQ_LOG")" "&symbols=AAPL" "alpaca_get_open_orders AAPL: symbols filter sent"

lib_call 'alpaca_get_orders_since 2000-01-01T00:00:00Z'
assert_equals "0" "$RC" "alpaca_get_orders_since: returns 0"
assert_equals "stub-order-0001|true" \
    "$(echo "$OUT" | jq -r '"\(.[0].id)|\(any(.[]; .status == "filled"))"')" \
    "alpaca_get_orders_since: oldest first, all statuses (includes filled)"
assert_contains "$(cat "$REQ_LOG")" "status=all&after=2000-01-01T00:00:00Z&nested=true&direction=asc&limit=500" \
    "alpaca_get_orders_since: status=all, after, nested, asc, limit 500"

lib_call 'alpaca_get_orders_since 2100-01-01T00:00:00Z'
assert_equals "0" "$(echo "$OUT" | jq -r 'length')" "alpaca_get_orders_since future: empty array"

lib_call 'alpaca_get_orders_since "yesterday; rm"'
assert_equals "1" "$RC" "alpaca_get_orders_since bad timestamp: returns 1"

lib_call 'alpaca_get_order_by_client_id sst-AAPL-b-0001'
assert_equals "0|stub-order-0002" "$RC|$(echo "$OUT" | jq -r '.id')" "alpaca_get_order_by_client_id: finds the bracket order"

lib_call 'alpaca_get_order_by_client_id sst-none-0000'
assert_equals "1" "$RC" "alpaca_get_order_by_client_id unknown id: returns 1"

lib_call 'alpaca_get_clock'
assert_equals "0|true" "$RC|$(echo "$OUT" | jq -r '.is_open')" "alpaca_get_clock: is_open true (stub default)"
assert_equals "true" "$(echo "$OUT" | jq -r 'has("timestamp") and has("next_open") and has("next_close")')" \
    "alpaca_get_clock: timestamp, next_open, next_close"

lib_call 'alpaca_get_calendar 2000-01-01 2100-12-31'
assert_equals "0|1|09:30|16:00" "$RC|$(echo "$OUT" | jq -r '"\(length)|\(.[0].open)|\(.[0].close)"')" \
    "alpaca_get_calendar: today 09:30-16:00 (stub default)"

lib_call 'alpaca_get_calendar today tomorrow'
assert_equals "1" "$RC" "alpaca_get_calendar bad dates: returns 1"

# Stub scenario file: closed market, holiday calendar
cat > "$STATE_FILE" <<'EOF'
{"clock": {"is_open": false, "timestamp": "2026-12-25T10:00:00-05:00",
           "next_open": "2026-12-28T09:30:00-05:00", "next_close": "2026-12-28T16:00:00-05:00"},
 "calendar": []}
EOF
lib_call 'alpaca_get_clock; alpaca_get_calendar 2026-12-25 2026-12-25'
assert_equals "false|2026-12-28T09:30:00-05:00|0" \
    "$(echo "$OUT" | jq -rs '"\(.[0].is_open)|\(.[0].next_open)|\(.[1] | length)"')" \
    "stub STATE_FILE: closed clock and empty (holiday) calendar"
rm -f "$STATE_FILE"

lib_call 'alpaca_get_account'
assert_equals "0" "$RC" "alpaca_get_account: returns 0"
assert_not_contains "$OUT" "stub-account-id-0000" "alpaca_get_account: full account id not printed"
assert_contains "$OUT" '"****0000"' "alpaca_get_account: account id masked to ****0000"
assert_equals "2503.75|false|0" \
    "$(echo "$OUT" | jq -r '"\(.last_equity)|\(.pattern_day_trader)|\(.daytrade_count)"')" \
    "alpaca_get_account: last_equity, pattern_day_trader, daytrade_count"
assert_not_contains "$OUT" "stub-key-id" "alpaca_get_account: API key not printed"

NO_CONNECT=1 lib_call 'alpaca_get_clock'
assert_equals "1" "$RC" "alpaca_get_clock before init: returns 1"
assert_contains "$OUT" "not initialized" "alpaca_get_clock before init: explained"

# ============================================================================
# alpaca_wrappers.sh does not shadow broker functions
# ============================================================================

echo ""
echo "--- alpaca_wrappers.sh ---"

T_ALARM=10 lib_call '
    funcs=$(sed -n "s/^\([a-z_][a-z0-9_]*\)() *{.*/\1/p" "$AGENT_DIR/lib/alpaca_broker.sh")
    before=$(for f in $funcs; do declare -f "$f"; done | cksum)
    source "$AGENT_DIR/lib/alpaca_wrappers.sh"
    after=$(for f in $funcs; do declare -f "$f"; done | cksum)
    [[ "$before" == "$after" ]] && echo "DEFS_SAME" || echo "DEFS_CHANGED"
    for f in $(sed -n "s/^\([a-z_][a-z0-9_]*\)() *{.*/\1/p" "$AGENT_DIR/lib/alpaca_wrappers.sh"); do
        case " $(echo $funcs) " in *" $f "*) echo "SHADOWED:$f" ;; esac
    done
    echo "init=$ALPACA_INITIALIZED"
    echo "count=$(alpaca_get_positions | jq length)"
    echo "price=$(alpaca_get_current_price AAPL)"
'
assert_equals "0" "$RC" "wrappers block finishes under perl alarm 10 (no recursion)"
assert_contains "$OUT" "DEFS_SAME" "sourcing alpaca_wrappers.sh keeps every alpaca_broker.sh definition"
assert_not_contains "$OUT" "SHADOWED:" "alpaca_wrappers.sh defines no function named like a broker function"
assert_contains "$OUT" "init=true" "sourcing alpaca_wrappers.sh keeps the initialized connection"
assert_contains "$OUT" "count=3" "alpaca_get_positions after the wrappers: 3-element array"
assert_contains "$OUT" "price=123.45" "alpaca_get_current_price reads .last_price"

lib_call 'source "$AGENT_DIR/lib/alpaca_wrappers.sh"; alpaca_place_stop_loss AAPL 2 97.5'
assert_equals "0" "$RC" "alpaca_place_stop_loss: returns 0"
assert_contains "$OUT" "stub-order-" "alpaca_place_stop_loss: prints the order id"
assert_equals "AAPL|2|sell|stop|97.50|gtc" \
    "$(tail -1 "$ORDER_LOG" | jq -r '"\(.symbol)|\(.qty)|\(.side)|\(.type)|\(.stop_price)|\(.time_in_force)"')" \
    "alpaca_place_stop_loss: sell stop 97.50 gtc"

lib_call 'source "$AGENT_DIR/lib/alpaca_wrappers.sh"; alpaca_place_take_profit AAPL 2 140'
assert_equals "0" "$RC" "alpaca_place_take_profit: returns 0"
assert_equals "AAPL|2|sell|limit|140.00|gtc" \
    "$(tail -1 "$ORDER_LOG" | jq -r '"\(.symbol)|\(.qty)|\(.side)|\(.type)|\(.limit_price)|\(.time_in_force)"')" \
    "alpaca_place_take_profit: sell limit 140.00 gtc"

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
