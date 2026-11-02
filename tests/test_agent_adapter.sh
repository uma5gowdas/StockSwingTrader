#!/bin/bash
# ============================================================================
# Unit Tests: Agent Cache Adapter (lib/agent_adapter.sh)
# ============================================================================
# agent_get / agent_gate_get statuses, path traversal, latest-dir selection,
# ttl, weight clamp and cap, agent_components_json reasons, and no network:
# curl/wget/nc/python are shadowed by logging functions and the non-comment
# code of the adapter must not call them. bash 3.2 + jq; no venv needed.
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sst_agent_adapter_test.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
export AGENT_CACHE_DIR="$WORK_DIR/cache"
NET_LOG="$WORK_DIR/net.log"
: > "$NET_LOG"
export NET_LOG
unset AGENTS_ENABLED AGENT_TECHNICAL_ENABLED AGENT_QUANT_WEIGHT AGENT_FUNDAMENTAL_WEIGHT AGENT_MARKET_WEIGHT
unset AGENT_MAX_TOTAL_WEIGHT AGENT_MAX_AGE_HOURS AGENT_GATE_MAX_AGE_DAYS

# Network shadows: any call is logged (and fails)
curl() { echo "curl $*" >> "$NET_LOG"; return 1; }
wget() { echo "wget $*" >> "$NET_LOG"; return 1; }
nc() { echo "nc $*" >> "$NET_LOG"; return 1; }
python() { echo "python $*" >> "$NET_LOG"; return 1; }
python3() { echo "python3 $*" >> "$NET_LOG"; return 1; }
export -f curl wget nc python python3

source "$PROJECT_DIR/lib/agent_adapter.sh"
source "$PROJECT_DIR/lib/portable.sh"

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

assert_no_network() {
    assert_equals "0" "$(wc -l < "$NET_LOG" | tr -d ' ')" "no curl/wget/nc/python call ($1)"
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

day_offset() {  # day_offset N -> America/New_York date N days from today
    TZ=America/New_York sst_date_offset_days "$1" %Y-%m-%d
}

TODAY=$(day_offset 0)

# write_env AGENT SYMBOL [DIR_DATE] [jq overrides]
write_env() {
    local agent=$1 sym=$2 d=${3:-$TODAY} extra=${4:-.}
    mkdir -p "$AGENT_CACHE_DIR/$agent/$d"
    jq -n --arg a "$agent" --arg s "$sym" --arg d "$d" --arg t "$(iso_now)" '
        {agent:$a, agent_version:"0.1.0", symbol:$s, as_of:$d, generated_at:$t, ttl_hours:36,
         available:true, reason:null, data_sources:["alpaca:sip"], synthetic:false, score:70,
         direction:"bullish", confidence:0.6, veto:{active:false, code:null, detail:null},
         features:{k:1}, evidence:[], llm:{mode:"none", model:null, tokens:0, cost_usd:0, cached:false},
         validation:{gate_id:null, passed:false}, warning:null}' | jq "$extra" > "$AGENT_CACHE_DIR/$agent/$d/$sym.json"
}

# write_gate SIGNAL [jq overrides]
write_gate() {
    mkdir -p "$AGENT_CACHE_DIR/gates"
    jq -n --arg s "$1" --arg t "$(iso_now)" '{signal_id:$s, generated_at:$t, passed:true, synthetic:false,
        data_sources:["alpaca:sip"], metrics:{}}' | jq "${2:-.}" > "$AGENT_CACHE_DIR/gates/$1.json"
}

status_of() {
    jget "$(agent_get "$@")" .status
}

# ============================================================================
# agent_get
# ============================================================================
echo "agent_get:"
write_env quant AAPL
assert_equals "DISABLED" "$(status_of quant AAPL)" "AGENTS_ENABLED unset -> DISABLED"
assert_equals "DISABLED" "$(AGENTS_ENABLED=false status_of quant AAPL)" "AGENTS_ENABLED=false -> DISABLED"
assert_equals "null" "$(jget "$(agent_get quant AAPL)" .score)" "DISABLED -> score null"
export AGENTS_ENABLED=true

