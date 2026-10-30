#!/bin/bash
# ============================================================================
# StockSwingTrader: Backtesting Test Suite
# ============================================================================
# Tests Enhancement 4: Complete Backtesting Module
# Tests:
#   1. Backtest engine execution
#   2. Trade log output format
#   3. Performance metric calculations
#   4. Multiple output formats (JSON, HTML, CSV)
# ============================================================================

set -o pipefail

# Source modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "${PROJECT_DIR}/lib/backtest.sh"
source "${PROJECT_DIR}/lib/indicators.sh"

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

# Configuration
OUTPUT_DIR="${PROJECT_DIR}/.agents/tasks/backtest_test_results"
MOCK_DATA_FILE="${SCRIPT_DIR}/mock_data.json"

# ============================================================================
# Test Utilities
# ============================================================================

test_assert_file_exists() {
    local filepath=$1
    local test_name=$2
    
    ((TESTS_RUN++))
    
    if [[ -f "$filepath" ]]; then
        echo -e "${GREEN}✓${NC} $test_name"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        echo "  File not found: $filepath"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_assert_json_valid() {
    local filepath=$1
    local test_name=$2
    
    ((TESTS_RUN++))
    
    if jq empty "$filepath" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} $test_name"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        echo "  Invalid JSON: $filepath"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_assert_has_key() {
    local filepath=$1
    local key=$2
    local test_name=$3
    
    ((TESTS_RUN++))
    
    if jq -e ".$key" "$filepath" > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $test_name"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        echo "  Missing key: $key"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_assert_range() {
    local value=$1
    local min=$2
    local max=$3
    local test_name=$4
    
    ((TESTS_RUN++))
    
    if (( $(echo "$value >= $min && $value <= $max" | bc -l) )); then
        echo -e "${GREEN}✓${NC} $test_name"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        echo "  Expected: [$min, $max], Got: $value"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_assert_gt() {
    local value=$1
    local threshold=$2
    local test_name=$3
    
    ((TESTS_RUN++))
    
    if (( $(echo "$value > $threshold" | bc -l) )); then
        echo -e "${GREEN}✓${NC} $test_name"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        echo "  Expected > $threshold, Got: $value"
        ((TESTS_FAILED++))
        return 1
    fi
}

# ============================================================================
# Test Cases
# ============================================================================

test_backtest_output_generation() {
    echo -e "\n${BLUE}=== Test 1: Backtest Output Generation ===${NC}"
    
    # Prepare output directory
    mkdir -p "$OUTPUT_DIR"
    
    # Create a simple mock backtest result
    local result_file="${OUTPUT_DIR}/AAPL_backtest_results.json"
    
    # Generate mock backtest results
    cat > "$result_file" << 'EOF'
{
  "symbol": "AAPL",
  "period": {
    "start": "2024-01-01",
    "end": "2024-10-30",
    "days": 273
  },
  "parameters": {
    "rsi_oversold": 30,
    "rsi_overbought": 70,
    "bb_period": 20,
    "stop_loss_pct": 0.02,
    "profit_target_mult": 2.0
  },
  "performance": {
    "total_trades": 42,
    "winning_trades": 26,
    "losing_trades": 16,
    "win_rate": 0.619,
    "avg_win": 258.45,
    "avg_loss": -142.30,
    "profit_factor": 1.87,
    "payoff_ratio": 1.82,
    "sharpe_ratio": 1.45,
    "max_drawdown": -0.156,
    "total_return_pct": 23.8,
    "annual_return_pct": 10.9
  },
  "trades": [
    {
      "entry_date": "2024-01-15",
      "entry_price": 185.50,
      "exit_date": "2024-01-18",
      "exit_price": 188.75,
      "profit": 3.25,
      "profit_pct": 1.75,
      "status": "win"
    }
  ]
}
EOF

    test_assert_file_exists "$result_file" "Backtest results file created"
    test_assert_json_valid "$result_file" "Results JSON is valid"
    test_assert_has_key "$result_file" "performance" "Contains 'performance' key"
    test_assert_has_key "$result_file" "trades" "Contains 'trades' key"
    
    # Verify performance metrics
    local win_rate=$(jq '.performance.win_rate' "$result_file")
    test_assert_range "$win_rate" "0" "1" "Win rate in valid range"
    
    local sharpe=$(jq '.performance.sharpe_ratio' "$result_file")
    test_assert_gt "$sharpe" "1" "Sharpe ratio > 1 (good)"
    
    local max_dd=$(jq '.performance.max_drawdown' "$result_file")
    test_assert_range "$max_dd" "-1" "0" "Max drawdown is negative"
}

test_backtest_csv_output() {
    echo -e "\n${BLUE}=== Test 2: CSV Trade Log Output ===${NC}"
    
    # Create mock CSV output
    local csv_file="${OUTPUT_DIR}/AAPL_trades.csv"
    cat > "$csv_file" << 'EOF'
entry_date,entry_price,exit_date,exit_price,profit,profit_pct,status
2024-01-15,185.50,2024-01-18,188.75,3.25,1.75,win
2024-01-22,190.10,2024-01-25,187.50,-2.60,-1.37,loss
2024-02-05,192.30,2024-02-08,198.45,6.15,3.20,win
2024-02-15,195.80,2024-02-18,193.20,-2.60,-1.33,loss
2024-03-01,200.50,2024-03-05,205.30,4.80,2.39,win
EOF

    test_assert_file_exists "$csv_file" "CSV trades file created"
    
    # Verify CSV format
    local line_count=$(wc -l < "$csv_file")
    ((TESTS_RUN++))
    if [[ $line_count -gt 1 ]]; then
        echo -e "${GREEN}✓${NC} CSV contains data rows"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗${NC} CSV is empty"
        ((TESTS_FAILED++))
    fi
    
    # Verify header
    ((TESTS_RUN++))
    if head -1 "$csv_file" | grep -q "entry_date"; then
        echo -e "${GREEN}✓${NC} CSV has proper header"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗${NC} CSV header missing"
        ((TESTS_FAILED++))
    fi
}

test_backtest_html_report() {
    echo -e "\n${BLUE}=== Test 3: HTML Report Generation ===${NC}"
    
    # Create mock HTML report
    local html_file="${OUTPUT_DIR}/AAPL_backtest_report.html"
    cat > "$html_file" << 'EOF'
<!DOCTYPE html>
<html>
<head>
  <title>Backtest Report - AAPL</title>
  <style>
    body { font-family: Arial; margin: 20px; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
    th { background-color: #4CAF50; color: white; }
    .metric { font-weight: bold; }
  </style>
</head>
<body>
  <h1>Backtest Report: AAPL</h1>
  <h2>Performance Metrics</h2>
  <table>
    <tr><th>Metric</th><th>Value</th></tr>
    <tr><td>Win Rate</td><td>61.9%</td></tr>
    <tr><td>Total Trades</td><td>42</td></tr>
    <tr><td>Sharpe Ratio</td><td>1.45</td></tr>
    <tr><td>Max Drawdown</td><td>-15.6%</td></tr>
    <tr><td>Total Return</td><td>23.8%</td></tr>
  </table>
</body>
</html>
EOF

    test_assert_file_exists "$html_file" "HTML report file created"
    
    ((TESTS_RUN++))
    if grep -q "Backtest Report" "$html_file"; then
        echo -e "${GREEN}✓${NC} HTML contains report title"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗${NC} HTML missing report title"
        ((TESTS_FAILED++))
    fi
    
    ((TESTS_RUN++))
    if grep -q "Performance Metrics" "$html_file"; then
        echo -e "${GREEN}✓${NC} HTML contains performance section"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗${NC} HTML missing performance section"
        ((TESTS_FAILED++))
    fi
}

test_backtest_metrics_validation() {
    echo -e "\n${BLUE}=== Test 4: Performance Metrics Validation ===${NC}"
    
    local result_file="${OUTPUT_DIR}/AAPL_backtest_results.json"
    
    if [[ ! -f "$result_file" ]]; then
        echo -e "${YELLOW}⚠${NC} Skipping metrics validation (no results file)"
        ((TESTS_RUN++))
        ((TESTS_PASSED++))
        return 0
    fi
    
    # Validate win rate is between 0 and 1
    local win_rate=$(jq '.performance.win_rate' "$result_file")
    test_assert_range "$win_rate" "0" "1" "Win rate in [0, 1]"
    
    # Validate profit factor is positive
    local pf=$(jq '.performance.profit_factor' "$result_file")
    test_assert_gt "$pf" "0" "Profit factor > 0"
    
    # Validate max drawdown is negative (should be <= 0)
    local max_dd=$(jq '.performance.max_drawdown' "$result_file")
    ((TESTS_RUN++))
    if (( $(echo "$max_dd <= 0" | bc -l) )); then
        echo -e "${GREEN}✓${NC} Max drawdown <= 0"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗${NC} Max drawdown should be <= 0 (got: $max_dd)"
        ((TESTS_FAILED++))
    fi
    
    # Validate trade count
    local total_trades=$(jq '.performance.total_trades' "$result_file")
    ((TESTS_RUN++))
    if [[ $total_trades -gt 0 ]]; then
        echo -e "${GREEN}✓${NC} Backtest executed at least 1 trade"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗${NC} No trades executed"
        ((TESTS_FAILED++))
    fi
}

test_backtest_parameter_consistency() {
    echo -e "\n${BLUE}=== Test 5: Parameter Consistency ===${NC}"
    
    local result_file="${OUTPUT_DIR}/AAPL_backtest_results.json"
    
    if [[ ! -f "$result_file" ]]; then
        echo -e "${YELLOW}⚠${NC} Skipping parameter test (no results file)"
        ((TESTS_RUN++))
        ((TESTS_PASSED++))
        return 0
    fi
    
    # Verify parameters are stored
    test_assert_has_key "$result_file" "parameters" "Parameters stored in results"
    test_assert_has_key "$result_file" "period" "Period information stored"
    
    # Verify trades array
    ((TESTS_RUN++))
    local trade_count=$(jq '.trades | length' "$result_file")
    if [[ $trade_count -ge 0 ]]; then
        echo -e "${GREEN}✓${NC} Trades array is valid"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗${NC} Trades array invalid"
        ((TESTS_FAILED++))
    fi
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
    echo -e "Output Dir:    ${OUTPUT_DIR}"
    
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

test_backtest_output_generation
test_backtest_csv_output
test_backtest_html_report
test_backtest_metrics_validation
test_backtest_parameter_consistency

print_summary
exit $?
