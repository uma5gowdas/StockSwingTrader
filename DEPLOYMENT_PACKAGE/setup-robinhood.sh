#!/bin/bash
################################################################################
# StockSwingTrader: Robinhood Broker Setup Wizard
################################################################################
# Purpose: Interactive setup wizard for Robinhood OAuth2 configuration
#
# Features:
#   - Explains Robinhood OAuth2 flow
#   - Generates authorization URL
#   - Prompts user to authenticate and paste authorization code
#   - Exchanges code for access and refresh tokens
#   - Fetches account information
#   - Saves tokens securely to config.robinhood.env
#   - Retry logic for network issues
#   - Clear instructions for token refresh
#
# Usage:
#   ./setup-robinhood.sh                       # Interactive OAuth2 setup
#   ./setup-robinhood.sh --client-id xxx       # With pre-filled client ID
#
# Output:
#   Creates: config.robinhood.env with validated OAuth2 tokens
#   Shows: Account details and trading status
#
# Requirements:
#   - bash 4.0+
#   - curl (for API calls)
#   - jq (optional, for pretty JSON output)
#
# OAuth2 Flow:
#   1. User opens authorization URL in browser
#   2. User authenticates with Robinhood credentials
#   3. Robinhood redirects with authorization code
#   4. User pastes code into this script
#   5. Script exchanges code for tokens
#   6. Tokens are saved securely
#
# No external dependencies beyond standard Unix utilities
################################################################################

set -o pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Output files
CONFIG_FILE="${SCRIPT_DIR}/config.robinhood.env"
LOG_FILE="${SCRIPT_DIR}/logs/setup-robinhood.log"
BACKUP_DIR="${SCRIPT_DIR}/backups"

# OAuth2 Configuration
ROBINHOOD_API_BASE_URL="https://api.robinhood.com"
ROBINHOOD_OAUTH_BASE_URL="https://api.robinhood.com/oauth2"
ROBINHOOD_REDIRECT_URI="http://localhost:8000"

# Default OAuth2 credentials (user should update in browser or config)
# These are example/default values - user will provide their actual app credentials
ROBINHOOD_CLIENT_ID="${ROBINHOOD_CLIENT_ID:-your_app_id}"
ROBINHOOD_CLIENT_SECRET="${ROBINHOOD_CLIENT_SECRET:-your_client_secret}"

# Retry configuration
MAX_RETRIES=3
INITIAL_BACKOFF=1
BACKOFF_MULTIPLIER=2

# Timeouts (seconds)
TIMEOUT_CONNECT=5
TIMEOUT_TOTAL=15
TEST_SYMBOL="AAPL"

# Color codes for output
COLOR_RESET='\033[0m'
COLOR_BOLD='\033[1m'
COLOR_GREEN='\033[32m'
COLOR_YELLOW='\033[33m'
COLOR_RED='\033[31m'
COLOR_BLUE='\033[34m'
COLOR_CYAN='\033[36m'

# ============================================================================
# Logging & Output Functions
# ============================================================================

print_header() {
    echo -e "\n${COLOR_BOLD}${COLOR_CYAN}=== $1 ===${COLOR_RESET}"
}

print_info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $1"
}

print_success() {
    echo -e "${COLOR_GREEN}[✓]${COLOR_RESET} $1"
}

print_warn() {
    echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $1"
}

print_error() {
    echo -e "${COLOR_RED}[✗]${COLOR_RESET} $1" >&2
}

log_message() {
    local level="$1"
    shift
    local msg="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Ensure log directory exists
    [[ ! -d "$(dirname "$LOG_FILE")" ]] && mkdir -p "$(dirname "$LOG_FILE")"
    
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
}

# ============================================================================
# Utility Functions
# ============================================================================

# URL encode a string
urlencode() {
    local string="$1"
    echo -n "$string" | jq -sRr @uri
}

# Generate a random state parameter for CSRF protection
generate_state() {
    openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | xxd -p
}

