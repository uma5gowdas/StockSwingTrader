#!/bin/bash
# ============================================================================
# Robinhood OAuth Configuration
# ============================================================================
# To use Robinhood broker, configure OAuth credentials below
# ============================================================================

# Option 1: OAuth Token (if you already have a refresh token from elsewhere)
# export ROBINHOOD_ACCESS_TOKEN="your_access_token_here"
# export ROBINHOOD_REFRESH_TOKEN="your_refresh_token_here"
# export ROBINHOOD_TOKEN_EXPIRES_AT="1234567890"

# Option 2: OAuth Client Credentials (for full OAuth flow)
# To get these, register your app at: https://robinhood.com/us/en/developers/
export ROBINHOOD_CLIENT_ID="your_client_id_here"
export ROBINHOOD_CLIENT_SECRET="your_client_secret_here"

# Redirect URI for OAuth callback (keep as-is unless you have custom setup)
export ROBINHOOD_OAUTH_REDIRECT_URI="http://localhost:8888/callback"

# Enable debug logging
export ROBINHOOD_DEBUG="false"

# ============================================================================
# Getting Your Robinhood OAuth Credentials
# ============================================================================
# 
# 1. Visit: https://robinhood.com/us/en/developers/
# 2. Create an app / register your application
# 3. Copy your Client ID and Client Secret
# 4. Paste them in the export statements above
# 5. Save this file: config.robinhood.sh
# 6. Run: source config.robinhood.sh
# 7. Then: ./StockSwingTrader_Agent.sh --broker robinhood --check-account
#
# ============================================================================

echo "[INFO] Robinhood OAuth credentials loaded from config.robinhood.sh"
