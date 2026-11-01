#!/bin/bash
# ============================================================================
# v2 golden case runner (shared by generate_goldens.sh and
# tests/test_scoring_agents.sh, so goldens and checks use one recipe)
# ============================================================================
# Usage:
#   run_case.sh v2 CASE_JSON [EXTRA_ENV...]
#       CASE_JSON = one element of cases.json:
#         {name, args:[...], ml:"absent"|"offline", env:{...},
#          mirofish_cache:null|{prediction, confidence}}
#       Runs calculate_confluence_score_v2 ARGS in a fresh
#       `bash -c 'source lib/scoring.sh; ...'` with a minimal environment
#       (PATH, HOME, TMPDIR + case env + EXTRA_ENV NAME=VALUE pairs).
#       ml "absent": `unset -f ml_predict_direction` (ML neutral 50).
#       ml "offline": SST_OFFLINE=1, ML_TIMEOUT_SECONDS=30, real predictor.
#       mirofish_cache: a temp MIROFISH_CACHE_DIR/<SYMBOL>.json written with
#       the current time; MIROFISH_ENABLED=true.
#   run_case.sh analyze [EXTRA_ENV...]
#       Sources StockSwingTrader_Agent.sh with SST_OFFLINE=1, an empty temp
#       SST_CONFIG_FILE and temp cache dirs, replaces fetch_stock_ohlcv with
#       ohlcv_60.json and prints analyze_stock AAPL (.v2_inputs and
#       .indicators.v2_inputs regime_detail.timestamp removed too).
# Output: compact, key-sorted JSON with latency/timestamps removed.
# ============================================================================

GOLDEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$GOLDEN_DIR/../../../.." && pwd)"

mode="$1"
shift

work=$(mktemp -d "${TMPDIR:-/tmp}/sst_v2_golden.XXXXXX")
trap 'rm -rf "$work"' EXIT

base_env=(PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" LANG=C LC_ALL=C)

if [[ "$mode" == "v2" ]]; then
    case_json="$1"
    shift
    envs=("${base_env[@]}" REGIME_CACHE_DIR="$work/regime")
    while IFS= read -r kv; do
        [[ -n "$kv" ]] && envs+=("$kv")
    done < <(printf '%s' "$case_json" | jq -r '(.env // {}) | to_entries[] | "\(.key)=\(.value)"')
    ml=$(printf '%s' "$case_json" | jq -r '.ml // "absent"')
    if [[ "$ml" == "offline" ]]; then
        envs+=(SST_OFFLINE=1 ML_TIMEOUT_SECONDS=30)
    fi
    if printf '%s' "$case_json" | jq -e '.mirofish_cache != null' >/dev/null 2>&1; then
        sym=$(printf '%s' "$case_json" | jq -r '.args[0]')
        mkdir -p "$work/mirofish"
        printf '%s' "$case_json" | jq --arg s "$sym" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{symbol:$s, generated_at:$t, prediction:.mirofish_cache.prediction,
              confidence:.mirofish_cache.confidence, status:"OK"}' > "$work/mirofish/$sym.json"
        envs+=(MIROFISH_ENABLED=true MIROFISH_CACHE_DIR="$work/mirofish")
    fi
    envs+=("$@")
    args=()
    while IFS= read -r a; do args+=("$a"); done < <(printf '%s' "$case_json" | jq -r '.args[]')
    env -i "${envs[@]}" /bin/bash -c '
        source "$1/lib/scoring.sh" >/dev/null 2>&1
        [[ "$2" == "absent" ]] && unset -f ml_predict_direction
        shift 2
        calculate_confluence_score_v2 "$@" </dev/null 2>/dev/null' _ "$PROJECT_DIR" "$ml" "${args[@]}" \
        | jq -S -c 'del(.metadata.latency_ms, .metadata.timestamp)'
elif [[ "$mode" == "analyze" ]]; then
    : > "$work/config.sh"
    mkdir -p "$work/regime" "$work/mirofish" "$work/risk" "$work/sentiment" "$work/home"
    env -i "${base_env[@]}" SST_OFFLINE=1 SST_CONFIG_FILE="$work/config.sh" \
        REGIME_CACHE_DIR="$work/regime" MIROFISH_CACHE_DIR="$work/mirofish" \
        RISK_BUDGET_DIR="$work/risk" SENTIMENT_CACHE_DIR="$work/sentiment" \
        SST_STATE_DIR="$work/state" ALERT_LOG_FILE="$work/alerts.log" \
        LOG_FILE=/dev/null "$@" /bin/bash -c '
        cd "$3" || exit 1
        source "$1/StockSwingTrader_Agent.sh" >/dev/null 2>&1
        LOG_FILE=/dev/null
        SST_GOLDEN_OHLCV="$2"
        fetch_stock_ohlcv() { cat "$SST_GOLDEN_OHLCV"; }
        analyze_stock AAPL 2>/dev/null | grep -v "^\["' _ "$PROJECT_DIR" "$GOLDEN_DIR/ohlcv_60.json" "$work" \
        | jq -S -c 'del(.confluence_v2.metadata.latency_ms, .confluence_v2.metadata.timestamp, .v2_inputs.regime_detail.timestamp, .indicators.v2_inputs.regime_detail.timestamp)'
else
    echo '{"error":"usage: run_case.sh v2 CASE_JSON | analyze"}' >&2
    exit 1
fi
