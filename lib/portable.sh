#!/bin/bash
################################################################################
# Portable helpers (macOS / Linux / WSL)
#
# One place for constructs that differ between BSD (macOS) and GNU (Linux)
# userlands or between bash 3.2 and bash 5. Time and stat go through perl, so
# the result is the same on every platform. This file is sourced:
#   - bash 3.2 safe (no mapfile, declare -A, ${v,,}, local -n)
#   - never turns on errexit, never changes the caller's SCRIPT_DIR / LIB_DIR /
#     AGENT_DIR (own dir var PORTABLE_LIB_DIR)
#   - never calls python (tests shadow python3 with functions)
# Globals: SST_PORTABLE_LOADED, SST_REPO_ROOT (and PORTABLE_LIB_DIR).
#
# Replaced constructs (do not use them elsewhere): `sed -i ''` / `sed -i`,
# `stat -f` / `stat -c`, `date +%s%N`, `date -v` / `date -d`, `timeout`,
# `sha256sum`, `mapfile`, `declare -A`.
################################################################################

if [[ -z "${SST_PORTABLE_LOADED:-}" ]]; then
SST_PORTABLE_LOADED=1

PORTABLE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SST_REPO_ROOT="$(cd "$PORTABLE_LIB_DIR/.." && pwd)"

# sst_repo_root: print the repository root (parent of lib/)
sst_repo_root() {
    printf '%s\n' "$SST_REPO_ROOT"
}

# sst_os: print macos | linux | wsl | other
sst_os() {
    case "$(uname -s 2>/dev/null)" in
        Darwin) echo "macos" ;;
        Linux)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        *) echo "other" ;;
    esac
}

# sst_use_repo_venv: put <repo>/.venv/bin first on PATH when
# <repo>/.venv/bin/python3 is executable, it is not already first and
# SST_NO_REPO_VENV is unset/empty. Idempotent. Changes PATH only.
# Returns: 0 (always)
sst_use_repo_venv() {
    [[ -n "${SST_NO_REPO_VENV:-}" ]] && return 0
    local venv_bin="$SST_REPO_ROOT/.venv/bin"
    [[ -x "$venv_bin/python3" ]] || return 0
    case "$PATH" in
        "$venv_bin"|"$venv_bin":*) return 0 ;;
    esac
    PATH="$venv_bin:$PATH"
    export PATH
    return 0
}

# sst_now_ms: epoch milliseconds (13 digits)
sst_now_ms() {
    perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'
}

# sst_file_mtime FILE: epoch seconds of the last modification
# Prints 0 and returns 1 when FILE does not exist.
sst_file_mtime() {
    perl -e 'my @s = stat shift; if (@s) { print "$s[9]\n"; exit 0 } print "0\n"; exit 1' -- "$1" 2>/dev/null
}

# sst_file_mtime_fmt FILE [FMT]: local-time modification time,
# default format "%Y-%m-%d %H:%M:%S". Prints nothing and returns 1 if missing.
sst_file_mtime_fmt() {
    perl -MPOSIX=strftime -e 'my ($f, $fmt) = @ARGV; my @s = stat $f or exit 1;
        print strftime($fmt, localtime $s[9]), "\n"' -- "$1" "${2:-%Y-%m-%d %H:%M:%S}" 2>/dev/null
}

# sst_file_size FILE: size in bytes. Prints nothing and returns 1 if missing.
sst_file_size() {
    perl -e 'my @s = stat shift or exit 1; print "$s[7]\n"' -- "$1" 2>/dev/null
}

# sst_file_mode FILE: octal permission bits like `stat -f %A` / `stat -c %a`
# (e.g. 600, 644, 4755). Prints nothing and returns 1 if missing.
sst_file_mode() {
    perl -e 'my @s = stat shift or exit 1; printf "%o\n", $s[2] & 07777' -- "$1" 2>/dev/null
}

# sst_sha256 [FILE]: lowercase hex SHA-256 of FILE or stdin (digest only)
sst_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$@" | awk '{print $1}'
    else
        openssl dgst -sha256 "$@" | awk '{print $NF}'
    fi
}

# sst_sed_inplace FILE SED_ARGS...: run `sed SED_ARGS FILE` and write the
# result back to FILE (replaces BSD `sed -i ''` / GNU `sed -i`). One pass; the
# expressions apply in the given order. The temp file sits next to FILE and
# FILE keeps its inode and mode.
# Example: sst_sed_inplace out.html -e 's/A/1/g' -e 's/B/2/g'
# Returns: sed's status (FILE untouched on failure)
sst_sed_inplace() {
    local file="$1"
    shift
    [[ -f "$file" ]] || return 1
    local tmp
    tmp=$(mktemp "$(dirname "$file")/.sst_sed.XXXXXX") || return 1
    local rc=0
    sed "$@" "$file" > "$tmp" || rc=$?
    if [[ $rc -eq 0 ]]; then
        cat "$tmp" > "$file" || rc=$?
    fi
    rm -f "$tmp"
    return $rc
}

# sst_timeout SECS CMD [ARGS...]: run CMD, kill its whole process group after
# SECS seconds (replaces coreutils `timeout`, missing on macOS).
# Returns: CMD's status, 124 on timeout, 125 fork failure, 127 exec failure
sst_timeout() {
    perl -e '
        my $t = shift;
        my $pid = fork() // exit 125;
        if ($pid == 0) { setpgrp(0, 0); exec @ARGV or exit 127; }
        $SIG{ALRM} = sub { kill "TERM", -$pid; kill "TERM", $pid; exit 124; };
        alarm $t;
        waitpid($pid, 0);
        exit($? >> 8);' -- "$@"
}

# sst_date_offset_days N [FMT]: local date N days from now (N may be
# negative; honours TZ), default format %Y-%m-%d. Replaces `date -v±Nd` /
# `date -d "N days"`. Calendar arithmetic at local noon, so DST changes never
# skip or repeat a day.
sst_date_offset_days() {
    perl -MPOSIX=strftime,mktime -e 'my ($n, $fmt) = @ARGV;
        my @t = localtime; @t[0, 1, 2] = (0, 0, 12); $t[3] += $n; $t[8] = -1;
        print strftime($fmt, localtime(mktime(@t))), "\n"' -- "$1" "${2:-%Y-%m-%d}"
}

fi
