#!/bin/bash
# ============================================================================
# Unit Tests: Regime Modules (Simplified)
# ============================================================================
# Tests for: lib/regime_detector.sh and lib/regime_weighting.sh
# ============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Source modules under test
source "$(dirname "$0")/../lib/regime_detector.sh"
source "$(dirname "$0")/../lib/regime_weighting.sh"

# Test utilities
assert_contains() {
    local haystack=$1
    local needle=$2
    local test_name=$3
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [[ "$haystack" == *"$needle"* ]]; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $test_name"
        echo "  Expected: $needle"
        echo "  Got: $haystack"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

test_trend_direction() {
    local result=$(detect_trend_direction 102.5 100.0)
    assert_contains "$result" "up" "Trend direction up (EMA20 > EMA50)"
}

test_regime_detection_json() {
    local result=$(detect_market_regime "AAPL")
    assert_contains "$result" '"regime"' "Regime detection returns JSON"
}

test_regime_detection_has_fields() {
    local result=$(detect_market_regime "GOOGL")
    assert_contains "$result" '"adx"' "Regime includes ADX"
    assert_contains "$result" '"trend"' "Regime includes trend"
    assert_contains "$result" '"volatility"' "Regime includes volatility"
}

test_regime_weighting_json() {
    local result=$(apply_regime_weights "TEST" 70 40)
    assert_contains "$result" '"combined_score"' "Weighting returns JSON with combined_score"
}

test_sideways_weights_mr() {
    local result=$(apply_regime_weights "TEST_SW" 80 20 "sideways")
    assert_contains "$result" '"mr_weight_pct": 70' "Sideways weights MeanReversion 70%"
}

test_trending_weights_tf() {
    local result=$(apply_regime_weights "TEST_TR" 20 80 "trending_bull")
    assert_contains "$result" '"tf_weight_pct": 70' "Trending weights TrendFollow 70%"
}

test_sideways_recommendation() {
    local result=$(apply_regime_weights "TEST_REC" 85 30 "sideways")
    assert_contains "$result" '"recommendation": "mean_reversion_buy"' "High MR score in sideways recommends mean reversion"
}

test_weighting_has_timestamp() {
    local result=$(apply_regime_weights "TEST_TIME" 50 50)
    assert_contains "$result" '"timestamp"' "Weighting output includes timestamp"
}

test_volatile_stop_loss_adj() {
    local result=$(apply_regime_weights "TEST_VOL" 50 50 "volatile")
    assert_contains "$result" '"stop_loss_adjustment_pct": 2' "Volatile regime increases stop-loss by 2%"
}

test_select_strategy_json() {
    local result=$(select_best_strategy "SELECT_TEST" 75 40)
    assert_contains "$result" '"best_strategy"' "Strategy selection returns JSON"
}

test_regime_change_json() {
    local result=$(detect_regime_change "CHANGE_TEST" "sideways")
    assert_contains "$result" '"changed"' "Regime change detection returns changed field"
}

test_cache_creation() {
    local symbol="CACHE_TEST"
    clear_regime_cache "$symbol"
    
    detect_market_regime "$symbol" > /dev/null
    
    local cache_file=$(get_regime_cache_file "$symbol")
    if [[ -f "$cache_file" ]]; then
        echo -e "${GREEN}✓${NC} Cache file creation works"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} Cache file creation works"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
    
    clear_regime_cache "$symbol"
}

test_batch_regimes() {
    local result=$(detect_regimes_batch "SYM1,SYM2,SYM3")
    assert_contains "$result" "[" "Batch regime detection returns array"
}

# Run all tests
echo "=========================================="
echo "  Regime Module Tests (Simplified)"
echo "=========================================="
echo ""

test_trend_direction
test_regime_detection_json
test_regime_detection_has_fields
test_regime_weighting_json
test_sideways_weights_mr
test_trending_weights_tf
test_sideways_recommendation
test_weighting_has_timestamp
test_volatile_stop_loss_adj
test_select_strategy_json
test_regime_change_json
test_cache_creation
test_batch_regimes

# Summary
echo ""
echo "=========================================="
echo "  Test Summary"
echo "=========================================="
echo "Total:  $TESTS_RUN"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "\n${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "\n${RED}$TESTS_FAILED tests failed.${NC}"
    exit 1
fi
