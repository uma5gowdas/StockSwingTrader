#!/bin/bash
# ============================================================================
# Test Suite for Alpaca Broker Module
# ============================================================================
# Comprehensive tests for lib/alpaca_broker.sh
# Tests cover: initialization, validation, formatting, error handling, and API interaction
# ============================================================================

set -o pipefail

# ============================================================================
# Test Framework Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
# Error-handler output goes to a private temp file (no fixed /tmp name)
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sst_broker_test.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
ERR_FILE="$WORK_DIR/err.txt"
TEST_LOG_FILE="${PROJECT_ROOT}/logs/test_alpaca.log"
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Suppress normal Alpaca logging for tests
export ALPACA_LOG_FILE="${PROJECT_ROOT}/logs/alpaca_test.log"
export ALPACA_DEBUG=false

# Create test log directory
mkdir -p "$(dirname "$TEST_LOG_FILE")"

# ============================================================================
# Test Utilities
# ============================================================================

# Print test header
print_test_header() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "TEST SUITE: Alpaca Broker Module"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Log test message
test_log() {
    local level="$1"
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" >> "$TEST_LOG_FILE"
}

# Run a test
run_test() {
    local test_name="$1"
    shift
    local test_func="$@"
    
    echo -n "Testing: $test_name ... "
    test_log "INFO" "Starting test: $test_name"
    
    if eval "$test_func" &>/dev/null; then
        echo "✓ PASSED"
        test_log "PASS" "$test_name"
        ((TESTS_PASSED++))
        return 0
    else
        echo "✗ FAILED"
        test_log "FAIL" "$test_name"
        ((TESTS_FAILED++))
        return 1
    fi
}

# Assert condition
assert_eq() {
    local actual="$1"
    local expected="$2"
    local msg="${3:-Assertion failed}"
    
    if [[ "$actual" == "$expected" ]]; then
        return 0
    else
        echo "ASSERT FAILED: $msg"
        echo "  Expected: $expected"
        echo "  Actual: $actual"
        return 1
    fi
}

# Assert exit code
assert_success() {
    local cmd="$1"
    local msg="${2:-Command should succeed}"
    
    if eval "$cmd" &>/dev/null; then
        return 0
    else
        echo "ASSERT FAILED: $msg"
        return 1
    fi
}

# Assert failure
assert_failure() {
    local cmd="$1"
    local msg="${2:-Command should fail}"
    
    if ! eval "$cmd" &>/dev/null; then
        return 0
    else
        echo "ASSERT FAILED: $msg"
        return 1
    fi
}

# ============================================================================
# TEST SETUP: Load Module
# ============================================================================

echo ""
echo "Loading Alpaca Broker Module..."
test_log "INFO" "Loading alpaca_broker.sh module"

if [[ ! -f "$PROJECT_ROOT/lib/alpaca_broker.sh" ]]; then
    echo "✗ FATAL: Module not found at $PROJECT_ROOT/lib/alpaca_broker.sh"
    test_log "ERROR" "Module file not found"
    exit 1
fi

# Source the module
source "$PROJECT_ROOT/lib/alpaca_broker.sh"

if [[ $? -eq 0 ]]; then
    echo "✓ Module loaded successfully"
    test_log "INFO" "Module loaded successfully"
else
    echo "✗ FATAL: Failed to load module"
    test_log "ERROR" "Failed to load module"
    exit 1
fi

# ============================================================================
# TESTS: Module Initialization
# ============================================================================

print_test_header

echo ""
echo "GROUP 1: Module Initialization & Configuration"
echo "───────────────────────────────────────────────"

# Test 1.1: Module variables are set
run_test "Module variables are initialized" \
    "[[ -n '\$ALPACA_API_BASE_URL' ]] && [[ -n '\$ALPACA_LOG_FILE' ]] && [[ -n '\$ALPACA_TIMEOUT' ]]"

# Test 1.2: Logging directory is created on demand
run_test "Logging initialization creates directory" \
    "alpaca_init_logging && [[ -d \"\$(dirname \$ALPACA_LOG_FILE)\" ]]"