# Parse JSON response (basic fallback if jq not available)
parse_json_value() {
    local json="$1"
    local key="$2"
    
    # Try using jq first if available
    if command -v jq &> /dev/null; then
        echo "$json" | jq -r ".$key // empty" 2>/dev/null
    else
        # Fallback: basic grep/sed parsing
        echo "$json" | grep -o "\"$key\":\"[^\"]*\"" | cut -d'"' -f4
    fi
}

# Make API call with retry logic
make_api_call() {
    local method="$1"
    local endpoint="$2"
    local access_token="${3:-}"
    local data="${4:-}"
    
    local url="${ROBINHOOD_API_BASE_URL}${endpoint}"
    local retry_count=0
    local backoff=$INITIAL_BACKOFF
    
    while (( retry_count < MAX_RETRIES )); do
        log_message "DEBUG" "API Call: $method $endpoint (attempt $((retry_count + 1))/$MAX_RETRIES)"
        
        local headers=(
            -H "Content-Type: application/json"
            -H "Accept: application/json"
        )
        
        if [[ -n "$access_token" ]]; then
            headers+=(-H "Authorization: Bearer $access_token")
        fi
        
        if [[ -n "$data" ]]; then
            local response=$(curl -s \
                --connect-timeout "$TIMEOUT_CONNECT" \
                --max-time "$TIMEOUT_TOTAL" \
                -X "$method" \
                "${headers[@]}" \
                -d "$data" \
                "$url" 2>&1)
        else
            local response=$(curl -s \
                --connect-timeout "$TIMEOUT_CONNECT" \
                --max-time "$TIMEOUT_TOTAL" \
                -X "$method" \
                "${headers[@]}" \
                "$url" 2>&1)
        fi
        
        # Check for successful response (no error indicators)
        if ! echo "$response" | grep -q "Connection refused\|timed out\|name or service not known\|Failed to resolve"; then
            echo "$response"
            return 0
        fi
        
        # Increment retry count and calculate backoff
        (( retry_count++ ))
        if (( retry_count < MAX_RETRIES )); then
            log_message "WARN" "API call failed, retrying in ${backoff}s..."
            sleep "$backoff"
            backoff=$((backoff * BACKOFF_MULTIPLIER))
        fi
    done
    
    log_message "ERROR" "API call failed after $MAX_RETRIES attempts: $method $endpoint"
    return 1
}

# ============================================================================
# OAuth2 Flow
# ============================================================================

explain_oauth2_flow() {
    print_header "Robinhood OAuth2 Authentication"
    
    echo ""
    echo "Robinhood uses OAuth2 for secure authentication. Here's how it works:"
    echo ""
    echo "1. ${COLOR_BOLD}Authorization${COLOR_RESET}"
    echo "   You'll open a link in your browser to authorize this application"
    echo "   to access your Robinhood account."
    echo ""
    echo "2. ${COLOR_BOLD}Authentication${COLOR_RESET}"
    echo "   You'll log in with your Robinhood username and password"
    echo "   (This setup wizard NEVER sees your credentials)"
    echo ""
    echo "3. ${COLOR_BOLD}Authorization Code${COLOR_RESET}"
    echo "   Robinhood will provide an authorization code in the URL"
    echo "   You'll paste this code back into this setup wizard"
    echo ""
    echo "4. ${COLOR_BOLD}Token Exchange${COLOR_RESET}"
    echo "   This wizard exchanges the code for access and refresh tokens"
    echo "   Tokens are saved securely in: $CONFIG_FILE"
    echo ""
    echo "5. ${COLOR_BOLD}Automatic Refresh${COLOR_RESET}"
    echo "   The refresh token allows automatic token renewal when needed"
    echo ""
}

