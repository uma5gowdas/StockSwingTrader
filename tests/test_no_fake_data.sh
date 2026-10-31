#!/bin/bash
# ============================================================================
# StockSwingTrader: No Silent Fake Data
# ============================================================================
# Synthetic data may only be used when explicitly requested (SST_OFFLINE=1,
# SST_ALLOW_SYNTHETIC=1 or --synthetic) and must then be marked
# "data_source": "synthetic" with a visible warning. Without the opt-in:
#   - ML inference returns {"available": false, "reason": ...}
#   - calculate_confluence_score_v2 gives ML zero weight (others renormalized)
#   - backtests fail (non-zero exit, error JSON, no metrics)
#   - regime detection / Kalman demo series / agent OHLCV report unavailable
# Real-data paths are exercised offline with yfinance stubs on PYTHONPATH
# (tests/stubs/yfinance_{empty,error,fixture}).
# macOS bash 3.2 compatible (no `timeout`, no mapfile).
# ============================================================================

set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"
LIB="$PROJECT_DIR/lib"
AGENT="$PROJECT_DIR/StockSwingTrader_Agent.sh"
STUB_EMPTY="$TEST_DIR/stubs/yfinance_empty"
STUB_ERROR="$TEST_DIR/stubs/yfinance_error"
STUB_FIXTURE="$TEST_DIR/stubs/yfinance_fixture"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sst_no_fake_data.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
export REGIME_CACHE_DIR="$WORK_DIR/regime"
export MIROFISH_CACHE_DIR="$WORK_DIR/mirofish"
export SENTIMENT_CACHE_DIR="$WORK_DIR/sentiment"
export RISK_BUDGET_DIR="$WORK_DIR/risk_budget"
export ML_TIMEOUT_SECONDS=20
export LOG_FILE=/dev/null
mkdir -p "$REGIME_CACHE_DIR" "$MIROFISH_CACHE_DIR"

# Every test sets the opt-in variables itself; start from "no opt-in".
unset SST_ALLOW_SYNTHETIC
export SST_OFFLINE=0

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1)); echo -e "${GREEN}✓${NC} $1"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); echo -e "${RED}✗${NC} $1"; [[ -n "$2" ]] && echo "  $2"; }

assert_eq() {
    local expected=$1 actual=$2 name=$3
    if [[ "$expected" == "$actual" ]]; then pass "$name"; else fail "$name" "Expected: '$expected'  Got: '$actual'"; fi
}

# assert_jq JSON EXPR NAME : passes when EXPR is true for JSON
assert_jq() {
    local json=$1 expr=$2 name=$3
    if [[ -n "$json" ]] && echo "$json" | jq -e "$expr" >/dev/null 2>&1; then pass "$name"
    else fail "$name" "jq '$expr' not true for: $(echo "$json" | head -c 400)"; fi
}

section() { echo -e "\n${BLUE}=== $1 ===${NC}"; }

infer() { python3 "$LIB/ml_inference.py" "$@" </dev/null 2>/dev/null; }

# 60 rows of OHLCV (enough for real features) and 10 rows (too few)
awk 'BEGIN { p = 100; print "Open,High,Low,Close,Volume"
    for (i = 0; i < 60; i++) { p = p * (1 + ((i * 37) % 11 - 5) / 500); printf "%.2f,%.2f,%.2f,%.2f,%d\n", p, p * 1.01, p * 0.99, p, 1000000 + i * 1000 } }' \
    > "$WORK_DIR/ohlcv60.csv"
head -11 "$WORK_DIR/ohlcv60.csv" > "$WORK_DIR/ohlcv10.csv"

# ============================================================================
section "ML inference: synthetic only on explicit request, always marked"
# ============================================================================
r=$(SST_OFFLINE=1 infer --symbol AAPL --period 5); rc=$?
assert_eq "0" "$rc" "SST_OFFLINE=1: inference exits 0"
assert_jq "$r" '.available == true and .data_source == "synthetic"' "SST_OFFLINE=1: result is marked data_source=synthetic"
assert_jq "$r" '.warning | test("SYNTHETIC")' "SST_OFFLINE=1: result carries a SYNTHETIC warning"

r=$(PYTHONPATH="$STUB_EMPTY" infer --symbol AAPL --synthetic)
assert_jq "$r" '.available == true and .data_source == "synthetic" and (.warning | length > 0)' "--synthetic flag with no market data: marked synthetic"

