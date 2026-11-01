#!/bin/bash
# ============================================================================
# Scoring + Agents: zero-weight identity and agent weight math
# ============================================================================
# 1. Every v2 golden captured at 970af57 (tests/fixtures/agents/v2_golden,
#    before any agent-layer lib change) is reproduced exactly (jq -S, latency
#    and timestamps removed) with AGENTS_ENABLED unset.
# 2. With AGENTS_ENABLED=true, OK quant/fundamental/market caches, PASSED
#    gates and every weight 0: identical after deleting components.agents,
#    and the agents block reports reason "shadow".
# 3. analyze_stock golden identical (agents off, and on with weights 0).
# 4. Applied weights: confluence = round(core*(1-w) + score*w), weight_percent
#    scaled; gate/staleness/availability/synthetic reasons give weight 0;
#    3 x 0.30 capped at 0.30; agents before sentiment; MiroFish and
#    ML-unavailable paths.
# No venv, no network (SST_OFFLINE for ML, yfinance_empty stub otherwise).
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"
GOLDEN="$TEST_DIR/fixtures/agents/v2_golden"
RUN="$GOLDEN/run_case.sh"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sst_scoring_agents.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

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

jget() {
    echo "$1" | jq -r "$2"
}

iso_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

iso_hours_ago() {
    date -u -v-"$1"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 hours ago" +%Y-%m-%dT%H:%M:%SZ
}

TODAY=$(TZ=America/New_York date +%Y-%m-%d)

case_json() {  # case_json NAME -> one element of cases.json
    jq -c --arg n "$1" '.[] | select(.name == $n)' "$GOLDEN/cases.json"
}

expected() {
    jq -S -c . "$GOLDEN/expected/$1.json"
}

# mk_cache DIR: quant 80 / fundamental 60 / market 40 for AAPL, MSFT, NVDA
# (fresh, OK, not synthetic) and PASSED gates for all three signals
mk_cache() {
    local dir=$1 a s score
    for a in quant fundamental market; do
        case "$a" in quant) score=80 ;; fundamental) score=60 ;; market) score=40 ;; esac
        mkdir -p "$dir/$a/$TODAY"
        for s in AAPL MSFT NVDA; do
            jq -n --arg a "$a" --arg s "$s" --arg d "$TODAY" --arg t "$(iso_now)" --argjson sc "$score" '
                {agent:$a, agent_version:"0.1.0", symbol:$s, as_of:$d, generated_at:$t, ttl_hours:36,
                 available:true, reason:null, data_sources:["alpaca:sip"], synthetic:false, score:$sc,
                 direction:"neutral", confidence:0.5, veto:{active:false, code:null, detail:null},
                 features:{}, evidence:[], llm:{mode:"none", model:null, tokens:0, cost_usd:0, cached:false},
                 validation:{gate_id:null, passed:true}, warning:null}' > "$dir/$a/$TODAY/$s.json"
        done
    done
    mkdir -p "$dir/gates"
    for s in quant_rank fundamental_quality market_news_score; do
        jq -n --arg s "$s" --arg t "$(iso_now)" '{signal_id:$s, generated_at:$t, passed:true, synthetic:false}' \
            > "$dir/gates/$s.json"
    done
}

CACHE="$WORK_DIR/cache"
mk_cache "$CACHE"
ON=(AGENTS_ENABLED=true AGENT_CACHE_DIR="$CACHE")

# core CASE_OUTPUT -> unrounded 4-weight core (ML available) as in lib/scoring.sh
core_of() {
    jget "$1" '.components | "\(.ml_confidence.score) \(.regime_score.score) \(.technical_score.score) \(.volume_trend_score.score)"' |
        awk '{ printf "%.4f", $1 * 0.15 + $2 * 0.35 + $3 * 0.30 + $4 * 0.20 }'
}

