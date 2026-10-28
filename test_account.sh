#!/bin/bash
source config.sh
source lib/alpaca_broker.sh

alpaca_init
if [ $? -eq 0 ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ALPACA ACCOUNT STATUS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    RESPONSE=$(curl -s -H "APCA-API-KEY-ID: $ALPACA_API_KEY" -H "APCA-API-SECRET-KEY: $ALPACA_SECRET_KEY" "https://paper-api.alpaca.markets/v2/account")
    
    ACCOUNT_NUM=$(echo "$RESPONSE" | jq -r '.account_number')
    STATUS=$(echo "$RESPONSE" | jq -r '.status')
    CASH=$(echo "$RESPONSE" | jq -r '.cash')
    BUYING_POWER=$(echo "$RESPONSE" | jq -r '.buying_power')
    PORTFOLIO=$(echo "$RESPONSE" | jq -r '.portfolio_value')
    EQUITY=$(echo "$RESPONSE" | jq -r '.equity')
    CREATED=$(echo "$RESPONSE" | jq -r '.created_at')
    
    echo ""
    echo "  Account Number:        $ACCOUNT_NUM"
    echo "  Status:                $STATUS"
    echo "  Cash Balance:          \$$CASH"
    echo "  Buying Power:          \$$BUYING_POWER"
    echo "  Portfolio Value:       \$$PORTFOLIO"
    echo "  Equity:                \$$EQUITY"
    echo "  Account Created:       $CREATED"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "✅ Alpaca integration successful!"
    echo "   Your paper trading account is active and ready to use."
    echo ""
    echo "Next steps:"
    echo "  1. Run: ./StockSwingTrader_Agent.sh --check-account"
    echo "  2. Or: ./StockSwingTrader_Agent.sh --symbols AAPL,MSFT --alpaca"
    echo ""
fi
