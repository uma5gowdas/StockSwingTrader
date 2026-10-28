#!/bin/bash
# ============================================================================
# StockSwingTrader: Robinhood OAuth Token Management Module
# ============================================================================
# Manages OAuth2 authorization flow, token storage, encryption, and refresh
# Stores encrypted tokens in ~/.robinhood_tokens.json
# Automatically refreshes expired tokens before API calls
# ============================================================================

set -o pipefail

# ============================================================================
# Module Configuration & Globals
# ============================================================================

# OAuth Configuration
ROBINHOOD_OAUTH_BASE_URL="${ROBINHOOD_OAUTH_BASE_URL:-https://api.robinhood.com}"
ROBINHOOD_CLIENT_ID="${ROBINHOOD_CLIENT_ID:-}"
ROBINHOOD_CLIENT_SECRET="${ROBINHOOD_CLIENT_SECRET:-}"
ROBINHOOD_OAUTH_REDIRECT_URI="${ROBINHOOD_OAUTH_REDIRECT_URI:-http://localhost:8888/callback}"

# Token Storage
ROBINHOOD_TOKENS_FILE="${HOME}/.robinhood_tokens.json"
ROBINHOOD_TOKEN_ENCRYPTION_ENABLED="${ROBINHOOD_TOKEN_ENCRYPTION_ENABLED:-true}"

# Logging & Debug
ROBINHOOD_LOG_FILE="${ROBINHOOD_LOG_FILE:-logs/robinhood.log}"
ROBINHOOD_DEBUG="${ROBINHOOD_DEBUG:-false}"

# OAuth Flow Timeouts
ROBINHOOD_OAUTH_BROWSER_TIMEOUT=300  # 5 minutes for user to complete browser flow
ROBINHOOD_OAUTH_SERVER_TIMEOUT=310   # 5+ minutes for local callback server
ROBINHOOD_TOKEN_BUFFER_SECONDS=300   # Treat token as expired if < 5 min remaining

# Token Refresh
ROBINHOOD_TOKEN_REFRESH_RETRIES=1
ROBINHOOD_TOKEN_REFRESH_TIMEOUT=5

# ============================================================================
# Helper: Logging Functions
# ============================================================================

# Initialize logging directory
robinhood_init_logging() {
    local log_dir=$(dirname "$ROBINHOOD_LOG_FILE")
    [[ ! -d "$log_dir" ]] && mkdir -p "$log_dir"
    touch "$ROBINHOOD_LOG_FILE"
}

# Log message with timestamp
robinhood_log() {
    local level="$1"
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    robinhood_init_logging
    echo "[${timestamp}] [${level}] ${message}" >> "$ROBINHOOD_LOG_FILE"
    
    if [[ "$ROBINHOOD_DEBUG" == "true" ]]; then
        echo "[${level}] ${message}" >&2
    fi
}

# ============================================================================
# Helper: Encryption & Decryption
# ============================================================================

# Derive encryption key from user@hostname
# Returns: 64-character hex string (256-bit key)
robinhood_oauth_derive_key() {
    local key_material="${USER}@$(hostname)"
    echo -n "$key_material" | sha256sum | cut -d' ' -f1
}

# Generate random IV for encryption
# Returns: 32-character hex string (16-byte IV)
robinhood_oauth_generate_iv() {
    openssl rand -hex 16
}

# Encrypt plaintext JSON with AES-256-CBC
# Args: PLAINTEXT_JSON
# Returns: IV:CIPHERTEXT (hex:base64)
robinhood_oauth_encrypt_tokens() {
    local plaintext="$1"
    local key=$(robinhood_oauth_derive_key)
    local iv=$(robinhood_oauth_generate_iv)
    
    # Encrypt with OpenSSL
    local ciphertext=$(echo -n "$plaintext" | \
        openssl enc -aes-256-cbc -K "$key" -iv "$iv" -e -a 2>/dev/null)
    
    if [[ -z "$ciphertext" ]]; then
        robinhood_log "ERROR" "Encryption failed"
        return 1
    fi
    
    # Return IV:CIPHERTEXT
    echo "${iv}:${ciphertext}"
    return 0
}

