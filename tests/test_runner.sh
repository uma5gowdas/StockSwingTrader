#!/bin/bash
# ============================================================================
# StockSwingTrader: Master Test Runner
# ============================================================================
# Executes all test suites, parses each suite's own pass/fail counts and
# writes a report to reports/test-report.md (git-ignored; SST_TEST_REPORT_FILE
# overrides).
#
# A suite PASSES only when it exits 0, reports at least one passed test and
# reports zero failures. A suite whose counts cannot be parsed FAILS.
# Exit code: 0 if every suite passes, 1 otherwise.
#
# Suites run offline (SST_OFFLINE=1): no yfinance/broker network calls.
# Works with macOS bash 3.2 (no `timeout`, no `date +%N` needed).
# ============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPORT_FILE="${SST_TEST_REPORT_FILE:-$PROJECT_DIR/reports/test-report.md}"
REPORT_DIR="$(dirname "$REPORT_FILE")"
# Use <repo>/.venv for python3 when it exists (PATH only; SST_NO_REPO_VENV=1
# disables)
source "$PROJECT_DIR/lib/portable.sh"
sst_use_repo_venv

export SST_OFFLINE=1
# Agent-layer settings from the caller's shell would change the v2 output the
# suites assert on; suites that need them set them explicitly.
unset AGENTS_ENABLED AGENT_CACHE_DIR AGENT_TECHNICAL_ENABLED AGENT_QUANT_WEIGHT \
    AGENT_FUNDAMENTAL_WEIGHT AGENT_MARKET_WEIGHT AGENT_MAX_TOTAL_WEIGHT

mkdir -p "$REPORT_DIR"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Totals (individual test cases across all suites)
TOTAL_TESTS_PASSED=0
TOTAL_TESTS_FAILED=0
TOTAL_TESTS_RUN=0
SUITES_PASSED=0
SUITES_FAILED=0
SUITES_SKIPPED=0

# Agent layer venv (requirements-agents.txt). Suites registered with "venv"
# run with this python (.py) or get AGENTS_PY exported (.sh); when it is not
# executable they are reported as SKIP, which is not a failure.
# SST_AGENTS_VENV=/nonexistent simulates a machine without the venv.
AGENTS_VENV="${SST_AGENTS_VENV:-$PROJECT_DIR/.venv-agents}"
AGENTS_PY="${AGENTS_VENV}/bin/python"

# Markdown table rows for the report
TEST_RESULTS=""

TEST_NAMES=()
TEST_FILES=()
TEST_KINDS=()

# add_test NAME FILE [venv]
add_test() {
    TEST_NAMES+=("$1")
    TEST_FILES+=("$2")
    TEST_KINDS+=("${3:-}")
}

