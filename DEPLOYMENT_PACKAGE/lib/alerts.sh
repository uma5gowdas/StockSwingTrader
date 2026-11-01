#!/bin/bash
# ============================================================================
# StockSwingTrader: Alerts
# ============================================================================
# send_alert LEVEL EVENT MESSAGE [DETAILS_JSON]
#   Always appends one JSON line to ALERT_LOG_FILE (default logs/alerts.log in
#   the project). Optional channels, both OFF by default:
#     Slack: ALERTS_SLACK_ENABLED=true + ALERT_SLACK_WEBHOOK_URL
#     Email: ALERTS_EMAIL_ENABLED=true + ALERT_EMAIL_TO (piped to
#            ${ALERT_SENDMAIL_CMD:-sendmail} -t)
#   A failing channel is logged as an "alert_channel_error" line; it is never
#   fatal (send_alert always returns 0).
# Events: order_placed, order_filled, order_rejected, cap_hit,
#   duplicate_blocked, halt, resume, reconcile_mismatch, outside_hours,
#   pdt_warning, error
# Callers must not put key values or full account ids in MESSAGE/DETAILS.
#
# Sourced library: no errexit, does not change SCRIPT_DIR/LIB_DIR/AGENT_DIR.
# ============================================================================

ALERTS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Path of the alert log (directory created)
# Returns: absolute or caller-given path on stdout
alert_log_file() {
    local file="${ALERT_LOG_FILE:-}"
    [[ -n "$file" ]] || file="$ALERTS_LIB_DIR/../logs/alerts.log"
    mkdir -p "$(dirname "$file")" 2>/dev/null
    echo "$file"
}

# Append one alert line to the alert log
# Args: LEVEL EVENT MESSAGE [DETAILS_JSON]
# Returns: 0
_alert_write_line() {
    local level="$1" event="$2" message="$3" details="${4:-}"
    local file ts
    file=$(alert_log_file)
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # DETAILS must be JSON; anything else is stored as a string
    if [[ -z "$details" ]] || ! echo "$details" | jq -e . >/dev/null 2>&1; then
        details=$(jq -cn --arg d "$details" 'if $d == "" then null else $d end')
    fi
    jq -cn --arg ts "$ts" --arg level "$level" --arg event "$event" --arg message "$message" \
        --argjson details "$details" --arg mode "${SST_ENDPOINT_MODE:-unknown}" \
        '{ts: $ts, level: $level, event: $event, message: $message, details: $details, mode: $mode}' \
        >> "$file" 2>/dev/null
    return 0
}

# Post an alert to the Slack webhook
# Args: LEVEL EVENT MESSAGE
# Returns: 0 sent, 1 failed
_alert_send_slack() {
    local level="$1" event="$2" message="$3" body code
    body=$(jq -cn --arg t "[StockSwingTrader ${level}] ${event} (${SST_ENDPOINT_MODE:-unknown}): ${message}" '{text: $t}')
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "${ALERT_TIMEOUT_SECONDS:-5}" \
        -X POST -H 'Content-Type: application/json' -d "$body" "$ALERT_SLACK_WEBHOOK_URL" 2>/dev/null)
    [[ "$code" =~ ^2[0-9][0-9]$ ]]
}

# Send an alert email through sendmail -t
# Args: LEVEL EVENT MESSAGE [DETAILS_JSON]
# Returns: 0 sent, 1 failed
_alert_send_email() {
    local level="$1" event="$2" message="$3" details="${4:-}"
    local cmd="${ALERT_SENDMAIL_CMD:-sendmail}"
    command -v "$cmd" >/dev/null 2>&1 || return 1
    {
        echo "To: ${ALERT_EMAIL_TO}"
        echo "Subject: [StockSwingTrader ${level}] ${event}"
        echo "Content-Type: text/plain; charset=utf-8"
        echo ""
        echo "Event:   ${event}"
        echo "Level:   ${level}"
        echo "Mode:    ${SST_ENDPOINT_MODE:-unknown}"
        echo "Time:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo ""
        echo "${message}"
        [[ -n "$details" ]] && echo "" && echo "Details: ${details}"
    } | perl -e 'alarm shift; exec @ARGV' "${ALERT_TIMEOUT_SECONDS:-5}" "$cmd" -t >/dev/null 2>&1
}

# Record an alert and forward it to the enabled channels
# Args: LEVEL (info|warn|critical) EVENT MESSAGE [DETAILS_JSON]
# Returns: 0 always (alerting never blocks or aborts the caller)
# Example: send_alert warn cap_hit "MAX_ORDER_QTY 100 exceeded" '{"qty":500}'
send_alert() {
    local level="${1:-info}" event="${2:-error}" message="${3:-}" details="${4:-}"
    _alert_write_line "$level" "$event" "$message" "$details"

    if [[ "${ALERTS_SLACK_ENABLED:-false}" == "true" && -n "${ALERT_SLACK_WEBHOOK_URL:-}" ]]; then
        _alert_send_slack "$level" "$event" "$message" || \
            _alert_write_line warn alert_channel_error "Slack alert failed for event $event" '{"channel":"slack"}'
    fi
    if [[ "${ALERTS_EMAIL_ENABLED:-false}" == "true" && -n "${ALERT_EMAIL_TO:-}" ]]; then
        _alert_send_email "$level" "$event" "$message" "$details" || \
            _alert_write_line warn alert_channel_error "Email alert failed for event $event" '{"channel":"email"}'
    fi
    return 0
}

# One-line summary of the alert channels (for --safety-status)
# Returns: e.g. "log /path/alerts.log; slack off; email off"
alert_channels_summary() {
    local slack=off email=off
    [[ "${ALERTS_SLACK_ENABLED:-false}" == "true" && -n "${ALERT_SLACK_WEBHOOK_URL:-}" ]] && slack=on
    [[ "${ALERTS_SLACK_ENABLED:-false}" == "true" && -z "${ALERT_SLACK_WEBHOOK_URL:-}" ]] && slack="off (no webhook URL)"
    [[ "${ALERTS_EMAIL_ENABLED:-false}" == "true" && -n "${ALERT_EMAIL_TO:-}" ]] && email=on
    [[ "${ALERTS_EMAIL_ENABLED:-false}" == "true" && -z "${ALERT_EMAIL_TO:-}" ]] && email="off (no ALERT_EMAIL_TO)"
    echo "log $(alert_log_file); slack $slack; email $email"
}

export -f alert_log_file
export -f _alert_write_line
export -f _alert_send_slack
export -f _alert_send_email
export -f send_alert
export -f alert_channels_summary