out=$(agent_get quant AAPL)
assert_equals "OK|70|bullish|0.6|false|$TODAY" "$(jget "$out" '"\(.status)|\(.score)|\(.direction)|\(.confidence)|\(.synthetic)|\(.as_of)"')" "fresh envelope -> OK with score, direction, confidence"
assert_equals "age_hours,agent,as_of,available,confidence,direction,features,generated_at,reason,score,status,symbol,synthetic,veto" \
    "$(jget "$out" 'keys | join(",")')" "agent_get returns the documented fields"
assert_equals "OK" "$(status_of quant aapl)" "lowercase symbol resolves to the same file"
assert_equals "MISSING" "$(status_of quant MSFT)" "no cache file -> MISSING"
assert_equals "MISSING" "$(status_of fundamental AAPL)" "other agent, no file -> MISSING"

write_env technical AAPL
assert_equals "DISABLED" "$(status_of technical AAPL)" "technical without AGENT_TECHNICAL_ENABLED -> DISABLED"
assert_equals "OK" "$(AGENT_TECHNICAL_ENABLED=true status_of technical AAPL)" "technical with AGENT_TECHNICAL_ENABLED=true -> OK"

assert_equals "INVALID" "$(status_of quant '../etc')" "path traversal symbol -> INVALID"
assert_equals "INVALID" "$(status_of quant 'A..B')" "symbol with '..' -> INVALID"
assert_equals "INVALID" "$(status_of quant '')" "empty symbol -> INVALID"
assert_equals "INVALID" "$(status_of '../quant' AAPL)" "agent with traversal -> INVALID"
assert_equals "INVALID" "$(status_of nope AAPL)" "unknown agent -> INVALID"
assert_equals "INVALID" "$(status_of quant AAPL '../2026-01-01')" "bad as_of -> INVALID"
assert_equals "1" "$(agent_cache_file quant '../x' >/dev/null; echo $?)" "agent_cache_file rejects traversal (rc 1)"

mkdir -p "$AGENT_CACHE_DIR/quant/$TODAY"
echo '{"agent":"quant", "symbol": ' > "$AGENT_CACHE_DIR/quant/$TODAY/BAD.json"
assert_equals "INVALID" "$(status_of quant BAD)" "unparsable JSON -> INVALID"
echo '[1,2]' > "$AGENT_CACHE_DIR/quant/$TODAY/ARR.json"
assert_equals "INVALID" "$(status_of quant ARR)" "JSON array -> INVALID"
write_env quant MIS "$TODAY" '.agent = "market"'
assert_equals "INVALID" "$(status_of quant MIS)" ".agent mismatch -> INVALID"
write_env quant SYMX "$TODAY" '.symbol = "OTHER"'
assert_equals "INVALID" "$(status_of quant SYMX)" ".symbol mismatch -> INVALID"
write_env quant TS "$TODAY" '.generated_at = "yesterday"'
assert_equals "INVALID" "$(status_of quant TS)" "unparsable generated_at -> INVALID"
write_env quant FUT "$TODAY" ".generated_at = \"$(iso_hours_ahead 2)\""
assert_equals "INVALID" "$(status_of quant FUT)" "generated_at 2 h in the future -> INVALID"
write_env quant BIG "$TODAY" '.score = 150'
assert_equals "INVALID" "$(status_of quant BIG)" "score 150 -> INVALID"
write_env quant STR "$TODAY" '.score = "70"'
assert_equals "INVALID" "$(status_of quant STR)" "score as string -> INVALID"
write_env quant AVB "$TODAY" '.available = "yes"'
assert_equals "INVALID" "$(status_of quant AVB)" "available not boolean -> INVALID"
write_env quant NUL "$TODAY" '.score = null'
assert_equals "OK|null" "$(jget "$(agent_get quant NUL)" '"\(.status)|\(.score)"')" "score null is allowed (OK, score null)"

write_env quant OLD "$TODAY" ".generated_at = \"$(iso_hours_ago 40)\""
assert_equals "STALE|null" "$(jget "$(agent_get quant OLD)" '"\(.status)|\(.score)"')" "40 h old, ttl_hours 36 -> STALE, score null"
write_env quant TTL "$TODAY" ".generated_at = \"$(iso_hours_ago 40)\" | .ttl_hours = 48"
assert_equals "OK" "$(status_of quant TTL)" "40 h old, ttl_hours 48 -> OK (file ttl wins)"
write_env quant NOTTL "$TODAY" ".generated_at = \"$(iso_hours_ago 20)\" | del(.ttl_hours)"
assert_equals "OK" "$(status_of quant NOTTL)" "20 h old, no ttl -> AGENT_MAX_AGE_HOURS 36 -> OK"
assert_equals "STALE" "$(AGENT_MAX_AGE_HOURS=10 status_of quant NOTTL)" "20 h old, no ttl, AGENT_MAX_AGE_HOURS=10 -> STALE"

