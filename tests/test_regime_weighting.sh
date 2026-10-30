#!/bin/bash
# ============================================================================
# Unit Tests: Regime-Adaptive Weighting Module
# ============================================================================
# Tests for: lib/regime_weighting.sh
# Coverage: Regime-based strategy weighting, risk adjustment, recommendations
# ============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Source modules under test
source "$(dirname "$0")/../lib/regime_weighting.sh"
source "$(dirname "$0")/../lib/regime_detector.sh"
source "$(dirname "$0")/../lib/indicators.sh"

# ============================================================================
# Test Utilities
# ============================================================================

assert_equals() {
    local expected=$1
    local actual=$2
    local test_name=$3
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}✓ PASS${NC}: $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}: $test_name"
        echo "  Expected: $expected"
        echo "  Got:      $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_contains() {
    local haystack=$1
    local needle=$2
    local test_name=$3
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [[ "$haystack" == *"$needle"* ]]; then
        echo -e "${GREEN}✓ PASS${NC}: $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}: $test_name"
        echo "  Expected to contain: $needle"
        echo "  Got: $haystack"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_numeric_between() {
    local value=$1
    local min=$2
    local max=$3
    local test_name=$4
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if (( $(echo "$value >= $min && $value <= $max" | bc -l) )); then
        echo -e "${GREEN}✓ PASS${NC}: $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}: $test_name"
        echo "  Expected between: $min - $max"
        echo "  Got: $value"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ============================================================================
# Test Suite: Regime Weights
# ============================================================================

test_sideways_weights() {
    local weights=$(get_regime_weights "sideways")
    local mr_weight=$(echo "$weights" | grep -o '"mr_weight":[0-9]*' | cut -d: -f2)
    local tf_weight=$(echo "$weights" | grep -o '"tf_weight":[0-9]*' | cut -d: -f2)
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [[ $mr_weight -eq 70 && $tf_weight -eq 30 ]]; then
        echo -e "${GREEN}✓ PASS${NC}: Sideways regime weights MeanReversion 70% / TrendFollow 30%"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}: Sideways regime weights"
        echo "  Expected: MR=70, TF=30"
        echo "  Got: MR=$mr_weight, TF=$tf_weight"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

test_trending_bull_weights() {
    local weights=$(get_regime_weights "trending_bull")
    local mr_weight=$(echo "$weights" | grep -o '"mr_weight":[0-9]*' | cut -d: -f2)
    local tf_weight=$(echo "$weights" | grep -o '"tf_weight":[0-9]*' | cut -d: -f2)
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [[ $mr_weight -eq 30 && $tf_weight -eq 70 ]]; then
        echo -e "${GREEN}✓ PASS${NC}: Trending bull regime weights TrendFollow 70% / MeanReversion 30%"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}: Trending bull regime weights"
        echo "  Expected: MR=30, TF=70"
        echo "  Got: MR=$mr_weight, TF=$tf_weight"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

test_trending_bear_weights() {
    local weights=$(get_regime_weights "trending_bear")
    local mr_weight=$(echo "$weights" | grep -o '"mr_weight":[0-9]*' | cut -d: -f2)
    local tf_weight=$(echo "$weights" | grep -o '"tf_weight":[0-9]*' | cut -d: -f2)
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [[ $mr_weight -eq 30 && $tf_weight -eq 70 ]]; then
        echo -e "${GREEN}✓ PASS${NC}: Trending bear regime weights TrendFollow 70% / MeanReversion 30%"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}: Trending bear regime weights"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

test_volatile_weights() {
    local weights=$(get_regime_weights "volatile")
    local mr_weight=$(echo "$weights" | grep -o '"mr_weight":[0-9]*' | cut -d: -f2)
    local tf_weight=$(echo "$weights" | grep -o '"tf_weight":[0-9]*' | cut -d: -f2)
    local sl_adj=$(echo "$weights" | grep -o '"stop_loss_adjustment":[0-9]*' | cut -d: -f2)
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [[ $mr_weight -eq 50 && $tf_weight -eq 50 && $sl_adj -eq 2 ]]; then
        echo -e "${GREEN}✓ PASS${NC}: Volatile regime weights balanced + 2% stop-loss adjustment"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}: Volatile regime weights"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ============================================================================
# Test Suite: Confidence Multipliers
# ============================================================================

test_confidence_multiplier_sideways() {
    local adjusted=$(apply_confidence_multiplier 50 "sideways" 30)
    assert_numeric_between "$adjusted" "49" "51" "Sideways regime confidence multiplier ~1.0"
}

test_confidence_multiplier_trending_bull() {
    local adjusted=$(apply_confidence_multiplier 50 "trending_bull" 30)
    assert_numeric_between "$adjusted" "54" "56" "Trending bull regime boosts confidence 1.1x"
}

test_confidence_multiplier_volatile_low() {
    local adjusted=$(apply_confidence_multiplier 50 "volatile" 20)
    assert_numeric_between "$adjusted" "39" "41" "Volatile regime reduces confidence to 0.8x"
}

test_confidence_multiplier_volatile_high() {
    local adjusted=$(apply_confidence_multiplier 50 "volatile" 30)
    assert_numeric_between "$adjusted" "34" "36" "Very volatile market reduces confidence to 0.7x"
}

# ============================================================================
# Test Suite: Combined Score Calculation
# ============================================================================

test_combined_score_sideways_mean_reversion() {
    # In sideways market, mean reversion gets higher weight
    local result=$(apply_regime_weights "TEST_SIDEWAYS" 80 40 "sideways")
    local combined=$(echo "$result" | grep -o '"combined_score":[0-9.]*' | cut -d: -f2)
    
    # Expected: (80 * 0.7) + (40 * 0.3) = 56 + 12 = 68
    assert_numeric_between "$combined" "67" "69" "Sideways: MR-favored combined score calculation"
}

test_combined_score_trending_trend_follow() {
    # In trending market, trend follow gets higher weight
    local result=$(apply_regime_weights "TEST_TREND" 40 85 "trending_bull")
    local combined=$(echo "$result" | grep -o '"combined_score":[0-9.]*' | cut -d: -f2)
    
    # Expected: (40 * 0.3) + (85 * 0.7) = 12 + 59.5 = 71.5 * 1.1 (confidence) = 78.65
    assert_numeric_between "$combined" "77" "80" "Trending: TF-favored combined score with confidence boost"
}

test_combined_score_volatile_reduction() {
    # In volatile market, score gets reduced 20%
    local result=$(apply_regime_weights "TEST_VOL" 60 60 "volatile")
    local combined=$(echo "$result" | grep -o '"combined_score":[0-9.]*' | cut -d: -f2)
    
    # Expected: (60 * 0.5) + (60 * 0.5) = 60, then * 0.8 = 48
    assert_numeric_between "$combined" "47" "49" "Volatile: Score reduced 20% for risk management"
}

# ============================================================================
# Test Suite: JSON Output Validation
# ============================================================================

test_regime_weights_returns_json() {
    local result=$(apply_regime_weights "JSON_TEST" 50 50)
    assert_contains "$result" '"combined_score"' "apply_regime_weights returns JSON"
}

test_regime_weights_has_symbol() {
    local result=$(apply_regime_weights "SYMBOL_TEST" 50 50)
    assert_contains "$result" '"symbol":"SYMBOL_TEST"' "Output includes symbol"
}

test_regime_weights_has_recommendation() {
    local result=$(apply_regime_weights "REC_TEST" 80 20 "sideways")
    assert_contains "$result" '"recommendation"' "Output includes recommendation"
}

test_regime_weights_has_weights_breakdown() {
    local result=$(apply_regime_weights "WEIGHTS_TEST" 60 60)
    assert_contains "$result" '"weights"' "Output includes weights breakdown"
}

test_regime_weights_has_timestamp() {
    local result=$(apply_regime_weights "TIME_TEST" 50 50)
    assert_contains "$result" '"timestamp"' "Output includes timestamp"
}

# ============================================================================
# Test Suite: Strategy Selection
# ============================================================================

test_select_best_strategy_sideways_high_mr() {
    local result=$(select_best_strategy "SELECT_SIDEWAYS" 85 30)
    local strategy=$(echo "$result" | grep -o '"best_strategy":"[^"]*' | cut -d'"' -f4)
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [[ "$strategy" == *"mean_reversion"* ]]; then
        echo -e "${GREEN}✓ PASS${NC}: High MR score in sideways selects mean reversion"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}: Strategy selection based on scores"
        echo "  Got strategy: $strategy"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

test_select_best_strategy_trending_high_tf() {
    # Force trending regime to test TF selection
    clear_regime_cache "SELECT_TREND"
    
    # Create a mock regime scenario by setting test data
    local result=$(apply_regime_weights "SELECT_TREND" 30 85 "trending_bull")
    local recommendation=$(echo "$result" | grep -o '"recommendation":"[^"]*' | cut -d'"' -f4)
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [[ "$recommendation" == *"trend"* || "$recommendation" == *"buy"* ]]; then
        echo -e "${GREEN}✓ PASS${NC}: High TF score in trending recommends trend follow"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}: Recommendation for trending market"
        echo "  Got: $recommendation"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ============================================================================
# Test Suite: Volatility-Adjusted Risk
# ============================================================================

test_adjusted_stop_loss_sideways() {
    local adjusted=$(calculate_adjusted_stop_loss "sideways" 3.0 30)
    assert_numeric_between "$adjusted" "2.9" "3.1" "Sideways market stop-loss unchanged"
}

test_adjusted_stop_loss_trending() {
    local adjusted=$(calculate_adjusted_stop_loss "trending_bull" 3.0 60)
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if (( $(echo "$adjusted > 3.0" | bc -l) )); then
        echo -e "${GREEN}✓ PASS${NC}: Trending market widens stop-loss"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}: Trending market stop-loss adjustment"
        echo "  Expected > 3.0, got: $adjusted"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

test_adjusted_stop_loss_volatile() {
    local adjusted=$(calculate_adjusted_stop_loss "volatile" 3.0 50)
    assert_numeric_between "$adjusted" "4.9" "5.1" "Volatile market increases stop-loss by 2%"
}

# ============================================================================
# Test Suite: Regime Change Detection
# ============================================================================

test_regime_change_detection_no_change() {
    local result=$(detect_regime_change "NO_CHANGE" "sideways")
    local changed=$(echo "$result" | grep -o '"changed":[a-z]*' | cut -d: -f2)
    
    # Depends on what regime detector returns, but structure should be valid
    assert_contains "$result" '"changed"' "Regime change detection returns changed field"
}

test_regime_change_action_triggered() {
    local result=$(detect_regime_change "CHANGE_TEST" "sideways")
    assert_contains "$result" '"action"' "Regime change detection returns action field"
}

# ============================================================================
# Test Suite: Win Rate Improvement Estimation
# ============================================================================

test_win_rate_improvement_sideways() {
    local improvement=$(estimate_win_rate_improvement "sideways" 50)
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    # Should be between 50% and 56% (base 50 + 3-5% improvement)
    if (( $(echo "$improvement >= 52 && $improvement <= 56" | bc -l) )); then
        echo -e "${GREEN}✓ PASS${NC}: Sideways regime estimated +3-5% win rate improvement"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}: Win rate improvement calculation"
        echo "  Got: $improvement"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

test_win_rate_improvement_trending() {
    local improvement=$(estimate_win_rate_improvement "trending_bull" 50)
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    # Should be between 50% and 56% (base 50 + 4-5% improvement)
    if (( $(echo "$improvement >= 53 && $improvement <= 56" | bc -l) )); then
        echo -e "${GREEN}✓ PASS${NC}: Trending regime estimated +4-5% win rate improvement"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}: Trending win rate improvement"
        echo "  Got: $improvement"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ============================================================================
# Test Suite: Edge Cases
# ============================================================================

test_score_clamping_high() {
    local result=$(apply_regime_weights "CLAMP_HIGH" 150 150)
    local combined=$(echo "$result" | grep -o '"combined_score":[0-9.]*' | cut -d: -f2)
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if (( $(echo "$combined <= 100" | bc -l) )); then
        echo -e "${GREEN}✓ PASS${NC}: High scores clamped to max range"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}: Score clamping"
        echo "  Expected <= 100, got: $combined"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

test_score_clamping_low() {
    local result=$(apply_regime_weights "CLAMP_LOW" -50 -50)
    local combined=$(echo "$result" | grep -o '"combined_score":[0-9.]*' | cut -d: -f2)
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if (( $(echo "$combined >= 0" | bc -l) )); then
        echo -e "${GREEN}✓ PASS${NC}: Negative scores clamped to 0"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}: Negative score handling"
        echo "  Expected >= 0, got: $combined"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ============================================================================
# Integration Tests
# ============================================================================

test_integration_full_weighting_workflow() {
    # Simulate complete workflow: detect regime, weight scores, get recommendation
    local result=$(apply_regime_weights "INTEGRATION_FULL" 65 45)
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    # Check for all critical fields
    if echo "$result" | grep -q '"combined_score"' && \
       echo "$result" | grep -q '"recommendation"' && \
       echo "$result" | grep -q '"regime"'; then
        echo -e "${GREEN}✓ PASS${NC}: Complete weighting workflow produces all required outputs"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}: Integration workflow completeness"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ============================================================================
# Run All Tests
# ============================================================================

echo "=========================================="
echo "  Regime Weighting Unit Tests"
echo "=========================================="
echo ""

echo "Regime Weights Configuration:"
test_sideways_weights
test_trending_bull_weights
test_trending_bear_weights
test_volatile_weights

echo ""
echo "Confidence Multiplier Tests:"
test_confidence_multiplier_sideways
test_confidence_multiplier_trending_bull
test_confidence_multiplier_volatile_low
test_confidence_multiplier_volatile_high

echo ""
echo "Combined Score Calculation Tests:"
test_combined_score_sideways_mean_reversion
test_combined_score_trending_trend_follow
test_combined_score_volatile_reduction

echo ""
echo "JSON Output Validation:"
test_regime_weights_returns_json
test_regime_weights_has_symbol
test_regime_weights_has_recommendation
test_regime_weights_has_weights_breakdown
test_regime_weights_has_timestamp

echo ""
echo "Strategy Selection Tests:"
test_select_best_strategy_sideways_high_mr
test_select_best_strategy_trending_high_tf

echo ""
echo "Volatility-Adjusted Risk Tests:"
test_adjusted_stop_loss_sideways
test_adjusted_stop_loss_trending
test_adjusted_stop_loss_volatile

echo ""
echo "Regime Change Detection Tests:"
test_regime_change_detection_no_change
test_regime_change_action_triggered

echo ""
echo "Win Rate Improvement Tests:"
test_win_rate_improvement_sideways
test_win_rate_improvement_trending

echo ""
echo "Edge Cases Tests:"
test_score_clamping_high
test_score_clamping_low

echo ""
echo "Integration Tests:"
test_integration_full_weighting_workflow

# ============================================================================
# Test Summary
# ============================================================================

echo ""
echo "=========================================="
echo "  Test Summary"
echo "=========================================="
echo "Total Tests:  $TESTS_RUN"
echo -e "Passed:       ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed:       ${RED}$TESTS_FAILED${NC}"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "\n${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "\n${RED}Some tests failed.${NC}"
    exit 1
fi