# ============================================================================
# 1 + 2. v2 goldens: agents off, and on with every weight 0
# ============================================================================
echo "v2 goldens (captured at 970af57):"
n=$(jq length "$GOLDEN/cases.json")
for ((i = 0; i < n; i++)); do
    c=$(jq -c ".[$i]" "$GOLDEN/cases.json")
    name=$(jget "$c" .name)
    exp=$(expected "$name")
    off=$(bash "$RUN" v2 "$c")
    assert_equals "$exp" "$off" "$name: AGENTS_ENABLED unset -> identical to golden"
    on=$(bash "$RUN" v2 "$c" "${ON[@]}")
    assert_equals "$exp" "$(echo "$on" | jq -S -c 'del(.components.agents)')" "$name: AGENTS_ENABLED=true, weights 0 -> identical apart from components.agents"
    assert_equals "shadow,shadow,shadow|0" "$(jget "$on" '.components.agents | "\(.quant.reason),\(.fundamental.reason),\(.market.reason)|\(.applied_weight_percent)"')" "$name: agents block reports shadow, applied 0%"
done
off=$(bash "$RUN" v2 "$(case_json a1_bull_trending_bull_k1)" AGENTS_ENABLED=false AGENT_CACHE_DIR="$CACHE" AGENT_QUANT_WEIGHT=0.3)
assert_equals "$(expected a1_bull_trending_bull_k1)" "$off" "AGENTS_ENABLED=false with weights set -> identical, no agents block"

# ============================================================================
# 3. analyze_stock golden
# ============================================================================
echo ""
echo "analyze_stock golden:"
exp=$(expected e1_analyze_stock_AAPL)
assert_equals "$exp" "$(bash "$RUN" analyze)" "analyze_stock AAPL (agents off) -> identical to golden"
on=$(bash "$RUN" analyze "${ON[@]}")
assert_equals "$exp" "$(echo "$on" | jq -S -c 'del(.confluence_v2.components.agents)')" "analyze_stock AAPL (agents on, weights 0) -> identical apart from components.agents"
assert_equals "shadow" "$(jget "$on" .confluence_v2.components.agents.quant.reason)" "analyze_stock: agents block present in shadow mode"

# ============================================================================
# 4. Applied weights
# ============================================================================
echo ""
echo "Applied weights:"
A1=$(case_json a1_bull_trending_bull_k1)
gold=$(expected a1_bull_trending_bull_k1)
core=$(core_of "$gold")
out=$(bash "$RUN" v2 "$A1" "${ON[@]}" AGENT_QUANT_WEIGHT=0.1)
want=$(awk -v c="$core" 'BEGIN { printf "%.0f", c * 0.9 + 80 * 0.1 }')
assert_equals "$want" "$(jget "$out" .confluence_score)" "quant 0.1 (score 80): confluence = round(core x 0.9 + 80 x 0.1) = $want"
assert_equals "13.5|31.5|27.0|18.0" "$(jget "$out" '[.components.ml_confidence, .components.regime_score, .components.technical_score, .components.volume_trend_score] | map(.weight_percent | tostring) | join("|")')" "core weight_percent scaled by 0.9"
assert_equals "10|10|true|applied" "$(jget "$out" '.components.agents | "\(.applied_weight_percent)|\(.quant.weight_percent)|\(.quant.applied)|\(.quant.reason)"')" "agents block: quant 10%, applied"
assert_equals "100" "$(jget "$out" '([.components | to_entries[] | select(.key != "agents") | .value.weight_percent] | add) + .components.agents.applied_weight_percent | . + 0.0001 | floor')" "weight_percent sum = 100 (core + agents)"
assert_equals "$(jget "$gold" '"\(.signal_strength)|\(.breakdown.signal_counts | tojson)"')" "$(jget "$out" '"\(.signal_strength)|\(.breakdown.signal_counts | tojson)"')" "agents cast no vote (signal counts unchanged)"
assert_equals "$(jget "$gold" '.components | del(.ml_confidence.weight_percent, .regime_score.weight_percent, .technical_score.weight_percent, .volume_trend_score.weight_percent) | tojson')" \
    "$(jget "$out" '.components | del(.agents, .ml_confidence.weight_percent, .regime_score.weight_percent, .technical_score.weight_percent, .volume_trend_score.weight_percent) | tojson')" "component scores unchanged"