add_test "ML Predictor" "${SCRIPT_DIR}/test_ml_predictor.sh"
add_test "Regime Weighting" "${SCRIPT_DIR}/test_regime_weighting.sh"
add_test "Kalman Filter" "${SCRIPT_DIR}/test_kalman_filter.sh"
add_test "Backtest" "${SCRIPT_DIR}/test_backtest.sh"
add_test "ML Scoring Integration" "${SCRIPT_DIR}/test_ml_scoring_integration.sh"
add_test "Regime Detector" "${SCRIPT_DIR}/test_regime_detector.sh"
add_test "Scoring Integration (Python)" "${SCRIPT_DIR}/test_scoring_integration.py"
add_test "Dashboard Components" "${SCRIPT_DIR}/test_dashboard.js"
add_test "Backend API" "${SCRIPT_DIR}/test_backend.js"
add_test "Kelly Sizing & Risk Budget" "${SCRIPT_DIR}/test_kelly_sizing.sh"
add_test "Sentiment (deterministic)" "${SCRIPT_DIR}/test_sentiment.sh"
add_test "MiroFish Cache Adapter" "${SCRIPT_DIR}/test_mirofish_adapter.sh"
add_test "Phase 1 Integration (CLI)" "${SCRIPT_DIR}/test_phase1_integration.sh"
add_test "No Silent Fake Data" "${SCRIPT_DIR}/test_no_fake_data.sh"
add_test "Broker Commands (stubbed)" "${SCRIPT_DIR}/test_broker_commands.sh"
add_test "V2 CLI Scoring" "${SCRIPT_DIR}/test_v2_cli_scoring.sh"
add_test "Order Execution (stubbed)" "${SCRIPT_DIR}/test_order_execution.sh"
add_test "Live Safety (stubbed)" "${SCRIPT_DIR}/test_live_safety.sh"
add_test "Portable helpers" "${SCRIPT_DIR}/test_portable.sh"
add_test "Setup script" "${SCRIPT_DIR}/test_setup.sh"
add_test "Agents: Contract" "${SCRIPT_DIR}/test_agents_contract.py" venv
add_test "Agents: Data Clients" "${SCRIPT_DIR}/test_agents_data.py" venv
add_test "Agent Adapter (bash)" "${SCRIPT_DIR}/test_agent_adapter.sh"
add_test "Scoring + Agents (zero-weight identity)" "${SCRIPT_DIR}/test_scoring_agents.sh"
add_test "Agents: Technical" "${SCRIPT_DIR}/test_agents_technical.py" venv
add_test "Agents: Parity vs bash" "${SCRIPT_DIR}/test_agents_parity.sh" venv
add_test "Agents: Validation" "${SCRIPT_DIR}/test_agents_validate.py" venv
add_test "Agents: CLI (offline)" "${SCRIPT_DIR}/test_agents_cli.sh" venv
add_test "Agents: Quant" "${SCRIPT_DIR}/test_agents_quant.py" venv
add_test "Agents: Quant pipeline (offline)" "${SCRIPT_DIR}/test_agents_quant_pipeline.sh" venv
add_test "Agents: Quant blend parity (bash)" "${SCRIPT_DIR}/test_agents_quant_blend.sh" venv

# ============================================================================
# Utility Functions
# ============================================================================

now_ms() {
    perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'
}

strip_ansi() {
    perl -pe 's/\e\[[0-9;]*[A-Za-z]//g; s/\r//g'
}

