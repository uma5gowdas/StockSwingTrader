#!/bin/bash
# ============================================================================
# Unit Tests: setup.sh
# ============================================================================
# Runs setup.sh in a temp skeleton copy (setup.sh, config.template.sh,
# StockSwingTrader_Agent.sh, lib/portable.sh, stub requirements files) with
# every network step skipped or in --dry-run, so no network is used:
# --help, unknown flag, --dry-run changes nothing, config.sh creation (mode
# 600, idempotent), an existing config.sh is never touched, --configure-keys
# writes values without printing them, the paper URL warning, --doctor on the
# real repo (exit 0, no key values printed) and with jq missing from PATH
# (exit 1 + brew/apt hints). bash 3.2; no python, no network.
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sst_setup_test.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
unset SST_CONFIG_FILE SST_SETUP_DRY_RUN
RUN_BASH="${BASH:-bash}"
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
        fail "$name" "expected '$expected', got '$actual'"
    fi
}
assert_contains() {
    local haystack=$1 needle=$2 name=$3
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$name"
    else
        fail "$name" "missing '$needle'"
    fi
}
# make_skeleton DIR: minimal repo copy for setup.sh
make_skeleton() {
    local d="$1"
    mkdir -p "$d/lib"
    cp "$PROJECT_DIR/setup.sh" "$PROJECT_DIR/config.template.sh" "$PROJECT_DIR/StockSwingTrader_Agent.sh" "$d/"
    cp "$PROJECT_DIR/lib/portable.sh" "$d/lib/"
    printf '# stub core requirements (test)\n' > "$d/requirements.txt"
    printf '# stub agent requirements (test)\n' > "$d/requirements-agents.txt"
    chmod 755 "$d/setup.sh"
}
# listing DIR: every path with mode and checksum (files)
listing() {
    (cd "$1" && find . -print | LC_ALL=C sort | while IFS= read -r p; do
        if [[ -f "$p" ]]; then
            echo "$p $(sst_file_mode "$p") $(cksum < "$p")"
        else
            echo "$p $(sst_file_mode "$p")"
        fi
    done)
}
run_setup() { # run_setup DIR ARGS... (stdin /dev/null); sets OUT, RC
    local d="$1"
    shift
    OUT="$("$RUN_BASH" "$d/setup.sh" "$@" </dev/null 2>&1)"
    RC=$?
}
CONFIG_ONLY_FLAGS="--non-interactive --skip-python --skip-agents --skip-node --skip-model --skip-smoke"
# ============================================================================
echo "=== Syntax, --help, unknown flag ==="
if "$RUN_BASH" -n "$PROJECT_DIR/setup.sh"; then pass "bash -n setup.sh"; else fail "bash -n setup.sh"; fi
assert_equals "755" "$(sst_file_mode "$PROJECT_DIR/setup.sh")" "setup.sh is mode 755"
SK="$WORK_DIR/sk_help"
make_skeleton "$SK"
run_setup "$SK" --help
assert_equals "0" "$RC" "--help exits 0"
assert_contains "$OUT" "Usage: ./setup.sh" "--help prints usage"
assert_contains "$OUT" "--doctor" "--help lists --doctor"
run_setup "$SK" --no-such-flag
assert_equals "2" "$RC" "unknown flag exits 2"
assert_contains "$OUT" "Unknown option: --no-such-flag" "unknown flag is named"
run_setup "$SK" --with-agents --skip-agents
assert_equals "2" "$RC" "--with-agents + --skip-agents exits 2"
# ============================================================================
echo "=== --dry-run changes nothing ==="
SK="$WORK_DIR/sk_dry"
make_skeleton "$SK"
BEFORE="$(listing "$SK")"
run_setup "$SK" --dry-run --non-interactive
assert_equals "0" "$RC" "--dry-run --non-interactive exits 0"
AFTER="$(listing "$SK")"
if [[ "$BEFORE" == "$AFTER" ]]; then pass "--dry-run: listing + checksums identical"; else fail "--dry-run changed the skeleton" "$(diff <(echo "$BEFORE") <(echo "$AFTER"))"; fi
[[ ! -e "$SK/config.sh" ]] && pass "--dry-run: no config.sh created" || fail "--dry-run created config.sh"
[[ ! -e "$SK/.venv" ]] && pass "--dry-run: no .venv created" || fail "--dry-run created .venv"
for s in "prerequisites: done" "venv: dry-run" "pip: dry-run" "agents-venv: skipped" "npm-backend: skipped" \
    "npm-frontend: skipped" "config: dry-run" "keys: skipped" "model: dry-run" "smoke: dry-run"; do
    assert_contains "$OUT" "[setup] $s" "--dry-run lists '$s'"
