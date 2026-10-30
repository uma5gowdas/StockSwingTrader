#!/bin/bash
# ============================================================================
# StockSwingTrader: Backtesting Test Suite
# ============================================================================
# Tests Enhancement 4: Complete Backtesting Module by running the real
# pipeline (lib/backtest.sh -> lib/backtest_engine.py -> report generator)
# and checking its outputs against values recomputed from the trade journal.
# Tests:
#   1. Metric helper functions with known inputs
#   2. Backtest engine execution and results JSON
#   3. Metrics consistent with trade journal / equity curve
#   4. CSV trade log and HTML report generation
#   5. Determinism and error handling
#
# Runs offline: SST_OFFLINE=1 makes the engine use seeded synthetic prices.
# ============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

export SST_OFFLINE=1
OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sst_backtest_test.XXXXXX")"
trap 'rm -rf "$OUTPUT_DIR"' EXIT
export BACKTEST_OUTPUT_DIR="$OUTPUT_DIR"

source "${PROJECT_DIR}/lib/backtest.sh"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

SYMBOL="AAPL"
START_DATE="2020-01-01"
END_DATE="2024-01-01"
RESULT_FILE=""

# ============================================================================
# Test Utilities
# ============================================================================

pass() { ((TESTS_RUN++)); ((TESTS_PASSED++)); echo -e "${GREEN}✓${NC} $1"; }
fail() { ((TESTS_RUN++)); ((TESTS_FAILED++)); echo -e "${RED}✗${NC} $1"; [[ -n "$2" ]] && echo "  $2"; }

test_assert_equal() {
    local actual=$1 expected=$2 test_name=$3
    if [[ "$actual" == "$expected" ]]; then pass "$test_name"
    else fail "$test_name" "Expected: $expected, Got: $actual"; fi
}

test_assert_file_exists() {
    if [[ -s "$1" ]]; then pass "$2"; else fail "$2" "Missing or empty: $1"; fi
}

# Passes when the jq expression is true for the file
test_assert_jq_file() {
    local file=$1 expr=$2 test_name=$3
    if jq -e "$expr" "$file" > /dev/null 2>&1; then pass "$test_name"
    else fail "$test_name" "jq '$expr' was not true (got: $(jq -c "$expr" "$file" 2>&1 | head -c 200))"; fi
}

# |a - b| <= tol
test_assert_close() {
    local a=$1 b=$2 tol=$3 test_name=$4
    if awk -v a="$a" -v b="$b" -v t="$tol" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= t) }'; then
        pass "$test_name"
    else
        fail "$test_name" "Expected $b ± $tol, Got: $a"
    fi
}

# ============================================================================
# Test Cases
# ============================================================================

test_metric_helpers() {
    echo -e "\n${BLUE}=== Test 1: Metric Helper Functions ===${NC}"

    local trades='[{"pnl": 100}, {"pnl": -50}, {"pnl": 50}, {"pnl": -25}]'
    # gross profit 150 / gross loss 75
    test_assert_close "$(calculate_profit_factor "$trades")" "2.0" "0.0001" "Profit factor = gross profit / gross loss"
    # avg win 75 / avg loss 37.5
    test_assert_close "$(calculate_payoff_ratio "$trades")" "2.0" "0.0001" "Payoff ratio = avg win / avg loss"
    test_assert_equal "$(calculate_profit_factor '[]')" "0" "Profit factor of no trades is 0"
    # Peak 120 -> trough 90 = -25%
    test_assert_close "$(calculate_max_drawdown '[100, 120, 90, 130]')" "-25" "0.0001" "Max drawdown from equity curve"
    test_assert_close "$(calculate_sharpe_ratio '[0.01, 0.01, 0.01]')" "0" "0" "Sharpe ratio is 0 for zero-variance returns"
    local sharpe
    sharpe=$(calculate_sharpe_ratio '[0.01, -0.005, 0.02, 0.0]')
    if awk -v s="$sharpe" 'BEGIN { exit !(s > 0) }'; then pass "Sharpe ratio positive for positive mean returns ($sharpe)"
    else fail "Sharpe ratio positive for positive mean returns" "Got: $sharpe"; fi
}

