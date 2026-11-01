#!/bin/bash
# ============================================================================
# StockSwingTrader: Agent Cache Adapter (optional, default OFF)
# ============================================================================
# Reads the JSON envelopes the Python agent layer (agents/, `python -m agents
# <agent> run`) writes to the cache, and the validation gates. Follows
# lib/mirofish_adapter.sh: NO network calls, no python, bash 3.2 + jq only.
# The scan never runs an agent; it only reads these files.
#
# Layout (AGENT_CACHE_DIR, default cache/agents; relative = project root):
#   <agent>/<YYYY-MM-DD>/<SYMBOL>.json   envelope (agents/schemas/envelope.schema.json)
#   gates/<signal_id>.json               gate {signal_id, generated_at, passed,
#                                        synthetic, ...} (Strategy Validation)
#
# agent_get statuses:
#   DISABLED     AGENTS_ENABLED != true (technical: also AGENT_TECHNICAL_ENABLED != true)
#   MISSING      no cache file
#   INVALID      bad agent/symbol, unparsable JSON, .agent/.symbol mismatch,
#                generated_at unparsable or > 5 min in the future, score not
#                null / 0..100, available not boolean
#   STALE        age > ttl_hours of the file (else AGENT_MAX_AGE_HOURS, 36)
#   UNAVAILABLE  available false
#   OK           usable (score is null unless OK)
# agent_gate_get statuses: MISSING | INVALID | SYNTHETIC | EXPIRED (older than
#   AGENT_GATE_MAX_AGE_DAYS, 45) | FAILED | PASSED (checked in that order)
#
# Additive agents (calculate_confluence_score_v2, lib/scoring.sh):
#   quant       gate quant_rank           AGENT_QUANT_WEIGHT
#   fundamental gate fundamental_quality  AGENT_FUNDAMENTAL_WEIGHT
#   market      gate market_news_score    AGENT_MARKET_WEIGHT
# Weights default 0, each clamped to [0, 0.30] (non-numeric = 0); the applied
# total is capped at AGENT_MAX_TOTAL_WEIGHT (0.30, clamped to [0, 0.5]) by
# proportional scaling. A weight applies only when the cache is OK, not
# synthetic (except SST_OFFLINE=1) and the gate is PASSED.
# ============================================================================

# Module-private lib dir (do NOT touch SCRIPT_DIR, other libs depend on it)
_AGENT_ADAPTER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export _AGENT_ADAPTER_LIB_DIR