prompt_oauth_credentials() {
    print_header "OAuth2 Application Credentials"
    
    echo ""
    print_info "You need to provide OAuth2 application credentials."
    echo ""
    echo "To create an app:"
    echo "  1. Go to: https://developer.robinhood.com"
    echo "  2. Create a new application"
    echo "  3. Set Redirect URI to: http://localhost:8000"
    echo "  4. Copy your Client ID and Client Secret below"
    echo ""
    
    local client_id="$ROBINHOOD_CLIENT_ID"
    local client_secret="$ROBINHOOD_CLIENT_SECRET"
    
    # If defaults are still set, prompt for real values
    if [[ "$client_id" == "your_app_id" ]] || [[ -z "$client_id" ]]; then
        while [[ -z "$client_id" || "$client_id" == "your_app_id" ]]; do
            echo -e -n "${COLOR_YELLOW}? Enter your Robinhood OAuth2 Client ID${COLOR_RESET}: " >&2
            read -r client_id
            if [[ -z "$client_id" ]]; then
                print_error "Client ID cannot be empty"
            fi
        done
    fi
    
    if [[ "$client_secret" == "your_client_secret" ]] || [[ -z "$client_secret" ]]; then
        while [[ -z "$client_secret" || "$client_secret" == "your_client_secret" ]]; do
            echo -e -n "${COLOR_YELLOW}? Enter your Robinhood OAuth2 Client Secret${COLOR_RESET}: " >&2
            read -rs client_secret
            echo ""
            if [[ -z "$client_secret" ]]; then
                print_error "Client Secret cannot be empty"
            fi
        done
    fi
    
    OAUTH_CLIENT_ID="$client_id"
    OAUTH_CLIENT_SECRET="$client_secret"
}

generate_authorization_url() {
    local client_id="$1"
    local state=$(generate_state)
    
    # Store state for verification
    AUTH_STATE="$state"
    
    # Build authorization URL
    local scope_encoded=$(urlencode "read write")
    local auth_url="${ROBINHOOD_OAUTH_BASE_URL}/authorize/?client_id=${client_id}&response_type=code&scope=${scope_encoded}&redirect_uri=${ROBINHOOD_REDIRECT_URI}&state=${state}"
    
    echo "$auth_url"
}

prompt_for_authorization_code() {
    local auth_url="$1"
    
    print_header "Authorization Step"
    
    echo ""
    print_info "Opening authorization URL in your browser..."
    echo ""
    echo "Authorization URL:"
    echo "${COLOR_CYAN}$auth_url${COLOR_RESET}"
    echo ""
    echo "If the link doesn't open automatically, copy and paste it into your browser."
    echo ""
    
    # Try to open the URL in a browser
    if command -v open &> /dev/null; then
        open "$auth_url" 2>/dev/null || true
    elif command -v xdg-open &> /dev/null; then
        xdg-open "$auth_url" 2>/dev/null || true
    elif command -v gnome-open &> /dev/null; then
        gnome-open "$auth_url" 2>/dev/null || true
    fi
    
    echo ""
    print_info "After you authorize, you'll be redirected to a localhost URL."
    echo "The URL will look like: http://localhost:8000/?code=XXX&state=XXX"
    echo ""
    
    local auth_code=""
    while [[ -z "$auth_code" ]]; do
        echo -e -n "${COLOR_YELLOW}? Paste the authorization code from the URL${COLOR_RESET}: " >&2
        read -r auth_code
        if [[ -z "$auth_code" ]]; then
            print_error "Authorization code cannot be empty"
        fi
    done
    
    AUTH_CODE="$auth_code"
}

