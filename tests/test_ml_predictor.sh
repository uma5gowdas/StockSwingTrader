#!/bin/bash
# ============================================================================
# StockSwingTrader: ML Predictor Test Suite
# ============================================================================
# Tests Enhancement 1: XGBoost ML Predictor against the real trained model
# (lib/models/xgboost_predictor.pkl) and the real inference code.
# Tests:
#   1. Prediction JSON format from historical OHLCV (--data-file)
#   2. Deterministic predictions (same input -> same output)
#   3. Inference latency
#   4. Error handling (missing file, bad columns, missing args)
#   5. Bash wrapper (lib/ml_predictor.sh)
#
# Runs offline: SST_OFFLINE=1 stops ml_inference.py from calling yfinance.
# ============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "${PROJECT_DIR}/lib/ml_predictor.sh"

export SST_OFFLINE=1

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

ML_MODEL_PATH="${PROJECT_DIR}/lib/models/xgboost_predictor.pkl"
ML_INFERENCE="${PROJECT_DIR}/lib/ml_inference.py"
# Cold python start + xgboost import is ~3s on a laptop; 10s bounds a hang.
LATENCY_LIMIT_MS=10000

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sst_ml_test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
OHLCV_CSV="${TMP_DIR}/ohlcv.csv"
BAD_CSV="${TMP_DIR}/bad.csv"

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

test_assert_json_valid() {
    local json_str=$1 test_name=$2
    if [[ -n "$json_str" ]] && echo "$json_str" | jq -e . > /dev/null 2>&1; then pass "$test_name"
    else fail "$test_name" "Invalid JSON: $json_str"; fi
}

test_assert_has_key() {
    local json_str=$1 key=$2 test_name=$3
    if echo "$json_str" | jq -e "has(\"$key\")" > /dev/null 2>&1; then pass "$test_name"
    else fail "$test_name" "Missing key: $key"; fi
}

# Passes when the jq expression evaluates to true for the JSON
test_assert_jq() {
    local json_str=$1 expr=$2 test_name=$3
    if echo "$json_str" | jq -e "$expr" > /dev/null 2>&1; then pass "$test_name"
    else fail "$test_name" "jq '$expr' was not true for: $json_str"; fi
}

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }

# 60 daily bars of a deterministic upward random walk
write_fixture_csv() {
    awk 'BEGIN {
        srand(42); p = 100
        print "Open,High,Low,Close,Volume"
        for (i = 0; i < 60; i++) {
            p = p * (1 + (rand() - 0.45) * 0.02)
            printf "%.2f,%.2f,%.2f,%.2f,%d\n", p * 0.999, p * 1.01, p * 0.99, p, 1000000 + i * 1000
        }
    }' > "$OHLCV_CSV"
    printf 'Date,Price\n2024-01-01,100\n' > "$BAD_CSV"
}

infer() {
    python3 "$ML_INFERENCE" "$@" </dev/null 2>/dev/null
}

# ============================================================================
# Test Cases
# ============================================================================

test_model_present() {
    echo -e "\n${BLUE}=== Test 0: Trained Model ===${NC}"
    if [[ -f "$ML_MODEL_PATH" ]]; then
        pass "Model file present ($ML_MODEL_PATH)"
        return 0
    fi
    fail "Model file present" "Train it first: python3 lib/train_ml_model.py"
    return 1
}

test_ml_json_format() {
    echo -e "\n${BLUE}=== Test 1: ML Prediction JSON Format ===${NC}"

    local result
    result=$(infer --symbol TEST --period 5 --data-file "$OHLCV_CSV")
    test_assert_equal "$?" "0" "Inference exits 0"

    test_assert_json_valid "$result" "Valid JSON output"
    test_assert_has_key "$result" "direction" "Contains 'direction' key"
    test_assert_has_key "$result" "confidence" "Contains 'confidence' key"
    test_assert_has_key "$result" "probability" "Contains 'probability' key"
    test_assert_has_key "$result" "timestamp" "Contains 'timestamp' key"
    test_assert_jq "$result" '.symbol == "TEST" and .period == 5' "Echoes symbol and period"
    test_assert_jq "$result" '.direction == "up" or .direction == "down"' "Direction is 'up' or 'down'"
    test_assert_jq "$result" '.confidence >= 0 and .confidence <= 100' "Confidence in range [0, 100]"
    # Probability is that of the predicted class, so it is at least 0.5
    test_assert_jq "$result" '.probability >= 0.5 and .probability <= 1' "Probability of predicted class in [0.5, 1]"
    test_assert_jq "$result" '.confidence == ((.probability * 100) | floor)' "Confidence equals floor(probability * 100)"
    test_assert_jq "$result" '.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' "Timestamp is ISO 8601 UTC"
}

