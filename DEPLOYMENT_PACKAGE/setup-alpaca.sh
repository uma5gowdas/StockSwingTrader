#!/bin/bash
################################################################################
# StockSwingTrader: Alpaca Broker Setup Wizard
################################################################################
# Purpose: Interactive setup wizard for Alpaca broker configuration
#
# Features:
#   - Prompt for API Key and Secret
#   - Validate credentials with test API call
#   - Fetch account information (account number, buying power, positions)
#   - Set account ID in configuration
#   - Test market data access with sample symbol
#   - Save validated config to config.alpaca.env
#   - Retry logic for network issues
#   - Clear success/error messages
#
# Usage:
#   ./setup-alpaca.sh                          # Interactive setup
#   ALPACA_API_KEY=xxx ALPACA_SECRET_KEY=yyy ./setup-alpaca.sh  # Pre-filled
#
# Output:
#   Creates: config.alpaca.env with validated credentials
#   Shows: Account details and trading status
#
# Requirements:
#   - bash 4.0+
#   - curl (for API calls)
#   - jq (optional, for pretty JSON output)
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
CONFIG_FILE="${SCRIPT_DIR}/config.alpaca.env"
LOG_FILE="${SCRIPT_DIR}/logs/setup-alpaca.log"
BACKUP_DIR="${SCRIPT_DIR}/backups"

# API Configuration
ALPACA_API_BASE_URL="https://paper-api.alpaca.markets"
ALPACA_API_VERSION="v2"

# Retry configuration
MAX_RETRIES=3
INITIAL_BACKOFF=1
BACKOFF_MULTIPLIER=2

# Timeouts (seconds)
TIMEOUT_CONNECT=5
TIMEOUT_TOTAL=15
TEST_SYMBOL="AAPL"

