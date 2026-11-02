#!/bin/bash
################################################################################
# StockSwingTrader v6.3 - one-command setup (macOS, Linux, WSL)
#
# Idempotent and non-destructive: an existing .venv, .venv-agents, config.sh,
# node_modules or ML model is never overwritten. Every step prints
#   [setup] <step>: done | exists | skipped | dry-run | failed
#
# Order: flags -> OS -> prerequisites -> .venv (+ requirements.txt) ->
# optional .venv-agents (python3.12, requirements-agents.txt, pip check) ->
# npm ci in backend/ and frontend/ -> config.sh from config.template.sh
# (mode 600) -> optional API key prompts -> ML model -> smoke -> --full-tests.
#
# Secrets: key values are read with `read -rs`, passed to perl through the
# environment (never argv), written to a temp file in the repo dir and moved
# over config.sh (mode 600). Only "KEY: set" / "KEY: unchanged" is printed.
# ALPACA_BASE_URL is never changed; setup warns when it is not the paper host.
#
# bash 3.2 compatible. Network is used only by pip and npm (--skip-python,
# --skip-agents, --skip-node turn them off; --dry-run prints them only).
################################################################################
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/portable.sh
source "$ROOT/lib/portable.sh"

PY_MIN="3.12"        # xgboost 3.4.1 (requirements.txt) needs Python >= 3.12
AGENTS_PY_VERSION="3.12"
NODE_MIN="18"
JQ_MIN="1.6"
JQ_WARN="1.7"
BASH_MIN="3.2"
PAPER_HOST="paper-api.alpaca.markets"
KEY_NAMES="ALPACA_API_KEY ALPACA_SECRET_KEY API_KEY_FINNHUB API_KEY_NEWSAPI FRED_API_KEY SEC_USER_AGENT"
CONFIG_FILE="$ROOT/config.sh"
TEMPLATE_FILE="$ROOT/config.template.sh"
MODEL_FILE="$ROOT/lib/models/xgboost_predictor.pkl"
VENV_DIR="$ROOT/.venv"
AGENTS_VENV_DIR="$ROOT/.venv-agents"
STAMP_NAME=".sst-requirements.sha256"

NON_INTERACTIVE=false
WITH_AGENTS=false
SKIP_PYTHON=false
SKIP_AGENTS=false
SKIP_NODE=false
SKIP_MODEL=false
SKIP_CONFIG=false
SKIP_SMOKE=false
CONFIGURE_KEYS=false
FULL_TESTS=false
DOCTOR=false
DRY_RUN=false
[[ "${SST_SETUP_DRY_RUN:-}" == "1" ]] && DRY_RUN=true

FAILED_STEPS=0
PREREQ_MISSING=0
PY_CMD=""

usage() {
    cat <<'EOF'
Usage: ./setup.sh [OPTIONS]

Sets up StockSwingTrader on this machine (macOS, Linux, WSL). Safe to re-run:
existing .venv, .venv-agents, config.sh, node_modules and the ML model are kept.

Options:
  --non-interactive  Never prompt (no key prompts; .venv-agents only with --with-agents)
  --with-agents      Also create .venv-agents (python3.12, requirements-agents.txt, ~1.2 GB)
  --skip-python      Do not create .venv or pip install requirements.txt
  --skip-agents      Do not create .venv-agents
  --skip-node        Do not run npm ci in backend/ and frontend/ (node/npm not required)
  --skip-model       Do not train lib/models/xgboost_predictor.pkl when it is missing
  --skip-config      Do not create config.sh and do not prompt for keys
  --skip-smoke       Do not run the smoke checks
  --configure-keys   Prompt for API keys (reads stdin; Enter keeps the current value)
  --full-tests       Run bash tests/test_runner.sh at the end (~40-50 min with agents)
  --doctor           Read-only report: tools, venvs, model, node_modules, config (no network)
  --dry-run          Print the planned actions, change nothing (also SST_SETUP_DRY_RUN=1)
  -h, --help         Show this help

Keys asked by --configure-keys: ALPACA_API_KEY ALPACA_SECRET_KEY API_KEY_FINNHUB
API_KEY_NEWSAPI FRED_API_KEY SEC_USER_AGENT. ALPACA_BASE_URL stays
https://paper-api.alpaca.markets (paper trading only).

Exit codes: 0 ok, 1 a required tool is missing or a step failed, 2 bad option.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=true ;;
        --with-agents) WITH_AGENTS=true ;;
        --skip-python) SKIP_PYTHON=true ;;
        --skip-agents) SKIP_AGENTS=true ;;
        --skip-node) SKIP_NODE=true ;;
        --skip-model) SKIP_MODEL=true ;;
        --skip-config) SKIP_CONFIG=true ;;
        --skip-smoke) SKIP_SMOKE=true ;;
        --configure-keys) CONFIGURE_KEYS=true ;;
        --full-tests) FULL_TESTS=true ;;
        --doctor) DOCTOR=true ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [[ "$WITH_AGENTS" == true && "$SKIP_AGENTS" == true ]]; then
    echo "Conflicting options: --with-agents and --skip-agents" >&2
    exit 2
