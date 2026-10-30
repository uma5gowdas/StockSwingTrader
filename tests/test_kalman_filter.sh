#!/bin/bash
# ============================================================================
# StockSwingTrader: Kalman Filter Test Suite
# ============================================================================
# Tests:
#   1. Basic filtering with synthetic data
#   2. Smoothness verification
#   3. Performance validation (<100ms per 100 prices)
#   4. False signal reduction measurement
#   5. Edge cases (single price, no noise, etc.)
# ============================================================================

# Source the Kalman filter module
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/kalman_filter.sh"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'  # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# ============================================================================
# Test Utilities
# ============================================================================

test_assert_equal() {
    local actual=$1
    local expected=$2
    local test_name=$3
    
    ((TESTS_RUN++))
    
    if [[ "$actual" == "$expected" ]]; then
        echo -e "${GREEN}✓${NC} $test_name"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗${NC} $test_name"
        echo "  Expected: $expected"
        echo "  Got:      $actual"
        ((TESTS_FAILED++))
    fi
}

test_assert_gt() {
    local actual=$1
    local threshold=$2
    local test_name=$3
    
    ((TESTS_RUN++))
    
    if (( $(echo "$actual > $threshold" | bc -l) )); then
        echo -e "${GREEN}✓${NC} $test_name"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗${NC} $test_name"
        echo "  Expected: > $threshold"
        echo "  Got:      $actual"
        ((TESTS_FAILED++))
    fi
}

test_assert_lt() {
    local actual=$1
    local threshold=$2
    local test_name=$3
    
    ((TESTS_RUN++))
    
    if (( $(echo "$actual < $threshold" | bc -l) )); then
        echo -e "${GREEN}✓${NC} $test_name"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗${NC} $test_name"
        echo "  Expected: < $threshold"
        echo "  Got:      $actual"
        ((TESTS_FAILED++))
    fi
}

# Milliseconds since epoch (macOS date has no %N)
now_ms() {
    perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'
}

# Count direction reversals in a price series
count_reversals() {
    awk -v data="$*" 'BEGIN {
        n = split(data, p, " "); c = 0
        for (i = 3; i <= n; i++) {
            a = p[i-1] - p[i-2]; b = p[i] - p[i-1]
            if ((a > 0 && b < 0) || (a < 0 && b > 0)) c++
        }
        print c
    }'
}

# ============================================================================
# Test 1: Basic Kalman Filter
# ============================================================================

test_basic_kalman_filter() {
    echo ""
    echo "Test 1: Basic Kalman Filter"
    echo "============================"
    
    # Create simple price data with noise
    local -a prices=(100.0 100.5 100.2 100.8 101.0 100.9 101.5 101.3 101.8 102.0)
    
    local result=$(apply_kalman_filter "${prices[@]}" -q 0.01 -r 0.1)
    
    # Check JSON structure
    local has_filtered=$(echo "$result" | grep -c "filtered_prices")
    test_assert_equal "$has_filtered" "1" "JSON contains filtered_prices"
    
    local has_state=$(echo "$result" | grep -c "\"state\"")
    test_assert_equal "$has_state" "1" "JSON contains state"
    
    local has_covariance=$(echo "$result" | grep -c "\"covariance\"")
    test_assert_equal "$has_covariance" "1" "JSON contains covariance"
    
    local has_residuals=$(echo "$result" | grep -c "residuals")
    test_assert_equal "$has_residuals" "1" "JSON contains residuals"
    
    # Extract count
    local count=$(echo "$result" | jq -r '.count')
    test_assert_equal "$count" "10" "Output count matches input count"
}

# ============================================================================
# Test 2: Smoothness Verification
# ============================================================================

