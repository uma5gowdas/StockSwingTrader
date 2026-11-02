#!/bin/bash
# ============================================================================
# StockSwingTrader: Fractional Kelly Position Sizing + Daily Risk Budget
# ============================================================================
# Ported from v6.2 Phase 1 (phase1/lib/kelly_criterion.sh and
# phase1/lib/risk_budgeting.sh), rewritten for bash 3.2 (macOS) with awk math.
#
# Differences from Phase 1, all of which make sizing MORE conservative:
#   - Fraction is f*/KELLY_CRITERION_DIVISOR (quarter Kelly by default, divisor
#     floored at 2), not Phase 1's 0.85 x full Kelly.
#   - Regime multipliers are never above 1.0 (Phase 1 CALM_RANGE 1.2 dropped).
#   - A position below MIN_POSITION_SIZE_DOLLARS becomes 0 (skip), instead of
#     being raised up to the minimum.
#   - Negative or zero edge gives 0 size.
#   - Daily risk is qty x (entry - stop), not position dollars. The budget pct
#     is min(DAILY_RISK_BUDGET_PCT, daily loss limit of DEFAULT_RISK_LEVEL).
#   - flock (absent on macOS) is replaced by an atomic mkdir lock; the EOD cron
#     reset is replaced by a date-keyed ledger file.
#
# Hard caps that are never exceeded: MAX_POSITION_SIZE ($),
# KELLY_MAX_POSITION_PCT (% of equity), ALPACA_MAX_POSITION_SIZE (shares, if
# set), the daily risk budget and the daily drawdown (loss) limit.
#
# This file does not source trading_thresholds.sh: every input has a
# ${VAR:-default} fallback so it also works from DEPLOYMENT_PACKAGE/.
# ============================================================================
KELLY_SIZING_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${KELLY_SIZING_LIB_DIR}/portable.sh"

# ----------------------------------------------------------------------------
# Internal helpers
# ----------------------------------------------------------------------------

# _kelly_is_number VALUE -> rc 0 if VALUE is a plain decimal number
_kelly_is_number() {
    [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]
}

# _kelly_warn MESSAGE -> uses the agent's log_warn when available, else stderr
_kelly_warn() {
    if declare -f log_warn >/dev/null 2>&1; then
        log_warn "$*" >&2
    else
        echo "[WARN] $*" >&2
    fi
}

# _kelly_loss_limit_pct -> daily loss limit pct for DEFAULT_RISK_LEVEL
_kelly_loss_limit_pct() {
    case "${DEFAULT_RISK_LEVEL:-moderate}" in
        conservative) echo "${DAILY_LOSS_LIMIT_CONSERVATIVE_PCT:-2}" ;;
        aggressive)   echo "${DAILY_LOSS_LIMIT_AGGRESSIVE_PCT:-10}" ;;
        *)            echo "${DAILY_LOSS_LIMIT_MODERATE_PCT:-5}" ;;
    esac
}

# _kelly_ledger_file -> today's ledger path
_kelly_ledger_file() {
    echo "${RISK_BUDGET_DIR:-${HOME}/.stockswingtrader/risk_budget}/ledger_$(date +%Y-%m-%d).txt"
}

# ----------------------------------------------------------------------------
# kelly_fraction WIN_RATE RISK_REWARD
# Description: Raw Kelly fraction f* = (b*p - (1-p)) / b. May be negative.
# Args: WIN_RATE (0..1), RISK_REWARD (b > 0)
# Returns: f* with 6 decimals on stdout; rc 1 and no output on invalid input
# Example: kelly_fraction 0.55 1.5   # -> 0.250000
# ----------------------------------------------------------------------------
kelly_fraction() {
    local p="$1" b="$2"
    _kelly_is_number "$p" && _kelly_is_number "$b" || return 1
    awk -v p="$p" -v b="$b" 'BEGIN { exit !(p >= 0 && p <= 1 && b > 0) }' || return 1
    awk -v p="$p" -v b="$b" 'BEGIN { printf "%.6f\n", (b * p - (1 - p)) / b }'
}

# ----------------------------------------------------------------------------
# kelly_regime_multiplier REGIME
# Description: Size multiplier for a v6.3 regime name. Never above 1.0.
# Args: REGIME (sideways|trending_bull|trending_bear|volatile|...)
# Returns: multiplier on stdout
# Example: kelly_regime_multiplier volatile   # -> 0.5
# ----------------------------------------------------------------------------
kelly_regime_multiplier() {
    case "$1" in
        volatile) echo "0.5" ;;
        *)        echo "1.0" ;;
    esac
}