test_backtest_execution() {
    echo -e "\n${BLUE}=== Test 2: Backtest Engine Execution ===${NC}"

    local output rc
    output=$(backtest_strategy "$SYMBOL" "$START_DATE" "$END_DATE" 80 2>/dev/null); rc=$?
    test_assert_equal "$rc" "0" "backtest_strategy exits 0"

    RESULT_FILE=$(echo "$output" | tail -1)
    test_assert_file_exists "$RESULT_FILE" "Results JSON written to BACKTEST_OUTPUT_DIR"
    [[ -s "$RESULT_FILE" ]] || return 1

    test_assert_jq_file "$RESULT_FILE" '.' "Results JSON is valid"
    test_assert_jq_file "$RESULT_FILE" '.symbol == "AAPL"' "Results record the symbol"
    test_assert_jq_file "$RESULT_FILE" '.period == "2020-01-01 to 2024-01-01"' "Results record the period"
    test_assert_jq_file "$RESULT_FILE" '.strategy == "mean_reversion" or .strategy == "trend_follow"' "Best strategy is a known strategy"
    test_assert_jq_file "$RESULT_FILE" \
        'all(.total_pnl, .win_rate, .sharpe_ratio, .max_drawdown, .profit_factor, .payoff_ratio, .num_trades; type == "number")' \
        "All performance metrics are numbers"
    test_assert_jq_file "$RESULT_FILE" '.num_trades >= 1' "Backtest executed at least 1 trade"
}

test_metrics_consistency() {
    echo -e "\n${BLUE}=== Test 3: Metrics Match Trade Journal & Equity Curve ===${NC}"
    [[ -s "$RESULT_FILE" ]] || { fail "Results file available"; return 1; }

    # 80/20 split of the weekday bars in the period
    local bars
    bars=$(python3 -c "import pandas as pd; d = pd.date_range('$START_DATE', '$END_DATE', freq='D'); n = int((d.day_of_week < 5).sum()); print(n - int(n * 0.8))")
    test_assert_jq_file "$RESULT_FILE" ".data_points == $bars" "Test split has 20% of bars ($bars)"
    test_assert_jq_file "$RESULT_FILE" '(.equity_curve | length) == .data_points' "Equity curve has one point per bar"
    test_assert_jq_file "$RESULT_FILE" '.num_trades == (.trade_journal | length)' "num_trades matches trade journal"
    test_assert_jq_file "$RESULT_FILE" \
        '((.total_pnl - ([.trade_journal[].pnl] | add)) | fabs) < 0.01' "total_pnl = sum of trade P&L"
    test_assert_jq_file "$RESULT_FILE" \
        '((.win_rate - (([.trade_journal[] | select(.pnl > 0)] | length) * 100 / .num_trades)) | fabs) < 0.0001' \
        "win_rate (%) = winning trades / trades"
    test_assert_jq_file "$RESULT_FILE" '.win_rate >= 0 and .win_rate <= 100' "Win rate in [0, 100]%"
    test_assert_jq_file "$RESULT_FILE" '((.final_capital - .initial_capital - .total_pnl) | fabs) < 0.01' \
        "final_capital = initial_capital + total_pnl"
    test_assert_jq_file "$RESULT_FILE" '.max_drawdown <= 0 and .max_drawdown > -100' "Max drawdown in (-100, 0]%"

    # Drawdown must come from the mark-to-market equity curve
    local recomputed
    recomputed=$(calculate_max_drawdown "$(jq -c '.equity_curve' "$RESULT_FILE")")
    test_assert_close "$(jq '.max_drawdown' "$RESULT_FILE")" "$recomputed" "0.001" "max_drawdown matches equity curve"
    # Equity is cash + open position, so it never collapses to the cash left after buying
    test_assert_jq_file "$RESULT_FILE" '(.equity_curve | min) > (.initial_capital * 0.5)' \
        "Equity curve is marked to market (min > 50% of capital)"
    test_assert_jq_file "$RESULT_FILE" \
        'all(.trade_journal[]; .exit_time >= .entry_time and .entry_price > 0 and .exit_price > 0)' \
        "Every trade exits on/after entry with positive prices"
}

