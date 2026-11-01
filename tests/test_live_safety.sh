#!/bin/bash
# ============================================================================
# Tests: live safety (Step 1) - lib/order_safety.sh, lib/alerts.sh and the
# agent's guarded --buy/--sell flow
# ============================================================================
# Covers: default limit + bracket payload with an sst- client order id; caps
# (MAX_ORDER_QTY, MAX_ORDER_NOTIONAL, MAX_DAILY_NOTIONAL, MAX_OPEN_POSITIONS,
# daily loss halt, no short); kill switch file, --halt / --resume; duplicate
# guard (ledger and broker open orders); reconciliation (block, override,
# --reconcile exit codes, --reconcile-accept, fills, unknown open orders);
# market hours (refuse, holiday wording, queue); PDT warning; paper/live guard
# (--live + typed confirmation, tracked config refused); alerts to the log,
# a Slack webhook stub and a sendmail stub; --safety-status and --help.
#
# SAFETY: no real broker is contacted. Every scenario starts its own Alpaca
# stub (tests/stubs/alpaca_stub_server.py, 127.0.0.1 only) with a STATE_FILE
# and points the agent at it with a stub config (SST_CONFIG_FILE). HOME,
# SST_STATE_DIR and ALERT_LOG_FILE are temp paths, so the repo's .state/ and
# kill switch are never touched. The real config.sh is only sourced in a
# subshell to check that its URL is the paper endpoint (nothing is printed).
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
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sst_live_safety.XXXXXX")"
STUB_PID=""

