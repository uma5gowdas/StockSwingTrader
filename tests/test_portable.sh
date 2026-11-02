#!/bin/bash
# ============================================================================
# Unit Tests: Portable helpers (lib/portable.sh)
# ============================================================================
# mtime / size / mode / formatted mtime against touch -t + chmod files,
# sha256, in-place sed (order, mode, inode), timeout, date offsets, epoch ms,
# repo venv PATH handling, sst_os, double sourcing, and that the lib keeps the
# caller's SCRIPT_DIR/LIB_DIR/AGENT_DIR and errexit off and never calls python.
# bash 3.2 + perl; no venv, no network.
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sst_portable_test.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
NET_LOG="$WORK_DIR/net.log"
: > "$NET_LOG"
export NET_LOG
# python must never be called by the helpers
python() { echo "python $*" >> "$NET_LOG"; return 1; }
python3() { echo "python3 $*" >> "$NET_LOG"; return 1; }
export -f python python3

SCRIPT_DIR="caller-script-dir"
LIB_DIR="caller-lib-dir"
AGENT_DIR="caller-agent-dir"
unset SST_PORTABLE_LOADED SST_NO_REPO_VENV
source "$PROJECT_DIR/lib/portable.sh"

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
assert_match() {
    local regex=$1 actual=$2 name=$3
    if [[ "$actual" =~ $regex ]]; then
        pass "$name"
    else
        fail "$name" "Expected to match: '$regex'  Got: '$actual'"
    fi
}

echo "=== Sourcing ==="
assert_equals "caller-script-dir" "$SCRIPT_DIR" "SCRIPT_DIR unchanged"
assert_equals "caller-lib-dir" "$LIB_DIR" "LIB_DIR unchanged"
assert_equals "caller-agent-dir" "$AGENT_DIR" "AGENT_DIR unchanged"
assert_equals "1" "$SST_PORTABLE_LOADED" "SST_PORTABLE_LOADED set"
assert_equals "$PROJECT_DIR" "$SST_REPO_ROOT" "SST_REPO_ROOT = parent of lib/"
assert_equals "$PROJECT_DIR" "$(sst_repo_root)" "sst_repo_root"
case "$-" in *e*) fail "errexit stays off after sourcing" ;; *) pass "errexit stays off after sourcing" ;; esac
source "$PROJECT_DIR/lib/portable.sh"
assert_equals "0" "$?" "sourcing twice returns 0"
assert_equals "$PROJECT_DIR" "$SST_REPO_ROOT" "SST_REPO_ROOT unchanged after second source"
assert_equals "0" "$(grep -v '^[[:space:]]*#' "$PROJECT_DIR/lib/portable.sh" | grep -cE '(^|[^A-Z_])(SCRIPT_DIR|LIB_DIR|AGENT_DIR)=|set -e|errexit')" "portable.sh code does not assign SCRIPT_DIR/LIB_DIR/AGENT_DIR or set errexit"
assert_equals "0" "$(grep -v '^[[:space:]]*#' "$PROJECT_DIR/lib/portable.sh" | grep -cE '(^|[^a-z_/.])python3?([^a-z_]|$)')" "portable.sh code has no python call"
out=$(bash -c 'source "$1"; source "$1"; declare -F sst_now_ms >/dev/null && echo ok' _ "$PROJECT_DIR/lib/portable.sh" 2>&1)
assert_equals "ok" "$out" "double source in a fresh shell defines the helpers without output"

echo "=== sst_os ==="
os=$(sst_os)
assert_match '^(macos|linux|wsl|other)$' "$os" "sst_os value ($os)"
case "$(uname -s)" in
    Darwin) assert_equals "macos" "$os" "sst_os on Darwin" ;;
    Linux) assert_match '^(linux|wsl)$' "$os" "sst_os on Linux" ;;
esac

