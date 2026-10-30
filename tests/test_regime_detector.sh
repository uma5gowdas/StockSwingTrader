#!/bin/bash
# ============================================================================
# Unit Tests: Regime Detector Module
# ============================================================================
# Tests for: lib/regime_detector.sh
# Coverage: Market regime detection, cache management, trend analysis
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

# Isolate the regime cache so results from earlier runs (15 min TTL) or
# other processes never leak into these tests.
export REGIME_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sst_regime_test.XXXXXX")"
trap 'rm -rf "$REGIME_CACHE_DIR"' EXIT

# Source modules under test
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
# Test Suite: Trend Direction Detection
# ============================================================================

test_trend_direction_uptrend() {
    local result=$(detect_trend_direction 102.5 100.0)
    assert_equals "up" "$result" "Trend direction: EMA20 > EMA50 should be uptrend"
}

test_trend_direction_downtrend() {
    local result=$(detect_trend_direction 98.5 100.0)
    assert_equals "down" "$result" "Trend direction: EMA20 < EMA50 should be downtrend"
}

test_trend_direction_neutral() {
    local result=$(detect_trend_direction 100.0 100.0)
    assert_equals "neutral" "$result" "Trend direction: EMA20 = EMA50 should be neutral"
}

# ============================================================================
# Test Suite: Bollinger Bands Volatility
# ============================================================================

test_bb_width_calculation() {
    # BB width = (upper - lower) / middle * 100
    local result=$(calc_bb_width_pct 110.0 100.0 90.0)
    # (110 - 90) / 100 * 100 = 20%
    assert_numeric_between "$result" "19.5" "20.5" "BB width calculation"
}

test_bb_width_tight_bands() {
    local result=$(calc_bb_width_pct 102.0 100.0 98.0)
    # (102 - 98) / 100 * 100 = 4%
    assert_numeric_between "$result" "3.5" "4.5" "BB width with tight bands"
}

# ============================================================================
# Test Suite: ADX Approximation
# ============================================================================

test_adx_approx_uptrend() {
    # EMA20 significantly above EMA50 = strong uptrend = high ADX
    local -a prices=(95 96 97 98 99 100 101 102 103 104 105 106 107 108 109 110)
    local result=$(calc_adx_approx 108 100 "${prices[@]}")
    
    # Should be > 30 for strong trend
    assert_numeric_between "$result" "30" "100" "ADX approximation for strong uptrend"
}

test_adx_approx_sideways() {
    # EMA20 close to EMA50 = low trend strength = low ADX
    local -a prices=(100 100.5 100 100.3 100 100.2 100 100.1 100 100.2)
    local result=$(calc_adx_approx 100.2 100.0 "${prices[@]}")
    
    # Should be < 20 for sideways market
    assert_numeric_between "$result" "0" "20" "ADX approximation for sideways market"
}

# ============================================================================
# Test Suite: Market Regime Detection
# ============================================================================

test_regime_detection_returns_json() {
    local result=$(detect_market_regime "AAPL")
    assert_contains "$result" '"regime"' "Regime detection returns JSON with regime field"
}

test_regime_detection_has_adx() {
    local result=$(detect_market_regime "GOOGL")
    assert_contains "$result" '"adx"' "Regime detection includes ADX"
}

test_regime_detection_has_trend() {
    local result=$(detect_market_regime "MSFT")
    assert_contains "$result" '"trend"' "Regime detection includes trend direction"
}

test_regime_detection_has_volatility() {
    local result=$(detect_market_regime "TSLA")
    assert_contains "$result" '"volatility"' "Regime detection includes volatility"
}

test_regime_is_valid_type() {
    local result=$(detect_market_regime "GOOG")
    local regime=$(echo "$result" | jq -r '.regime')
    
    # Check if regime is one of valid types
    case "$regime" in
        sideways|trending_bull|trending_bear|volatile)
            assert_equals "$regime" "$regime" "Regime is valid type"
            ;;
        *)
            echo -e "${RED}✗ FAIL${NC}: Regime is valid type"
            echo "  Got invalid regime: $regime"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            TESTS_RUN=$((TESTS_RUN + 1))
            ;;
    esac
}

# ============================================================================
# Test Suite: Cache Management
# ============================================================================