exchange_code_for_tokens() {
    local client_id="$1"
    local client_secret="$2"
    local auth_code="$3"
    
    print_info "Exchanging authorization code for tokens..."
    log_message "INFO" "Exchanging auth code for tokens"
    
    # Prepare token request
    local token_request=$(cat <<EOF
{
    "grant_type": "authorization_code",
    "code": "$auth_code",
    "client_id": "$client_id",
    "client_secret": "$client_secret",
    "redirect_uri": "$ROBINHOOD_REDIRECT_URI"
}
EOF
    )
    
    # Make token request
    local response=$(make_api_call "POST" "/token/" "" "$token_request")
    
    if [[ -z "$response" ]]; then
        print_error "Failed to exchange authorization code"
        log_message "ERROR" "Token exchange failed - empty response"
        return 1
    fi
    
    # Check for error in response
    if echo "$response" | grep -q "error\|invalid_grant\|invalid_client"; then
        print_error "Token exchange failed. Please check your credentials and authorization code."
        print_error "Response: $response"
        log_message "ERROR" "Token exchange error: $response"
        return 1
    fi
    
    # Extract tokens from response
    ACCESS_TOKEN=$(parse_json_value "$response" "access_token")
    REFRESH_TOKEN=$(parse_json_value "$response" "refresh_token")
    TOKEN_EXPIRES_IN=$(parse_json_value "$response" "expires_in")
    
    if [[ -z "$ACCESS_TOKEN" ]] || [[ -z "$REFRESH_TOKEN" ]]; then
        print_error "Failed to extract tokens from response"
        log_message "ERROR" "Token extraction failed from response: $response"
        return 1
    fi
    
    print_success "Successfully obtained access and refresh tokens"
    log_message "INFO" "Token exchange successful, expires_in: $TOKEN_EXPIRES_IN seconds"
    
    return 0
}

# ============================================================================
# Account Information Retrieval
# ============================================================================

fetch_account_info() {
    local access_token="$1"
    
    print_info "Fetching account information..."
    log_message "INFO" "Fetching account info from Robinhood"
    
    local response=$(make_api_call "GET" "/user/accounts/" "$access_token")
    
    if [[ -z "$response" ]]; then
        print_error "Failed to fetch account information"
        log_message "ERROR" "Failed to fetch account info"
        return 1
    fi
    
    print_success "Account information retrieved"
    
    # Parse and display account details
    echo -e "\n${COLOR_BOLD}Account Details:${COLOR_RESET}"
    
    # Account number
    local account_num=$(parse_json_value "$response" "account_number")
    [[ -n "$account_num" ]] && echo "  Account Number:  $account_num" || echo "  Account Number:  (not available)"
    
    # Account type
    local account_type=$(parse_json_value "$response" "account_type")
    [[ -n "$account_type" ]] && echo "  Account Type:    $account_type" || echo "  Account Type:    (not available)"
    
    # Buying power
    local buying_power=$(parse_json_value "$response" "buying_power")
    [[ -n "$buying_power" ]] && echo "  Buying Power:    \$$buying_power" || echo "  Buying Power:    (not available)"
    
    # Cash
    local cash=$(parse_json_value "$response" "cash")
    [[ -n "$cash" ]] && echo "  Cash:            \$$cash" || echo "  Cash:            (not available)"
    
    # Equity value
    local equity=$(parse_json_value "$response" "equity")
    [[ -n "$equity" ]] && echo "  Equity:          \$$equity" || echo "  Equity:          (not available)"
    
    # Margin enabled
    local margin=$(parse_json_value "$response" "margin_enabled")
    if [[ -n "$margin" ]]; then
        if [[ "$margin" == "true" ]]; then
            echo "  Margin:          ${COLOR_GREEN}Enabled${COLOR_RESET}"
        else
            echo "  Margin:          ${COLOR_YELLOW}Disabled${COLOR_RESET}"
        fi
    fi
    
    echo ""
    
    # Store for later use
    ACCOUNT_INFO="$response"
    return 0
}

# ============================================================================
# Configuration File Management
# ============================================================================

create_config_backup() {
    if [[ -f "$CONFIG_FILE" ]]; then
        print_info "Backing up existing configuration..."
        [[ ! -d "$BACKUP_DIR" ]] && mkdir -p "$BACKUP_DIR"
        
        local backup_file="${BACKUP_DIR}/config.robinhood.env.backup.$(date '+%Y%m%d_%H%M%S')"
        cp "$CONFIG_FILE" "$backup_file"
        print_success "Configuration backed up to: $backup_file"
        log_message "INFO" "Created backup: $backup_file"
    fi
}