fi
if [[ "$CONFIGURE_KEYS" == true && "$SKIP_CONFIG" == true ]]; then
    echo "Conflicting options: --configure-keys and --skip-config" >&2
    exit 2
fi

INTERACTIVE=false
[[ "$NON_INTERACTIVE" != true && -t 0 ]] && INTERACTIVE=true

log() { echo "[setup] $*"; }
step_failed() {
    FAILED_STEPS=$((FAILED_STEPS + 1))
    log "$1: failed${2:+ ($2)}"
}

# ask "QUESTION" -> 0 for y/yes (interactive only; default No)
ask() {
    [[ "$INTERACTIVE" == true ]] || return 1
    local answer=""
    printf '%s [y/N] ' "$1" >&2
    IFS= read -r answer || return 1
    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
    esac
    return 1
}

# ver_ge HAVE MIN: dotted numeric compare (suffixes like 1.7.1-apple ignored)
ver_ge() {
    local IFS=.
    local -a have=($1) min=($2)
    local i x y
    for i in 0 1 2; do
        x="${have[$i]:-0}"; x="${x%%[!0-9]*}"; x="${x:-0}"
        y="${min[$i]:-0}"; y="${y%%[!0-9]*}"; y="${y:-0}"
        if (( 10#$x > 10#$y )); then return 0; fi
        if (( 10#$x < 10#$y )); then return 1; fi
    done
    return 0
}

tool_version() {
    case "$1" in
        bash) bash -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]}"' 2>/dev/null ;;
        git) git --version 2>/dev/null | awk '{print $3}' ;;
        python*) "$1" -V 2>&1 | awk '{print $2}' ;;
        jq) jq --version 2>/dev/null | sed 's/^jq-//' ;;
        node) node --version 2>/dev/null | sed 's/^v//' ;;
        npm) npm --version 2>/dev/null ;;
        curl) curl --version 2>/dev/null | awk 'NR == 1 {print $2}' ;;
        perl) perl -e 'printf "%vd\n", $^V' 2>/dev/null ;;
        openssl) openssl version 2>/dev/null | awk '{print $2}' ;;
        bc) bc --version </dev/null 2>/dev/null | awk 'NR == 1 {print $2}' ;;
        *) echo "" ;;
    esac
}

pkg_hint() {
    echo "      macOS: brew install $1"
    echo "      Ubuntu/Debian: sudo apt-get install -y $2"
}

