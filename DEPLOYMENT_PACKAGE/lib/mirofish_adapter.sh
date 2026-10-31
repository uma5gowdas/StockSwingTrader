#!/bin/bash
# ============================================================================
# StockSwingTrader: MiroFish Cache Adapter (optional, default OFF)
# ============================================================================
# Ported from v6.2 Phase 1 (phase1/lib/mirofish_adapter.sh and
# phase1/ml/mirofish_predictor.py), but rewritten as a CACHE READER.
#
# Why no HTTP client:
#   The v6.2 adapter POSTed to MIROFISH_API_URL/predict. Real MiroFish has no
#   /predict endpoint (it is an async multi-agent social simulator; see
#   .agents/tasks/mirofish-real-integration-plan.md), so the v6.2 client
#   always fell back to NEUTRAL. Calling it per symbol at scan time would
#   only add latency. This adapter therefore makes NO network calls: it reads
#   ${MIROFISH_CACHE_DIR}/<SYMBOL>.json. A missing cache file costs one file
#   test per symbol and the existing scoring is used unchanged.
#
# The cache producer (an overnight lib/mirofish_bridge.py that would drive
# MiroFish and write these files) is NOT implemented yet.
#
# API CONTRACT UNVERIFIED: the cache schema below is provisional. It has not
# been checked against real MiroFish output (a separate investigation is
# running) and may change when the bridge is written.
#
# Cache schema (one file per symbol, ${MIROFISH_CACHE_DIR}/<SYMBOL>.json):
#   {
#     "symbol":       "AAPL",
#     "generated_at": "2026-10-31T02:00:00Z",   ISO-8601 UTC ("as_of" accepted)
#     "prediction":   "BULLISH"|"BEARISH"|"NEUTRAL",
#     "confidence":   0..1,
#     "agent_votes":  {"bullish":N,"bearish":N,"neutral":N},   optional
#     "status":       "OK",                                    optional
#     "simulation_id"/"model"/"n_agents":                      optional, ignored
#   }
#
# Statuses returned by mirofish_get_prediction:
#   DISABLED        MIROFISH_ENABLED != true
#   MISSING         no cache file
#   INVALID         bad symbol, unparsable JSON, bad prediction/confidence,
#                   generated_at > 5 min in the future, or file status != OK
#   STALE           older than MIROFISH_MAX_AGE_HOURS (default 36)
#   LOW_CONFIDENCE  confidence < MIROFISH_MIN_CONFIDENCE (default 0.4)
#   OK              usable; score = 50 +/- 50*confidence (NEUTRAL = 50)
# Only OK contributes to scoring.
# ============================================================================

# Module-private lib dir (do NOT touch SCRIPT_DIR, other libs depend on it)
_MIROFISH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export _MIROFISH_LIB_DIR