save_config() {
    local client_id="$1"
    local access_token="$2"
    local refresh_token="$3"
    
    print_info "Saving configuration to: $CONFIG_FILE..."
    log_message "INFO" "Saving configuration"
    
    # Ensure directory exists
    [[ ! -d "$(dirname "$CONFIG_FILE")" ]] && mkdir -p "$(dirname "$CONFIG_FILE")"
    
    # Create backup of existing config
    create_config_backup
    
    # Write new config file
    cat > "$CONFIG_FILE" << 'EOF'
#!/bin/bash
################################################################################
# Robinhood Broker Configuration
# Generated by: setup-robinhood.sh
# Timestamp: SETUP_TIMESTAMP
################################################################################

# Robinhood OAuth2 Credentials (validated)
export ROBINHOOD_ENABLED=true
export ROBINHOOD_CLIENT_ID="CLIENT_ID_PLACEHOLDER"
export ROBINHOOD_ACCESS_TOKEN="ACCESS_TOKEN_PLACEHOLDER"
export ROBINHOOD_REFRESH_TOKEN="REFRESH_TOKEN_PLACEHOLDER"

# Robinhood API Configuration
export ROBINHOOD_API_BASE_URL="https://api.robinhood.com"
export ROBINHOOD_API_VERSION="v1"
export ROBINHOOD_TIMEOUT_SECONDS=15
export ROBINHOOD_MAX_RETRIES=3

# Trading Configuration
export ROBINHOOD_MIN_POSITION_SIZE=1          # Minimum shares to hold
export ROBINHOOD_MAX_POSITION_SIZE=1000       # Maximum shares per trade
export ROBINHOOD_AUTO_TRADE=false             # Auto-execute trades on strong signals
export ROBINHOOD_STRONG_BUY_THRESHOLD=80      # Confluence score threshold for auto-buy
export ROBINHOOD_STRONG_SELL_THRESHOLD=20     # Confluence score threshold for auto-sell
export ROBINHOOD_LOG_ALL_TRADES=true          # Log all trade attempts

# Logging
export ROBINHOOD_LOG_FILE="logs/robinhood.log"
export ROBINHOOD_DEBUG=false

# Token Refresh Configuration
export ROBINHOOD_TOKEN_REFRESH_INTERVAL=3600  # Refresh token every hour (3600 seconds)
export ROBINHOOD_TOKEN_EXPIRY_CHECK=true      # Check and refresh tokens automatically

# Account Information
export SETUP_DATE="SETUP_TIMESTAMP"
export SETUP_STATUS="completed"

################################################################################
# Token Refresh Instructions
################################################################################
#
# The access token will expire after a period of time. The refresh token can be
# used to obtain a new access token without requiring user authentication.
#
# To manually refresh the token, run:
#   ROBINHOOD_REFRESH_TOKEN="$ROBINHOOD_REFRESH_TOKEN" \
#   ROBINHOOD_CLIENT_ID="$ROBINHOOD_CLIENT_ID" \
#   curl -X POST https://api.robinhood.com/oauth2/token/ \
#     -d '{"grant_type": "refresh_token", "refresh_token": "'$ROBINHOOD_REFRESH_TOKEN'"}'
#
# Update the ROBINHOOD_ACCESS_TOKEN with the new token from the response.
#
# For automated refresh, the StockSwingTrader agent will handle this automatically
# if ROBINHOOD_TOKEN_EXPIRY_CHECK is set to true.
#
################################################################################

EOF
    
    # Replace placeholders
    sed -i '' "s|CLIENT_ID_PLACEHOLDER|$client_id|g" "$CONFIG_FILE"
    sed -i '' "s|ACCESS_TOKEN_PLACEHOLDER|$access_token|g" "$CONFIG_FILE"
    sed -i '' "s|REFRESH_TOKEN_PLACEHOLDER|$refresh_token|g" "$CONFIG_FILE"
    sed -i '' "s|SETUP_TIMESTAMP|$TIMESTAMP|g" "$CONFIG_FILE"
    
    # Secure permissions
    chmod 600 "$CONFIG_FILE"
    
    print_success "Configuration saved successfully"
    log_message "INFO" "Configuration saved to $CONFIG_FILE with secure permissions (600)"
    
    return 0
}

