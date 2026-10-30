#!/bin/bash
# ============================================================================
# Test: ML Predictor Integration into Scoring Pipeline
# ============================================================================
# Tests all modules load, execute, and output correct JSON format
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"
TEST_DIR="${SCRIPT_DIR}"
RESULTS_FILE="${TEST_DIR}/.test_results.json"

# Run the real ML predictor offline (no yfinance) with a timeout that fits
# a cold python start, and isolate the regime cache.
export SST_OFFLINE=1
export ML_TIMEOUT_SECONDS="${ML_TIMEOUT_SECONDS:-20}"
export REGIME_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sst_regime_test.XXXXXX")"
trap 'rm -rf "$REGIME_CACHE_DIR"' EXIT

echo "=========================================="
echo "ML Scoring Integration Test Suite"
echo "=========================================="

# Color codes for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# ============================================================================
# Helper Functions
# ============================================================================

test_module() {
    local test_name=$1
    local module_path=$2
    
    ((TESTS_RUN++))
    echo -n "Test $TESTS_RUN: $test_name ... "
    
    if [[ -f "$module_path" ]]; then
        if bash -n "$module_path" 2>/dev/null; then
            echo -e "${GREEN}✓ PASS${NC}"
            ((TESTS_PASSED++))
            return 0
        else
            echo -e "${RED}✗ FAIL${NC} (syntax error)"
            ((TESTS_FAILED++))
            return 1
        fi
    else
        echo -e "${RED}✗ FAIL${NC} (file not found)"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_function_exists() {
    local test_name=$1
    local function_name=$2
    local module_path=$3
    
    ((TESTS_RUN++))
    echo -n "Test $TESTS_RUN: $test_name ... "
    
    if bash -c "source $module_path && declare -f $function_name > /dev/null 2>&1" 2>/dev/null; then
        echo -e "${GREEN}✓ PASS${NC}"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}✗ FAIL${NC} (function not found)"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_json_output() {
    local test_name=$1
    local json_output=$2
    
    ((TESTS_RUN++))
    echo -n "Test $TESTS_RUN: $test_name ... "
    
    if echo "$json_output" | jq . > /dev/null 2>&1; then
        echo -e "${GREEN}✓ PASS${NC}"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}✗ FAIL${NC} (invalid JSON)"
        echo "  Output: $json_output"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_score_range() {
    local test_name=$1
    local score=$2
    
    ((TESTS_RUN++))
    echo -n "Test $TESTS_RUN: $test_name ... "
    
    if (( $(echo "$score >= 0 && $score <= 100" | bc -l) )); then
        echo -e "${GREEN}✓ PASS${NC} (score=$score)"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}✗ FAIL${NC} (score=$score out of range 0-100)"
        ((TESTS_FAILED++))
        return 1
    fi
}

# ============================================================================
# Module Loading Tests
# ============================================================================

echo ""
echo "--- Module Syntax Validation ---"
test_module "scoring.sh syntax" "${LIB_DIR}/scoring.sh"
test_module "ml_predictor.sh syntax" "${LIB_DIR}/ml_predictor.sh"
test_module "regime_weighting.sh syntax" "${LIB_DIR}/regime_weighting.sh"
test_module "kalman_filter.sh syntax" "${LIB_DIR}/kalman_filter.sh"

# ============================================================================
# Function Availability Tests
# ============================================================================

echo ""
echo "--- Function Availability ---"
test_function_exists "calculate_confluence_score_v2 exists" "calculate_confluence_score_v2" "${LIB_DIR}/scoring.sh"
test_function_exists "ml_predict_direction exists" "ml_predict_direction" "${LIB_DIR}/ml_predictor.sh"
test_function_exists "get_regime_weights exists" "get_regime_weights" "${LIB_DIR}/regime_weighting.sh"
test_function_exists "apply_kalman_filter exists" "apply_kalman_filter" "${LIB_DIR}/kalman_filter.sh"

# ============================================================================
# Individual Scorer Function Tests
# ============================================================================

echo ""
echo "--- Individual Scorer Functions ---"

source "${LIB_DIR}/scoring.sh" 2>/dev/null

# Test RSI scorer
rsi_test=$(score_rsi 70)
test_score_range "score_rsi(70)" "$rsi_test"

# Test MACD scorer
macd_test=$(score_macd 0.05 0.03 0.02)
test_score_range "score_macd(0.05, 0.03, 0.02)" "$macd_test"

# Test Bollinger Bands scorer
bb_test=$(score_bollinger_bands 100 105 102 99)
test_score_range "score_bollinger_bands(100, 105, 102, 99)" "$bb_test"

# Test OBV scorer
obv_test=$(score_obv 1000000 950000)
test_score_range "score_obv(1000000, 950000)" "$obv_test"