# ----------------------------------------------------------------------------
# kelly_confidence_multiplier CONFIDENCE
# Description: Phase 1 confidence multiplier 0.2 + 0.7*c, clamped to [0.6, 0.9]
# Args: CONFIDENCE (0..100); non-numeric is treated as 50
# Returns: multiplier with 4 decimals on stdout
# Example: kelly_confidence_multiplier 60   # -> 0.6200
# ----------------------------------------------------------------------------
kelly_confidence_multiplier() {
    local conf="$1"
    _kelly_is_number "$conf" || conf=50
    awk -v c="$conf" 'BEGIN {
        m = 0.2 + 0.7 * (c / 100)
        if (m < 0.6) m = 0.6
        if (m > 0.9) m = 0.9
        printf "%.4f\n", m
    }'
}

# ----------------------------------------------------------------------------
# risk_budget_daily_limit EQUITY
# Description: Daily risk budget in dollars:
#   EQUITY x min(DAILY_RISK_BUDGET_PCT, loss limit pct of DEFAULT_RISK_LEVEL)
# Returns: dollars with 2 decimals; rc 1 on invalid equity
# Example: risk_budget_daily_limit 10000   # -> 200.00
# ----------------------------------------------------------------------------
risk_budget_daily_limit() {
    local equity="$1"
    _kelly_is_number "$equity" || return 1
    local budget_pct="${DAILY_RISK_BUDGET_PCT:-2}"
    _kelly_is_number "$budget_pct" || budget_pct=2
    awk -v e="$equity" -v b="$budget_pct" -v l="$(_kelly_loss_limit_pct)" 'BEGIN {
        pct = (b < l) ? b : l
        if (pct < 0) pct = 0
        v = e * pct / 100
        if (v < 0) v = 0
        printf "%.2f\n", v
    }'
}

# ----------------------------------------------------------------------------
# risk_budget_used
# Description: Risk dollars already allocated today (sum of ledger column 2)
# Returns: dollars with 2 decimals (0.00 when no ledger exists)
# ----------------------------------------------------------------------------
risk_budget_used() {
    local ledger
    ledger="$(_kelly_ledger_file)"
    if [[ ! -f "$ledger" ]]; then
        echo "0.00"
        return 0
    fi
    awk '{ s += $2 } END { printf "%.2f\n", s + 0 }' "$ledger"
}

# ----------------------------------------------------------------------------
# risk_budget_remaining EQUITY
# Description: Daily limit minus used, floored at 0
# Returns: dollars with 2 decimals
# Example: risk_budget_remaining 10000   # -> 200.00 on a fresh day
# ----------------------------------------------------------------------------
risk_budget_remaining() {
    local limit used
    limit=$(risk_budget_daily_limit "$1") || return 1
    used=$(risk_budget_used)
    awk -v l="$limit" -v u="$used" 'BEGIN { r = l - u; if (r < 0) r = 0; printf "%.2f\n", r }'
}

# ----------------------------------------------------------------------------
# risk_budget_allocate TRADE_ID RISK_DOLLARS EQUITY
# Description: Atomically reserve RISK_DOLLARS of today's budget.
#   Uses an mkdir lock (50 x 0.1s retries; a lock older than 30s is removed
#   once as stale). Lock timeout is treated as a rejection (conservative).
# Returns: rc 0 if reserved, rc 1 if rejected (over budget, bad input, lock)
# Example: risk_budget_allocate MR_AAPL_1 15.00 10000
# ----------------------------------------------------------------------------
risk_budget_allocate() {
    local trade_id="$1" risk="$2" equity="$3"
    [[ -n "$trade_id" ]] || return 1
    _kelly_is_number "$risk" && _kelly_is_number "$equity" || return 1
    awk -v r="$risk" 'BEGIN { exit !(r >= 0) }' || return 1

    local dir="${RISK_BUDGET_DIR:-${HOME}/.stockswingtrader/risk_budget}"
    mkdir -p "$dir" 2>/dev/null || return 1
    local lock="$dir/.lock"
    local tries=0 stale_checked=0
    while ! mkdir "$lock" 2>/dev/null; do
        if [[ $stale_checked -eq 0 && -d "$lock" ]]; then
            local mtime age
            mtime=$(sst_file_mtime "$lock")
            age=$(( $(date +%s) - mtime ))
            if (( age > 30 )); then
                stale_checked=1
                rmdir "$lock" 2>/dev/null
                continue
            fi
        fi
        tries=$((tries + 1))
        if (( tries >= 50 )); then
            _kelly_warn "risk_budget_allocate: lock timeout for $trade_id"
            return 1
        fi
        sleep 0.1
    done

    local limit used rc=1
    limit=$(risk_budget_daily_limit "$equity")
    used=$(risk_budget_used)
    if awk -v u="$used" -v r="$risk" -v l="$limit" 'BEGIN { exit !(u + r <= l + 0.000001) }'; then
        printf '%s %.2f\n' "$trade_id" "$risk" >> "$(_kelly_ledger_file)" && rc=0
    fi
    rmdir "$lock" 2>/dev/null
    return $rc
}

