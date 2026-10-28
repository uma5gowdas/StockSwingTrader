# Robinhood MCP Integration Guide

## Overview

Robinhood officially provides **Model Context Protocol (MCP) servers** for trading without requiring OAuth app registration.

**Two MCP Endpoints:**
- **Trading API:** https://agent.robinhood.com/mcp/trading
- **Banking API:** https://banking-agent.robinhood.com/mcp/banking

## How to Use Robinhood via Kiro MCP

### Step 1: Access Robinhood MCP Tools in Kiro

The Robinhood MCP servers are now configured in your Kiro settings. You can access them by:

1. **Opening Kiro Command Palette:** `Cmd+Shift+P` (Mac) or `Ctrl+Shift+P` (Windows)
2. **Typing:** `MCP: List Available Tools`
3. **Selecting:** Robinhood Trading or Robinhood Banking
4. **Authenticating:** Browser will open → Login with Robinhood credentials → Authorize

### Step 2: Use Robinhood Trading Commands

Once authenticated, you can ask Kiro agents to:

```
Check my Robinhood account balance
Get my open positions on Robinhood
Place a buy order for 10 AAPL shares on Robinhood
Sell 5 MSFT shares on Robinhood
Get my order history on Robinhood
Check my account buying power on Robinhood
```

### Step 3: Example Workflow

**You (User):** 
> Check my Robinhood account and show buying power

**Kiro Agent:**
- Connects to Robinhood MCP Trading API
- Authenticates with your browser OAuth
- Retrieves account data
- Displays: Balance, Buying Power, Open Positions, Recent Orders

**You (User):**
> Place a buy order: 10 AAPL shares on Robinhood

**Kiro Agent:**
- Calls Robinhood MCP Trading endpoint
- Places market/limit order
- Returns order confirmation (Order ID, Status, Execution Price)

## Authentication Flow

### First Time Setup
1. You ask Kiro: "Check my Robinhood account"
2. Kiro detects no auth tokens
3. Browser opens to Robinhood OAuth page
4. You login with Robinhood username/password
5. You authorize "Kiro" app (one-time)
6. Tokens saved securely in Kiro (encrypted)
7. Future requests use cached tokens (auto-refresh)

### Token Management
- **Storage:** Encrypted locally in Kiro config
- **Refresh:** Automatic before expiry
- **Security:** Never sent to third parties
- **Revocation:** Revoke in Robinhood app settings anytime

## Available MCP Operations

### Trading API Functions

**Account Information:**
- `get_account()` — Account balance, buying power, equity
- `get_positions()` — Open positions and holdings
- `get_orders()` — Order history and status
- `get_order_details(order_id)` — Specific order info

**Trading Operations:**
- `place_order(symbol, qty, side, order_type, price)` — Buy/sell stocks
- `cancel_order(order_id)` — Cancel pending orders
- `modify_order(order_id, qty, price)` — Update order parameters

**Market Data:**
- `get_quote(symbol)` — Real-time stock price
- `get_market_hours()` — Market open/close times
- `get_watchlist()` — Your saved watchlist

### Banking API Functions

**Account Transfers:**
- `get_bank_accounts()` — Linked bank accounts
- `initiate_transfer(amount, direction)` — Deposit/withdrawal
- `get_transfer_history()` — Past transfers

**Account Management:**
- `get_account_statements()` — Monthly statements
- `get_tax_documents()` — 1099 forms
- `update_account_info()` — Profile updates

## Kiro Agent Commands

Ask Kiro agents these questions and they'll use Robinhood MCP:

### Account Monitoring
```
"Check my Robinhood account status"
"What's my current buying power on Robinhood?"
"Show me all my Robinhood positions"
"Get my recent order history from Robinhood"
```

### Trading
```
"Buy 10 shares of AAPL on Robinhood"
"Sell 5 shares of MSFT on Robinhood at $400"
"Place a limit order for TSLA at $250 for 20 shares"
"Cancel my GOOGL order #12345"
```

### Analysis
```
"Show me my Robinhood portfolio allocation"
"What's my total portfolio value on Robinhood?"
"Calculate my gains/losses on Robinhood"
"Compare my Robinhood vs Alpaca performance"
```

### Banking
```
"Show my linked bank accounts on Robinhood"
"Initiate a deposit of $5000 on Robinhood"
"Get my recent transfer history from Robinhood"
```

## Comparison: Shell Script vs MCP

| Feature | Shell Script | MCP Agent |
|---------|-------------|-----------|
| Authentication | Requires OAuth registration ❌ | Official Robinhood OAuth ✅ |
| Ease of Setup | Complex (need developer account) ❌ | Click & authorize ✅ |
| Security | Token storage overhead ⚠️ | Kiro encryption ✅ |
| User Experience | Command-line only | Natural language ✅ |
| Feature Support | Limited (custom implementation) | Full Robinhood API ✅ |
| Third-party Status | Unofficial, risky ⚠️ | Official, supported ✅ |

## Troubleshooting

**Issue:** "MCP server not found"
- → Restart Kiro (`Cmd+Shift+P` → `Developer: Reload Window`)
- → Verify settings.json has Robinhood MCP URLs

**Issue:** "Authentication failed"
- → Verify your Robinhood account is active
- → Check internet connection
- → Try revoking app in Robinhood settings and re-authorize

**Issue:** "Order placement failed"
- → Verify account has buying power
- → Check market hours (9:30 AM - 4:00 PM EST)
- → Ensure sufficient funds for order

**Issue:** "Token expired"
- → Tokens auto-refresh automatically
- → If manual refresh needed: Clear Kiro cache and re-authenticate

## Security & Privacy

### What's Shared
- Your Robinhood credentials (only with official Robinhood OAuth)
- Trading account data (account info, positions, orders)
- Nothing else is transmitted

### What's NOT Shared
- Your Robinhood password (never stored locally)
- Personal identification details (unless required by Robinhood)
- Bank account numbers (standard OAuth security)

### Best Practices
- ✅ Always authorize through official Robinhood OAuth
- ✅ Revoke app access in Robinhood settings if unused
- ✅ Don't share Robinhood tokens with anyone
- ✅ Keep Kiro updated for security patches
- ❌ Don't share credentials via email/chat
- ❌ Don't use public WiFi for authentication

## Integration with StockSwingTrader

You can combine Robinhood MCP with StockSwingTrader:

**Analysis via Shell Script + Trading via MCP:**
```bash
# Analyze stocks (no broker needed)
./StockSwingTrader_Agent.sh --top-10 --debug

# Execute trades on Robinhood via Kiro MCP
# (Ask Kiro agent: "Buy the top recommendation from StockSwingTrader")
```

**Multi-Broker Portfolio:**
- Use Alpaca for some trades (shell script works)
- Use Robinhood MCP for other trades (Kiro agents)
- Both logged to unified trade journal

## Next Steps

1. **Authenticate:** Ask Kiro any Robinhood question
2. **Authorize:** Complete browser OAuth when prompted
3. **Trade:** Use natural language to buy/sell/monitor
4. **Combine:** Mix with StockSwingTrader analysis

### Example First Query:
> "Connect to my Robinhood account and show me my current account balance and open positions"

---

**Version:** 1.0 (Robinhood MCP Integration)
**Status:** Official Robinhood API, Production Ready
**Last Updated:** 2025-10-28