done
BEFORE="$(listing "$SK")"
OUT="$(SST_SETUP_DRY_RUN=1 "$RUN_BASH" "$SK/setup.sh" --non-interactive </dev/null 2>&1)"
RC=$?
assert_equals "0" "$RC" "SST_SETUP_DRY_RUN=1 exits 0"
assert_contains "$OUT" "config: dry-run" "SST_SETUP_DRY_RUN=1 acts as --dry-run"
assert_equals "$BEFORE" "$(listing "$SK")" "SST_SETUP_DRY_RUN=1 changes nothing"
# ============================================================================
echo "=== config.sh creation (mode 600, idempotent) ==="
SK="$WORK_DIR/sk_cfg"
make_skeleton "$SK"
run_setup "$SK" $CONFIG_ONLY_FLAGS
assert_equals "0" "$RC" "config-only run exits 0"
[[ -f "$SK/config.sh" ]] && pass "config.sh created" || fail "config.sh not created" "$OUT"
assert_equals "600" "$(sst_file_mode "$SK/config.sh")" "config.sh mode 600"
if cmp -s "$SK/config.template.sh" "$SK/config.sh"; then pass "config.sh = config.template.sh"; else fail "config.sh differs from the template"; fi
assert_contains "$OUT" "[setup] config: done" "config step reports done"
for s in "venv: skipped" "pip: skipped" "agents-venv: skipped" "npm-backend: skipped" "model: skipped" "smoke: skipped"; do
    assert_contains "$OUT" "[setup] $s" "skip flags: '$s'"
done
[[ ! -e "$SK/.venv" ]] && pass "--skip-python: no .venv" || fail "--skip-python created .venv"
cp "$SK/config.sh" "$WORK_DIR/config.first"
M1="$(sst_file_mtime "$SK/config.sh")"
run_setup "$SK" $CONFIG_ONLY_FLAGS
assert_equals "0" "$RC" "second run exits 0"
if cmp -s "$WORK_DIR/config.first" "$SK/config.sh"; then pass "second run: config.sh byte-identical"; else fail "second run changed config.sh"; fi
assert_equals "$M1" "$(sst_file_mtime "$SK/config.sh")" "second run: config.sh mtime unchanged"
assert_contains "$OUT" "[setup] config: exists" "second run reports exists"
leftover="$(cd "$SK" && ls -a | grep -c '^\.config\.sh\.')"
assert_equals "0" "$leftover" "no temp config files left"
# ============================================================================
echo "=== Existing config.sh is never touched ==="
SK="$WORK_DIR/sk_existing"
make_skeleton "$SK"
printf 'export ALPACA_API_KEY="keep-me"\nexport CUSTOM_SETTING=1\n' > "$SK/config.sh"
chmod 640 "$SK/config.sh"
cp "$SK/config.sh" "$WORK_DIR/config.existing"
run_setup "$SK" $CONFIG_ONLY_FLAGS
assert_equals "0" "$RC" "run with existing config.sh exits 0"
if cmp -s "$WORK_DIR/config.existing" "$SK/config.sh"; then pass "existing config.sh byte-identical"; else fail "existing config.sh was modified"; fi
assert_equals "640" "$(sst_file_mode "$SK/config.sh")" "existing config.sh mode unchanged"
assert_contains "$OUT" "[setup] config: exists" "existing config.sh reported as exists"
# Paper URL warning, file unchanged
printf 'export ALPACA_BASE_URL="https://api.alpaca.markets"\n' >> "$SK/config.sh"
cp "$SK/config.sh" "$WORK_DIR/config.live"
run_setup "$SK" $CONFIG_ONLY_FLAGS
assert_contains "$OUT" "WARNING: ALPACA_BASE_URL in config.sh points to 'api.alpaca.markets'" "non-paper URL warns"
if cmp -s "$WORK_DIR/config.live" "$SK/config.sh"; then pass "non-paper URL is not changed silently"; else fail "setup changed ALPACA_BASE_URL"; fi
# ============================================================================
echo "=== --configure-keys (values never printed) ==="
SK="$WORK_DIR/sk_keys"
make_skeleton "$SK"
run_setup "$SK" $CONFIG_ONLY_FLAGS
V_API="PKSSTTESTKEY0001"
V_SECRET="sst'secret\$HOME value 0002"
V_FINN="finnhubSSTtest0003"
V_FRED="fredSSTtest0005"
V_SEC="SST Tester sst-test0006@example.com"
OUT="$(printf '%s\n' "$V_API" "$V_SECRET" "$V_FINN" "" "$V_FRED" "$V_SEC" | \
    "$RUN_BASH" "$SK/setup.sh" $CONFIG_ONLY_FLAGS --configure-keys 2>&1)"