# Decrypt ciphertext with AES-256-CBC
# Args: ENCRYPTED_DATA (IV:CIPHERTEXT format)
# Returns: PLAINTEXT_JSON
robinhood_oauth_decrypt_tokens() {
    local encrypted="$1"
    local key=$(robinhood_oauth_derive_key)
    
    # Parse IV and ciphertext
    local iv="${encrypted%%:*}"
    local ciphertext="${encrypted#*:}"
    
    # Validate format
    if [[ -z "$iv" ]] || [[ -z "$ciphertext" ]]; then
        robinhood_log "ERROR" "Invalid encrypted token format"
        return 1
    fi
    
    # Decrypt
    local plaintext=$(echo -n "$ciphertext" | \
        openssl enc -aes-256-cbc -K "$key" -iv "$iv" -d -a 2>/dev/null)
    
    if [[ -z "$plaintext" ]]; then
        robinhood_log "ERROR" "Decryption failed"
        return 1
    fi
    
    echo "$plaintext"
    return 0
}

# ============================================================================
# Helper: Token File I/O
# ============================================================================

# Load tokens from encrypted storage
# Sets global: ROBINHOOD_ACCESS_TOKEN, ROBINHOOD_REFRESH_TOKEN, ROBINHOOD_TOKEN_EXPIRES_AT
# Returns: 0 on success, 1 if no token file exists
robinhood_oauth_load_tokens() {
    if [[ ! -f "$ROBINHOOD_TOKENS_FILE" ]]; then
        robinhood_log "WARN" "No token file found at $ROBINHOOD_TOKENS_FILE"
        return 1
    fi
    
    # Check file permissions
    local file_perms=$(stat -f '%A' "$ROBINHOOD_TOKENS_FILE" 2>/dev/null || stat -c '%a' "$ROBINHOOD_TOKENS_FILE" 2>/dev/null)
    if [[ "$file_perms" != "600" ]]; then
        robinhood_log "WARN" "Token file permissions are $file_perms, should be 600. Fixing..."
        chmod 0600 "$ROBINHOOD_TOKENS_FILE"
    fi
    
    # Read encrypted tokens
    local encrypted=$(cat "$ROBINHOOD_TOKENS_FILE" 2>/dev/null)
    if [[ -z "$encrypted" ]]; then
        robinhood_log "ERROR" "Token file is empty"
        return 1
    fi
    
    # Decrypt
    local plaintext
    plaintext=$(robinhood_oauth_decrypt_tokens "$encrypted") || return 1
    
    # Parse JSON
    if command -v jq &>/dev/null; then
        ROBINHOOD_ACCESS_TOKEN=$(echo "$plaintext" | jq -r '.access_token // empty')
        ROBINHOOD_REFRESH_TOKEN=$(echo "$plaintext" | jq -r '.refresh_token // empty')
        ROBINHOOD_TOKEN_EXPIRES_AT=$(echo "$plaintext" | jq -r '.expires_at // empty')
    else
        # Fallback: basic grep if jq not available
        ROBINHOOD_ACCESS_TOKEN=$(echo "$plaintext" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
        ROBINHOOD_REFRESH_TOKEN=$(echo "$plaintext" | grep -o '"refresh_token":"[^"]*"' | cut -d'"' -f4)
        ROBINHOOD_TOKEN_EXPIRES_AT=$(echo "$plaintext" | grep -o '"expires_at":"[^"]*"' | cut -d'"' -f4)
    fi
    
    if [[ -z "$ROBINHOOD_ACCESS_TOKEN" ]]; then
        robinhood_log "ERROR" "Failed to parse access token from token file"
        return 1
    fi
    
    robinhood_log "INFO" "Tokens loaded from $ROBINHOOD_TOKENS_FILE"
    return 0
}

# Save tokens to encrypted storage
# Args: ACCESS_TOKEN, REFRESH_TOKEN, EXPIRES_IN (seconds from now)
# Returns: 0 on success, 1 on failure
robinhood_oauth_save_tokens() {
    local access_token="$1"
    local refresh_token="$2"
    local expires_in="$3"
    
    if [[ -z "$access_token" ]] || [[ -z "$refresh_token" ]]; then
        robinhood_log "ERROR" "Cannot save tokens: missing access or refresh token"
        return 1
    fi
    
    # Calculate expiration timestamp
    local expires_at=$(($(date +%s) + expires_in))
    
    # Build token JSON
    local token_json=$(cat <<EOF
{
  "access_token": "$access_token",
  "refresh_token": "$refresh_token",
  "expires_at": "$expires_at",
  "saved_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)
    
    # Encrypt and save
    local encrypted
    encrypted=$(robinhood_oauth_encrypt_tokens "$token_json") || return 1
    
    # Write to file
    echo "$encrypted" > "$ROBINHOOD_TOKENS_FILE" 2>/dev/null || {
        robinhood_log "ERROR" "Failed to write token file: $ROBINHOOD_TOKENS_FILE"
        return 1
    }
    
    # Set restrictive permissions
    chmod 0600 "$ROBINHOOD_TOKENS_FILE"
    
    # Clear sensitive variables from memory
    unset access_token refresh_token token_json
    
    robinhood_log "INFO" "Tokens saved to $ROBINHOOD_TOKENS_FILE (expires at $expires_at)"
    return 0
}

# Delete stored tokens (logout)
# Returns: 0 on success
robinhood_oauth_clear_tokens() {
    if [[ -f "$ROBINHOOD_TOKENS_FILE" ]]; then
        rm -f "$ROBINHOOD_TOKENS_FILE"
        robinhood_log "INFO" "Tokens cleared"
    fi
    return 0
}

# ============================================================================
# Helper: Token Expiration Check
# ============================================================================

# Check if token is expired or about to expire
# Uses ROBINHOOD_TOKEN_EXPIRES_AT (must be loaded first)
# Returns: 0 if expired, 1 if valid
robinhood_oauth_is_token_expired() {
    if [[ -z "$ROBINHOOD_TOKEN_EXPIRES_AT" ]]; then
        robinhood_log "WARN" "Token expiration time not set"
        return 0  # Treat as expired
    fi
    
    local now=$(date +%s)
    local buffer=$ROBINHOOD_TOKEN_BUFFER_SECONDS
    local expiry_threshold=$((ROBINHOOD_TOKEN_EXPIRES_AT - buffer))
    
    if [[ $now -ge $expiry_threshold ]]; then
        robinhood_log "DEBUG" "Token expired or expiring soon (expires at $ROBINHOOD_TOKEN_EXPIRES_AT, now $now)"
        return 0  # Expired
    fi
    
    robinhood_log "DEBUG" "Token valid (expires at $ROBINHOOD_TOKEN_EXPIRES_AT, now $now)"
    return 1  # Valid
}

# ============================================================================
# OAuth Flow: Generate Authorization URL
# ============================================================================

# Generate OAuth authorization URL for user to visit
# Args: None
# Returns: Authorization URL string
robinhood_oauth_get_auth_url() {
    if [[ -z "$ROBINHOOD_CLIENT_ID" ]]; then
        robinhood_log "ERROR" "ROBINHOOD_CLIENT_ID not set"
        return 1
    fi
    
    # Generate random state parameter for CSRF protection
    local state=$(openssl rand -hex 32)
    export ROBINHOOD_OAUTH_STATE="$state"
    
    # Build authorization URL
    local auth_url="${ROBINHOOD_OAUTH_BASE_URL}/oauth2/authorize/"
    auth_url+="?client_id=${ROBINHOOD_CLIENT_ID}"
    auth_url+="&response_type=code"
    auth_url+="&redirect_uri=$(echo -n "$ROBINHOOD_OAUTH_REDIRECT_URI" | sed 's/ /%20/g')"
    auth_url+="&scope=read%20write"
    auth_url+="&state=${state}"
    
    robinhood_log "INFO" "Generated OAuth authorization URL"
    echo "$auth_url"
    return 0
}

# ============================================================================
# OAuth Flow: Exchange Authorization Code for Tokens
# ============================================================================

# Exchange authorization code for access and refresh tokens
# Args: CODE
# Returns: 0 on success, 1 on failure
robinhood_oauth_exchange_code() {
    local code="$1"
    
    if [[ -z "$code" ]]; then
        robinhood_log "ERROR" "Authorization code is required"
        return 1
    fi
    
    if [[ -z "$ROBINHOOD_CLIENT_ID" ]] || [[ -z "$ROBINHOOD_CLIENT_SECRET" ]]; then
        robinhood_log "ERROR" "Missing OAuth credentials (CLIENT_ID or CLIENT_SECRET)"
        return 1
    fi
    
    # Exchange code for tokens
    local token_endpoint="${ROBINHOOD_OAUTH_BASE_URL}/oauth2/token/"
    local payload=$(cat <<EOF
{
  "grant_type": "authorization_code",
  "code": "$code",
  "client_id": "$ROBINHOOD_CLIENT_ID",
  "client_secret": "$ROBINHOOD_CLIENT_SECRET",
  "redirect_uri": "$ROBINHOOD_OAUTH_REDIRECT_URI"
}
EOF
)
    
    robinhood_log "DEBUG" "Exchanging authorization code for tokens"
    
    local response
    response=$(curl -s -X POST \
        --connect-timeout 10 \
        -m "$ROBINHOOD_TOKEN_REFRESH_TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$token_endpoint" 2>/dev/null) || {
        robinhood_log "ERROR" "Token exchange request failed (curl error)"
        return 1
    }
    
    robinhood_log "DEBUG" "Token exchange response: $response"
    
    # Parse response
    local access_token
    local refresh_token
    local expires_in
    
    if command -v jq &>/dev/null; then
        access_token=$(echo "$response" | jq -r '.access_token // empty')
        refresh_token=$(echo "$response" | jq -r '.refresh_token // empty')
        expires_in=$(echo "$response" | jq -r '.expires_in // 86400')
        
        local error=$(echo "$response" | jq -r '.error // empty')
        if [[ -n "$error" ]]; then
            robinhood_log "ERROR" "Token exchange error: $error"
            return 1
        fi
    else
        # Fallback parsing
        access_token=$(echo "$response" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
        refresh_token=$(echo "$response" | grep -o '"refresh_token":"[^"]*"' | cut -d'"' -f4)
        expires_in=$(echo "$response" | grep -o '"expires_in":[0-9]*' | cut -d':' -f2)
        expires_in="${expires_in:-86400}"
    fi
    
    if [[ -z "$access_token" ]] || [[ -z "$refresh_token" ]]; then
        robinhood_log "ERROR" "Failed to parse tokens from response"
        return 1
    fi
    
    # Save tokens
    robinhood_oauth_save_tokens "$access_token" "$refresh_token" "$expires_in" || return 1
    
    robinhood_log "INFO" "Authorization code exchanged successfully for tokens"
    return 0
}

# ============================================================================
# OAuth Flow: Refresh Expired Token
# ============================================================================

# Refresh access token using refresh token
# Returns: 0 on success, 1 on failure
robinhood_oauth_refresh_token() {
    if [[ -z "$ROBINHOOD_REFRESH_TOKEN" ]]; then
        robinhood_log "ERROR" "Refresh token not available"
        return 1
    fi
    
    if [[ -z "$ROBINHOOD_CLIENT_ID" ]] || [[ -z "$ROBINHOOD_CLIENT_SECRET" ]]; then
        robinhood_log "ERROR" "Missing OAuth credentials for token refresh"
        return 1
    fi
    
    local token_endpoint="${ROBINHOOD_OAUTH_BASE_URL}/oauth2/token/"
    local payload=$(cat <<EOF
{
  "grant_type": "refresh_token",
  "refresh_token": "$ROBINHOOD_REFRESH_TOKEN",
  "client_id": "$ROBINHOOD_CLIENT_ID",
  "client_secret": "$ROBINHOOD_CLIENT_SECRET"
}
EOF
)
    
    robinhood_log "INFO" "Refreshing access token"
    
    local response
    response=$(curl -s -X POST \
        --connect-timeout 10 \
        -m "$ROBINHOOD_TOKEN_REFRESH_TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$token_endpoint" 2>/dev/null) || {
        robinhood_log "ERROR" "Token refresh request failed (curl error)"
        return 1
    }
    
    robinhood_log "DEBUG" "Token refresh response: $response"
    
    # Parse response
    local access_token
    local expires_in
    
    if command -v jq &>/dev/null; then
        access_token=$(echo "$response" | jq -r '.access_token // empty')
        expires_in=$(echo "$response" | jq -r '.expires_in // 86400')
        
        local error=$(echo "$response" | jq -r '.error // empty')
        if [[ -n "$error" ]]; then
            robinhood_log "ERROR" "Token refresh error: $error"
            robinhood_oauth_clear_tokens
            return 1
        fi
    else
        access_token=$(echo "$response" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
        expires_in=$(echo "$response" | grep -o '"expires_in":[0-9]*' | cut -d':' -f2)
        expires_in="${expires_in:-86400}"
    fi
    
    if [[ -z "$access_token" ]]; then
        robinhood_log "ERROR" "Failed to parse new access token"
        return 1
    fi
    
    # Update token storage with new access token, keep refresh token
    robinhood_oauth_save_tokens "$access_token" "$ROBINHOOD_REFRESH_TOKEN" "$expires_in" || return 1
    
    robinhood_log "INFO" "Access token refreshed successfully"
    return 0
}

# ============================================================================
# Helper: Get Authorization Header
# ============================================================================

# Generate Authorization header value
# Returns: "Bearer <access_token>"
robinhood_oauth_get_auth_header() {
    if [[ -z "$ROBINHOOD_ACCESS_TOKEN" ]]; then
        robinhood_log "ERROR" "Access token not available"
        return 1
    fi
    
    echo "Bearer $ROBINHOOD_ACCESS_TOKEN"
    return 0
}

# ============================================================================
# Public API: Setup & Authorization
# ============================================================================

# Initiate OAuth browser login flow
# 1. Generates authorization URL
# 2. Opens browser for user approval
# 3. Stores code_verifier temporarily (PKCE support)
# 4. Waits for callback with auth code
# Returns: 0 on success, 1 on failure
robinhood_setup_oauth() {
    robinhood_log "INFO" "Starting OAuth setup flow"
    
    if [[ -z "$ROBINHOOD_CLIENT_ID" ]]; then
        robinhood_log "ERROR" "ROBINHOOD_CLIENT_ID environment variable not set"
        return 1
    fi
    
    # Generate authorization URL
    local auth_url
    auth_url=$(robinhood_oauth_get_auth_url) || return 1
    
    robinhood_log "INFO" "Opening browser for authorization: $auth_url"
    echo "Opening Robinhood login in browser..."
    echo "Authorization URL: $auth_url"
    
    # Try to open in browser
    if command -v open &>/dev/null; then
        open "$auth_url" 2>/dev/null
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$auth_url" 2>/dev/null
    fi
    
    echo ""
    echo "Please complete the authorization in your browser."
    echo "After approving, you will be redirected to a callback URL."
    echo ""
    read -p "Enter the authorization code from the callback URL: " auth_code
    
    if [[ -z "$auth_code" ]]; then
        robinhood_log "ERROR" "No authorization code provided"
        return 1
    fi
    
    # Exchange code for tokens
    robinhood_oauth_exchange_code "$auth_code" || return 1
    
    robinhood_log "INFO" "OAuth setup completed successfully"
    echo "✓ Authorization successful. Tokens saved to $ROBINHOOD_TOKENS_FILE"
    return 0
}

# ============================================================================
# Public API: Token Exchange
# ============================================================================

# Exchange authorization code for access and refresh tokens
# Args: AUTH_CODE
# Returns: JSON with {access_token, refresh_token, expires_at, token_type}
robinhood_request_access_token() {
    local auth_code="$1"
    
    if [[ -z "$auth_code" ]]; then
        robinhood_log "ERROR" "Authorization code is required"
        return 1
    fi
    
    robinhood_oauth_exchange_code "$auth_code" || return 1
    
    # Return token info as JSON
    robinhood_oauth_load_tokens || return 1
    
    local expires_at="${ROBINHOOD_TOKEN_EXPIRES_AT:-0}"
    local token_type="Bearer"
    
    cat <<EOF
{
  "access_token": "$ROBINHOOD_ACCESS_TOKEN",
  "refresh_token": "$ROBINHOOD_REFRESH_TOKEN",
  "expires_at": $expires_at,
  "token_type": "$token_type"
}
EOF
    return 0
}

# ============================================================================
# Public API: Token Refresh
# ============================================================================

# Check token expiration and refresh if needed
# Auto-runs before every API call that needs auth
# Returns: 0 if token is valid (refreshed or already valid), 1 on failure
robinhood_refresh_token_if_needed() {
    # Load current tokens
    robinhood_oauth_load_tokens
    
    # Check if expired
    if robinhood_oauth_is_token_expired; then
        robinhood_log "INFO" "Token expired, refreshing..."
        
        # Attempt refresh with retries
        local attempt=1
        while [[ $attempt -le $ROBINHOOD_TOKEN_REFRESH_RETRIES ]]; do
            if robinhood_oauth_refresh_token; then
                robinhood_log "INFO" "Token refreshed successfully"
                return 0
            fi
            
            if [[ $attempt -lt $ROBINHOOD_TOKEN_REFRESH_RETRIES ]]; then
                local wait_time=$((2 ** (attempt - 1)))
                robinhood_log "WARN" "Token refresh attempt $attempt failed, retrying in ${wait_time}s..."
                sleep "$wait_time"
            fi
            
            ((attempt++))
        done
        
        robinhood_log "ERROR" "Token refresh failed after $ROBINHOOD_TOKEN_REFRESH_RETRIES attempts"
        return 1
    fi
    
    robinhood_log "DEBUG" "Token is valid, no refresh needed"
    return 0
}

# ============================================================================
# Public API: Token Access
# ============================================================================

# Get current access token
# Reads ~/.robinhood_tokens.json
# Returns: Current access_token on stdout
robinhood_get_token() {
    robinhood_oauth_load_tokens || return 1
    
    if [[ -z "$ROBINHOOD_ACCESS_TOKEN" ]]; then
        robinhood_log "ERROR" "No access token available"
        return 1
    fi
    
    echo "$ROBINHOOD_ACCESS_TOKEN"
    return 0
}

# ============================================================================
# Public API: Token Validation
# ============================================================================

# Check if current token is valid (not expired)
# Returns: 0 (valid/exit code success), 1 (expired/missing - exit code failure)
robinhood_token_valid() {
    robinhood_oauth_load_tokens
    
    if robinhood_oauth_is_token_expired; then
        robinhood_log "WARN" "Token is expired or missing"
        return 1  # Token expired
    fi
    
    robinhood_log "DEBUG" "Token is valid"
    return 0  # Token valid
}

# ============================================================================
# Module Export
# ============================================================================

export -f robinhood_init_logging
export -f robinhood_log
export -f robinhood_oauth_derive_key
export -f robinhood_oauth_generate_iv
export -f robinhood_oauth_encrypt_tokens
export -f robinhood_oauth_decrypt_tokens
export -f robinhood_oauth_load_tokens
export -f robinhood_oauth_save_tokens
export -f robinhood_oauth_clear_tokens
export -f robinhood_oauth_is_token_expired
export -f robinhood_oauth_get_auth_url
export -f robinhood_oauth_exchange_code
export -f robinhood_oauth_refresh_token
export -f robinhood_oauth_get_auth_header
export -f robinhood_setup_oauth
export -f robinhood_request_access_token
export -f robinhood_refresh_token_if_needed
export -f robinhood_get_token
export -f robinhood_token_valid

# ============================================================================
# End of Module
# ============================================================================
