#!/bin/bash
# ============================================================================
# Integration Tests: v2 confluence scoring in the CLI (Step 1, FEAT-001)
# ============================================================================
# Tests for: score_obv_trend (real OBV score), score_mean_reversion_setup,
# score_trend_follow_setup, kalman_trend_from_closes, build_v2_inputs, the
# optional 10th (sentiment) arg of calculate_confluence_score_v2, the v2
# analysis shape from analyze_stock, SCORING_MODE=legacy / --legacy-score,
# the SCORE BREAKDOWN stdout block and the JSON + HTML reports.
# Offline: SST_OFFLINE=1 (ML uses its seeded synthetic features); real-shaped
# bars come from tests/stubs/yfinance_fixture. macOS bash 3.2 compatible.
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"
AGENT="$PROJECT_DIR/StockSwingTrader_Agent.sh"
LIB="$PROJECT_DIR/lib"
STUB_FIXTURE="$TEST_DIR/stubs/yfinance_fixture"
STUB_EMPTY="$TEST_DIR/stubs/yfinance_empty"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sst_v2_cli_test.XXXXXX")"
export SST_OFFLINE=1
unset SST_ALLOW_SYNTHETIC SCORING_MODE V2_SENTIMENT_WEIGHT OBV_LOOKBACK KALMAN_TREND_THRESHOLD_PCT
export MIROFISH_CACHE_DIR="$WORK_DIR/mirofish"
export RISK_BUDGET_DIR="$WORK_DIR/risk_budget"
export REGIME_CACHE_DIR="$WORK_DIR/regime"
export SENTIMENT_CACHE_DIR="$WORK_DIR/sentiment"
export BACKTEST_OUTPUT_DIR="$WORK_DIR/backtests"
# One ML prediction takes ~5 s; never let a timeout change a score mid-test
export ML_TIMEOUT_SECONDS=30
mkdir -p "$MIROFISH_CACHE_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

# ============================================================================
# Test Utilities
# ============================================================================
pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓ PASS${NC}: $1"
}

fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗ FAIL${NC}: $1"
    [[ -n "$2" ]] && echo "  $2"
}

assert_equals() {
    local expected=$1 actual=$2 name=$3
    if [[ "$expected" == "$actual" ]]; then
        pass "$name"
    else
        fail "$name" "Expected: '$expected'  Got: '$actual'"
    fi
}

assert_true() {
    local name=$1
    shift
    if "$@"; then
        pass "$name"
    else
        fail "$name" "Command failed: $*"
    fi
}

# assert_jq JSON EXPR NAME : passes when EXPR is true for JSON
assert_jq() {
    local json=$1 expr=$2 name=$3
    if [[ -n "$json" ]] && echo "$json" | jq -e "$expr" >/dev/null 2>&1; then
        pass "$name"
    else
        fail "$name" "jq '$expr' not true for: $(echo "$json" | head -c 400)"
    fi
}

jget() {
    echo "$1" | jq -r "$2"
}

# lib CMD... : run CMD in a fresh bash with lib/scoring.sh sourced
lib() {
    bash -c 'source "$1/scoring.sh" 2>/dev/null; shift; "$@" </dev/null 2>/dev/null' _ "$LIB" "$@"
}

# v2 ENV... -- ARGS... : calculate_confluence_score_v2 ARGS with ENV, compact
v2() {
    local -a envs=()
    while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
    shift
    env "${envs[@]}" bash -c 'source "$1/scoring.sh" 2>/dev/null; shift; calculate_confluence_score_v2 "$@" </dev/null 2>/dev/null' _ "$LIB" "$@" | jq -c .
}

# Strip run-dependent metadata so two v2 outputs can be compared
v2_stable() {
    echo "$1" | jq -S -c 'del(.metadata.latency_ms, .metadata.timestamp)'
}

