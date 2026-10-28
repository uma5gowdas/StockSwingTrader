# StockSwingTrader Agent - Troubleshooting Guide

This guide covers common issues, their causes, and solutions.

---

## Installation & Setup Issues

### Issue: Command not found: bash (macOS)

**Symptoms**:
```
bash: command not found
zsh: command not found: bash
```

**Cause**: System bash version is too old (< 4.0)

**Solution**:
```bash
# Install newer bash via Homebrew
brew install bash

# Verify version
/usr/local/bin/bash --version

# Update shebang if needed
sed -i '' 's##!/bin/bash##!/usr/local/bin/bash#' StockSwingTrader_Agent.sh

# Or use full path to run
/usr/local/bin/bash ./StockSwingTrader_Agent.sh --help
```

### Issue: Permission Denied

**Symptoms**:
```
-bash: ./StockSwingTrader_Agent.sh: Permission denied
```

**Cause**: Script doesn't have execute permissions

**Solution**:
```bash
chmod +x StockSwingTrader_Agent.sh
chmod +x lib/*.sh
ls -la StockSwingTrader_Agent.sh  # verify rwxr-xr-x
```

### Issue: Missing Required Tools (curl, bc)

**Symptoms**:
```
command not found: curl
command not found: bc
```

**Cause**: Required utility not installed

**Solution - macOS**:
```bash
# curl is usually pre-installed, but if missing:
brew install curl

# Install bc for floating-point math
brew install bc
```

**Solution - Linux (Debian/Ubuntu)**:
```bash
sudo apt-get update
sudo apt-get install -y curl bc
```

**Solution - Linux (CentOS/RHEL)**:
```bash
sudo yum install -y curl bc
```

### Issue: No jq installed (Warning)

**Symptoms**:
```
WARNING: jq not found. Some JSON parsing features disabled.
```

**Status**: This is a warning, not a blocker. Agent continues with reduced JSON parsing.

**Solution** (optional):
```bash
# macOS
brew install jq

# Linux Debian/Ubuntu
sudo apt-get install jq

# Linux CentOS/RHEL
sudo yum install jq
```

---

## Configuration Issues

### Issue: config.template.sh not found

**Symptoms**:
```
ERROR: config.template.sh not found
```

**Cause**: Script is not in the correct directory

**Solution**:
```bash
# Verify you're in the right directory
pwd
# Should show: .../StockSwingTrader

# Verify config.template.sh exists
ls -la config.template.sh

# If missing, check project structure:
ls -la
# Should show: StockSwingTrader_Agent.sh, config.template.sh, lib/, etc.
```

### Issue: API Key Not Recognized

**Symptoms**:
```
Authentication error: 401 Unauthorized
Invalid API key
```

**Cause**: API key is invalid, expired, or not configured correctly

**Solution**:
```bash
# 1. Verify config.sh exists and has your key
cp config.template.sh config.sh
nano config.sh  # or vim/code

# 2. Check the key format (no quotes usually)
export API_KEY_ALPHA_VANTAGE="abc123xyz"  # correct
export API_KEY_ALPHA_VANTAGE=abc123xyz    # also works

# 3. Verify the key is active in the API provider's dashboard:
# Alpha Vantage: https://www.alphavantage.co/
# Finnhub: https://finnhub.io/

# 4. Test the key directly
curl "https://www.alphavantage.co/query?function=GLOBAL_QUOTE&symbol=AAPL&apikey=YOUR_KEY"

# 5. If test fails, regenerate the key in the API dashboard
```

### Issue: Demo Mode Not Working

**Symptoms**:
```
ERROR: No API data available and demo mode disabled
```

**Cause**: Demo mode settings are off or config is invalid

**Solution**:
```bash
# Verify demo mode is enabled in config
grep "DEMO_MODE" config.template.sh

# It should show:
export DEMO_MODE="1"  # or "true"

# Run with explicit demo flag
bash StockSwingTrader_Agent.sh --symbols AAPL --debug
```

---

