# How to Place Your First Order - Step by Step

## Quick Summary
Placing an order takes just ONE command. Here's how:

```bash
./StockSwingTrader_Agent.sh --buy 10 AAPL
```

That's it! But let's walk through it in detail...

---

## Step 1: Verify Your Account First

Before placing any trades, check your account status:

```bash
cd /Users/P3291917/Builds/6/StockSwingTrader
source config.sh
./StockSwingTrader_Agent.sh --check-account
```

**Expected Output:**
```
Account Number:    PA3V0PY54
Status:            ACTIVE
Cash Balance:      $100,000
Buying Power:      $400,000
Portfolio Value:   $100,000
```

✅ If you see this, you're ready to trade!

---

## Step 2: Check Current Stock Price

Before buying, see what the stock is currently trading at:

```bash
./StockSwingTrader_Agent.sh --symbols AAPL --alpaca
```

This will show you:
- Current price
- Recent trends
- Buy/sell signals
- Technical indicators
- **Recommended action** (BUY, SELL, or HOLD)

---

## Step 3: Place Your First Order

### Simple Buy Order

```bash
./StockSwingTrader_Agent.sh --buy 10 AAPL
```

**What this does:**
- Buy 10 shares of Apple (AAPL)
- Places a market order at current price
- Asks for your confirmation before executing

**Expected Output:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ALPACA TRADE CONFIRMATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Action:            BUY
Symbol:            AAPL
Quantity:          10 shares
Order Type:        Market
Time in Force:     Day
Estimated Cost:    ~$1,750 (at $175/share)

Buying Power After: $398,250

⚠️  IMPORTANT: This is a REAL trade on your paper account!

Continue? (yes/no): 
```

### Confirm the Order

Type `yes` and press Enter:

```
Continue? (yes/no): yes

✅ Order Placed Successfully!

Order ID:          e1a2b3c4-d5e6-f7g8-h9i0-j1k2l3m4n5o6
Status:            FILLED
Symbol:            AAPL
Quantity:          10 shares
Average Price:     $175.50
Total Cost:        $1,755.00
Time Filled:       2026-10-28 15:35:22

Your Position:
  • 10 shares @ $175.50 avg
  • Current Value: ~$1,755
  • Unrealized P&L: $0.00 (0%)