# ============================================================================
# Fixture: real-shaped bars (yfinance stub), indicators computed once and
# replayed (the bash indicator code takes ~20 s per symbol)
# ============================================================================
FIXTURE_OHLCV="$WORK_DIR/ohlcv.json"
FIXTURE_IND="$WORK_DIR/indicators.json"
PYTHONPATH="$STUB_FIXTURE" SST_OFFLINE=0 bash -c '
    source "$1" >/dev/null 2>&1; LOG_FILE=/dev/null
    o=$(fetch_stock_ohlcv AAPL 60); echo "$o" > "$2"
    calculate_all_indicators AAPL "$o" > "$3" 2>/dev/null' _ "$AGENT" "$FIXTURE_OHLCV" "$FIXTURE_IND"

run_analysis() {
    env "$@" bash -c '
        source "$1" >/dev/null 2>&1
        LOG_FILE=/dev/null
        SST_FIXTURE_OHLCV="$2"
        SST_FIXTURE_IND="$3"
        fetch_stock_ohlcv() { cat "$SST_FIXTURE_OHLCV"; }
        calculate_all_indicators() { cat "$SST_FIXTURE_IND"; }
        analyze_stock AAPL 2>/dev/null | grep -v "^\["
    ' _ "$AGENT" "$FIXTURE_OHLCV" "$FIXTURE_IND"
}

echo "Fixture:"
assert_jq "$(cat "$FIXTURE_OHLCV")" '.data_source == "yfinance" and (.ohlcv | length == 60)' "fixture OHLCV: 60 yfinance-stub bars"
IND=$(cat "$FIXTURE_IND")
assert_jq "$IND" '.v2_inputs | type == "object"' "calculate_all_indicators embeds .v2_inputs"
assert_jq "$IND" '.v2_inputs | (has("obv_score") and has("obv_available") and has("obv_change") and has("obv_lookback")
    and has("mr_score") and has("tf_score") and has("kalman_trend") and has("kalman_slope_pct") and has("kalman_available")
    and has("regime") and has("regime_detail") and has("ema_12") and has("ema_26") and has("sma_50") and has("sma_200")
    and has("last_volume") and has("avg_volume_20") and has("avg_volume_30") and has("closes_count"))' "v2_inputs has every documented key"
assert_jq "$IND" '.v2_inputs | .closes_count == 60 and .sma_200 == null and (.sma_50 | type == "number")' "60 bars: sma_50 computed, sma_200 null"
assert_jq "$IND" '.v2_inputs.regime_detail.data_source == "caller" and .v2_inputs.regime == .v2_inputs.regime_detail.regime and .v2_inputs.regime != "unknown"' "regime detected from the fetched closes (data_source caller)"
assert_jq "$IND" '(.indicators | keys) == (["atr","bollinger_bands","macd","rsi","stochastic","williams_r"])' "indicators block unchanged (v2_inputs is outside it)"

# ============================================================================
# OBV trend score
# ============================================================================
echo ""
echo "score_obv_trend:"
ONES=$(jq -c -n '[range(0;12)] | map(1000)')
UP=$(jq -c -n '[range(0;12)] | map(1000 * (. + 1))')
DOWN=$(jq -c -n '[range(0;12)] | map(12000 - 1000 * .)')
FLAT=$(jq -c -n '[range(0;12)] | map(5000)')
assert_equals "100|true" "$(jget "$(lib score_obv_trend "$UP" "$ONES")" '"\(.obv_score)|\(.obv_available)"')" "all up bars -> 100"
assert_equals "0|true" "$(jget "$(lib score_obv_trend "$DOWN" "$ONES")" '"\(.obv_score)|\(.obv_available)"')" "all down bars -> 0"
assert_equals "50|true" "$(jget "$(lib score_obv_trend "$FLAT" "$ONES")" '"\(.obv_score)|\(.obv_available)"')" "flat OBV -> 50"
assert_equals "50|false|null" "$(jget "$(lib score_obv_trend '[1000,2000,3000]' '[1000,1000,1000]')" '"\(.obv_score)|\(.obv_available)|\(.obv_change)"')" "short series (< N+1 points) -> 50, obv_available false"
assert_equals "75" "$(jget "$(lib score_obv_trend '[0,1000,1000,2000]' '[1000,1000,1000,1000]' 2)" .obv_score)" "lookback 2: half the volume up -> 75"
assert_equals "3" "$(jget "$(OBV_LOOKBACK=3 lib score_obv_trend "$UP" "$ONES")" .obv_lookback)" "OBV_LOOKBACK sets the default lookback"

