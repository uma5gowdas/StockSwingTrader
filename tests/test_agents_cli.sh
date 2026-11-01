#!/bin/bash
# ============================================================================
# Agents: CLI (offline) (venv suite, no network)
# ============================================================================
# `python -m agents validate gate --offline --report-dir DIR` exits 0 and
# writes 4 gate files (temp AGENT_CACHE_DIR) with passed false and the reason
# synthetic_data, plus report.html (balanced tags, SYNTHETIC banner) and
# report.json; lib/agent_adapter.sh agent_gate_get reads every gate as
# SYNTHETIC (cross-language contract); a missing symbol exits 2 and writes no
# gate; `validate parity --offline` exits 0; `technical run --offline
# --symbols ZZZ` exits 2; `validate status` exits 0 and lists the 4 gates.
# No network: ALPACA_DATA_URL points at 127.0.0.1:9 and a sitecustomize.py
# put first on PYTHONPATH logs and refuses every socket connect; the log must
# stay empty.
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

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sst_agents_cli.XXXXXX")"
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

summary() {
    echo ""
    echo "=========================================="
    echo "  Test Summary"
    echo "=========================================="
    echo "Total Tests:  $TESTS_RUN"
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"
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

# --- isolation: temp cache, no network ---------------------------------------
NET_LOG="$WORK_DIR/net.log"
: > "$NET_LOG"
mkdir -p "$WORK_DIR/site"
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
    raise OSError("network disabled by tests/test_agents_cli.sh")


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

export AGENT_CACHE_DIR="$WORK_DIR/cache"
export SST_OFFLINE=1
export SST_NET_LOG="$NET_LOG"
export ALPACA_DATA_URL="http://127.0.0.1:9"
export PYTHONPATH="$WORK_DIR/site${PYTHONPATH:+:$PYTHONPATH}"
unset AGENTS_ENABLED AGENT_GATE_MAX_AGE_DAYS

agents() {
    ( cd "$PROJECT_DIR" && "$AGENTS_PY" -m agents "$@" )
}

# sitecustomize is active (sanity: a connect attempt is logged and refused)
probe=$(cd "$PROJECT_DIR" && "$AGENTS_PY" -c '
import socket
s = socket.socket()
try:
    s.connect(("127.0.0.1", 9))
    print("connected")
except OSError as e:
    print("refused")
' 2>/dev/null)
if [[ "$probe" == "refused" ]] && grep -q "connect" "$NET_LOG"; then
    pass "network guard active (connect refused and logged)"
else
    fail "network guard active (connect refused and logged)" "probe=$probe"
fi
: > "$NET_LOG"

# --- validate gate --offline ---------------------------------------------------
REPORT_DIR="$WORK_DIR/report"
OUT="$WORK_DIR/gate.json"
echo "Running validate gate --offline (vectorbt + v2 replay, ~1 min)..."
agents validate gate --offline --report-dir "$REPORT_DIR" > "$OUT" 2> "$WORK_DIR/gate.err"
rc=$?
if [[ $rc -eq 0 ]]; then
    pass "validate gate --offline exits 0"
else
    fail "validate gate --offline exits 0" "rc=$rc $(tail -5 "$WORK_DIR/gate.err")"
fi

if jq -e '.run_id and (.gates | length == 4) and .synthetic == true' "$OUT" >/dev/null 2>&1; then
    pass "summary JSON has run_id, 4 gates, synthetic true"
else
    fail "summary JSON has run_id, 4 gates, synthetic true" "$(head -c 400 "$OUT")"
fi

for sig in v2_confluence v2_confluence_adx mr_only tf_only; do
    f="$AGENT_CACHE_DIR/gates/$sig.json"
    if [[ -f "$f" ]] && jq -e --arg s "$sig" '.signal_id == $s and .passed == false and .synthetic == true
            and (.reasons | index("synthetic_data") != null) and .agent == "validate"
            and (.criteria | length == 8) and (.folds | length == 2)' "$f" >/dev/null 2>&1; then
        pass "gate file $sig: passed false, synthetic, reason synthetic_data"
    else
        fail "gate file $sig: passed false, synthetic, reason synthetic_data" "$(head -c 300 "$f" 2>/dev/null)"
    fi
    g=$(source "$PROJECT_DIR/lib/agent_adapter.sh" >/dev/null 2>&1; agent_gate_get "$sig")
    if [[ "$(jq -r '.status + "|" + (.passed | tostring)' <<< "$g" 2>/dev/null)" == "SYNTHETIC|false" ]]; then
        pass "agent_gate_get $sig reads the Python gate as SYNTHETIC (contract)"
    else
        fail "agent_gate_get $sig reads the Python gate as SYNTHETIC (contract)" "$g"
    fi
done

# Every gate file validates against the schema
schema_out=$(cd "$PROJECT_DIR" && "$AGENTS_PY" -c '
import json, sys
from pathlib import Path
from agents.validate.gate import gate_errors
bad = 0
for p in sorted(Path(sys.argv[1]).glob("*.json")):
    errs = gate_errors(json.loads(p.read_text()))
    if errs:
        bad += 1
        print(p.name, errs[:3])
print("BAD=%d" % bad)
' "$AGENT_CACHE_DIR/gates" 2>&1)
if [[ "$schema_out" == *"BAD=0"* ]]; then
    pass "4 gate files validate against agents/schemas/gate.schema.json"
else
    fail "4 gate files validate against agents/schemas/gate.schema.json" "$schema_out"
fi

if [[ -f "$REPORT_DIR/report.html" && -f "$REPORT_DIR/report.json" ]]; then
    pass "report.html and report.json written to --report-dir"
else
    fail "report.html and report.json written to --report-dir" "$(ls "$REPORT_DIR" 2>&1)"
fi

html_out=$(cd "$PROJECT_DIR" && "$AGENTS_PY" -c '
import sys
from html.parser import HTMLParser
VOID = {"meta", "br", "hr", "img", "input", "link"}
class C(HTMLParser):
    def __init__(self):
        super().__init__(); self.stack = []; self.err = 0
    def handle_starttag(self, t, a):
        if t not in VOID: self.stack.append(t)
    def handle_endtag(self, t):
        if t in VOID: return
        if self.stack and self.stack[-1] == t: self.stack.pop()
        else: self.err += 1
page = open(sys.argv[1], encoding="utf-8").read()
c = C(); c.feed(page); c.close()
ok = c.err == 0 and not c.stack and "SYNTHETIC DATA" in page and "<script" not in page and page.count("<polyline") >= 4
print("OK" if ok else "BAD err=%d open=%s" % (c.err, c.stack[-3:]))
' "$REPORT_DIR/report.html" 2>&1)
if [[ "$html_out" == "OK" ]]; then
    pass "report.html: balanced tags, SYNTHETIC banner, no script, SVG curves"
else
    fail "report.html: balanced tags, SYNTHETIC banner, no script, SVG curves" "$html_out"
fi

if jq -e '.legacy_parity.ok == true and (.gates | length == 4) and .meta.synthetic == true' \
        "$REPORT_DIR/report.json" >/dev/null 2>&1; then
    pass "report.json: 4 gates, legacy parity ok, synthetic meta"
else
    fail "report.json: 4 gates, legacy parity ok, synthetic meta"
fi

if [[ -s "$AGENT_CACHE_DIR/validate/trials.jsonl" ]]; then
    pass "trial log cache/agents/validate/trials.jsonl written"
else
    fail "trial log cache/agents/validate/trials.jsonl written"
fi

# --- missing data: exit 2, no gate files ----------------------------------------
EMPTY_CACHE="$WORK_DIR/cache_missing"
out=$(AGENT_CACHE_DIR="$EMPTY_CACHE" agents validate gate --offline --symbols AAA,ZZZ --signals mr_only \
    --report-dir "$WORK_DIR/report_missing" 2>/dev/null)
rc=$?
if [[ $rc -eq 2 ]] && jq -e '.error == "market_data_unavailable" and (.unavailable | has("ZZZ"))' <<< "$out" >/dev/null 2>&1 \
        && [[ ! -d "$EMPTY_CACHE/gates" && ! -e "$WORK_DIR/report_missing" ]]; then
    pass "validate gate with a missing symbol exits 2 and writes no gate/report"
else
    fail "validate gate with a missing symbol exits 2 and writes no gate/report" "rc=$rc $out"
fi

out=$(agents validate gate --offline --signals nope 2>/dev/null)
rc=$?
if [[ $rc -eq 1 ]] && jq -e '.error == "unknown_signal"' <<< "$out" >/dev/null 2>&1; then
    pass "validate gate --signals nope exits 1 (unknown_signal)"
else
    fail "validate gate --signals nope exits 1 (unknown_signal)" "rc=$rc"
fi

# --- validate parity --offline -------------------------------------------------
out=$(agents validate parity --offline 2>/dev/null)
rc=$?
if [[ $rc -eq 0 ]] && jq -e '.ok == true and (.results | length == 6) and ([.results[] | select(.legacy_trades != .vbt_trades)] | length == 0)' \
        <<< "$out" >/dev/null 2>&1; then
    pass "validate parity --offline exits 0 (6 symbol/strategy pairs, equal trade counts)"
else
    fail "validate parity --offline exits 0 (6 symbol/strategy pairs, equal trade counts)" "rc=$rc ${out:0:300}"
fi

# --- technical run on an unknown symbol ----------------------------------------
agents technical run --offline --symbols ZZZ > "$WORK_DIR/tech.json" 2>/dev/null
rc=$?
if [[ $rc -eq 2 ]]; then
    pass "technical run --offline --symbols ZZZ exits 2"
else
    fail "technical run --offline --symbols ZZZ exits 2" "rc=$rc"
fi

# --- validate status -----------------------------------------------------------
out=$(agents validate status 2>/dev/null)
rc=$?
if [[ $rc -eq 0 ]] && jq -e '(.gates | length == 4) and ([.gates[] | select(.passed == false and .synthetic == true and .age_days != null)] | length == 4)' \
        <<< "$out" >/dev/null 2>&1; then
    pass "validate status exits 0 and lists 4 gates (passed false, age_days)"
else
    fail "validate status exits 0 and lists 4 gates (passed false, age_days)" "rc=$rc ${out:0:300}"
fi
# Compare against the real config values without ever printing them
leaks=0
while IFS= read -r v; do
    [[ ${#v} -ge 8 ]] || continue
    [[ "$out" == *"$v"* ]] && leaks=$((leaks + 1))
done < <(cd "$PROJECT_DIR" && /bin/bash -c 'source ./config.template.sh >/dev/null 2>&1
    [[ -f ./config.sh ]] && source ./config.sh >/dev/null 2>&1
    printf "%s\n" "$ALPACA_API_KEY" "$ALPACA_SECRET_KEY" "$API_KEY_FINNHUB" "$API_KEY_NEWSAPI" "$FRED_API_KEY"' 2>/dev/null)
if [[ $leaks -eq 0 ]]; then
    pass "validate status prints no key values"
else
    fail "validate status prints no key values" "$leaks value(s) found in stdout"
fi

# --- no network ------------------------------------------------------------------
if [[ ! -s "$NET_LOG" ]]; then
    pass "no network connection attempted by any offline run"
else
    fail "no network connection attempted by any offline run" "$(head -5 "$NET_LOG")"
fi

summary