cleanup() {
    stop_stub
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

export SST_OFFLINE=1
export HOME="$WORK_DIR/home"
mkdir -p "$HOME"
# Never inherit safety settings from the caller's environment
unset SST_LOOPBACK_IS_LIVE ORDER_LIVE_FLAG KILL_SWITCH_FILE ALERTS_SLACK_ENABLED ALERTS_EMAIL_ENABLED \
    ALERT_SLACK_WEBHOOK_URL MAX_ORDER_QTY MAX_ORDER_NOTIONAL MAX_DAILY_NOTIONAL MAX_OPEN_POSITIONS \
    DAILY_LOSS_LIMIT_PCT OUTSIDE_HOURS_POLICY RECONCILE_ON_STARTUP

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
        echo "$haystack" | tail -10 | sed 's/^/    | /'
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

assert_true() {
    local name=$1
    shift
    if "$@"; then
        pass "$name"
    else
        fail "$name" "condition false: $*"
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

# Number of alert lines with EVENT in the scenario's alert log
alert_count() {
    if [[ -f "$ALERTS" ]]; then
        jq -r --arg e "$1" 'select(.event == $e) | .event' "$ALERTS" 2>/dev/null | wc -l | tr -d ' '
    else
        echo 0
    fi
}

# Number of POST /v2/orders requests the stub received
post_count() {
    grep -c '^POST /v2/orders' "$REQ_LOG" 2>/dev/null || true
}

# ============================================================================
# Scenario setup: one stub + state dir + alert log per scenario
# ============================================================================

stop_stub() {
    if [[ -n "$STUB_PID" ]]; then
        kill "$STUB_PID" 2>/dev/null
        wait "$STUB_PID" 2>/dev/null
        STUB_PID=""
    fi
}

# new_scenario NAME [STATE_JSON]: fresh stub, state dir, logs and config
new_scenario() {
    local name=$1 state=${2:-'{}'}
    stop_stub
    SC_DIR="$WORK_DIR/$name"
    mkdir -p "$SC_DIR"
    STATE_FILE="$SC_DIR/stub_state.json"
    REQ_LOG="$SC_DIR/requests.log"
    ORDER_LOG="$SC_DIR/orders.log"
    ALERTS="$SC_DIR/alerts.log"
    SC_STATE_DIR="$SC_DIR/state"
    LEDGER="$SC_STATE_DIR/orders.jsonl"
    echo "$state" > "$STATE_FILE"
    : > "$REQ_LOG"
    : > "$ORDER_LOG"
    python3 "$TEST_DIR/stubs/alpaca_stub_server.py" "$SC_DIR/port" "$REQ_LOG" "$ORDER_LOG" "$STATE_FILE" &
    STUB_PID=$!
    for _ in $(seq 1 100); do
        [[ -s "$SC_DIR/port" ]] && break
        sleep 0.1
    done
    STUB_URL="http://127.0.0.1:$(cat "$SC_DIR/port" 2>/dev/null)"
    STUB_CONFIG="$SC_DIR/config.stub.sh"
    cat > "$STUB_CONFIG" <<EOF
export ALPACA_API_KEY="stub-key-id"
export ALPACA_SECRET_KEY="stub-secret"
export ALPACA_OAUTH_TOKEN=""
export ALPACA_BASE_URL="$STUB_URL"
export ALPACA_DATA_URL="$STUB_URL"
export ROBINHOOD_API_BASE_URL="http://127.0.0.1:9"
export ROBINHOOD_OAUTH_BASE_URL="http://127.0.0.1:9"
export SST_STATE_DIR="$SC_STATE_DIR"
export ALERT_LOG_FILE="$ALERTS"
EOF
    echo ""
    echo "--- $name (stub $STUB_URL) ---"
}

set_state() {
    echo "$1" > "$STATE_FILE"
}

# run_agent STDIN ARGS... : run the agent in the scenario dir against the
# stub config. Sets OUT (stdout+stderr) and RC. Killed after 90 s.
run_agent() {
    local input=$1
    shift
    OUT=$(cd "$SC_DIR" && printf '%s' "$input" | \
        SST_CONFIG_FILE="${RUN_CONFIG:-$STUB_CONFIG}" \
        perl -e 'alarm 90; exec @ARGV' bash "$AGENT" "$@" 2>&1)
    RC=$?
}

accept_baseline() {
    run_agent "" --reconcile-accept
    assert_equals "0" "$RC" "$1: --reconcile-accept exits 0"
}

# Raw Alpaca position for STATE_FILE
pos() {
    jq -cn --arg s "$1" --arg q "$2" '{symbol:$s, qty:$q, avg_entry_price:"100.00", current_price:"123.45",
        market_value:"0", unrealized_pl:"0", unrealized_plpc:"0"}'
}

DEFAULT_POSITIONS="[$(pos AAPL 10),$(pos MSFT 5),$(pos NVDA 2)]"

echo "=========================================="
echo "  Live Safety Test Suite"
echo "=========================================="

# ============================================================================
# Library: endpoint mode, pure helpers
# ============================================================================

echo ""
echo "--- order_safety.sh helpers ---"

modes=$(cd "$WORK_DIR" && bash -c '
    source "$1/lib/order_safety.sh" >/dev/null 2>&1 </dev/null
    echo "$(broker_endpoint_mode alpaca https://paper-api.alpaca.markets)|$(broker_endpoint_mode alpaca https://api.alpaca.markets)|$(broker_endpoint_mode alpaca http://127.0.0.1:5000)|$(broker_endpoint_mode alpaca http://localhost:1)|$(broker_endpoint_mode robinhood "")|$(SST_LOOPBACK_IS_LIVE=1 broker_endpoint_mode alpaca http://127.0.0.1:5000)|$(broker_endpoint_mode alpaca https://paper-api.alpaca.markets.evil.example)"
' _ "$PROJECT_DIR")
assert_equals "paper|live|local|local|live|live|live" "$modes" \
    "broker_endpoint_mode: paper, live, loopback local, robinhood live, SST_LOOPBACK_IS_LIVE=1 live, look-alike host live"

helpers=$(cd "$WORK_DIR" && SST_STATE_DIR="$WORK_DIR/helpers_state" ALERT_LOG_FILE="$WORK_DIR/helpers_alerts.log" bash -c '
    source "$1/lib/scoring.sh" >/dev/null 2>&1 </dev/null
    source "$1/lib/order_safety.sh" >/dev/null 2>&1 </dev/null
    cid=$(generate_client_order_id AAPL buy)
    [[ "$cid" =~ ^sst-AAPL-b-[0-9]{14}-[0-9a-f]{4}$ ]] && c=ok || c="bad:$cid"
    echo "$c|$(compute_limit_price buy 123.45)|$(compute_limit_price sell 123.45)|$(order_bracket_levels_from buy 100 | jq -r "\"\(.stop_price) \(.take_profit_price) \(.method)\"")|$(order_bracket_levels_from buy 100 2 sideways 50 | jq -r "\"\(.stop_price) \(.method)\"")|$(ORDER_MAX_STOP_PCT=15 order_bracket_levels_from buy 100 20 | jq -r "if .stop_pct == 15 then \"clamped15\" else .stop_pct end")"
' _ "$PROJECT_DIR")
assert_equals "ok|123.70|123.20|95.00 108.00 percent|96.00 atr+regime|clamped15" "$helpers" \
    "client order id format, limit price +/-0.2%, percent / ATR+regime bracket levels, stop pct clamp"

recon=$(cd "$WORK_DIR" && bash -c '
    source "$1/lib/order_safety.sh" >/dev/null 2>&1 </dev/null
    base="{\"taken_at\":\"2026-01-01T00:00:00Z\",\"positions\":{\"AAPL\":10}}"
    p1="[{\"symbol\":\"AAPL\",\"quantity\":12}]"
    o1="[{\"id\":\"1\",\"client_order_id\":\"sst-AAPL-b-1\",\"symbol\":\"AAPL\",\"side\":\"buy\",\"qty\":\"2\",\"filled_qty\":\"2\",\"status\":\"filled\",\"legs\":null}]"
    o2="[{\"id\":\"2\",\"client_order_id\":\"manual\",\"symbol\":\"AMD\",\"side\":\"buy\",\"qty\":\"1\",\"filled_qty\":\"0\",\"status\":\"accepted\"}]"
    a=$(reconcile_compute "$p1" "$o1" "$base" | jq -r .status)
    b=$(reconcile_compute "$p1" "[]" "$base" | jq -r ".status + \":\" + (.mismatches[0].broker_qty|tostring) + \"/\" + (.mismatches[0].expected_qty|tostring)")
    c=$(reconcile_compute "[{\"symbol\":\"AAPL\",\"quantity\":10}]" "$o2" "$base" | jq -r ".status + \":\" + .unknown_open_orders[0].symbol")
    d=$(reconcile_compute "[]" "[]" "" | jq -r ".status + \":\" + (.auto_create|tostring)")
    e=$(reconcile_compute "$p1" "[]" "" | jq -r .status)
    echo "$a|$b|$c|$d|$e"
' _ "$PROJECT_DIR")
assert_equals "ok|mismatch:12/10|mismatch:AMD|ok:true|no_baseline" "$recon" \
    "reconcile_compute: agent fill counted, external change, unknown open order, empty account, no baseline"

# ============================================================================
# Default order: limit + bracket gtc + client order id; duplicate guard
# ============================================================================

new_scenario default_and_duplicates
accept_baseline "default"

run_agent "yes"$'\n' --buy AAPL 2
assert_equals "0" "$RC" "default --buy AAPL 2 + 'yes' exits 0"
assert_contains "$OUT" "BUY ORDER PLACED (ALPACA)" "default buy placed"
assert_contains "$OUT" "Mode: LOCAL STUB" "mode printed once (LOCAL STUB)"
assert_contains "$OUT" "Order Type:      limit (bracket)" "confirmation shows limit (bracket)"
assert_contains "$OUT" 'Limit Price:     $123.70' "confirmation shows the limit price"
assert_contains "$OUT" "Time in Force:   gtc" "confirmation shows gtc"
assert_contains "$OUT" "Client Order ID: sst-AAPL-b-" "confirmation shows the client order id"
payload=$(tail -1 "$ORDER_LOG")
assert_equals "limit|bracket|gtc|123.70" "$(echo "$payload" | jq -r '"\(.type)|\(.order_class)|\(.time_in_force)|\(.limit_price)"')" \
    "default payload: limit, order_class bracket, gtc, limit 123.70"
assert_true "default payload: client_order_id starts with sst-" \
    bash -c '[[ "$1" =~ ^sst-AAPL-b- ]]' _ "$(echo "$payload" | jq -r .client_order_id)"
assert_equals "true" "$(echo "$payload" | jq -r '(.stop_loss.stop_price|tonumber) < (.limit_price|tonumber) and (.take_profit.limit_price|tonumber) > (.limit_price|tonumber)')" \
    "default payload: stop_loss.stop_price < limit < take_profit.limit_price"
assert_equals "117.52|133.60" "$(echo "$payload" | jq -r '"\(.stop_loss.stop_price)|\(.take_profit.limit_price)"')" \
    "bracket levels: STOP_LOSS_PERCENT 5 / TARGET_PROFIT_PERCENT 8 from the limit price (offline = percent method)"
assert_equals "accepted|$(echo "$payload" | jq -r .client_order_id)" "$(tail -1 "$LEDGER" | jq -r '"\(.status)|\(.client_order_id)"')" \
    "ledger: order recorded as accepted with the same client order id"
assert_equals "1" "$(alert_count order_placed)" "alert log: order_placed"

posts=$(post_count)
run_agent "yes"$'\n' --buy AAPL 1
assert_equals "1" "$RC" "duplicate buy AAPL exits 1"
assert_contains "$OUT" "duplicate buy AAPL" "duplicate buy AAPL refused"
assert_equals "$posts" "$(post_count)" "duplicate buy: no POST"
assert_equals "1" "$(alert_count duplicate_blocked)" "alert log: duplicate_blocked"

run_agent "yes"$'\n' --sell AAPL 1
assert_equals "0" "$RC" "opposite side (sell AAPL) allowed"
assert_contains "$OUT" "SELL ORDER PLACED (ALPACA)" "opposite side sell placed"
assert_contains "$OUT" "Open bracket legs" "sell warns that open bracket legs hold the shares"
assert_equals "limit|day|123.20" "$(tail -1 "$ORDER_LOG" | jq -r '"\(.type)|\(.time_in_force)|\(.limit_price)"')" \
    "sell payload: plain limit, day, ref - 0.2%"

pre_order=$(jq -cn '{id:"pre-0001", client_order_id:"sst-MSFT-s-20260101000000-abcd", symbol:"MSFT", side:"sell",
    qty:"1", filled_qty:"0", status:"accepted", type:"limit", order_class:"", created_at:"2026-01-01T00:00:00Z", legs:null}')
new_scenario broker_open_order_duplicate "{\"orders\":[$pre_order]}"
accept_baseline "broker duplicate"
run_agent "yes"$'\n' --sell MSFT 1
assert_equals "1" "$RC" "open broker sell order MSFT: second sell exits 1"
assert_contains "$OUT" "broker already has an open sell order" "duplicate of a broker open order refused"
assert_equals "0" "$(post_count)" "broker open order duplicate: no POST"

# ============================================================================
# Caps
# ============================================================================

new_scenario caps
accept_baseline "caps"

reqs=$(count_lines "$REQ_LOG")
MAX_ORDER_QTY=5 run_agent "yes"$'\n' --buy AAPL 6
assert_equals "1" "$RC" "MAX_ORDER_QTY=5: buy 6 exits 1"
assert_contains "$OUT" "MAX_ORDER_QTY" "MAX_ORDER_QTY reason shown"
assert_equals "$reqs" "$(count_lines "$REQ_LOG")" "MAX_ORDER_QTY: refused before any broker request"
assert_equals "1" "$(alert_count cap_hit)" "MAX_ORDER_QTY: cap_hit alert"

MAX_ORDER_QTY=5 run_agent "yes"$'\n' --sell AAPL 6
assert_equals "1" "$RC" "MAX_ORDER_QTY applies to sells too"

MAX_ORDER_NOTIONAL=200 run_agent "yes"$'\n' --buy AAPL 2
assert_equals "1" "$RC" "MAX_ORDER_NOTIONAL=200: buy 2 x 123.70 exits 1"
assert_contains "$OUT" "MAX_ORDER_NOTIONAL" "MAX_ORDER_NOTIONAL reason shown"
assert_equals "0" "$(post_count)" "MAX_ORDER_NOTIONAL: no POST"
assert_equals "3" "$(alert_count cap_hit)" "MAX_ORDER_NOTIONAL: cap_hit alert"

MAX_DAILY_NOTIONAL=400 run_agent "yes"$'\n' --buy AAPL 1
assert_equals "0" "$RC" "MAX_DAILY_NOTIONAL=400: first buy (123.70) placed"
MAX_DAILY_NOTIONAL=400 run_agent "yes"$'\n' --buy MSFT 1
assert_equals "0" "$RC" "MAX_DAILY_NOTIONAL=400: second buy (247.40 total) placed"
posts=$(post_count)
MAX_DAILY_NOTIONAL=400 run_agent "yes"$'\n' --buy NVDA 2
assert_equals "1" "$RC" "MAX_DAILY_NOTIONAL=400: third buy (494.80 total) exits 1"
assert_contains "$OUT" "MAX_DAILY_NOTIONAL" "MAX_DAILY_NOTIONAL reason shown"
assert_equals "$posts" "$(post_count)" "MAX_DAILY_NOTIONAL: no POST for the third buy"
assert_equals "4" "$(alert_count cap_hit)" "MAX_DAILY_NOTIONAL: cap_hit alert"

posts=$(post_count)
run_agent "yes"$'\n' --sell NVDA 3
assert_equals "1" "$RC" "sell 3 NVDA with 2 held exits 1 (no short)"
assert_contains "$OUT" "short selling is not allowed" "no-short reason shown"
assert_equals "$posts" "$(post_count)" "sell above position: no POST"

new_scenario open_positions "{\"positions\":[$(pos AAPL 1),$(pos MSFT 1),$(pos NVDA 1),$(pos AMD 1),$(pos INTC 1)]}"
accept_baseline "open positions"
run_agent "yes"$'\n' --buy TSLA 1
assert_equals "1" "$RC" "MAX_OPEN_POSITIONS=5 with 5 held: new symbol exits 1"
assert_contains "$OUT" "MAX_OPEN_POSITIONS" "MAX_OPEN_POSITIONS reason shown"
assert_equals "0" "$(post_count)" "MAX_OPEN_POSITIONS: no POST"
assert_equals "1" "$(alert_count cap_hit)" "MAX_OPEN_POSITIONS: cap_hit alert"
run_agent "yes"$'\n' --buy AMD 1
assert_equals "0" "$RC" "MAX_OPEN_POSITIONS: adding to a held symbol is allowed"

new_scenario daily_loss '{"account":{"last_equity":"3000.00"}}'
accept_baseline "daily loss"
run_agent "yes"$'\n' --buy AAPL 1
assert_equals "1" "$RC" "daily loss (equity 2503.75 vs last_equity 3000): buy exits 1"
assert_contains "$OUT" "DAILY LOSS HALT" "daily loss halt reason shown"
assert_equals "0" "$(post_count)" "daily loss halt: no POST"
assert_equals "1" "$(alert_count halt)" "daily loss halt: halt alert"
run_agent "yes"$'\n' --sell AAPL 1
assert_equals "0" "$RC" "daily loss halt: sells (exits) still allowed"
assert_equals "1" "$(post_count)" "daily loss halt: the sell was sent"

# ============================================================================
# Kill switch, --halt, --resume
# ============================================================================

new_scenario kill_switch
accept_baseline "kill switch"
mkdir -p "$SC_STATE_DIR"
echo '{"ts":"2026-01-01T00:00:00Z","reason":"file test","by":"test"}' > "$SC_STATE_DIR/KILL_SWITCH"
reqs=$(count_lines "$REQ_LOG")
run_agent "yes"$'\n' --buy AAPL 1
assert_equals "1" "$RC" "KILL_SWITCH file: buy exits 1"
assert_contains "$OUT" "KILL SWITCH ACTIVE" "KILL_SWITCH file: reason shown"
assert_equals "$reqs" "$(count_lines "$REQ_LOG")" "KILL_SWITCH file: zero requests to the stub"
rm -f "$SC_STATE_DIR/KILL_SWITCH"

run_agent "" --halt "test halt"
assert_equals "0" "$RC" "--halt exits 0"
assert_contains "$OUT" "KILL SWITCH ENGAGED: test halt" "--halt reports the reason"
assert_true "--halt writes the kill switch file" test -f "$SC_STATE_DIR/KILL_SWITCH"
assert_equals "$reqs" "$(count_lines "$REQ_LOG")" "--halt makes no broker request"
assert_true "halt alert logged with the reason" bash -c 'jq -e "select(.event == \"halt\" and (.message | contains(\"test halt\")))" "$1" >/dev/null' _ "$ALERTS"
run_agent "" --safety-status
assert_contains "$OUT" "Kill switch:        ACTIVE" "--safety-status shows the active kill switch"
run_agent "yes"$'\n' --sell AAPL 1
assert_equals "1" "$RC" "--halt: sell exits 1"
assert_equals "$reqs" "$(count_lines "$REQ_LOG")" "--halt: blocked order makes no request"
run_agent "" --resume
assert_equals "0" "$RC" "--resume exits 0"
assert_contains "$OUT" "Kill switch released" "--resume releases the switch"
assert_equals "1" "$(alert_count resume)" "resume alert logged"
run_agent "yes"$'\n' --buy AAPL 1
assert_equals "0" "$RC" "after --resume: buy placed"
assert_equals "1" "$(post_count)" "after --resume: one POST"

# ============================================================================
# Reconciliation
# ============================================================================

new_scenario reconciliation "{\"positions\":$DEFAULT_POSITIONS}"
accept_baseline "reconciliation"
set_state "{\"positions\":[$(pos AAPL 15),$(pos MSFT 5),$(pos NVDA 2)]}"
run_agent "yes"$'\n' --buy MSFT 1
assert_equals "1" "$RC" "external position change: order exits 1"
assert_contains "$OUT" "MISMATCH" "reconciliation mismatch reported"
assert_contains "$OUT" "AAPL: broker 15, expected 10" "mismatch detail shown"
assert_equals "0" "$(post_count)" "reconciliation mismatch: no POST"
assert_equals "1" "$(alert_count reconcile_mismatch)" "reconcile_mismatch alert"

run_agent "yes"$'\n' --buy MSFT 1 --allow-mismatch
assert_equals "0" "$RC" "--allow-mismatch: order placed"
assert_contains "$OUT" "allow-mismatch" "--allow-mismatch prints a warning"
assert_equals "1" "$(post_count)" "--allow-mismatch: one POST"

run_agent "" --reconcile
assert_equals "3" "$RC" "--reconcile with a mismatch exits 3"
run_agent "" --reconcile-accept
assert_equals "0" "$RC" "--reconcile-accept exits 0"
run_agent "" --reconcile
assert_equals "0" "$RC" "--reconcile after accept exits 0"
assert_contains "$OUT" "RECONCILIATION (alpaca): OK" "--reconcile reports OK"

run_agent "yes"$'\n' --buy FIL 1 --order-type market --no-bracket
assert_equals "0" "$RC" "FIL buy (stub fills it) placed"
fil_cid=$(tail -1 "$ORDER_LOG" | jq -r .client_order_id)
assert_equals "filled" "$(jq -r --arg c "$fil_cid" 'select(.client_order_id == $c) | .status' "$LEDGER")" \
    "FIL fill: ledger order marked filled"
assert_equals "1" "$(alert_count order_filled)" "FIL fill: order_filled alert"
set_state "{\"positions\":[$(pos AAPL 15),$(pos MSFT 5),$(pos NVDA 2),$(pos FIL 1)]}"
# Ledger entry back to accepted: --reconcile must mark it filled from the broker
jq -c --arg c "$fil_cid" 'if .client_order_id == $c then .status = "accepted" else . end' "$LEDGER" > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
run_agent "" --reconcile
assert_equals "0" "$RC" "agent fill counted: --reconcile still exits 0"
assert_equals "filled" "$(jq -r --arg c "$fil_cid" 'select(.client_order_id == $c) | .status' "$LEDGER")" \
    "--reconcile marks the filled agent order filled in the ledger"
assert_equals "2" "$(alert_count order_filled)" "--reconcile: order_filled alert"

ext_order=$(jq -cn --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{id:"ext-0001", client_order_id:"manual-order-1", symbol:"AMD",
    side:"buy", qty:"1", filled_qty:"0", status:"accepted", type:"limit", order_class:"", created_at:$t, legs:null}')
set_state "{\"positions\":[$(pos AAPL 15),$(pos MSFT 5),$(pos NVDA 2),$(pos FIL 1)],\"orders\":[$ext_order]}"
run_agent "" --reconcile
assert_equals "3" "$RC" "unknown open order: --reconcile exits 3"
assert_contains "$OUT" "unknown open order" "unknown open order reported"

new_scenario no_baseline
run_agent "yes"$'\n' --buy AAPL 1
assert_equals "1" "$RC" "no baseline and broker positions: order exits 1"
assert_contains "$OUT" "NO BASELINE" "no baseline reported"
run_agent "" --check-account
assert_equals "0" "$RC" "no baseline: --check-account still exits 0 (warning only)"
assert_contains "$OUT" "ALPACA ACCOUNT STATUS" "no baseline: --check-account still shows the account"
assert_contains "$OUT" "warning only" "no baseline: --check-account prints a reconciliation warning"

new_scenario empty_account '{"positions":[]}'
run_agent "" --reconcile
assert_equals "0" "$RC" "empty account without baseline: --reconcile exits 0"
assert_true "empty account: baseline auto-created" test -f "$SC_STATE_DIR/positions_baseline.json"

# ============================================================================
# Market hours
# ============================================================================

closed_clock='{"is_open":false,"timestamp":"2026-10-31T20:00:00-04:00","next_open":"2026-11-02T09:30:00-05:00","next_close":"2026-11-02T16:00:00-05:00"}'
new_scenario market_hours "{\"clock\":$closed_clock}"
accept_baseline "market hours"
run_agent "yes"$'\n' --buy AAPL 1
assert_equals "1" "$RC" "market closed: buy exits 1"
assert_contains "$OUT" "market is closed" "market closed reason shown"
assert_contains "$OUT" "2026-11-02T09:30:00-05:00" "next open shown"
assert_equals "0" "$(post_count)" "market closed: no POST"
assert_equals "1" "$(alert_count outside_hours)" "outside_hours alert"

set_state "{\"clock\":$closed_clock,\"calendar\":[]}"
run_agent "yes"$'\n' --buy AAPL 1
assert_equals "1" "$RC" "holiday: buy exits 1"
assert_contains "$OUT" "holiday" "holiday wording when the calendar has no session today"

OUTSIDE_HOURS_POLICY=queue run_agent "yes"$'\n' --buy AAPL 1
assert_equals "0" "$RC" "OUTSIDE_HOURS_POLICY=queue: order placed"
assert_contains "$OUT" "Alpaca will hold the order until the next open" "queue notice shown"
assert_equals "1" "$(post_count)" "queue: one POST"

# ============================================================================
# PDT warning
# ============================================================================

new_scenario pdt
accept_baseline "pdt"
run_agent "yes"$'\n' --buy AAPL 1 --no-bracket
assert_equals "0" "$RC" "pdt: buy placed"
run_agent "yes"$'\n' --sell AAPL 1
assert_equals "0" "$RC" "pdt: sell after a buy today placed (warning only)"
assert_contains "$OUT" "PDT WARNING" "PDT warning printed (equity 2503.75 < 25000)"
assert_contains "$OUT" "selling AAPL on the day it was bought" "PDT warning names the day trade"
assert_true "pdt_warning alert logged" bash -c '[[ $(jq -r "select(.event == \"pdt_warning\") | .event" "$1" | wc -l) -ge 1 ]]' _ "$ALERTS"

# ============================================================================
# Paper / live guard
# ============================================================================

new_scenario live_guard
SST_LOOPBACK_IS_LIVE=1 accept_baseline "live guard"
reqs=$(count_lines "$REQ_LOG")
SST_LOOPBACK_IS_LIVE=1 run_agent "yes"$'\n' --buy AAPL 1
assert_equals "1" "$RC" "LIVE endpoint without --live: exits 1"
assert_contains "$OUT" "orders need --live" "LIVE without --live: reason shown"
assert_contains "$OUT" "Mode: LIVE" "LIVE mode printed"
assert_equals "$reqs" "$(count_lines "$REQ_LOG")" "LIVE without --live: no request to the broker"

SST_LOOPBACK_IS_LIVE=1 run_agent "yes"$'\n' --buy AAPL 1 --live
assert_equals "0" "$RC" "LIVE --live + 'yes': exits 0"
assert_contains "$OUT" "Type the symbol and quantity to confirm (e.g. AAPL 1):" "LIVE asks for a typed confirmation"
assert_contains "$OUT" "Order cancelled" "LIVE --live + 'yes' (not 'AAPL 1'): cancelled"
assert_equals "0" "$(post_count)" "LIVE --live + 'yes': no POST"

SST_LOOPBACK_IS_LIVE=1 run_agent "AAPL 1"$'\n' --buy AAPL 1 --live
assert_equals "0" "$RC" "LIVE --live + 'AAPL 1': exits 0"
assert_contains "$OUT" "BUY ORDER PLACED (ALPACA)" "LIVE --live + typed confirmation: placed"
assert_contains "$OUT" "Mode:            LIVE" "confirmation screen shows Mode LIVE"
assert_equals "1" "$(post_count)" "LIVE --live + typed confirmation: one POST"

# Tracked config + live endpoint: refused for every broker command
GIT_CFG_DIR="$SC_DIR/tracked_repo"
mkdir -p "$GIT_CFG_DIR"
cp "$STUB_CONFIG" "$GIT_CFG_DIR/config.sh"
git -C "$GIT_CFG_DIR" init -q >/dev/null 2>&1
git -C "$GIT_CFG_DIR" add config.sh >/dev/null 2>&1
git -C "$GIT_CFG_DIR" -c user.name=sst-test -c user.email=sst-test@example.invalid -c commit.gpgsign=false \
    commit -q -m "tracked stub config" >/dev/null 2>&1
assert_true "tracked config fixture is tracked in its temp git repo" \
    bash -c 'git -C "$1" ls-files --error-unmatch config.sh >/dev/null 2>&1' _ "$GIT_CFG_DIR"
reqs=$(count_lines "$REQ_LOG")
SST_LOOPBACK_IS_LIVE=1 RUN_CONFIG="$GIT_CFG_DIR/config.sh" run_agent "AAPL 1"$'\n' --buy AAPL 1 --live
assert_equals "1" "$RC" "LIVE + git-tracked config: --buy --live exits 1"
assert_contains "$OUT" "tracked in git and must stay on paper" "LIVE + tracked config: reason shown"
SST_LOOPBACK_IS_LIVE=1 RUN_CONFIG="$GIT_CFG_DIR/config.sh" run_agent "" --check-account
assert_equals "1" "$RC" "LIVE + git-tracked config: --check-account exits 1"
assert_equals "$reqs" "$(count_lines "$REQ_LOG")" "LIVE + tracked config: no request to the broker"
RUN_CONFIG="$GIT_CFG_DIR/config.sh" run_agent "" --check-account
assert_equals "0" "$RC" "tracked config on a non-live endpoint is fine"

# The real repo config.sh stays on paper (value check only; nothing printed)
real_mode=$(cd "$PROJECT_DIR" && bash -c 'source config.sh >/dev/null 2>&1; case $ALPACA_BASE_URL in *paper-api.alpaca.markets*) echo paper;; esac' 2>/dev/null)
assert_equals "paper" "$real_mode" "repo config.sh ALPACA_BASE_URL is the paper endpoint"

# Robinhood (stub functions only) without --live is refused before any call
rh_out=$(cd "$SC_DIR" && printf 'AAPL 1\n' | SST_CONFIG_FILE="$STUB_CONFIG" perl -e 'alarm 30; exec @ARGV' bash -c '
    source "$1" >/dev/null 2>&1 </dev/null
    BROKER_CHOICE=robinhood
    load_broker_module >/dev/null 2>&1 || exit 90
    robinhood_api_request() { echo "UNEXPECTED_NETWORK_CALL" >&2; return 1; }
    robinhood_init() { ROBINHOOD_INITIALIZED=true; }
    robinhood_get_account() { echo "{\"equity\":900}"; }
    robinhood_get_positions() { echo "[]"; }
    robinhood_get_quote() { echo "{\"last_price\":50.5}"; }
    robinhood_place_order() { echo "$*" >> "$2/rh_orders.log"; echo "{\"order_id\":\"rh-stub\"}"; }
    broker_connect >/dev/null 2>&1 || exit 91
    place_buy_order AAPL 1
' _ "$AGENT" "$SC_DIR" 2>&1)
assert_contains "$rh_out" "orders need --live" "robinhood (stubbed) without --live: refused"
assert_equals "0" "$(count_lines "$SC_DIR/rh_orders.log")" "robinhood without --live: robinhood_place_order not called"
assert_not_contains "$rh_out" "UNEXPECTED_NETWORK_CALL" "robinhood stub flow makes no API request"

# ============================================================================
# Alerts: log, Slack webhook stub, sendmail stub
# ============================================================================

new_scenario alerts
accept_baseline "alerts"
run_agent "yes"$'\n' --buy AAPL 1
run_agent "yes"$'\n' --buy REJ 1
assert_equals "1" "$RC" "REJ buy rejected by the stub"
MAX_ORDER_QTY=1 run_agent "yes"$'\n' --buy MSFT 2
run_agent "" --halt "alert test"
for ev in order_placed order_rejected cap_hit halt; do
    assert_true "alert log has a $ev line" bash -c '[[ $(jq -r --arg e "$2" "select(.event == \$e) | .event" "$1" | wc -l) -ge 1 ]]' _ "$ALERTS" "$ev"
done
assert_equals "true" "$(tail -1 "$ALERTS" | jq -r 'has("ts") and has("level") and has("message") and has("details") and .mode == "local"')" \
    "alert line has ts, level, message, details and mode"
assert_equals "rejected" "$(jq -r 'select(.symbol == "REJ") | .status' "$LEDGER")" "ledger: rejected order marked rejected"
assert_not_contains "$(cat "$ALERTS")" "stub-secret" "alert log has no key values"
assert_not_contains "$(cat "$ALERTS")" "stub-key-id" "alert log has no key id"
run_agent "" --resume

hooks_before=$(grep -c '^POST /hooks/' "$REQ_LOG" || true)
ALERTS_SLACK_ENABLED=false ALERT_SLACK_WEBHOOK_URL="$STUB_URL/hooks/slack" run_agent "" --halt "slack disabled"
assert_equals "$hooks_before" "$(grep -c '^POST /hooks/' "$REQ_LOG" || true)" "Slack disabled: no webhook request"
run_agent "" --resume
ALERTS_SLACK_ENABLED=true ALERT_SLACK_WEBHOOK_URL="$STUB_URL/hooks/slack" run_agent "" --halt "slack enabled"
hook_line=$(grep '^POST /hooks/slack' "$REQ_LOG" | tail -1)
assert_contains "$hook_line" "POST /hooks/slack" "Slack enabled: webhook POST received by the stub"
assert_contains "$hook_line" "slack enabled" "Slack message carries the alert text"
assert_not_contains "$hook_line" "stub-secret" "Slack body has no secret key value"
assert_not_contains "$hook_line" "stub-key-id" "Slack body has no key id"
run_agent "" --resume

SENDMAIL_OUT="$SC_DIR/sendmail.out"
FAKE_SENDMAIL="$SC_DIR/fake_sendmail.sh"
printf '#!/bin/bash\n[[ "$1" == "-t" ]] || exit 2\ncat > "%s"\n' "$SENDMAIL_OUT" > "$FAKE_SENDMAIL"
chmod +x "$FAKE_SENDMAIL"
ALERTS_EMAIL_ENABLED=true ALERT_EMAIL_TO="ops@example.invalid" ALERT_SENDMAIL_CMD="$FAKE_SENDMAIL" \
    run_agent "" --halt "email test"
mail=$(cat "$SENDMAIL_OUT" 2>/dev/null)
assert_contains "$mail" "To: ops@example.invalid" "email: To header"
assert_contains "$mail" "Subject: [StockSwingTrader critical] halt" "email: Subject with level and event"
assert_contains "$mail" "email test" "email: message body"
run_agent "" --resume
ALERTS_EMAIL_ENABLED=true ALERT_EMAIL_TO="ops@example.invalid" ALERT_SENDMAIL_CMD="$SC_DIR/missing_sendmail" \
    run_agent "" --halt "email failure"
assert_equals "0" "$RC" "failing email channel is not fatal"
assert_true "failing email channel logs alert_channel_error" \
    bash -c 'jq -e "select(.event == \"alert_channel_error\")" "$1" >/dev/null' _ "$ALERTS"
run_agent "" --resume

# ============================================================================
# --safety-status and --help
# ============================================================================

reqs=$(count_lines "$REQ_LOG")
run_agent "" --safety-status
assert_equals "0" "$RC" "--safety-status exits 0"
assert_contains "$OUT" "Kill switch:        off" "--safety-status shows the kill switch"
assert_contains "$OUT" "MAX_ORDER_QTY=100 MAX_ORDER_NOTIONAL=2500 MAX_DAILY_NOTIONAL=10000 MAX_OPEN_POSITIONS=5" "--safety-status shows the caps"
assert_contains "$OUT" "Mode:               LOCAL STUB" "--safety-status shows the mode"
assert_contains "$OUT" "Baseline:" "--safety-status shows the baseline"
assert_equals "$reqs" "$(count_lines "$REQ_LOG")" "--safety-status makes no broker request"

run_agent "" --help
for flag in --legacy-score --order-type --limit-price --no-bracket --live --allow-mismatch --halt --resume \
    --safety-status --reconcile --reconcile-accept; do
    assert_contains "$OUT" "    $flag" "--help lists $flag"
done

run_agent "yes"$'\n' --buy AAPL 1 --order-type stop
assert_equals "1" "$RC" "--order-type stop is rejected"
run_agent "yes"$'\n' --buy AAPL 1 --limit-price abc
assert_equals "1" "$RC" "--limit-price abc is rejected"
run_agent "yes"$'\n' --buy NVDA 1 --limit-price 120.5 --no-bracket
assert_equals "0" "$RC" "--limit-price 120.5 --no-bracket placed"
assert_equals "limit|120.50|null" "$(tail -1 "$ORDER_LOG" | jq -r '"\(.type)|\(.limit_price)|\(.order_class)"')" \
    "--limit-price sets the limit, --no-bracket sends a plain order"

# The repo state dir was never used
assert_not_contains "$(ls -A "$PROJECT_DIR/.state" 2>/dev/null)" "KILL_SWITCH" "repo .state/ has no kill switch from the tests"

stop_stub

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