r=$(PYTHONPATH="$STUB_EMPTY" SST_ALLOW_SYNTHETIC=1 infer --symbol AAPL)
assert_jq "$r" '.data_source == "synthetic" and (.warning | length > 0)' "SST_ALLOW_SYNTHETIC=1 with no market data: marked synthetic"

r=$(PYTHONPATH="$STUB_FIXTURE" SST_ALLOW_SYNTHETIC=1 infer --symbol AAPL)
assert_jq "$r" '.data_source == "yfinance" and (has("warning") | not)' "SST_ALLOW_SYNTHETIC=1 still prefers real data when it exists"

# ============================================================================
section "ML inference: no real data and no opt-in -> explicit unavailable"
# ============================================================================
r=$(PYTHONPATH="$STUB_EMPTY" infer --symbol AAPL --period 5); rc=$?
assert_eq "0" "$rc" "empty market data: inference exits 0 (unavailable is a valid answer)"
assert_jq "$r" '.available == false and .data_source == null and (.reason | test("no data"))' "empty market data: available=false with a reason"
assert_jq "$r" '(has("direction") or has("confidence") or has("probability")) | not' "empty market data: no direction/confidence/probability invented"

r=$(PYTHONPATH="$STUB_ERROR" infer --symbol AAPL)
assert_jq "$r" '.available == false and (.reason | test("fetch failed"))' "market data fetch error: available=false"

r=$(infer --symbol AAPL --data-file "$WORK_DIR/ohlcv10.csv")
assert_jq "$r" '.available == false and (.reason | test("10 rows"))' "--data-file with 10 rows: available=false (not synthetic)"

r=$(echo '{"symbol":"AAPL","open":1,"high":1,"low":1,"close":1,"volume":1}' | PYTHONPATH="$STUB_EMPTY" python3 "$LIB/ml_inference.py" --symbol AAPL 2>/dev/null)
assert_jq "$r" '.available == false' "single stdin record (old placeholder shape) is not turned into a prediction"

r=$(PYTHONPATH="$STUB_EMPTY" bash "$LIB/ml_predictor.sh" predict AAPL 5 </dev/null 2>/dev/null); rc=$?
assert_eq "0" "$rc" "ml_predictor.sh predict exits 0 for unavailable"
assert_jq "$r" '.available == false and .symbol == "AAPL"' "ml_predictor.sh passes the unavailable result through"
if grep -q 'PLACEHOLDER' "$LIB/ml_predictor.sh"; then fail "ml_predictor.sh no longer sends a PLACEHOLDER record"
else pass "ml_predictor.sh no longer sends a PLACEHOLDER record"; fi

# ============================================================================
section "ML inference: real-data paths carry their source"
# ============================================================================
r=$(PYTHONPATH="$STUB_FIXTURE" infer --symbol AAPL --period 5)
assert_jq "$r" '.available == true and .data_source == "yfinance" and (.direction == "up" or .direction == "down")' "yfinance data: prediction marked data_source=yfinance"
assert_jq "$r" '(has("warning") | not) and .model_training_data == "synthetic"' "yfinance data: no synthetic warning; model_training_data reported"

r=$(infer --symbol AAPL --data-file "$WORK_DIR/ohlcv60.csv")
assert_jq "$r" '.available == true and .data_source == "file"' "--data-file with 60 rows: data_source=file"

records=$(python3 -c "import csv, json, sys; print(json.dumps(list(csv.DictReader(open(sys.argv[1])))))" "$WORK_DIR/ohlcv60.csv")
r=$(echo "$records" | PYTHONPATH="$STUB_EMPTY" python3 "$LIB/ml_inference.py" --symbol AAPL 2>/dev/null)
assert_jq "$r" '.available == true and .data_source == "stdin"' "stdin array of 60 OHLCV records: data_source=stdin"

