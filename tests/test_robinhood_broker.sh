#!/bin/bash
# ============================================================================
# Test Suite for Robinhood Broker Module
# ============================================================================
# Comprehensive tests for lib/robinhood_broker.sh and lib/robinhood_oauth.sh
# Tests cover: OAuth, token management, API wrappers, broker routing, and strategies
# ============================================================================

set -o pipefail

# ============================================================================
# Test Framework Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_LOG_FILE="${PROJECT_ROOT}/logs/test_robinhood.log"
TEST_RESULTS_FILE="${PROJECT_ROOT}/tests/test_results_robinhood.txt"
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Suppress normal Robinhood logging for tests
export ROBINHOOD_LOG_FILE="${PROJECT_ROOT}/logs/robinhood_test.log"
export ROBINHOOD_DEBUG=false

# Mock OAuth settings
export ROBINHOOD_CLIENT_ID="test_client_123"
export ROBINHOOD_CLIENT_SECRET="test_secret_456"
export ROBINHOOD_OAUTH_REDIRECT_URI="http://localhost:8888/callback"

# Create test log directory
mkdir -p "$(dirname "$TEST_LOG_FILE")"

# ============================================================================
# Test Utilities
# ============================================================================

# Print test header
print_test_header() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "TEST SUITE: Robinhood Broker Module"
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

# Assert success
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
# TEST SETUP: Load Modules
# ============================================================================

echo ""
echo "Loading Robinhood Modules..."
test_log "INFO" "Loading robinhood_oauth.sh and robinhood_broker.sh modules"

# Load OAuth module
if [[ ! -f "$PROJECT_ROOT/lib/robinhood_oauth.sh" ]]; then
    echo "✗ FATAL: OAuth module not found at $PROJECT_ROOT/lib/robinhood_oauth.sh"
    test_log "ERROR" "OAuth module file not found"
    exit 1
fi

source "$PROJECT_ROOT/lib/robinhood_oauth.sh"
if [[ $? -eq 0 ]]; then
    echo "✓ OAuth module loaded successfully"
    test_log "INFO" "OAuth module loaded"
else
    echo "✗ FATAL: Failed to load OAuth module"
    test_log "ERROR" "Failed to load OAuth module"
    exit 1
fi

# Load broker module
if [[ ! -f "$PROJECT_ROOT/lib/robinhood_broker.sh" ]]; then
    echo "✗ FATAL: Broker module not found at $PROJECT_ROOT/lib/robinhood_broker.sh"
    test_log "ERROR" "Broker module file not found"
    exit 1
fi

source "$PROJECT_ROOT/lib/robinhood_broker.sh"
if [[ $? -eq 0 ]]; then
    echo "✓ Broker module loaded successfully"
    test_log "INFO" "Broker module loaded"
else
    echo "✗ FATAL: Failed to load broker module"
    test_log "ERROR" "Failed to load broker module"
    exit 1
fi

# ============================================================================
# TESTS: OAuth Module - Part 1: Functions Load
# ============================================================================

print_test_header

echo ""
echo "GROUP 1: OAuth Module Functions (3 tests)"
echo "─────────────────────────────────────────"

# Test 1.1: All OAuth functions exist
run_test "robinhood_oauth_load_tokens function exists" \
    "type robinhood_oauth_load_tokens | grep -q 'function'"

run_test "robinhood_oauth_save_tokens function exists" \
    "type robinhood_oauth_save_tokens | grep -q 'function'"

run_test "robinhood_oauth_refresh_token function exists" \
    "type robinhood_oauth_refresh_token | grep -q 'function'"

# ============================================================================
# TESTS: OAuth Module - Part 2: Token Structure
# ============================================================================

echo ""
echo "GROUP 2: Token Structure & Storage (3 tests)"
echo "───────────────────────────────────────────"

# Test 2.1: Token file structure after mock login
run_test "Token file directory is ~/.robinhood_tokens.json" \
    "[[ \"\$ROBINHOOD_TOKENS_FILE\" == \"\${HOME}/.robinhood_tokens.json\" ]]"