# ============================================================================
# Integrated Scoring Pipeline Tests
# ============================================================================

echo ""
echo "--- Integrated Scoring Pipeline ---"

# Test basic scoring function call
((TESTS_RUN++))
echo -n "Test $TESTS_RUN: calculate_confluence_score_v2 executes ... "

test_output=$(calculate_confluence_score_v2 "AAPL" 65 60 70 55 "sideways" 60 55 1 </dev/null 2>/dev/null || true)

if [[ -n "$test_output" ]]; then
    echo -e "${GREEN}✓ PASS${NC}"
    ((TESTS_PASSED++))
    
    # Validate JSON output
    test_json_output "calculate_confluence_score_v2 JSON format" "$test_output"
    
    # Extract and validate confluence score
    confluence_score=$(echo "$test_output" | jq -r '.confluence_score // "error"' 2>/dev/null || echo "error")
    if [[ "$confluence_score" != "error" ]]; then
        test_score_range "confluence_score range validation" "$confluence_score"
    fi
    
    # Validate recommendation field
    ((TESTS_RUN++))
    echo -n "Test $TESTS_RUN: recommendation field valid ... "
    recommendation=$(echo "$test_output" | jq -r '.recommendation // "error"' 2>/dev/null || echo "error")
    if [[ "$recommendation" =~ ^(STRONG_BUY|BUY|HOLD|SELL|STRONG_SELL)$ ]]; then
        echo -e "${GREEN}✓ PASS${NC} (recommendation=$recommendation)"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗ FAIL${NC} (invalid recommendation=$recommendation)"
        ((TESTS_FAILED++))
    fi
    
    # Validate signal_strength field
    ((TESTS_RUN++))
    echo -n "Test $TESTS_RUN: signal_strength field valid ... "
    signal_strength=$(echo "$test_output" | jq -r '.signal_strength // "error"' 2>/dev/null || echo "error")
    if [[ "$signal_strength" =~ ^[0-4]$ ]]; then
        echo -e "${GREEN}✓ PASS${NC} (signal_strength=$signal_strength)"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗ FAIL${NC} (invalid signal_strength=$signal_strength)"
        ((TESTS_FAILED++))
    fi
    
    # Validate components structure
    ((TESTS_RUN++))
    echo -n "Test $TESTS_RUN: components structure complete ... "
    has_ml=$(echo "$test_output" | jq '.components.ml_confidence' 2>/dev/null | grep -q "score" && echo "yes" || echo "no")
    has_regime=$(echo "$test_output" | jq '.components.regime_score' 2>/dev/null | grep -q "score" && echo "yes" || echo "no")
    has_technical=$(echo "$test_output" | jq '.components.technical_score' 2>/dev/null | grep -q "score" && echo "yes" || echo "no")
    has_volume=$(echo "$test_output" | jq '.components.volume_trend_score' 2>/dev/null | grep -q "score" && echo "yes" || echo "no")
    
    if [[ "$has_ml" == "yes" && "$has_regime" == "yes" && "$has_technical" == "yes" && "$has_volume" == "yes" ]]; then
        echo -e "${GREEN}✓ PASS${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗ FAIL${NC} (missing components: ML=$has_ml, Regime=$has_regime, Technical=$has_technical, Volume=$has_volume)"
        ((TESTS_FAILED++))
    fi
    
    # Validate the ML component really ran and its score is the predictor's
    ((TESTS_RUN++))
    echo -n "Test $TESTS_RUN: ML predictor output used in confluence ... "
    expected_ml=$(bash "${LIB_DIR}/ml_predictor.sh" predict AAPL 5 </dev/null 2>/dev/null | jq -r '.confidence')
    actual_ml=$(echo "$test_output" | jq -r '.components.ml_confidence.score')
    ml_dir=$(echo "$test_output" | jq -r '.components.ml_confidence.direction')
    ml_err=$(echo "$test_output" | jq -r '.metadata.ml_error')
    if [[ -z "$ml_err" && "$ml_dir" =~ ^(up|down)$ && "$actual_ml" == "$expected_ml" ]]; then
        echo -e "${GREEN}✓ PASS${NC} (ml=${actual_ml}, direction=${ml_dir})"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗ FAIL${NC} (ml=${actual_ml}, expected=${expected_ml}, direction=${ml_dir}, error=${ml_err})"
        ((TESTS_FAILED++))
    fi

    # Validate latency: the ML call is bounded by ML_TIMEOUT_SECONDS, the
    # rest of the pipeline must add less than 2s on top.
    latency_limit=$(( ML_TIMEOUT_SECONDS * 1000 + 2000 ))
    ((TESTS_RUN++))
    echo -n "Test $TESTS_RUN: latency measurement < ${latency_limit}ms ... "
    latency=$(echo "$test_output" | jq -r '.metadata.latency_ms // "missing"' 2>/dev/null)
    if [[ "$latency" =~ ^[0-9]+$ ]] && (( latency > 0 && latency < latency_limit )); then
        echo -e "${GREEN}✓ PASS${NC} (latency=${latency}ms)"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗ FAIL${NC} (latency=${latency}ms, limit ${latency_limit}ms)"
        ((TESTS_FAILED++))
    fi
    