closes=$(jq -r '[.ohlcv[].close] | map(tostring) | join(" ")' "$FIXTURE_OHLCV")
vols=$(jq -r '[.ohlcv[].volume] | map(tostring) | join(" ")' "$FIXTURE_OHLCV")
vols_json=$(jq -c '[.ohlcv[].volume]' "$FIXTURE_OHLCV")
obv_from_bars() {
    bash -c '
        source "$1/indicators.sh" 2>/dev/null; source "$1/scoring.sh" 2>/dev/null
        read -ra c <<< "$2"; read -ra v <<< "$3"
        cv=""; for ((i = 0; i < ${#c[@]}; i++)); do cv="$cv${c[$i]} ${v[$i]} "; done
        score_obv_trend "$(calc_obv $cv)" "$4" | jq -r .obv_score' _ "$LIB" "$closes" "$vols" "$vols_json"
}
obv1=$(obv_from_bars)
obv2=$(obv_from_bars)
assert_equals "$obv1" "$obv2" "OBV score from the fixture bars is deterministic ($obv1)"
assert_equals "$obv1" "$(jget "$IND" .v2_inputs.obv_score)" "v2_inputs.obv_score equals score_obv_trend on the fixture arrays"
assert_true "fixture OBV score is computed from the bars, not the constant 50 ($obv1)" test "$obv1" != "50"

# ============================================================================
# Mean-reversion / trend-following setup scores, Kalman trend
# ============================================================================
echo ""
echo "MR / TF / Kalman helpers:"
assert_equals "94" "$(lib score_mean_reversion_setup 30 95 110 90 2 1 1 0)" "MR: RSI 30, lower half of band, high volume, MACD > signal -> 94"
assert_equals "50" "$(lib score_mean_reversion_setup 50 100 110 90 1 1 0 0)" "MR: neutral RSI, mid band, MACD == signal -> 50"
assert_equals "5" "$(lib score_mean_reversion_setup 80 112 110 90 1 1 0 1)" "MR: RSI 80, above upper band, MACD < signal -> 5"
assert_equals "100" "$(lib score_mean_reversion_setup 5 80 110 90 2 1 2 1)" "MR: clamped at 100"
assert_equals "86" "$(lib score_trend_follow_setup 105 101 100 102 '' 2 1)" "TF: EMA12 > EMA26, close > SMA50, high volume -> 86"
assert_equals "20" "$(lib score_trend_follow_setup 95 99 100 98 '' 1 1)" "TF: EMA12 < EMA26, close < SMA50 -> 20"
assert_equals "90" "$(lib score_trend_follow_setup 105 101 100 102 100 1 1)" "TF: with SMA200 below close -> 90"
assert_equals "65" "$(lib score_trend_follow_setup 105 101 100 '' '' 1 1)" "TF: no SMA50/SMA200 (empty) -> only the EMA term"
rising=$(jq -c -n '[range(0;30)] | map(100 + .)')
falling=$(jq -c -n '[range(0;30)] | map(130 - .)')
flat=$(jq -c -n '[range(0;30)] | map(100)')
assert_equals "1|true" "$(jget "$(lib kalman_trend_from_closes "$rising")" '"\(.kalman_trend)|\(.kalman_available)"')" "Kalman: rising closes -> 1"
assert_equals "-1|true" "$(jget "$(lib kalman_trend_from_closes "$falling")" '"\(.kalman_trend)|\(.kalman_available)"')" "Kalman: falling closes -> -1"
assert_equals "0|true" "$(jget "$(lib kalman_trend_from_closes "$flat")" '"\(.kalman_trend)|\(.kalman_available)"')" "Kalman: flat closes -> 0"
assert_equals "0|false" "$(jget "$(lib kalman_trend_from_closes '[100,101]')" '"\(.kalman_trend)|\(.kalman_available)"')" "Kalman: too few closes -> 0, unavailable"
assert_equals "0" "$(jget "$(KALMAN_TREND_THRESHOLD_PCT=50 lib kalman_trend_from_closes "$rising")" .kalman_trend)" "KALMAN_TREND_THRESHOLD_PCT raises the trend threshold"

# ============================================================================
# calculate_confluence_score_v2: optional 10th (sentiment) arg
# ============================================================================
echo ""
echo "v2 sentiment arg:"
ARGS9=(AAPL 65 70 55 60 trending_bull 60 72 1)
o9=$(v2 -- "${ARGS9[@]}")
ona=$(v2 -- "${ARGS9[@]}" na)
o80=$(v2 V2_SENTIMENT_WEIGHT=0.1 -- "${ARGS9[@]}" 80)
assert_jq "$o9" '.components | has("sentiment") | not' "9 args: no sentiment component (output unchanged)"
assert_equals "$(v2_stable "$o9")" "$(v2_stable "$(echo "$ona" | jq -c 'del(.components.sentiment)')")" "arg 10 na: identical to 9-arg output apart from the sentiment block"
assert_jq "$ona" '.components.sentiment == {score: null, available: false, weight_percent: 0}' "arg 10 na: sentiment {score null, available false, weight 0}"
core=$(echo "$o80" | jq -r '.components | .ml_confidence.score * 0.15 + .regime_score.score * 0.35 + .technical_score.score * 0.30 + .volume_trend_score.score * 0.20')
expected=$(awk -v c="$core" 'BEGIN { printf "%.0f", c * 0.9 + 8 }')
assert_equals "$expected" "$(jget "$o80" .confluence_score)" "arg 10 = 80, weight 0.1: confluence = round(core*0.9 + 8) ($expected)"
assert_jq "$o80" '.components | .ml_confidence.weight_percent == 13.5 and .regime_score.weight_percent == 31.5 and .technical_score.weight_percent == 27 and .volume_trend_score.weight_percent == 18' "arg 10 = 80: other weights scale by 0.9"
assert_jq "$o80" '.components.sentiment == {score: 80, available: true, weight_percent: 10}' "arg 10 = 80: sentiment component score 80, weight 10%"
assert_equals "$(echo "$o9" | jq -c .breakdown.signal_counts)" "$(echo "$o80" | jq -c .breakdown.signal_counts)" "sentiment casts no vote"
o0=$(v2 V2_SENTIMENT_WEIGHT=0 -- "${ARGS9[@]}" 80)
assert_jq "$o0" '.components.sentiment.available == true and .components.sentiment.weight_percent == 0' "V2_SENTIMENT_WEIGHT=0: sentiment shown with 0 weight"
assert_equals "$(jget "$o9" .confluence_score)" "$(jget "$o0" .confluence_score)" "V2_SENTIMENT_WEIGHT=0: score unchanged"
un=$(v2 SST_OFFLINE=0 PYTHONPATH="$STUB_EMPTY" -- "${ARGS9[@]}" 80)
assert_jq "$un" '.components | .ml_confidence.weight_percent == 0 and .regime_score.weight_percent == 37.1 and .technical_score.weight_percent == 31.8 and .volume_trend_score.weight_percent == 21.2 and .sentiment.weight_percent == 10' "ML unavailable + sentiment: renormalized weights scale by 0.9"
un_expected=$(echo "$un" | jq -r '.components | ((.regime_score.score * 35 + .technical_score.score * 30 + .volume_trend_score.score * 20) / 85) * 0.9 + 8' | awk '{ printf "%.0f", $1 }')
assert_equals "$un_expected" "$(jget "$un" .confluence_score)" "ML unavailable + sentiment: score = renormalized core*0.9 + 8"

# ============================================================================
# analyze_stock: default v2, legacy mode
# ============================================================================
echo ""
echo "analyze_stock (v2 default):"
a=$(run_analysis KELLY_SIZING_ENABLED=false MIROFISH_ENABLED=false)
assert_equals "1" "$(echo "$a" | grep -c '^{')" "analysis is one compact JSON line"
assert_jq "$a" '.symbol == "AAPL" and .scoring_model == "v2"' "default .scoring_model == v2"
assert_jq "$a" '[.confluence_v2.components | has("ml_confidence", "regime_score", "technical_score", "volume_trend_score")] | all' "confluence_v2 has the 4 core components"
assert_jq "$a" '.confluence.final_confidence == .confluence_v2.confluence_score and .confluence.signal == .confluence_v2.recommendation' "confluence.final_confidence/signal mirror confluence_v2"
assert_jq "$a" '.confluence.model == "v2" and (.confluence.reasoning | type == "string")' "normalized .confluence has model v2 and reasoning"
assert_jq "$a" '.confluence_v2.components.regime_score.regime == .v2_inputs.regime and .v2_inputs.regime_detail.data_source == "caller"' "regime comes from the caller closes, not the synthetic demo series"
assert_jq "$a" '.scores.obv == .v2_inputs.obv_score and .confluence_v2.breakdown.individual_scores.obv == .scores.obv' "scores.obv == v2_inputs.obv_score (fed into v2)"
mr_ok=$(echo "$a" | jq -r '.v2_inputs as $i | .confluence_v2.breakdown.individual_scores | (.mean_reversion == $i.mr_score and .trend_following == $i.tf_score and .kalman_trend == $i.kalman_trend)')
assert_equals "true" "$mr_ok" "MR/TF/Kalman values in v2 breakdown match v2_inputs"
assert_jq "$a" '.data_source == "yfinance" and .data_warning == ""' "top-level data_warning is about prices only (ML synthetic warning stays in confluence_v2)"
assert_jq "$a" '.confluence_v2.metadata.data_warning | test("SYNTHETIC")' "ML synthetic warning kept at confluence_v2.metadata.data_warning"
assert_jq "$a" '.confluence_v2.components.sentiment.available == false and .confluence_v2.components.sentiment.weight_percent == 0 and .confluence.sentiment_available == false and .confluence.sentiment_contribution == null' "offline sentiment: unavailable, 0 weight"
assert_jq "$a" '.v2_inputs_available == true' "v2_inputs_available true for computed indicators"

kel=$(run_analysis KELLY_SIZING_ENABLED=true MIROFISH_ENABLED=true)
assert_equals "MISSING" "$(jget "$kel" .confluence_v2.components.mirofish.status)" "MiroFish on, no cache -> v2 mirofish component MISSING"
assert_equals "$(jget "$a" .confluence.final_confidence)" "$(jget "$kel" .confluence.final_confidence)" "MiroFish MISSING leaves the v2 score unchanged"
assert_jq "$kel" '.position_sizing.regime == .confluence_v2.components.regime_score.regime and .position_sizing.regime != "unknown"' "Kelly sizing uses the v2 regime"

jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{symbol:"AAPL", generated_at:$t, prediction:"BULLISH", confidence:0.8}' > "$MIROFISH_CACHE_DIR/AAPL.json"
mf=$(run_analysis MIROFISH_ENABLED=true MIROFISH_WEIGHT=0.1)
rm -f "$MIROFISH_CACHE_DIR/AAPL.json"
assert_jq "$mf" '.confluence_v2.components.mirofish.weight_percent == 10 and .confluence_v2.components.mirofish.status == "OK"' "fresh cache: v2 mirofish component OK, 10%"
mf_expected=$(echo "$mf" | jq -r '.confluence_v2.components | (.ml_confidence.score * 0.15 + .regime_score.score * 0.35 + .technical_score.score * 0.30 + .volume_trend_score.score * 0.20) * 0.9 + .mirofish.score * 0.1' | awk '{ printf "%.0f", $1 }')
assert_equals "$mf_expected" "$(jget "$mf" .confluence.final_confidence)" "MiroFish applied once inside v2: core*0.9 + mirofish*0.1"
assert_jq "$mf" '.confluence.mirofish | has("applied") | not' "no legacy apply_mirofish_to_confluence blend on top (no .confluence.mirofish.applied)"

echo ""
echo "analyze_stock (legacy):"
lg=$(run_analysis SCORING_MODE=legacy)
assert_jq "$lg" '.scoring_model == "legacy" and (has("confluence_v2") | not)' "SCORING_MODE=legacy: scoring_model legacy, no confluence_v2"
assert_jq "$lg" '.confluence | has("technical_avg") and has("final_confidence") and has("signal") and has("reasoning") and (has("model") | not)' "SCORING_MODE=legacy: legacy confluence shape"
assert_equals "$(jget "$lg" .confluence.technical_avg)" "$(jget "$lg" .confluence.final_confidence)" "legacy offline: final confidence equals technical average"
assert_equals "$(jget "$a" .scores.obv)" "$(jget "$lg" .scores.obv)" "legacy mode also uses the real OBV score"

# Hand-made indicator JSON without v2_inputs: neutral inputs, flagged
HAND='{"symbol":"T","data_source":"yfinance","last_close":100,"indicators":{"rsi":{"rsi":50},"macd":{"macd":0,"signal":0,"histogram":0},"bollinger_bands":{"upper":110,"middle":100,"lower":90},"stochastic":{"k_line":50},"williams_r": -50,"atr":"1"}}'
h=$(bash -c 'source "$1" >/dev/null 2>&1; LOG_FILE=/dev/null; score_stock T "$2" 2>/dev/null | grep -v "^\["' _ "$AGENT" "$HAND")
assert_jq "$h" '.v2_inputs_available == false and .scores.obv == 50 and .confluence_v2.components.regime_score.regime == "unknown"' "no v2_inputs: OBV 50, regime unknown, v2_inputs_available false"

# ============================================================================
# CLI: stdout breakdown, JSON + HTML reports, --legacy-score, --help
# ============================================================================
echo ""
echo "CLI:"
"$AGENT" --symbols AAPL --output-dir "$WORK_DIR/cli" > "$WORK_DIR/cli.txt" 2>&1; rc=$?
assert_equals "0" "$rc" "SST_OFFLINE=1 --symbols AAPL exits 0"
assert_true "stdout has 'SCORE BREAKDOWN (v2'" grep -q 'SCORE BREAKDOWN (v2' "$WORK_DIR/cli.txt"
line=$(grep '^AAPL  score ' "$WORK_DIR/cli.txt")
assert_true "breakdown line has ML/Regime/Technical/Volume/Trend/Sentiment/OBV parts" \
    bash -c '[[ "$1" == *"| ML "* && "$1" == *"| Regime "* && "$1" == *"| Technical "* && "$1" == *"| Volume/Trend "* && "$1" == *"| Sentiment "* && "$1" == *"| OBV "* ]]' _ "$line"
json_file=$(ls "$WORK_DIR/cli"/swing_analysis_*.json 2>/dev/null | head -1)
html_file=$(ls "$WORK_DIR/cli"/swing_analysis_*.html 2>/dev/null | head -1)
assert_jq "$(cat "$json_file" 2>/dev/null)" 'type == "array" and length == 1 and (.[0] | has("confluence_v2")) and .[0].scoring_model == "v2"' "JSON report: valid array of 1 analysis with confluence_v2"
cli_regime=$(jq -r '.[0].confluence_v2.components.regime_score.regime' "$json_file" 2>/dev/null)
assert_true "HTML report has the score-breakdown section" grep -q 'id="score-breakdown"' "$html_file"
assert_true "HTML breakdown names the regime ($cli_regime)" grep -q "<td>[0-9]* ${cli_regime} (" "$html_file"
assert_true "HTML breakdown uses th scope=col headers and a caption" bash -c 'grep -q "<th scope=\"col\">Regime</th>" "$1" && grep -q "<caption>" "$1"' _ "$html_file"
assert_true "HTML has no SCORE_BREAKDOWN_SECTION placeholder left" bash -c '! grep -q SCORE_BREAKDOWN_SECTION "$1"' _ "$html_file"
assert_true "HTML has no hard-coded 50%/50/100 cells" bash -c '! grep -Eq ">(50/100|50%)<" "$1"' _ "$html_file"
assert_true "stdout breakdown printed before 'Analysis Complete!'" bash -c 'awk "/SCORE BREAKDOWN/ { b = NR } /Analysis Complete!/ { c = NR } END { exit !(b && c && b < c) }" "$1"' _ "$WORK_DIR/cli.txt"

"$AGENT" --symbols AAPL --legacy-score --output-dir "$WORK_DIR/cli_legacy" > "$WORK_DIR/cli_legacy.txt" 2>&1; rc=$?
assert_equals "0" "$rc" "--legacy-score run exits 0"
assert_true "--legacy-score prints 'SCORE BREAKDOWN (legacy'" grep -q 'SCORE BREAKDOWN (legacy' "$WORK_DIR/cli_legacy.txt"
assert_jq "$(cat "$WORK_DIR"/cli_legacy/swing_analysis_*.json 2>/dev/null)" '.[0].scoring_model == "legacy" and (.[0] | has("confluence_v2") | not) and (.[0].confluence | has("technical_avg"))' "--legacy-score: JSON analysis has the legacy shape"
assert_true "--legacy-score HTML row says legacy" grep -q '<td>legacy</td>' "$(ls "$WORK_DIR"/cli_legacy/swing_analysis_*.html | head -1)"

# --watchlist FILE under /bin/bash (3.2 on macOS): read loop, not a bash-4 builtin.
# 2 symbols (one with a CRLF ending), a blank line and a comment line.
printf '# my watchlist\nAAPL\r\n\n  MSFT  \n' > "$WORK_DIR/watchlist.txt"
/bin/bash "$AGENT" --watchlist "$WORK_DIR/watchlist.txt" --output-dir "$WORK_DIR/cli_wl" > "$WORK_DIR/cli_wl.txt" 2>&1; rc=$?
assert_equals "0" "$rc" "--watchlist FILE under /bin/bash exits 0"
assert_true "--watchlist: no 'command not found'" bash -c '! grep -q "command not found" "$1"' _ "$WORK_DIR/cli_wl.txt"
assert_jq "$(cat "$WORK_DIR"/cli_wl/swing_analysis_*.json 2>/dev/null)" 'type == "array" and length == 2 and ([.[].symbol] | sort) == ["AAPL", "MSFT"]' "--watchlist: 2 symbols analyzed (blank/comment skipped, CR and spaces trimmed)"
help_out=$("$AGENT" --help 2>&1)
assert_true "--help lists --legacy-score" grep -q -- '--legacy-score' <<< "$help_out"
assert_true "--help says v2 scoring always runs the ML predictor" grep -q 'always runs the ML predictor' <<< "$help_out"
assert_true "--version mentions v2 confluence scoring" grep -q 'v2 confluence scoring' <<< "$("$AGENT" --version 2>&1)"

# HTML: escaping and inputs without analyses
bash -c 'source "$1" >/dev/null 2>&1
    generate_html_report "{\"symbol\":\"AAPL\",\"data_source\": \"yfinance\"}" "$2/none.html"
    a=$(echo "$3" | jq -c ".symbol = \"<b>X</b>\"")
    generate_html_report "$a" "$2/esc.html"' _ "$AGENT" "$WORK_DIR" "$a" >/dev/null 2>&1
assert_true "HTML without analyses: 'No score breakdown in this input'" grep -q 'No score breakdown in this input' "$WORK_DIR/none.html"
assert_true "HTML breakdown escapes text (@html)" bash -c 'grep -q "&lt;b&gt;X&lt;/b&gt;" "$1" && ! grep -q "<b>X</b>" "$1"' _ "$WORK_DIR/esc.html"

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=========================================="
echo "  Test Summary"
echo "=========================================="
echo "Total Tests:  $TESTS_RUN"
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "\n${GREEN}All tests passed!${NC}"
    exit 0
fi
echo -e "\n${RED}Some tests failed.${NC}"
exit 1