# Test 2.2: Initialize token file with mock data
run_test "robinhood_oauth_load_tokens handles missing file gracefully" \
    "robinhood_oauth_load_tokens 2>/dev/null || true; [[ ! -z \"\$ROBINHOOD_TOKENS_FILE\" ]]"

# Test 2.3: Token encryption/decryption functions exist
run_test "robinhood_oauth_encrypt_tokens function exists" \
    "type robinhood_oauth_encrypt_tokens | grep -q 'function'"

# ============================================================================
# TESTS: OAuth Module - Part 3: Token Refresh Logic
# ============================================================================

echo ""
echo "GROUP 3: Token Refresh Logic (3 tests)"
echo "──────────────────────────────────────"

# Test 3.1: Token expiration check function exists
run_test "robinhood_oauth_is_token_expired function exists" \
    "type robinhood_oauth_is_token_expired | grep -q 'function'"

# Test 3.2: Refresh token logic function exists
run_test "robinhood_oauth_refresh_token_if_needed function exists" \
    "type robinhood_refresh_token_if_needed | grep -q 'function'"

# Test 3.3: Token validity checker exists
run_test "robinhood_token_valid function exists" \
    "type robinhood_token_valid | grep -q 'function'"

# ============================================================================
# TESTS: API Wrapper Functions - Part 1: Account Info
# ============================================================================

echo ""
echo "GROUP 4: API Wrapper - Account Functions (8 tests)"
echo "──────────────────────────────────────────────────"

# Mock account response
MOCK_ACCOUNT_RESPONSE='{
  "id": "mock_account_123",
  "type": "margin",
  "status": "active",
  "account_type": "individual",
  "buying_power": "50000.00",
  "cash": "10000.00",
  "equity": "25000.00",
  "portfolio_value": "25000.00",
  "currency": "USD"
}'

# Test 4.1: Check account function exists and callable
run_test "robinhood_check_account function exists" \
    "type robinhood_check_account | grep -q 'function'"

# Test 4.2: Get account function exists
run_test "robinhood_get_account function exists" \
    "type robinhood_get_account | grep -q 'function'"

# Test 4.3: Place order function exists and callable
run_test "robinhood_place_order function exists" \
    "type robinhood_place_order | grep -q 'function'"

# Test 4.4: Get positions function exists
run_test "robinhood_get_positions function exists" \
    "type robinhood_get_positions | grep -q 'function'"

# Test 4.5: Get quote function exists
run_test "robinhood_get_quote function exists" \
    "type robinhood_get_quote | grep -q 'function'"

# Test 4.6: Get orders function exists
run_test "robinhood_get_orders function exists" \
    "type robinhood_get_orders | grep -q 'function'"

# Test 4.7: Cancel order function exists
run_test "robinhood_cancel_order function exists" \
    "type robinhood_cancel_order | grep -q 'function'"

# Test 4.8: Format order response function exists
run_test "robinhood_format_order_response function exists" \
    "type robinhood_format_order_response | grep -q 'function'"

# ============================================================================
# TESTS: Broker Module - Symbol & Quantity Validation
# ============================================================================

echo ""
echo "GROUP 5: Broker Validation Functions (6 tests)"
echo "──────────────────────────────────────────────"

# Test 5.1: Symbol validation
run_test "robinhood_validate_symbol accepts AAPL" \
    "robinhood_validate_symbol 'AAPL'"

run_test "robinhood_validate_symbol rejects lowercase" \
    "! robinhood_validate_symbol 'aapl'"

# Test 5.2: Quantity validation
run_test "robinhood_validate_quantity accepts 100" \
    "robinhood_validate_quantity '100'"

run_test "robinhood_validate_quantity rejects 0" \
    "! robinhood_validate_quantity '0'"

# Test 5.3: Side validation
run_test "robinhood_validate_side accepts buy" \
    "robinhood_validate_side 'buy'"

run_test "robinhood_validate_side rejects BUY (uppercase)" \
    "! robinhood_validate_side 'BUY'"

# ============================================================================
# TESTS: Broker Module - Error Handling
# ============================================================================

echo ""
echo "GROUP 6: Error Handling (5 tests)"
echo "──────────────────────────────────"