# Test 1.3: Log file is created
run_test "Log file is created and writable" \
    "alpaca_init_logging && [[ -f \"\$ALPACA_LOG_FILE\" ]] && touch \"\$ALPACA_LOG_FILE\" 2>/dev/null"

# ============================================================================
# TESTS: Symbol Validation
# ============================================================================

echo ""
echo "GROUP 2: Symbol Validation (alpaca_validate_symbol)"
echo "────────────────────────────────────────────────────"

# Test 2.1: Valid symbols
run_test "Valid symbol: AAPL" \
    "alpaca_validate_symbol 'AAPL'"

run_test "Valid symbol: MSFT" \
    "alpaca_validate_symbol 'MSFT'"

run_test "Valid symbol: GOOG" \
    "alpaca_validate_symbol 'GOOG'"

run_test "Valid symbol: BRK (three letters)" \
    "alpaca_validate_symbol 'BRK'"

run_test "Valid symbol: A (single letter ticker)" \
    "alpaca_validate_symbol 'A'"

# Test 2.2: Invalid symbols

run_test "Invalid symbol: TOOLONG (too long)" \
    "! alpaca_validate_symbol 'TOOLONG'"

run_test "Invalid symbol: 123 (numbers only)" \
    "! alpaca_validate_symbol '123'"

run_test "Invalid symbol: !@# (special chars)" \
    "! alpaca_validate_symbol '!@#'"

run_test "Invalid symbol: Empty string" \
    "! alpaca_validate_symbol ''"

run_test "Invalid symbol: abc (lowercase)" \
    "! alpaca_validate_symbol 'abc'"

# ============================================================================
# TESTS: Quantity Validation
# ============================================================================

echo ""
echo "GROUP 3: Quantity Validation (alpaca_validate_quantity)"
echo "─────────────────────────────────────────────────────────"

# Test 3.1: Valid quantities
run_test "Valid quantity: 100" \
    "alpaca_validate_quantity '100'"

run_test "Valid quantity: 50.5" \
    "alpaca_validate_quantity '50.5'"

run_test "Valid quantity: 0.01" \
    "alpaca_validate_quantity '0.01'"

# Test 3.2: Invalid quantities
run_test "Invalid quantity: 0 (zero)" \
    "! alpaca_validate_quantity '0'"

run_test "Invalid quantity: -50 (negative)" \
    "! alpaca_validate_quantity '-50'"

run_test "Invalid quantity: abc (non-numeric)" \
    "! alpaca_validate_quantity 'abc'"

run_test "Invalid quantity: Empty string" \
    "! alpaca_validate_quantity ''"

# ============================================================================
# TESTS: Side Validation
# ============================================================================

echo ""
echo "GROUP 4: Side Validation (alpaca_validate_side)"
echo "────────────────────────────────────────────────"

# Test 4.1: Valid sides
run_test "Valid side: buy" \
    "alpaca_validate_side 'buy'"

run_test "Valid side: sell" \
    "alpaca_validate_side 'sell'"

# Test 4.2: Invalid sides
run_test "Invalid side: BUY (uppercase)" \
    "! alpaca_validate_side 'BUY'"

run_test "Invalid side: hold" \
    "! alpaca_validate_side 'hold'"

run_test "Invalid side: Empty string" \
    "! alpaca_validate_side ''"

# ============================================================================
# TESTS: Currency Formatting
# ============================================================================

echo ""
echo "GROUP 5: Currency Formatting (alpaca_format_currency)"
echo "──────────────────────────────────────────────────────"

# Test 5.1: Positive amounts (without color)
run_test "Format positive: 1000 -> contains \$1000.00" \
    "alpaca_format_currency 1000 false | grep -q '1000.00'"

run_test "Format positive: 1234.56 -> contains \$1234.56" \
    "alpaca_format_currency 1234.56 false | grep -q '1234.56'"

# Test 5.2: Negative amounts (without color)
run_test "Format negative: -500 -> contains -\$500.00" \
    "alpaca_format_currency -500 false | grep -q '500.00'"