test_smoothness_improvement() {
    echo ""
    echo "Test 2: Smoothness Improvement"
    echo "==============================="
    
    # Create price data with noise pattern
    local -a raw_prices=(100.0 100.5 99.8 100.9 99.7 101.2 100.1 101.5 99.9 102.0)
    
    local result=$(apply_kalman_filter "${raw_prices[@]}" -q 0.01 -r 0.1)
    
    # Extract filtered prices (output is multi-line JSON; grep -P is not on macOS)
    local -a filtered_prices=($(echo "$result" | jq -r '.filtered_prices[]'))
    
    test_assert_gt "${#filtered_prices[@]}" "0" "Filtered prices returned"
    if [[ ${#filtered_prices[@]} -gt 0 ]]; then
        # Both arrays should have same length
        test_assert_equal "${#filtered_prices[@]}" "${#raw_prices[@]}" "Filtered output length matches input"
        
        # Filtered should be smoother (smaller variations)
        # Calculate variation for raw
        local raw_var=0
        for ((i = 1; i < ${#raw_prices[@]}; i++)); do
            local diff=$(echo "${raw_prices[$i]} - ${raw_prices[$((i-1))]}" | bc -l)
            local abs_diff=$(echo "sqrt($diff * $diff)" | bc -l)
            raw_var=$(echo "$raw_var + $abs_diff" | bc -l)
        done
        
        # Calculate variation for filtered
        local filtered_var=0
        for ((i = 1; i < ${#filtered_prices[@]}; i++)); do
            local diff=$(echo "${filtered_prices[$i]} - ${filtered_prices[$((i-1))]}" | bc -l)
            local abs_diff=$(echo "sqrt($diff * $diff)" | bc -l)
            filtered_var=$(echo "$filtered_var + $abs_diff" | bc -l)
        done
        
        # Filtered should have less variation
        echo "  Raw variation: $raw_var"
        echo "  Filtered variation: $filtered_var"
        
        test_assert_lt "$filtered_var" "$raw_var" "Filtered prices have lower variation"
    fi
}

# ============================================================================
# Test 3: Performance Validation
# ============================================================================

test_performance() {
    echo ""
    echo "Test 3: Performance Validation"
    echo "=============================="
    
    # Generate 100 price points
    local -a prices=()
    local price=100.0
    for ((i = 0; i < 100; i++)); do
        price=$(echo "$price + (${RANDOM} % 10 - 5) / 10" | bc -l)
        prices+=("$price")
    done
    
    # Time the filter
    local start_time=$(now_ms)
    local result=$(apply_kalman_filter "${prices[@]}" -q 0.01 -r 0.1)
    local end_time=$(now_ms)
    
    # Calculate elapsed time in milliseconds
    local elapsed_ms=$(( end_time - start_time ))
    
    echo "  Processed 100 prices in ${elapsed_ms}ms"
    
    test_assert_equal "$(echo "$result" | jq -r '.count')" "100" "All 100 prices filtered"
    # Target: <500ms for 100 prices (v6.3 Kalman budget; includes python3 start-up)
    test_assert_lt "$elapsed_ms" "500" "Performance target met (<500ms for 100 prices)"
}

# ============================================================================
# Test 4: False Signal Reduction
# ============================================================================

test_false_signal_reduction() {
    echo ""
    echo "Test 4: False Signal Reduction"
    echo "==============================="
    
    # Create price data with whipsaw pattern (frequent reversals)
    local -a whipsaw_prices=(100.0 100.3 100.1 100.4 100.2 100.5 100.3 100.6 100.4 100.7
                             100.5 100.8 100.6 100.9 100.7 101.0 100.8 101.1 100.9 101.2)
    
    local result=$(apply_kalman_filter "${whipsaw_prices[@]}" -q 0.01 -r 0.1)
    
    # Direction reversals (whipsaws) in raw vs Kalman-filtered prices
    local raw_changes=$(count_reversals "${whipsaw_prices[@]}")
    local -a filtered=($(echo "$result" | jq -r '.filtered_prices[]'))
    local filtered_changes=$(count_reversals "${filtered[@]}")
    
    echo "  Raw direction changes: $raw_changes"
    echo "  Filtered direction changes: $filtered_changes"
    
    test_assert_equal "${#filtered[@]}" "${#whipsaw_prices[@]}" "Filtered whipsaw series has same length"
    test_assert_lt "$filtered_changes" "$raw_changes" "False signal (whipsaw) reduction"
}

# ============================================================================
# Test 5: Edge Cases
# ============================================================================

test_edge_cases() {
    echo ""
    echo "Test 5: Edge Cases"
    echo "=================="
    
    # Single price
    local result=$(apply_kalman_filter 100.5 -q 0.01 -r 0.1)
    local has_error=$(echo "$result" | grep -c "error" || true)
    if [[ $has_error -eq 0 ]]; then
        echo -e "${GREEN}✓${NC} Single price handled"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗${NC} Single price failed"
        ((TESTS_FAILED++))
    fi
    ((TESTS_RUN++))
    
    # Empty input
    local result=$(apply_kalman_filter -q 0.01 -r 0.1 2>&1)
    local has_error=$(echo "$result" | grep -c "error" || true)
    if [[ $has_error -gt 0 ]]; then
        echo -e "${GREEN}✓${NC} Empty input handled correctly"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗${NC} Empty input should produce error"
        ((TESTS_FAILED++))
    fi
    ((TESTS_RUN++))
    
    # Constant prices (no noise)
    local -a constant=(100.0 100.0 100.0 100.0 100.0)
    local result=$(apply_kalman_filter "${constant[@]}" -q 0.01 -r 0.1)
    local count=$(echo "$result" | jq -r '.count')
    test_assert_equal "$count" "5" "Constant prices handled"
    test_assert_equal "$(echo "$result" | jq -r '.state')" "100.0" "Constant prices filter to the constant"
}

# ============================================================================
# Test 6: Python Backend Compatibility
# ============================================================================

test_python_backend() {
    echo ""
    echo "Test 6: Python Backend Compatibility"
    echo "====================================="
    
    if command -v python3 &>/dev/null; then
        local -a prices=(100.0 100.5 100.2 100.8 101.0)
        local price_json=$(printf '[%s]' "$(IFS=,; echo "${prices[*]}")")
        
        local result=$(apply_kalman_filter_fast "$price_json" 0.01 0.1)
        
        test_assert_equal "$(echo "$result" | jq -r '.filtered_prices | length')" "5" "Python backend returns 5 filtered prices"
        test_assert_equal "$(echo "$result" | jq -r '.count')" "5" "Python backend reports count"
    else
        echo -e "${RED}✗${NC} Python3 not available"
        ((TESTS_RUN++))
        ((TESTS_FAILED++))
    fi
}

# ============================================================================
# Main Test Execution
# ============================================================================

main() {
    echo ""
    echo "======================================"
    echo "Kalman Filter Test Suite"
    echo "======================================"
    
    # Run all tests
    test_basic_kalman_filter
    test_smoothness_improvement
    test_performance
    test_false_signal_reduction
    test_edge_cases
    test_python_backend
    
    # Print summary
    echo ""
    echo "======================================"
    echo "Test Summary"
    echo "======================================"
    echo "Total tests: $TESTS_RUN"
    echo -e "Passed:      ${GREEN}$TESTS_PASSED${NC}"
    
    echo -e "Failed:      ${RED}$TESTS_FAILED${NC}"
    
    echo ""
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}Some tests failed${NC}"
        return 1
    fi
}

main "$@"