## API & Data Fetching Issues

### Issue: API Rate Limiting (429 Too Many Requests)

**Symptoms**:
```
HTTP/1.1 429 Too Many Requests
Rate limit exceeded
```

**Cause**: Too many API calls in quick succession

**Explanation**:
- Alpha Vantage: 5 requests/minute (free tier)
- Finnhub: 60 requests/minute (free tier)

**Solution**:
```bash
# Option 1: Increase delay between requests
# Edit config.sh and set:
export API_CALL_DELAY="2"  # 2 seconds between calls (default: 0.2)

# Option 2: Analyze fewer stocks at once
./StockSwingTrader_Agent.sh --symbols AAPL,MSFT  # instead of 10

# Option 3: Wait before re-running
# Wait 60+ seconds, then try again

# Option 4: Upgrade API tier
# Consider paid plan for higher limits
```

### Issue: API Timeout (Connection Timeout)

**Symptoms**:
```
curl: (28) Operation timed out
Connection timeout
```

**Cause**: API server is slow or unreachable

**Solution**:
```bash
# 1. Check if the API is available
curl -I https://www.alphavantage.co/
# Should return HTTP 200

# 2. Try a simpler request first
curl "https://www.alphavantage.co/query?function=GLOBAL_QUOTE&symbol=AAPL&apikey=demo"

# 3. Increase timeout in config.sh
export API_TIMEOUT="30"  # increased from default

# 4. Check internet connection
ping 8.8.8.8

# 5. Try again later (API may be temporarily down)
```

### Issue: No Data Returned from API

**Symptoms**:
```
Error message: null, undefined, or empty response
Technical indicators show as 0 or N/A
```

**Cause**: API returned empty or invalid data

**Solution**:
```bash
# 1. Enable debug logging to see raw API responses
./StockSwingTrader_Agent.sh --symbols AAPL --debug

# 2. Check the API response directly
curl "https://www.alphavantage.co/query?function=TIME_SERIES_DAILY&symbol=AAPL&apikey=YOUR_KEY" | head

# 3. Verify the symbol exists
# Try well-known symbols: AAPL, MSFT, GOOGL, TSLA, AMZN

# 4. Check if stock is trading
# Market holidays and after-hours data may not be available

# 5. Verify API credits/quota
# Check your API dashboard for remaining requests
```

### Issue: Data is Stale or Cached

**Symptoms**:
```
Report shows old prices or dates
"Data as of 2 hours ago" or older
```

**Cause**: Agent is using cached data

**Solution**:
```bash
# 1. Clear the cache
rm -rf cache/data/*

# 2. Re-run analysis (will fetch fresh data)
./StockSwingTrader_Agent.sh --symbols AAPL

# 3. Configure cache duration in config.sh
export CACHE_TTL="3600"  # cache for 1 hour (3600 seconds)

# 4. Force fresh data on next run
export FORCE_FRESH_DATA="1"
./StockSwingTrader_Agent.sh --symbols AAPL
```

---

## Data & Analysis Issues

### Issue: Technical Indicators Show Zero Values

**Symptoms**:
```
RSI: 0
MACD: 0
Bollinger Bands: upper=0, middle=0, lower=0
```

**Cause**: Insufficient price data or calculation error

**Solution**:
```bash
# 1. Verify price data is available
# Check logs
tail -50 logs/agent.log

# 2. Try a well-established stock
./StockSwingTrader_Agent.sh --symbols AAPL

# 3. Enable debug for detailed output
./StockSwingTrader_Agent.sh --symbols AAPL --debug | grep -i "price\|data"

# 4. Verify bc is working correctly
echo "100 / 3" | bc -l  # should return 33.33...

# 5. Check if stock has enough historical data (20+ days)
# New stocks or recently listed may not have sufficient data
```

### Issue: Sentiment Analysis Returns N/A

**Symptoms**:
```
Twitter Sentiment: N/A
Reddit Sentiment: N/A
Overall Sentiment Score: Unable to calculate
```