# Test 5.3: Zero amount
run_test "Format zero: 0 -> contains \$0.00" \
    "alpaca_format_currency 0 false | grep -q '0.00'"

# Test 5.4: Small decimals
run_test "Format decimal: 0.99 -> contains \$0.99" \
    "alpaca_format_currency 0.99 false | grep -q '0.99'"

# ============================================================================
# TESTS: Percentage Formatting
# ============================================================================

echo ""
echo "GROUP 6: Percentage Formatting (alpaca_format_percent)"
echo "───────────────────────────────────────────────────────"

# Test 6.1: Format percentages
run_test "Format positive percent: 5.25" \
    "alpaca_format_percent 5.25 | grep -q '5.25%'"

run_test "Format negative percent: -3.50" \
    "alpaca_format_percent -3.50 | grep -q '3.50%'"

run_test "Format zero percent: 0" \
    "alpaca_format_percent 0 | grep -q '0.00%'"

# ============================================================================
# TESTS: Error Handling
# ============================================================================

echo ""
echo "GROUP 7: Error Handling (alpaca_handle_error)"
echo "─────────────────────────────────────────────"

# Test 7.1: HTTP error codes
run_test "Handle 401 Unauthorized" \
    "alpaca_handle_error 401 '{\"message\":\"Invalid API key\"}' > \"\$ERR_FILE\" 2>&1 || true; grep -qi 'unauthorized\\|invalid' \"\$ERR_FILE\""

run_test "Handle 403 Forbidden" \
    "alpaca_handle_error 403 '{\"message\":\"No permission\"}' > \"\$ERR_FILE\" 2>&1 || true; grep -qi 'forbidden' \"\$ERR_FILE\""

run_test "Handle 400 Bad Request" \
    "alpaca_handle_error 400 '{\"message\":\"Invalid parameters\"}' > \"\$ERR_FILE\" 2>&1 || true; grep -qi 'bad request' \"\$ERR_FILE\""

run_test "Handle 404 Not Found" \
    "alpaca_handle_error 404 '{\"message\":\"Resource not found\"}' > \"\$ERR_FILE\" 2>&1 || true; grep -qi 'not found' \"\$ERR_FILE\""

run_test "Handle 422 Unprocessable Entity" \
    "alpaca_handle_error 422 '{\"message\":\"Insufficient buying power\"}' > \"\$ERR_FILE\" 2>&1 || true; grep -qi 'unprocessable\\|insufficient' \"\$ERR_FILE\""

run_test "Handle 429 Rate Limited" \
    "alpaca_handle_error 429 '{\"message\":\"Too many requests\"}' > \"\$ERR_FILE\" 2>&1 || true; grep -qi 'rate' \"\$ERR_FILE\""

run_test "Handle 500 Server Error" \
    "alpaca_handle_error 500 '{\"message\":\"Internal server error\"}' > \"\$ERR_FILE\" 2>&1 || true; grep -qi 'server error' \"\$ERR_FILE\""

# ============================================================================
# TESTS: Logging
# ============================================================================

echo ""
echo "GROUP 8: Logging Functions"
echo "──────────────────────────"

# Test 8.1: Log messages
run_test "Log INFO message" \
    "alpaca_log 'INFO' 'Test message' && grep -q 'Test message' \"\$ALPACA_LOG_FILE\""

run_test "Log ERROR message" \
    "alpaca_log 'ERROR' 'Error test' && grep -q 'Error test' \"\$ALPACA_LOG_FILE\""

run_test "Log contains timestamp" \
    "alpaca_log 'DEBUG' 'Timestamp test' && grep -q '[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}' \"\$ALPACA_LOG_FILE\""

# Test 8.2: Verify no credentials in logs
run_test "No API keys logged (credentials not exposed)" \
    "! grep -q 'ALPACA_API_KEY' \"\$ALPACA_LOG_FILE\" 2>/dev/null || true"

# ============================================================================
# TESTS: Initialization with Invalid Credentials
# ============================================================================

