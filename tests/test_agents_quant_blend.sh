#!/bin/bash
# ============================================================================
# Agents: Quant blend parity (venv suite, offline, no network)
# ============================================================================
# The quant_rank gate signal replays calculate_confluence_score_v2 with an
# applied quant agent in Python (agents/technical/bash_compat.py,
# agent_blend=(w, w x q)). This suite proves the replay equals bash:
#   - windows from tests/fixtures/agents/parity/v2_windows.json (ML absent and
#     ML unavailable, BUY / SELL / HOLD), quant score q in {10, 50, 85},
#     AGENT_QUANT_WEIGHT=0.15, a fresh non-synthetic quant envelope and a
#     PASSED quant_rank gate in a temp AGENT_CACHE_DIR: bash
#     calculate_confluence_score_v2 (AGENTS_ENABLED=true, SST_OFFLINE=1)
#     == Python (confluence_score, recommendation and the whole JSON apart
#     from components.agents / latency / timestamp); bash reports the quant
#     agent as applied
#   - two windows with sentiment 70 (agents before sentiment, weights
#     rescaled by both)
#   - AGENT_QUANT_WEIGHT=0: score and recommendation identical to agents off
#     (shadow), and Python agent_blend=(0, 0) == the plain replay
# ML absent: `unset -f ml_predict_direction` (neutral 50). ML unavailable:
# the yfinance_empty stub with SST_OFFLINE=0 (no network).
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"
AGENTS_PY="${AGENTS_PY:-$PROJECT_DIR/.venv-agents/bin/python}"
WINDOWS="$TEST_DIR/fixtures/agents/parity/v2_windows.json"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sst_quant_blend.XXXXXX")"
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
    if [[ "$1" == "$2" ]]; then
        pass "$3"
    else
        fail "$3" "Expected: '$1'  Got: '$2'"
    fi
}

summary() {
    echo ""
    echo "=========================================="
    echo "  Test Summary"
    echo "=========================================="
    echo "Total Tests:  $TESTS_RUN"
    echo "Tests Passed: $TESTS_PASSED"
    echo "Tests Failed: $TESTS_FAILED"
    if [[ $TESTS_FAILED -eq 0 && $TESTS_PASSED -gt 0 ]]; then
        echo -e "\n${GREEN}All tests passed!${NC}"
        exit 0
    fi
    echo -e "\n${RED}Some tests failed.${NC}"
    exit 1
}

if [[ ! -x "$AGENTS_PY" ]]; then
    fail "agent venv python at $AGENTS_PY" "create it: ./setup.sh --with-agents (or python3.12 -m venv .venv-agents && .venv-agents/bin/pip install -r requirements-agents.txt)"
    summary
fi

TODAY=$(TZ=America/New_York date +%Y-%m-%d)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# mk_cache DIR SCORE: quant envelope SCORE for AAA/BBB/CCC + PASSED quant_rank gate
mk_cache() {
    local dir=$1 score=$2 s
    mkdir -p "$dir/quant/$TODAY" "$dir/gates"
    for s in AAA BBB CCC; do
        jq -n --arg s "$s" --arg d "$TODAY" --arg t "$NOW" --argjson sc "$score" '
            {agent:"quant", agent_version:"0.2.0", symbol:$s, as_of:$d, generated_at:$t, ttl_hours:84,
             available:true, reason:null, data_sources:["alpaca:sip"], synthetic:false, score:$sc,
             direction:"neutral", confidence:0.5, veto:{active:false, code:null, detail:null},
             features:{}, evidence:[], llm:{mode:"none", model:null, tokens:0, cost_usd:0, cached:false},
             validation:{gate_id:"quant_rank", passed:true}, warning:null}' > "$dir/quant/$TODAY/$s.json"
    done
    jq -n --arg t "$NOW" '{signal_id:"quant_rank", generated_at:$t, passed:true, synthetic:false}' \
        > "$dir/gates/quant_rank.json"
}
for q in 10 50 85; do mk_cache "$WORK_DIR/cache_q$q" "$q"; done

# Cases + Python expectations (one JSON line per case)
cd "$PROJECT_DIR" || exit 1
"$AGENTS_PY" - "$WINDOWS" > "$WORK_DIR/cases.jsonl" 2> "$WORK_DIR/helper.err" <<'PY'
import json, sys
from agents.technical import bash_compat as bc