# check_tool KIND NAME MIN BREW_PKG APT_PKGS [NOTE]
#   KIND required|optional. Prints a line in doctor mode; prints problems with
#   install hints in every mode. Missing/too old required tools count in
#   PREREQ_MISSING.
check_tool() {
    local kind="$1" name="$2" min="$3" brew_pkg="$4" apt_pkgs="$5" note="${6:-}"
    local version
    if ! command -v "$name" >/dev/null 2>&1; then
        if [[ "$kind" == required ]]; then
            PREREQ_MISSING=$((PREREQ_MISSING + 1))
            echo "  MISSING  $name (required${min:+, >= $min})"
            pkg_hint "$brew_pkg" "$apt_pkgs"
        elif [[ "$DOCTOR" == true ]]; then
            echo "  absent   $name (optional${note:+: $note})"
            pkg_hint "$brew_pkg" "$apt_pkgs"
        fi
        return 1
    fi
    version="$(tool_version "$name")"
    if [[ -n "$min" && -n "$version" ]] && ! ver_ge "$version" "$min"; then
        if [[ "$kind" == required ]]; then
            PREREQ_MISSING=$((PREREQ_MISSING + 1))
            echo "  TOO OLD  $name $version (required >= $min)"
            pkg_hint "$brew_pkg" "$apt_pkgs"
        elif [[ "$DOCTOR" == true ]]; then
            echo "  too old  $name $version (optional, >= $min${note:+: $note})"
            pkg_hint "$brew_pkg" "$apt_pkgs"
        fi
        return 1
    fi
    [[ "$DOCTOR" == true ]] && echo "  ok       $name ${version:-present}${min:+ (min $min)}"
    return 0
}

# find_python: first of python3, python3.13, python3.12 with version >= PY_MIN
find_python() {
    local c v
    for c in python3 python3.14 python3.13 python3.12; do
        command -v "$c" >/dev/null 2>&1 || continue
        v="$(tool_version "$c")"
        if [[ -n "$v" ]] && ver_ge "$v" "$PY_MIN"; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

python_has_venv() {
    "$1" -m venv --help >/dev/null 2>&1 && "$1" -c 'import ensurepip' >/dev/null 2>&1
}

# agents_python: python3.12 (requirements-agents.txt is resolved on 3.12)
agents_python() {
    local v
    if command -v "python$AGENTS_PY_VERSION" >/dev/null 2>&1; then
        echo "python$AGENTS_PY_VERSION"
        return 0
    fi
    if [[ -n "$PY_CMD" ]]; then
        v="$(tool_version "$PY_CMD")"
        case "$v" in "$AGENTS_PY_VERSION".*) echo "$PY_CMD"; return 0 ;; esac
    fi
    return 1
}

# check_prereqs NEED_PYTHON NEED_NODE
check_prereqs() {
    local need_python="$1" need_node="$2" v
    [[ "$DOCTOR" == true ]] && echo "Tools:"
    check_tool required bash "$BASH_MIN" bash bash
    check_tool required git "" git git
    check_tool required jq "$JQ_MIN" jq jq && {
        v="$(tool_version jq)"
        if [[ -n "$v" ]] && ! ver_ge "$v" "$JQ_WARN"; then
            echo "  WARN     jq $v < $JQ_WARN (output may differ; 1.7+ recommended)"
            pkg_hint jq jq
        fi
    }
    check_tool required bc "" bc bc
    check_tool required curl "" curl curl
    check_tool required perl "" perl perl
    if [[ "$need_python" == true ]]; then
        PY_CMD="$(find_python)"
        if [[ -z "$PY_CMD" ]]; then
            PREREQ_MISSING=$((PREREQ_MISSING + 1))
            if command -v python3 >/dev/null 2>&1; then
                echo "  TOO OLD  python3 $(tool_version python3) (required >= $PY_MIN)"
            else
                echo "  MISSING  python3 (required, >= $PY_MIN)"
            fi
            pkg_hint "python@$AGENTS_PY_VERSION" "python3 python3-venv python3-pip"
        elif ! python_has_venv "$PY_CMD"; then
            PREREQ_MISSING=$((PREREQ_MISSING + 1))
            echo "  MISSING  venv/ensurepip module for $PY_CMD $(tool_version "$PY_CMD")"
            pkg_hint "python@$AGENTS_PY_VERSION" "python3-venv"
        elif [[ "$DOCTOR" == true ]]; then
            echo "  ok       $PY_CMD $(tool_version "$PY_CMD") (min $PY_MIN, venv ok)"
        fi
    fi
    if [[ "$need_node" == true ]]; then
        check_tool required node "$NODE_MIN" node "nodejs npm"
        check_tool required npm "" node "nodejs npm"
    fi
    if [[ "$DOCTOR" == true ]]; then
        check_tool optional "python$AGENTS_PY_VERSION" "" "python@$AGENTS_PY_VERSION" \
            "python$AGENTS_PY_VERSION python$AGENTS_PY_VERSION-venv" "agent layer (.venv-agents)"
        check_tool optional openssl "" openssl openssl "Robinhood only"
    fi
    case "$(sst_os)" in
        linux|wsl)
            if [[ ! -e /usr/share/zoneinfo/America/New_York ]]; then
                echo "  WARN     tzdata missing (/usr/share/zoneinfo/America/New_York)"
                pkg_hint tzdata tzdata
            fi
            ;;
    esac
}

