# StockSwingTrader: Broker Setup Wizards

This document describes the standalone broker setup wizards for Alpaca and Robinhood. These scripts enable independent broker configuration without requiring Kiro or any external tools.

## Overview

The deployment package includes two interactive setup wizards:
- **setup-alpaca.sh** — Configure Alpaca API key and secret
- **setup-robinhood.sh** — Configure Robinhood OAuth2 authentication

Both scripts:
- Run completely standalone (no Kiro, no external dependencies beyond bash/curl)
- Validate credentials before saving
- Provide clear success/error feedback
- Include retry logic for network issues
- Save configuration to secure environment files
- Can be transferred to any system and run independently

## Quick Start

### Alpaca Setup

```bash
cd /path/to/StockSwingTrader/DEPLOYMENT_PACKAGE
./setup-alpaca.sh
```

**Steps:**
1. Provide your Alpaca API Key
2. Provide your Alpaca Secret Key
3. Credentials are validated with a test API call
4. Account information is fetched and displayed
5. Market data access is tested
6. Configuration is saved to `config.alpaca.env`

**Output:** `config.alpaca.env` with validated credentials

### Robinhood Setup

```bash
cd /path/to/StockSwingTrader/DEPLOYMENT_PACKAGE
./setup-robinhood.sh
```

**Steps:**
1. Provide OAuth2 Client ID and Secret
2. Authorization URL is generated
3. You authenticate in your browser
4. Authorization code is exchanged for tokens
5. Account information is fetched and displayed
6. Configuration is saved to `config.robinhood.env`

**Output:** `config.robinhood.env` with OAuth2 tokens

## Detailed Usage

### setup-alpaca.sh

#### Getting Your Credentials

1. Go to: https://app.alpaca.markets/paper/dashboard/settings/api
2. Copy your API Key
3. Copy your Secret Key

#### Running the Setup

```bash
./setup-alpaca.sh
```

#### Environment Variables

You can pre-fill credentials using environment variables:

```bash
ALPACA_API_KEY="your_key" ALPACA_SECRET_KEY="your_secret" ./setup-alpaca.sh
```

#### Configuration Output

After successful setup, `config.alpaca.env` contains:

```bash
export ALPACA_ENABLED=true
export ALPACA_API_KEY="your_key"
export ALPACA_SECRET_KEY="your_secret"
export ALPACA_BASE_URL="https://paper-api.alpaca.markets"
export ALPACA_MODE="paper"
export ALPACA_TIMEOUT_SECONDS=15
export ALPACA_MAX_RETRIES=3
# ... additional trading configuration
```

#### Using the Configuration

```bash
# Source the configuration
source config.alpaca.env

# Start trading with Alpaca
./StockSwingTrader_Agent.sh --broker alpaca
```

#### Troubleshooting

| Issue | Solution |
|-------|----------|
| "Invalid API Key format" | Ensure your API Key is at least 10 characters |
| "Authentication failed" | Verify your API Key and Secret Key are correct |
| "Failed to reach Alpaca API" | Check your internet connection and firewall |
| "Could not fetch account information" | Verify your credentials have account access |

---

### setup-robinhood.sh

#### Getting Your Credentials

1. Create a Robinhood Developer Application:
   - Go to: https://developer.robinhood.com
   - Create a new application
   - Set Redirect URI to: `http://localhost:8000`
   - Copy your Client ID
   - Copy your Client Secret