write_env quant UNA "$TODAY" '.available = false | .score = null | .data_sources = [] | .reason = "no market data"'
out=$(agent_get quant UNA)
assert_equals "UNAVAILABLE|null|no market data" "$(jget "$out" '"\(.status)|\(.score)|\(.reason)"')" "available false -> UNAVAILABLE with reason"
write_env quant SYN "$TODAY" '.synthetic = true | .warning = "fixture"'
assert_equals "OK|true" "$(jget "$(agent_get quant SYN)" '"\(.status)|\(.synthetic)"')" "synthetic envelope -> OK, synthetic true"
assert_no_network "agent_get"

# Latest-dir selection
echo ""
echo "Latest dir:"
write_env market LAT "2020-01-01" '.score = 10 | .ttl_hours = 1000000'
write_env market LAT "$(day_offset -1)" '.score = 20'
write_env market LAT "$(day_offset 1)" '.score = 30'
write_env market OTHER "$TODAY"
assert_equals "20|$(day_offset -1)" "$(jget "$(agent_get market LAT)" '"\(.score)|\(.as_of)"')" "newest dir <= today holding the symbol (future dir and other-symbol dir ignored)"
assert_equals "10" "$(jget "$(agent_get market LAT 2020-01-01)" .score)" "explicit AS_OF selects that dir"
assert_equals "MISSING" "$(status_of market LAT 2019-12-31)" "explicit AS_OF without file -> MISSING"
assert_equals "$AGENT_CACHE_DIR/market/$(day_offset -1)/LAT.json" "$(agent_cache_file market LAT)" "agent_cache_file prints the selected path"
assert_equals "2" "$(agent_cache_file market NONE >/dev/null; echo $?)" "agent_cache_file: nothing found -> rc 2"
rel=$(AGENT_CACHE_DIR=cache/agents agent_cache_dir)
assert_equals "$PROJECT_DIR/cache/agents" "$rel" "relative AGENT_CACHE_DIR resolves against the project root"

# ============================================================================
# agent_gate_get
# ============================================================================
echo ""
echo "agent_gate_get:"
gate_status() { jget "$(agent_gate_get "$1")" '"\(.status)|\(.passed)"'; }
assert_equals "MISSING|false" "$(gate_status quant_rank)" "no gate file -> MISSING"
assert_equals "INVALID|false" "$(gate_status '../x')" "bad signal id -> INVALID"
assert_equals "INVALID|false" "$(gate_status 'Quant')" "uppercase signal id -> INVALID"
write_gate quant_rank
out=$(agent_gate_get quant_rank)
assert_equals "PASSED|true|0" "$(jget "$out" '"\(.status)|\(.passed)|\(.age_days)"')" "fresh passed gate -> PASSED"
assert_equals "age_days,passed,signal_id,status" "$(jget "$out" 'keys | join(",")')" "gate result fields"
write_gate g_fail '.passed = false'
assert_equals "FAILED|false" "$(gate_status g_fail)" "passed false -> FAILED"
write_gate g_syn '.synthetic = true'
assert_equals "SYNTHETIC|false" "$(gate_status g_syn)" "synthetic gate -> SYNTHETIC (never passes)"
write_gate g_old ".generated_at = \"$(iso_hours_ago 1200)\""
assert_equals "EXPIRED|false" "$(gate_status g_old)" "50-day-old gate -> EXPIRED (default 45 days)"
assert_equals "PASSED|true" "$(AGENT_GATE_MAX_AGE_DAYS=60 gate_status g_old)" "AGENT_GATE_MAX_AGE_DAYS=60 -> PASSED"
write_gate g_mis '.signal_id = "other"'
assert_equals "INVALID|false" "$(gate_status g_mis)" "signal_id mismatch -> INVALID"
write_gate g_pb '.passed = "true"'
assert_equals "INVALID|false" "$(gate_status g_pb)" "passed not boolean -> INVALID"
write_gate g_fut ".generated_at = \"$(iso_hours_ahead 3)\""
assert_equals "INVALID|false" "$(gate_status g_fut)" "future gate -> INVALID"
echo 'not json' > "$AGENT_CACHE_DIR/gates/g_bad.json"
assert_equals "INVALID|false" "$(gate_status g_bad)" "unparsable gate -> INVALID"
assert_no_network "agent_gate_get"