# config_states: one line per key "KEY empty|placeholder|set" and
# "__HOST__ <host>" for ALPACA_BASE_URL, from template + config.sh sourced in
# a child bash (values never leave it).
config_states() {
    "$BASH" -c '
        cd "$1" || exit 1
        [ -f ./config.template.sh ] && source ./config.template.sh >/dev/null 2>&1
        [ -f "$2" ] && source "$2" >/dev/null 2>&1
        shift 2
        for k in "$@"; do
            v="${!k}"
            case "$v" in
                "") s=empty ;;
                demo|your_*|YOUR_*|changeme|CHANGEME) s=placeholder ;;
                *) s=set ;;
            esac
            echo "$k $s"
        done
        u="${ALPACA_BASE_URL:-}"; h="${u#*://}"; h="${h%%/*}"; h="${h%%:*}"
        echo "__HOST__ $h"
    ' _ "$ROOT" "$CONFIG_FILE" $KEY_NAMES </dev/null 2>/dev/null
}

check_paper_url() {
    local host
    host="$(config_states | awk '$1 == "__HOST__" {print $2}')"
    if [[ -z "$host" || "$host" == "$PAPER_HOST" ]]; then
        return 0
    fi
    echo "[setup] WARNING: ALPACA_BASE_URL in config.sh points to '$host', not $PAPER_HOST."
    echo "[setup] WARNING: setup does not change it. Use paper trading: ALPACA_BASE_URL=\"https://$PAPER_HOST\""
    return 1
}

################################################################################
# --doctor
################################################################################
run_doctor() {
    local states line
    echo "StockSwingTrader setup doctor (read-only)"
    echo "Repo:     $ROOT"
    echo "OS:       $(sst_os) ($(uname -sm 2>/dev/null))"
    echo "Shell:    bash $BASH_VERSION (running)"
    check_prereqs true true
    echo "Python environments:"
    if [[ -x "$VENV_DIR/bin/python" ]]; then
        echo "  .venv          present (Python $("$VENV_DIR/bin/python" -V 2>&1 | awk '{print $2}'))"
    else
        echo "  .venv          absent (run ./setup.sh)"
    fi
    if [[ -x "$AGENTS_VENV_DIR/bin/python" ]]; then
        echo "  .venv-agents   present (Python $("$AGENTS_VENV_DIR/bin/python" -V 2>&1 | awk '{print $2}'))"
    else
        echo "  .venv-agents   absent (optional: ./setup.sh --with-agents)"
    fi
    echo "ML model:"
    if [[ -f "$MODEL_FILE" ]]; then
        echo "  lib/models/xgboost_predictor.pkl present ($(sst_file_size "$MODEL_FILE") bytes)"
    else
        echo "  lib/models/xgboost_predictor.pkl absent (./setup.sh trains it)"
    fi
    echo "Node modules:"
    local d
    for d in backend frontend; do
        if [[ -d "$ROOT/$d/node_modules" ]]; then
            echo "  $d/node_modules present"
        elif [[ -f "$ROOT/$d/package.json" ]]; then
            echo "  $d/node_modules absent (./setup.sh runs npm ci)"
        fi
    done
    echo "Config:"
    if [[ -f "$CONFIG_FILE" ]]; then
        local mode
        mode="$(sst_file_mode "$CONFIG_FILE")"
        if [[ "$mode" == "600" ]]; then
            echo "  config.sh      present (mode $mode)"
        else
            echo "  config.sh      present (mode $mode; recommended: chmod 600 config.sh)"
        fi
    else
        echo "  config.sh      absent (./setup.sh creates it from config.template.sh)"
    fi
    [[ -n "${SST_CONFIG_FILE:-}" ]] && echo "  SST_CONFIG_FILE is set (the agent reads that file instead of config.sh)"
    states="$(config_states)"
    while IFS= read -r line; do
        case "$line" in
            __HOST__*)
                local host="${line#__HOST__ }"
                if [[ -z "$host" || "$host" == "$PAPER_HOST" ]]; then
                    echo "  ALPACA_BASE_URL host: ${host:-$PAPER_HOST (default)} (paper)"
                else
                    echo "  ALPACA_BASE_URL host: $host (NOT paper - keep $PAPER_HOST)"
                fi
                ;;
            "") ;;
            *) echo "  ${line%% *}: ${line#* }" ;;
        esac
    done <<< "$states"
    echo ""
    if [[ $PREREQ_MISSING -gt 0 ]]; then
        echo "Doctor: $PREREQ_MISSING required tool(s) missing or too old (see hints above)."
        return 1
    fi
    echo "Doctor: all required tools present."
    return 0
}

