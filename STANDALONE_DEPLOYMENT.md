# StockSwingTrader Standalone Deployment Guide

## Overview

Deploy StockSwingTrader on **any system** without Kiro. This package includes:
- **Alpaca trading** (shell script based)
- **Robinhood trading** (direct MCP HTTP calls)
- **Complete analysis engine** (indicators, strategies, sentiment)
- **Trade journal** (unified logging for both brokers)

## System Requirements

### Minimum Requirements
- **OS:** macOS, Linux, or Windows (WSL)
- **Shell:** bash 4.0+
- **Tools:** curl, jq, bc
- **Disk:** ~50 MB
- **Internet:** Required for API access

### Installation Check
```bash
# Verify dependencies
bash --version        # Should be 4.0+
curl --version        # Should be installed
jq --version          # Should be installed
bc --version          # Should be installed
```

### Install Missing Dependencies

**macOS (Homebrew):**
```bash
brew install bash curl jq bc
```

**Linux (Ubuntu/Debian):**
```bash
sudo apt-get install bash curl jq bc
```

**Linux (RHEL/CentOS):**
```bash
sudo yum install bash curl jq bc
```

**Windows (WSL):**
```bash
# In WSL terminal
sudo apt-get install bash curl jq bc
```

## Deployment

### Step 1: Extract Package
```bash
tar -xzf StockSwingTrader_v6.2_DualBroker_Deployable.tar.gz
cd StockSwingTrader
chmod +x *.sh robinhood-cli
```

### Step 2: Setup Alpaca (Optional)
```bash
# Copy template
cp config.template.sh config.sh

# Edit with your Alpaca API credentials
nano config.sh
# Add:
# export APCA_API_KEY_ID="your_key"
# export APCA_API_SECRET_KEY="your_secret"

# Test connection
./StockSwingTrader_Agent.sh --check-account
```

### Step 3: Setup Robinhood (Optional)
```bash
# First-time authentication
./robinhood-cli auth
# Opens browser → Login with Robinhood credentials → Authorize

# Test connection
./robinhood-cli account
```

### Step 4: Install to System (Optional)
```bash
# Copy to /opt or /usr/local
sudo cp -r StockSwingTrader /opt/

# Create symlink for easy access
sudo ln -s /opt/StockSwingTrader/robinhood-cli /usr/local/bin/robinhood
sudo ln -s /opt/StockSwingTrader/StockSwingTrader_Agent.sh /usr/local/bin/stockswingtrader

# Now you can run from anywhere:
robinhood account
stockswingtrader --check-account
```

## Usage

### Robinhood Trading (Standalone CLI)

```bash
# Authenticate (one-time)
./robinhood-cli auth

# Check account
./robinhood-cli account

# View positions
./robinhood-cli positions

# Buy shares (market order)
./robinhood-cli buy AAPL 10

# Buy shares (limit order)
./robinhood-cli buy MSFT 5 350

# Sell shares
./robinhood-cli sell GOOGL 3

# Get price quote
./robinhood-cli quote TSLA
```

### Alpaca Trading (Shell Script)

```bash
# Check account
./StockSwingTrader_Agent.sh --check-account

# Analyze stocks
./StockSwingTrader_Agent.sh --symbols AAPL,MSFT

# Place buy order
./StockSwingTrader_Agent.sh --buy AAPL 10

# View positions
./StockSwingTrader_Agent.sh --view-positions
```

## File Structure

```
StockSwingTrader/
├── robinhood-cli                          # Standalone Robinhood CLI
├── StockSwingTrader_Agent.sh              # Main agent (Alpaca)
├── lib/
│   ├── robinhood_mcp_direct.sh            # Direct MCP integration (no Kiro)
│   ├── alpaca_broker.sh                   # Alpaca integration
│   ├── indicators.sh                      # 9 technical indicators
│   ├── indicators_new.sh                  # 3 new indicators
│   ├── strategy_mean_reversion.sh         # Mean reversion strategy
│   ├── strategy_trend_follow.sh           # Trend following strategy
│   ├── risk_management.sh                 # Risk controls
│   ├── trade_journal.sh                   # Trade logging
│   └── scoring.sh                         # Signal scoring
├── tests/
│   ├── test_alpaca_broker.sh              # 65 Alpaca tests
│   └── test_robinhood_broker.sh           # 57 Robinhood tests
├── config.template.sh                     # Configuration template
├── ROBINHOOD_MCP_GUIDE.md                 # Robinhood MCP guide
├── STANDALONE_DEPLOYMENT.md               # This file
└── logs/                                  # Runtime logs (auto-created)
    ├── agent.log
    ├── trades.json
    └── robinhood_mcp.log
```

## Configuration

### Alpaca Config (config.sh)
```bash
# Your Alpaca API credentials
export APCA_API_KEY_ID="your_key_id"
export APCA_API_SECRET_KEY="your_secret_key"

# Optional: Custom endpoints
export APCA_API_BASE_URL="https://paper-api.alpaca.markets"
export ALPACA_DEBUG="false"
```

### Robinhood Config (Environment Variables)
```bash
# Optional: Custom MCP endpoints
export ROBINHOOD_MCP_TRADING_URL="https://agent.robinhood.com/mcp/trading"
export ROBINHOOD_MCP_BANKING_URL="https://banking-agent.robinhood.com/mcp/banking"

# Optional: Custom OAuth
export ROBINHOOD_MCP_CLIENT_ID="robinhood-trading-api"
export ROBINHOOD_MCP_REDIRECT_URI="http://localhost:8888/callback"

# Optional: Debug mode
export ROBINHOOD_DEBUG="true"
```

