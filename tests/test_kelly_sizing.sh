#!/bin/bash
# ============================================================================
# Unit Tests: Kelly Position Sizing & Daily Risk Budget (Phase 1 port)
# ============================================================================
# Tests for: lib/kelly_sizing.sh, its integration in lib/risk_management.sh
# and the strategy files.
# Expected values are computed by hand from the documented formula:
#   f* = (b*p - (1-p)) / b ; f = f*/max(divisor,2) * regime_mult * conf_mult
#   conf_mult = clamp(0.2 + 0.7*conf/100, 0.6, 0.9)
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"

export RISK_BUDGET_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sst_kelly_test.XXXXXX")"
trap 'rm -rf "$RISK_BUDGET_DIR"' EXIT

# Pin the inputs so config/environment cannot change expected values
export MAX_POSITION_SIZE=2500
export KELLY_MAX_POSITION_PCT=10
export KELLY_CRITERION_DIVISOR=4
export MIN_POSITION_SIZE_DOLLARS=100
export DAILY_RISK_BUDGET_PCT=2
export DEFAULT_RISK_LEVEL=moderate
export DAILY_LOSS_LIMIT_CONSERVATIVE_PCT=2
export DAILY_LOSS_LIMIT_MODERATE_PCT=5
export DAILY_LOSS_LIMIT_AGGRESSIVE_PCT=10
export KELLY_WIN_RATE=0.55
export KELLY_WIN_LOSS_RATIO=1.5
unset ALPACA_MAX_POSITION_SIZE
export KELLY_SIZING_ENABLED=false

source "$PROJECT_DIR/lib/kelly_sizing.sh"

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

# assert_true NAME CMD... : passes when CMD exits 0
assert_true() {
    local name=$1
    shift
    if "$@"; then
        pass "$name"
    else
        fail "$name" "Command failed: $*"
    fi
}

# approx A B [EPS] : rc 0 if |A-B| <= EPS
approx() {
    awk -v a="$1" -v b="$2" -v e="${3:-0.000001}" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= e) }'
}

jget() {
    echo "$1" | jq -r "$2"
}

# ============================================================================
# kelly_fraction
# ============================================================================
echo "kelly_fraction:"
assert_equals "0.250000" "$(kelly_fraction 0.55 1.5)" "kelly_fraction 0.55 1.5 = 0.25"
out=$(kelly_fraction 0.4 1.0)
assert_true "kelly_fraction 0.4 1.0 is negative ($out)" awk -v v="$out" 'BEGIN { exit !(v < 0) }'
out=$(kelly_fraction 1.5 1); rc=$?
assert_equals "1|" "$rc|$out" "kelly_fraction rejects win rate > 1 (rc 1, no output)"
out=$(kelly_fraction 0.5 0); rc=$?
assert_equals "1|" "$rc|$out" "kelly_fraction rejects risk/reward 0"
out=$(kelly_fraction abc 1); rc=$?
assert_equals "1|" "$rc|$out" "kelly_fraction rejects non-numeric input"

# ============================================================================
# Multipliers
# ============================================================================
echo ""
echo "Multipliers:"
assert_equals "0.6000" "$(kelly_confidence_multiplier 0)" "confidence 0 -> multiplier floor 0.6"
assert_equals "0.9000" "$(kelly_confidence_multiplier 100)" "confidence 100 -> multiplier cap 0.9"
assert_equals "0.6200" "$(kelly_confidence_multiplier 60)" "confidence 60 -> 0.2+0.42 = 0.62"
assert_equals "0.5" "$(kelly_regime_multiplier volatile)" "volatile regime multiplier 0.5"
assert_equals "1.0" "$(kelly_regime_multiplier trending_bull)" "trending regime multiplier never above 1.0"

# ============================================================================
# kelly_position_plan
# ============================================================================
echo ""
echo "kelly_position_plan:"
risk_budget_reset
base=$(kelly_position_plan 10000 100 95 60 sideways 0.55 1.5)
assert_true "base plan is valid JSON" jq -e . <<< "$base" >/dev/null
assert_equals "OK" "$(jget "$base" .status)" "base plan status OK"
assert_true "base kelly_fraction ~= 0.25/4*0.62 = 0.03875" approx "$(jget "$base" .kelly_fraction)" 0.03875
assert_true "base position_dollars 387.50" approx "$(jget "$base" .position_dollars)" 387.5
assert_equals "3" "$(jget "$base" .qty)" "base qty floor(387.5/100) = 3"
assert_true "base risk_dollars 3*5 = 15" approx "$(jget "$base" .risk_dollars)" 15
assert_equals "kelly" "$(jget "$base" .binding_cap)" "base binding cap is kelly"