################################################################################
# Steps
################################################################################
# write_stamp DIR FILE / stamp_matches DIR FILE: sha256 of the requirements
# file last installed into the venv, so re-runs skip pip (no network).
stamp_matches() {
    [[ -f "$1/$STAMP_NAME" ]] || return 1
    [[ "$(cat "$1/$STAMP_NAME" 2>/dev/null)" == "$(sst_sha256 "$2")" ]]
}
write_stamp() {
    sst_sha256 "$2" > "$1/$STAMP_NAME"
}

step_venv() {
    if [[ "$SKIP_PYTHON" == true ]]; then
        log "venv: skipped (--skip-python)"
        log "pip: skipped (--skip-python)"
        return 0
    fi
    if [[ -x "$VENV_DIR/bin/python" ]]; then
        log "venv: exists (.venv, Python $("$VENV_DIR/bin/python" -V 2>&1 | awk '{print $2}'))"
    elif [[ "$DRY_RUN" == true ]]; then
        log "venv: dry-run (would run: $PY_CMD -m venv .venv)"
    else
        if "$PY_CMD" -m venv "$VENV_DIR"; then
            log "venv: done (.venv, Python $("$VENV_DIR/bin/python" -V 2>&1 | awk '{print $2}'))"
        else
            step_failed venv "$PY_CMD -m venv .venv"
            return 1
        fi
    fi
    if [[ ! -f "$ROOT/requirements.txt" ]]; then
        log "pip: skipped (no requirements.txt)"
    elif [[ -x "$VENV_DIR/bin/python" ]] && stamp_matches "$VENV_DIR" "$ROOT/requirements.txt"; then
        log "pip: exists (requirements.txt already installed in .venv)"
    elif [[ "$DRY_RUN" == true ]]; then
        log "pip: dry-run (would run: .venv/bin/python -m pip install -r requirements.txt)"
    else
        if "$VENV_DIR/bin/python" -m pip install -q --disable-pip-version-check -r "$ROOT/requirements.txt"; then
            write_stamp "$VENV_DIR" "$ROOT/requirements.txt"
            log "pip: done (requirements.txt)"
        else
            step_failed pip "pip install -r requirements.txt"
            return 1
        fi
    fi
    return 0
}

