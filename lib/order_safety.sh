#!/bin/bash
# ============================================================================
# StockSwingTrader: Pre-trade order safety (live-readiness Step 1)
# ============================================================================
# Used by the agent's --buy/--sell flow (place_guarded_order) and the local
# commands --halt/--resume/--safety-status and --reconcile/--reconcile-accept.
#
#   Kill switch      kill_switch_file/active/engage/release
#   Endpoint mode    broker_endpoint_mode (paper | local | live),
#                    config_file_is_tracked (live + tracked config = refused)
#   Order ledger     order_ledger_file/append/update, generate_client_order_id,
#                    order_lock_acquire/release
#   Caps             check_order_qty_cap, check_order_caps (MAX_ORDER_QTY,
#                    MAX_ORDER_NOTIONAL, MAX_DAILY_NOTIONAL, MAX_OPEN_POSITIONS,
#                    no shorting)
#   Daily loss halt  check_daily_loss_halt (enforce_daily_drawdown_limit)
#   Duplicates       check_duplicate_order (ledger + broker open orders)
#   Reconciliation   reconcile_compute (pure), reconcile_with_broker,
#                    reconcile_accept (baseline + ledger, Alpaca only)
#   Market hours     check_market_hours (OUTSIDE_HOURS_POLICY refuse|queue)
#   PDT              check_pdt_warning (warning only)
#   Prices           compute_limit_price, order_bracket_levels_from (pure),
#                    order_bracket_levels (ATR/regime from real bars only)
#   Status           safety_status_report
#
# Every block returns 1 with a one-line reason on stdout and sends an alert
# (lib/alerts.sh). State lives in SST_STATE_DIR (default <project>/.state,
# gitignored). The trading day is TZ=America/New_York date +%F.
#
# Sourced library: no errexit, does not change SCRIPT_DIR/LIB_DIR/AGENT_DIR.
# ============================================================================

ORDER_SAFETY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$ORDER_SAFETY_LIB_DIR/alerts.sh" 2>/dev/null
if ! declare -F enforce_daily_drawdown_limit >/dev/null 2>&1; then
    source "$ORDER_SAFETY_LIB_DIR/risk_management.sh" >/dev/null 2>&1
fi

# Statuses that count as a live agent order (duplicates, daily notional)
ORDER_SAFETY_ACTIVE_STATUSES='["submitted","accepted","filled","unknown"]'
# Alpaca statuses of an order that is still working
ORDER_SAFETY_OPEN_STATUSES='["new","accepted","pending_new","partially_filled","held","accepted_for_bidding","pending_cancel","pending_replace","calculated","done_for_day"]'

# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------

# _os_num VALUE DEFAULT -> VALUE when it is a non-negative number, else DEFAULT
_os_num() {
    if [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then echo "$1"; else echo "$2"; fi
}

# _os_gt A B -> rc 0 when A > B (decimal)
_os_gt() {
    LC_ALL=C awk -v a="$1" -v b="$2" 'BEGIN { exit !((a + 0) > (b + 0)) }'
}

# _os_trading_day -> YYYY-MM-DD in America/New_York
_os_trading_day() {
    TZ=America/New_York date +%F
}

# _os_round PRICE -> Alpaca rounding (>= $1: 2 dp, < $1: 4 dp)
_os_round() {
    if declare -F alpaca_round_price >/dev/null 2>&1; then
        alpaca_round_price "$1"
    else
        LC_ALL=C awk -v p="$1" 'BEGIN { if (p + 0 <= 0) exit 1; if (p + 0 >= 1) printf "%.2f\n", p; else printf "%.4f\n", p }'
    fi
}

# _os_positions_map POSITIONS_JSON -> {"SYM": qty, ...} (array or object
# stream; quantity or qty; zero quantities dropped)
_os_positions_map() {
    local positions="${1:-[]}"
    echo "$positions" | jq -c -s '
        [.[] | if type == "array" then .[] else . end | select(type == "object")]
        | map({key: (.symbol // ""), value: ((.quantity // .qty // 0) | tonumber)})
        | map(select(.key != "" and .value != 0))
        | from_entries' 2>/dev/null || echo '{}'
}

# ----------------------------------------------------------------------------
# State directory and kill switch
# ----------------------------------------------------------------------------

# State directory (SST_STATE_DIR or <project>/.state), created, absolute
# Returns: path on stdout
sst_state_dir() {
    local dir="${SST_STATE_DIR:-}"
    [[ -n "$dir" ]] || dir="$ORDER_SAFETY_LIB_DIR/../.state"
    mkdir -p "$dir" 2>/dev/null
    (cd "$dir" 2>/dev/null && pwd) || echo "$dir"
}

# Kill switch file path (KILL_SWITCH_FILE or <state>/KILL_SWITCH)
kill_switch_file() {
    if [[ -n "${KILL_SWITCH_FILE:-}" ]]; then
        echo "$KILL_SWITCH_FILE"
    else
        echo "$(sst_state_dir)/KILL_SWITCH"
    fi
}

# Is the kill switch engaged?
# Returns: 0 + the switch JSON {ts, reason, by} when active; 1 when not
kill_switch_active() {
    local file
    file=$(kill_switch_file)
    [[ -f "$file" ]] || return 1
    if jq -e . "$file" >/dev/null 2>&1; then
        jq -c . "$file"
    else
        jq -cn --arg r "$(head -c 200 "$file" 2>/dev/null)" '{ts: null, reason: $r, by: null}'
    fi
    return 0
}

# Engage the kill switch: no new orders until kill_switch_release
# Args: [REASON]
# Returns: 0; prints the switch JSON
kill_switch_engage() {
    local reason="${1:-manual halt}" file
    file=$(kill_switch_file)
    mkdir -p "$(dirname "$file")" 2>/dev/null
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg reason "$reason" --arg by "${USER:-unknown}" \
        '{ts: $ts, reason: $reason, by: $by}' > "$file" || return 1
    send_alert critical halt "Kill switch engaged: $reason. No new orders until --resume." "$(cat "$file")"
    cat "$file"
    return 0
}

# Release the kill switch
# Returns: 0 (also when it was not engaged)
kill_switch_release() {
    local file previous
    file=$(kill_switch_file)
    if [[ ! -f "$file" ]]; then
        echo '{"kill_switch":"off","changed":false}'
        return 0
    fi
    previous=$(kill_switch_active)
    rm -f "$file" || return 1
    send_alert info resume "Kill switch released; orders allowed again" "${previous:-}"
    echo '{"kill_switch":"off","changed":true}'
    return 0
}

# ----------------------------------------------------------------------------
# Endpoint mode and config guard
# ----------------------------------------------------------------------------

# Classify the trading endpoint
# Args: BROKER URL
# Returns: "paper" (host paper-api.alpaca.markets or empty URL = Alpaca's paper
#          default), "local" (127.0.0.1 / localhost / [::1], unless
#          SST_LOOPBACK_IS_LIVE=1, a test knob that only makes things stricter),
#          "live" (anything else; robinhood is always live)
broker_endpoint_mode() {
    local broker="${1:-alpaca}" url="${2:-}" host
    if [[ "$broker" == "robinhood" ]]; then
        echo "live"
        return 0
    fi
    if [[ -z "$url" ]]; then
        echo "paper"
        return 0
    fi
    host="${url#*://}"
    host="${host%%/*}"
    host="${host##*@}"
    if [[ "$host" == \[* ]]; then
        host="${host%%]*}]"
    else
        host="${host%%:*}"
    fi
    host=$(echo "$host" | tr '[:upper:]' '[:lower:]')
    case "$host" in
        paper-api.alpaca.markets) echo "paper" ;;
        127.0.0.1|localhost|"[::1]")
            if [[ "${SST_LOOPBACK_IS_LIVE:-0}" == "1" ]]; then echo "live"; else echo "local"; fi
            ;;
        *) echo "live" ;;
    esac
}

# Display label for a mode: PAPER | LOCAL STUB | LIVE
endpoint_mode_label() {
    case "$1" in
        paper) echo "PAPER" ;;
        local) echo "LOCAL STUB" ;;
        *) echo "LIVE" ;;
    esac
}