echo "=== stat helpers ==="
f="$WORK_DIR/stat file.txt"
printf 'hello world\n' > "$f"
TZ=UTC touch -t 202001021530.45 "$f"
chmod 640 "$f"
assert_equals "1577979045" "$(sst_file_mtime "$f")" "sst_file_mtime (touch -t 2020-01-02 15:30:45 UTC)"
assert_equals "2020-01-02 15:30:45" "$(TZ=UTC sst_file_mtime_fmt "$f")" "sst_file_mtime_fmt default format"
assert_equals "2020-01-02" "$(TZ=UTC sst_file_mtime_fmt "$f" '%Y-%m-%d')" "sst_file_mtime_fmt custom format"
assert_equals "2020-01-02 10:30:45" "$(TZ=America/New_York sst_file_mtime_fmt "$f")" "sst_file_mtime_fmt honours TZ (local time)"
assert_equals "12" "$(sst_file_size "$f")" "sst_file_size"
assert_equals "640" "$(sst_file_mode "$f")" "sst_file_mode 640"
chmod 600 "$f"
assert_equals "600" "$(sst_file_mode "$f")" "sst_file_mode 600"
chmod 4755 "$f"
assert_equals "4755" "$(sst_file_mode "$f")" "sst_file_mode keeps setuid bit (4755)"
chmod 644 "$f"
d="$WORK_DIR/lockdir"
mkdir "$d"
TZ=UTC touch -t 202001021530.45 "$d"
assert_equals "1577979045" "$(sst_file_mtime "$d")" "sst_file_mtime on a directory"
missing="$WORK_DIR/missing"
out=$(sst_file_mtime "$missing"); rc=$?
assert_equals "0|1" "$out|$rc" "sst_file_mtime missing file prints 0, returns 1"
out=$(sst_file_size "$missing"); rc=$?
assert_equals "|1" "$out|$rc" "sst_file_size missing file prints nothing, returns 1"
out=$(sst_file_mode "$missing"); rc=$?
assert_equals "|1" "$out|$rc" "sst_file_mode missing file prints nothing, returns 1"
out=$(sst_file_mtime_fmt "$missing"); rc=$?
assert_equals "|1" "$out|$rc" "sst_file_mtime_fmt missing file prints nothing, returns 1"
: > "$WORK_DIR/empty"
assert_equals "0" "$(sst_file_size "$WORK_DIR/empty")" "sst_file_size empty file"

echo "=== sst_sha256 ==="
assert_equals "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "$(printf 'abc' | sst_sha256)" "sst_sha256 stdin 'abc'"
printf 'abc' > "$WORK_DIR/abc"
assert_equals "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "$(sst_sha256 "$WORK_DIR/abc")" "sst_sha256 FILE"
assert_equals "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" "$(printf '' | sst_sha256)" "sst_sha256 empty input"

echo "=== sst_sed_inplace ==="
s="$WORK_DIR/sed.html"
printf 'A B C\nA|x\nline3\n' > "$s"
chmod 640 "$s"
inode_before=$(ls -i "$s" | awk '{print $1}')
sst_sed_inplace "$s" -e 's/A/B/g' -e 's/B/C/g' -e 's|x|y/z|g'
rc=$?
assert_equals "0" "$rc" "sst_sed_inplace returns 0"
assert_equals "$(printf 'C C C\nC|y/z\nline3')" "$(cat "$s")" "expressions applied in order (A->B->C)"
assert_equals "640" "$(sst_file_mode "$s")" "file mode kept"
assert_equals "$inode_before" "$(ls -i "$s" | awk '{print $1}')" "inode kept"
assert_equals "0" "$(ls -a "$WORK_DIR" | grep -c '^\.sst_sed\.')" "no temp file left"
printf 'keep\n' > "$s"
sst_sed_inplace "$s" -e 's/unterminated' 2>/dev/null
rc=$?
if [[ $rc -ne 0 ]]; then pass "bad expression returns non-zero ($rc)"; else fail "bad expression returns non-zero"; fi
assert_equals "keep" "$(cat "$s")" "file untouched on sed failure"
assert_equals "0" "$(ls -a "$WORK_DIR" | grep -c '^\.sst_sed\.')" "no temp file left after failure"
sst_sed_inplace "$WORK_DIR/nofile" -e 's/a/b/' 2>/dev/null
assert_equals "1" "$?" "missing file returns 1"
# multi-expression single pass equals sequential passes (html_report pattern)
printf 'T1 T2 BANNER\nT2 T1\n' > "$WORK_DIR/seq1"
cp "$WORK_DIR/seq1" "$WORK_DIR/seq2"
sst_sed_inplace "$WORK_DIR/seq1" -e 's|BANNER|<b>x</b>|g' -e 's/T1/one/g' -e 's/T2/two T1/g'
for e in 's|BANNER|<b>x</b>|g' 's/T1/one/g' 's/T2/two T1/g'; do
    sed "$e" "$WORK_DIR/seq2" > "$WORK_DIR/seq2.tmp" && cat "$WORK_DIR/seq2.tmp" > "$WORK_DIR/seq2"