step_agents() {
    local want=false apy
    if [[ "$SKIP_AGENTS" == true ]]; then
        log "agents-venv: skipped (--skip-agents)"
        return 0
    fi
    if [[ "$WITH_AGENTS" == true ]]; then
        want=true
    elif [[ -x "$AGENTS_VENV_DIR/bin/python" ]]; then
        log "agents-venv: exists (.venv-agents; ./setup.sh --with-agents re-checks its packages)"
        return 0
    elif ask "Create the agent venv .venv-agents (Python $AGENTS_PY_VERSION, ~1.2 GB download)?"; then
        want=true
    fi
    if [[ "$want" != true ]]; then
        log "agents-venv: skipped (optional; ./setup.sh --with-agents)"
        return 0
    fi
    apy="$(agents_python)"
    if [[ -x "$AGENTS_VENV_DIR/bin/python" ]]; then
        log "agents-venv: exists (.venv-agents, Python $("$AGENTS_VENV_DIR/bin/python" -V 2>&1 | awk '{print $2}'))"
    elif [[ -z "$apy" ]]; then
        echo "  MISSING  python$AGENTS_PY_VERSION (needed for .venv-agents)"
        pkg_hint "python@$AGENTS_PY_VERSION" "python$AGENTS_PY_VERSION python$AGENTS_PY_VERSION-venv"
        step_failed agents-venv "python$AGENTS_PY_VERSION not found"
        return 1
    elif [[ "$DRY_RUN" == true ]]; then
        log "agents-venv: dry-run (would run: $apy -m venv .venv-agents)"
    else
        if "$apy" -m venv "$AGENTS_VENV_DIR"; then
            log "agents-venv: done (.venv-agents)"
        else
            step_failed agents-venv "$apy -m venv .venv-agents"
            return 1
        fi
    fi
    if [[ ! -f "$ROOT/requirements-agents.txt" ]]; then
        log "agents-pip: skipped (no requirements-agents.txt)"
    elif [[ -x "$AGENTS_VENV_DIR/bin/python" ]] && stamp_matches "$AGENTS_VENV_DIR" "$ROOT/requirements-agents.txt"; then
        log "agents-pip: exists (requirements-agents.txt already installed)"
    elif [[ "$DRY_RUN" == true ]]; then
        log "agents-pip: dry-run (would run: .venv-agents/bin/python -m pip install -r requirements-agents.txt && pip check)"
        return 0
    else
        if "$AGENTS_VENV_DIR/bin/python" -m pip install -q --disable-pip-version-check -r "$ROOT/requirements-agents.txt"; then
            write_stamp "$AGENTS_VENV_DIR" "$ROOT/requirements-agents.txt"
            log "agents-pip: done (requirements-agents.txt)"
        else
            step_failed agents-pip "pip install -r requirements-agents.txt"
            return 1
        fi
    fi
    if [[ "$DRY_RUN" != true ]]; then
        if "$AGENTS_VENV_DIR/bin/python" -m pip check --disable-pip-version-check >/dev/null 2>&1; then
            log "agents-pip-check: done (no broken requirements)"
        else
            "$AGENTS_VENV_DIR/bin/python" -m pip check --disable-pip-version-check
            step_failed agents-pip-check "pip check"
            return 1
        fi
    fi
    return 0
}

# step_npm DIR: npm ci unless node_modules is at least as new as the lockfile
step_npm() {
    local d="$1" name="npm-$1"
    local dir="$ROOT/$d"
    if [[ "$SKIP_NODE" == true ]]; then
        log "$name: skipped (--skip-node)"
        return 0
    fi
    if [[ ! -f "$dir/package.json" || ! -f "$dir/package-lock.json" ]]; then
        log "$name: skipped (no $d/package.json + package-lock.json)"
        return 0
    fi
    if [[ -f "$dir/node_modules/.package-lock.json" ]]; then
        local lock_m nm_m
        lock_m="$(sst_file_mtime "$dir/package-lock.json")"
        nm_m="$(sst_file_mtime "$dir/node_modules/.package-lock.json")"
        if [[ "$nm_m" -ge "$lock_m" ]]; then
            log "$name: exists ($d/node_modules up to date with package-lock.json)"
            return 0
        fi
    fi
    if [[ "$DRY_RUN" == true ]]; then
        log "$name: dry-run (would run: npm ci in $d/)"
        return 0
    fi
    if (cd "$dir" && npm ci --no-audit --no-fund); then
        log "$name: done (npm ci in $d/)"
    else
        step_failed "$name" "npm ci in $d/"
        return 1
    fi
    return 0
}