# ============================================================================
# Weights
# ============================================================================
echo ""
echo "Weights:"
assert_equals "0" "$(agent_effective_weight quant)" "weights default 0"
assert_equals "0.1" "$(AGENT_QUANT_WEIGHT=0.1 agent_effective_weight quant)" "0.1 kept"
assert_equals "0.3" "$(AGENT_FUNDAMENTAL_WEIGHT=0.9 agent_effective_weight fundamental)" "0.9 clamped to 0.30"
assert_equals "0.2" "$(AGENT_MARKET_WEIGHT=.2 agent_effective_weight market)" ".2 accepted"
assert_equals "0" "$(AGENT_QUANT_WEIGHT=abc agent_effective_weight quant)" "non-numeric -> 0"
assert_equals "0" "$(AGENT_QUANT_WEIGHT=-0.1 agent_effective_weight quant)" "negative -> 0"
assert_equals "0" "$(AGENT_QUANT_WEIGHT=0.2 agent_effective_weight technical)" "non-additive agent -> 0"
assert_equals "0.3" "$(agent_max_total_weight)" "AGENT_MAX_TOTAL_WEIGHT default 0.30"
assert_equals "0.5" "$(AGENT_MAX_TOTAL_WEIGHT=0.9 agent_max_total_weight)" "AGENT_MAX_TOTAL_WEIGHT clamped to 0.5"
assert_equals "0.3" "$(AGENT_MAX_TOTAL_WEIGHT=x agent_max_total_weight)" "AGENT_MAX_TOTAL_WEIGHT non-numeric -> 0.30"

# ============================================================================
# agent_components_json
# ============================================================================
echo ""
echo "agent_components_json:"
reasons() { jget "$1" '[.agents.quant.reason, .agents.fundamental.reason, .agents.market.reason] | join(",")'; }
rm -rf "$AGENT_CACHE_DIR"
out=$(AGENTS_ENABLED=false agent_components_json AAPL)
assert_equals "disabled,disabled,disabled|0|0" "$(reasons "$out")|$(jget "$out" .applied_weight)|$(jget "$out" .weighted_sum)" "disabled -> reasons disabled, weight 0"
assert_equals "missing,missing,missing" "$(reasons "$(agent_components_json AAPL)")" "no files -> missing"
write_env quant AAPL "$TODAY" '.score = 80'
write_env fundamental AAPL "$TODAY" '.score = 60'
write_env market AAPL "$TODAY" '.score = 40'
assert_equals "no_gate,no_gate,no_gate" "$(reasons "$(agent_components_json AAPL)")" "OK caches without gates -> no_gate"
write_gate quant_rank
write_gate fundamental_quality
write_gate market_news_score
out=$(agent_components_json AAPL)
assert_equals "shadow,shadow,shadow|0|0" "$(reasons "$out")|$(jget "$out" .applied_weight)|$(jget "$out" .weighted_sum)" "OK + PASSED, weights 0 -> shadow, nothing applied"
assert_equals "80|OK|0|false|quant_rank|PASSED" "$(jget "$out" '.agents.quant | "\(.score)|\(.status)|\(.weight)|\(.applied)|\(.signal_id)|\(.gate_status)"')" "per-agent fields (score, status, weight, applied, signal, gate)"
out=$(AGENT_QUANT_WEIGHT=0.1 agent_components_json AAPL)
assert_equals "applied,shadow,shadow|0.1|8" "$(reasons "$out")|$(jget "$out" .applied_weight)|$(jget "$out" .weighted_sum)" "quant 0.1 -> applied, weighted_sum 8"
out=$(AGENT_QUANT_WEIGHT=0.3 AGENT_FUNDAMENTAL_WEIGHT=0.3 AGENT_MARKET_WEIGHT=0.3 agent_components_json AAPL)
assert_equals "0.3" "$(jget "$out" '.applied_weight * 1000 | round / 1000')" "3 x 0.30 -> total capped at 0.30"
assert_equals "0.1|0.1|0.1" "$(jget "$out" '[.agents[] | .weight * 1000 | round / 1000 | tostring] | join("|")')" "cap scales each weight proportionally (0.1 each)"
assert_equals "18" "$(jget "$out" '.weighted_sum * 1000 | round / 1000')" "weighted_sum = 0.1 x (80 + 60 + 40)"
out=$(AGENT_QUANT_WEIGHT=0.2 AGENT_MARKET_WEIGHT=0.2 AGENT_MAX_TOTAL_WEIGHT=0.2 agent_components_json AAPL)
assert_equals "0.2|0.1|0.1|12" "$(jget "$out" '[(.applied_weight, .agents.quant.weight, .agents.market.weight, .weighted_sum) * 1000 | round / 1000 | tostring] | join("|")')" "custom cap 0.2 over 0.4 requested -> 0.1 each"