# ============================================================================
section "Scoring v2: unavailable ML has zero weight, score unchanged by ML"
# ============================================================================
v2() {
    # v2 ENV... -- SYMBOL ARGS...
    local -a envs=()
    while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
    shift
    env "${envs[@]}" bash -c 'source "$1/scoring.sh" 2>/dev/null; shift; calculate_confluence_score_v2 "$@" </dev/null 2>/dev/null' _ "$LIB" "$@"
}
un=$(v2 PYTHONPATH="$STUB_EMPTY" -- AAPL 65 70 55 60 trending_bull 60 72 1)
assert_jq "$un" '.components.ml_confidence | .score == null and .weight_percent == 0 and .available == false and .direction == "unavailable"' "ML unavailable: score null, weight 0, available false"
assert_jq "$un" '.metadata.ml_available == false and .metadata.ml_error == ""' "ML unavailable: metadata.ml_available false (not reported as an error)"
assert_jq "$un" '.components.regime_score.weight_percent == 41.2 and .components.technical_score.weight_percent == 35.3 and .components.volume_trend_score.weight_percent == 23.5' "ML unavailable: other weights renormalized 35/85, 30/85, 20/85"
expected=$(echo "$un" | jq -r '.components | ((.regime_score.score * 35 + .technical_score.score * 30 + .volume_trend_score.score * 20) / 85 + 0.5 | floor)')
assert_eq "$expected" "$(echo "$un" | jq -r .confluence_score)" "ML unavailable: confluence = renormalized regime/technical/volume ($expected)"
un2=$(v2 PYTHONPATH="$STUB_ERROR" -- MSFT 65 70 55 60 trending_bull 60 72 1)
assert_eq "$(echo "$un" | jq -c '[.confluence_score, .recommendation, .signal_strength]')" \
    "$(echo "$un2" | jq -c '[.confluence_score, .recommendation, .signal_strength]')" \
    "ML unavailable: same inputs give the same score for any symbol (ML cannot move it)"
assert_jq "$un" '.breakdown.signal_counts.total_agreement == 3' "ML unavailable: ML casts no bullish/bearish vote"

jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{symbol:"AAPL", generated_at:$t, prediction:"BULLISH", confidence:0.8}' > "$MIROFISH_CACHE_DIR/AAPL.json"
mf=$(v2 PYTHONPATH="$STUB_EMPTY" MIROFISH_ENABLED=true MIROFISH_WEIGHT=0.1 -- AAPL 65 70 55 60 trending_bull 60 72 1)
rm -f "$MIROFISH_CACHE_DIR/AAPL.json"
mf_expected=$(echo "$mf" | jq -r '.components | (((.regime_score.score * 35 + .technical_score.score * 30 + .volume_trend_score.score * 20) / 85) * 0.9 + .mirofish.score * 0.1 + 0.5 | floor)')
assert_eq "$mf_expected" "$(echo "$mf" | jq -r .confluence_score)" "ML unavailable + MiroFish 10%: renormalized base * 0.9 + mirofish * 0.1"
assert_jq "$mf" '.components.ml_confidence.weight_percent == 0 and .components.mirofish.weight_percent == 10' "ML unavailable + MiroFish: ML weight 0, MiroFish 10%"

syn=$(v2 SST_OFFLINE=1 -- AAPL 65 70 55 60 trending_bull 60 72 1)
assert_jq "$syn" '.components.ml_confidence | .data_source == "synthetic" and .available == true and .weight_percent == 15' "SST_OFFLINE=1: ML component marked data_source=synthetic"
assert_jq "$syn" '.metadata.data_warning | test("SYNTHETIC")' "SST_OFFLINE=1: metadata.data_warning names SYNTHETIC"

real=$(v2 PYTHONPATH="$STUB_FIXTURE" -- AAPL 65 70 55 60 trending_bull 60 72 1)
assert_jq "$real" '.components.ml_confidence | .data_source == "yfinance" and .weight_percent == 15 and (.score | type == "number")' "real data: ML marked data_source=yfinance with 15% weight"
assert_jq "$real" '.metadata.data_warning == "" and .metadata.ml_available == true' "real data: no data warning"

# ============================================================================
section "Backtest: no real data -> clear failure; synthetic only when asked"
# ============================================================================
cat > "$WORK_DIR/bt.json" <<JSON
{"symbol": "AAPL", "start_date": "2020-01-01", "end_date": "2024-01-01", "train_pct": 80,
 "strategies": ["mean_reversion", "trend_follow"], "output_file": "$WORK_DIR/bt_out.json"}
