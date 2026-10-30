# StockSwingTrader v6.3 - Installation Guide

**Version:** 6.3  
**Last Updated:** October 30, 2024  
**Time to Complete:** 15-30 minutes

---

## Table of Contents

1. [System Requirements](#system-requirements)
2. [Pre-Installation Checklist](#pre-installation-checklist)
3. [Step-by-Step Installation](#step-by-step-installation)
4. [Dependencies Installation](#dependencies-installation)
5. [Configuration](#configuration)
6. [Verification](#verification)
7. [Troubleshooting](#troubleshooting)

---

## System Requirements

### Minimum Requirements

| Component | Minimum Version | Recommended |
|-----------|-----------------|-------------|
| **OS** | macOS 10.15 / Ubuntu 18.04 | macOS 12+ / Ubuntu 20.04+ |
| **Bash** | 4.0 | 5.0+ |
| **Python** | 3.8 | 3.10+ |
| **Node.js** | 14.0 | 18.0+ |
| **npm** | 6.0 | 8.0+ |
| **Git** | 2.0 | 2.30+ |
| **Disk Space** | 1 GB | 5 GB (with history) |
| **RAM** | 4 GB | 8 GB (for backtesting) |

### OS-Specific Commands

#### macOS
```bash
# Install Homebrew (if not installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install prerequisites
brew install bash python@3.11 node@18 git
```

#### Ubuntu/Debian
```bash
# Update package manager
sudo apt-get update

# Install prerequisites
sudo apt-get install -y bash python3.11 python3.11-venv nodejs npm git
```

#### WSL2 on Windows
```bash
# Inside WSL2 Ubuntu terminal, follow Ubuntu instructions above
```

---

## Pre-Installation Checklist

```bash
# Verify Bash version
bash --version
# Should show: GNU bash, version 4.0 or higher

# Verify Python version
python3 --version
# Should show: Python 3.8 or higher

# Verify Node.js version
node --version
# Should show: v14.0.0 or higher

# Verify npm version
npm --version
# Should show: 6.0.0 or higher

# Verify Git
git --version
# Should show: git version 2.0 or higher
```

---

## Step-by-Step Installation

### Step 1: Clone Repository

```bash
# Clone from GitHub
git clone https://github.com/uma5gowdas/StockSwingTrader.git
cd StockSwingTrader

# Checkout v6.3 branch
git checkout v6.3

# Verify you're on correct branch
git branch -v
# Should show: * v6.3 ...
```

### Step 2: Create Python Virtual Environment (Recommended)

```bash
# Create virtual environment
python3 -m venv venv

# Activate virtual environment
# On macOS/Linux:
source venv/bin/activate

# On Windows (Command Prompt):
# venv\Scripts\activate

# On Windows (PowerShell):
# .\venv\Scripts\Activate.ps1

# Verify activation
which python
# Should show: path/to/venv/bin/python
```

### Step 3: Install Python Dependencies

```bash
# Upgrade pip
pip install --upgrade pip setuptools wheel

# Install requirements
pip install -r requirements.txt

# Verify installations
pip list
# Should show all required packages
```

### Step 4: Install Backend Dependencies

```bash
# Navigate to backend directory
cd backend

# Install npm packages
npm install

# Verify installation
npm list
# Should show dependency tree

# Return to root
cd ..
```

### Step 5: Install Frontend Dependencies

```bash
# Navigate to frontend directory
cd frontend

# Install npm packages
npm install

# Verify installation
npm list
# Should show dependency tree

# Return to root
cd ..
```

### Step 6: Make Scripts Executable

```bash
# Make main agent executable
chmod +x StockSwingTrader_Agent.sh

# Make all shell scripts executable
find . -name "*.sh" -type f -exec chmod +x {} \;

# Verify permissions
ls -la StockSwingTrader_Agent.sh
# Should show: -rwxr-xr-x
```

---

## Dependencies Installation

### Python Packages (in requirements.txt)

```txt
numpy>=1.21.0              # Numerical computing
pandas>=1.3.0              # Data manipulation
scikit-learn>=1.0.0        # Machine learning utilities
xgboost>=1.5.0             # ML model framework
requests>=2.26.0           # HTTP requests
alpha-vantage>=2.3.1       # Stock market data
finnhub-python>=1.2.8      # Financial data API
tweepy>=4.0.0              # Twitter data
newsapi>=1.4.1             # News data
python-dotenv>=0.19.0      # Environment variables
joblib>=1.1.0              # Model persistence
requests-oauthlib>=1.3.0   # OAuth authentication
```

**Installation Command:**
```bash
pip install -r requirements.txt

# Or install individually:
pip install numpy pandas scikit-learn xgboost requests \
    alpha-vantage finnhub-python tweepy newsapi \
    python-dotenv joblib requests-oauthlib
```

### Node.js Packages - Backend

**Located in:** `backend/package.json`

Key dependencies:
- `express` - Web framework
- `axios` - HTTP client
- `dotenv` - Environment configuration
- `cors` - Cross-origin support
- `body-parser` - Request parsing

**Installation:**
```bash
cd backend
npm install
```

### Node.js Packages - Frontend

**Located in:** `frontend/package.json`

Key dependencies:
- `react` - UI library
- `typescript` - Type safety
- `vite` - Build tool
- `recharts` - Charts library
- `tailwindcss` - CSS framework
- `axios` - HTTP client

**Installation:**
```bash
cd frontend
npm install
```

---

## Configuration

### Step 1: Create Configuration File

```bash
# Copy template configuration
cp config.template.sh config.sh

# Or for Robinhood:
cp config.template.sh config.robinhood.sh
```

### Step 2: Edit Configuration

```bash
# Edit with your favorite editor
nano config.sh
# or
vim config.sh
# or
code config.sh  # VS Code
```

### Step 3: Set Required API Keys

```bash
# In config.sh, set these variables:

export ALPHA_VANTAGE_API_KEY="your_alpha_vantage_key"
export FINNHUB_API_KEY="your_finnhub_key"
export ALPACA_API_KEY="your_alpaca_key"
export ALPACA_SECRET_KEY="your_alpaca_secret"
export ALPACA_BASE_URL="https://paper-api.alpaca.markets"  # Paper trading

# Optional: Robinhood (if using robinhood broker)
export RH_USERNAME="your_robinhood_username"
export RH_PASSWORD="your_robinhood_password"

# Optional: Social media (for sentiment)
export TWITTER_API_KEY="your_twitter_key"
export STOCKTWITS_API_KEY="your_stocktwits_key"
export NEWSAPI_KEY="your_newsapi_key"
```

### Step 4: Load Configuration

```bash
# Load configuration in current session
source config.sh

# Or add to ~/.bashrc for automatic loading
echo "source ~/path/to/StockSwingTrader/config.sh" >> ~/.bashrc
source ~/.bashrc
```

### API Key Acquisition

#### Alpha Vantage (Free)
1. Go to: https://www.alphavantage.co/
2. Click "Get Free API Key"
3. Enter email, click "GET FREE API KEY"
4. Check email for API key
5. Add to config.sh

#### Finnhub (Free)
1. Go to: https://finnhub.io/
2. Sign up for free account
3. Log in to dashboard
4. Copy API key from profile
5. Add to config.sh

#### Alpaca (Free Paper Trading)
1. Go to: https://alpaca.markets/
2. Sign up for account
3. Verify email
4. Get API keys from dashboard
5. Use paper trading endpoint
6. Add to config.sh

#### Robinhood (Free)
1. Install Robinhood app
2. Create account and verify
3. Use credentials in config.robinhood.sh
4. Note: Official API not available, uses unofficial integration

---

## Verification

### Verify Installation

```bash
# 1. Check main agent
./StockSwingTrader_Agent.sh --help
# Should show help message

# 2. Test Python modules
python lib/ml_inference.py --test
# Should complete without errors

# 3. Check ML model
python -c "import joblib; m = joblib.load('lib/models/xgboost_predictor.pkl'); print(f'Model loaded: {type(m)}')"
# Should output: Model loaded: <class 'xgboost.sklearn.XGBClassifier'>

# 4. Check backend
cd backend && npm start &
sleep 2
curl http://localhost:3001/health
# Should return OK or similar
kill %1  # Stop background process

# 5. Verify frontend build
cd frontend && npm run build
# Should complete without errors

# 6. Test API connectivity
bash tests/verify_dependencies.sh
```

### Run Test Suite

```bash
# Unit tests (if configured)
bash tests/test_indicators.sh

# Integration tests
bash tests/test_ml_scoring_integration.sh

# Kalman filter tests
bash tests/test_kalman_filter.sh

# Regime detector tests
bash tests/test_regime_detector.sh
```

### Quick Functionality Test

```bash
# Test with demo data (no API calls needed)
./StockSwingTrader_Agent.sh --demo --symbols AAPL

# Check output exists
ls -la .agents/tasks/analysis_*_AAPL.json

# Verify JSON format
jq . .agents/tasks/analysis_*_AAPL.json | head -20
```

---

## Troubleshooting

### Common Installation Issues

#### Python Module Not Found

**Problem:**
```
ModuleNotFoundError: No module named 'xgboost'
```

**Solution:**
```bash
# Verify virtual environment is activated
which python  # Should show /path/to/venv/bin/python

# Reinstall requirements
pip install --upgrade -r requirements.txt

# Verify installation
python -c "import xgboost; print(xgboost.__version__)"
```

#### Node Modules Missing

**Problem:**
```
Error: Cannot find module 'express'
```

**Solution:**
```bash
# Navigate to backend/frontend directory
cd backend  # or frontend

# Reinstall npm packages
rm -rf node_modules package-lock.json
npm install

# Verify installation
npm list express
```

#### Git Clone Failed

**Problem:**
```
fatal: unable to access repository
```

**Solution:**
```bash
# Check internet connection
ping github.com

# Try HTTPS (instead of SSH)
git clone https://github.com/uma5gowdas/StockSwingTrader.git

# Or use git with verbose output
git clone -v https://github.com/uma5gowdas/StockSwingTrader.git
```

#### Permission Denied

**Problem:**
```
bash: ./StockSwingTrader_Agent.sh: Permission denied
```

**Solution:**
```bash
# Make scripts executable
chmod +x StockSwingTrader_Agent.sh

# Or make all shell scripts executable
find . -name "*.sh" -type f -exec chmod +x {} \;

# Verify
ls -la StockSwingTrader_Agent.sh
# Should show: -rwxr-xr-x
```

#### Port Already in Use

**Problem:**
```
Error: listen EADDRINUSE: address already in use :::3001
```

**Solution:**
```bash
# Kill process using port 3001
lsof -i :3001
kill -9 <PID>

# Or use different port
export PORT=3002
npm start
```

#### API Key Invalid

**Problem:**
```
Error: Invalid API key or rate limit exceeded
```

**Solution:**
```bash
# Verify API key format
echo $ALPHA_VANTAGE_API_KEY

# Check API key validity
curl "https://www.alphavantage.co/query?function=GLOBAL_QUOTE&symbol=IBM&apikey=$ALPHA_VANTAGE_API_KEY"

# Re-enter API key in config.sh
nano config.sh

# Reload configuration
source config.sh
```

---

## Post-Installation

### First Run

```bash
# 1. Activate virtual environment (if using)
source venv/bin/activate

# 2. Load configuration
source config.sh

# 3. Run single symbol analysis
./StockSwingTrader_Agent.sh --symbols AAPL

# 4. Check results
cat .agents/tasks/analysis_*_AAPL.json | jq .

# 5. Expected output: JSON with analysis results
```

### Start Dashboard

```bash
# Terminal 1: Start Backend
cd backend && npm start
# Should output: Server running on http://localhost:3001

# Terminal 2: Start Frontend
cd frontend && npm run dev
# Should output: http://localhost:5173

# Open browser and visit: http://localhost:5173
```

### Next Steps

1. **Review Documentation:** Read docs/ directory
2. **Explore Features:** Try different command flags
3. **Configure Alerts:** Set up price/score alerts
4. **Connect Broker:** Follow broker setup guides
5. **Start Trading:** Begin paper trading analysis

---

## Support

If you encounter issues:

1. **Check logs:**
   ```bash
   tail -f logs/trading_$(date +%Y%m%d).log
   ```

2. **Enable debug mode:**
   ```bash
   export DEBUG_MODE=true
   ./StockSwingTrader_Agent.sh --symbols AAPL
   ```

3. **Run verification:**
   ```bash
   bash tests/verify_dependencies.sh
   ```

4. **Check documentation:**
   - `README.md` - Quick start
   - `FEATURES.md` - Feature descriptions
   - `ARCHITECTURE.md` - System design
   - `.kiro/steering/stockswingtrader-v6.3.md` - Complete reference

---

**Installation Complete!** Ready to start trading? Run:
```bash
./StockSwingTrader_Agent.sh --symbols AAPL,MSFT --ml --regime-adapt
```
