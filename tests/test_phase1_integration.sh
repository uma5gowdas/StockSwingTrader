#!/bin/bash
# ============================================================================
# Integration Tests: Phase 1 CLI wiring (StockSwingTrader_Agent.sh)
# ============================================================================
# Tests for: --kelly / --mirofish / --phase1 flags, help/version text, the
# Kelly position_sizing block in analyze_stock, sentiment "na" handling,
# the MiroFish blend in score_stock, the --backtest syntax fix, and that
# MIROFISH_ENABLED=true with nothing at MIROFISH_API_URL adds no per-symbol
# delay to a full CLI run.
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

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sst_phase1_test.XXXXXX")"
export SST_OFFLINE=1
export MIROFISH_CACHE_DIR="$WORK_DIR/mirofish"
export RISK_BUDGET_DIR="$WORK_DIR/risk_budget"
export REGIME_CACHE_DIR="$WORK_DIR/regime"
export SENTIMENT_CACHE_DIR="$WORK_DIR/sentiment"
export BACKTEST_OUTPUT_DIR="$WORK_DIR/backtests"
mkdir -p "$MIROFISH_CACHE_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

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

assert_true() {
    local name=$1
    shift
    if "$@"; then
        pass "$name"
    else
        fail "$name" "Command failed: $*"
    fi
}

now_ms() {
    perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'
}

jget() {
    echo "$1" | jq -r "$2"
}

# run_analysis ENV_ASSIGNMENTS... : source the agent in a fresh bash, run
# analyze_stock AAPL on fixed demo data, print the JSON (log lines stripped).
# The OHLCV series and indicators are computed once and replayed so every
# variant scores identical input (the demo generator is random and the bash
# indicator code takes ~20 s per symbol).
FIXTURE_OHLCV="$WORK_DIR/ohlcv.json"
FIXTURE_IND="$WORK_DIR/indicators.json"
bash -c 'source "$1" >/dev/null 2>&1; LOG_FILE=/dev/null; o=$(fetch_stock_ohlcv AAPL 60); echo "$o" > "$2"; calculate_all_indicators AAPL "$o" > "$3" 2>/dev/null' _ "$AGENT" "$FIXTURE_OHLCV" "$FIXTURE_IND"

run_analysis() {
    env "$@" bash -c '
        source "$1" >/dev/null 2>&1
        LOG_FILE=/dev/null
        SST_FIXTURE_OHLCV="$2"
        SST_FIXTURE_IND="$3"
        fetch_stock_ohlcv() { cat "$SST_FIXTURE_OHLCV"; }
        calculate_all_indicators() { cat "$SST_FIXTURE_IND"; }
        analyze_stock AAPL 2>/dev/null | grep -v "^\["
    ' _ "$AGENT" "$FIXTURE_OHLCV" "$FIXTURE_IND"
}

# ============================================================================
# Help / version / flags
# ============================================================================
echo "Help and flags:"
help_out=$("$AGENT" --help 2>&1)
for flag in --kelly --mirofish --phase1; do
    assert_true "--help lists $flag" grep -q -- "$flag" <<< "$help_out"
done
assert_true "--version mentions Phase 1" grep -q "Phase 1" <<< "$("$AGENT" --version 2>&1)"
"$AGENT" --no-such-flag >/dev/null 2>&1; rc=$?
assert_equals "1" "$rc" "unknown flag still exits 1"
agent_dir=$(bash -c 'source "$1" >/dev/null 2>&1; echo "$AGENT_DIR"' _ "$AGENT")
assert_equals "$PROJECT_DIR" "$agent_dir" "AGENT_DIR is the project root after sourcing the agent"
assert_true "fixture indicators computed (>= 30 demo closes)" jq -e '.indicators.rsi.rsi' "$FIXTURE_IND" >/dev/null

# ============================================================================
# analyze_stock wiring
# ============================================================================
echo ""
echo "analyze_stock:"
plain=$(run_analysis KELLY_SIZING_ENABLED=false MIROFISH_ENABLED=false)
assert_true "analysis JSON parses (Kelly/MiroFish off)" jq -e 'type == "object" and .symbol == "AAPL"' <<< "$plain" >/dev/null
assert_equals "false|false" "$(jget "$plain" '(has("position_sizing")|tostring) + "|" + (.confluence|has("mirofish")|tostring)')" "disabled: no position_sizing, no mirofish block"
assert_equals "null|false" "$(jget "$plain" '(.scores.sentiment|tostring) + "|" + (.confluence.sentiment_available|tostring)')" "offline: sentiment null, sentiment_available false"
assert_equals "$(jget "$plain" .confluence.technical_avg)" "$(jget "$plain" .confluence.final_confidence)" "offline: final confidence equals technical average"

