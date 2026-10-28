#!/bin/bash
# ============================================================================
# StockSwingTrader: Robinhood MCP Direct Integration (No Kiro Required)
# ============================================================================
# Direct HTTP calls to Robinhood MCP servers
# Works on any system with curl, bash, and jq
# ============================================================================

set -o pipefail

# ============================================================================
# MCP Configuration
# ============================================================================

ROBINHOOD_MCP_TRADING_URL="${ROBINHOOD_MCP_TRADING_URL:-https://agent.robinhood.com/mcp/trading}"
ROBINHOOD_MCP_BANKING_URL="${ROBINHOOD_MCP_BANKING_URL:-https://banking-agent.robinhood.com/mcp/banking}"

# Token storage
ROBINHOOD_MCP_TOKENS_FILE="${HOME}/.robinhood_mcp_tokens.json"
ROBINHOOD_MCP_LOG_FILE="${ROBINHOOD_MCP_LOG_FILE:-logs/robinhood_mcp.log}"

# Logging
robinhood_mcp_log() {
    local level="$1"
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    mkdir -p "$(dirname "$ROBINHOOD_MCP_LOG_FILE")"
    echo "[${timestamp}] [${level}] ${message}" >> "$ROBINHOOD_MCP_LOG_FILE"
    
    if [[ "$ROBINHOOD_DEBUG" == "true" ]]; then
        echo "[${level}] ${message}" >&2
    fi
}

# ============================================================================
# Authentication - Browser OAuth Flow
# ============================================================================

# Start local callback server to capture OAuth code
robinhood_mcp_start_callback_server() {
    local port="${1:-8888}"
    local state="${2:-}"
    
    robinhood_mcp_log "INFO" "Starting local callback server on port $port"
    
    # Use nc (netcat) or Python to listen for callback
    if command -v python3 &>/dev/null; then
        # Python HTTP server
        cat > /tmp/robinhood_callback.py << 'PYEOF'
#!/usr/bin/env python3
import http.server
import socketserver
import sys
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8888

class CallbackHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        query = parse_qs(urlparse(self.path).query)
        if 'code' in query:
            code = query['code'][0]
            print(f"AUTH_CODE:{code}")
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            self.wfile.write(b'Authorization successful! You can close this window.')
            sys.exit(0)
        else:
            self.send_response(400)
            self.end_headers()

    def log_message(self, format, *args):
        pass  # Suppress logs

with socketserver.TCPServer(("", PORT), CallbackHandler) as httpd:
    print(f"Listening on port {PORT}...")
    httpd.handle_request()
PYEOF
        python3 /tmp/robinhood_callback.py "$port" 2>/dev/null &
        echo $!
    fi
}

# Open browser to OAuth authorization URL
robinhood_mcp_open_browser() {
    local auth_url="$1"
    
    robinhood_mcp_log "INFO" "Opening browser for OAuth authorization"
    
    if command -v open &>/dev/null; then
        open "$auth_url"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$auth_url"
    elif command -v start &>/dev/null; then
        start "$auth_url"
    else
        echo "ERROR: Cannot open browser. Please visit this URL manually:"
        echo "$auth_url"
        return 1
    fi
}

# Initialize OAuth flow
robinhood_mcp_oauth_init() {
    local client_id="${ROBINHOOD_MCP_CLIENT_ID:-robinhood-trading-api}"
    local redirect_uri="${ROBINHOOD_MCP_REDIRECT_URI:-http://localhost:8888/callback}"
    local scope="read write"
    local state=$(openssl rand -hex 32)
    
    robinhood_mcp_log "INFO" "Initiating OAuth flow"
    
    # Generate authorization URL
    local auth_url="${ROBINHOOD_MCP_TRADING_URL}/oauth/authorize"
    auth_url+="?client_id=${client_id}"
    auth_url+="&response_type=code"
    auth_url+="&redirect_uri=${redirect_uri}"
    auth_url+="&scope=${scope}"
    auth_url+="&state=${state}"
    
    echo "Starting OAuth authorization flow..."
    echo "Opening browser to: $auth_url"
    echo ""
    
    robinhood_mcp_open_browser "$auth_url"
    
    # Start callback server
    local callback_pid=$(robinhood_mcp_start_callback_server 8888 "$state")
    
    echo "Waiting for authorization (timeout in 300 seconds)..."
    sleep 5
    
    # Wait for callback
    local timeout=300
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if [[ -f /tmp/robinhood_auth_code.txt ]]; then
            local auth_code=$(cat /tmp/robinhood_auth_code.txt)
            rm /tmp/robinhood_auth_code.txt
            robinhood_mcp_log "INFO" "Received authorization code: $auth_code"
            echo "$auth_code"
            return 0
        fi
        sleep 1
        ((elapsed++))
    done
    
    robinhood_mcp_log "ERROR" "OAuth timeout - no authorization code received"
    return 1
}