# ----------------------------------------------------------------------------
# risk_budget_reset
# Description: Remove today's ledger (budget resets daily on its own)
# ----------------------------------------------------------------------------
risk_budget_reset() {
    rm -f "$(_kelly_ledger_file)"
}

# ----------------------------------------------------------------------------
# kelly_position_plan EQUITY ENTRY STOP [CONF=60] [REGIME=unknown]
#                     [WIN_RATE] [RISK_REWARD] [DAY_START_EQUITY]
# Description: Pure sizing plan (never allocates budget). Steps:
#   1. invalid input -> INVALID_INPUT (rc 1)
#   2. drawdown since DAY_START_EQUITY >= loss limit -> DRAWDOWN_LIMIT
#   3. f* <= 0 -> NO_EDGE
#   4. f = f*/max(divisor,2) x regime_mult x conf_mult
#   5. pos = min(equity*f, equity*KELLY_MAX_POSITION_PCT/100, MAX_POSITION_SIZE)
#   6. qty = floor(pos/entry), capped by ALPACA_MAX_POSITION_SIZE
#   7. qty*(entry-stop) capped by today's remaining risk budget
#   8. qty*entry < MIN_POSITION_SIZE_DOLLARS -> BELOW_MIN (qty 0)
# Returns: one JSON object on stdout
# Example: kelly_position_plan 10000 100 95 60 sideways
# ----------------------------------------------------------------------------
kelly_position_plan() {
    local equity="$1" entry="$2" stop="$3"
    local conf="${4:-60}" regime="${5:-unknown}"
    local p="${6:-${KELLY_WIN_RATE:-0.55}}" b="${7:-${KELLY_WIN_LOSS_RATIO:-1.5}}"
    local day_start="${8:-}"

    local divisor="${KELLY_CRITERION_DIVISOR:-4}"
    _kelly_is_number "$divisor" || divisor=4
    local max_pct="${KELLY_MAX_POSITION_PCT:-10}"
    _kelly_is_number "$max_pct" || max_pct=10
    local max_dollars="${MAX_POSITION_SIZE:-2500}"
    _kelly_is_number "$max_dollars" || max_dollars=2500
    local min_dollars="${MIN_POSITION_SIZE_DOLLARS:-100}"
    _kelly_is_number "$min_dollars" || min_dollars=100
    local shares_cap="${ALPACA_MAX_POSITION_SIZE:-}"
    _kelly_is_number "$shares_cap" || shares_cap=""
    _kelly_is_number "$conf" || conf=60

    local status="OK" rc=0 f_raw="null"
    if ! _kelly_is_number "$equity" || ! _kelly_is_number "$entry" || ! _kelly_is_number "$stop" \
        || ! awk -v e="$equity" -v n="$entry" -v s="$stop" 'BEGIN { exit !(e > 0 && n > 0 && s < n && s >= 0) }' \
        || ! f_raw=$(kelly_fraction "$p" "$b"); then
        status="INVALID_INPUT"; rc=1; f_raw="null"
    fi
    if [[ -n "$day_start" ]] && ! _kelly_is_number "$day_start"; then
        status="INVALID_INPUT"; rc=1
    fi

    local regime_mult conf_mult remaining="0" loss_limit
    regime_mult=$(kelly_regime_multiplier "$regime")
    conf_mult=$(kelly_confidence_multiplier "$conf")
    loss_limit=$(_kelly_loss_limit_pct)
    if [[ "$status" == "OK" ]]; then
        remaining=$(risk_budget_remaining "$equity")
    fi

    # All arithmetic in one awk pass; prints space-separated fields.
    local calc
    calc=$(awk -v st="$status" -v e="$equity" -v n="$entry" -v s="$stop" \
        -v fr="$f_raw" -v d="$divisor" -v rm="$regime_mult" -v cm="$conf_mult" \
        -v mp="$max_pct" -v md="$max_dollars" -v mn="$min_dollars" -v sc="$shares_cap" \
        -v rem="$remaining" -v ds="$day_start" -v ll="$loss_limit" 'BEGIN {
        f = 0; pos = 0; qty = 0; rps = 0; risk = 0; bind = "none"
        pct_cap = (st == "OK") ? e * mp / 100 : 0
        if (st == "OK") {
            rps = n - s
            if (ds != "" && ds > 0 && (ds - e) / ds * 100 >= ll) st = "DRAWDOWN_LIMIT"
            else if (fr <= 0) st = "NO_EDGE"
        }
        if (st == "OK") {
            if (d < 2) d = 2
            f = fr / d * rm * cm
            pos = e * f; bind = "kelly"
            if (pct_cap < pos) { pos = pct_cap; bind = "max_position_pct" }
            if (md < pos)      { pos = md;      bind = "max_position_size" }
            qty = int(pos / n)
            if (sc != "" && qty > sc + 0) { qty = int(sc); bind = "shares_cap" }
            if (rem <= 0) { st = "BUDGET_EXHAUSTED"; qty = 0 }
            else if (qty * rps > rem + 0.000001) { qty = int(rem / rps); bind = "daily_risk_budget" }
            if (st == "OK" && qty * n < mn) { st = "BELOW_MIN"; qty = 0 }
            risk = qty * rps
        }
        printf "%s %.6f %.2f %d %.2f %.2f %s %.2f\n", st, f, pos, qty, rps, risk, bind, pct_cap
    }')

    local c_status c_f c_pos c_qty c_rps c_risk c_bind c_pct
    read -r c_status c_f c_pos c_qty c_rps c_risk c_bind c_pct <<< "$calc"

    local shares_json="null"
    [[ -n "$shares_cap" ]] && shares_json="$shares_cap"
    local p_json="null" b_json="null"
    _kelly_is_number "$p" && p_json="$p"
    _kelly_is_number "$b" && b_json="$b"

    jq -cn --arg status "$c_status" --argjson kelly_raw "$f_raw" \
        --argjson kelly_fraction "$c_f" --argjson regime_multiplier "$regime_mult" \
        --argjson confidence_multiplier "$conf_mult" --argjson position_dollars "$c_pos" \
        --argjson qty "$c_qty" --argjson risk_per_share "$c_rps" --argjson risk_dollars "$c_risk" \
        --arg binding_cap "$c_bind" --argjson max_position_dollars "$max_dollars" \
        --argjson max_position_pct_dollars "$c_pct" --argjson shares_cap "$shares_json" \
        --argjson daily_budget_remaining "$remaining" --argjson win_rate "$p_json" \
        --argjson risk_reward "$b_json" --arg regime "$regime" '{
            status: $status, kelly_raw: $kelly_raw, kelly_fraction: $kelly_fraction,
            regime: $regime, regime_multiplier: $regime_multiplier,
            confidence_multiplier: $confidence_multiplier,
            position_dollars: $position_dollars, qty: $qty,
            risk_per_share: $risk_per_share, risk_dollars: $risk_dollars,
            binding_cap: $binding_cap,
            caps: { max_position_dollars: $max_position_dollars,
                    max_position_pct_dollars: $max_position_pct_dollars,
                    shares_cap: $shares_cap,
                    daily_budget_remaining: $daily_budget_remaining },
            win_rate: $win_rate, risk_reward: $risk_reward }'
    return $rc
}