**Cause**: Sentiment API unavailable or no data available

**Solution**:
```bash
# 1. Check if sentiment APIs are accessible
curl -s https://api.twitter.com/  # may require auth

# 2. Try a major stock with more social discussion
./StockSwingTrader_Agent.sh --symbols TSLA,GME,NVDA

# 3. Run during market hours for fresher sentiment
# 9:30 AM - 4:00 PM ET is optimal

# 4. Check internet connectivity
ping 8.8.8.8

# 5. Verify sentiment API keys in config.sh (if using premium)
```

### Issue: Confidence Scores Are All 50 (Neutral)

**Symptoms**:
```
All stocks show 50% confidence
All signals show HOLD
```

**Cause**: Conflicting indicators or insufficient data

**Solution**:
```bash
# 1. Check if price data is fetched
tail logs/agent.log | grep -i "price\|aapl"

# 2. Verify at least one indicator is calculating
./StockSwingTrader_Agent.sh --symbols AAPL --debug | grep -i "rsi\|macd\|signal"

# 3. Try a well-established stock with clear trends
./StockSwingTrader_Agent.sh --symbols AAPL  # not a penny stock

# 4. Check if market conditions are neutral
# During sideways markets, all indicators may show neutral signals

# 5. Review the technical analysis manually
# Open the HTML report and verify calculations look reasonable
```

---

## Report Generation Issues

### Issue: HTML Report Not Created

**Symptoms**:
```
No files in output/reports/
ERROR: Report generation failed
```

**Cause**: File system permissions or report generation error

**Solution**:
```bash
# 1. Verify output directory exists and is writable
mkdir -p output/reports
chmod 755 output/reports
chmod 755 output

# 2. Check if html_report.sh is present
ls -la lib/html_report.sh

# 3. Run with debug to see generation process
./StockSwingTrader_Agent.sh --symbols AAPL --debug

# 4. Check disk space
df -h
# Should have at least 50MB free

# 5. Verify file permissions after run
ls -la output/reports/
```

### Issue: HTML Report Opens Incorrectly

**Symptoms**:
```
Browser shows garbled text
Charts don't display
CSS styling missing
```

**Cause**: HTML file is corrupted or browser compatibility issue

**Solution**:
```bash
# 1. Try a different browser
# Chrome, Firefox, Safari all supported

# 2. Clear browser cache
# Chrome: Ctrl+Shift+Del, select "All time"

# 3. Check file integrity
file output/reports/swing_analysis_*.html
# Should show: HTML document, ASCII text

# 4. Verify the file size is reasonable
ls -lh output/reports/swing_analysis_*.html
# Should be 100KB - 500KB

# 5. Regenerate the report
rm output/reports/swing_analysis_*.html
./StockSwingTrader_Agent.sh --symbols AAPL
```

---

## Logging & Debugging

### Issue: No Log File Created

**Symptoms**:
```
logs/agent.log doesn't exist or is empty
```

**Cause**: Log directory permissions or debug disabled

**Solution**:
```bash
# 1. Create logs directory
mkdir -p logs
chmod 755 logs

# 2. Run with debug flag
./StockSwingTrader_Agent.sh --symbols AAPL --debug

# 3. Verify logging is enabled in config
grep "DEBUG\|LOG" config.template.sh

# 4. Check permissions
ls -la logs/

# 5. Manually create log file
touch logs/agent.log
chmod 644 logs/agent.log
```

### Issue: Debug Output Too Verbose

**Symptoms**:
```
Hundreds of lines of debug output
Hard to find actual errors
```

**Solution**:
```bash
# 1. Filter logs for errors only
./StockSwingTrader_Agent.sh --symbols AAPL --debug 2>&1 | grep -i "error\|fail"

# 2. Run without debug flag for cleaner output
./StockSwingTrader_Agent.sh --symbols AAPL

# 3. Save debug output to file for analysis
./StockSwingTrader_Agent.sh --symbols AAPL --debug > debug_output.txt 2>&1

# 4. Check specific sections
tail -100 logs/agent.log
tail -50 logs/agent.log | grep "AAPL"
```