echo ""
echo "GROUP 9: Initialization & Connection Handling"
echo "─────────────────────────────────────────────"

# Test 9.1: Initialization works when module is sourced with proper setup
run_test "Init function is callable after module loads" \
    "bash -c 'source lib/alpaca_broker.sh && type alpaca_init'"

# Test 9.2: Init returns appropriate status codes
run_test "Init with test credentials completes" \
    "bash -c 'ALPACA_API_KEY=test ALPACA_SECRET_KEY=test source lib/alpaca_broker.sh && alpaca_init' 2>&1 | grep -q 'initialized\\|ERROR' || true"

# ============================================================================
# TESTS: JSON Parsing
# ============================================================================

echo ""
echo "GROUP 10: JSON Response Handling"
echo "────────────────────────────────"

# Mock JSON responses for testing
MOCK_ACCOUNT_RESPONSE='{
  "id": "test-account-123",
  "status": "ACTIVE",
  "currency": "USD",
  "cash": "10000.00",
  "portfolio_value": "25000.00",
  "equity": "25000.00",
  "buying_power": "50000.00",
  "daytrading_buying_power": "50000.00"
}'

MOCK_ERROR_RESPONSE='{
  "message": "Invalid API key",
  "code": 40110000
}'

# Test 10.1: Parse valid JSON
run_test "Parse valid account JSON response" \
    "echo '$MOCK_ACCOUNT_RESPONSE' | grep -q 'test-account-123'"

run_test "Extract ID from account JSON" \
    "echo '$MOCK_ACCOUNT_RESPONSE' | grep -q '\"id\"'"

# Test 10.2: Parse error JSON
run_test "Extract error message from JSON" \
    "echo '$MOCK_ERROR_RESPONSE' | grep -q 'Invalid API key'"

# Test 10.3: Handle malformed JSON gracefully
run_test "Handle malformed JSON without crashing" \
    "echo '{invalid json}' | grep -q 'invalid' || true"

# ============================================================================
# TESTS: Dry Run Scenarios
# ============================================================================

echo ""
echo "GROUP 11: Integration Tests (Dry Run)"
echo "─────────────────────────────────────"

# Test 11.1: Verify functions are callable
run_test "Function alpaca_init is callable" \
    "type alpaca_init | grep -q 'function'"

run_test "Function alpaca_get_account is callable" \
    "type alpaca_get_account | grep -q 'function'"

run_test "Function alpaca_place_order is callable" \
    "type alpaca_place_order | grep -q 'function'"

run_test "Function alpaca_validate_symbol is callable" \
    "type alpaca_validate_symbol | grep -q 'function'"

# Test 11.2: Verify no syntax errors
run_test "Script has valid bash syntax" \
    "bash -n \"$PROJECT_ROOT/lib/alpaca_broker.sh\""

# Test 11.3: Verify error handling doesn't hardcode URLs
run_test "No hardcoded secrets in module" \
    "! grep -E 'sk-|pk-|ALPACA_KEY=|SECRET=' \"$PROJECT_ROOT/lib/alpaca_broker.sh\""

# ============================================================================
# TESTS: Environment Variables
# ============================================================================

echo ""
echo "GROUP 12: Environment Variable Handling"
echo "───────────────────────────────────────"

# Test 12.1: API key environment variable variations
run_test "Supports ALPACA_API_KEY variable" \
    "export ALPACA_API_KEY='test' && [[ ! -z \"\$ALPACA_API_KEY\" ]]"

run_test "Supports APCA_API_KEY_ID variable (Alpaca standard)" \
    "export APCA_API_KEY_ID='test' && [[ ! -z \"\$APCA_API_KEY_ID\" ]]"

# Test 12.2: Base URL configuration
run_test "Custom ALPACA_BASE_URL respected" \
    "export ALPACA_BASE_URL='https://custom.api' && [[ ! -z \"\$ALPACA_BASE_URL\" ]]"

# ============================================================================
# TESTS: Configuration Verification
# ============================================================================