else
    echo -e "${RED}✗ FAIL${NC} (no output)"
    ((TESTS_FAILED++))
fi

# ML timeout: a 1s limit cannot fit a cold python start, so the pipeline must
# fall back to a neutral ML score instead of hanging (macOS has no `timeout`).
((TESTS_RUN++))
echo -n "Test $TESTS_RUN: ML timeout falls back to neutral score ... "
timeout_output=$(ML_TIMEOUT_SECONDS=1 calculate_confluence_score_v2 "AAPL" 50 50 50 50 "sideways" 50 50 0 </dev/null 2>/dev/null)
if [[ "$(echo "$timeout_output" | jq -r '.components.ml_confidence.score')" == "50" && \
      "$(echo "$timeout_output" | jq -r '.metadata.ml_error')" == "timeout_or_failure" && \
      "$(echo "$timeout_output" | jq -r '.metadata.latency_ms')" -lt 3000 ]]; then
    echo -e "${GREEN}✓ PASS${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${RED}✗ FAIL${NC} (output: $(echo "$timeout_output" | jq -c '{ml: .components.ml_confidence, m: .metadata}'))"
    ((TESTS_FAILED++))
fi

# The ML component is a real model, so threshold tests pin symbols whose
# offline prediction is known and check that precondition first.
ml_fixture() {
    local symbol=$1 want_dir=$2
    ((TESTS_RUN++))
    echo -n "Test $TESTS_RUN: ML fixture $symbol predicts $want_dir with confidence > 60 ... "
    local r
    r=$(bash "${LIB_DIR}/ml_predictor.sh" predict "$symbol" 5 </dev/null 2>/dev/null)
    if echo "$r" | jq -e --arg d "$want_dir" '.direction == $d and .confidence > 60' >/dev/null 2>&1; then
        echo -e "${GREEN}✓ PASS${NC} ($(echo "$r" | jq -c '{direction, confidence}'))"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗ FAIL${NC} (got $r)"
        ((TESTS_FAILED++))
    fi
}

# ============================================================================
# Scoring Thresholds Tests
# ============================================================================

echo ""
echo "--- Scoring Threshold Rules ---"

# Test STRONG_BUY threshold (70+): all components bullish
ml_fixture "TEST1" "up"
((TESTS_RUN++))
echo -n "Test $TESTS_RUN: STRONG_BUY threshold (score >= 70) ... "
strong_buy_test=$(calculate_confluence_score_v2 "TEST1" 90 90 90 90 "trending_bull" 90 90 1 </dev/null 2>/dev/null)
strong_buy_rec=$(echo "$strong_buy_test" | jq -r '.recommendation // "error"' 2>/dev/null || echo "error")
strong_buy_score=$(echo "$strong_buy_test" | jq -r '.confluence_score // 0' 2>/dev/null || echo "0")

if [[ "$strong_buy_rec" == "STRONG_BUY" && $(echo "$strong_buy_score >= 70" | bc -l) -eq 1 ]]; then
    echo -e "${GREEN}✓ PASS${NC} (recommendation=$strong_buy_rec, score=$strong_buy_score)"
    ((TESTS_PASSED++))
else
    echo -e "${RED}✗ FAIL${NC} (expected STRONG_BUY with score>=70, got $strong_buy_rec with score=$strong_buy_score)"
    ((TESTS_FAILED++))
fi

# Test HOLD threshold (40-60)
((TESTS_RUN++))
echo -n "Test $TESTS_RUN: HOLD threshold (40 <= score < 60) ... "
hold_test=$(calculate_confluence_score_v2 "TEST2" 50 50 50 50 "sideways" 50 50 0 </dev/null 2>/dev/null)
hold_rec=$(echo "$hold_test" | jq -r '.recommendation // "error"' 2>/dev/null || echo "error")
hold_score=$(echo "$hold_test" | jq -r '.confluence_score // 0' 2>/dev/null || echo "0")

if [[ "$hold_rec" == "HOLD" && $(echo "$hold_score >= 40 && $hold_score < 60" | bc -l) -eq 1 ]]; then
    echo -e "${GREEN}✓ PASS${NC} (recommendation=$hold_rec, score=$hold_score)"
    ((TESTS_PASSED++))