```

✅ **Congratulations! You've placed your first order!**

---

## Step 4: Check Your New Position

Verify your position was created:

```bash
./StockSwingTrader_Agent.sh --check-position AAPL
```

**Output:**
```
Symbol:            AAPL
Quantity:          10
Entry Price:       $175.50
Current Price:     $175.75
Market Value:      $1,757.50
Unrealized P&L:    +$2.50 (0.14%)
```

Or view all positions:

```bash
./StockSwingTrader_Agent.sh --view-positions
```

---

## Different Order Types

### Buy Order
```bash
./StockSwingTrader_Agent.sh --buy 10 AAPL
```

### Sell Order
```bash
./StockSwingTrader_Agent.sh --sell 5 AAPL
```

### Buy Multiple Stocks
```bash
./StockSwingTrader_Agent.sh --buy 10 AAPL
./StockSwingTrader_Agent.sh --buy 5 MSFT
./StockSwingTrader_Agent.sh --buy 3 TSLA
```

---

## Important Things to Know

### ✅ Safe to Practice
- This is **PAPER TRADING** (virtual money)
- No real money is involved
- Perfect for learning and testing strategies
- You have $100,000 starting capital

### ⚠️ Market Hours Matter
- **Market Open**: 9:30 AM EST
- **Market Close**: 4:00 PM EST
- Orders placed during market hours fill immediately
- Orders placed after hours fill at market open next day

### 💰 Position Sizing
- You have $400,000 buying power
- Each share of AAPL costs ~$175
- So you can buy ~2,285 shares (but don't!)
- **Recommendation**: Start with small positions (1-10 shares)

### 📊 Monitoring Your Trades
After placing an order:

**Check position value:**
```bash
./StockSwingTrader_Agent.sh --check-position AAPL
```

**See all positions:**
```bash
./StockSwingTrader_Agent.sh --view-positions
```

**Check account balance:**
```bash
./StockSwingTrader_Agent.sh --check-account
```

---

## Taking Profits (Selling)

### Sell Your Entire Position
```bash
./StockSwingTrader_Agent.sh --sell 10 AAPL
```

### Sell Part of Position
```bash
./StockSwingTrader_Agent.sh --sell 5 AAPL
```
(This sells 5 shares, keeps 5 shares)

### Example Trade: Buy, Hold, Sell

1. Buy 10 shares:
```bash
./StockSwingTrader_Agent.sh --buy 10 AAPL
```

2. Wait for price to go up (watch market)

3. Sell when satisfied with profit:
```bash
./StockSwingTrader_Agent.sh --sell 10 AAPL
```

4. Check your profit:
```bash
./StockSwingTrader_Agent.sh --check-account
```
(Portfolio value will have increased)

---

## Common First Orders to Try

### Conservative (Safest for Learning)
```bash
# Buy 1 share of each major stock
./StockSwingTrader_Agent.sh --buy 1 AAPL
./StockSwingTrader_Agent.sh --buy 1 MSFT
./StockSwingTrader_Agent.sh --buy 1 GOOGL
```

### Moderate (Recommended for Practice)
```bash
# Buy small positions
./StockSwingTrader_Agent.sh --buy 5 AAPL
./StockSwingTrader_Agent.sh --buy 5 MSFT
./StockSwingTrader_Agent.sh --buy 5 TSLA
```

### Aggressive (For Learning Risk Management)
```bash
# Larger positions to see impact of price swings
./StockSwingTrader_Agent.sh --buy 20 AAPL
./StockSwingTrader_Agent.sh --buy 15 MSFT
```

---

## Troubleshooting Your First Order

### Error: "Insufficient Buying Power"
- Check your balance: `./StockSwingTrader_Agent.sh --check-account`
- You start with $100,000 cash
- AAPL @ $175 × 10 shares = $1,750 (well within budget)

### Error: "Invalid Symbol"
- Make sure symbol is uppercase: AAPL (not aapl)
- Must be valid US stock: AAPL, MSFT, GOOGL, etc.

### Error: "Order Rejected"
- Check if market is open (9:30 AM - 4:00 PM EST)
- After hours orders fill at market open next day

### Order Not Showing in Positions
- Wait a moment for order to fill
- Market must be open for instant fills
- Check: `./StockSwingTrader_Agent.sh --view-positions`

---

## Next Steps After Your First Trade

1. ✅ Place a buy order
2. ✅ Watch the position value change as market moves
3. ✅ Place a sell order when ready to take profit/loss
4. ✅ Place multiple orders across different stocks
5. ✅ Analyze stocks before trading (use --symbols flag)
6. ✅ Read about risk management in API_SETUP_GUIDE.md
7. ✅ Enable auto-trading if comfortable (advanced)

---

## Real-World Trading Tips

### Risk Management
- Never risk more than 2% of your capital on one trade
- With $100K, max loss per trade: $2,000
- Set stop-losses to limit downside
- Take profits at predetermined levels

### Position Sizing
- Start small (1-5 shares per position)
- Scale up as you gain confidence
- Don't put all eggs in one basket
- Diversify across multiple stocks

### Discipline
- Follow your trading plan
- Don't chase losses
- Don't revenge trade
- Let winners run, cut losers early

### Learning
- Paper trade for at least 2-4 weeks
- Test your strategy with different market conditions
- Keep a trading journal
- Review what worked and what didn't

---

## Keyboard Shortcuts & Commands

```bash
# Quick reference
cd /Users/P3291917/Builds/6/StockSwingTrader

# Check everything
./StockSwingTrader_Agent.sh --check-account    # Account status
./StockSwingTrader_Agent.sh --view-positions   # All positions

# Place orders
./StockSwingTrader_Agent.sh --buy 10 AAPL      # Buy
./StockSwingTrader_Agent.sh --sell 10 AAPL     # Sell

# Analyze before trading
./StockSwingTrader_Agent.sh --symbols AAPL,MSFT --alpaca

# Get help
./StockSwingTrader_Agent.sh --help
```

---

## You're Ready! 🚀

You now know how to:
✅ Check your account
✅ Analyze stocks
✅ Place buy orders
✅ Place sell orders
✅ Monitor positions
✅ Manage trades

**Next Step**: Run your first order right now!

```bash
cd /Users/P3291917/Builds/6/StockSwingTrader
./StockSwingTrader_Agent.sh --buy 10 AAPL
```

Good luck! 🎉