# Is FILE tracked by git?
# Args: FILE
# Returns: 0 tracked, 1 not tracked / no git / no file
config_file_is_tracked() {
    local file="$1" dir base
    [[ -n "$file" && -f "$file" ]] || return 1
    command -v git >/dev/null 2>&1 || return 1
    dir=$(cd "$(dirname "$file")" 2>/dev/null && pwd) || return 1
    base=$(basename "$file")
    git -C "$dir" ls-files --error-unmatch "$base" >/dev/null 2>&1
}

# ----------------------------------------------------------------------------
# Order ledger, client order ids, lock
# ----------------------------------------------------------------------------

# Order ledger path (<state>/orders.jsonl)
order_ledger_file() {
    echo "$(sst_state_dir)/orders.jsonl"
}

# Append one order to the ledger
# Args: ORDER_JSON (ts_epoch, trading_day, client_order_id, broker, mode,
#       symbol, side, qty, type, limit_price, stop_price, take_profit_price,
#       notional, status, broker_order_id)
# Returns: 0 written, 1 invalid JSON
order_ledger_append() {
    local json="$1" line
    line=$(echo "$json" | jq -c 'select(type == "object")' 2>/dev/null)
    [[ -n "$line" ]] || return 1
    echo "$line" >> "$(order_ledger_file)"
}

# Update the status (and broker order id) of a ledger order
# Args: CLIENT_ORDER_ID STATUS [BROKER_ORDER_ID]
# Returns: 0 (1 when the ledger is missing)
order_ledger_update() {
    local cid="$1" status="$2" broker_id="${3:-}" file tmp
    file=$(order_ledger_file)
    [[ -f "$file" ]] || return 1
    tmp="${file}.tmp.$$"
    jq -c --arg cid "$cid" --arg st "$status" --arg bid "$broker_id" --argjson now "$(date +%s)" '
        if .client_order_id == $cid
        then .status = $st | .updated_epoch = $now
             | (if $bid != "" then .broker_order_id = $bid else . end)
        else . end' "$file" > "$tmp" 2>/dev/null && mv "$tmp" "$file"
}

# Ledger orders as one JSON array (empty array when there is no ledger)
order_ledger_entries() {
    local file
    file=$(order_ledger_file)
    if [[ -s "$file" ]]; then
        jq -c -s '.' "$file" 2>/dev/null || echo '[]'
    else
        echo '[]'
    fi
}

# Client order id for an agent order
# Args: SYMBOL SIDE
# Returns: sst-<SYM>-<b|s>-<YYYYmmddHHMMSS>-<4 hex> (prefix sst- marks agent orders)
generate_client_order_id() {
    local symbol="$1" side="$2" s hex
    [[ "$side" == "sell" ]] && s=s || s=b
    hex=$(od -An -N2 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    [[ "$hex" =~ ^[0-9a-f]{4}$ ]] || hex=$(printf '%04x' $((RANDOM % 65536)))
    echo "sst-${symbol}-${s}-$(date -u +%Y%m%d%H%M%S)-${hex}"
}

# Take the order lock (<state>/order.lock; a lock older than 120 s is stale)
# Returns: 0 locked, 1 still held by another run after ~10 s
order_lock_acquire() {
    local lock tries=0 mtime now
    lock="$(sst_state_dir)/order.lock"
    while ! mkdir "$lock" 2>/dev/null; do
        mtime=$(perl -e 'my @s = stat shift; print $s[9] // 0' "$lock" 2>/dev/null)
        now=$(date +%s)
        if [[ -n "$mtime" && $((now - ${mtime:-0})) -gt 120 ]]; then
            rm -rf "$lock"
            continue
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 50 ]]; then
            echo "Order lock busy: another order is being submitted ($lock)"
            return 1
        fi
        sleep 0.2
    done
    echo "$$ $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lock/owner" 2>/dev/null
    return 0
}