else
    echo -e "${RED}✗ FAIL${NC} (expected HOLD with 40<=score<60, got $hold_rec with score=$hold_score)"
    ((TESTS_FAILED++))
fi

# Test STRONG_SELL threshold (score < 30): all components bearish.
# (TEST3's model prediction is "up", which would dissent; TEST2 is "down".)
ml_fixture "TEST2" "down"
((TESTS_RUN++))
echo -n "Test $TESTS_RUN: STRONG_SELL threshold (score < 30) ... "
strong_sell_test=$(calculate_confluence_score_v2 "TEST2" 10 10 10 10 "trending_bear" 10 10 -1 </dev/null 2>/dev/null)
strong_sell_rec=$(echo "$strong_sell_test" | jq -r '.recommendation // "error"' 2>/dev/null || echo "error")
strong_sell_score=$(echo "$strong_sell_test" | jq -r '.confluence_score // 100' 2>/dev/null || echo "100")

if [[ "$strong_sell_rec" == "STRONG_SELL" && $(echo "$strong_sell_score < 30" | bc -l) -eq 1 ]]; then
    echo -e "${GREEN}✓ PASS${NC} (recommendation=$strong_sell_rec, score=$strong_sell_score)"
    ((TESTS_PASSED++))
else
    echo -e "${RED}✗ FAIL${NC} (expected STRONG_SELL with score<30, got $strong_sell_rec with score=$strong_sell_score)"
    ((TESTS_FAILED++))
fi

# ============================================================================
# Regime Adaptation Tests
# ============================================================================

echo ""
echo "--- Regime Adaptation Tests ---"

# Same symbol (same ML score) and indicators; only MR vs TF strength swaps.
regime_component() {
    calculate_confluence_score_v2 "TEST4" 50 50 50 50 "$1" "$2" "$3" 0 </dev/null 2>/dev/null
}

# Test sideways regime weighting: 70% MR + 30% TF
((TESTS_RUN++))
echo -n "Test $TESTS_RUN: sideways regime favors mean reversion ... "
sideways_mr=$(regime_component sideways 80 40)
sideways_tf=$(regime_component sideways 40 80)
s_mr=$(echo "$sideways_mr" | jq -r '.confluence_score')
s_tf=$(echo "$sideways_tf" | jq -r '.confluence_score')
s_comp=$(echo "$sideways_mr" | jq -r '.components.regime_score.score')
if [[ "$s_comp" == "68" ]] && (( s_mr > s_tf )); then
    echo -e "${GREEN}✓ PASS${NC} (regime component 80*0.7+40*0.3=$s_comp; MR-high=$s_mr > TF-high=$s_tf)"
    ((TESTS_PASSED++))
else
    echo -e "${RED}✗ FAIL${NC} (regime component=$s_comp expected 68; MR-high=$s_mr, TF-high=$s_tf)"
    ((TESTS_FAILED++))
fi

# Test trending regime weighting: 30% MR + 70% TF
((TESTS_RUN++))
echo -n "Test $TESTS_RUN: trending regime favors trend following ... "
trend_mr=$(regime_component trending_bull 80 40)
trend_tf=$(regime_component trending_bull 40 80)
t_mr=$(echo "$trend_mr" | jq -r '.confluence_score')
t_tf=$(echo "$trend_tf" | jq -r '.confluence_score')
t_comp=$(echo "$trend_tf" | jq -r '.components.regime_score.score')
if [[ "$t_comp" == "68" ]] && (( t_tf > t_mr )); then
    echo -e "${GREEN}✓ PASS${NC} (regime component 40*0.3+80*0.7=$t_comp; TF-high=$t_tf > MR-high=$t_mr)"
    ((TESTS_PASSED++))
else
    echo -e "${RED}✗ FAIL${NC} (regime component=$t_comp expected 68; TF-high=$t_tf, MR-high=$t_mr)"
    ((TESTS_FAILED++))
fi

# Test volatile regime: 50/50 then -20%
((TESTS_RUN++))
echo -n "Test $TESTS_RUN: volatile regime reduces strategy score 20% ... "
v_comp=$(regime_component volatile 60 60 | jq -r '.components.regime_score.score')
if [[ "$v_comp" == "48" ]]; then
    echo -e "${GREEN}✓ PASS${NC} ((60*0.5+60*0.5)*0.8=$v_comp)"
    ((TESTS_PASSED++))
else
    echo -e "${RED}✗ FAIL${NC} (expected 48, got $v_comp)"
    ((TESTS_FAILED++))
fi

# ============================================================================
# Test Summary
# ============================================================================

echo ""
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo -e "Tests Run:  $TESTS_RUN"
echo -e "Passed:     ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed:     ${RED}$TESTS_FAILED${NC}"
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}✗ Some tests failed${NC}"
    exit 1
fi