JSON
out=$(PYTHONPATH="$STUB_EMPTY" python3 "$LIB/backtest_engine.py" "$WORK_DIR/bt.json" 2>/dev/null); rc=$?
assert_eq "2" "$rc" "engine with empty market data exits 2"
assert_jq "$out" '.error == "market_data_unavailable" and .available == false and (.reason | test("no data"))' "engine prints an error JSON with the reason"
assert_jq "$out" '(has("total_pnl") or has("win_rate") or has("sharpe_ratio")) | not' "engine error JSON has no metrics"
if [[ -e "$WORK_DIR/bt_out.json" ]]; then fail "no results file is written without data"; else pass "no results file is written without data"; fi

out=$(PYTHONPATH="$STUB_ERROR" python3 "$LIB/backtest_engine.py" "$WORK_DIR/bt.json" 2>/dev/null); rc=$?
assert_eq "2" "$rc" "engine with failing market data fetch exits 2"
assert_jq "$out" '.error == "market_data_unavailable" and (.reason | test("fetch failed"))' "fetch failure is reported, not replaced by synthetic prices"

bt_dir="$WORK_DIR/bt_none"
bt_stdout=$(PYTHONPATH="$STUB_EMPTY" BACKTEST_OUTPUT_DIR="$bt_dir" bash -c 'source "$1/backtest.sh"; backtest_strategy AAPL 2023-01-01 2023-12-31 80' _ "$LIB" 2>/dev/null); rc=$?
assert_eq "1" "$rc" "backtest_strategy without market data returns 1"
if echo "$bt_stdout" | grep -q '\.json$'; then fail "backtest_strategy prints no results path on failure" "$bt_stdout"
else pass "backtest_strategy prints no results path on failure"; fi
assert_eq "0" "$(ls "$bt_dir" 2>/dev/null | grep -c . | tr -d ' ')" "no backtest/HTML/CSV files written without data"
PYTHONPATH="$STUB_EMPTY" BACKTEST_OUTPUT_DIR="$bt_dir" bash -c 'source "$1/backtest.sh"; backtest_multi_symbol AAPL,MSFT 2023-01-01 2023-12-31 80' _ "$LIB" >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "backtest_multi_symbol without market data returns 1"
PYTHONPATH="$STUB_EMPTY" BACKTEST_OUTPUT_DIR="$bt_dir" "$AGENT" --backtest AAPL --start 2023-01-01 --end 2023-12-31 >/dev/null 2>&1; rc=$?
if [[ $rc -ne 0 ]]; then pass "agent --backtest without market data exits non-zero ($rc)"; else fail "agent --backtest without market data exits non-zero"; fi

bt_dir="$WORK_DIR/bt_syn"
PYTHONPATH="$STUB_EMPTY" SST_ALLOW_SYNTHETIC=1 BACKTEST_OUTPUT_DIR="$bt_dir" bash -c 'source "$1/backtest.sh"; backtest_multi_symbol AAPL 2020-01-01 2024-01-01 80' _ "$LIB" >/dev/null 2>&1; rc=$?
assert_eq "0" "$rc" "SST_ALLOW_SYNTHETIC=1: backtest_multi_symbol succeeds on synthetic prices"
f=$(ls "$bt_dir"/backtest_AAPL_*.json 2>/dev/null | head -1)
res=$(cat "$f" 2>/dev/null)
assert_jq "$res" '.data_source == "synthetic" and (.warning | test("SYNTHETIC"))' "SST_ALLOW_SYNTHETIC=1: results JSON marked synthetic with warning"
if grep -q 'role="alert"><strong>SYNTHETIC DATA' "${f%.json}.html" 2>/dev/null; then pass "SST_ALLOW_SYNTHETIC=1: HTML report shows a SYNTHETIC DATA banner"
else fail "SST_ALLOW_SYNTHETIC=1: HTML report shows a SYNTHETIC DATA banner"; fi
summary=$(cat "$bt_dir"/portfolio_summary_*.json 2>/dev/null)
assert_jq "$summary" '.data_sources == ["synthetic"] and .metrics.AAPL.data_source == "synthetic" and (.warning | test("SYNTHETIC"))' "portfolio summary lists data sources and warns on synthetic"

bt_dir="$WORK_DIR/bt_off"
f=$(SST_OFFLINE=1 BACKTEST_OUTPUT_DIR="$bt_dir" bash -c 'source "$1/backtest.sh"; backtest_strategy AAPL 2020-01-01 2024-01-01 80' _ "$LIB" 2>/dev/null | tail -1)
assert_jq "$(cat "$f" 2>/dev/null)" '.data_source == "synthetic" and (.warning | length > 0)' "SST_OFFLINE=1: backtest marked synthetic"