test_ml_consistency() {
    echo -e "\n${BLUE}=== Test 2: Deterministic Predictions ===${NC}"

    local r1 r2
    r1=$(infer --symbol TEST --data-file "$OHLCV_CSV" | jq -c '{direction, probability}')
    r2=$(infer --symbol TEST --data-file "$OHLCV_CSV" | jq -c '{direction, probability}')
    test_assert_equal "$r2" "$r1" "Same OHLCV data gives the same prediction"

    # No data: synthetic features are seeded per symbol, stable across processes
    r1=$(infer --symbol MSFT | jq -c '{direction, probability}')
    r2=$(infer --symbol MSFT | jq -c '{direction, probability}')
    test_assert_jq "$r1" 'has("direction")' "Synthetic-feature fallback returns a prediction"
    test_assert_equal "$r2" "$r1" "Synthetic-feature fallback is deterministic per symbol"
}

test_ml_inference_latency() {
    echo -e "\n${BLUE}=== Test 3: ML Inference Latency ===${NC}"

    local start_time end_time latency
    start_time=$(now_ms)
    infer --symbol TEST --data-file "$OHLCV_CSV" > /dev/null
    end_time=$(now_ms)
    latency=$((end_time - start_time))
    echo "  Measured: ${latency}ms (includes python3 start-up and model load)"

    if (( latency < LATENCY_LIMIT_MS )); then
        pass "Inference latency < ${LATENCY_LIMIT_MS}ms"
    else
        fail "Inference latency < ${LATENCY_LIMIT_MS}ms" "Measured ${latency}ms"
    fi
}

test_ml_error_handling() {
    echo -e "\n${BLUE}=== Test 4: Error Handling ===${NC}"

    local result rc
    result=$(infer --symbol TEST --data-file "${TMP_DIR}/missing.csv"); rc=$?
    test_assert_equal "$rc" "1" "Missing data file exits 1"
    test_assert_jq "$result" '.error | test("Cannot read data file")' "Missing data file returns JSON error"

    result=$(infer --symbol TEST --data-file "$BAD_CSV"); rc=$?
    test_assert_equal "$rc" "1" "CSV without OHLCV columns exits 1"
    test_assert_jq "$result" '.error | test("missing columns")' "CSV without OHLCV columns returns JSON error"

    python3 "$ML_INFERENCE" </dev/null > /dev/null 2>&1; rc=$?
    test_assert_equal "$rc" "2" "Missing --symbol is rejected (argparse exit 2)"
}

test_ml_wrapper() {
    echo -e "\n${BLUE}=== Test 5: Bash Wrapper (ml_predictor.sh) ===${NC}"

    local result rc
    result=$(ml_predict_direction "AAPL" 5 < "$TMP_DIR/empty_stdin" 2>/dev/null); rc=$?
    test_assert_equal "$rc" "0" "ml_predict_direction exits 0"
    test_assert_json_valid "$result" "ml_predict_direction stdout is pure JSON (warnings on stderr)"
    test_assert_jq "$result" '.symbol == "AAPL" and (.direction == "up" or .direction == "down")' "ml_predict_direction returns a direction for AAPL"

    local err
    err=$(ml_predict_direction "" 2>&1 >/dev/null); rc=$?
    test_assert_equal "$rc" "1" "Empty symbol exits 1"
    test_assert_jq "$err" '.error == "Symbol is required"' "Empty symbol returns JSON error"

    result=$(bash "${PROJECT_DIR}/lib/ml_predictor.sh" predict AAPL 5 </dev/null 2>/dev/null)
    test_assert_jq "$result" '.symbol == "AAPL"' "CLI 'predict' command works"

    result=$(ml_get_model_status)
    test_assert_jq "$result" '.status == "ready" and .size_bytes > 0' "Model status reports ready"
}

# ============================================================================
# Summary
# ============================================================================

print_summary() {
    echo -e "\n${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}        ML Predictor Test Summary${NC}"
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
echo -e "${BLUE}║${NC}    StockSwingTrader: ML Predictor Test Suite${NC}"
echo -e "${BLUE}║${NC}    Enhancement 1: XGBoost ML Predictions${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"

write_fixture_csv
: > "$TMP_DIR/empty_stdin"

if test_model_present; then
    test_ml_json_format
    test_ml_consistency
    test_ml_inference_latency
    test_ml_error_handling
    test_ml_wrapper
fi

print_summary
exit $?
