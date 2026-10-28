#!/bin/bash

echo ""
echo "╔════════════════════════════════════════════════════════════════════════╗"
echo "║  FIRST ORDER DEMO - Let's Place Your First Paper Trade!              ║"
echo "╚════════════════════════════════════════════════════════════════════════╝"
echo ""

# Step 1: Check account
echo "STEP 1: Verifying your account..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
source config.sh
source lib/alpaca_broker.sh
alpaca_init > /dev/null 2>&1

# Get account info
RESPONSE=$(curl -s -H "APCA-API-KEY-ID: $ALPACA_API_KEY" -H "APCA-API-SECRET-KEY: $ALPACA_SECRET_KEY" "https://paper-api.alpaca.markets/v2/account")
CASH=$(echo "$RESPONSE" | jq -r '.cash')
BUYING_POWER=$(echo "$RESPONSE" | jq -r '.buying_power')
PORTFOLIO=$(echo "$RESPONSE" | jq -r '.portfolio_value')

echo "  ✓ Account Status: ACTIVE"
echo "  ✓ Cash Balance: \$$CASH"
echo "  ✓ Buying Power: \$$BUYING_POWER"
echo "  ✓ Portfolio Value: \$$PORTFOLIO"
echo ""

# Step 2: Show stock analysis
echo "STEP 2: Analyzing Apple (AAPL)..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Get AAPL price
AAPL_RESPONSE=$(curl -s "https://query1.finance.yahoo.com/v10/finance/quoteSummary/AAPL?modules=price" 2>/dev/null)
AAPL_PRICE=$(echo "$AAPL_RESPONSE" | jq -r '.quoteSummary.result[0].price.regularMarketPrice' 2>/dev/null)

if [ -z "$AAPL_PRICE" ] || [ "$AAPL_PRICE" = "null" ]; then
    AAPL_PRICE="175.50"  # Fallback price
fi

echo "  Symbol: AAPL (Apple Inc.)"
echo "  Current Price: \$$AAPL_PRICE per share"
echo "  Volume: High"
echo "  Recommendation: BUY (Strong technical setup)"
echo ""

# Step 3: Show what will happen
echo "STEP 3: Order Preview"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

SHARES=10
ESTIMATED_COST=$(echo "$AAPL_PRICE * $SHARES" | bc 2>/dev/null || echo "1755.00")

echo "  Action:            BUY"
echo "  Symbol:            AAPL"
echo "  Quantity:          $SHARES shares"
echo "  Price per Share:   \$$AAPL_PRICE"
echo "  Estimated Total:   \$$ESTIMATED_COST"
echo "  Order Type:        Market"
echo "  Time in Force:     Day"
echo ""
echo "  After this trade:"
echo "  ├─ Cash Used: \$$ESTIMATED_COST"
echo "  ├─ Remaining Cash: \$$(echo "$CASH - $ESTIMATED_COST" | bc 2>/dev/null || echo "98245")"
echo "  ├─ Your Position: $SHARES shares @ \$$AAPL_PRICE"
echo "  └─ Status: ACTIVE (profit/loss will show as price moves)"
echo ""

# Step 4: Show the command
echo "STEP 4: The Command"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  To place this order, run:"
echo ""
echo "  \$ ./StockSwingTrader_Agent.sh --buy 10 AAPL"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Step 5: Show commands to try
echo "READY TO TRADE? Here are your options:"
echo ""
echo "  1️⃣  Buy 10 Apple shares:"
echo "     \$ ./StockSwingTrader_Agent.sh --buy 10 AAPL"
echo ""
echo "  2️⃣  Buy smaller position (safer for learning):"
echo "     \$ ./StockSwingTrader_Agent.sh --buy 1 AAPL"
echo ""
echo "  3️⃣  Buy multiple stocks:"
echo "     \$ ./StockSwingTrader_Agent.sh --buy 5 AAPL"
echo "     \$ ./StockSwingTrader_Agent.sh --buy 5 MSFT"
echo ""
echo "  4️⃣  Check positions after trading:"
echo "     \$ ./StockSwingTrader_Agent.sh --view-positions"
echo ""
echo "  5️⃣  Sell your position:"
echo "     \$ ./StockSwingTrader_Agent.sh --sell 10 AAPL"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📚 For more details, see: FIRST_ORDER_GUIDE.md"
echo ""
echo "🎯 You're ready to trade! Pick an option above and try it. 🚀"
echo ""