# ----------------------------------------------------------------------------
# agent_cache_dir
# Description: Agent cache root; a relative AGENT_CACHE_DIR resolves against
#   the project root (parent of lib/)
# Returns: absolute directory path
# ----------------------------------------------------------------------------
agent_cache_dir() {
    local dir="${AGENT_CACHE_DIR:-cache/agents}"
    if [[ "$dir" != /* ]]; then
        dir="$(cd "${_AGENT_ADAPTER_LIB_DIR}/.." && pwd)/${dir}"
    fi
    echo "$dir"
}

# ----------------------------------------------------------------------------
# _agent_valid_name AGENT
# Description: rc 0 when AGENT is one of the six agent names
# ----------------------------------------------------------------------------
_agent_valid_name() {
    case "$1" in
        market|fundamental|technical|quant|validate|portfolio) return 0 ;;
    esac
    return 1
}

# ----------------------------------------------------------------------------
# _agent_norm_symbol SYMBOL
# Description: Uppercased SYMBOL if it matches ^[A-Z0-9.-]{1,10}$ without '..'
# Returns: symbol on stdout; rc 1 when invalid
# ----------------------------------------------------------------------------
_agent_norm_symbol() {
    local sym
    sym=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
    [[ "$sym" =~ ^[A-Z0-9.-]{1,10}$ ]] || return 1
    [[ "$sym" == *..* ]] && return 1
    echo "$sym"
}

# ----------------------------------------------------------------------------
# _agent_signal_for AGENT / _agent_weight_var AGENT
# Description: gate signal id / weight variable name of an additive agent
# ----------------------------------------------------------------------------
_agent_signal_for() {
    case "$1" in
        quant) echo "quant_rank" ;;
        fundamental) echo "fundamental_quality" ;;
        market) echo "market_news_score" ;;
        *) return 1 ;;
    esac
}
_agent_weight_var() {
    case "$1" in
        quant) echo "AGENT_QUANT_WEIGHT" ;;
        fundamental) echo "AGENT_FUNDAMENTAL_WEIGHT" ;;
        market) echo "AGENT_MARKET_WEIGHT" ;;
        *) return 1 ;;
    esac
}

# ----------------------------------------------------------------------------
# agent_cache_file AGENT SYMBOL [AS_OF]
# Description: Envelope path. With AS_OF (YYYY-MM-DD): <dir>/<agent>/<AS_OF>/
#   <SYM>.json. Without: the newest YYYY-MM-DD dir <= today (America/New_York)
#   that holds <SYM>.json.
# Returns: path on stdout; rc 1 invalid agent/symbol/as_of; rc 2 none found
# Example: agent_cache_file quant AAPL 2026-10-30
# ----------------------------------------------------------------------------
agent_cache_file() {
    local agent="$1" sym as_of="$3"
    _agent_valid_name "$agent" || return 1
    sym=$(_agent_norm_symbol "$2") || return 1
    local base
    base="$(agent_cache_dir)/${agent}"
    if [[ -n "$as_of" ]]; then
        [[ "$as_of" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
        echo "${base}/${as_of}/${sym}.json"
        return 0
    fi
    local today best="" d name
    today=$(TZ=America/New_York date +%Y-%m-%d)
    for d in "$base"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]; do
        [[ -f "$d/${sym}.json" ]] || continue
        name="${d##*/}"
        # string comparison is date order for YYYY-MM-DD
        [[ "$name" > "$today" ]] && continue
        best="$d/${sym}.json"
    done
    [[ -n "$best" ]] || return 2
    echo "$best"
}

# ----------------------------------------------------------------------------
# _agent_result AGENT SYMBOL STATUS [REASON]
# Description: Minimal non-OK agent_get record
# ----------------------------------------------------------------------------
_agent_result() {
    jq -cn --arg agent "$1" --arg symbol "$2" --arg status "$3" --arg reason "${4:-}" \
        '{agent:$agent, symbol:$symbol, status:$status, as_of:null, generated_at:null,
          age_hours:null, available:null, synthetic:null, score:null, direction:null,
          confidence:null, veto:null, features:null,
          reason:(if $reason == "" then null else $reason end)}'
}

