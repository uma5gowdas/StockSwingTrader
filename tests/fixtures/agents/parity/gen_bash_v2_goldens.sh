#!/bin/bash
# ============================================================================
# Bash v2 parity goldens for agents/technical/bash_compat.py
# ============================================================================
# Runs the REAL bash scan path (StockSwingTrader_Agent.sh
# calculate_all_indicators -> score_stock -> calculate_confluence_score_v2)
# on 60-bar windows of the offline fixtures (tests/fixtures/agents/bars) and
# writes tests/fixtures/agents/parity/v2_windows.json.
#
# Windows: AAA, BBB, CCC x 20 end indices (59, 108, ..., 990; 0-based data
# rows), 60 bars each. ML "absent" (unset -f ml_predict_direction: ML 50
# neutral) for all 60; ML "unavailable" (SST_OFFLINE=0 + the yfinance_empty
# stub on PYTHONPATH, ML_TIMEOUT_SECONDS=30) for 5 of them: 65 entries.
#
# No network: fetch_current_price is replaced by `echo 0; return 1` (the
# Bollinger price is then the last close, as offline), aggregate_sentiment
# prints {"aggregate_sentiment_score":null} (sentiment "na"), an empty
# SST_CONFIG_FILE and temp cache dirs are used, LOG_FILE=/dev/null.
#
# Usage:
#   gen_bash_v2_goldens.sh                       regenerate v2_windows.json
#   gen_bash_v2_goldens.sh window SYM END ML     print one entry (compact JSON)
#   gen_bash_v2_goldens.sh window-json SYM END   print the OHLCV window JSON
#   gen_bash_v2_goldens.sh list                  print "SYM END ML" per entry
# ============================================================================
PARITY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$PARITY_DIR/../../../.." && pwd)"
BARS_DIR="$PROJECT_DIR/tests/fixtures/agents/bars"
OUT_FILE="$PARITY_DIR/v2_windows.json"
WINDOW_BARS=60

# list: every (symbol, end index, ml mode) entry, in output order
list_windows() {
    local s k end
    for s in AAA BBB CCC; do
        for ((k = 0; k < 20; k++)); do
            end=$((59 + k * 49))
            echo "$s $end absent"
        done
    done
    echo "AAA 59 unavailable"
    echo "AAA 549 unavailable"
    echo "BBB 304 unavailable"
    echo "CCC 794 unavailable"
    echo "CCC 990 unavailable"
}

# window_json SYM END -> {"symbol","data_source":"fixture","ohlcv":[...]}
# (one line; the CSV text of each number is kept as is)
window_json() {
    local sym=$1 end=$2
    awk -F, -v s="$sym" -v e="$end" -v n="$WINDOW_BARS" '
        NR == 1 { next }
        { i = NR - 2 }
        i > e - n && i <= e {
            row = sprintf("{\"date\":\"%s\",\"open\":%s,\"high\":%s,\"low\":%s,\"close\":%s,\"volume\":%s}", $1, $2, $3, $4, $5, $6)
            out = (out == "" ? row : out "," row)
        }
        END { printf "{\"symbol\":\"%s\",\"data_source\":\"fixture\",\"ohlcv\":[%s]}\n", s, out }' "$BARS_DIR/$sym.csv"
}

# run_window SYM END ML -> one entry (compact JSON)
run_window() {
    local sym=$1 end=$2 ml=$3
    local work
    work=$(mktemp -d "${TMPDIR:-/tmp}/sst_parity.XXXXXX")
    : > "$work/config.sh"
    mkdir -p "$work/regime" "$work/mirofish" "$work/risk" "$work/sentiment"
    window_json "$sym" "$end" > "$work/window.json"
    local end_date
    end_date=$(jq -r '.ohlcv[-1].date' "$work/window.json")
    local -a ml_env=(SST_OFFLINE=1)
    if [[ "$ml" == "unavailable" ]]; then
        ml_env=(SST_OFFLINE=0 PYTHONPATH="$PROJECT_DIR/tests/stubs/yfinance_empty" ML_TIMEOUT_SECONDS=30)
    fi
    env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" LANG=C LC_ALL=C \
        SST_CONFIG_FILE="$work/config.sh" REGIME_CACHE_DIR="$work/regime" \
        MIROFISH_CACHE_DIR="$work/mirofish" RISK_BUDGET_DIR="$work/risk" \
        SENTIMENT_CACHE_DIR="$work/sentiment" SST_STATE_DIR="$work/state" \
        ALERT_LOG_FILE="$work/alerts.log" LOG_FILE=/dev/null "${ml_env[@]}" /bin/bash -c '
        cd "$2" || exit 1
        source "$1/StockSwingTrader_Agent.sh" >/dev/null 2>&1
        LOG_FILE=/dev/null
        fetch_current_price() { echo 0; return 1; }
        aggregate_sentiment() { echo "{\"aggregate_sentiment_score\":null}"; }
        [[ "$4" == "absent" ]] && unset -f ml_predict_direction
        ohlcv=$(cat "$2/window.json")
        ind=$(calculate_all_indicators "$3" "$ohlcv" 2>/dev/null) || exit 1
        score_stock "$3" "$ind" 2>/dev/null | grep "^{"' _ "$PROJECT_DIR" "$work" "$sym" "$ml" \
        | jq -c --arg id "$(printf '%s_%03d_%s' "$sym" "$end" "$ml")" --arg sym "$sym" \
            --argjson end "$end" --arg date "$end_date" --arg ml "$ml" '
            {id: $id, symbol: $sym, end_index: $end, end_date: $date, bars: 60, ml_mode: $ml,
             last_close: .indicators.last_close,
             indicators: .indicators.indicators,
             scores: .scores,
             v2_inputs: (.v2_inputs | del(.regime_detail.timestamp)),
             confluence_v2: (.confluence_v2 | del(.metadata.latency_ms, .metadata.timestamp))}'
    local rc=${PIPESTATUS[0]}
    rm -rf "$work"
    return "$rc"
}

generate_all() {
    local tmp start n=0 jobs=0
    start=$(date +%s)
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/sst_parity_all.XXXXXX")
    while read -r sym end ml; do
        n=$((n + 1))
        ( run_window "$sym" "$end" "$ml" > "$tmp/$(printf '%03d' "$n").json" ) &
        jobs=$((jobs + 1))
        if [[ $jobs -ge 4 ]]; then
            wait
            jobs=0
        fi
    done < <(list_windows)
    wait
    local f bad=0
    for f in "$tmp"/*.json; do
        if ! jq -e 'type == "object" and .confluence_v2.confluence_score != null' "$f" >/dev/null 2>&1; then
            echo "ERROR: window $(basename "$f") failed" >&2
            bad=1
        fi
    done
    if [[ $bad -ne 0 ]]; then
        rm -rf "$tmp"
        return 1
    fi
    jq -s -S '.' "$tmp"/*.json > "$OUT_FILE.tmp" && mv "$OUT_FILE.tmp" "$OUT_FILE"
    rm -rf "$tmp"
    echo "wrote $OUT_FILE ($(jq length "$OUT_FILE") entries, $(( $(date +%s) - start )) s)"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-all}" in
        all) generate_all ;;
        window) run_window "$2" "$3" "${4:-absent}" ;;
        window-json) window_json "$2" "$3" ;;
        list) list_windows ;;
        *) echo '{"error":"usage: gen_bash_v2_goldens.sh [all|window SYM END ML|window-json SYM END|list]"}' >&2; exit 1 ;;
    esac
fi