done
assert_equals "$(cat "$WORK_DIR/seq2")" "$(cat "$WORK_DIR/seq1")" "one pass == sequential passes"

echo "=== sst_timeout ==="
t0=$(sst_now_ms)
sst_timeout 1 sleep 5
rc=$?
t1=$(sst_now_ms)
assert_equals "124" "$rc" "sst_timeout 1 sleep 5 returns 124"
if (( t1 - t0 < 3000 )); then pass "timeout fires in < 3 s ($((t1 - t0)) ms)"; else fail "timeout fires in < 3 s" "$((t1 - t0)) ms"; fi
sst_timeout 5 true
assert_equals "0" "$?" "sst_timeout 5 true returns 0"
sst_timeout 5 bash -c 'exit 3'
assert_equals "3" "$?" "sst_timeout passes the command's exit status"
assert_equals "hi there" "$(sst_timeout 5 echo hi there)" "sst_timeout passes stdout and args"
assert_equals "piped" "$(echo piped | sst_timeout 5 cat)" "sst_timeout passes stdin"
# the whole process group is killed (child of the timed-out shell)
marker="$WORK_DIR/grandchild"
sst_timeout 1 bash -c "sleep 3; touch '$marker'" 2>/dev/null
sleep 3
if [[ ! -e "$marker" ]]; then pass "process group killed on timeout"; else fail "process group killed on timeout"; fi

echo "=== sst_date_offset_days ==="
assert_equals "$(TZ=America/New_York date +%Y-%m-%d)" "$(TZ=America/New_York sst_date_offset_days 0)" "offset 0 = today (America/New_York)"
expect_p1=$(TZ=America/New_York perl -MPOSIX=strftime -e 'my @t = localtime; print strftime("%Y-%m-%d", 0,0,12, $t[3]+1, $t[4], $t[5])')
expect_m1=$(TZ=America/New_York perl -MPOSIX=strftime -e 'my @t = localtime; print strftime("%Y-%m-%d", 0,0,12, $t[3]-1, $t[4], $t[5])')
assert_equals "$expect_p1" "$(TZ=America/New_York sst_date_offset_days 1)" "offset +1"
assert_equals "$expect_m1" "$(TZ=America/New_York sst_date_offset_days -1)" "offset -1"
d0=$(TZ=America/New_York sst_date_offset_days 0 '%s')
d7=$(TZ=America/New_York sst_date_offset_days 7 '%s')
diff_days=$(( (d7 - d0 + 43200) / 86400 ))
assert_equals "7" "$diff_days" "offset +7 is 7 calendar days"
assert_match '^[0-9]{4}/[0-9]{2}/[0-9]{2}$' "$(sst_date_offset_days -3 '%Y/%m/%d')" "custom format"
assert_match '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' "$(sst_date_offset_days -400)" "large negative offset"