# ----------------------------------------------------------------------------
# agent_get AGENT SYMBOL [AS_OF]
# Description: Read and validate a cached agent envelope. Never makes a
#   network call.
# Returns: JSON {agent, symbol, status, as_of, generated_at, age_hours,
#   available, synthetic, score, direction, confidence, veto, features, reason}
# Example: AGENTS_ENABLED=true agent_get quant AAPL
# ----------------------------------------------------------------------------
agent_get() {
    local agent="$1" symbol="$2" as_of="$3"
    if [[ "${AGENTS_ENABLED:-false}" != "true" ]]; then
        _agent_result "$agent" "$symbol" "DISABLED" "AGENTS_ENABLED is not true"
        return 0
    fi
    if [[ "$agent" == "technical" && "${AGENT_TECHNICAL_ENABLED:-false}" != "true" ]]; then
        _agent_result "$agent" "$symbol" "DISABLED" "AGENT_TECHNICAL_ENABLED is not true"
        return 0
    fi
    local sym file rc
    if ! _agent_valid_name "$agent"; then
        _agent_result "$agent" "$symbol" "INVALID" "unknown agent"
        return 0
    fi
    if ! sym=$(_agent_norm_symbol "$symbol"); then
        _agent_result "$agent" "$symbol" "INVALID" "invalid symbol"
        return 0
    fi
    file=$(agent_cache_file "$agent" "$sym" "$as_of")
    rc=$?
    if [[ $rc -eq 1 ]]; then
        _agent_result "$agent" "$sym" "INVALID" "invalid as_of"
        return 0
    fi
    if [[ $rc -ne 0 || ! -f "$file" ]]; then
        _agent_result "$agent" "$sym" "MISSING" "no cache file"
        return 0
    fi

    local max_age="${AGENT_MAX_AGE_HOURS:-36}"
    [[ "$max_age" =~ ^[0-9]+(\.[0-9]+)?$ ]] || max_age=36

    local out
    out=$(jq -c --arg agent "$agent" --arg symbol "$sym" --argjson max_age "$max_age" '
        def base(s; r): {agent:$agent, symbol:$symbol, status:s, as_of:null, generated_at:null,
            age_hours:null, available:null, synthetic:null, score:null, direction:null,
            confidence:null, veto:null, features:null, reason:r};
        if type != "object" then base("INVALID"; "not a JSON object")
        elif .agent != $agent then base("INVALID"; "agent mismatch")
        elif .symbol != $symbol then base("INVALID"; "symbol mismatch")
        else
          (try (.generated_at | fromdateiso8601) catch null) as $t
          | if $t == null then base("INVALID"; "generated_at unparsable")
            elif ($t - now) > 300 then base("INVALID"; "generated_at in the future")
            elif (.score != null and ((.score | type) != "number" or .score < 0 or .score > 100))
              then base("INVALID"; "score not null or 0..100")
            elif ((.available | type) != "boolean") then base("INVALID"; "available not boolean")
            else
              ((if (.ttl_hours | type) == "number" and .ttl_hours > 0 then .ttl_hours else $max_age end)) as $ttl
              | (((now - $t) / 3600) | if . < 0 then 0 else . end) as $age
              | (if $age > $ttl then "STALE"
                 elif .available == false then "UNAVAILABLE"
                 else "OK" end) as $st
              | {agent:$agent, symbol:$symbol, status:$st, as_of:(.as_of // null),
                 generated_at:.generated_at, age_hours:(($age * 100 | round) / 100),
                 available:.available, synthetic:(.synthetic == true),
                 score:(if $st == "OK" then .score else null end),
                 direction:(.direction // null), confidence:(.confidence // null),
                 veto:(.veto // null), features:(.features // null),
                 reason:(if $st == "STALE" then "older than \($ttl) h" else (.reason // null) end)}
            end
        end' "$file" 2>/dev/null)
    if [[ -z "$out" ]]; then
        _agent_result "$agent" "$sym" "INVALID" "unparsable JSON"
        return 0
    fi
    echo "$out"
}

# ----------------------------------------------------------------------------
# agent_gate_get SIGNAL_ID
# Description: Read a validation gate gates/<SIGNAL_ID>.json
# Returns: JSON {signal_id, status, age_days, passed}; passed is true only
#   for PASSED
# Example: agent_gate_get quant_rank
# ----------------------------------------------------------------------------
agent_gate_get() {
    local sig="$1"
    local max_days="${AGENT_GATE_MAX_AGE_DAYS:-45}"
    [[ "$max_days" =~ ^[0-9]+(\.[0-9]+)?$ ]] || max_days=45
    if [[ ! "$sig" =~ ^[a-z0-9_]{1,64}$ ]]; then
        jq -cn --arg s "$sig" '{signal_id:$s, status:"INVALID", age_days:null, passed:false}'
        return 0
    fi
    local file
    file="$(agent_cache_dir)/gates/${sig}.json"
    if [[ ! -f "$file" ]]; then
        jq -cn --arg s "$sig" '{signal_id:$s, status:"MISSING", age_days:null, passed:false}'
        return 0
    fi
    local out
    out=$(jq -c --arg s "$sig" --argjson max_days "$max_days" '
        def res(st; age): {signal_id:$s, status:st, age_days:age, passed:(st == "PASSED")};
        if type != "object" then res("INVALID"; null)
        elif .signal_id != $s then res("INVALID"; null)
        elif (.passed | type) != "boolean" then res("INVALID"; null)
        else
          (try (.generated_at | fromdateiso8601) catch null) as $t
          | if $t == null then res("INVALID"; null)
            elif ($t - now) > 300 then res("INVALID"; null)
            else
              ((((now - $t) / 86400) | if . < 0 then 0 else . end) * 100 | round / 100) as $age
              | if .synthetic == true then res("SYNTHETIC"; $age)
                elif $age > $max_days then res("EXPIRED"; $age)
                elif .passed != true then res("FAILED"; $age)
                else res("PASSED"; $age) end
            end
        end' "$file" 2>/dev/null)
    if [[ -z "$out" ]]; then
        jq -cn --arg s "$sig" '{signal_id:$s, status:"INVALID", age_days:null, passed:false}'
        return 0
    fi
    echo "$out"
}

# ----------------------------------------------------------------------------
# agent_effective_weight AGENT
# Description: AGENT_<X>_WEIGHT of an additive agent clamped to [0, 0.30];
#   0 when unset, non-numeric or not an additive agent
# ----------------------------------------------------------------------------
agent_effective_weight() {
    local var w
    var=$(_agent_weight_var "$1") || { echo "0"; return 0; }
    w="${!var:-0}"
    if [[ ! "$w" =~ ^[0-9]+(\.[0-9]+)?$ && ! "$w" =~ ^\.[0-9]+$ ]]; then
        echo "0"
        return 0
    fi
    awk -v w="$w" 'BEGIN { if (w > 0.30) w = 0.30; if (w < 0) w = 0; printf "%g\n", w }'
}

# ----------------------------------------------------------------------------
# agent_max_total_weight
# Description: AGENT_MAX_TOTAL_WEIGHT (default 0.30) clamped to [0, 0.5];
#   non-numeric -> 0.30
# ----------------------------------------------------------------------------
agent_max_total_weight() {
    local w="${AGENT_MAX_TOTAL_WEIGHT:-0.30}"
    if [[ ! "$w" =~ ^[0-9]+(\.[0-9]+)?$ && ! "$w" =~ ^\.[0-9]+$ ]]; then
        w=0.30
    fi
    awk -v w="$w" 'BEGIN { if (w > 0.5) w = 0.5; if (w < 0) w = 0; printf "%g\n", w }'
}

# ----------------------------------------------------------------------------
# agent_components_json SYMBOL
# Description: Per-agent contributions for calculate_confluence_score_v2.
#   reason per agent: applied | disabled | missing | invalid | stale |
#   unavailable | synthetic (synthetic cache outside SST_OFFLINE=1) |
#   no_gate | gate_failed | gate_expired | gate_synthetic | shadow (eligible,
#   weight 0). Checked in that order; only "applied" carries weight.
# Returns: JSON {applied_weight, weighted_sum, max_total_weight,
#   agents:{quant|fundamental|market:{status, score, weight,
#   configured_weight, applied, reason, signal_id, gate_status}}}
# Example: AGENTS_ENABLED=true AGENT_QUANT_WEIGHT=0.1 agent_components_json AAPL
# ----------------------------------------------------------------------------
agent_components_json() {
    local symbol="$1" a got gate w sig items="[]"
    # Additive agents in output order
    for a in quant fundamental market; do
        got=$(agent_get "$a" "$symbol")
        sig=$(_agent_signal_for "$a")
        gate=$(agent_gate_get "$sig")
        w=$(agent_effective_weight "$a")
        items=$(jq -c --arg a "$a" --argjson got "$got" --argjson gate "$gate" --argjson w "$w" \
            --arg offline "${SST_OFFLINE:-0}" '
            ($got.status) as $st
            | (if $st == "DISABLED" then "disabled"
               elif $st == "MISSING" then "missing"
               elif $st == "INVALID" then "invalid"
               elif $st == "STALE" then "stale"
               elif $st == "UNAVAILABLE" then "unavailable"
               elif $st != "OK" then "invalid"
               elif ($got.synthetic == true and $offline != "1") then "synthetic"
               elif ($gate.status == "MISSING" or $gate.status == "INVALID") then "no_gate"
               elif $gate.status == "FAILED" then "gate_failed"
               elif $gate.status == "EXPIRED" then "gate_expired"
               elif $gate.status == "SYNTHETIC" then "gate_synthetic"
               elif $w <= 0 then "shadow"
               elif ($got.score | type) != "number" then "unavailable"
               else "applied" end) as $reason
            | . + [{agent:$a, status:$st, score:$got.score, configured_weight:$w,
                    applied:($reason == "applied"), reason:$reason,
                    signal_id:$gate.signal_id, gate_status:$gate.status}]' <<< "$items")
    done
    jq -c --argjson max "$(agent_max_total_weight)" '
        ([.[] | select(.applied) | .configured_weight] | add // 0) as $raw
        | (if $raw > $max and $raw > 0 then $max / $raw else 1 end) as $k
        | map(. + {weight:(if .applied then .configured_weight * $k else 0 end)}) as $rows
        | {applied_weight:([$rows[] | .weight] | add // 0),
           weighted_sum:([$rows[] | select(.applied) | .score * .weight] | add // 0),
           max_total_weight:$max,
           agents:(reduce $rows[] as $r ({}; . + {($r.agent): ($r | del(.agent))}))}' <<< "$items"
}

export -f agent_cache_dir _agent_valid_name _agent_norm_symbol _agent_signal_for _agent_weight_var
export -f agent_cache_file _agent_result agent_get agent_gate_get agent_effective_weight
export -f agent_max_total_weight agent_components_json