RC=$?
assert_equals "0" "$RC" "--configure-keys exits 0"
leaks=0
for v in "$V_API" "$V_SECRET" "$V_FINN" "$V_FRED" "$V_SEC" "PKSSTTESTKEY" "0002" "0003" "0005" "0006"; do
    [[ "$OUT" == *"$v"* ]] && leaks=$((leaks + 1))
done
assert_equals "0" "$leaks" "stdout/stderr contain no key value"
for k in ALPACA_API_KEY ALPACA_SECRET_KEY API_KEY_FINNHUB FRED_API_KEY SEC_USER_AGENT; do
    assert_contains "$OUT" "$k: set" "prints '$k: set'"
done
assert_contains "$OUT" "API_KEY_NEWSAPI: unchanged" "empty input keeps API_KEY_NEWSAPI"
assert_equals "600" "$(sst_file_mode "$SK/config.sh")" "config.sh mode 600 after keys"
read_cfg() { # read_cfg DIR KEY -> effective value after template + config.sh
    (cd "$1" && unset "$2" && source ./config.template.sh >/dev/null 2>&1 && source ./config.sh >/dev/null 2>&1 && printf '%s' "${!2}")
}
assert_equals "$V_API" "$(read_cfg "$SK" ALPACA_API_KEY)" "ALPACA_API_KEY written"
assert_equals "$V_SECRET" "$(read_cfg "$SK" ALPACA_SECRET_KEY)" "ALPACA_SECRET_KEY written (quote, \$ and space preserved)"
assert_equals "$V_FINN" "$(read_cfg "$SK" API_KEY_FINNHUB)" "API_KEY_FINNHUB written"
assert_equals "demo" "$(read_cfg "$SK" API_KEY_NEWSAPI)" "API_KEY_NEWSAPI unchanged (template default)"
assert_equals "$V_FRED" "$(read_cfg "$SK" FRED_API_KEY)" "FRED_API_KEY appended"
assert_equals "$V_SEC" "$(read_cfg "$SK" SEC_USER_AGENT)" "SEC_USER_AGENT appended"
assert_equals "https://paper-api.alpaca.markets" "$(read_cfg "$SK" ALPACA_BASE_URL)" "ALPACA_BASE_URL stays paper"
assert_equals "1" "$(grep -c '^export ALPACA_API_KEY=' "$SK/config.sh")" "one ALPACA_API_KEY line (replaced in place)"
assert_equals "1" "$(grep -c '^export FRED_API_KEY=' "$SK/config.sh")" "one FRED_API_KEY line"
assert_equals "$(grep -c '' "$SK/config.template.sh")" "$(( $(grep -c '' "$SK/config.sh") - 2 ))" "only the 2 missing keys appended"
cp "$SK/config.sh" "$WORK_DIR/config.keys"
OUT="$(printf '\n\n\n\n\n\n' | "$RUN_BASH" "$SK/setup.sh" $CONFIG_ONLY_FLAGS --configure-keys 2>&1)"
assert_equals "0" "$?" "--configure-keys with all-empty input exits 0"
if cmp -s "$WORK_DIR/config.keys" "$SK/config.sh"; then pass "all-empty input: config.sh byte-identical"; else fail "all-empty input changed config.sh"; fi
assert_equals "6" "$(echo "$OUT" | grep -c ': unchanged$')" "all six keys unchanged"
OUT="$(printf 'PKSSTREPLACED0007\n' | "$RUN_BASH" "$SK/setup.sh" $CONFIG_ONLY_FLAGS --configure-keys 2>&1)"
assert_equals "PKSSTREPLACED0007" "$(read_cfg "$SK" ALPACA_API_KEY)" "re-run replaces ALPACA_API_KEY"
assert_equals "$V_SECRET" "$(read_cfg "$SK" ALPACA_SECRET_KEY)" "re-run keeps the other keys (EOF = unchanged)"
[[ "$OUT" != *"PKSSTREPLACED0007"* ]] && pass "replacement value not printed" || fail "replacement value printed"
leftover="$(cd "$SK" && ls -a | grep -c '^\.config\.sh\.')"
assert_equals "0" "$leftover" "no temp config files left after key writes"
# Doctor in the configured skeleton: states only, read-only
BEFORE="$(listing "$SK")"
run_setup "$SK" --doctor
assert_contains "$OUT" "ALPACA_API_KEY: set" "--doctor shows ALPACA_API_KEY: set"
assert_contains "$OUT" "API_KEY_NEWSAPI: placeholder" "--doctor shows the demo placeholder"
assert_contains "$OUT" "config.sh      present (mode 600)" "--doctor shows config.sh mode"
assert_contains "$OUT" "ALPACA_BASE_URL host: paper-api.alpaca.markets (paper)" "--doctor shows the paper host"
leaks=0
for v in "PKSSTREPLACED0007" "$V_SECRET" "$V_FINN" "$V_FRED" "$V_SEC"; do
    [[ "$OUT" == *"$v"* ]] && leaks=$((leaks + 1))