# Extract "passed failed" from a suite's (ANSI-stripped) output.
# Recognised summary formats:
#   Tests Passed:  N / Tests Failed:  N   (ml_predictor, backtest, python)
#   Passed:        N / Failed:        N   (regime, kalman, ml scoring)
#   ℹ pass N / ℹ fail N  or  # pass N / # fail N   (node --test)
# The last occurrence wins. Prints nothing if either count is missing.
parse_counts() {
    awk '
        { line = $0 }
        match(line, /^[ \t]*(Tests[ \t]+)?Passed:[ \t]*[0-9]+[ \t]*$/) { n = line; gsub(/[^0-9]/, "", n); passed = n }
        match(line, /^[ \t]*(Tests[ \t]+)?Failed:[ \t]*[0-9]+[ \t]*$/) { n = line; gsub(/[^0-9]/, "", n); failed = n }
        match(line, /^(ℹ|#) pass [0-9]+$/) { n = line; sub(/^(ℹ|#) pass /, "", n); passed = n }
        match(line, /^(ℹ|#) fail [0-9]+$/) { n = line; sub(/^(ℹ|#) fail /, "", n); failed = n }
        END { if (passed != "" && failed != "") print passed, failed }
    '
}

print_header() {
    echo -e "\n${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}    StockSwingTrader: Comprehensive Test Suite Runner${NC}"
    echo -e "${BLUE}║${NC}    All Enhancements Validation${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}\n"
}

record_row() {
    TEST_RESULTS="${TEST_RESULTS}| $1 | $2 | $3 | $4 |"$'\n'
}

# Run one suite and fold its counts into the totals
# Args: name, file, [kind: "venv" = needs the agent venv]
run_suite() {
    local test_name=$1
    local test_file=$2
    local kind=${3:-}
    local -a cmd=()

    echo -e "${BLUE}[TEST]${NC} Running: ${test_name}..."

    if [[ ! -f "$test_file" ]]; then
        echo -e "${RED}[FAIL]${NC} ${test_name}: test file not found ($test_file)"
        SUITES_FAILED=$((SUITES_FAILED + 1))
        TOTAL_TESTS_FAILED=$((TOTAL_TESTS_FAILED + 1))
        record_row "$test_name" "❌ FAIL" "-" "Test file not found"
        return 1
    fi

    if [[ "$kind" == "venv" && ! -x "$AGENTS_PY" ]]; then
        echo -e "${YELLOW}[SKIP]${NC} ${test_name}: agent venv not found (${AGENTS_VENV}); create it: ./setup.sh --with-agents (or python3.12 -m venv .venv-agents && .venv-agents/bin/pip install -r requirements-agents.txt)"
        SUITES_SKIPPED=$((SUITES_SKIPPED + 1))
        record_row "$test_name" "⏭ SKIP" "-" "agent venv not found (${AGENTS_VENV})"
        return 0
    fi

    case "$test_file" in
        *.py)
            if [[ "$kind" == "venv" ]]; then
                cmd=("$AGENTS_PY" "$test_file")
            else
                cmd=(python3 "$test_file")
            fi
            ;;
        *.js) cmd=(node --test --test-reporter=spec "$test_file") ;;
        *)    cmd=(bash "$test_file") ;;
    esac

    if ! command -v "${cmd[0]}" &> /dev/null; then
        echo -e "${RED}[FAIL]${NC} ${test_name}: ${cmd[0]} not available"
        SUITES_FAILED=$((SUITES_FAILED + 1))
        TOTAL_TESTS_FAILED=$((TOTAL_TESTS_FAILED + 1))
        record_row "$test_name" "❌ FAIL" "-" "${cmd[0]} not available"
        return 1
    fi

    local start_time end_time elapsed output exit_code counts
    start_time=$(now_ms)
    output=$(cd "$PROJECT_DIR" && AGENTS_PY="$AGENTS_PY" "${cmd[@]}" < /dev/null 2>&1 | strip_ansi)
    exit_code=$?
    end_time=$(now_ms)
    elapsed=$((end_time - start_time))

    counts=$(echo "$output" | parse_counts)
    if [[ -z "$counts" ]]; then
        echo -e "${RED}[FAIL]${NC} ${test_name} (${elapsed}ms)"
        echo -e "  ${YELLOW}Reason: could not parse pass/fail counts (exit code ${exit_code})${NC}"
        echo "$output" | tail -5 | sed 's/^/    /'
        SUITES_FAILED=$((SUITES_FAILED + 1))
        TOTAL_TESTS_FAILED=$((TOTAL_TESTS_FAILED + 1))
        record_row "$test_name" "❌ FAIL" "${elapsed}ms" "Could not parse results (exit ${exit_code})"
        return 1
    fi

    local passed=${counts% *}
    local failed=${counts#* }
    TOTAL_TESTS_PASSED=$((TOTAL_TESTS_PASSED + passed))
    TOTAL_TESTS_FAILED=$((TOTAL_TESTS_FAILED + failed))

    if [[ $exit_code -eq 0 && $failed -eq 0 && $passed -gt 0 ]]; then
        echo -e "${GREEN}[PASS]${NC} ${test_name} (${elapsed}ms) - ${passed} passed, ${failed} failed"
        SUITES_PASSED=$((SUITES_PASSED + 1))
        record_row "$test_name" "✅ PASS" "${elapsed}ms" "${passed} passed, ${failed} failed"
        return 0
    fi

    local reason="exit code ${exit_code}"
    [[ $passed -eq 0 && $failed -eq 0 ]] && reason="no tests executed (exit code ${exit_code})"
    echo -e "${RED}[FAIL]${NC} ${test_name} (${elapsed}ms) - ${passed} passed, ${failed} failed"
    echo -e "  ${YELLOW}Reason: ${reason}${NC}"
    echo "$output" | grep -E '✗|✖|FAIL' | head -10 | sed 's/^/    /'
    if [[ $failed -eq 0 ]]; then
        # Non-zero exit without reported failures still counts as a failure
        TOTAL_TESTS_FAILED=$((TOTAL_TESTS_FAILED + 1))
    fi
    SUITES_FAILED=$((SUITES_FAILED + 1))
    record_row "$test_name" "❌ FAIL" "${elapsed}ms" "${passed} passed, ${failed} failed (${reason})"
    return 1
}

success_rate() {
    if [[ $TOTAL_TESTS_RUN -eq 0 ]]; then
        echo "0"
    else
        echo $(( TOTAL_TESTS_PASSED * 100 / TOTAL_TESTS_RUN ))
    fi
}

# ============================================================================
# Report Generation
# ============================================================================

generate_markdown_report() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local overall="✅ All suites passed"
    [[ $SUITES_FAILED -gt 0 ]] && overall="❌ ${SUITES_FAILED} suite(s) failed"

    cat > "$REPORT_FILE" << EOF
# StockSwingTrader v6.3 - Test Report

**Generated:** $timestamp  
**Command:** \`bash tests/test_runner.sh\`  
**Result:** $overall

## Summary

| Metric | Value |
|--------|-------|
| Suites | $((SUITES_PASSED + SUITES_FAILED + SUITES_SKIPPED)) (${SUITES_PASSED} passed, ${SUITES_FAILED} failed, ${SUITES_SKIPPED} skipped) |
| Total Tests | ${TOTAL_TESTS_RUN} |
| Tests Passed | **${TOTAL_TESTS_PASSED}** |
| Tests Failed | **${TOTAL_TESTS_FAILED}** |
| Success Rate | $(success_rate)% |

## Results by Suite

| Suite | Status | Time | Details |
|-------|--------|------|---------|
${TEST_RESULTS}
Counts are taken from each suite's own summary output. A suite passes only
when it exits 0 with at least one passed test and zero failures.

## Suites

| Suite | File | Runner | Exercises |
|-------|------|--------|-----------|
| ML Predictor | tests/test_ml_predictor.sh | bash | lib/ml_inference.py with the trained XGBoost model, lib/ml_predictor.sh |
| Regime Weighting | tests/test_regime_weighting.sh | bash | lib/regime_weighting.sh (weights, multipliers, recommendations) |
| Kalman Filter | tests/test_kalman_filter.sh | bash | lib/kalman_filter.sh + lib/kalman_inference.py |
| Backtest | tests/test_backtest.sh | bash | lib/backtest.sh + lib/backtest_engine.py end to end (JSON/CSV/HTML) |
| ML Scoring Integration | tests/test_ml_scoring_integration.sh | bash | lib/scoring.sh calculate_confluence_score_v2 with the real ML predictor |
| Regime Detector | tests/test_regime_detector.sh | bash | lib/regime_detector.sh (trend, ADX, BB width, cache, batch) |
| Scoring Integration (Python) | tests/test_scoring_integration.py | python3 | Confluence weighting formula and signal thresholds |
| Dashboard Components | tests/test_dashboard.js | node --test | frontend/src utils, usePolling hook, all App routes, tsc --noEmit |
| Backend API | tests/test_backend.js | node --test | backend/server.js routes on an ephemeral port |
| Kelly Sizing & Risk Budget | tests/test_kelly_sizing.sh | bash | lib/kelly_sizing.sh (fractional Kelly, caps, daily risk budget ledger), risk_management/strategy wiring |
| Sentiment (deterministic) | tests/test_sentiment.sh | bash | lib/sentiment.sh (news keyword classifier, unavailable sources, local Finnhub stub), legacy sentiment sentinel |
| MiroFish Cache Adapter | tests/test_mirofish_adapter.sh | bash | lib/mirofish_adapter.sh cache statuses, legacy and v2 blending, no network calls |
| Phase 1 Integration (CLI) | tests/test_phase1_integration.sh | bash | StockSwingTrader_Agent.sh --kelly/--mirofish/--phase1, help, --backtest syntax, MiroFish-enabled timing |
| No Silent Fake Data | tests/test_no_fake_data.sh | bash | data_source rules with yfinance stubs (no data, error, fixture) |
| Broker Commands (stubbed) | tests/test_broker_commands.sh | bash | --check-account/--view-positions/--buy/--sell and deprecated aliases against a local Alpaca stub, Robinhood with stub functions, confirmation yes/no, invalid input, --ml/--kalman loading, libs keep SCRIPT_DIR |
| Portable helpers | tests/test_portable.sh | bash | lib/portable.sh (perl stat/mtime/mode/size, sha256, one-pass in-place sed, process-group timeout, date offsets, epoch ms, repo .venv PATH, sst_os; bash 3.2, no python) |
| Setup script | tests/test_setup.sh | bash | setup.sh in a temp skeleton: --help, unknown flag, --dry-run changes nothing, config.sh mode 600 + idempotent, existing config.sh untouched, --configure-keys without printing values, paper URL warning, --doctor (real repo exit 0, jq missing exit 1 + brew/apt hints); no network |
| Agents: Contract | tests/test_agents_contract.py | .venv-agents python (SKIP without venv) | agents/ envelope schema + rules, atomic cache writes, path guards, config masking, config.sh agent settings reach the CLI, assert_paper, LLM providers + \$0 budget, CLI exit codes |
| Agents: Data Clients | tests/test_agents_data.py | .venv-agents python (SKIP without venv) | agents/data Alpaca bars client against a 127.0.0.1 stub (pagination, GET only, host whitelist, sip->iex, retry, stale, timeout, cache), offline fixtures, yfinance fallback off |
| Agent Adapter (bash) | tests/test_agent_adapter.sh | bash | lib/agent_adapter.sh statuses, gates, latest dir, ttl, weight clamp/cap, components reasons, no network |
| Scoring + Agents (zero-weight identity) | tests/test_scoring_agents.sh | bash | v2 goldens captured at 970af57 unchanged (agents off, and on with weights 0), applied weight math, gate/staleness reasons, sentiment ordering, Technical Agent scan hook (regime_adx) |
| Agents: Technical | tests/test_agents_technical.py | .venv-agents python (SKIP without venv) | TA-Lib features (ranges, ADX14), regime_adx rule table, trend_state, envelopes (synthetic, < 60 bars unavailable), technical run/status CLI exit codes |
| Agents: Parity vs bash | tests/test_agents_parity.sh | bash + .venv-agents python (SKIP without venv) | TA-Lib vs bash indicator tolerances, bash_compat port exact vs bash (indicators, 40 score_* edge inputs), v2 port vs 65 stored bash windows, 3 live bash recomputes |
| Agents: Validation | tests/test_agents_validate.py | .venv-agents python (SKIP without venv) | stats (Sharpe, DSR, PSR, PBO/CSCV), walk-forward folds, vectorbt gate engine (next-open fills, ATR stop, TP), legacy parity vs lib/backtest_engine.py, gate criteria + schema, report HTML, trial log, v2 replay vs bash_compat |
| Agents: CLI (offline) | tests/test_agents_cli.sh | bash + .venv-agents python (SKIP without venv) | validate gate --offline (4 synthetic gate files, report), agent_gate_get contract, missing data exit 2, validate parity --offline, technical run exit 2, validate status, no network |
| Agents: Quant | tests/test_agents_quant.py | .venv-agents python (SKIP without venv) | quant universe file, raw store (offline fixtures, resume/refresh, 127.0.0.1 Alpaca stub: GET only, vwap, 429 retry, paper assert, failed batch), 14 legacy features vs lib/ml_inference.py (no look-ahead), Qlib bin store layout + qlib D.features round trip, quant ingest/status CLI, quant run not_implemented; folds + embargo, IC / Newey-West t / top-k metrics, handlers (label, 172/14 features, no look-ahead), planted-signal training (lgbm, xgb14), predictions -> envelopes, train/predict CLI exit codes; top-k / quant_rank signal builders, quant_rank at w 0 == v2_confluence, baseline criterion, go / no-go rule, evaluate report, gate/evaluate CLI exit codes |
| Agents: Quant pipeline (offline) | tests/test_agents_quant_pipeline.sh | bash + .venv-agents python (SKIP without venv) | quant ingest -> train (lgbm, xgb14) -> predict --offline, artefacts under the temp cache (no ./mlruns), envelopes for every offline rank symbol, lib/agent_adapter.sh agent_get OK + components reason synthetic; v2 goldens identical with the quant envelope at AGENT_QUANT_WEIGHT=0 (shadow), 0.15 applies; quant evaluate --offline (go false, synthetic gates, banner); no network |
| Agents: Quant blend parity (bash) | tests/test_agents_quant_blend.sh | bash + .venv-agents python (SKIP without venv) | bash_compat agent_blend vs bash calculate_confluence_score_v2 with an applied quant agent (score, recommendation, whole JSON; q 10/50/85, ML absent/unavailable, sentiment), AGENT_QUANT_WEIGHT=0 shadow identity |

## Environment

- **OS:** $(uname -s) $(uname -r) ($(uname -m))
- **Bash:** $(bash --version | head -1)
- **Python:** $(python3 --version 2>&1)
- **Node:** $(node --version 2>&1)
- **Offline mode:** SST_OFFLINE=1 (synthetic/seeded data, no network)
- **Agent venv:** ${AGENTS_VENV} ($( [[ -x "$AGENTS_PY" ]] && "$AGENTS_PY" --version 2>&1 || echo "not found: venv suites skipped"))
EOF

    echo -e "\n${GREEN}✓${NC} Report generated: $REPORT_FILE"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    print_header

    local start_time=$(now_ms)

    local i=0
    for test_name in "${TEST_NAMES[@]}"; do
        run_suite "$test_name" "${TEST_FILES[$i]}" "${TEST_KINDS[$i]}"
        i=$((i + 1))
    done

    TOTAL_TESTS_RUN=$((TOTAL_TESTS_PASSED + TOTAL_TESTS_FAILED))

    generate_markdown_report

    local end_time=$(now_ms)
    local elapsed=$(( (end_time - start_time) / 1000 ))

    echo -e "\n${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}        Test Execution Summary${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo -e "Suites:              $((SUITES_PASSED + SUITES_FAILED + SUITES_SKIPPED)) (${SUITES_PASSED} passed, ${SUITES_FAILED} failed, ${SUITES_SKIPPED} skipped)"
    echo -e "Total Tests Run:     ${TOTAL_TESTS_RUN}"
    echo -e "Tests Passed:        ${GREEN}${TOTAL_TESTS_PASSED}${NC}"
    echo -e "Tests Failed:        ${RED}${TOTAL_TESTS_FAILED}${NC}"
    echo -e "Success Rate:        $(success_rate)%"
    echo -e "Report File:         ${REPORT_FILE}"
    echo -e "Total Execution:     ${elapsed}s"

    if [[ $SUITES_FAILED -eq 0 && $TOTAL_TESTS_FAILED -eq 0 && $TOTAL_TESTS_PASSED -gt 0 ]]; then
        echo -e "\n${GREEN}✅ All tests PASSED!${NC}"
        return 0
    else
        echo -e "\n${RED}❌ Some tests FAILED${NC}"
        return 1
    fi
}

main
exit $?