wins = json.load(open(sys.argv[1]))
picked, want = [], {"SELL": 3, "BUY": 4, "HOLD": 3}
for w in sorted(wins, key=lambda x: x["id"]):
    rec = w["confluence_v2"]["recommendation"]
    if w["ml_mode"] == "absent" and want.get(rec, 0) > 0:
        picked.append(w)
        want[rec] -= 1
picked += [w for w in sorted(wins, key=lambda x: x["id"]) if w["ml_mode"] == "unavailable"][:2]

def args_of(w):
    c = w["confluence_v2"]
    i = c["breakdown"]["individual_scores"]
    return [w["symbol"], str(i["rsi"]), str(i["macd"]), str(i["bollinger_bands"]), str(i["obv"]),
            c["components"]["regime_score"]["regime"], str(i["mean_reversion"]), str(i["trend_following"]),
            str(i["kalman_trend"])]

def case(w, q, weight, sentiment="na"):
    a = args_of(w)
    blend = (weight, weight * q) if weight > 0 else None
    # ML unavailable: the reason text the yfinance_empty stub gives in bash
    ml = w["ml_mode"] if w["ml_mode"] == "absent" else {
        "available": False, "reason": "yfinance returned no data for %s" % w["symbol"]}
    py = bc.calculate_confluence_score_v2(*a, sentiment=sentiment, ml_mode=ml, agent_blend=blend)
    plain = bc.calculate_confluence_score_v2(*a, sentiment=sentiment, ml_mode=ml)
    zero = bc.calculate_confluence_score_v2(*a, sentiment=sentiment, ml_mode=ml, agent_blend=(0.0, 0.0))
    return {"id": w["id"], "q": q, "weight": weight, "ml": w["ml_mode"], "args": a + [sentiment],
            "python": py, "plain": plain, "zero_equals_plain": zero == plain,
            "stored": {"confluence_score": w["confluence_v2"]["confluence_score"],
                       "recommendation": w["confluence_v2"]["recommendation"]}}

for w in picked:
    for q in (10, 50, 85):
        print(json.dumps(case(w, q, 0.15)))
for w in picked[:2]:
    print(json.dumps(case(w, 50, 0.15, sentiment="70")))
for w in picked[:4]:
    print(json.dumps(case(w, 85, 0.0)))
PY
rc=$?
if [[ $rc -ne 0 ]]; then
    fail "python helper exited 0" "$(tail -5 "$WORK_DIR/helper.err")"
    summary
fi
n_cases=$(wc -l < "$WORK_DIR/cases.jsonl" | tr -d ' ')
[[ "$n_cases" -ge 30 ]] && pass "python helper wrote $n_cases cases (>= 6 windows x 3 quant scores + extras)" \
    || fail "python helper wrote >= 30 cases" "got $n_cases"

# bash_v2 ML Q WEIGHT ARGS... -> calculate_confluence_score_v2 JSON (agents on)
bash_v2() {
    local ml=$1 q=$2 weight=$3
    shift 3
    local envs=(PATH="$PATH" HOME="$WORK_DIR/home" TMPDIR="${TMPDIR:-/tmp}" LANG=C LC_ALL=C
                REGIME_CACHE_DIR="$WORK_DIR/regime" AGENTS_ENABLED=true AGENT_CACHE_DIR="$WORK_DIR/cache_q$q"
                AGENT_QUANT_WEIGHT="$weight")
    if [[ "$ml" == "unavailable" ]]; then
        envs+=(SST_OFFLINE=0 PYTHONPATH="$TEST_DIR/stubs/yfinance_empty" ML_TIMEOUT_SECONDS=30)
    else
        envs+=(SST_OFFLINE=1)
    fi
    env -i "${envs[@]}" /bin/bash -c '
        source "$1/lib/scoring.sh" >/dev/null 2>&1
        [[ "$2" == "absent" ]] && unset -f ml_predict_direction
        shift 2
        calculate_confluence_score_v2 "$@" </dev/null 2>/dev/null' _ "$PROJECT_DIR" "$ml" "$@"
}