# Color codes for output
readonly COLOR_RESET='\033[0m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_GREEN='\033[32m'
readonly COLOR_YELLOW='\033[33m'
readonly COLOR_RED='\033[31m'
readonly COLOR_BLUE='\033[34m'
readonly COLOR_CYAN='\033[36m'

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

# Validate API Key format (should start with PK and be alphanumeric)
validate_api_key_format() {
    local key="$1"
    
    if [[ ! $key =~ ^[A-Za-z0-9_-]+$ ]]; then
        return 1
    fi
    
    if (( ${#key} < 10 )); then
        return 1
    fi
    
    return 0
}

# Validate Secret Key format (should be alphanumeric)
validate_secret_key_format() {
    local secret="$1"
    
    if [[ ! $secret =~ ^[A-Za-z0-9_-]+$ ]]; then
        return 1
    fi
    
    if (( ${#secret} < 10 )); then
        return 1
    fi
    
    return 0
}

# Make API call with retry logic
make_api_call() {
    local method="$1"
    local endpoint="$2"
    local api_key="$3"
    local secret_key="$4"
    local data="${5:-}"
    
    local url="${ALPACA_API_BASE_URL}/${ALPACA_API_VERSION}${endpoint}"
    local retry_count=0
    local backoff=$INITIAL_BACKOFF
    
    while (( retry_count < MAX_RETRIES )); do
        log_message "DEBUG" "API Call: $method $endpoint (attempt $((retry_count + 1))/$MAX_RETRIES)"
        
        if [[ -n "$data" ]]; then
            local response=$(curl -s \
                --connect-timeout "$TIMEOUT_CONNECT" \
                --max-time "$TIMEOUT_TOTAL" \
                -X "$method" \
                -H "APCA-API-KEY-ID: $api_key" \
                -H "APCA-API-SECRET-KEY: $secret_key" \
                -H "Content-Type: application/json" \
                -d "$data" \
                "$url" 2>&1)
        else
            local response=$(curl -s \
                --connect-timeout "$TIMEOUT_CONNECT" \
                --max-time "$TIMEOUT_TOTAL" \
                -X "$method" \
                -H "APCA-API-KEY-ID: $api_key" \
                -H "APCA-API-SECRET-KEY: $secret_key" \
                "$url" 2>&1)
        fi
        
        local http_code=$(echo "$response" | tail -n1)
        
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
# Credential Validation
# ============================================================================

validate_alpaca_credentials() {
    local api_key="$1"
    local secret_key="$2"
    
    print_info "Validating Alpaca credentials..."
    log_message "INFO" "Validating credentials for API key: ${api_key:0:10}..."
    
    # Test API call to get account info
    local response=$(make_api_call "GET" "/account" "$api_key" "$secret_key")
    
    if [[ -z "$response" ]]; then
        print_error "Failed to reach Alpaca API. Check your internet connection and API endpoints."
        log_message "ERROR" "API response empty"
        return 1
    fi
    
    # Check for error response (common patterns)
    if echo "$response" | grep -q '"error"\|"message"\|"invalid"\|401\|403\|404'; then
        if echo "$response" | grep -q "401\|Unauthorized\|invalid credentials"; then
            print_error "Authentication failed. Please verify your API Key and Secret Key are correct."
            log_message "ERROR" "Authentication failed: $response"
            return 1
        else
            print_warn "Received error response: $response"
            log_message "ERROR" "API error response: $response"
            return 1
        fi
    fi
    
    # Extract account ID from response
    local account_id=$(echo "$response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    
    if [[ -z "$account_id" ]]; then
        # Try alternative parsing
        account_id=$(echo "$response" | grep -o 'id.*' | head -1)
        if [[ -z "$account_id" ]]; then
            print_warn "Could not extract account ID from response"
            log_message "WARN" "Account ID extraction failed"
            return 1
        fi
    fi
    
    print_success "Credentials validated successfully"
    log_message "INFO" "Credentials validation successful, account_id: $account_id"
    
    # Export for use in other functions
    ALPACA_ACCOUNT_ID="$account_id"
    return 0
}

# ============================================================================
# Account Information Retrieval
# ============================================================================

fetch_account_info() {
    local api_key="$1"
    local secret_key="$2"
    
    print_info "Fetching account information..."
    log_message "INFO" "Fetching account info from Alpaca"
    
    local response=$(make_api_call "GET" "/account" "$api_key" "$secret_key")
    
    if [[ -z "$response" ]]; then
        print_error "Failed to fetch account information"
        log_message "ERROR" "Failed to fetch account info"
        return 1
    fi
    
    print_success "Account information retrieved"
    
    # Parse and display account details
    echo -e "\n${COLOR_BOLD}Account Details:${COLOR_RESET}"
    
    # Account number
    local account_num=$(echo "$response" | grep -o '"account_number":"[^"]*"' | cut -d'"' -f4)
    [[ -n "$account_num" ]] && echo "  Account Number:  $account_num" || echo "  Account Number:  (not available)"
    
    # Buying power
    local buying_power=$(echo "$response" | grep -o '"buying_power":"[^"]*"' | cut -d'"' -f4)
    [[ -n "$buying_power" ]] && echo "  Buying Power:    \$${buying_power}" || echo "  Buying Power:    (not available)"
    
    # Cash
    local cash=$(echo "$response" | grep -o '"cash":"[^"]*"' | cut -d'"' -f4)
    [[ -n "$cash" ]] && echo "  Cash:            \$${cash}" || echo "  Cash:            (not available)"
    
    # Portfolio value
    local portfolio_value=$(echo "$response" | grep -o '"portfolio_value":"[^"]*"' | cut -d'"' -f4)
    [[ -n "$portfolio_value" ]] && echo "  Portfolio Value: \$${portfolio_value}" || echo "  Portfolio Value: (not available)"
    
    # Equity
    local equity=$(echo "$response" | grep -o '"equity":"[^"]*"' | cut -d'"' -f4)
    [[ -n "$equity" ]] && echo "  Equity:          \$${equity}" || echo "  Equity:          (not available)"
    
    # Trading status
    local trading_enabled=$(echo "$response" | grep -o '"trading_blocked":false' | head -1)
    if [[ -n "$trading_enabled" ]]; then
        echo "  Trading Status:  ${COLOR_GREEN}Enabled${COLOR_RESET}"
    else
        echo "  Trading Status:  ${COLOR_YELLOW}Blocked or Paper Trading${COLOR_RESET}"
    fi
    
    echo ""
    
    # Store info for later use
    ACCOUNT_INFO="$response"
    return 0
}

# ============================================================================
# Market Data Testing
# ============================================================================

test_market_data_access() {
    local api_key="$1"
    local secret_key="$2"
    
    print_info "Testing market data access with symbol: $TEST_SYMBOL..."
    log_message "INFO" "Testing market data with symbol: $TEST_SYMBOL"
    
    local response=$(make_api_call "GET" "/last/quote/$TEST_SYMBOL?feed=iex" "$api_key" "$secret_key")
    
    if [[ -z "$response" ]]; then
        print_warn "Could not fetch market data (API may have rate limits or data access issues)"
        log_message "WARN" "Market data test failed"
        return 1
    fi
    
    # Check for error
    if echo "$response" | grep -q '"error"\|"message"'; then
        print_warn "Market data access may be limited (common with paper trading)"
        log_message "WARN" "Market data access limited: $response"
        return 0  # Not a fatal error
    fi
    
    # Try to parse price data
    local price=$(echo "$response" | grep -o '"last_quote":{"ask":"[^"]*' | cut -d'"' -f4)
    if [[ -n "$price" ]]; then
        print_success "Market data access verified (Last quote for $TEST_SYMBOL: \$$price)"
        log_message "INFO" "Market data test successful"
        return 0
    else
        print_success "Market data access verified"
        log_message "INFO" "Market data test successful"
        return 0
    fi
}

# ============================================================================
# Configuration File Management
# ============================================================================

create_config_backup() {
    if [[ -f "$CONFIG_FILE" ]]; then
        print_info "Backing up existing configuration..."
        [[ ! -d "$BACKUP_DIR" ]] && mkdir -p "$BACKUP_DIR"
        
        local backup_file="${BACKUP_DIR}/config.alpaca.env.backup.$(date '+%Y%m%d_%H%M%S')"
        cp "$CONFIG_FILE" "$backup_file"
        print_success "Configuration backed up to: $backup_file"
        log_message "INFO" "Created backup: $backup_file"
    fi
}

save_config() {
    local api_key="$1"
    local secret_key="$2"
    
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
# Alpaca Broker Configuration
# Generated by: setup-alpaca.sh
# Timestamp: SETUP_TIMESTAMP
################################################################################

# Alpaca API Credentials (validated)
export ALPACA_ENABLED=true
export ALPACA_API_KEY="API_KEY_PLACEHOLDER"
export ALPACA_SECRET_KEY="SECRET_KEY_PLACEHOLDER"

# Alpaca API Configuration
export ALPACA_BASE_URL="https://paper-api.alpaca.markets"
export ALPACA_API_VERSION="v2"
export ALPACA_TIMEOUT_SECONDS=15
export ALPACA_MAX_RETRIES=3

# Trading Configuration
export ALPACA_MODE="paper"                  # Use 'paper' for paper trading, 'live' for real trading
export ALPACA_MIN_POSITION_SIZE=100         # Minimum shares to hold
export ALPACA_MAX_POSITION_SIZE=1000        # Maximum shares per trade
export ALPACA_AUTO_TRADE=false              # Auto-execute trades on strong signals
export ALPACA_STRONG_BUY_THRESHOLD=80       # Confluence score threshold for auto-buy
export ALPACA_STRONG_SELL_THRESHOLD=20      # Confluence score threshold for auto-sell
export ALPACA_LOG_ALL_TRADES=true           # Log all trade attempts

# Logging
export ALPACA_LOG_FILE="logs/alpaca.log"
export ALPACA_DEBUG=false

# Account Information
export ALPACA_ACCOUNT_ID="ACCOUNT_ID_PLACEHOLDER"

# Status
export SETUP_DATE="SETUP_TIMESTAMP"
export SETUP_STATUS="completed"

EOF
    
    # Replace placeholders
    sed -i '' "s|API_KEY_PLACEHOLDER|$api_key|g" "$CONFIG_FILE"
    sed -i '' "s|SECRET_KEY_PLACEHOLDER|$secret_key|g" "$CONFIG_FILE"
    sed -i '' "s|ACCOUNT_ID_PLACEHOLDER|${ALPACA_ACCOUNT_ID:-unknown}|g" "$CONFIG_FILE"
    sed -i '' "s|SETUP_TIMESTAMP|$TIMESTAMP|g" "$CONFIG_FILE"
    
    # Secure permissions
    chmod 600 "$CONFIG_FILE"
    
    print_success "Configuration saved successfully"
    log_message "INFO" "Configuration saved to $CONFIG_FILE with secure permissions (600)"
    
    return 0
}

# ============================================================================
# Interactive Setup
# ============================================================================

prompt_for_credentials() {
    print_header "Alpaca API Credentials"
    
    print_info "Please provide your Alpaca API credentials."
    print_info "Get them from: https://app.alpaca.markets/paper/dashboard/settings/api"
    echo ""
    
    local api_key="${ALPACA_API_KEY:-}"
    local secret_key="${ALPACA_SECRET_KEY:-}"
    
    # Prompt for API Key
    if [[ -z "$api_key" ]]; then
        while [[ -z "$api_key" ]]; do
            echo -e -n "${COLOR_YELLOW}? Enter Alpaca API Key${COLOR_RESET}: " >&2
            read -rs api_key
            echo ""
            
            if ! validate_api_key_format "$api_key"; then
                print_error "Invalid API Key format. API Key should be at least 10 characters."
                api_key=""
                continue
            fi
        done
    else
        print_info "Using pre-filled API Key"
    fi
    
    # Prompt for Secret Key
    if [[ -z "$secret_key" ]]; then
        while [[ -z "$secret_key" ]]; do
            echo -e -n "${COLOR_YELLOW}? Enter Alpaca Secret Key${COLOR_RESET}: " >&2
            read -rs secret_key
            echo ""
            
            if ! validate_secret_key_format "$secret_key"; then
                print_error "Invalid Secret Key format. Secret Key should be at least 10 characters."
                secret_key=""
                continue
            fi
        done
    else
        print_info "Using pre-filled Secret Key"
    fi
    
    # Return credentials
    SETUP_API_KEY="$api_key"
    SETUP_SECRET_KEY="$secret_key"
}

# ============================================================================
# Main Setup Flow
# ============================================================================

main() {
    print_header "StockSwingTrader: Alpaca Setup Wizard"
    
    log_message "INFO" "=== Setup Started ==="
    log_message "INFO" "Script: $SCRIPT_NAME"
    log_message "INFO" "Timestamp: $TIMESTAMP"
    
    # Step 1: Get credentials
    print_info "Step 1/5: Collecting credentials..."
    prompt_for_credentials
    echo ""
    
    # Step 2: Validate credentials
    print_info "Step 2/5: Validating credentials..."
    if ! validate_alpaca_credentials "$SETUP_API_KEY" "$SETUP_SECRET_KEY"; then
        print_error "Credential validation failed. Please verify your API Key and Secret Key."
        log_message "ERROR" "Setup failed: credential validation"
        exit 1
    fi
    echo ""
    
    # Step 3: Fetch account information
    print_info "Step 3/5: Fetching account information..."
    if ! fetch_account_info "$SETUP_API_KEY" "$SETUP_SECRET_KEY"; then
        print_warn "Could not fetch full account information, continuing with setup..."
    fi
    echo ""
    
    # Step 4: Test market data access
    print_info "Step 4/5: Testing market data access..."
    if ! test_market_data_access "$SETUP_API_KEY" "$SETUP_SECRET_KEY"; then
        print_warn "Market data test failed, but this may be expected with paper trading..."
    fi
    echo ""
    
    # Step 5: Save configuration
    print_info "Step 5/5: Saving configuration..."
    if ! save_config "$SETUP_API_KEY" "$SETUP_SECRET_KEY"; then
        print_error "Failed to save configuration"
        log_message "ERROR" "Setup failed: could not save config"
        exit 1
    fi
    echo ""
    
    # Success message
    print_header "Setup Complete!"
    echo ""
    print_success "Alpaca broker setup completed successfully"
    echo ""
    echo "Configuration saved to:"
    echo "  ${COLOR_CYAN}${CONFIG_FILE}${COLOR_RESET}"
    echo ""
    echo "Next steps:"
    echo "  1. Review the configuration: ${COLOR_CYAN}cat $CONFIG_FILE${COLOR_RESET}"
    echo "  2. Source the config: ${COLOR_CYAN}source $CONFIG_FILE${COLOR_RESET}"
    echo "  3. Start trading: ${COLOR_CYAN}./StockSwingTrader_Agent.sh --broker alpaca${COLOR_RESET}"
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