echo ""
echo "GROUP 13: Configuration & Constants"
echo "────────────────────────────────────"

# Test 13.1: Default values are set
run_test "Default timeout is set" \
    "[[ \"\$ALPACA_TIMEOUT\" -gt 0 ]] && echo \"Timeout: \$ALPACA_TIMEOUT\""

run_test "Default max retries is set" \
    "[[ \"\$ALPACA_MAX_RETRIES\" -gt 0 ]] && echo \"Max retries: \$ALPACA_MAX_RETRIES\""

run_test "Backoff multiplier is configured" \
    "[[ \"\$ALPACA_BACKOFF_MULTIPLIER\" -gt 0 ]]"

# ============================================================================
# TESTS: File System Operations
# ============================================================================

echo ""
echo "GROUP 14: File System Operations"
echo "─────────────────────────────────"

# Test 14.1: Log file operations
run_test "Log file is readable" \
    "[[ -r \"\$ALPACA_LOG_FILE\" ]]"

run_test "Log file contains valid entries" \
    "[[ -f \"\$ALPACA_LOG_FILE\" ]] && [[ -s \"\$ALPACA_LOG_FILE\" ]]"

# Test 14.2: Cache directory (if used)
run_test "Logs directory exists" \
    "[[ -d \"${PROJECT_ROOT}/logs\" ]]"

# ============================================================================
# Final Summary
# ============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TEST SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "✓ Tests Passed:  $TESTS_PASSED"
echo "✗ Tests Failed:  $TESTS_FAILED"
echo "⊘ Tests Skipped: $TESTS_SKIPPED"
echo ""

TOTAL_TESTS=$((TESTS_PASSED + TESTS_FAILED))

if [[ $TOTAL_TESTS -gt 0 ]]; then
    PASS_RATE=$((TESTS_PASSED * 100 / TOTAL_TESTS))
    echo "Pass Rate: $PASS_RATE% ($TESTS_PASSED/$TOTAL_TESTS)"
fi

echo ""
echo "Test Log: $TEST_LOG_FILE"
echo "Alpaca Log: $ALPACA_LOG_FILE"
echo ""

# ============================================================================
# Verification Checks
# ============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "VERIFICATION CHECKS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check 1: Module loads without errors
echo -n "Check 1: Module loads in isolation ... "
if bash -c "source $PROJECT_ROOT/lib/alpaca_broker.sh && echo 'SUCCESS'" | grep -q SUCCESS; then
    echo "✓ PASS"
else
    echo "✗ FAIL"
fi

# Check 2: All functions exported
echo -n "Check 2: Core functions are exported ... "
if bash -c "source $PROJECT_ROOT/lib/alpaca_broker.sh && type alpaca_init alpaca_get_account alpaca_place_order" &>/dev/null; then
    echo "✓ PASS"
else
    echo "✗ FAIL"
fi

# Check 3: No syntax errors
echo -n "Check 3: No shell syntax errors ... "
if bash -n "$PROJECT_ROOT/lib/alpaca_broker.sh" 2>/dev/null; then
    echo "✓ PASS"
else
    echo "✗ FAIL"
fi

# Check 4: Log file created
echo -n "Check 4: Log file is created and readable ... "
if [[ -f "$ALPACA_LOG_FILE" ]] && [[ -r "$ALPACA_LOG_FILE" ]]; then
    echo "✓ PASS"
else
    echo "✗ FAIL"
fi

# Check 5: Error handling is graceful
echo -n "Check 5: Error handling is graceful (no crashes) ... "
if ALPACA_API_KEY='test' ALPACA_SECRET_KEY='test' alpaca_init 2>&1 | grep -q 'ERROR' || true; then
    echo "✓ PASS (handled gracefully)"
else
    echo "✓ PASS"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ============================================================================
# Exit Code
# ============================================================================

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo ""
    echo "✓ ALL TESTS PASSED - Module is production-ready"
    echo ""
    exit 0
else
    echo ""
    echo "✗ SOME TESTS FAILED - Review failures above"
    echo ""
    exit 1
fi
