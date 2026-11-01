#!/bin/bash
# ============================================================================
# Agents: Quant pipeline (offline) (venv suite, no network)
# ============================================================================
# End to end on the offline fixture panel (temp AGENT_CACHE_DIR, HOME,
# SST_STATE_DIR; SST_OFFLINE=1; QUANT_TEST_FAST=1):
#   python -m agents quant ingest --offline
#   python -m agents quant train --offline --arms lgbm,xgb14
#   python -m agents quant predict --offline --as-of <last fixture session>
# exit 0 each; one envelope per offline rank symbol with .agent "quant" and
# .synthetic true; predictions parquet, train manifest, latest.json and the
# MLflow file store under the temp cache (no ./mlruns). Then the bash side:
# lib/agent_adapter.sh agent_get quant QAA is OK with SST_OFFLINE=1, and
# agent_components_json marks it 'synthetic' without SST_OFFLINE.
# No network: a sitecustomize.py first on PYTHONPATH logs and refuses every
# socket connect; the log must stay empty. bash 3.2 compatible.
# Needs AGENTS_PY (the runner exports it; default .venv-agents/bin/python).
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
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sst_agents_quant_pipeline.XXXXXX")"
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
        fail "$3" "expected '$1', got '$2'"
    fi
}

summary() {
    echo ""
    echo "=========================================="
    echo "  Test Summary"
    echo "=========================================="
    echo "Total Tests:  $TESTS_RUN"
    echo "Tests Passed:  $TESTS_PASSED"
    echo "Tests Failed:  $TESTS_FAILED"
    if [[ $TESTS_FAILED -eq 0 && $TESTS_PASSED -gt 0 ]]; then
        echo -e "\n${GREEN}All tests passed!${NC}"
        exit 0
    fi
    echo -e "\n${RED}Some tests failed.${NC}"
    exit 1
}

if [[ ! -x "$AGENTS_PY" ]]; then
    fail "agent venv python found" "$AGENTS_PY is not executable (create .venv-agents first)"
    summary
fi

# --- isolation: temp cache/home/state, no network ------------------------------
NET_LOG="$WORK_DIR/net.log"
: > "$NET_LOG"
mkdir -p "$WORK_DIR/site" "$WORK_DIR/home" "$WORK_DIR/state"
cat > "$WORK_DIR/site/sitecustomize.py" <<'PY'
# Test guard: log and refuse every outbound socket connect (no network).
import os
import socket

_LOG = os.environ.get("SST_NET_LOG")


def _blocked(self, address, *args, **kwargs):
    fam = getattr(self, "family", None)
    if fam == getattr(socket, "AF_UNIX", object()):
        return _orig_connect(self, address)
    if _LOG:
        with open(_LOG, "a") as fh:
            fh.write("connect %r\n" % (address,))
    raise OSError("network disabled by tests/test_agents_quant_pipeline.sh")


def _blocked_ex(self, address):
    try:
        _blocked(self, address)
    except OSError:
        return 111
    return 0


_orig_connect = socket.socket.connect
socket.socket.connect = _blocked
socket.socket.connect_ex = _blocked_ex
PY

CACHE="$WORK_DIR/cache"
export AGENT_CACHE_DIR="$CACHE"
export HOME="$WORK_DIR/home"
export SST_STATE_DIR="$WORK_DIR/state"
export SST_OFFLINE=1
export QUANT_TEST_FAST=1
export QUANT_N_JOBS=2
export SST_NET_LOG="$NET_LOG"
export ALPACA_DATA_URL="http://127.0.0.1:9"
export PYTHONPATH="$WORK_DIR/site${PYTHONPATH:+:$PYTHONPATH}"
unset AGENTS_ENABLED AGENT_TECHNICAL_ENABLED AGENT_QUANT_WEIGHT AGENT_FUNDAMENTAL_WEIGHT AGENT_MARKET_WEIGHT
unset AGENT_MAX_TOTAL_WEIGHT AGENT_MAX_AGE_HOURS AGENT_GATE_MAX_AGE_DAYS QUANT_TTL_HOURS

agents() {
    ( cd "$PROJECT_DIR" && "$AGENTS_PY" -m agents "$@" )
}

had_mlruns=0
[[ -e "$PROJECT_DIR/mlruns" ]] && had_mlruns=1

# Offline rank universe (agents.quant.universe.rank_universe(True))
RANK=$(cd "$PROJECT_DIR" && "$AGENTS_PY" -c 'from agents.quant.universe import rank_universe; print(" ".join(rank_universe(True)))')
n_rank=$(echo "$RANK" | wc -w | tr -d ' ')
assert_equals "15" "$n_rank" "offline rank universe has 15 symbols"

# --- ingest ---------------------------------------------------------------------
out=$(agents quant ingest --offline 2>"$WORK_DIR/ingest.err"); rc=$?
assert_equals "0" "$rc" "quant ingest --offline exits 0"
assert_equals "true" "$(jq -r '.store.synthetic' <<< "$out" 2>/dev/null)" "ingest store is synthetic"
LAST=$(jq -r '.store.calendar_end' <<< "$out" 2>/dev/null)
assert_equals "2022-11-01" "$LAST" "last fixture session"

# --- train ----------------------------------------------------------------------
out=$(agents quant train --offline --arms lgbm,xgb14 2>"$WORK_DIR/train.err"); rc=$?
assert_equals "0" "$rc" "quant train --offline --arms lgbm,xgb14 exits 0"
if jq -e . >/dev/null 2>&1 <<< "$out"; then
    pass "train stdout is one JSON document"