test_cache_file_creation() {
    local symbol="TEST_SYM"
    clear_regime_cache "$symbol"  # Clean first
    
    detect_market_regime "$symbol" > /dev/null
    
    local cache_file=$(get_regime_cache_file "$symbol")
    if [[ -f "$cache_file" ]]; then
        echo -e "${GREEN}✓ PASS${NC}: Cache file creation"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}: Cache file creation"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
}

test_cache_validity_check() {
    local symbol="CACHE_TEST"
    clear_regime_cache "$symbol"
    
    # Create cache
    detect_market_regime "$symbol" > /dev/null
    
    # Should be valid immediately
    if is_regime_cache_valid "$symbol"; then
        echo -e "${GREEN}✓ PASS${NC}: Cache validity check returns true for fresh cache"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}: Cache validity check returns true for fresh cache"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
    
    # Clean up
    clear_regime_cache "$symbol"
}

test_cache_loading() {
    local symbol="LOAD_TEST"
    clear_regime_cache "$symbol"
    
    # Create and save
    local regime1=$(detect_market_regime "$symbol")
    
    # Load from cache
    local regime2=$(load_regime_from_cache "$symbol")
    
    if [[ -n "$regime2" ]]; then
        echo -e "${GREEN}✓ PASS${NC}: Cache loading returns cached data"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}: Cache loading returns cached data"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
    
    # Clean up
    clear_regime_cache "$symbol"
}

# ============================================================================
# Test Suite: Batch Operations
# ============================================================================

test_batch_regimes_returns_array() {
    local result=$(detect_regimes_batch "AAPL GOOGL MSFT")
    assert_contains "$result" "[" "Batch regime detection returns array"
}

test_batch_regimes_multiple_symbols() {
    local result=$(detect_regimes_batch "TEST1,TEST2,TEST3")
    local count=$(echo "$result" | jq 'length' 2>/dev/null)
    
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$count" == "3" ]]; then
        echo -e "${GREEN}✓ PASS${NC}: Batch regime detection processes multiple symbols"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}: Batch regime detection processes multiple symbols"
        echo "  Expected a JSON array of 3 regimes, got: $count"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ============================================================================
# Test Suite: Edge Cases
# ============================================================================

test_regime_with_empty_symbol() {
    local result=$(detect_market_regime "")
    assert_contains "$result" '"error"' "Empty symbol returns error"
}

test_regime_with_invalid_lookback() {
    # Should still work with large lookback
    local result=$(detect_market_regime "AAPL" 100)
    assert_contains "$result" '"regime"' "Large lookback period handled"
}

# ============================================================================
# Integration Tests
# ============================================================================

test_integration_regime_signals_for_trading() {
    local regime_json=$(detect_market_regime "INTEGRATION_TEST")
    local regime=$(echo "$regime_json" | jq -r '.regime')
    local adx=$(echo "$regime_json" | jq -r '.adx')
    local trend=$(echo "$regime_json" | jq -r '.trend')
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    # Check all required fields are present and reasonable
    if [[ -n "$regime" && -n "$adx" && -n "$trend" ]]; then
        echo -e "${GREEN}✓ PASS${NC}: Regime data complete for trading decisions"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}: Regime data complete for trading decisions"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ============================================================================
# Run All Tests
# ============================================================================

echo "=========================================="
echo "  Regime Detector Unit Tests"
echo "=========================================="
echo ""

test_trend_direction_uptrend
test_trend_direction_downtrend
test_trend_direction_neutral

echo ""
echo "Bollinger Bands Volatility Tests:"
test_bb_width_calculation
test_bb_width_tight_bands

echo ""
echo "ADX Approximation Tests:"
test_adx_approx_uptrend
test_adx_approx_sideways

echo ""
echo "Market Regime Detection Tests:"
test_regime_detection_returns_json
test_regime_detection_has_adx
test_regime_detection_has_trend
test_regime_detection_has_volatility
test_regime_is_valid_type

echo ""
echo "Cache Management Tests:"
test_cache_file_creation
test_cache_validity_check
test_cache_loading

echo ""
echo "Batch Operations Tests:"
test_batch_regimes_returns_array
test_batch_regimes_multiple_symbols

echo ""
echo "Edge Cases Tests:"
test_regime_with_empty_symbol
test_regime_with_invalid_lookback

echo ""
echo "Integration Tests:"
test_integration_regime_signals_for_trading

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
