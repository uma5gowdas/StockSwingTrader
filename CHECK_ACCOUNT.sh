#!/bin/bash

# Load credentials
source config.sh

echo "╔════════════════════════════════════════════╗"
echo "║   ALPACA ACCOUNT STATUS                   ║"
echo "╚════════════════════════════════════════════╝"
echo ""

# Get account info
RESPONSE=$(curl -s -H "APCA-API-KEY-ID: $ALPACA_API_KEY" -H "APCA-API-SECRET-KEY: $ALPACA_SECRET_KEY" "https://paper-api.alpaca.markets/v2/account")

# Extract values
ACCOUNT=$(echo "$RESPONSE" | jq -r '.account_number' 2>/dev/null)
STATUS=$(echo "$RESPONSE" | jq -r '.status' 2>/dev/null)
CASH=$(echo "$RESPONSE" | jq -r '.cash' 2>/dev/null)
BUYING_POWER=$(echo "$RESPONSE" | jq -r '.buying_power' 2>/dev/null)
PORTFOLIO=$(echo "$RESPONSE" | jq -r '.portfolio_value' 2>/dev/null)
EQUITY=$(echo "$RESPONSE" | jq -r '.equity' 2>/dev/null)

echo "  Account Number:    $ACCOUNT"
echo "  Status:            $STATUS ✅"
echo "  Cash Balance:      \$$CASH"
echo "  Buying Power:      \$$BUYING_POWER"
echo "  Portfolio Value:   \$$PORTFOLIO"
echo "  Equity:            \$$EQUITY"
echo ""
echo "✅ Connection successful!"
echo ""