# Release the order lock
order_lock_release() {
    rm -rf "$(sst_state_dir)/order.lock"
    return 0
}

# ----------------------------------------------------------------------------
# Caps
# ----------------------------------------------------------------------------

# MAX_ORDER_QTY check (both sides; no broker needed)
# Args: QTY [SYMBOL] [SIDE]
# Returns: 0 ok; 1 + reason (alert cap_hit)
check_order_qty_cap() {
    local qty="$1" symbol="${2:-}" side="${3:-}" max
    max=$(_os_num "${MAX_ORDER_QTY:-100}" 100)
    if _os_gt "$qty" "$max"; then
        echo "Order blocked: quantity $qty exceeds MAX_ORDER_QTY $max"
        send_alert warn cap_hit "MAX_ORDER_QTY: $side $qty $symbol exceeds $max" \
            "$(jq -cn --arg s "$symbol" --arg side "$side" --arg q "$qty" --arg m "$max" '{cap:"MAX_ORDER_QTY", symbol:$s, side:$side, qty:($q|tonumber), limit:($m|tonumber)}')"
        return 1
    fi
    return 0
}

# Buy notional of today's agent orders in the ledger for this broker
# Args: [BROKER=${BROKER_CHOICE:-alpaca}]
# Returns: number on stdout
daily_buy_notional_used() {
    local broker="${1:-${BROKER_CHOICE:-alpaca}}"
    order_ledger_entries | jq -r --arg day "$(_os_trading_day)" --arg b "$broker" \
        --argjson st "$ORDER_SAFETY_ACTIVE_STATUSES" '
        [.[] | select(.trading_day == $day and .broker == $b and .side == "buy"
                      and (.status as $s | $st | index($s)))
             | (.notional // 0 | tonumber)] | add // 0' 2>/dev/null || echo 0
}

# Hard caps for one order
# Args: SIDE SYMBOL QTY PRICE POSITIONS_JSON
#   Buys: MAX_ORDER_QTY, MAX_ORDER_NOTIONAL (qty*price), MAX_DAILY_NOTIONAL
#   (today's ledger buys + this), MAX_OPEN_POSITIONS (only for a new symbol).
#   Sells: MAX_ORDER_QTY and qty <= held qty (no shorting); never blocked by
#   notional/position caps so exits stay possible.
# Returns: 0 + JSON {ok, notional, daily_notional_used, daily_notional_after,
#          open_positions, held_qty}; 1 + reason (alert cap_hit)
check_order_caps() {
    local side="$1" symbol="$2" qty="$3" price="$4" positions="${5:-[]}"
    local map held count notional used after max_notional max_daily max_pos details

    check_order_qty_cap "$qty" "$symbol" "$side" || return 1

    map=$(_os_positions_map "$positions")
    held=$(echo "$map" | jq -r --arg s "$symbol" '.[$s] // 0')
    count=$(echo "$map" | jq -r 'length')
    notional=$(LC_ALL=C awk -v q="$qty" -v p="$price" 'BEGIN { printf "%.2f", q * p }')
    used=$(daily_buy_notional_used)
    after=$(LC_ALL=C awk -v u="$used" -v n="$notional" 'BEGIN { printf "%.2f", u + n }')
    max_notional=$(_os_num "${MAX_ORDER_NOTIONAL:-2500}" 2500)
    max_daily=$(_os_num "${MAX_DAILY_NOTIONAL:-10000}" 10000)
    max_pos=$(_os_num "${MAX_OPEN_POSITIONS:-5}" 5)
    details=$(jq -cn --arg s "$symbol" --arg side "$side" --arg q "$qty" --arg p "$price" --arg n "$notional" \
        --arg u "$used" --arg c "$count" --arg h "$held" \
        '{symbol:$s, side:$side, qty:($q|tonumber), price:($p|tonumber), notional:($n|tonumber),
          daily_notional_used:($u|tonumber), open_positions:($c|tonumber), held_qty:($h|tonumber)}')

    if [[ "$side" == "sell" ]]; then
        if _os_gt "$qty" "$held"; then
            echo "Order blocked: sell $qty $symbol exceeds the held position ($held shares); short selling is not allowed"
            send_alert warn cap_hit "No short: sell $qty $symbol > held $held" "$details"
            return 1
        fi
    else
        if _os_gt "$notional" "$max_notional"; then
            echo "Order blocked: notional \$$notional exceeds MAX_ORDER_NOTIONAL \$$max_notional"
            send_alert warn cap_hit "MAX_ORDER_NOTIONAL: buy $qty $symbol = \$$notional > \$$max_notional" "$details"
            return 1
        fi
        if _os_gt "$after" "$max_daily"; then
            echo "Order blocked: today's buy notional would be \$$after (used \$$used + \$$notional), above MAX_DAILY_NOTIONAL \$$max_daily"
            send_alert warn cap_hit "MAX_DAILY_NOTIONAL: \$$after > \$$max_daily" "$details"
            return 1
        fi
        if _os_gt "$held" 0; then
            :
        elif [[ "$count" -ge "${max_pos%.*}" ]]; then
            echo "Order blocked: $count open positions, MAX_OPEN_POSITIONS is $max_pos ($symbol would be a new position)"
            send_alert warn cap_hit "MAX_OPEN_POSITIONS: $count held, $symbol would be new (max $max_pos)" "$details"
            return 1
        fi
    fi
    echo "$details" | jq -c --arg a "$after" '. + {ok: true, daily_notional_after: ($a|tonumber)}'
    return 0
}

# ----------------------------------------------------------------------------
# Daily loss halt
# ----------------------------------------------------------------------------

# Daily loss limit pct: DAILY_LOSS_LIMIT_PCT, else DEFAULT_RISK_LEVEL's limit
daily_loss_limit_pct() {
    if [[ "${DAILY_LOSS_LIMIT_PCT:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "$DAILY_LOSS_LIMIT_PCT"
    elif declare -F _kelly_loss_limit_pct >/dev/null 2>&1; then
        _kelly_loss_limit_pct
    else
        echo 5
    fi
}

# Block buys when equity fell more than the daily loss limit below the prior
# close equity (last_equity): covers realized + unrealized P&L
# Args: ACCOUNT_JSON [SIDE=buy]
# Returns: 0 ok / skipped (no last_equity) / sell allowed; 1 + reason (alert halt)
check_daily_loss_halt() {
    local account="$1" side="${2:-buy}" last equity limit result exceeded loss
    last=$(echo "$account" | jq -r '.last_equity // empty' 2>/dev/null)
    equity=$(echo "$account" | jq -r '.equity // .portfolio_value // empty' 2>/dev/null)
    if ! [[ "$last" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! _os_gt "$last" 0 || ! [[ "$equity" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        echo "NOTICE: daily loss check skipped (account has no last_equity)"
        return 0
    fi
    limit=$(daily_loss_limit_pct)
    result=$(enforce_daily_drawdown_limit "$last" "$equity" "$limit" 2>/dev/null)
    exceeded=$(echo "$result" | jq -r '.limit_exceeded // false' 2>/dev/null)
    loss=$(echo "$result" | jq -r '.current_loss_pct // 0' 2>/dev/null)
    loss=$(LC_ALL=C awk -v l="$loss" 'BEGIN { printf "%.2f", l }')
    if [[ "$exceeded" == "true" ]]; then
        if [[ "$side" == "sell" ]]; then
            echo "NOTICE: daily loss limit reached (${loss}% >= ${limit}%); exits are still allowed"
            return 0
        fi
        echo "DAILY LOSS HALT: equity is down ${loss}% from the prior close (limit ${limit}%). New buys are blocked today; sells are allowed."
        send_alert critical halt "Daily loss halt: down ${loss}% (limit ${limit}%), buys blocked" \
            "$(jq -cn --arg l "$loss" --arg m "$limit" '{current_loss_pct:($l|tonumber), daily_loss_limit:($m|tonumber)}')"
        return 1
    fi
    return 0
}

# ----------------------------------------------------------------------------
# Duplicate guard
# ----------------------------------------------------------------------------

# Refuse a second order for the same symbol + side: ledger orders (this
# broker, status submitted/accepted/filled/unknown) within
# DUPLICATE_ORDER_WINDOW_SECONDS, or a top-level open broker order. No override.
# Args: SYMBOL SIDE [OPEN_ORDERS_JSON=[]]
# Returns: 0 ok; 1 + reason (alert duplicate_blocked)
check_duplicate_order() {
    local symbol="$1" side="$2" open_orders="${3:-[]}" window since hit broker_hit
    window=$(_os_num "${DUPLICATE_ORDER_WINDOW_SECONDS:-300}" 300)
    since=$(( $(date +%s) - ${window%.*} ))
    hit=$(order_ledger_entries | jq -r --arg s "$symbol" --arg side "$side" --arg b "${BROKER_CHOICE:-alpaca}" \
        --argjson since "$since" --argjson st "$ORDER_SAFETY_ACTIVE_STATUSES" '
        [.[] | select(.symbol == $s and .side == $side and .broker == $b
                      and ((.ts_epoch // 0) >= $since) and (.status as $x | $st | index($x)))]
        | last | if . then "\(.client_order_id) (\(.status))" else "" end' 2>/dev/null)
    if [[ -n "$hit" ]]; then
        echo "Order blocked: duplicate $side $symbol; the agent placed $hit within the last ${window%.*} s"
        send_alert warn duplicate_blocked "Duplicate $side $symbol (ledger $hit)" \
            "$(jq -cn --arg s "$symbol" --arg side "$side" '{symbol:$s, side:$side, source:"ledger"}')"
        return 1
    fi
    broker_hit=$(echo "${open_orders:-[]}" | jq -r --arg s "$symbol" --arg side "$side" '
        [.[]? | select(.symbol == $s and .side == $side)] | first
        | if . then "\(.client_order_id // .id) (\(.status))" else "" end' 2>/dev/null)
    if [[ -n "$broker_hit" ]]; then
        echo "Order blocked: duplicate $side $symbol; the broker already has an open $side order $broker_hit"
        send_alert warn duplicate_blocked "Duplicate $side $symbol (open broker order)" \
            "$(jq -cn --arg s "$symbol" --arg side "$side" '{symbol:$s, side:$side, source:"broker_open_orders"}')"
        return 1
    fi
    return 0
}

# ----------------------------------------------------------------------------
# Reconciliation (Alpaca)
# ----------------------------------------------------------------------------

# Baseline file (<state>/positions_baseline.json)
reconcile_baseline_file() {
    echo "$(sst_state_dir)/positions_baseline.json"
}

# Compare broker positions with baseline + agent orders (pure)
# Args: POSITIONS_JSON ORDERS_SINCE_JSON BASELINE_JSON|"" [OPEN_ORDERS_JSON]
#   ORDERS_SINCE_JSON: orders created after baseline.taken_at (nested legs).
#   expected[sym] = baseline.positions[sym] + sum over orders whose
#   client_order_id starts with "sst-" of filled_qty * (buy +1 / sell -1),
#   plus their legs' filled_qty * side sign.
#   OPEN_ORDERS_JSON (default: open orders in ORDERS_SINCE_JSON): top-level
#   open orders without the sst- prefix (and not accepted in the baseline)
#   are unknown_open_orders.
# Returns: JSON {status: ok|mismatch|no_baseline, mismatches:[{symbol,
#          broker_qty, expected_qty}], unknown_open_orders:[...], expected,
#          broker, baseline_taken_at, auto_create}; rc 0 ok, 1 otherwise
reconcile_compute() {
    local positions="${1:-[]}" orders="${2:-[]}" baseline="${3:-}" open_orders="${4:-}"
    local broker_map result
    broker_map=$(_os_positions_map "$positions")
    [[ -n "$baseline" ]] && echo "$baseline" | jq -e 'type == "object"' >/dev/null 2>&1 || baseline="null"
    echo "$orders" | jq -e 'type == "array"' >/dev/null 2>&1 || orders='[]'
    if [[ -z "$open_orders" ]] || ! echo "$open_orders" | jq -e 'type == "array"' >/dev/null 2>&1; then
        open_orders=$(echo "$orders" | jq -c --argjson os "$ORDER_SAFETY_OPEN_STATUSES" \
            '[.[] | select(.status as $s | $os | index($s))]')
    fi
    result=$(jq -cn --argjson broker "$broker_map" --argjson orders "$orders" --argjson base "$baseline" \
        --argjson open "$open_orders" '
        def sgn: if . == "sell" then -1 else 1 end;
        def fq: ((.filled_qty // 0) | tonumber? // 0);
        ($base.accepted_open_order_ids // []) as $accepted
        | ([$open[] | select(((.client_order_id // "") | startswith("sst-")) | not)
                    | select(.id as $i | $accepted | index($i) | not)
                    | {id, symbol, side, qty, status, client_order_id}]) as $unknown
        | if $base == null then
            {status: (if ($broker | length) == 0 and ($unknown | length) == 0 and ($open | length) == 0
                      then "ok" else "no_baseline" end),
             mismatches: [], unknown_open_orders: $unknown, expected: {}, broker: $broker,
             baseline_taken_at: null,
             auto_create: (($broker | length) == 0 and ($open | length) == 0)}
          else
            ([$orders[] | select((.client_order_id // "") | startswith("sst-"))
               | ({symbol, d: ((fq) * (.side | sgn))}),
                 ((.legs // [])[] | {symbol, d: ((fq) * (.side | sgn))})]
             | reduce .[] as $o (($base.positions // {}); .[$o.symbol] = ((.[$o.symbol] // 0) + $o.d))
             | with_entries(select(.value != 0))) as $expected
            | ([(($expected | keys) + ($broker | keys)) | unique[]
                | {symbol: ., broker_qty: ($broker[.] // 0), expected_qty: ($expected[.] // 0)}
                | select(.broker_qty != .expected_qty)]) as $mm
            | {status: (if ($mm | length) == 0 and ($unknown | length) == 0 then "ok" else "mismatch" end),
               mismatches: $mm, unknown_open_orders: $unknown, expected: $expected, broker: $broker,
               baseline_taken_at: $base.taken_at, auto_create: false}
          end')
    [[ -n "$result" ]] || { echo '{"status":"error","error":"reconcile_compute failed"}'; return 1; }
    echo "$result"
    [[ "$(echo "$result" | jq -r .status)" == "ok" ]]
}

# Write the baseline from the broker's current positions (and open orders)
# Args: POSITIONS_JSON [OPEN_ORDERS_JSON]
# Returns: 0 + baseline JSON
_reconcile_write_baseline() {
    local positions="$1" open_orders="${2:-[]}" file map
    file=$(reconcile_baseline_file)
    map=$(_os_positions_map "$positions")
    echo "$open_orders" | jq -e 'type == "array"' >/dev/null 2>&1 || open_orders='[]'
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg b "${BROKER_CHOICE:-alpaca}" \
        --argjson p "$map" --argjson o "$open_orders" \
        '{taken_at: $ts, broker: $b, positions: $p,
          accepted_open_order_ids: [$o[] | select(((.client_order_id // "") | startswith("sst-")) | not) | .id]}' \
        > "$file" || return 1
    cat "$file"
}

# Reconcile the broker with the local baseline + order ledger (Alpaca)
# Fetches positions, open orders and the orders since the baseline, marks
# newly filled agent orders "filled" in the ledger (alert order_filled) and
# prints a report. No baseline and an empty account: baseline auto-created.
# Returns: 0 match (or robinhood: not available), 1 mismatch / no baseline
#          (alert reconcile_mismatch), 2 broker data unavailable
reconcile_with_broker() {
    local positions open_orders orders="[]" baseline="" file result status cid
    if [[ "${BROKER_CHOICE:-alpaca}" != "alpaca" ]]; then
        echo "NOTICE: reconciliation not available for ${BROKER_CHOICE}"
        return 0
    fi
    positions=$(alpaca_get_positions 2>/dev/null) && echo "$positions" | jq -e 'type == "array"' >/dev/null 2>&1 || {
        echo "RECONCILIATION: could not read broker positions"
        return 2
    }
    open_orders=$(alpaca_get_open_orders 2>/dev/null) || {
        echo "RECONCILIATION: could not read broker open orders"
        return 2
    }
    file=$(reconcile_baseline_file)
    if [[ -f "$file" ]] && jq -e '.taken_at' "$file" >/dev/null 2>&1; then
        baseline=$(jq -c . "$file")
        orders=$(alpaca_get_orders_since "$(echo "$baseline" | jq -r .taken_at)" 2>/dev/null) || {
            echo "RECONCILIATION: could not read broker orders"
            return 2
        }
    fi

    # Agent orders the broker reports filled: mark them in the ledger
    for cid in $(echo "$orders" | jq -r '.[] | select((.client_order_id // "") | startswith("sst-"))
                                          | select(.status == "filled") | .client_order_id'); do
        status=$(order_ledger_entries | jq -r --arg c "$cid" '[.[] | select(.client_order_id == $c)] | last | .status // empty')
        if [[ -n "$status" && "$status" != "filled" ]]; then
            order_ledger_update "$cid" filled
            send_alert info order_filled "Order filled: $cid" "$(jq -cn --arg c "$cid" '{client_order_id:$c}')"
        fi
    done

    result=$(reconcile_compute "$positions" "$orders" "$baseline" "$open_orders")
    status=$(echo "$result" | jq -r '.status')
    if [[ "$status" == "ok" ]]; then
        if [[ -z "$baseline" ]]; then
            _reconcile_write_baseline "$positions" "$open_orders" >/dev/null
            echo "RECONCILIATION (alpaca): OK - empty account, baseline created"
        else
            echo "RECONCILIATION (alpaca): OK - broker positions match the baseline ($(echo "$baseline" | jq -r .taken_at)) + agent orders"
        fi
        return 0
    fi
    if [[ "$status" == "no_baseline" ]]; then
        echo "RECONCILIATION (alpaca): NO BASELINE - the broker has positions or open orders and no baseline was accepted"
        echo "$result" | jq -r '.broker | to_entries[] | "  broker: \(.key) \(.value)"'
    else
        echo "RECONCILIATION (alpaca): MISMATCH"
        echo "$result" | jq -r '.mismatches[] | "  \(.symbol): broker \(.broker_qty), expected \(.expected_qty)"'
    fi
    echo "$result" | jq -r '.unknown_open_orders[] | "  unknown open order (not placed by this agent): \(.symbol) \(.side) \(.qty) \(.status)"'
    echo "  Review with --reconcile; adopt the broker state with --reconcile-accept"
    send_alert warn reconcile_mismatch "Reconciliation $status" \
        "$(echo "$result" | jq -c '{status, mismatches, unknown_open_orders: (.unknown_open_orders | map({symbol, side, qty}))}')"
    return 1
}

# Adopt the broker's current positions (and open orders) as the baseline
# Returns: 0 + summary; 1 when broker data is unavailable
reconcile_accept() {
    local positions open_orders baseline
    if [[ "${BROKER_CHOICE:-alpaca}" != "alpaca" ]]; then
        echo "NOTICE: reconciliation not available for ${BROKER_CHOICE}"
        return 0
    fi
    positions=$(alpaca_get_positions 2>/dev/null) && echo "$positions" | jq -e 'type == "array"' >/dev/null 2>&1 || {
        echo "RECONCILIATION: could not read broker positions"
        return 1
    }
    open_orders=$(alpaca_get_open_orders 2>/dev/null) || open_orders='[]'
    baseline=$(_reconcile_write_baseline "$positions" "$open_orders") || return 1
    send_alert info reconcile_accept "Reconciliation baseline accepted" \
        "$(echo "$baseline" | jq -c '{taken_at, positions}')"
    echo "RECONCILIATION BASELINE ACCEPTED ($(echo "$baseline" | jq -r .taken_at))"
    echo "$baseline" | jq -r '.positions | to_entries[] | "  \(.key): \(.value)"'
    echo "Baseline file: $(reconcile_baseline_file)"
    return 0
}

# ----------------------------------------------------------------------------
# Market hours and PDT
# ----------------------------------------------------------------------------

# Is the market open? (Alpaca clock; fail closed on error)
# Closed: OUTSIDE_HOURS_POLICY=refuse (default) blocks (alert outside_hours);
# queue allows with a notice (Alpaca holds the order until the next open).
# Returns: 0 open / queued / robinhood (skipped); 1 + reason
check_market_hours() {
    local clock is_open next_open today cal kind policy
    if [[ "${BROKER_CHOICE:-alpaca}" != "alpaca" ]]; then
        echo "NOTICE: market hours check not available for ${BROKER_CHOICE}"
        return 0
    fi
    if ! clock=$(alpaca_get_clock 2>/dev/null) || [[ -z "$clock" ]]; then
        echo "Order blocked: market clock unavailable (fail closed)"
        send_alert warn error "Market clock unavailable; order refused" ""
        return 1
    fi
    is_open=$(echo "$clock" | jq -r '.is_open')
    [[ "$is_open" == "true" ]] && return 0
    next_open=$(echo "$clock" | jq -r '.next_open // "unknown"')
    today=$(_os_trading_day)
    kind="the market is closed"
    if cal=$(alpaca_get_calendar "$today" "$today" 2>/dev/null); then
        if ! echo "$cal" | jq -e --arg d "$today" 'any(.[]; .date == $d)' >/dev/null 2>&1; then
            kind="market holiday: $today is not a trading day (holiday or weekend)"
        fi
    fi
    policy="${OUTSIDE_HOURS_POLICY:-refuse}"
    if [[ "$policy" == "queue" ]]; then
        echo "NOTICE: $kind; Alpaca will hold the order until the next open $next_open (OUTSIDE_HOURS_POLICY=queue)"
        return 0
    fi
    echo "Order blocked: $kind (next open $next_open). OUTSIDE_HOURS_POLICY=refuse"
    send_alert warn outside_hours "Order refused outside market hours ($kind)" \
        "$(jq -cn --arg n "$next_open" --arg k "$kind" '{next_open:$n, reason:$k}')"
    return 1
}

# Pattern day trader warning (never blocks)
# Args: SIDE SYMBOL ACCOUNT_JSON ORDERS_TODAY_JSON [BRACKET=false]
#   Warns when equity < PDT_EQUITY_THRESHOLD (25000) and the order can make a
#   day trade: a sell of a symbol bought today (ledger or broker orders), or a
#   bracket buy (its legs can fill today).
# Returns: 0; prints "PDT WARNING ..." (alert pdt_warning) when it applies
check_pdt_warning() {
    local side="$1" symbol="$2" account="$3" orders_today="${4:-[]}" bracket="${5:-false}"
    local equity threshold count bought reason=""
    equity=$(echo "$account" | jq -r '.equity // .portfolio_value // empty' 2>/dev/null)
    [[ "$equity" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 0
    threshold=$(_os_num "${PDT_EQUITY_THRESHOLD:-25000}" 25000)
    _os_gt "$threshold" "$equity" || return 0
    count=$(echo "$account" | jq -r '.daytrade_count // 0' 2>/dev/null)
    if [[ "$side" == "sell" ]]; then
        bought=$(order_ledger_entries | jq -r --arg s "$symbol" --arg d "$(_os_trading_day)" '
            any(.[]; .symbol == $s and .side == "buy" and .trading_day == $d
                     and (.status == "accepted" or .status == "filled" or .status == "submitted"))' 2>/dev/null)
        if [[ "$bought" != "true" ]]; then
            bought=$(echo "$orders_today" | jq -r --arg s "$symbol" '
                any(.[]?; .symbol == $s and .side == "buy"
                         and (.status != "canceled" and .status != "rejected" and .status != "expired"))' 2>/dev/null)
        fi
        [[ "$bought" == "true" ]] && reason="selling $symbol on the day it was bought is a day trade"
    elif [[ "$bracket" == "true" ]]; then
        reason="the bracket legs of this buy can fill today, which would be a day trade"
    fi
    [[ -n "$reason" ]] || return 0
    echo "PDT WARNING: equity \$$equity is below \$$threshold; $reason (daytrade_count $count; 4 day trades in 5 business days flags the account)"
    send_alert warn pdt_warning "PDT: $side $symbol, $reason" \
        "$(jq -cn --arg s "$symbol" --arg side "$side" --arg c "$count" '{symbol:$s, side:$side, daytrade_count:($c|tonumber? // 0)}')"
    return 0
}

# ----------------------------------------------------------------------------
# Prices
# ----------------------------------------------------------------------------

# Marketable limit price from a reference price
# Args: SIDE REF_PRICE [OFFSET_PCT=${LIMIT_OFFSET_PCT:-0.2}]
# Returns: buy ref*(1+o/100), sell ref*(1-o/100), rounded like Alpaca
compute_limit_price() {
    local side="$1" ref="$2" offset="${3:-${LIMIT_OFFSET_PCT:-0.2}}" raw
    offset=$(_os_num "$offset" 0.2)
    raw=$(LC_ALL=C awk -v s="$side" -v r="$ref" -v o="$offset" 'BEGIN {
        if (s == "sell") printf "%.6f", r * (1 - o / 100); else printf "%.6f", r * (1 + o / 100) }')
    _os_round "$raw"
}

# Bracket stop / take-profit levels (pure)
# Args: SIDE ENTRY [ATR] [REGIME] [VOLATILITY=50]
#   ATR > 0: stop pct = ATR*STOP_LOSS_ATR_MULTIPLIER/ENTRY*100, adjusted by
#   calculate_adjusted_stop_loss REGIME pct VOLATILITY (method atr+regime);
#   else STOP_LOSS_PERCENT (method percent). Clamped to
#   [ORDER_MIN_STOP_PCT 1, ORDER_MAX_STOP_PCT 15]. Take profit:
#   TARGET_PROFIT_PERCENT. Buy: stop below / target above the entry (at
#   least 0.01 away); sell: mirrored.
# Returns: JSON {stop_price, take_profit_price, stop_pct, method, regime, atr}
order_bracket_levels_from() {
    local side="$1" entry="$2" atr="${3:-}" regime="${4:-}" vol="${5:-50}"
    local pct method="percent" min max tp_pct stop tp
    min=$(_os_num "${ORDER_MIN_STOP_PCT:-1}" 1)
    max=$(_os_num "${ORDER_MAX_STOP_PCT:-15}" 15)
    tp_pct=$(_os_num "${TARGET_PROFIT_PERCENT:-8}" 8)
    if [[ "$atr" =~ ^[0-9]+(\.[0-9]+)?$ ]] && _os_gt "$atr" 0; then
        pct=$(LC_ALL=C awk -v a="$atr" -v m="$(_os_num "${STOP_LOSS_ATR_MULTIPLIER:-2}" 2)" -v e="$entry" \
            'BEGIN { printf "%.4f", a * m / e * 100 }')
        method="atr"
        if [[ -n "$regime" && "$regime" != "unknown" ]] && declare -F calculate_adjusted_stop_loss >/dev/null 2>&1; then
            pct=$(calculate_adjusted_stop_loss "$regime" "$pct" "$(_os_num "$vol" 50)" 2>/dev/null) || pct=""
            method="atr+regime"
        fi
    fi
    [[ "$pct" =~ ^-?[0-9]*\.?[0-9]+$ ]] || { pct=$(_os_num "${STOP_LOSS_PERCENT:-5}" 5); method="percent"; }
    pct=$(LC_ALL=C awk -v p="$pct" -v lo="$min" -v hi="$max" 'BEGIN { if (p < lo) p = lo; if (p > hi) p = hi; printf "%.2f", p }')
    if [[ "$side" == "sell" ]]; then
        stop=$(LC_ALL=C awk -v e="$entry" -v p="$pct" 'BEGIN { s = e * (1 + p / 100); if (s < e + 0.01) s = e + 0.01; printf "%.6f", s }')
        tp=$(LC_ALL=C awk -v e="$entry" -v p="$tp_pct" 'BEGIN { t = e * (1 - p / 100); if (t > e - 0.01) t = e - 0.01; printf "%.6f", t }')
        stop=$(_os_round "$stop"); tp=$(_os_round "$tp")
    else
        stop=$(calc_stop_loss_percent "$entry" "$pct")
        tp=$(calc_take_profit "$entry" "$tp_pct")
        stop=$(LC_ALL=C awk -v e="$entry" -v s="$stop" 'BEGIN { if (s > e - 0.01) s = e - 0.01; printf "%.6f", s }')
        tp=$(LC_ALL=C awk -v e="$entry" -v t="$tp" 'BEGIN { if (t < e + 0.01) t = e + 0.01; printf "%.6f", t }')
        stop=$(_os_round "$stop"); tp=$(_os_round "$tp")
    fi
    jq -cn --arg s "$stop" --arg t "$tp" --arg p "$pct" --arg m "$method" --arg r "$regime" --arg a "$atr" \
        '{stop_price: $s, take_profit_price: $t, stop_pct: ($p | tonumber), method: $m,
          regime: (if $r == "" then null else $r end), atr: (if $a == "" then null else ($a | tonumber? // null) end)}'
}

# Bracket levels for SYMBOL: ATR(14) and regime come only from REAL bars
# (fetch_stock_ohlcv with data_source yfinance); offline / synthetic / no
# data -> percent method
# Args: SYMBOL ENTRY [SIDE=buy]
# Returns: JSON like order_bracket_levels_from + {bars_source}
order_bracket_levels() {
    local symbol="$1" entry="$2" side="${3:-buy}" ohlcv="" src="none" atr="" regime="" vol=50 levels
    if [[ "${SST_OFFLINE:-0}" != "1" ]] && declare -F fetch_stock_ohlcv >/dev/null 2>&1; then
        ohlcv=$(fetch_stock_ohlcv "$symbol" 60 2>/dev/null | grep '^{' | tail -1)
        src=$(echo "$ohlcv" | jq -r '.data_source // "none"' 2>/dev/null)
        [[ -n "$src" ]] || src="none"
    fi
    if [[ "$src" == "yfinance" ]]; then
        local hlc closes rd
        hlc=$(echo "$ohlcv" | jq -r '[.ohlcv[] | "\(.high) \(.low) \(.close)"] | join(" ")')
        closes=$(echo "$ohlcv" | jq -r '[.ohlcv[].close] | join(" ")')
        declare -F calc_atr >/dev/null 2>&1 && atr=$(calc_atr 14 $hlc 2>/dev/null | grep -o '[0-9.]*' | head -1)
        if declare -F detect_market_regime >/dev/null 2>&1; then
            # shellcheck disable=SC2086
            rd=$(detect_market_regime "$symbol" "$(echo "$closes" | wc -w | tr -d ' ')" $closes 2>/dev/null)
            regime=$(echo "$rd" | jq -r '.regime // empty' 2>/dev/null)
            vol=$(echo "$rd" | jq -r '.volatility // 50' 2>/dev/null)
        fi
    fi
    levels=$(order_bracket_levels_from "$side" "$entry" "$atr" "$regime" "$vol") || return 1
    echo "$levels" | jq -c --arg b "$src" '. + {bars_source: $b}'
}

# ----------------------------------------------------------------------------
# Status
# ----------------------------------------------------------------------------

# Local safety status (no broker contact)
# Args: BROKER URL
# Returns: 0; prints the report
safety_status_report() {
    local broker="${1:-${BROKER_CHOICE:-alpaca}}" url="${2:-${ALPACA_BASE_URL:-}}" mode ks used ledger today_count base age
    mode=$(broker_endpoint_mode "$broker" "$url")
    echo "============================================"
    echo "SAFETY STATUS"
    echo "============================================"
    echo "Mode:               $(endpoint_mode_label "$mode") ($broker${url:+, $url})"
    if ks=$(kill_switch_active); then
        echo "Kill switch:        ACTIVE since $(echo "$ks" | jq -r '.ts // "?"'): $(echo "$ks" | jq -r '.reason // ""')"
    else
        echo "Kill switch:        off"
    fi
    echo "Caps:               MAX_ORDER_QTY=${MAX_ORDER_QTY:-100} MAX_ORDER_NOTIONAL=${MAX_ORDER_NOTIONAL:-2500} MAX_DAILY_NOTIONAL=${MAX_DAILY_NOTIONAL:-10000} MAX_OPEN_POSITIONS=${MAX_OPEN_POSITIONS:-5}"
    echo "Daily loss limit:   $(daily_loss_limit_pct)% (DAILY_LOSS_LIMIT_PCT${DAILY_LOSS_LIMIT_PCT:+=$DAILY_LOSS_LIMIT_PCT}; empty = DEFAULT_RISK_LEVEL ${DEFAULT_RISK_LEVEL:-moderate})"
    used=$(BROKER_CHOICE="$broker" daily_buy_notional_used)
    echo "Today's buys:       \$$used of \$${MAX_DAILY_NOTIONAL:-10000} ($broker, trading day $(_os_trading_day))"
    ledger=$(order_ledger_entries)
    today_count=$(echo "$ledger" | jq -r --arg d "$(_os_trading_day)" '[.[] | select(.trading_day == $d)] | length')
    echo "Order ledger:       $(echo "$ledger" | jq -r 'length') orders ($today_count today) in $(order_ledger_file)"
    base=$(reconcile_baseline_file)
    if [[ -f "$base" ]]; then
        age=$(( ( $(date +%s) - $(perl -e 'my @s = stat shift; print $s[9] // 0' "$base") ) / 60 ))
        echo "Baseline:           $(jq -r '.taken_at' "$base") (${age} min old)"
    else
        echo "Baseline:           none (run --reconcile-accept)"
    fi
    echo "Orders:             ${ORDER_TYPE:-limit} (offset ${LIMIT_OFFSET_PCT:-0.2}%), bracket ${ORDER_BRACKET:-true} (${BRACKET_TIME_IN_FORCE:-gtc}), outside hours ${OUTSIDE_HOURS_POLICY:-refuse}, duplicate window ${DUPLICATE_ORDER_WINDOW_SECONDS:-300} s"
    echo "Reconcile on start: ${RECONCILE_ON_STARTUP:-true}"
    echo "Alerts:             $(alert_channels_summary)"
    echo "============================================"
    return 0
}

export -f _os_num _os_gt _os_trading_day _os_round _os_positions_map
export -f sst_state_dir kill_switch_file kill_switch_active kill_switch_engage kill_switch_release
export -f broker_endpoint_mode endpoint_mode_label config_file_is_tracked
export -f order_ledger_file order_ledger_append order_ledger_update order_ledger_entries
export -f generate_client_order_id order_lock_acquire order_lock_release
export -f check_order_qty_cap daily_buy_notional_used check_order_caps
export -f daily_loss_limit_pct check_daily_loss_halt check_duplicate_order
export -f reconcile_baseline_file reconcile_compute _reconcile_write_baseline reconcile_with_broker reconcile_accept
export -f check_market_hours check_pdt_warning
export -f compute_limit_price order_bracket_levels_from order_bracket_levels
export -f safety_status_report