p=$(kelly_position_plan 10000 100 95 60 sideways 0.4 1.0)
assert_equals "NO_EDGE|0" "$(jget "$p" '.status + "|" + (.qty|tostring)')" "negative edge -> NO_EDGE, qty 0"
p=$(kelly_position_plan 10000 100 95 60 sideways 0.4 1.5)
assert_equals "NO_EDGE|0" "$(jget "$p" '.status + "|" + (.qty|tostring)')" "zero edge (p=0.4, b=1.5) -> NO_EDGE, qty 0"

p=$(kelly_position_plan 1000000 100 95 100 sideways 0.9 3)
assert_true "MAX_POSITION_SIZE caps position at 2500" approx "$(jget "$p" .position_dollars)" 2500
assert_equals "max_position_size" "$(jget "$p" .binding_cap)" "MAX_POSITION_SIZE is the binding cap"
assert_true "MAX_POSITION_SIZE cap: qty*entry <= 2500" awk -v q="$(jget "$p" .qty)" 'BEGIN { exit !(q * 100 <= 2500) }'

p=$(MAX_POSITION_SIZE=100000000 kelly_position_plan 100000 100 95 100 sideways 0.9 3)
assert_equals "max_position_pct" "$(jget "$p" .binding_cap)" "KELLY_MAX_POSITION_PCT binds when dollar cap is huge"
assert_true "pct cap: position <= 10% of 100000" awk -v v="$(jget "$p" .position_dollars)" 'BEGIN { exit !(v <= 10000) }'

p=$(ALPACA_MAX_POSITION_SIZE=2 kelly_position_plan 10000 100 95 60 sideways 0.55 1.5)
assert_equals "2|shares_cap" "$(jget "$p" '(.qty|tostring) + "|" + .binding_cap')" "ALPACA_MAX_POSITION_SIZE=2 caps shares at 2"

side=$(kelly_position_plan 10000 100 95 60 sideways 0.55 1.5)
vol=$(kelly_position_plan 10000 100 95 60 volatile 0.55 1.5)
assert_true "volatile kelly_fraction is half of sideways" approx "$(jget "$vol" .kelly_fraction)" "$(awk -v s="$(jget "$side" .kelly_fraction)" 'BEGIN { print s / 2 }')"

p=$(KELLY_CRITERION_DIVISOR=1 kelly_position_plan 10000 100 95 60 sideways 0.55 1.5)
assert_true "divisor 1 is clamped to 2 (fraction 0.25/2*0.62 = 0.0775)" approx "$(jget "$p" .kelly_fraction)" 0.0775

p=$(kelly_position_plan 2000 100 95 60 sideways 0.55 1.5)
assert_equals "BELOW_MIN|0" "$(jget "$p" '.status + "|" + (.qty|tostring)')" "position below MIN_POSITION_SIZE_DOLLARS -> BELOW_MIN, qty 0"

p=$(kelly_position_plan 9400 100 95 60 sideways 0.55 1.5 10000)
assert_equals "DRAWDOWN_LIMIT|0" "$(jget "$p" '.status + "|" + (.qty|tostring)')" "6% drawdown >= 5% moderate limit -> DRAWDOWN_LIMIT"

p=$(kelly_position_plan 10000 100 100 60 sideways 0.55 1.5); rc=$?
assert_equals "INVALID_INPUT|0|1" "$(jget "$p" '.status + "|" + (.qty|tostring)')|$rc" "stop >= entry -> INVALID_INPUT (rc 1)"

# ============================================================================
# Daily risk budget
# ============================================================================
echo ""
echo "Daily risk budget:"
risk_budget_reset
assert_equals "200.00" "$(risk_budget_daily_limit 10000)" "daily limit = 2% of 10000"
assert_equals "200.00" "$(DEFAULT_RISK_LEVEL=conservative DAILY_RISK_BUDGET_PCT=3 risk_budget_daily_limit 10000)" "budget pct capped at conservative loss limit (2%)"
assert_equals "500.00" "$(DAILY_RISK_BUDGET_PCT=50 risk_budget_daily_limit 10000)" "budget pct never above moderate loss limit (5%)"

risk_budget_allocate t1 150 10000; rc=$?
assert_equals "0|50.00" "$rc|$(risk_budget_remaining 10000)" "allocate 150 accepted, 50 remaining"
risk_budget_allocate t2 60 10000; rc=$?
assert_equals "1|150.00" "$rc|$(risk_budget_used)" "allocate 60 rejected (over budget), used unchanged"

p=$(kelly_position_plan 10000 100 50 60 sideways 0.55 1.5)
assert_equals "OK|1|daily_risk_budget" "$(jget "$p" '.status + "|" + (.qty|tostring) + "|" + .binding_cap')" "remaining budget 50 caps qty to 1 (risk 50/share)"