done
assert_equals "0" "$leaks" "--doctor prints no key value"
assert_equals "$BEFORE" "$(listing "$SK")" "--doctor changes nothing"
# ============================================================================
echo "=== --doctor on the real repo ==="
run_setup "$PROJECT_DIR" --doctor
assert_equals "0" "$RC" "--doctor on the real repo exits 0"
assert_contains "$OUT" "Doctor: all required tools present." "--doctor summary"
if [[ -f "$PROJECT_DIR/config.sh" ]]; then
    leaks=0
    for k in ALPACA_API_KEY ALPACA_SECRET_KEY API_KEY_FINNHUB API_KEY_NEWSAPI FRED_API_KEY SEC_USER_AGENT; do
        v="$(read_cfg "$PROJECT_DIR" "$k")"
        [[ ${#v} -ge 6 && "$OUT" == *"$v"* ]] && leaks=$((leaks + 1))
    done
    unset v
    assert_equals "0" "$leaks" "--doctor on the real repo prints no key value"
else
    pass "real repo has no config.sh (no key values to leak)"
fi
# ============================================================================
echo "=== --doctor with jq missing from PATH ==="
NOJQ_BIN="$WORK_DIR/nojq-bin"
mkdir -p "$NOJQ_BIN"
for t in bash sh env git bc curl perl python3 python3.12 python3.13 node npm openssl uname awk sed grep \
    cat dirname basename head tail tr cut sort ls rm cp mv chmod mktemp cmp find wc date id readlink; do
    p="$(command -v "$t" 2>/dev/null)"
    [[ -n "$p" && "$p" == /* ]] && ln -s "$p" "$NOJQ_BIN/$t"
done
if PATH="$NOJQ_BIN" command -v jq >/dev/null 2>&1; then
    fail "test setup: jq still on the restricted PATH"
else
    pass "restricted PATH has no jq"
fi
OUT="$(PATH="$NOJQ_BIN" "$RUN_BASH" "$WORK_DIR/sk_cfg/setup.sh" --doctor </dev/null 2>&1)"
RC=$?
assert_equals "1" "$RC" "--doctor without jq exits 1"
assert_contains "$OUT" "MISSING  jq" "--doctor names jq as missing"
assert_contains "$OUT" "brew install jq" "--doctor prints 'brew install jq'"
assert_contains "$OUT" "apt-get install -y jq" "--doctor prints 'apt-get install -y jq'"
OUT="$(PATH="$NOJQ_BIN" "$RUN_BASH" "$WORK_DIR/sk_cfg/setup.sh" $CONFIG_ONLY_FLAGS </dev/null 2>&1)"
RC=$?
assert_equals "1" "$RC" "setup without jq exits 1 before any step"
assert_contains "$OUT" "prerequisites: failed" "setup without jq reports prerequisites: failed"
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