step_config() {
    if [[ "$SKIP_CONFIG" == true ]]; then
        log "config: skipped (--skip-config)"
        return 0
    fi
    if [[ -f "$CONFIG_FILE" ]]; then
        log "config: exists (config.sh left unchanged)"
    elif [[ ! -f "$TEMPLATE_FILE" ]]; then
        step_failed config "config.template.sh not found"
        return 1
    elif [[ "$DRY_RUN" == true ]]; then
        log "config: dry-run (would copy config.template.sh to config.sh, mode 600)"
        return 0
    else
        local tmp
        tmp="$(mktemp "$ROOT/.config.sh.XXXXXX")" || { step_failed config "mktemp"; return 1; }
        if cp "$TEMPLATE_FILE" "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$CONFIG_FILE"; then
            log "config: done (config.sh created from config.template.sh, mode 600; add keys with ./setup.sh --configure-keys)"
        else
            rm -f "$tmp"
            step_failed config "could not create config.sh"
            return 1
        fi
    fi
    check_paper_url
    return 0
}

# write_key KEY: value in SST_V (environment); replaces every
# `export KEY=...` line in config.sh or appends one. Temp file in the repo
# dir, mode 600, then mv.
write_key() {
    local key="$1" tmp
    tmp="$(mktemp "$ROOT/.config.sh.XXXXXX")" || return 1
    if SST_K="$key" perl -e '
        my ($file, $tmp) = @ARGV;
        my $k = $ENV{SST_K};
        my $v = $ENV{SST_V};
        (my $q = $v) =~ s/\x27/\x27\\\x27\x27/g;
        my $line = "export $k=\x27$q\x27\n";
        open(my $in, "<", $file) or exit 1;
        my @lines = <$in>;
        close $in;
        my $found = 0;
        for (@lines) {
            if (/^\s*export\s+\Q$k\E=/) { $_ = $line; $found = 1; }
        }
        if (!$found) {
            $lines[-1] .= "\n" if @lines && $lines[-1] !~ /\n\z/;
            push @lines, $line;
        }
        open(my $out, ">", $tmp) or exit 1;
        print $out @lines;
        close $out or exit 1;
    ' -- "$CONFIG_FILE" "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$CONFIG_FILE"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

step_keys() {
    local want=false k SST_V
    if [[ "$SKIP_CONFIG" == true ]]; then
        return 0
    fi
    if [[ "$CONFIGURE_KEYS" == true ]]; then
        want=true
    elif ask "Enter API keys into config.sh now (Enter keeps the current value)?"; then
        want=true
    fi
    if [[ "$want" != true ]]; then
        log "keys: skipped (./setup.sh --configure-keys to enter them)"
        return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then
        log "keys: dry-run (would prompt for $KEY_NAMES)"
        return 0
    fi
    if [[ ! -f "$CONFIG_FILE" ]]; then
        step_failed keys "config.sh not found"
        return 1
    fi
    for k in $KEY_NAMES; do
        SST_V=""
        printf '%s (Enter = keep current): ' "$k" >&2
        if [[ "$k" == SEC_USER_AGENT ]]; then
            IFS= read -r SST_V || SST_V="${SST_V:-}"
        else
            IFS= read -rs SST_V || SST_V="${SST_V:-}"
            [[ -t 0 ]] && echo "" >&2
        fi
        [[ -t 0 ]] || echo "" >&2
        SST_V="${SST_V%$'\r'}"
        if [[ -z "$SST_V" ]]; then
            echo "$k: unchanged"
            continue
        fi
        if SST_V="$SST_V" write_key "$k"; then
            echo "$k: set"
        else
            echo "$k: unchanged (write failed)"
            FAILED_STEPS=$((FAILED_STEPS + 1))
        fi
        SST_V=""
    done
    chmod 600 "$CONFIG_FILE"
    log "keys: done (config.sh mode 600)"
    check_paper_url
    return 0
}

step_model() {
    if [[ "$SKIP_MODEL" == true ]]; then
        log "model: skipped (--skip-model)"
        return 0
    fi
    if [[ -f "$MODEL_FILE" ]]; then
        log "model: exists (lib/models/xgboost_predictor.pkl)"
        return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then
        log "model: dry-run (would run: .venv/bin/python lib/train_ml_model.py)"
        return 0
    fi
    if [[ ! -x "$VENV_DIR/bin/python" ]]; then
        log "model: skipped (no .venv; run ./setup.sh without --skip-python)"
        return 0
    fi
    if (cd "$ROOT" && "$VENV_DIR/bin/python" lib/train_ml_model.py); then
        log "model: done (lib/models/xgboost_predictor.pkl trained on synthetic data)"
    else
        step_failed model "python lib/train_ml_model.py"
        return 1
    fi
    return 0
}

# smoke_run LABEL CMD...: run in ROOT, output to a temp log; tail on failure
smoke_run() {
    local label="$1" out rc
    shift
    out="$(mktemp "${TMPDIR:-/tmp}/sst_setup_smoke.XXXXXX")" || return 1
    (cd "$ROOT" && "$@") > "$out" 2>&1 </dev/null
    rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "  ok       $label"
    else
        echo "  FAILED   $label (exit $rc); last lines:"
        tail -20 "$out" | sed 's/^/    /'
    fi
    rm -f "$out"
    return $rc
}

step_smoke() {
    if [[ "$SKIP_SMOKE" == true ]]; then
        log "smoke: skipped (--skip-smoke)"
        return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then
        log "smoke: dry-run (would run: ./StockSwingTrader_Agent.sh --version; --safety-status;" \
            "SST_OFFLINE=1 ./StockSwingTrader_Agent.sh --symbols AAPL --output-dir output/reports;" \
            "bash lib/ml_predictor.sh status)"
        return 0
    fi
    local bad=0
    smoke_run "./StockSwingTrader_Agent.sh --version" ./StockSwingTrader_Agent.sh --version || bad=1
    smoke_run "./StockSwingTrader_Agent.sh --safety-status" ./StockSwingTrader_Agent.sh --safety-status || bad=1
    smoke_run "SST_OFFLINE=1 ./StockSwingTrader_Agent.sh --symbols AAPL --output-dir output/reports" \
        env SST_OFFLINE=1 ./StockSwingTrader_Agent.sh --symbols AAPL --output-dir output/reports || bad=1
    smoke_run "bash lib/ml_predictor.sh status" bash lib/ml_predictor.sh status || bad=1
    if [[ $bad -eq 0 ]]; then
        log "smoke: done"
    else
        step_failed smoke "see FAILED lines above"
        return 1
    fi
    return 0
}

step_full_tests() {
    [[ "$FULL_TESTS" == true ]] || return 0
    if [[ "$DRY_RUN" == true ]]; then
        log "full-tests: dry-run (would run: bash tests/test_runner.sh)"
        return 0
    fi
    if (cd "$ROOT" && bash tests/test_runner.sh); then
        log "full-tests: done (report in reports/test-report.md)"
    else
        step_failed full-tests "bash tests/test_runner.sh; report in reports/test-report.md"
        return 1
    fi
    return 0
}

################################################################################
# Main
################################################################################
if [[ "$DOCTOR" == true ]]; then
    run_doctor
    exit $?
fi

[[ "$DRY_RUN" == true ]] && log "dry-run: printing planned actions only, nothing is changed"
log "os: $(sst_os)"
need_python=true
[[ "$SKIP_PYTHON" == true ]] && need_python=false
need_node=true
[[ "$SKIP_NODE" == true ]] && need_node=false
check_prereqs "$need_python" "$need_node"
if [[ $PREREQ_MISSING -gt 0 ]]; then
    log "prerequisites: failed ($PREREQ_MISSING required tool(s) missing or too old; install them and re-run)"
    exit 1
fi
log "prerequisites: done"

step_venv
step_agents
step_npm backend
step_npm frontend
step_config
step_keys
step_model
step_smoke
step_full_tests

if [[ $FAILED_STEPS -gt 0 ]]; then
    log "finished with $FAILED_STEPS failed step(s)"
    exit 1
fi
if [[ "$DRY_RUN" == true ]]; then
    log "finished (dry-run, nothing changed)"
else
    log "finished. Next: ./setup.sh --doctor, ./StockSwingTrader_Agent.sh --help"
fi
exit 0