---

## Performance Issues

### Issue: Script Runs Very Slowly

**Symptoms**:
```
Takes 2+ minutes to analyze 5 stocks
API calls appear stuck
```

**Cause**: API rate limiting, network latency, or system resources

**Solution**:
```bash
# 1. Check network connectivity
ping 8.8.8.8
curl -I https://www.alphavantage.co/

# 2. Reduce number of stocks
./StockSwingTrader_Agent.sh --symbols AAPL  # instead of 10

# 3. Increase API delay to reduce rate limiting
export API_CALL_DELAY="1"  # 1 second between calls

# 4. Check system resources
top  # or Activity Monitor (macOS)
# Should have 500MB+ free RAM

# 5. Disable unnecessary features
# Remove sentiment analysis if not needed

# 6. Use cached data when available
# Run same symbols again (uses cache)
```

### Issue: High CPU Usage

**Symptoms**:
```
Script uses 80%+ CPU
System becomes sluggish
```

**Cause**: Complex calculations or inefficient loops

**Solution**:
```bash
# 1. Check which process is using CPU
top -o %CPU
# Identify if it's bash or a sub-process

# 2. Reduce number of calculations
./StockSwingTrader_Agent.sh --symbols AAPL  # fewer stocks

# 3. Disable debug mode (debug adds overhead)
# Remove --debug flag

# 4. Use simpler analysis
# Limit to key indicators only

# 5. Wait for process to complete
# Background calculations may take time
```

---

## Platform-Specific Issues

### macOS Issues

**Issue: "zsh: command not found: bash"**
```bash
# Solution: Use full path or brew-installed bash
/usr/local/bin/bash StockSwingTrader_Agent.sh --help

# Or make it default
chsh -s /usr/local/bin/bash
```

**Issue: Permission denied on first run**
```bash
# Solution
chmod +x *.sh lib/*.sh
```

### Linux Issues

**Issue: "command not found: curl"**
```bash
# Debian/Ubuntu
sudo apt-get install curl bc

# CentOS/RHEL
sudo yum install curl bc
```

**Issue: sed incompatibility**
```bash
# Use gnu-sed on BSD/macOS
brew install gnu-sed
# Or use gawk instead
```

### WSL (Windows Subsystem for Linux)

**Issue: Performance is very slow**
```bash
# Ensure WSL2 (not WSL1)
wsl --list -v

# Upgrade if needed
wsl --set-version <distro> 2

# Mount project outside /mnt for better performance
cd ~/projects/StockSwingTrader
```

---

## Getting More Help

### Enable Maximum Debug Output

```bash
# Run with all debugging enabled
bash -x ./StockSwingTrader_Agent.sh --symbols AAPL --debug 2>&1 | tee full_debug.log
```

### Capture Complete Error Information

```bash
# Save everything to a file for analysis
{
    echo "=== System Information ==="
    bash --version
    curl --version
    bc --version || echo "bc not found"
    echo ""
    echo "=== Directory Contents ==="
    ls -la
    echo ""
    echo "=== Running Agent ==="
    ./StockSwingTrader_Agent.sh --symbols AAPL --debug
} > troubleshoot_report.txt 2>&1
```

### Check Known Issues

1. Review logs/agent.log for specific error codes
2. Check API provider status pages (Alpha Vantage, Finnhub)
3. Verify market is open (US trading hours: 9:30 AM - 4:00 PM ET)
4. Check project documentation (README.md, API_SETUP_GUIDE.md)

---

## Still Need Help?

When reporting issues, provide:

1. **Error message** - Exact text from terminal or logs
2. **Command run** - What you typed: `./StockSwingTrader_Agent.sh --symbols AAPL --debug`
3. **System info** - `bash --version`, OS name, processor
4. **Recent logs** - Last 50 lines from `logs/agent.log`
5. **Attempted solutions** - What you've already tried

This information helps diagnose the issue quickly.