bt_dir="$WORK_DIR/bt_real"
f=$(PYTHONPATH="$STUB_FIXTURE" BACKTEST_OUTPUT_DIR="$bt_dir" bash -c 'source "$1/backtest.sh"; backtest_strategy AAPL 2020-01-01 2024-01-01 80' _ "$LIB" 2>/dev/null | tail -1)
res=$(cat "$f" 2>/dev/null)
assert_jq "$res" '.data_source == "yfinance" and (has("warning") | not) and .num_trades >= 1' "real data: backtest marked data_source=yfinance, no warning"
if [[ -f "${f%.json}.html" ]] && grep -q 'Data source: <strong>yfinance' "${f%.json}.html" && ! grep -q 'role="alert"' "${f%.json}.html"; then
    pass "real data: HTML report names yfinance and has no warning banner"
else
    fail "real data: HTML report names yfinance and has no warning banner"
fi

# ============================================================================
section "Regime detector and Kalman demo series"
# ============================================================================
rd() { env "$@" bash -c 'source "$1/regime_detector.sh" 2>/dev/null; shift; detect_market_regime "$@"' _ "$LIB" "${RD_ARGS[@]}"; }
RD_ARGS=(AAPL)
r=$(rd SST_OFFLINE=0)
assert_jq "$r" '.regime == "unknown" and .available == false and .data_source == null' "no opt-in: regime unknown/unavailable (no mock series)"
r=$(rd SST_OFFLINE=1)
assert_jq "$r" '.data_source == "synthetic" and (.warning | test("SYNTHETIC")) and .regime != "unknown"' "SST_OFFLINE=1: demo series result marked synthetic"
r=$(rd SST_OFFLINE=0)
assert_jq "$r" '.available == false' "cached synthetic regime is not served once the opt-in is gone"
RD_ARGS=(REALX 30 $(seq 100 1 130))
r=$(rd SST_OFFLINE=0)
assert_jq "$r" '.data_source == "caller" and .regime == "trending_bull"' "caller-supplied closes: data_source=caller"
RD_ARGS=(SHORT 30 1 2 3)
r=$(rd SST_OFFLINE=0)
assert_jq "$r" '.available == false and (.reason | test("20"))' "too few closes: unavailable, not padded with fake data"

r=$(bash -c 'source "$1/kalman_filter.sh" 2>/dev/null; get_kalman_filtered_prices AAPL 1' _ "$LIB"); rc=$?
assert_eq "1" "$rc" "get_kalman_filtered_prices without opt-in returns 1"
assert_jq "$r" '.available == false' "get_kalman_filtered_prices without opt-in: available=false"
r=$(SST_ALLOW_SYNTHETIC=1 bash -c 'source "$1/kalman_filter.sh" 2>/dev/null; get_kalman_filtered_prices AAPL 1' _ "$LIB")
assert_jq "$r" '.data_source == "synthetic" and (.filtered_prices | length == 24)' "get_kalman_filtered_prices with opt-in: marked synthetic"

# ============================================================================
section "Agent OHLCV, scores and HTML report"
# ============================================================================
agent_fn() { env "$@" AGENT_CMD="$AGENT_CMD" bash -c 'source "$1" >/dev/null 2>&1; LOG_FILE=/dev/null; shift; eval "$AGENT_CMD"' _ "$AGENT"; }
AGENT_CMD='fetch_stock_ohlcv AAPL 60'
out=$(agent_fn PYTHONPATH="$STUB_EMPTY" SST_OFFLINE=0 2>/dev/null); rc=$?
assert_eq "1|" "$rc|$out" "fetch_stock_ohlcv without market data or opt-in: rc 1, no data"
out=$(agent_fn PYTHONPATH="$STUB_EMPTY" SST_OFFLINE=0 SST_ALLOW_SYNTHETIC=1 2>/dev/null)
assert_jq "$out" '.data_source == "synthetic" and (.ohlcv | length == 60)' "SST_ALLOW_SYNTHETIC=1: demo OHLCV marked synthetic"
out=$(agent_fn SST_OFFLINE=1 2>/dev/null)
assert_jq "$out" '.data_source == "synthetic"' "SST_OFFLINE=1: demo OHLCV marked synthetic"
out=$(agent_fn PYTHONPATH="$STUB_FIXTURE" SST_OFFLINE=0 2>/dev/null)
assert_jq "$out" '.data_source == "yfinance" and (.ohlcv | length == 60) and (.ohlcv[0].close > 0)' "yfinance OHLCV: 60 real bars marked data_source=yfinance"

