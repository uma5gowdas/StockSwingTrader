#!/bin/bash
# ============================================================================
# Unit Tests: Deterministic Sentiment (Phase 1 news classifier merge)
# ============================================================================
# Tests for: lib/sentiment.sh and the sentiment sentinel in
# lib/scoring.sh calculate_confluence_score.
# Network: only a local HTTP stub on 127.0.0.1 (tests/http_stub.py) and a
# closed local port; no external hosts.
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sst_sentiment_test.XXXXXX")"
export SENTIMENT_CACHE_DIR="$WORK_DIR/cache"
export SST_OFFLINE=1
export REGIME_CACHE_DIR="$WORK_DIR/regime"
STUB_PID=""
cleanup() {
    [[ -n "$STUB_PID" ]] && kill "$STUB_PID" 2>/dev/null
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

source "$PROJECT_DIR/lib/sentiment.sh"
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

# ============================================================================
# Social sources: explicit unavailable, no randomness
# ============================================================================
echo "Social sources:"
for src in twitter reddit stocktwits; do
    out=$("parse_${src}_sentiment" AAPL)
    assert_equals "unavailable|null|$src" "$(jget "$out" '.status + "|" + (.sentiment_score|tostring) + "|" + .source')" "$src parser returns unavailable with null score"
done
assert_equals "0" "$(grep -c 'RANDOM' "$PROJECT_DIR/lib/sentiment.sh")" "lib/sentiment.sh contains no \$RANDOM"

# ============================================================================
# Aggregate (offline)
# ============================================================================
echo ""
echo "Aggregate (offline):"
a1=$(aggregate_sentiment AAPL | jq -S -c 'del(.timestamp)')
a2=$(aggregate_sentiment AAPL | jq -S -c 'del(.timestamp)')
assert_equals "$a1" "$a2" "aggregate_sentiment is deterministic across calls"
assert_equals "false|null|unavailable|0" "$(jget "$a1" '(.available|tostring) + "|" + (.aggregate_sentiment_score|tostring) + "|" + .sentiment_label + "|" + (.confidence|tostring)')" "offline aggregate: unavailable, null score, confidence 0"
assert_equals "null" "$(sentiment_to_confidence null)" "sentiment_to_confidence null -> null"
assert_equals "70" "$(sentiment_to_confidence 70)" "sentiment_to_confidence 70 -> 70 (unchanged)"

# ============================================================================
# analyze_news_sentiment (Phase 1 keyword classifier)
# ============================================================================
echo ""
echo "News classifier:"
bull=$(analyze_news_sentiment '[{"headline":"Apple beats estimates and gets upgrade","summary":""}]')
assert_equals "1|ok" "$(jget "$bull" '(.positive_count|tostring) + "|" + .status')" "bullish headline classified BULLISH"
assert_true "bullish headline score > 50" test "$(jget "$bull" .sentiment_score)" -gt 50
bear=$(analyze_news_sentiment '[{"headline":"Shares fall after downgrade","summary":""}]')
assert_equals "1" "$(jget "$bear" .negative_count)" "bearish headline classified BEARISH"
assert_true "bearish headline score < 50" test "$(jget "$bear" .sentiment_score)" -lt 50
mixed='[{"headline":"Earnings beat expectations","summary":""},{"headline":"Company faces lawsuit","summary":""}]'
m1=$(analyze_news_sentiment "$mixed"); m2=$(analyze_news_sentiment "$mixed"); m3=$(analyze_news_sentiment "$mixed")
assert_equals "0.00|50" "$(jget "$m1" '(.sentiment_bias|tostring) + "|" + (.sentiment_score|tostring)')" "one bullish + one bearish article -> bias 0, score 50"
assert_true "mixed fixture deterministic across 3 runs" test "$m1" == "$m2" -a "$m2" == "$m3"
neg=$(analyze_news_sentiment '[{"headline":"Apple does not beat estimates","summary":""}]')
plain=$(analyze_news_sentiment '[{"headline":"Apple beats estimates","summary":""}]')
assert_true "negated headline bias magnitude <= non-negated" awk -v a="$(jget "$neg" .sentiment_bias)" -v b="$(jget "$plain" .sentiment_bias)" 'BEGIN { if (a < 0) a = -a; if (b < 0) b = -b; exit !(a <= b) }'
neg_both=$(analyze_news_sentiment '[{"headline":"Upgrade but cannot avoid lawsuit and downgrade","summary":""}]')
assert_equals "1" "$(jget "$neg_both" .negative_count)" "negation discount applies to both sides (bearish weight still wins)"
empty=$(analyze_news_sentiment '[]')
assert_equals "unavailable|null|0" "$(jget "$empty" '.status + "|" + (.sentiment_score|tostring) + "|" + (.articles_analyzed|tostring)')" "empty article list -> unavailable"
txt=$(analyze_news_sentiment 'Stock surges to record after strong rally')
assert_true "plain-text input still returns valid JSON" jq -e '.status == "ok" and .articles_analyzed == 1' <<< "$txt" >/dev/null

# ============================================================================
# Legacy confluence with unavailable sentiment
# ============================================================================
echo ""
echo "Legacy confluence sentinel:"
c_na=$(calculate_confluence_score 60 60 60 60 60 60 na)
assert_equals "60|false|null" "$(jget "$c_na" '(.final_confidence|tostring) + "|" + (.sentiment_available|tostring) + "|" + (.sentiment_contribution|tostring)')" "na sentiment -> final = technical avg, sentiment_available false"
c_100=$(calculate_confluence_score 60 60 60 60 60 60 100)
assert_true "sentiment 100 differs from na (sentiment really weighted when available)" test "$(jget "$c_100" .final_confidence)" != "$(jget "$c_na" .final_confidence)"
assert_equals "$(jget "$c_na" .technical_avg)" "$(jget "$c_na" .final_confidence)" "unavailable sentiment does not move the score"
c_50=$(calculate_confluence_score 70 70 70 70 70 50 50)
expected=$(printf "%.0f" "$(echo "(66 * 0.8) + (50 * 0.2)" | bc)")
assert_equals "$expected|true" "$(jget "$c_50" '(.final_confidence|tostring) + "|" + (.sentiment_available|tostring)')" "legacy 7-arg call unchanged: (technical_avg*0.8)+(50*0.2)"
c_null=$(calculate_confluence_score 60 60 60 60 60 60 null)
assert_equals "false" "$(jget "$c_null" .sentiment_available)" "'null' sentinel also means unavailable"

# ============================================================================
# Real fetch path against a local Finnhub stub
# ============================================================================
echo ""
echo "Finnhub fetch (local stub):"
mkdir -p "$WORK_DIR/fixtures"
cat > "$WORK_DIR/fixtures/company-news" <<'EOF'
[
  {"headline": "Company beats earnings estimates", "summary": "Strong growth and record profit"},
  {"headline": "Analyst issues downgrade", "summary": "Concern over weak demand"},
  {"headline": "Shares rally after upgrade", "summary": ""}
]
EOF
python3 "$TEST_DIR/http_stub.py" "$WORK_DIR/fixtures" "$WORK_DIR/port" "$WORK_DIR/requests.log" &
STUB_PID=$!
for _ in $(seq 1 50); do [[ -f "$WORK_DIR/port" ]] && break; sleep 0.1; done
PORT=$(cat "$WORK_DIR/port" 2>/dev/null)
assert_true "local stub started" test -n "$PORT"

ns=$(SST_OFFLINE=0 ENABLE_FINNHUB=true API_KEY_FINNHUB=testkey FINNHUB_BASE_URL="http://127.0.0.1:$PORT" news_sentiment TEST)
assert_equals "finnhub|3|ok" "$(jget "$ns" '.provider + "|" + (.articles_analyzed|tostring) + "|" + .status')" "news_sentiment uses Finnhub and analyzes 3 articles"
assert_equals "2|1" "$(jget "$ns" '(.positive_count|tostring) + "|" + (.negative_count|tostring)')" "stub articles classified 2 bullish, 1 bearish"
assert_true "Finnhub token sent as header, not in URL" bash -c 'grep -q "company-news?symbol=TEST&from=" "$1" && ! grep -q "token=" "$1" && grep -qi "x-finnhub-token" "$1"' _ "$WORK_DIR/requests.log"
assert_true "successful news result cached" test -f "$SENTIMENT_CACHE_DIR/TEST_news_sentiment.json"
rm -f "$SENTIMENT_CACHE_DIR/TEST_news_sentiment.json"
ag=$(SST_OFFLINE=0 ENABLE_FINNHUB=true API_KEY_FINNHUB=testkey FINNHUB_BASE_URL="http://127.0.0.1:$PORT" aggregate_sentiment TEST)
assert_equals "true|true" "$(jget "$ag" '(.available|tostring) + "|" + ((.sources.news != null)|tostring)')" "aggregate_sentiment available with news source"
assert_equals "$(jget "$ns" .sentiment_score)" "$(jget "$ag" .aggregate_sentiment_score)" "aggregate equals the only available source (news)"
kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; STUB_PID=""

# ============================================================================
# Failure paths are fast
# ============================================================================
echo ""
echo "Failure paths:"
rm -rf "$SENTIMENT_CACHE_DIR"
t0=$(now_ms)
un=$(SST_OFFLINE=0 ENABLE_FINNHUB=true API_KEY_FINNHUB=testkey FINNHUB_BASE_URL="http://127.0.0.1:9" news_sentiment TEST2)
t1=$(now_ms)
assert_equals "unavailable" "$(jget "$un" .status)" "unreachable Finnhub -> unavailable"
assert_true "unreachable Finnhub returns in < 3000 ms ($((t1 - t0)) ms)" test $((t1 - t0)) -lt 3000
assert_true "unavailable result is not cached" test ! -f "$SENTIMENT_CACHE_DIR/TEST2_news_sentiment.json"
t0=$(now_ms)
ph=$(SST_OFFLINE=0 ENABLE_FINNHUB=true API_KEY_FINNHUB=YOUR_API_KEY_FINNHUB ENABLE_NEWSAPI=true API_KEY_NEWSAPI=YOUR_API_KEY_NEWSAPI FINNHUB_BASE_URL="http://127.0.0.1:9" news_sentiment TEST3)
t1=$(now_ms)
assert_equals "unavailable" "$(jget "$ph" .status)" "placeholder keys -> unavailable"
assert_true "placeholder keys return in < 500 ms, no network attempt ($((t1 - t0)) ms)" test $((t1 - t0)) -lt 500
bad=$(SST_OFFLINE=0 API_KEY_FINNHUB=testkey news_sentiment '../etc')
assert_equals "unavailable" "$(jget "$bad" .status)" "invalid symbol rejected before any URL is built"

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
