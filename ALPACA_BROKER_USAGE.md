# Alpaca Broker Integration Module

The `lib/alpaca_broker.sh` module provides a complete Bash interface to the Alpaca Paper Trading API.

## Quick Start

```bash
#!/bin/bash

# Source the module
source lib/alpaca_broker.sh

# Set Alpaca credentials (from environment or config)
export APCA_API_KEY_ID="your_api_key"
export APCA_API_SECRET_KEY="your_secret_key"

# Initialize connection to Alpaca
alpaca_init

# Get account information
alpaca_get_account

# Place an order
alpaca_place_order "AAPL" 10 "buy"

# Check positions
alpaca_get_positions
```

## Configuration

Set these environment variables before calling `alpaca_init()`:

- `APCA_API_KEY_ID` - Your Alpaca API key
- `APCA_API_SECRET_KEY` - Your Alpaca API secret
- OR `APCA_API_OAUTH_TOKEN` - OAuth token (alternative auth method)

Optional:
- `ALPACA_DEBUG=true` - Enable verbose debug logging
- `ALPACA_LOG_FILE=logs/alpaca.log` - Custom log file location

## Core Functions

### alpaca_init()
Initialize the Alpaca API connection. Must be called before any other functions.
```bash
alpaca_init
```

### alpaca_get_account()
Get account details (equity, buying power, cash balance, etc).
```bash
alpaca_get_account
```

### alpaca_get_positions()
List all open positions.
```bash
alpaca_get_positions
```

### alpaca_check_position(SYMBOL)
Check if a symbol has an open position.
```bash
alpaca_check_position "AAPL"
```

### alpaca_place_order(SYMBOL, QTY, SIDE)
Place a market order.
- SYMBOL: Stock ticker (A-Z, 1-5 chars)
- QTY: Number of shares (positive number)
- SIDE: "buy" or "sell"

```bash
alpaca_place_order "AAPL" 10 "buy"
alpaca_place_order "TSLA" 5.5 "sell"
```

### alpaca_get_order_status(ORDER_ID)
Get the status of a specific order.
```bash
alpaca_get_order_status "12345-67890"
```

### alpaca_cancel_order(ORDER_ID)
Cancel a pending order.
```bash
alpaca_cancel_order "12345-67890"
```

## Helper Functions

### alpaca_check_connection()
Test API connectivity without making changes.
```bash
alpaca_check_connection && echo "Connected!"
```

### alpaca_validate_symbol(SYMBOL)
Validate symbol format.
```bash
alpaca_validate_symbol "AAPL" && echo "Valid"
```

### alpaca_validate_quantity(QTY)
Validate quantity format.
```bash
alpaca_validate_quantity "10" && echo "Valid"
```

### alpaca_validate_side(SIDE)
Validate side (buy/sell).
```bash
alpaca_validate_side "buy" && echo "Valid"
```

### alpaca_format_currency(NUMBER, [SHOW_COLOR=true])
Format a number as currency with optional color.
```bash
alpaca_format_currency "1234.56"      # Green: $1234.56
alpaca_format_currency "-50.00"       # Red: -$50.00
alpaca_format_currency "0" "false"    # No color: $0.00
```

### alpaca_format_percent(PERCENT)
Format percentage with color coding.
```bash
alpaca_format_percent "5.25"          # Green: 5.25%
alpaca_format_percent "-2.50"         # Red: -2.50%
```

## Error Handling

The module automatically handles:
- Invalid API credentials (401, 403)
- Insufficient buying power (422)
- Invalid symbols
- Rate limiting (429) with automatic retry
- Connection timeouts
- Malformed requests (400)

All errors are logged to `logs/alpaca.log` with timestamps.

## Logging

Logs are written to `logs/alpaca.log` with format:
```
[2024-10-28 15:30:45] [INFO] Account information retrieved
[2024-10-28 15:30:46] [ERROR] Invalid symbol format: aapl (must be 1-5 uppercase letters)
```

Enable debug mode for verbose output:
```bash
export ALPACA_DEBUG=true
alpaca_init
```

## Security Notes

- API credentials are **never** echoed or logged
- Use environment variables only (never hardcode keys)
- All API calls use HTTPS
- Input validation on all user inputs
- Special characters are properly escaped

## API Endpoints Used

Paper Trading Base URL: `https://paper-api.alpaca.markets/v2`

Endpoints:
- `GET /account` - Get account info
- `GET /positions` - List positions
- `GET /positions/{symbol}` - Check symbol position
- `POST /orders` - Place order
- `GET /orders/{order_id}` - Get order status
- `DELETE /orders/{order_id}` - Cancel order

## Rate Limiting

The module implements exponential backoff for rate-limited responses (429):
- Initial backoff: 1 second
- Max retries: 3 attempts
- Multiplier: 2x per retry

## Troubleshooting

**"ERROR: Missing Alpaca API credentials"**
- Set APCA_API_KEY_ID and APCA_API_SECRET_KEY environment variables
- Or set APCA_API_OAUTH_TOKEN

**"ERROR: Unauthorized"**
- Verify API credentials are correct
- Check credentials are not expired

**"ERROR: Insufficient buying power"**
- Your account doesn't have enough cash for this trade
- Check account balance with `alpaca_get_account`

**"ERROR: Invalid symbol format"**
- Symbol must be 1-5 uppercase letters (e.g., AAPL, MSFT, TSLA)