risk_budget_allocate t3 50 10000
p=$(kelly_position_plan 10000 100 95 60 sideways 0.55 1.5)
assert_equals "BUDGET_EXHAUSTED|0" "$(jget "$p" '.status + "|" + (.qty|tostring)')" "exhausted budget -> BUDGET_EXHAUSTED, qty 0"

# Concurrency: 6 parallel allocations of 50 against a 200 budget
risk_budget_reset
for i in 1 2 3 4 5 6; do
    risk_budget_allocate "c$i" 50 10000 &
done
wait
ledger="$RISK_BUDGET_DIR/ledger_$(date +%Y-%m-%d).txt"
lines=$(wc -l < "$ledger" | tr -d ' ')
assert_equals "4|200.00" "$lines|$(risk_budget_used)" "6 concurrent allocations: exactly 4 succeed, used 200"
assert_true "lock directory released after concurrent run" test ! -d "$RISK_BUDGET_DIR/.lock"
risk_budget_reset

# ============================================================================
# kelly_cap_qty
# ============================================================================
echo ""
echo "kelly_cap_qty:"
assert_equals "50" "$(KELLY_SIZING_ENABLED=false kelly_cap_qty 50 100 95 10000)" "disabled -> qty unchanged"
assert_equals "3" "$(KELLY_SIZING_ENABLED=true kelly_cap_qty 50 100 95 10000)" "enabled -> capped to Kelly qty 3"
assert_equals "2" "$(KELLY_SIZING_ENABLED=true kelly_cap_qty 2 100 95 10000)" "enabled -> never increases qty (2 stays 2)"
assert_equals "1" "$(KELLY_SIZING_ENABLED=true kelly_cap_qty 50 100 95 10000 60 volatile)" "enabled + volatile regime -> qty 1 (half Kelly fraction)"
assert_equals "0" "$(KELLY_WIN_RATE=0.4 KELLY_WIN_LOSS_RATIO=1 KELLY_SIZING_ENABLED=true kelly_cap_qty 50 100 95 10000)" "enabled + negative edge -> qty 0"

# ============================================================================
# Every plan output is valid JSON
# ============================================================================
echo ""
echo "JSON validity:"
all_ok=true
for args in "10000 100 95 60 sideways" "10000 100 95 60 sideways 0.4 1.0" "abc 100 95" \
            "10000 100 120" "2000 100 95" "9400 100 95 60 x 0.55 1.5 10000" "10000 100 95 notanumber"; do
    out=$(kelly_position_plan $args 2>/dev/null)
    if ! echo "$out" | jq -e 'type == "object" and has("status") and has("qty")' >/dev/null 2>&1; then
        all_ok=false
        echo "  invalid JSON for: $args -> $out"
    fi
done
assert_equals "true" "$all_ok" "every kelly_position_plan output parses as a JSON object"

# ============================================================================
# Integration with lib/risk_management.sh and the strategies
# ============================================================================
echo ""
echo "Integration:"
rm_out=$(bash -c 'source "$1/lib/risk_management.sh" >/dev/null 2>&1; declare -f kelly_cap_qty >/dev/null && declare -f risk_budget_allocate >/dev/null && echo yes' _ "$PROJECT_DIR")
assert_equals "yes" "$rm_out" "sourcing risk_management.sh provides kelly_cap_qty and risk_budget_allocate"
# Value captured from the unmodified calculate_position_size before the port
size_out=$(bash -c 'source "$1/lib/risk_management.sh" >/dev/null 2>&1; calculate_position_size 10000 2' _ "$PROJECT_DIR")
assert_equals "625.0000" "$size_out" "calculate_position_size 10000 2 unchanged (625.0000)"
assert_true "strategy_mean_reversion.sh passes bash -n" bash -n "$PROJECT_DIR/lib/strategy_mean_reversion.sh"
assert_true "strategy_trend_follow.sh passes bash -n" bash -n "$PROJECT_DIR/lib/strategy_trend_follow.sh"
for f in strategy_mean_reversion.sh strategy_trend_follow.sh; do
    order_line=$(grep -n 'alpaca_place_order "$symbol"' "$PROJECT_DIR/lib/$f" | head -1 | cut -d: -f1)
    budget_line=$(grep -n 'risk_budget_allocate' "$PROJECT_DIR/lib/$f" | head -1 | cut -d: -f1)
    assert_true "$f reserves risk budget before placing the order" test -n "$budget_line" -a -n "$order_line" -a "${budget_line:-0}" -lt "${order_line:-0}"
done

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