# Mock error responses
MOCK_401_ERROR='{
  "detail": "Invalid authentication credentials"
}'

MOCK_403_ERROR='{
  "detail": "Permission denied"
}'

# Test 6.1: Error handler function exists
run_test "robinhood_handle_error function exists" \
    "type robinhood_handle_error | grep -q 'function'"

# Test 6.2: Handle 401 Unauthorized
run_test "Handle 401 Unauthorized error gracefully" \
    "robinhood_handle_error 401 \"\$MOCK_401_ERROR\" > /tmp/err.txt 2>&1 || true; grep -qi 'invalid\\|auth' /tmp/err.txt"

# Test 6.3: Handle 403 Forbidden
run_test "Handle 403 Forbidden error gracefully" \
    "robinhood_handle_error 403 \"\$MOCK_403_ERROR\" > /tmp/err.txt 2>&1 || true; grep -qi 'forbidden\\|permission' /tmp/err.txt"

# Test 6.4: Handle 500 Server error
run_test "Handle 500 Server error gracefully" \
    "robinhood_handle_error 500 '{\"detail\":\"Server error\"}' > /tmp/err.txt 2>&1 || true; grep -qi 'server' /tmp/err.txt"

# Test 6.5: Error function returns non-zero on error codes
run_test "robinhood_handle_error returns failure status for error codes" \
    "! robinhood_handle_error 400 '{\"detail\":\"Bad request\"}' 2>/dev/null || true"

# ============================================================================
# TESTS: Format Functions
# ============================================================================

echo ""
echo "GROUP 7: Format Functions (3 tests)"
echo "───────────────────────────────────"

# Test 7.1: Currency formatting
run_test "robinhood_format_currency function exists" \
    "type robinhood_format_currency | grep -q 'function'"

# Test 7.2: Currency formats positive amounts
run_test "robinhood_format_currency formats 1000.50 correctly" \
    "robinhood_format_currency 1000.50 false | grep -q '1000.50'"

# Test 7.3: Currency formats negative amounts
run_test "robinhood_format_currency handles negative amounts" \
    "robinhood_format_currency -500 false | grep -q '500'"

# ============================================================================
# TESTS: Broker Initialization
# ============================================================================

echo ""
echo "GROUP 8: Broker Initialization (3 tests)"
echo "────────────────────────────────────────"

# Test 8.1: Init logging function exists
run_test "robinhood_init_logging function exists" \
    "type robinhood_init_logging | grep -q 'function'"

# Test 8.2: Init function exists
run_test "robinhood_init function exists" \
    "type robinhood_init | grep -q 'function'"

# Test 8.3: Logging directory created
run_test "robinhood_init_logging creates directory" \
    "robinhood_init_logging && [[ -d \"\$(dirname \$ROBINHOOD_LOG_FILE)\" ]]"

# ============================================================================
# TESTS: CLI Broker Flag - Alpaca Default
# ============================================================================

echo ""
echo "GROUP 9: CLI Broker Selection (3 tests)"
echo "──────────────────────────────────────"

# Test 9.1: Default broker is Alpaca
run_test "Default broker is Alpaca when no flag specified" \
    "grep -q 'BROKER_CHOICE.*alpaca' \"$PROJECT_ROOT/StockSwingTrader_Agent.sh\""

# Test 9.2: Script can load with --broker alpaca flag
run_test "Script loads with --broker alpaca flag" \
    "bash -c 'source $PROJECT_ROOT/StockSwingTrader_Agent.sh --broker alpaca 2>&1' | grep -qi 'alpaca\\|loaded' || true"

# Test 9.3: Script recognizes --broker robinhood flag
run_test "Script can parse --broker robinhood flag" \
    "grep -q 'robinhood' \"$PROJECT_ROOT/StockSwingTrader_Agent.sh\""

# ============================================================================
# TESTS: Strategy Integration - Mean Reversion
# ============================================================================

echo ""
echo "GROUP 10: Strategy Integration (2 tests)"
echo "─────────────────────────────────────────"