# score_stock: data source carried through; no quote -> last close, not 0
IND='{"symbol":"T","data_source":"synthetic","last_close":100,"indicators":{"rsi":{"rsi":50},"macd":{"macd":0,"signal":0,"histogram":0},"bollinger_bands":{"upper":110,"middle":100,"lower":90},"stochastic":{"k_line":50},"williams_r": -50,"atr":"1"}}'
AGENT_CMD="score_stock T '$IND'"
out=$(agent_fn SST_OFFLINE=1 2>/dev/null | grep -v '^\[')
assert_jq "$out" '.data_source == "synthetic" and (.data_warning | test("SYNTHETIC"))' "score_stock: synthetic input marked in the analysis"
assert_jq "$out" '.scores.bollinger_bands == 50' "score_stock: no live quote -> Bollinger uses last close (50), not price 0 (100)"
AGENT_CMD="score_stock T '${IND/synthetic/yfinance}'"
out=$(agent_fn SST_OFFLINE=1 2>/dev/null | grep -v '^\[')
assert_jq "$out" '.data_source == "yfinance" and .data_warning == ""' "score_stock: real input has no data warning"

AGENT_CMD='calculate_all_indicators AAPL "$(fetch_stock_ohlcv AAPL 60)"'
out=$(agent_fn PYTHONPATH="$STUB_FIXTURE" SST_OFFLINE=0 2>/dev/null)
assert_jq "$out" '.data_source == "yfinance" and (.last_close > 0) and (.indicators.rsi | type == "object")' "calculate_all_indicators on yfinance bars records data_source and last_close"

AGENT_CMD='generate_html_report "{\"symbol\":\"AAPL\",\"data_source\": \"synthetic\"}" "$WORK/syn.html"; generate_html_report "{\"symbol\":\"AAPL\",\"data_source\": \"yfinance\"}" "$WORK/real.html"'
agent_fn WORK="$WORK_DIR" >/dev/null 2>&1
if grep -q 'role="alert">SYNTHETIC DATA' "$WORK_DIR/syn.html" 2>/dev/null; then pass "HTML analysis report shows SYNTHETIC DATA banner for synthetic input"
else fail "HTML analysis report shows SYNTHETIC DATA banner for synthetic input"; fi
if [[ -f "$WORK_DIR/real.html" ]] && ! grep -q 'role="alert"' "$WORK_DIR/real.html"; then pass "HTML analysis report has no banner for yfinance input"
else fail "HTML analysis report has no banner for yfinance input"; fi
if grep -Eq '>(50/100|50%)<' "$WORK_DIR/real.html" 2>/dev/null; then fail "HTML report shows no hard-coded 50 sentiment/confidence values"
else pass "HTML report shows no hard-coded 50 sentiment/confidence values"; fi

PYTHONPATH="$STUB_EMPTY" SST_OFFLINE=0 "$AGENT" --symbols AAPL --output-dir "$WORK_DIR/cli" > "$WORK_DIR/cli.txt" 2>&1; rc=$?
assert_eq "1" "$rc" "CLI with no market data and no opt-in exits 1"
if grep -q 'Successfully analyzed 0 out of 1' "$WORK_DIR/cli.txt" && grep -q 'No stocks analyzed successfully' "$WORK_DIR/cli.txt"; then
    pass "CLI reports 0 analyzed instead of a fake analysis"
else
    fail "CLI reports 0 analyzed instead of a fake analysis" "$(tail -5 "$WORK_DIR/cli.txt")"
fi
if ls "$WORK_DIR/cli"/*.html >/dev/null 2>&1; then fail "CLI writes no report without data"; else pass "CLI writes no report without data"; fi

# ============================================================================
echo -e "\n${BLUE}No Fake Data Test Summary${NC}"
echo "Tests Run:     $TESTS_RUN"
echo "Tests Passed:  $TESTS_PASSED"
echo "Tests Failed:  $TESTS_FAILED"
[[ $TESTS_FAILED -eq 0 ]]