# ============================================================================
# MCP API Calls (Direct HTTP)
# ============================================================================

# Call Robinhood Trading MCP endpoint
robinhood_mcp_call() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    
    local url="${ROBINHOOD_MCP_TRADING_URL}${endpoint}"
    
    robinhood_mcp_log "INFO" "MCP Call: $method $endpoint"
    
    local curl_opts=(-s -X "$method" "$url")
    
    # Add auth token if available
    if [[ -f "$ROBINHOOD_MCP_TOKENS_FILE" ]]; then
        local token=$(jq -r '.access_token // empty' "$ROBINHOOD_MCP_TOKENS_FILE" 2>/dev/null)
        if [[ -n "$token" ]]; then
            curl_opts+=(-H "Authorization: Bearer $token")
        fi
    fi
    
    curl_opts+=(-H "Content-Type: application/json")
    
    if [[ -n "$data" ]]; then
        curl_opts+=(-d "$data")
    fi
    
    local response=$(curl "${curl_opts[@]}")
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" "${curl_opts[@]}")
    
    robinhood_mcp_log "INFO" "HTTP Response: $http_code"
    
    if [[ "$http_code" == "401" ]]; then
        robinhood_mcp_log "WARN" "Unauthorized - token may have expired"
        return 1
    fi
    
    echo "$response"
}

# ============================================================================
# Wrapper Functions (User-Facing)
# ============================================================================

# Check account
robinhood_mcp_check_account() {
    robinhood_mcp_log "INFO" "Checking Robinhood account via MCP"
    robinhood_mcp_call GET "/api/accounts" | jq '.' 2>/dev/null || {
        robinhood_mcp_log "ERROR" "Failed to get account info"
        return 1
    }
}

# Get positions
robinhood_mcp_get_positions() {
    robinhood_mcp_log "INFO" "Fetching positions via MCP"
    robinhood_mcp_call GET "/api/positions" | jq '.' 2>/dev/null || {
        robinhood_mcp_log "ERROR" "Failed to get positions"
        return 1
    }
}

# Place order
robinhood_mcp_place_order() {
    local symbol="$1"
    local qty="$2"
    local side="$3"  # buy or sell
    local order_type="${4:-market}"
    local price="${5:-}"
    
    robinhood_mcp_log "INFO" "Placing $side order: $qty $symbol at $order_type"
    
    local order_data=$(jq -n \
        --arg symbol "$symbol" \
        --arg qty "$qty" \
        --arg side "$side" \
        --arg type "$order_type" \
        --arg price "$price" \
        '{
            symbol: $symbol,
            quantity: ($qty | tonumber),
            side: $side,
            order_type: $type,
            price: (if $price != "" then ($price | tonumber) else null end)
        }')
    
    robinhood_mcp_call POST "/api/orders" "$order_data" | jq '.' 2>/dev/null || {
        robinhood_mcp_log "ERROR" "Failed to place order"
        return 1
    }
}

# Get quotes
robinhood_mcp_get_quote() {
    local symbol="$1"
    robinhood_mcp_log "INFO" "Fetching quote for $symbol via MCP"
    robinhood_mcp_call GET "/api/quotes/$symbol" | jq '.' 2>/dev/null || {
        robinhood_mcp_log "ERROR" "Failed to get quote for $symbol"
        return 1
    }
}

# ============================================================================
# Exports (Public API)
# ============================================================================

export -f robinhood_mcp_check_account
export -f robinhood_mcp_get_positions
export -f robinhood_mcp_place_order
export -f robinhood_mcp_get_quote
export -f robinhood_mcp_call
export -f robinhood_mcp_log