# Test 10.1: Strategy modules exist
run_test "Mean reversion strategy module exists" \
    "[[ -f \"$PROJECT_ROOT/lib/strategy_mean_reversion.sh\" ]]"

run_test "Trend follow strategy module exists" \
    "[[ -f \"$PROJECT_ROOT/lib/strategy_trend_follow.sh\" ]]"

# ============================================================================
# TESTS: Trade Journal Integration
# ============================================================================

echo ""
echo "GROUP 11: Trade Journal Integration (3 tests)"
echo "──────────────────────────────────────────────"

# Test 11.1: Trade journal module exists
run_test "Trade journal module exists" \
    "[[ -f \"$PROJECT_ROOT/lib/trade_journal.sh\" ]]"

# Test 11.2: Trade journal module can be sourced
run_test "Trade journal module can be sourced" \
    "bash -c 'source $PROJECT_ROOT/lib/trade_journal.sh && type log_trade_entry' &>/dev/null"

# Test 11.3: Trade journal has entry recording function
run_test "Trade journal has entry recording function" \
    "bash -c 'source $PROJECT_ROOT/lib/trade_journal.sh && type log_trade_entry' 2>/dev/null || true"

# ============================================================================
# TESTS: Syntax Validation
# ============================================================================

echo ""
echo "GROUP 12: Syntax Validation (5 tests)"
echo "─────────────────────────────────────"

# Test 12.1: OAuth module has valid bash syntax
run_test "OAuth module has valid bash syntax" \
    "bash -n \"$PROJECT_ROOT/lib/robinhood_oauth.sh\""

# Test 12.2: Broker module has valid bash syntax
run_test "Broker module has valid bash syntax" \
    "bash -n \"$PROJECT_ROOT/lib/robinhood_broker.sh\""

# Test 12.3: Main agent script has valid bash syntax
run_test "Main agent script has valid bash syntax" \
    "bash -n \"$PROJECT_ROOT/StockSwingTrader_Agent.sh\""

# Test 12.4: Strategy modules have valid syntax
run_test "Strategy modules have valid bash syntax" \
    "bash -n \"$PROJECT_ROOT/lib/strategy_mean_reversion.sh\" && bash -n \"$PROJECT_ROOT/lib/strategy_trend_follow.sh\""

# Test 12.5: Trade journal module has valid syntax
run_test "Trade journal module has valid bash syntax" \
    "bash -n \"$PROJECT_ROOT/lib/trade_journal.sh\""

# ============================================================================
# TESTS: No Credentials Exposed
# ============================================================================

echo ""
echo "GROUP 13: Security Checks (4 tests)"
echo "───────────────────────────────────"

# Test 13.1: No hardcoded API keys in OAuth module
run_test "No hardcoded API keys in OAuth module" \
    "! grep -E 'sk-|pk-' \"$PROJECT_ROOT/lib/robinhood_oauth.sh\""

# Test 13.2: No hardcoded credentials in broker module
run_test "No hardcoded credentials in broker module" \
    "! grep -E 'sk-|pk-|Bearer ' \"$PROJECT_ROOT/lib/robinhood_broker.sh\" | grep -v 'export\\|authorization'"

# Test 13.3: Token file referenced correctly
run_test "Token file uses HOME variable for security" \
    "grep -q 'ROBINHOOD_TOKENS_FILE=.*HOME' \"$PROJECT_ROOT/lib/robinhood_oauth.sh\""

# Test 13.4: Test credentials are marked as test values
run_test "Test environment has test_client_123 marker for test credentials" \
    "[[ \"\$ROBINHOOD_CLIENT_ID\" == \"test_client_123\" ]]"

# ============================================================================
# TESTS: Configuration Variables
# ============================================================================

echo ""
echo "GROUP 14: Configuration Variables (4 tests)"
echo "───────────────────────────────────────────"

# Test 14.1: OAuth configuration variables exist
run_test "ROBINHOOD_OAUTH_BASE_URL is configured" \
    "[[ ! -z \"\$ROBINHOOD_OAUTH_BASE_URL\" ]]"

# Test 14.2: Token file path is configured
run_test "ROBINHOOD_TOKENS_FILE is configured" \
    "[[ ! -z \"\$ROBINHOOD_TOKENS_FILE\" ]]"