2. Have your Robinhood username and password ready (you'll authenticate in browser)

#### Running the Setup

```bash
./setup-robinhood.sh
```

#### OAuth2 Authentication Flow

The script implements the OAuth2 authentication flow:

1. **Client Registration** — Your OAuth2 application credentials (Client ID, Secret)
2. **Authorization Request** — Browser opens authorization URL
3. **User Authentication** — You log in to Robinhood
4. **Authorization Code** — You receive a code in the browser URL
5. **Token Exchange** — Script exchanges code for access and refresh tokens
6. **Token Storage** — Tokens are saved securely

#### Configuration Output

After successful setup, `config.robinhood.env` contains:

```bash
export ROBINHOOD_ENABLED=true
export ROBINHOOD_CLIENT_ID="your_client_id"
export ROBINHOOD_ACCESS_TOKEN="your_access_token"
export ROBINHOOD_REFRESH_TOKEN="your_refresh_token"
export ROBINHOOD_API_BASE_URL="https://api.robinhood.com"
export ROBINHOOD_TOKEN_REFRESH_INTERVAL=3600
export ROBINHOOD_TOKEN_EXPIRY_CHECK=true
# ... additional trading configuration
```

#### Security Notes

- **Never share your Client Secret** — Keep it confidential
- **Refresh tokens are sensitive** — The config file is created with 600 permissions (readable only by owner)
- **User credentials are never stored** — Only OAuth2 tokens are saved
- **Tokens expire** — The system automatically manages token refresh

#### Token Refresh

Access tokens expire after a period of time. The refresh token allows obtaining new access tokens:

**Automatic Refresh (recommended):**
```bash
# Set this in config.robinhood.env
export ROBINHOOD_TOKEN_EXPIRY_CHECK=true
```

The StockSwingTrader agent will automatically refresh tokens when needed.

**Manual Refresh:**
```bash
curl -X POST https://api.robinhood.com/oauth2/token/ \
  -H "Content-Type: application/json" \
  -d '{
    "grant_type": "refresh_token",
    "refresh_token": "'$ROBINHOOD_REFRESH_TOKEN'",
    "client_id": "'$ROBINHOOD_CLIENT_ID'"
  }'
```

Update `ROBINHOOD_ACCESS_TOKEN` in `config.robinhood.env` with the new token from the response.

#### Troubleshooting

| Issue | Solution |
|-------|----------|
| "Client ID cannot be empty" | Provide your OAuth2 Client ID from https://developer.robinhood.com |
| "Authorization code exchange failed" | Verify Client ID and Secret are correct, and code hasn't expired |
| "Failed to fetch account information" | Check internet connection, or continue without account info |
| "Token expired" | Run setup again or manually refresh using the token endpoint |

---

## Advanced Features

### Retry Logic

Both scripts include intelligent retry logic for network issues:

- **Max Retries:** 3 attempts
- **Initial Backoff:** 1 second
- **Exponential Backoff:** 2x multiplier (1s → 2s → 4s)
- **Timeouts:** 5s connection, 15s total

### Logging

All operations are logged to:
- **Alpaca:** `logs/setup-alpaca.log`
- **Robinhood:** `logs/setup-robinhood.log`

View logs:
```bash
tail -f logs/setup-alpaca.log
tail -f logs/setup-robinhood.log
```

### Configuration Backups

Existing configurations are automatically backed up before saving:
```bash
ls -la backups/config.*.env.backup.*
```

### Credential Validation

Both scripts validate credentials before saving:
- **Format validation** — API keys/secrets must match expected patterns
- **API validation** — Test API call confirms credentials work
- **Account info** — Fetches and displays account details
- **Market data** — Tests market data access (Alpaca)
- **Token exchange** — Tests OAuth2 flow (Robinhood)

---

## Using Multiple Brokers

You can configure and use both brokers:

```bash
# Configure both
./setup-alpaca.sh
./setup-robinhood.sh

# Start with Alpaca (default)
./StockSwingTrader_Agent.sh --broker alpaca --symbols AAPL,MSFT

# Switch to Robinhood
./StockSwingTrader_Agent.sh --broker robinhood --symbols AAPL,MSFT

# Check account status for each
./StockSwingTrader_Agent.sh --broker alpaca --check-account
./StockSwingTrader_Agent.sh --broker robinhood --check-account
```

---

## Deployment Package Contents

```
DEPLOYMENT_PACKAGE/
├── setup-alpaca.sh              # Alpaca setup wizard
├── setup-robinhood.sh           # Robinhood setup wizard
├── SETUP_WIZARDS.md            # This file
├── config/
│   ├── config.alpaca.env       # Generated by setup-alpaca.sh
│   └── config.robinhood.env    # Generated by setup-robinhood.sh
├── backups/                    # Configuration backups
├── logs/                       # Setup logs
└── ...
```

---

## System Requirements

- **bash 4.0+** (check with: `bash --version`)
- **curl** (for API calls)
- **sed** (for string replacement)
- **Internet connection** (for API validation)
- **macOS, Linux, or WSL** (bash-based environments)

Optional:
- **jq** (for prettier JSON output, falls back to grep if not available)
- **openssl** (for state parameter generation, falls back to /dev/urandom)

Verify requirements:
```bash
bash --version
curl --version
which sed
# Optional:
which jq
which openssl
```

---

## Transferring to Other Systems

The setup wizards are completely standalone:

1. Copy the scripts to your target system:
```bash
scp setup-alpaca.sh user@remote-system:/home/user/
scp setup-robinhood.sh user@remote-system:/home/user/
```

2. On the remote system, run setup:
```bash
bash setup-alpaca.sh
bash setup-robinhood.sh
```

3. Copy generated configs back (if needed):
```bash
scp remote-system:config.alpaca.env .
scp remote-system:config.robinhood.env .
```

No Kiro, Python, or external dependencies required on the target system.

---

## Integration with Main Agent

Once configured, use the setup configs with the main trading agent:

```bash
# Source configuration
source config.alpaca.env
source config.robinhood.env

# Run with specific broker
./StockSwingTrader_Agent.sh --broker alpaca --top-10

# Check account status
./StockSwingTrader_Agent.sh --broker robinhood --check-account

# View available options
./StockSwingTrader_Agent.sh --help
```

---

## Support & Documentation

- **Alpaca API Docs:** https://docs.alpaca.markets/api-documentation
- **Robinhood API Docs:** https://api.robinhood.com
- **Robinhood Developer Portal:** https://developer.robinhood.com
- **StockSwingTrader Documentation:** See INSTALL_README.md

---

## FAQ

**Q: Are my credentials secure?**
A: Yes. Credentials are stored in files with 600 permissions (owner-only readable). Source files are not committed to git (.gitignore excludes them).

**Q: Can I change brokers after setup?**
A: Yes. Run either setup wizard again or edit the config files directly.

**Q: What if I lose my refresh token?**
A: Run `setup-robinhood.sh` again to re-authenticate and get new tokens.

**Q: Can I use live trading credentials?**
A: Yes, but **NOT recommended** for testing. Use paper trading credentials first.

**Q: What if the script fails?**
A: Check the log files in `logs/` directory for detailed error messages.

**Q: Do I need to run setup every time?**
A: No. Setup once, and the configuration is reused. Only re-run if you change brokers or credentials.

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-10-28 | Initial release - Alpaca and Robinhood setup wizards |

---

**Last Updated:** 2024-10-28
**Author:** StockSwingTrader Deployment System
