#!/bin/bash
# ============================================================================
# Unit Tests: MiroFish Cache Adapter (Phase 1 port, optional, default OFF)
# ============================================================================
# Tests for: lib/mirofish_adapter.sh, apply_mirofish_to_confluence and the
# optional mirofish component of calculate_confluence_score_v2 (lib/scoring.sh).
# The adapter reads cache files only. A local HTTP stub is started at
# MIROFISH_API_URL to prove the adapter never calls the network even when a
# MiroFish-like server is reachable.
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sst_mirofish_test.XXXXXX")"
export MIROFISH_CACHE_DIR="$WORK_DIR/cache"
export REGIME_CACHE_DIR="$WORK_DIR/regime"
export SST_OFFLINE=1
export ML_TIMEOUT_SECONDS="${ML_TIMEOUT_SECONDS:-20}"
export MIROFISH_WEIGHT=0.10
export MIROFISH_MAX_AGE_HOURS=36
export MIROFISH_MIN_CONFIDENCE=0.4
mkdir -p "$MIROFISH_CACHE_DIR"
STUB_PID=""
cleanup() {
    [[ -n "$STUB_PID" ]] && kill "$STUB_PID" 2>/dev/null
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

source "$PROJECT_DIR/lib/scoring.sh" </dev/null >/dev/null 2>&1

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

now_ms() {
    perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'
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

iso_hours_ahead() {
    date -u -v+"$1"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 hours" +%Y-%m-%dT%H:%M:%SZ
}

# write_cache SYMBOL PREDICTION CONFIDENCE GENERATED_AT
write_cache() {
    jq -n --arg s "$1" --arg p "$2" --argjson c "$3" --arg t "$4" \
        '{symbol:$s, generated_at:$t, prediction:$p, confidence:$c, agent_votes:{bullish:7,bearish:2,neutral:1}, status:"OK"}' \
        > "$MIROFISH_CACHE_DIR/$1.json"
}

# ============================================================================
# mirofish_get_prediction
# ============================================================================
echo "mirofish_get_prediction:"
out=$(MIROFISH_ENABLED=false mirofish_get_prediction AAPL)
assert_equals "DISABLED|null" "$(jget "$out" '.status + "|" + (.score|tostring)')" "disabled -> DISABLED, score null"

export MIROFISH_ENABLED=true

# A reachable MiroFish-like stub at MIROFISH_API_URL must never be contacted
mkdir -p "$WORK_DIR/fixtures"
echo '{"status":"ok","service":"MiroFish Backend"}' > "$WORK_DIR/fixtures/health"
echo '{"prediction":"BULLISH","confidence":0.99}' > "$WORK_DIR/fixtures/predict"
: > "$WORK_DIR/requests.log"
python3 "$TEST_DIR/http_stub.py" "$WORK_DIR/fixtures" "$WORK_DIR/port" "$WORK_DIR/requests.log" &
STUB_PID=$!
for _ in $(seq 1 50); do [[ -f "$WORK_DIR/port" ]] && break; sleep 0.1; done
STUB_PORT=$(cat "$WORK_DIR/port" 2>/dev/null)
assert_true "local MiroFish-like stub started" test -n "$STUB_PORT"
curl -s --max-time 2 "http://127.0.0.1:$STUB_PORT/health" >/dev/null
: > "$WORK_DIR/requests.log"   # discard the self-check request

export MIROFISH_API_URL="http://127.0.0.1:$STUB_PORT"
out=$(mirofish_get_prediction NOSUCH)
assert_equals "MISSING|null" "$(jget "$out" '.status + "|" + (.score|tostring)')" "enabled, no cache file -> MISSING"
t0=$(now_ms)
for i in $(seq 1 20); do mirofish_get_prediction "SYM$i" >/dev/null; done
t1=$(now_ms)
assert_true "20 MISSING lookups take < 1000 ms total ($((t1 - t0)) ms)" test $((t1 - t0)) -lt 1000
export MIROFISH_API_URL="http://127.0.0.1:9"
t0=$(now_ms)
for i in $(seq 1 20); do mirofish_get_prediction "SYM$i" >/dev/null; done
t1=$(now_ms)
assert_true "unreachable MIROFISH_API_URL is ignored: 20 lookups < 1000 ms ($((t1 - t0)) ms)" test $((t1 - t0)) -lt 1000

write_cache AAPL BULLISH 0.8 "$(iso_now)"
out=$(mirofish_get_prediction AAPL)
assert_equals "OK|90|BULLISH" "$(jget "$out" '.status + "|" + (.score|tostring) + "|" + .prediction')" "fresh BULLISH 0.8 -> OK, score 90"
assert_equals "1" "$(mirofish_prediction_to_signal "$out")" "BULLISH OK -> signal 1"
assert_equals "7" "$(jget "$out" .agent_votes.bullish)" "agent_votes passed through"
out=$(mirofish_get_prediction aapl)
assert_equals "OK" "$(jget "$out" .status)" "lowercase symbol resolves to the same cache file"

write_cache MSFT BEARISH 0.6 "$(iso_now)"
out=$(mirofish_get_prediction MSFT)
assert_equals "OK|20" "$(jget "$out" '.status + "|" + (.score|tostring)')" "fresh BEARISH 0.6 -> score 20"
assert_equals "-1" "$(mirofish_prediction_to_signal "$out")" "BEARISH OK -> signal -1"

write_cache NEUT NEUTRAL 0.7 "$(iso_now)"
assert_equals "50" "$(jget "$(mirofish_get_prediction NEUT)" .score)" "fresh NEUTRAL -> score 50"

write_cache OLD BULLISH 0.8 "$(iso_hours_ago 40)"
out=$(mirofish_get_prediction OLD)
assert_equals "STALE|null" "$(jget "$out" '.status + "|" + (.score|tostring)')" "40h old cache -> STALE, score null"
assert_equals "0" "$(mirofish_prediction_to_signal "$out")" "STALE -> signal 0"

write_cache FUT BULLISH 0.8 "$(iso_hours_ahead 2)"
assert_equals "INVALID" "$(jget "$(mirofish_get_prediction FUT)" .status)" "future-dated cache -> INVALID"

echo '{"symbol":"BAD", "prediction": ' > "$MIROFISH_CACHE_DIR/BAD.json"
assert_equals "INVALID" "$(jget "$(mirofish_get_prediction BAD)" .status)" "malformed JSON -> INVALID"

jq -n --arg t "$(iso_now)" '{symbol:"WHAT", generated_at:$t, prediction:"MAYBE", confidence:0.8}' > "$MIROFISH_CACHE_DIR/WHAT.json"
assert_equals "INVALID" "$(jget "$(mirofish_get_prediction WHAT)" .status)" "unknown prediction value -> INVALID"

jq -n --arg t "$(iso_now)" '{symbol:"BIG", generated_at:$t, prediction:"BULLISH", confidence:1.5}' > "$MIROFISH_CACHE_DIR/BIG.json"
assert_equals "INVALID" "$(jget "$(mirofish_get_prediction BIG)" .status)" "confidence > 1 -> INVALID"

jq -n --arg t "$(iso_now)" '{symbol:"ERR", generated_at:$t, prediction:"BULLISH", confidence:0.8, status:"ERROR"}' > "$MIROFISH_CACHE_DIR/ERR.json"
assert_equals "INVALID" "$(jget "$(mirofish_get_prediction ERR)" .status)" "file status != OK -> INVALID"

jq -n --arg t "$(iso_now)" '{symbol:"ASOF", as_of:$t, prediction:"BULLISH", confidence:0.6}' > "$MIROFISH_CACHE_DIR/ASOF.json"
assert_equals "OK|80" "$(jget "$(mirofish_get_prediction ASOF)" '.status + "|" + (.score|tostring)')" "as_of accepted when generated_at is absent"

write_cache LOW BULLISH 0.2 "$(iso_now)"
assert_equals "LOW_CONFIDENCE|null" "$(jget "$(mirofish_get_prediction LOW)" '.status + "|" + (.score|tostring)')" "confidence 0.2 -> LOW_CONFIDENCE"

assert_equals "INVALID" "$(jget "$(mirofish_get_prediction '../etc')" .status)" "path traversal symbol ../etc -> INVALID"
assert_equals "INVALID" "$(jget "$(mirofish_get_prediction '')" .status)" "empty symbol -> INVALID"

# ============================================================================
# Weight helpers
# ============================================================================
echo ""
echo "Weights:"
assert_equals "0.5" "$(MIROFISH_WEIGHT=0.9 mirofish_effective_weight)" "weight 0.9 clamped to 0.5"
assert_equals "0" "$(MIROFISH_WEIGHT=abc mirofish_effective_weight)" "non-numeric weight -> 0"
assert_equals "0.1" "$(MIROFISH_WEIGHT=0.1 mirofish_effective_weight)" "weight 0.1 kept"
assert_equals "63" "$(mirofish_blend_score 60 90 0.1)" "blend 60 with 90 at w=0.1 -> 63"

# ============================================================================
# Legacy path: apply_mirofish_to_confluence
# ============================================================================
echo ""
echo "Legacy confluence blend:"
base=$(calculate_confluence_score 60 60 60 60 60 60 60)
assert_equals "$base" "$(MIROFISH_ENABLED=false apply_mirofish_to_confluence "$base" AAPL)" "disabled -> output byte-identical"
blended=$(apply_mirofish_to_confluence "$base" AAPL)
assert_equals "63|OK|true" "$(jget "$blended" '(.final_confidence|tostring) + "|" + .mirofish.status + "|" + (.mirofish.applied|tostring)')" "fresh BULLISH 0.8, w 0.1 -> final 63 with mirofish block"
assert_equals "BUY" "$(jget "$blended" .signal)" "signal recomputed from blended score"
missing=$(apply_mirofish_to_confluence "$base" NOSUCH)
assert_equals "$(jget "$base" .final_confidence)|MISSING|false" "$(jget "$missing" '(.final_confidence|tostring) + "|" + .mirofish.status + "|" + (.mirofish.applied|tostring)')" "missing cache -> final unchanged, block status MISSING"
shadow=$(MIROFISH_WEIGHT=0 apply_mirofish_to_confluence "$base" AAPL)
assert_equals "$(jget "$base" .final_confidence)|OK|false" "$(jget "$shadow" '(.final_confidence|tostring) + "|" + .mirofish.status + "|" + (.mirofish.applied|tostring)')" "shadow mode (w 0) -> block OK, score unchanged"
strong=$(calculate_confluence_score 74 74 74 74 74 74 74)
up=$(apply_mirofish_to_confluence "$strong" AAPL)
assert_equals "76|STRONG_BUY" "$(jget "$up" '(.final_confidence|tostring) + "|" + .signal')" "blend can cross a threshold: 74 -> 76 STRONG_BUY"

# ============================================================================
# v2 pipeline: optional component and renormalized weights
# ============================================================================
echo ""
echo "calculate_confluence_score_v2:"
v2_off=$(MIROFISH_ENABLED=false calculate_confluence_score_v2 AAPL 65 60 70 55 sideways 60 55 1 </dev/null)
assert_equals "false" "$(jget "$v2_off" '.components | has("mirofish")')" "disabled -> no components.mirofish"
assert_equals "15|35|30|20" "$(jget "$v2_off" '[.components[].weight_percent|tostring] | join("|")')" "disabled -> weights 15/35/30/20 unchanged"

v2_on=$(calculate_confluence_score_v2 AAPL 65 60 70 55 sideways 60 55 1 </dev/null)
assert_equals "OK|90" "$(jget "$v2_on" '.components.mirofish.status + "|" + (.components.mirofish.score|tostring)')" "enabled + fresh cache -> components.mirofish OK, score 90"
expected=$(echo "$v2_on" | jq -r '.components | "\(.ml_confidence.score) \(.regime_score.score) \(.technical_score.score) \(.volume_trend_score.score)"' |
    awk '{ v = ($1 * 0.15 + $2 * 0.35 + $3 * 0.30 + $4 * 0.20) * 0.9 + 90 * 0.1; printf "%d", int(v + 0.5) }')
assert_equals "$expected" "$(jget "$v2_on" .confluence_score)" "confluence = 4-weight composite x 0.9 + 90 x 0.1"
assert_true "weight_percent values sum to 100 (+/-0.2)" awk -v s="$(jget "$v2_on" '[.components[].weight_percent] | add')" 'BEGIN { d = s - 100; if (d < 0) d = -d; exit !(d <= 0.2) }'

v2_stale=$(calculate_confluence_score_v2 OLD 65 60 70 55 sideways 60 55 1 </dev/null)
expected=$(echo "$v2_stale" | jq -r '.components | "\(.ml_confidence.score) \(.regime_score.score) \(.technical_score.score) \(.volume_trend_score.score)"' |
    awk '{ v = $1 * 0.15 + $2 * 0.35 + $3 * 0.30 + $4 * 0.20; printf "%d", int(v + 0.5) }')
assert_equals "STALE|$expected" "$(jget "$v2_stale" '.components.mirofish.status + "|" + (.confluence_score|tostring)')" "enabled + stale cache -> plain 4-weight formula"
assert_equals "0" "$(jget "$v2_stale" .components.mirofish.weight_percent)" "stale cache contributes weight 0"

# ============================================================================
# No network: the stub must have received zero requests
# ============================================================================
echo ""
echo "Network isolation:"
kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; STUB_PID=""
assert_equals "0" "$(wc -l < "$WORK_DIR/requests.log" | tr -d ' ')" "reachable MiroFish stub received 0 requests from the adapter"
assert_equals "0" "$(grep -v '^[[:space:]]*#' "$PROJECT_DIR/lib/mirofish_adapter.sh" | grep -cE '(^|[^a-z_])(curl|wget|nc|python3?)([^a-z_]|$)')" "lib/mirofish_adapter.sh code (non-comment) has no curl/wget/nc/python calls"

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