# bash_v2_off ML ARGS... -> agents off
bash_v2_off() {
    local ml=$1
    shift
    local envs=(PATH="$PATH" HOME="$WORK_DIR/home" TMPDIR="${TMPDIR:-/tmp}" LANG=C LC_ALL=C
                REGIME_CACHE_DIR="$WORK_DIR/regime")
    if [[ "$ml" == "unavailable" ]]; then
        envs+=(SST_OFFLINE=0 PYTHONPATH="$TEST_DIR/stubs/yfinance_empty" ML_TIMEOUT_SECONDS=30)
    else
        envs+=(SST_OFFLINE=1)
    fi
    env -i "${envs[@]}" /bin/bash -c '
        source "$1/lib/scoring.sh" >/dev/null 2>&1
        [[ "$2" == "absent" ]] && unset -f ml_predict_direction
        shift 2
        calculate_confluence_score_v2 "$@" </dev/null 2>/dev/null' _ "$PROJECT_DIR" "$ml" "$@"
}
mkdir -p "$WORK_DIR/home"

echo ""
echo "Python agent blend vs bash calculate_confluence_score_v2:"
moved=0
while IFS= read -r c; do
    id=$(jq -r .id <<< "$c"); q=$(jq -r .q <<< "$c"); weight=$(jq -r .weight <<< "$c"); ml=$(jq -r .ml <<< "$c")
    args=()
    while IFS= read -r a; do args+=("$a"); done < <(jq -r '.args[]' <<< "$c")
    sent=${args[9]}
    label="$id q=$q w=$weight sentiment=$sent"
    out=$(bash_v2 "$ml" "$q" "$weight" "${args[@]}")
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$out"; then
        fail "$label: bash returned JSON" "${out:0:200}"
        continue
    fi
    py_sr=$(jq -r '.python | "\(.confluence_score)|\(.recommendation)"' <<< "$c")
    bash_sr=$(jq -r '"\(.confluence_score)|\(.recommendation)"' <<< "$out")
    if [[ "$weight" == "0" || "$weight" == "0.0" ]]; then
        off=$(bash_v2_off "$ml" "${args[@]}")
        assert_equals "$(jq -r '"\(.confluence_score)|\(.recommendation)"' <<< "$off")" "$bash_sr" \
            "$label: AGENT_QUANT_WEIGHT=0 -> bash score/recommendation identical to agents off"
        assert_equals "shadow|0" "$(jq -r '.components.agents.quant | "\(.reason)|\(.weight_percent)"' <<< "$out")" \
            "$label: quant agent in shadow mode"
        assert_equals "true|$(jq -r '.plain | "\(.confluence_score)|\(.recommendation)"' <<< "$c")" \
            "$(jq -r '.zero_equals_plain' <<< "$c")|$bash_sr" "$label: Python agent_blend=(0, 0) == plain replay == bash"
        continue
    fi
    assert_equals "$py_sr" "$bash_sr" "$label: confluence_score|recommendation Python == bash ($bash_sr)"
    assert_equals "applied|true" "$(jq -r '.components.agents.quant | "\(.reason)|\(.applied)"' <<< "$out")" \
        "$label: bash applied the quant agent"
    want=$(jq -S -c '.python' <<< "$c")
    got=$(jq -S -c 'del(.components.agents, .metadata.latency_ms, .metadata.timestamp)' <<< "$out")
    assert_equals "$want" "$got" "$label: whole v2 JSON (weights included) Python == bash"
    [[ "$(jq -r '.plain.confluence_score' <<< "$c")" != "$(jq -r '.python.confluence_score' <<< "$c")" ]] && moved=$((moved + 1))
    if [[ "$sent" == "na" && "$ml" == "absent" ]]; then
        assert_equals "$(jq -r '.stored | "\(.confluence_score)|\(.recommendation)"' <<< "$c")" \
            "$(jq -r '.plain | "\(.confluence_score)|\(.recommendation)"' <<< "$c")" "$label: plain replay == stored bash golden"
    fi
done < "$WORK_DIR/cases.jsonl"
[[ $moved -gt 0 ]] && pass "the quant blend moved the score in $moved cases" || fail "the quant blend moved some score" "0 cases"

summary