# ----------------------------------------------------------------------------
# mirofish_cache_dir
# Description: Cache directory; a relative MIROFISH_CACHE_DIR resolves
#   against the project root (parent of lib/)
# Returns: absolute directory path
# ----------------------------------------------------------------------------
mirofish_cache_dir() {
    local dir="${MIROFISH_CACHE_DIR:-cache/mirofish}"
    if [[ "$dir" != /* ]]; then
        dir="$(cd "${_MIROFISH_LIB_DIR}/.." && pwd)/${dir}"
    fi
    echo "$dir"
}

# ----------------------------------------------------------------------------
# mirofish_cache_file SYMBOL
# Description: Cache file path for SYMBOL (uppercased). Rejects anything not
#   matching ^[A-Z0-9.-]{1,10}$ (path-traversal guard).
# Returns: path on stdout; rc 1 for an invalid symbol
# ----------------------------------------------------------------------------
mirofish_cache_file() {
    local sym
    sym=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
    [[ "$sym" =~ ^[A-Z0-9.-]{1,10}$ ]] || return 1
    [[ "$sym" == *..* ]] && return 1
    echo "$(mirofish_cache_dir)/${sym}.json"
}

# ----------------------------------------------------------------------------
# _mirofish_result SYMBOL STATUS
# Description: Minimal non-OK result record
# ----------------------------------------------------------------------------
_mirofish_result() {
    jq -cn --arg symbol "$1" --arg status "$2" \
        '{symbol:$symbol, status:$status, prediction:null, confidence:null, agent_votes:null, generated_at:null, age_hours:null, score:null}'
}

# ----------------------------------------------------------------------------
# mirofish_get_prediction SYMBOL
# Description: Read and validate the cached MiroFish prediction. Never makes
#   a network call and never sleeps or retries.
# Returns: JSON {symbol, status, prediction, confidence, agent_votes,
#   generated_at, age_hours, score}; score is null unless status is OK
# Example: MIROFISH_ENABLED=true mirofish_get_prediction AAPL
# ----------------------------------------------------------------------------
mirofish_get_prediction() {
    local symbol="$1"
    if [[ "${MIROFISH_ENABLED:-false}" != "true" ]]; then
        _mirofish_result "$symbol" "DISABLED"
        return 0
    fi
    local file
    if ! file=$(mirofish_cache_file "$symbol"); then
        _mirofish_result "$symbol" "INVALID"
        return 0
    fi
    if [[ ! -f "$file" ]]; then
        _mirofish_result "$symbol" "MISSING"
        return 0
    fi

    local max_age="${MIROFISH_MAX_AGE_HOURS:-36}"
    [[ "$max_age" =~ ^[0-9]+(\.[0-9]+)?$ ]] || max_age=36
    local min_conf="${MIROFISH_MIN_CONFIDENCE:-0.4}"
    [[ "$min_conf" =~ ^[0-9]+(\.[0-9]+)?$ ]] || min_conf=0.4

    local out
    out=$(jq -c --arg symbol "$symbol" --argjson max_age "$max_age" --argjson min_conf "$min_conf" '
        def base(s): {symbol:$symbol, status:s, prediction:null, confidence:null, agent_votes:null, generated_at:null, age_hours:null, score:null};
        if type != "object" then base("INVALID")
        else
          ((.generated_at // .as_of // null)) as $ts
          | (try ($ts | fromdateiso8601) catch null) as $t
          | (.prediction // null) as $p
          | (.confidence // null) as $c
          | if ($p | IN("BULLISH","BEARISH","NEUTRAL") | not) then base("INVALID")
            elif ($c | type) != "number" or $c < 0 or $c > 1 then base("INVALID")
            elif $t == null then base("INVALID")
            elif ($t - now) > 300 then base("INVALID")
            elif (has("status") and .status != "OK") then base("INVALID")
            else
              (((now - $t) / 3600) | if . < 0 then 0 else . end) as $age
              | (if $age > $max_age then "STALE"
                 elif $c < $min_conf then "LOW_CONFIDENCE"
                 else "OK" end) as $st
              | {symbol:$symbol, status:$st, prediction:$p, confidence:$c,
                 agent_votes:(.agent_votes // null), generated_at:$ts,
                 age_hours:(($age * 100 | round) / 100),
                 score:(if $st != "OK" then null
                        elif $p == "BULLISH" then (50 + 50 * $c | round)
                        elif $p == "BEARISH" then (50 - 50 * $c | round)
                        else 50 end)}
            end
        end' "$file" 2>/dev/null)
    if [[ -z "$out" ]]; then
        _mirofish_result "$symbol" "INVALID"
        return 0
    fi
    echo "$out"
}

# ----------------------------------------------------------------------------
# mirofish_prediction_to_signal JSON
# Description: Direction signal (ported from Phase 1): 1 BULLISH, -1 BEARISH,
#   0 otherwise; 0 unless status is OK
# ----------------------------------------------------------------------------
mirofish_prediction_to_signal() {
    local sig
    sig=$(printf '%s' "$1" | jq -r 'if .status != "OK" then 0
        elif .prediction == "BULLISH" then 1
        elif .prediction == "BEARISH" then -1 else 0 end' 2>/dev/null)
    echo "${sig:-0}"
}

# ----------------------------------------------------------------------------
# mirofish_effective_weight
# Description: MIROFISH_WEIGHT (default 0.10) clamped to [0, 0.5]; 0 if not numeric
# ----------------------------------------------------------------------------
mirofish_effective_weight() {
    local w="${MIROFISH_WEIGHT:-0.10}"
    if [[ ! "$w" =~ ^[0-9]+(\.[0-9]+)?$ && ! "$w" =~ ^\.[0-9]+$ ]]; then
        echo "0"
        return 0
    fi
    awk -v w="$w" 'BEGIN { if (w > 0.5) w = 0.5; if (w < 0) w = 0; printf "%g\n", w }'
}

# ----------------------------------------------------------------------------
# mirofish_blend_score BASE MF_SCORE WEIGHT
# Description: round(BASE*(1-W) + MF_SCORE*W)
# Example: mirofish_blend_score 60 90 0.1   # -> 63
# ----------------------------------------------------------------------------
mirofish_blend_score() {
    awk -v b="$1" -v m="$2" -v w="$3" 'BEGIN { printf "%d\n", int(b * (1 - w) + m * w + 0.5) }'
}

export -f mirofish_cache_dir mirofish_cache_file _mirofish_result mirofish_get_prediction
export -f mirofish_prediction_to_signal mirofish_effective_weight mirofish_blend_score
