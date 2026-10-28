# Robinhood OAuth Setup Guide (v6.2)

## Prerequisites
- Robinhood account at https://www.robinhood.com/
- Robinhood developer account at https://developer.robinhood.com/

## Setup Steps

### 1. Create Developer App
- Log into https://developer.robinhood.com/
- Create new app
- Copy: CLIENT_ID, CLIENT_SECRET
- Set Redirect URI: http://localhost:8000

### 2. Update Configuration
- Edit config.sh
- Set ROBINHOOD_CLIENT_ID and ROBINHOOD_CLIENT_SECRET
- Set ROBINHOOD_REDIRECT_URI=http://localhost:8000

### 3. Authenticate
- Run: ./lib/robinhood_oauth.sh --setup
- Browser opens automatically
- Approve app access when prompted
- Tokens automatically stored in ~/.robinhood_tokens.json

### 4. Verify Setup
- Check token file: cat ~/.robinhood_tokens.json
- Should contain: access_token, refresh_token, expires_at, token_type

## Using Robinhood

### Run Strategies with Robinhood
```bash
# Mean reversion on Robinhood
./StockSwingTrader_Agent.sh --strategy mean-reversion --broker robinhood

# Trend following on Robinhood
./StockSwingTrader_Agent.sh --strategy trend-follow --broker robinhood
```

## Token Management

### Auto-Refresh
- Tokens automatically refresh before expiration
- Happens transparently during trading
- No user action required

### Manual Refresh
- Force refresh: ./lib/robinhood_oauth.sh --refresh
- Check expiration: ./lib/robinhood_oauth.sh --check-token

### Troubleshooting

**Token Expired**
- Solution: Auto-refreshes on next trade
- Or manually run: ./lib/robinhood_oauth.sh --refresh

**Authorization Revoked**
- Solution: Re-run setup: ./lib/robinhood_oauth.sh --setup

**API Errors**
- Check logs: tail -f logs/robinhood_api.log
- Verify network connectivity
- Verify CLIENT_ID and CLIENT_SECRET in config.sh

## Security Notes
- Tokens stored in ~/.robinhood_tokens.json (local file)
- Never commit tokens to version control
- Use environment variables for sensitive credentials in CI/CD
- Auto-refresh reduces token exposure time