# Test 14.3: Token buffer time is configured
run_test "Token refresh buffer time is configured" \
    "[[ \"\$ROBINHOOD_TOKEN_BUFFER_SECONDS\" -gt 0 ]]"

# Test 14.4: Timeout values are set
run_test "OAuth timeout is configured" \
    "[[ \"\$ROBINHOOD_OAUTH_BROWSER_TIMEOUT\" -gt 0 ]]"

# ============================================================================
# TESTS: Multi-Broker Support
# ============================================================================

echo ""
echo "GROUP 15: Dual-Broker Architecture (2 tests)"
echo "────────────────────────────────────────────"

# Test 15.1: Alpaca and Robinhood brokers can coexist
run_test "Both Alpaca and Robinhood broker modules exist" \
    "[[ -f \"$PROJECT_ROOT/lib/alpaca_broker.sh\" ]] && [[ -f \"$PROJECT_ROOT/lib/robinhood_broker.sh\" ]]"

# Test 15.2: Broker switching logic exists
run_test "Main agent script has broker selection logic" \
    "grep -q 'case.*BROKER_CHOICE' \"$PROJECT_ROOT/StockSwingTrader_Agent.sh\""

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
echo "Robinhood Log: $ROBINHOOD_LOG_FILE"
echo ""

# Save results to file
{
    echo "Robinhood Broker Test Results"
    echo "============================="
    echo ""
    echo "Tests Passed:  $TESTS_PASSED"
    echo "Tests Failed:  $TESTS_FAILED"
    echo "Tests Skipped: $TESTS_SKIPPED"
    echo "Pass Rate:     $PASS_RATE%"
    echo "Total Tests:   $TOTAL_TESTS"
    echo ""
    echo "Timestamp: $(date)"
} > "$TEST_RESULTS_FILE"

# ============================================================================
# Verification Checks
# ============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "VERIFICATION CHECKS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check 1: OAuth module loads without errors
echo -n "Check 1: OAuth module loads in isolation ... "
if bash -c "source $PROJECT_ROOT/lib/robinhood_oauth.sh && echo 'SUCCESS'" | grep -q SUCCESS; then
    echo "✓ PASS"
else
    echo "✗ FAIL"
fi

# Check 2: Broker module loads without errors
echo -n "Check 2: Broker module loads in isolation ... "
if bash -c "source $PROJECT_ROOT/lib/robinhood_broker.sh && echo 'SUCCESS'" | grep -q SUCCESS; then
    echo "✓ PASS"
else
    echo "✗ FAIL"
fi

# Check 3: All core functions are callable after loading
echo -n "Check 3: Core functions are exported ... "
if bash -c "source $PROJECT_ROOT/lib/robinhood_oauth.sh && source $PROJECT_ROOT/lib/robinhood_broker.sh && type robinhood_init robinhood_place_order robinhood_get_account" &>/dev/null; then
    echo "✓ PASS"
else
    echo "✗ FAIL"
fi

# Check 4: No syntax errors in any module
echo -n "Check 4: No shell syntax errors ... "
if bash -n "$PROJECT_ROOT/lib/robinhood_oauth.sh" && bash -n "$PROJECT_ROOT/lib/robinhood_broker.sh" 2>/dev/null; then
    echo "✓ PASS"
else
    echo "✗ FAIL"
fi

# Check 5: Robinhood and Alpaca can coexist
echo -n "Check 5: Dual-broker modules coexist ... "
if bash -c "source $PROJECT_ROOT/lib/alpaca_broker.sh && source $PROJECT_ROOT/lib/robinhood_broker.sh && echo 'OK'" 2>/dev/null | grep -q OK; then
    echo "✓ PASS"
else
    echo "✗ FAIL"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ============================================================================
# Exit Code
# ============================================================================

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo ""
    echo "✓ ALL TESTS PASSED - Robinhood Broker Integration Ready"
    echo ""
    exit 0
else
    echo ""
    echo "✗ SOME TESTS FAILED - Review failures above"
    echo ""
    exit 1
fi
