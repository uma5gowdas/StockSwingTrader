#!/bin/bash

source config.sh

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║              YOUR PENDING ORDERS                              ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

ORDERS=$(curl -s -H "APCA-API-KEY-ID: $ALPACA_API_KEY" -H "APCA-API-SECRET-KEY: $ALPACA_SECRET_KEY" "https://paper-api.alpaca.markets/v2/orders?status=all")

# Check for pending orders
PENDING=$(echo "$ORDERS" | jq '[.[] | select(.status=="accepted")] | length' 2>/dev/null)
FILLED=$(echo "$ORDERS" | jq '[.[] | select(.status=="filled")] | length' 2>/dev/null)

echo "📊 Order Summary:"
echo "   Pending (Accepted): $PENDING"
echo "   Filled: $FILLED"
echo ""

# Show all orders
echo "📋 All Orders:"
echo "$ORDERS" | jq -r '.[] | "\n  Order ID: \(.id)\n  ├─ Symbol: \(.symbol)\n  ├─ Side: \(.side | ascii_upcase)\n  ├─ Qty: \(.qty) shares\n  ├─ Filled: \(.filled_qty) shares\n  ├─ Status: \(.status | ascii_upcase)\n  ├─ Created: \(.created_at)\n  └─ Expires: \(.expires_at)"' 2>/dev/null

echo ""
echo "⏳ Order Status Explanation:"
echo "   • ACCEPTED: Order received, waiting to fill"
echo "   • FILLED: Order executed, position created"
echo "   • CANCELED: Order was cancelled"
echo ""
echo "📅 Market Status:"
echo "   Paper trading simulates US market hours (9:30 AM - 4:00 PM EST)"
echo "   After hours: Orders fill at next market open"
echo ""