out=$(bash "$RUN" v2 "$A1" "${ON[@]}" AGENT_QUANT_WEIGHT=0.3 AGENT_FUNDAMENTAL_WEIGHT=0.3 AGENT_MARKET_WEIGHT=0.3)
want=$(awk -v c="$core" 'BEGIN { printf "%.0f", c * 0.7 + 0.1 * (80 + 60 + 40) }')
assert_equals "30|10|10|10" "$(jget "$out" '.components.agents | "\(.applied_weight_percent)|\(.quant.weight_percent)|\(.fundamental.weight_percent)|\(.market.weight_percent)"')" "3 x 0.30 -> total 0.30 (10% each)"
assert_equals "$want" "$(jget "$out" .confluence_score)" "3 x 0.30: confluence = round(core x 0.7 + 0.1 x 180) = $want"
assert_equals "10.5|24.5|21.0|14.0" "$(jget "$out" '[.components.ml_confidence, .components.regime_score, .components.technical_score, .components.volume_trend_score] | map(.weight_percent | tostring) | join("|")')" "core weight_percent scaled by 0.7"

# Reasons that keep the weight at 0 (score identical to the golden)
check_zero() {  # check_zero CACHE_DIR REASON LABEL [EXTRA_ENV...]
    local dir=$1 reason=$2 label=$3
    shift 3
    local o
    o=$(bash "$RUN" v2 "$A1" AGENTS_ENABLED=true AGENT_CACHE_DIR="$dir" AGENT_QUANT_WEIGHT=0.1 "$@")
    assert_equals "$reason|0|$(jget "$gold" .confluence_score)" "$(jget "$o" '"\(.components.agents.quant.reason)|\(.components.agents.quant.weight_percent)|\(.confluence_score)"')" "$label -> weight 0, reason $reason, score unchanged"
    assert_equals "$gold" "$(echo "$o" | jq -S -c 'del(.components.agents)')" "$label -> output identical apart from components.agents"
}
variant() {  # variant NAME -> copy of the OK cache
    rm -rf "$WORK_DIR/$1"
    cp -R "$CACHE" "$WORK_DIR/$1"
    echo "$WORK_DIR/$1"
}
d=$(variant nogate); rm -f "$d/gates/quant_rank.json"
check_zero "$d" no_gate "gate missing"
d=$(variant gfail); jq '.passed = false' "$CACHE/gates/quant_rank.json" > "$d/gates/quant_rank.json"
check_zero "$d" gate_failed "gate failed"
d=$(variant gexp); jq --arg t "$(iso_hours_ago 1200)" '.generated_at = $t' "$CACHE/gates/quant_rank.json" > "$d/gates/quant_rank.json"
check_zero "$d" gate_expired "gate 50 days old"
d=$(variant gsyn); jq '.synthetic = true' "$CACHE/gates/quant_rank.json" > "$d/gates/quant_rank.json"
check_zero "$d" gate_synthetic "synthetic gate"
d=$(variant stale); jq --arg t "$(iso_hours_ago 40)" '.generated_at = $t' "$CACHE/quant/$TODAY/AAPL.json" > "$d/quant/$TODAY/AAPL.json"
check_zero "$d" stale "40 h old cache"
d=$(variant unav); jq '.available = false | .score = null | .data_sources = [] | .reason = "no data"' "$CACHE/quant/$TODAY/AAPL.json" > "$d/quant/$TODAY/AAPL.json"
check_zero "$d" unavailable "available false cache"
d=$(variant syn); jq '.synthetic = true | .warning = "fixture"' "$CACHE/quant/$TODAY/AAPL.json" > "$d/quant/$TODAY/AAPL.json"
check_zero "$d" synthetic "synthetic cache (online)"
d=$(variant miss); rm -f "$d/quant/$TODAY/AAPL.json"
check_zero "$d" missing "missing cache"