# ----------------------------------------------------------------------------
# kelly_cap_qty QTY ENTRY STOP EQUITY [CONF] [REGIME]
# Description: Cap an existing quantity by the Kelly plan. Only ever reduces.
#   No-op (echoes QTY) unless KELLY_SIZING_ENABLED=true.
# Returns: capped quantity on stdout (0 when the plan says skip)
# Example: KELLY_SIZING_ENABLED=true kelly_cap_qty 50 100 95 10000   # -> 3
# ----------------------------------------------------------------------------
kelly_cap_qty() {
    local qty="$1" entry="$2" stop="$3" equity="$4" conf="${5:-60}" regime="${6:-unknown}"
    if [[ "${KELLY_SIZING_ENABLED:-false}" != "true" ]]; then
        echo "$qty"
        return 0
    fi
    [[ "$qty" =~ ^[0-9]+$ ]] || { echo 0; return 0; }
    local plan plan_qty
    plan=$(kelly_position_plan "$equity" "$entry" "$stop" "$conf" "$regime")
    plan_qty=$(echo "$plan" | jq -r '.qty // 0' 2>/dev/null)
    [[ "$plan_qty" =~ ^[0-9]+$ ]] || plan_qty=0
    if (( plan_qty < qty )); then
        echo "$plan_qty"
    else
        echo "$qty"
    fi
}

export -f _kelly_is_number _kelly_warn _kelly_loss_limit_pct _kelly_ledger_file
export -f kelly_fraction kelly_regime_multiplier kelly_confidence_multiplier
export -f risk_budget_daily_limit risk_budget_used risk_budget_remaining
export -f risk_budget_allocate risk_budget_reset kelly_position_plan kelly_cap_qty