echo "=== sst_now_ms ==="
a=$(sst_now_ms)
sleep 0.05 2>/dev/null || sleep 1
b=$(sst_now_ms)
assert_match '^[0-9]{13}$' "$a" "13 digits"
if (( b >= a )); then pass "monotonic ($a <= $b)"; else fail "monotonic" "$a > $b"; fi
now_s=$(date +%s)
if (( a / 1000 >= now_s - 5 && a / 1000 <= now_s + 5 )); then pass "matches date +%s"; else fail "matches date +%s" "$a vs $now_s"; fi

echo "=== sst_use_repo_venv ==="
fake="$WORK_DIR/fakerepo"
mkdir -p "$fake/lib" "$fake/.venv/bin"
fake=$(cd "$fake" && pwd)
cp "$PROJECT_DIR/lib/portable.sh" "$fake/lib/"
printf '#!/bin/sh\necho fake\n' > "$fake/.venv/bin/python3"
chmod 755 "$fake/.venv/bin/python3"
out=$(env -u SST_PORTABLE_LOADED -u SST_NO_REPO_VENV PATH="/usr/bin:/bin" /bin/bash -c 'source "$1"; sst_use_repo_venv; sst_use_repo_venv; echo "$PATH"' _ "$fake/lib/portable.sh")
assert_equals "$fake/.venv/bin:/usr/bin:/bin" "$out" "PATH prepended once (idempotent)"
out=$(env -u SST_PORTABLE_LOADED SST_NO_REPO_VENV=1 PATH="/usr/bin:/bin" /bin/bash -c 'source "$1"; sst_use_repo_venv; echo "$PATH"' _ "$fake/lib/portable.sh")
assert_equals "/usr/bin:/bin" "$out" "skipped with SST_NO_REPO_VENV=1"
out=$(env -u SST_PORTABLE_LOADED -u SST_NO_REPO_VENV PATH="/usr/bin:/bin:$fake/.venv/bin" /bin/bash -c 'source "$1"; sst_use_repo_venv; echo "$PATH"' _ "$fake/lib/portable.sh")
assert_equals "$fake/.venv/bin:/usr/bin:/bin:$fake/.venv/bin" "$out" "prepended when present but not first"
out=$(env -u SST_PORTABLE_LOADED -u SST_NO_REPO_VENV PATH="/usr/bin:/bin" /bin/bash -c 'source "$1"; sst_use_repo_venv; type -P python3' _ "$fake/lib/portable.sh")
assert_equals "$fake/.venv/bin/python3" "$out" "python3 resolves to the repo venv"
chmod 644 "$fake/.venv/bin/python3"
out=$(env -u SST_PORTABLE_LOADED -u SST_NO_REPO_VENV PATH="/usr/bin:/bin" /bin/bash -c 'source "$1"; sst_use_repo_venv; echo "$PATH"' _ "$fake/lib/portable.sh")
assert_equals "/usr/bin:/bin" "$out" "skipped when .venv/bin/python3 is not executable"
rm -rf "$fake/.venv"
out=$(env -u SST_PORTABLE_LOADED -u SST_NO_REPO_VENV PATH="/usr/bin:/bin" /bin/bash -c 'source "$1"; sst_use_repo_venv; echo "rc=$? $PATH"' _ "$fake/lib/portable.sh")
assert_equals "rc=0 /usr/bin:/bin" "$out" "no .venv: PATH unchanged, returns 0"

echo "=== bash 3.2 / no python ==="
out=$(/bin/bash -n "$PROJECT_DIR/lib/portable.sh" 2>&1)
assert_equals "" "$out" "/bin/bash -n lib/portable.sh"
assert_equals "0" "$(grep -v '^[[:space:]]*#' "$PROJECT_DIR/lib/portable.sh" | grep -cE 'ma[p]file|declare -[A]|local -n|\$\{[a-zA-Z_]+,,\}')" "no bash-4-only constructs"
assert_equals "0" "$(wc -l < "$NET_LOG" | tr -d ' ')" "no python call during the suite"

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
