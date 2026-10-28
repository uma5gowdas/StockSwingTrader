# Robinhood OAuth Setup Guide

## Problem
The Robinhood OAuth integration requires registering your app with Robinhood's Developer API to get OAuth credentials (Client ID and Secret).

## Solution: Get Your OAuth Credentials

### Step 1: Register Your App with Robinhood
1. Visit: **https://robinhood.com/us/en/developers/**
2. Sign in with your Robinhood account
3. Click "Create App" or "Register Application"
4. Fill in the app details:
   - **App Name:** "StockSwingTrader"
   - **App Type:** "Confidential"
   - **Redirect URI:** `http://localhost:8888/callback`
5. Copy your **Client ID** and **Client Secret**

### Step 2: Configure StockSwingTrader
```bash
cd ~/Desktop/StockSwingTrader
nano config.robinhood.sh
```

Replace these lines with your credentials:
```bash
export ROBINHOOD_CLIENT_ID="YOUR_CLIENT_ID_HERE"
export ROBINHOOD_CLIENT_SECRET="YOUR_CLIENT_SECRET_HERE"
```

Save and exit (Ctrl+X, then Y, then Enter)

### Step 3: Load Credentials
```bash
source config.robinhood.sh
```

### Step 4: Test Connection
```bash
./StockSwingTrader_Agent.sh --broker robinhood --check-account
```

## Expected Output
After running the above, you should see:
1. Browser opens to Robinhood OAuth page
2. You log in with your Robinhood username/password
3. You authorize "StockSwingTrader" app
4. Tokens are saved automatically to `~/.robinhood_tokens.json` (encrypted)
5. Your account details appear in the terminal

## Troubleshooting

**Issue:** "Invalid client_id"
- → Double-check your Client ID matches exactly
- → Verify app is registered at https://robinhood.com/us/en/developers/

**Issue:** "Redirect URI mismatch"
- → Ensure redirect URI in Robinhood dashboard matches: `http://localhost:8888/callback`

**Issue:** "Authorization failed"
- → Verify your Robinhood account is in good standing
- → Some account types don't support API access

**Issue:** "Still shows 'your_app_id' placeholder"
- → You haven't sourced config.robinhood.sh
- → Run: `source config.robinhood.sh` first

## Alpaca Alternative
If you don't want to register with Robinhood, you can continue using Alpaca (which is already set up):

```bash
./StockSwingTrader_Agent.sh --check-account  # Uses Alpaca by default
```

## Security Notes
- Tokens are encrypted with AES-256 and stored in `~/.robinhood_tokens.json`
- Never commit `config.robinhood.sh` or `~/.robinhood_tokens.json` to git
- Both files are in `.gitignore` for protection
- Tokens auto-refresh before expiry