## Troubleshooting

### "command not found: jq"
```bash
# Install jq
# macOS: brew install jq
# Linux: sudo apt-get install jq
```

### "Permission denied" on scripts
```bash
chmod +x *.sh robinhood-cli
chmod +x lib/*.sh
chmod +x tests/*.sh
```

### Robinhood authentication fails
```bash
# Clear cached tokens
rm ~/.robinhood_mcp_tokens.json

# Try again
./robinhood-cli auth
```

### Alpaca connection fails
```bash
# Check credentials
echo $APCA_API_KEY_ID
echo $APCA_API_SECRET_KEY

# Source config
source config.sh

# Try again
./StockSwingTrader_Agent.sh --check-account
```

### "No module named json"
```bash
# jq is required for JSON parsing
# Install: brew install jq (macOS) or apt-get install jq (Linux)
```

## Running as Daemon/Cron

### Monitor Positions in Background
```bash
# Alpaca
./StockSwingTrader_Agent.sh --monitor-positions &

# Robinhood
./robinhood-cli positions > /tmp/rh_positions.log &
```

### Scheduled Analysis
```bash
# Add to crontab
crontab -e

# Run analysis at market open (9:35 AM EST)
35 9 * * 1-5 cd /opt/StockSwingTrader && ./StockSwingTrader_Agent.sh --top-10 > logs/daily_analysis.log

# Monitor positions every 5 minutes
*/5 9-16 * * 1-5 cd /opt/StockSwingTrader && ./robinhood-cli positions >> logs/robinhood_monitor.log
```

### Docker Deployment (Optional)

Create `Dockerfile`:
```dockerfile
FROM ubuntu:22.04

# Install dependencies
RUN apt-get update && apt-get install -y \
    bash curl jq bc git

# Copy StockSwingTrader
COPY StockSwingTrader /app/StockSwingTrader
WORKDIR /app/StockSwingTrader

# Setup scripts
RUN chmod +x *.sh robinhood-cli lib/*.sh

# Default command
CMD ["/bin/bash"]
```

Build & Run:
```bash
docker build -t stockswingtrader .
docker run -it -v ~/.robinhood_mcp_tokens.json:/root/.robinhood_mcp_tokens.json stockswingtrader
```

## Multi-Broker Usage

### Analyze with Both Brokers
```bash
# Get analysis from StockSwingTrader (no broker needed)
./StockSwingTrader_Agent.sh --top-10 --debug

# Check balances on both brokers
source config.sh
./StockSwingTrader_Agent.sh --check-account    # Alpaca
./robinhood-cli account                        # Robinhood
```

### Trade on Both Simultaneously
```bash
# Terminal 1: Alpaca
source config.sh
./StockSwingTrader_Agent.sh --monitor-positions &

# Terminal 2: Robinhood
./robinhood-cli account
./robinhood-cli buy AAPL 10
```

### Unified Trade Journal
```bash
# Both trades logged to logs/trades.json
cat logs/trades.json | jq '.'

# Filter by broker
cat logs/trades.json | jq '.[] | select(.broker == "alpaca")'
cat logs/trades.json | jq '.[] | select(.broker == "robinhood")'
```

## Performance & Limits

| Resource | Limit | Notes |
|----------|-------|-------|
| **API Calls** | 100/min | Rate limiting per broker |
| **Positions** | 500 max | Per account |
| **Orders** | 50/min | Market hours |
| **Quotes** | 1000/min | Real-time data |
| **Memory** | <100 MB | Typical operation |
| **Disk** | <1 MB | Logs (auto-rotated) |

## Security Best Practices

- ✅ Store API credentials in `config.sh` (not in code)
- ✅ Don't commit `config.sh` to git (use `.gitignore`)
- ✅ Protect `~/.robinhood_mcp_tokens.json` (encrypted locally)
- ✅ Use environment variables for sensitive data
- ✅ Rotate API keys regularly
- ✅ Monitor trade journal for unauthorized activity
- ✅ Run on trusted networks only
- ✅ Keep system updated (security patches)

## Support & Debugging

### Enable Debug Logging
```bash
# Alpaca
export ALPACA_DEBUG="true"
./StockSwingTrader_Agent.sh --debug --check-account

# Robinhood
export ROBINHOOD_DEBUG="true"
./robinhood-cli account
```

### View Logs
```bash
# Agent log
tail -f logs/agent.log

# Trade journal
cat logs/trades.json | jq '.'

# Robinhood MCP log
tail -f logs/robinhood_mcp.log
```

### Run Tests
```bash
# Alpaca tests
bash tests/test_alpaca_broker.sh

# Robinhood tests
bash tests/test_robinhood_broker.sh
```

## Version & Updates

**Current Version:** 6.2  
**Release Date:** 2025-10-28  
**Last Updated:** 2025-10-28

Check for updates:
```bash
cat PACKAGE_VERSION.txt
```

## License & Support

StockSwingTrader v6.2 is provided as-is. For support:
1. Check `TROUBLESHOOTING.md`
2. Review `ROBINHOOD_MCP_GUIDE.md`
3. Enable debug mode and check logs

---

**Happy trading! 🚀**