test_reports() {
    echo -e "\n${BLUE}=== Test 4: CSV Trade Log & HTML Report ===${NC}"
    [[ -s "$RESULT_FILE" ]] || { fail "Results file available"; return 1; }

    local csv_file="${RESULT_FILE%.json}.csv"
    local html_file="${RESULT_FILE%.json}.html"

    test_assert_file_exists "$csv_file" "CSV trade log generated"
    test_assert_equal "$(head -1 "$csv_file" | tr -d '\r')" \
        "entry_time,exit_time,entry_price,exit_price,pnl,return_pct,reason" "CSV has trade journal header"
    test_assert_equal "$(( $(wc -l < "$csv_file") - 1 ))" "$(jq '.num_trades' "$RESULT_FILE")" "CSV has one row per trade"

    test_assert_file_exists "$html_file" "HTML report generated"
    if grep -q "Backtest Report: AAPL" "$html_file"; then pass "HTML report title names the symbol"
    else fail "HTML report title names the symbol"; fi
    local trades
    trades=$(jq '.num_trades' "$RESULT_FILE")
    if grep -A1 'metric-label">Trades' "$html_file" | grep -q ">${trades}<"; then pass "HTML report shows trade count ($trades)"
    else fail "HTML report shows trade count ($trades)"; fi
}

test_determinism_and_errors() {
    echo -e "\n${BLUE}=== Test 5: Determinism & Error Handling ===${NC}"
    [[ -s "$RESULT_FILE" ]] || { fail "Results file available"; return 1; }

    sleep 1  # results files are timestamped to the second
    local second
    second=$(backtest_strategy "$SYMBOL" "$START_DATE" "$END_DATE" 80 2>/dev/null | tail -1)
    test_assert_equal "$(jq -c '[.total_pnl, .num_trades]' "$second" 2>/dev/null)" \
        "$(jq -c '[.total_pnl, .num_trades]' "$RESULT_FILE")" "Same inputs give the same backtest result"

    local rc
    backtest_strategy "$SYMBOL" "" "" > /dev/null 2>&1; rc=$?
    test_assert_equal "$rc" "1" "Missing dates are rejected"

    python3 "${PROJECT_DIR}/lib/backtest_engine.py" "${OUTPUT_DIR}/missing.json" > /dev/null 2>&1; rc=$?
    test_assert_equal "$rc" "1" "Engine rejects a missing config file"
}

# ============================================================================
# Summary
# ============================================================================

print_summary() {
    echo -e "\n${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}        Backtest Test Summary${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo -e "Tests Run:     ${TESTS_RUN}"
    echo -e "Tests Passed:  ${GREEN}${TESTS_PASSED}${NC}"
    echo -e "Tests Failed:  ${RED}${TESTS_FAILED}${NC}"

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "\n${GREEN}✓ All tests passed!${NC}"
        return 0
    else
        echo -e "\n${RED}✗ Some tests failed${NC}"
        return 1
    fi
}

# ============================================================================
# Main Execution
# ============================================================================

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}    StockSwingTrader: Backtesting Test Suite${NC}"
echo -e "${BLUE}║${NC}    Enhancement 4: Complete Backtesting Module${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"

test_metric_helpers
test_backtest_execution
test_metrics_consistency
test_reports
test_determinism_and_errors

print_summary
exit $?