write_gate quant_rank '.passed = false'
write_gate fundamental_quality ".generated_at = \"$(iso_hours_ago 1200)\""
write_gate market_news_score '.synthetic = true'
assert_equals "gate_failed,gate_expired,gate_synthetic" "$(reasons "$(AGENT_QUANT_WEIGHT=0.1 AGENT_FUNDAMENTAL_WEIGHT=0.1 AGENT_MARKET_WEIGHT=0.1 agent_components_json AAPL)")" "failed / expired / synthetic gates -> weight 0 with reasons"
assert_equals "0" "$(jget "$(AGENT_QUANT_WEIGHT=0.1 AGENT_FUNDAMENTAL_WEIGHT=0.1 AGENT_MARKET_WEIGHT=0.1 agent_components_json AAPL)" .applied_weight)" "no gate passed -> applied_weight 0"
write_gate quant_rank
write_gate fundamental_quality
write_gate market_news_score
write_env quant AAPL "$TODAY" ".generated_at = \"$(iso_hours_ago 40)\""
write_env fundamental AAPL "$TODAY" '.available = false | .score = null | .data_sources = [] | .reason = "x"'
write_env market AAPL "$TODAY" '.synthetic = true | .warning = "fixture"'
w3="AGENT_QUANT_WEIGHT=0.1 AGENT_FUNDAMENTAL_WEIGHT=0.1 AGENT_MARKET_WEIGHT=0.1"
assert_equals "stale,unavailable,synthetic" "$(reasons "$(env $w3 SST_OFFLINE=0 bash -c 'source "$1"; agent_components_json AAPL' _ "$PROJECT_DIR/lib/agent_adapter.sh")")" "stale / unavailable / synthetic (online) -> weight 0"
assert_equals "applied" "$(jget "$(env $w3 SST_OFFLINE=1 bash -c 'source "$1"; agent_components_json AAPL' _ "$PROJECT_DIR/lib/agent_adapter.sh")" .agents.market.reason)" "synthetic cache allowed only with SST_OFFLINE=1"
echo '{' > "$AGENT_CACHE_DIR/quant/$TODAY/AAPL.json"
assert_equals "invalid" "$(jget "$(agent_components_json AAPL)" .agents.quant.reason)" "invalid cache -> invalid"
assert_no_network "agent_components_json"

# ============================================================================
# No network in the adapter code
# ============================================================================
echo ""
echo "Network isolation:"
assert_equals "0" "$(grep -v '^[[:space:]]*#' "$PROJECT_DIR/lib/agent_adapter.sh" | grep -cE '(^|[^a-z_])(curl|wget|nc|python3?)([^a-z_]|$)')" "lib/agent_adapter.sh code (non-comment) has no curl/wget/nc/python calls"
assert_equals "0" "$(grep -cE '(^|[^A-Z_])(SCRIPT_DIR|LIB_DIR|AGENT_DIR)=|set -e|errexit' "$PROJECT_DIR/lib/agent_adapter.sh")" "adapter does not reassign SCRIPT_DIR/LIB_DIR/AGENT_DIR or enable errexit"
assert_no_network "whole suite"

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