else
    fail "train stdout is one JSON document" "$(head -3 <<< "$out")"
fi
assert_equals "lgbm xgb14" "$(jq -r '.arms | keys_unsorted | join(" ")' <<< "$out" 2>/dev/null)" "train arms"
assert_equals "2" "$(jq -r '.arms.lgbm.folds' <<< "$out" 2>/dev/null)" "lgbm: 2 offline folds"
assert_equals "172" "$(jq -r '.arms.lgbm.n_features' <<< "$out" 2>/dev/null)" "lgbm: 172 features"
assert_equals "14" "$(jq -r '.arms.xgb14.n_features' <<< "$out" 2>/dev/null)" "xgb14: 14 features"
assert_equals "true" "$(jq -r '.synthetic' <<< "$out" 2>/dev/null)" "train summary synthetic"
RID=$(jq -r '.train_run_id' <<< "$out" 2>/dev/null)
for arm in lgbm xgb14; do
    if [[ -s "$CACHE/quant/predictions/$arm.parquet" ]]; then
        pass "predictions/$arm.parquet written"
    else
        fail "predictions/$arm.parquet written"
    fi
done
if [[ -f "$CACHE/quant/models/$RID/train_manifest.json" ]]; then
    pass "models/<run>/train_manifest.json written"
else
    fail "models/<run>/train_manifest.json written" "run id '$RID'"
fi
assert_equals "$RID" "$(jq -r '.train_run_id' "$CACHE/quant/models/latest.json" 2>/dev/null)" "models/latest.json points at the run"
if ls "$CACHE"/quant/mlruns/*/*/meta.yaml >/dev/null 2>&1; then
    pass "MLflow file store under the temp cache"
else
    fail "MLflow file store under the temp cache"
fi
if [[ $had_mlruns -eq 1 || ! -e "$PROJECT_DIR/mlruns" ]]; then
    pass "no ./mlruns created in the repo"
else
    fail "no ./mlruns created in the repo"
fi

# --- predict --------------------------------------------------------------------
out=$(agents quant predict --offline --as-of "$LAST" 2>"$WORK_DIR/predict.err"); rc=$?
assert_equals "0" "$rc" "quant predict --offline --as-of $LAST exits 0"
assert_equals "15" "$(jq -r '.written | length' <<< "$out" 2>/dev/null)" "15 envelopes available"
missing=0; wrong=0
for s in $RANK; do
    f="$CACHE/quant/$LAST/$s.json"
    if [[ ! -f "$f" ]]; then
        missing=$((missing + 1))
        continue
    fi
    [[ "$(jq -r '[.agent, .synthetic, .available, (.warning | length > 0)] | map(tostring) | join(",")' "$f")" == "quant,true,true,true" ]] \
        || wrong=$((wrong + 1))
done
assert_equals "0" "$missing" "an envelope file for every offline rank symbol"
assert_equals "0" "$wrong" "every envelope: agent quant, synthetic true, available, warning"
assert_equals "true" "$(jq -rs 'map(.score) | (max == 100 and min == 0)' "$CACHE/quant/$LAST"/*.json 2>/dev/null)" "percentiles span 0..100"
assert_equals "true" "$(jq -r '.ttl_hours == 84' "$CACHE/quant/$LAST/QAA.json" 2>/dev/null)" "ttl_hours 84"

# --- bash adapter reads the envelopes ---------------------------------------------
source "$PROJECT_DIR/lib/agent_adapter.sh"
got=$(AGENTS_ENABLED=true SST_OFFLINE=1 agent_get quant QAA)
assert_equals "OK" "$(jq -r '.status' <<< "$got")" "agent_get quant QAA: OK (SST_OFFLINE=1)"
assert_equals "$(jq -r '.score' "$CACHE/quant/$LAST/QAA.json")" "$(jq -r '.score' <<< "$got")" "agent_get score = envelope score"
assert_equals "true" "$(jq -r '.synthetic' <<< "$got")" "agent_get synthetic true"
comp=$(AGENTS_ENABLED=true SST_OFFLINE=1 agent_components_json QAA)
assert_equals "no_gate" "$(jq -r '.agents.quant.reason' <<< "$comp")" "components (SST_OFFLINE=1): reason no_gate (no quant_rank gate)"
comp=$(unset SST_OFFLINE; AGENTS_ENABLED=true agent_components_json QAA)
assert_equals "synthetic" "$(jq -r '.agents.quant.reason' <<< "$comp")" "components (SST_OFFLINE unset): reason synthetic"
assert_equals "0" "$(jq -r '.applied_weight' <<< "$comp")" "components: applied weight 0"

# --- status ----------------------------------------------------------------------
out=$(agents quant status 2>/dev/null); rc=$?
assert_equals "0" "$rc" "quant status exits 0"
assert_equals "$RID" "$(jq -r '.models.train_run_id' <<< "$out" 2>/dev/null)" "status: models.train_run_id"
assert_equals "$LAST" "$(jq -r '.envelopes.latest_as_of' <<< "$out" 2>/dev/null)" "status: latest envelope dir"

# --- no network ------------------------------------------------------------------
if [[ ! -s "$NET_LOG" ]]; then
    pass "no network connection attempted"
else
    fail "no network connection attempted" "$(head -5 "$NET_LOG")"
fi

summary