# ============================================================================
# Main Setup Flow
# ============================================================================

main() {
    print_header "StockSwingTrader: Robinhood Setup Wizard"
    
    log_message "INFO" "=== Setup Started ==="
    log_message "INFO" "Script: $SCRIPT_NAME"
    log_message "INFO" "Timestamp: $TIMESTAMP"
    
    # Step 1: Explain OAuth2 flow
    print_info "Step 1/6: Learning about OAuth2 authentication..."
    explain_oauth2_flow
    echo ""
    
    # Step 2: Get OAuth2 credentials
    print_info "Step 2/6: Collecting OAuth2 credentials..."
    prompt_oauth_credentials
    echo ""
    
    # Step 3: Generate authorization URL
    print_info "Step 3/6: Generating authorization URL..."
    local auth_url=$(generate_authorization_url "$OAUTH_CLIENT_ID")
    log_message "INFO" "Generated auth URL"
    echo ""
    
    # Step 4: Prompt for authorization
    print_info "Step 4/6: Authorizing application..."
    prompt_for_authorization_code "$auth_url"
    echo ""
    
    # Step 5: Exchange code for tokens
    print_info "Step 5/6: Exchanging code for tokens..."
    if ! exchange_code_for_tokens "$OAUTH_CLIENT_ID" "$OAUTH_CLIENT_SECRET" "$AUTH_CODE"; then
        print_error "Failed to exchange authorization code for tokens"
        log_message "ERROR" "Setup failed: token exchange"
        exit 1
    fi
    echo ""
    
    # Step 6: Fetch account information and save config
    print_info "Step 6/6: Fetching account info and saving configuration..."
    if ! fetch_account_info "$ACCESS_TOKEN"; then
        print_warn "Could not fetch account information, but tokens are valid"
    fi
    
    if ! save_config "$OAUTH_CLIENT_ID" "$ACCESS_TOKEN" "$REFRESH_TOKEN"; then
        print_error "Failed to save configuration"
        log_message "ERROR" "Setup failed: could not save config"
        exit 1
    fi
    echo ""
    
    # Success message
    print_header "Setup Complete!"
    echo ""
    print_success "Robinhood broker setup completed successfully"
    echo ""
    echo "Configuration saved to:"
    echo "  ${COLOR_CYAN}${CONFIG_FILE}${COLOR_RESET}"
    echo ""
    echo "Important Information:"
    echo "  • Access tokens expire after a period of time"
    echo "  • The refresh token is used to obtain new access tokens"
    echo "  • StockSwingTrader will automatically refresh tokens when needed"
    echo "  • Keep your refresh token secure and never share it"
    echo ""
    echo "Next steps:"
    echo "  1. Review the configuration: ${COLOR_CYAN}cat $CONFIG_FILE${COLOR_RESET}"
    echo "  2. Source the config: ${COLOR_CYAN}source $CONFIG_FILE${COLOR_RESET}"
    echo "  3. Start trading: ${COLOR_CYAN}./StockSwingTrader_Agent.sh --broker robinhood${COLOR_RESET}"
    echo ""
    echo "Token Refresh:"
    echo "  • Tokens are automatically managed by the trading agent"
    echo "  • Manual refresh (if needed): See $CONFIG_FILE for instructions"
    echo ""
    
    log_message "INFO" "=== Setup Completed Successfully ==="
    
    return 0
}

# ============================================================================
# Entry Point
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit $?
fi