kelly=$(run_analysis KELLY_SIZING_ENABLED=true MIROFISH_ENABLED=true)
assert_true "analysis JSON parses (Kelly + MiroFish on)" jq -e 'type == "object" and .symbol == "AAPL"' <<< "$kelly" >/dev/null
assert_true "Kelly on: position_sizing.status present" jq -e '.position_sizing.status | type == "string"' <<< "$kelly" >/dev/null
assert_true "Kelly on: position_dollars <= MAX_POSITION_SIZE 2500" jq -e '.position_sizing.position_dollars <= 2500 and .position_sizing.qty * 1 >= 0' <<< "$kelly" >/dev/null
assert_true "Kelly on: risk_dollars <= daily budget (2% of 10000)" jq -e '.position_sizing.risk_dollars <= 200' <<< "$kelly" >/dev/null
assert_equals "0" "$(ls "$RISK_BUDGET_DIR" 2>/dev/null | wc -l | tr -d ' ')" "analysis mode never allocates risk budget"
assert_equals "MISSING" "$(jget "$kelly" .confluence.mirofish.status)" "MiroFish on, no cache -> block status MISSING"
assert_equals "$(jget "$plain" .confluence.final_confidence)" "$(jget "$kelly" .confluence.final_confidence)" "MiroFish MISSING leaves final confidence unchanged"

jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{symbol:"AAPL", generated_at:$t, prediction:"BULLISH", confidence:0.8}' > "$MIROFISH_CACHE_DIR/AAPL.json"
mf=$(run_analysis MIROFISH_ENABLED=true MIROFISH_WEIGHT=0.1)
assert_equals "OK|true" "$(jget "$mf" '.confluence.mirofish.status + "|" + (.confluence.mirofish.applied|tostring)')" "fresh BULLISH cache -> mirofish OK and applied"
expected=$(awk -v b="$(jget "$plain" .confluence.final_confidence)" 'BEGIN { printf "%d", int(b * 0.9 + 90 * 0.1 + 0.5) }')
assert_equals "$expected" "$(jget "$mf" .confluence.final_confidence)" "fresh cache blends final = base*0.9 + 90*0.1"
rm -f "$MIROFISH_CACHE_DIR/AAPL.json"

# ============================================================================
# --backtest syntax fix
# ============================================================================
echo ""
echo "Backtest CLI:"
bt_out=$("$AGENT" --backtest AAPL --start 2023-01-01 --end 2023-06-30 --output-dir "$WORK_DIR/bt_reports" 2>&1); rc=$?
assert_true "--backtest with --start/--end: no 'Unknown option'" bash -c '! grep -q "Unknown option" <<< "$1"' _ "$bt_out"
assert_true "--backtest: backtest module found (AGENT_DIR path)" bash -c '! grep -q "Backtest module not found" <<< "$1"' _ "$bt_out"
assert_true "--backtest: log shows 'Backtesting: AAPL'" grep -q "Backtesting: AAPL" <<< "$bt_out"
assert_equals "0" "$rc" "--backtest offline run exits 0"
examples=$(grep -- '--backtest AAPL' <<< "$help_out")
assert_true "help backtest examples use --start" grep -q -- '--start' <<< "$examples"
assert_true "no help example uses positional backtest dates" bash -c '! grep -Eq -- "--backtest [A-Z,]+ [0-9]{4}-" <<< "$1"' _ "$help_out"
assert_true "script header backtest example uses --start" bash -c 'grep -- "--backtest" "$1" | head -1 | grep -q -- "--start"' _ "$AGENT"

# ============================================================================
# Full CLI run: MIROFISH_ENABLED=true with nothing at MIROFISH_API_URL
# ============================================================================
echo ""
echo "CLI timing (MiroFish enabled, unreachable URL):"
t0=$(now_ms)
MIROFISH_ENABLED=true MIROFISH_API_URL=http://127.0.0.1:9 "$AGENT" --symbols AAPL,MSFT --phase1 --output-dir "$WORK_DIR/r1" > "$WORK_DIR/run_on.txt" 2>&1; rc_on=$?
t1=$(now_ms)
MIROFISH_ENABLED=false "$AGENT" --symbols AAPL,MSFT --output-dir "$WORK_DIR/r2" > "$WORK_DIR/run_off.txt" 2>&1; rc_off=$?
t2=$(now_ms)
t_on=$((t1 - t0)); t_off=$((t2 - t1))
echo "  enabled: ${t_on} ms, disabled: ${t_off} ms"
assert_equals "0|0" "$rc_on|$rc_off" "both CLI runs exit 0"
assert_true "enabled run analyzed both symbols" grep -q 'Successfully analyzed 2 out of 2' "$WORK_DIR/run_on.txt"
assert_true "disabled run analyzed both symbols" grep -q 'Successfully analyzed 2 out of 2' "$WORK_DIR/run_off.txt"
# Demo data and bc-heavy indicators make whole-run times noisy, so the
# overhead bound is 2 s plus 25% of the disabled run.
limit=$(( 2000 + t_off / 4 ))
assert_true "enabled run is not slower than disabled by > ${limit} ms (diff $((t_on - t_off)) ms)" test $((t_on - t_off)) -lt "$limit"
mf_ms=$(bash -c '
    source "$1" >/dev/null 2>&1
    export MIROFISH_ENABLED=true MIROFISH_API_URL=http://127.0.0.1:9
    c=$(calculate_confluence_score 60 60 60 60 60 60 na)
    t0=$(perl -MTime::HiRes=time -e "printf \"%d\", time*1000")
    for s in AAPL MSFT GOOGL AMZN TSLA; do apply_mirofish_to_confluence "$c" "$s" >/dev/null; done
    t1=$(perl -MTime::HiRes=time -e "printf \"%d\", time*1000")
    echo $((t1 - t0))
' _ "$AGENT")
assert_true "MiroFish step for 5 symbols takes < 1000 ms (${mf_ms} ms)" test "${mf_ms:-99999}" -lt 1000

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