# Agents before sentiment: final = (core x (1-wa) + sum) x (1-ws) + s x ws
echo ""
echo "Ordering (agents, then sentiment; MiroFish; ML unavailable):"
B1=$(case_json b1_bull_sentiment_70)
out=$(bash "$RUN" v2 "$B1" "${ON[@]}" AGENT_QUANT_WEIGHT=0.1)
want=$(awk -v c="$core" 'BEGIN { printf "%.0f", (c * 0.9 + 80 * 0.1) * 0.9 + 70 * 0.1 }')
assert_equals "$want" "$(jget "$out" .confluence_score)" "quant 0.1 + sentiment 70 (ws 0.10): confluence = $want"
wml=$(awk 'BEGIN { printf "%.1f", 15 * 0.9 * 0.9 }')
wre=$(awk 'BEGIN { printf "%.1f", 35 * 0.9 * 0.9 }')
assert_equals "$wml|$wre|10.0|9|9" "$(jget "$out" '"\(.components.ml_confidence.weight_percent)|\(.components.regime_score.weight_percent)|\(.components.sentiment.weight_percent)|\(.components.agents.quant.weight_percent)|\(.components.agents.applied_weight_percent)"')" "weights: core x 0.9 x 0.9, sentiment 10, quant 100 x 0.1 x 0.9 = 9"
assert_equals "100" "$(jget "$out" '([.components | to_entries[] | select(.key != "agents") | .value.weight_percent] | add) + .components.agents.applied_weight_percent | . + 0.5 | floor')" "weight_percent sum ~ 100 with sentiment and agents"

C1=$(case_json c1_mirofish_bullish_08)
gold_c1=$(expected c1_mirofish_bullish_08)
out=$(bash "$RUN" v2 "$C1" "${ON[@]}" AGENT_QUANT_WEIGHT=0.1)
core_mf=$(core_of "$gold_c1")
want=$(awk -v c="$core_mf" 'BEGIN { printf "%.0f", (c * 0.9 + 90 * 0.1) * 0.9 + 80 * 0.1 }')
assert_equals "$want" "$(jget "$out" .confluence_score)" "MiroFish (90, w 0.1) then quant 0.1: confluence = $want"
assert_equals "9.0|12.2|10" "$(jget "$out" '"\(.components.mirofish.weight_percent)|\(.components.ml_confidence.weight_percent)|\(.components.agents.quant.weight_percent)"')" "MiroFish 9.0%, ML 15 x 0.9 x 0.9, quant 10%"

# ML unavailable (yfinance_empty stub, no network): (35/30/20)/85 x (1 - wa)
mlu() {
    env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" LANG=C LC_ALL=C SST_OFFLINE=0 \
        PYTHONPATH="$TEST_DIR/stubs/yfinance_empty" ML_TIMEOUT_SECONDS=30 REGIME_CACHE_DIR="$WORK_DIR/regime" "$@" \
        /bin/bash -c 'source "$1/lib/scoring.sh" >/dev/null 2>&1; calculate_confluence_score_v2 AAPL 75 80 70 72 trending_bull 60 80 1 </dev/null 2>/dev/null' _ "$PROJECT_DIR"
}
base=$(mlu)
out=$(mlu "${ON[@]}" AGENT_QUANT_WEIGHT=0.1)
assert_equals "false|false" "$(jget "$base" .metadata.ml_available)|$(jget "$out" .metadata.ml_available)" "ML unavailable in both runs (yfinance_empty stub)"
want=$(jget "$base" '.components | "\(.regime_score.score) \(.technical_score.score) \(.volume_trend_score.score)"' |
    awk '{ printf "%.0f", ($1 * 35 + $2 * 30 + $3 * 20) / 85 * 0.9 + 80 * 0.1 }')
assert_equals "$want" "$(jget "$out" .confluence_score)" "ML unavailable + quant 0.1: confluence = renormalized core x 0.9 + 8 = $want"
assert_equals "0|$(awk 'BEGIN { printf "%.1f", 3500 / 85 * 0.9 }')|$(awk 'BEGIN { printf "%.1f", 3000 / 85 * 0.9 }')|$(awk 'BEGIN { printf "%.1f", 2000 / 85 * 0.9 }')" \
    "$(jget "$out" '[.components.ml_confidence, .components.regime_score, .components.technical_score, .components.volume_trend_score] | map(.weight_percent | tostring) | join("|")')" "ML unavailable weights 41.2/35.3/23.5 scaled by 0.9"

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
