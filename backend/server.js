const express = require('express');
const cors = require('cors');
const dotenv = require('dotenv');
const axios = require('axios');
const { execFile } = require('child_process');
const path = require('path');
const fs = require('fs');
const util = require('util');

const execFilePromise = util.promisify(execFile);

dotenv.config();

const app = express();
const PORT = process.env.PORT || 3000;
// Paths can be overridden via env (used by tests/test_backend.js).
const BASE_PATH = path.resolve(process.env.SST_BASE_PATH || path.join(__dirname, '..'));
const LOG_FILE = path.resolve(process.env.SST_LOG_FILE || '/Users/P3291917/Builds/6/.agents/tasks/backend.log');
const BACKTEST_DIR = path.resolve(process.env.BACKTEST_OUTPUT_DIR || '/Users/P3291917/Builds/6/.agents/tasks/backtest_results');

// Ticker symbols: letters, digits, dot or dash, max 10 chars (same rule as the
// frontend). Symbols are passed to bash scripts, so anything else is rejected.
const SYMBOL_PATTERN = /^[A-Z][A-Z0-9.-]{0,9}$/;

// Run a lib/ script with arguments passed directly (no shell interpolation).
function runScript(scriptPath, args, timeout) {
  return execFilePromise('bash', [scriptPath, ...args], { cwd: BASE_PATH, timeout });
}

// Validate :symbol; sends a 400 and returns null when invalid.
function validSymbol(req, res) {
  const symbol = String(req.params.symbol || '').toUpperCase();
  if (!SYMBOL_PATTERN.test(symbol)) {
    logRequest('WARN', 'Invalid symbol rejected', { symbol: req.params.symbol });
    res.status(400).json({ error: 'Invalid symbol' });
    return null;
  }
  return symbol;
}

// Ensure log directory exists
const logDir = path.dirname(LOG_FILE);
if (!fs.existsSync(logDir)) {
  fs.mkdirSync(logDir, { recursive: true });
}

// Logging utility
function logRequest(level, message, data = null) {
  const timestamp = new Date().toISOString();
  const logMessage = data ? `[${timestamp}] ${level}: ${message} ${JSON.stringify(data)}` : `[${timestamp}] ${level}: ${message}`;
  console.log(logMessage);
  fs.appendFileSync(LOG_FILE, logMessage + '\n');
}

// Middleware
app.use(cors({
  origin: ['http://localhost:3000', 'http://localhost:5173'],
  credentials: true
}));
app.use(express.json());

// Health check
app.get('/api/health', (req, res) => {
  logRequest('INFO', 'Health check requested');
  res.json({ status: 'healthy', timestamp: new Date().toISOString() });
});

// GET /api/portfolio - Execute bash script to get portfolio state
app.get('/api/portfolio', async (req, res) => {
  try {
    logRequest('INFO', 'Portfolio state requested');
    const scriptPath = path.join(BASE_PATH, 'lib', 'alpaca_broker.sh');
    
    if (!fs.existsSync(scriptPath)) {
      logRequest('ERROR', 'Portfolio script not found', { path: scriptPath });
      return res.status(500).json({ error: 'Portfolio script not found' });
    }

    const { stdout } = await runScript(scriptPath, ['get-portfolio'], 15000);

    try {
      const data = JSON.parse(stdout);
      logRequest('INFO', 'Portfolio data retrieved successfully');
      res.json(data);
    } catch (parseErr) {
      logRequest('ERROR', 'Failed to parse portfolio response', { error: parseErr.message });
      res.json({ raw: stdout });
    }
  } catch (error) {
    logRequest('ERROR', 'Portfolio retrieval failed', { error: error.message });
    res.status(500).json({ error: error.message });
  }
});

// GET /api/quotes/:symbol - Get real-time quote data
app.get('/api/quotes/:symbol', async (req, res) => {
  try {
    const symbol = validSymbol(req, res);
    if (!symbol) return;
    logRequest('INFO', `Quote requested for symbol: ${symbol}`);
    
    const scriptPath = path.join(BASE_PATH, 'lib', 'alpaca_broker.sh');
    
    if (!fs.existsSync(scriptPath)) {
      logRequest('ERROR', 'Quote script not found', { path: scriptPath });
      return res.status(500).json({ error: 'Quote script not found' });
    }

    const { stdout } = await runScript(scriptPath, ['get-quote', symbol], 10000);

    try {
      const data = JSON.parse(stdout);
      logRequest('INFO', `Quote retrieved for ${symbol}`);
      res.json(data);
    } catch (parseErr) {
      logRequest('ERROR', `Failed to parse quote response for ${symbol}`, { error: parseErr.message });
      res.json({ symbol, raw: stdout });
    }
  } catch (error) {
    logRequest('ERROR', `Quote retrieval failed for ${req.params.symbol}`, { error: error.message });
    res.status(500).json({ error: error.message });
  }
});

// GET /api/signals/:symbol - Execute scoring pipeline, return confluence score
app.get('/api/signals/:symbol', async (req, res) => {
  try {
    const symbol = validSymbol(req, res);
    if (!symbol) return;
    logRequest('INFO', `Signals requested for symbol: ${symbol}`);
    
    const scriptPath = path.join(BASE_PATH, 'lib', 'scoring.sh');
    
    if (!fs.existsSync(scriptPath)) {
      logRequest('ERROR', 'Scoring script not found', { path: scriptPath });
      return res.status(500).json({ error: 'Scoring script not found' });
    }

    const { stdout } = await runScript(scriptPath, [symbol], 20000);

    try {
      const data = JSON.parse(stdout);
      logRequest('INFO', `Signals calculated for ${symbol}`, { confluence: data.confluence_score });
      res.json(data);
    } catch (parseErr) {
      logRequest('ERROR', `Failed to parse signals for ${symbol}`, { error: parseErr.message });
      res.json({ symbol, raw: stdout });
    }
  } catch (error) {
    logRequest('ERROR', `Signal calculation failed for ${req.params.symbol}`, { error: error.message });
    res.status(500).json({ error: error.message });
  }
});

// GET /api/indicators/:symbol - Get technical indicators
app.get('/api/indicators/:symbol', async (req, res) => {
  try {
    const symbol = validSymbol(req, res);
    if (!symbol) return;
    logRequest('INFO', `Indicators requested for symbol: ${symbol}`);
    
    const scriptPath = path.join(BASE_PATH, 'lib', 'indicators_new.sh');
    
    if (!fs.existsSync(scriptPath)) {
      logRequest('ERROR', 'Indicators script not found', { path: scriptPath });
      return res.status(500).json({ error: 'Indicators script not found' });
    }

    const { stdout } = await runScript(scriptPath, [symbol], 15000);

    try {
      const data = JSON.parse(stdout);
      logRequest('INFO', `Indicators retrieved for ${symbol}`);
      res.json(data);
    } catch (parseErr) {
      logRequest('ERROR', `Failed to parse indicators for ${symbol}`, { error: parseErr.message });
      res.json({ symbol, raw: stdout });
    }
  } catch (error) {
    logRequest('ERROR', `Indicators retrieval failed for ${req.params.symbol}`, { error: error.message });
    res.status(500).json({ error: error.message });
  }
});

// GET /api/trades - Get trade history from log file
app.get('/api/trades', (req, res) => {
  try {
    logRequest('INFO', 'Trade history requested');
    
    const tradeLogPath = path.join(BASE_PATH, '.trades', 'trade_log.json');
    
    if (!fs.existsSync(tradeLogPath)) {
      logRequest('WARN', 'Trade log not found', { path: tradeLogPath });
      return res.json({ trades: [], message: 'No trade history available' });
    }

    const trades = JSON.parse(fs.readFileSync(tradeLogPath, 'utf-8'));
    logRequest('INFO', 'Trade history retrieved', { count: Array.isArray(trades) ? trades.length : 1 });
    res.json({ trades: Array.isArray(trades) ? trades : [trades] });
  } catch (error) {
    logRequest('ERROR', 'Trade history retrieval failed', { error: error.message });
    res.status(500).json({ error: error.message });
  }
});

// GET /api/stats - Calculate portfolio statistics
app.get('/api/stats', async (req, res) => {
  try {
    logRequest('INFO', 'Statistics requested');
    
    const scriptPath = path.join(BASE_PATH, 'lib', 'risk_management.sh');
    
    if (!fs.existsSync(scriptPath)) {
      logRequest('ERROR', 'Stats script not found', { path: scriptPath });
      return res.status(500).json({ error: 'Stats script not found' });
    }

    const { stdout } = await runScript(scriptPath, ['calculate-stats'], 10000);

    try {
      const data = JSON.parse(stdout);
      logRequest('INFO', 'Statistics calculated successfully');
      res.json(data);
    } catch (parseErr) {
      logRequest('ERROR', 'Failed to parse statistics', { error: parseErr.message });
      res.json({ raw: stdout });
    }
  } catch (error) {
    logRequest('ERROR', 'Statistics calculation failed', { error: error.message });
    res.status(500).json({ error: error.message });
  }
});

// Setting names whose values are credentials and must be masked in responses.
const SECRET_SETTING_PATTERN = /KEY|SECRET|TOKEN|PASSWORD|PASS|AUTH|CREDENTIAL/i;

// Editable settings and their value validators (return an error string or null).
const isNonNegativeNumber = (v) => /^\d+(\.\d+)?$/.test(v) && Number.isFinite(Number(v));
const SETTING_VALIDATORS = {
  RISK_PER_TRADE: (v) => (isNonNegativeNumber(v) ? null : 'must be a non-negative number'),
  MAX_POSITION_SIZE: (v) => (isNonNegativeNumber(v) ? null : 'must be a non-negative number'),
  MIN_CONFLUENCE_SCORE: (v) =>
    isNonNegativeNumber(v) && Number(v) <= 100 ? null : 'must be a number from 0 to 100',
  TRADING_ENABLED: (v) => (v === 'true' || v === 'false' ? null : 'must be true or false'),
};

// Whole-line match for one setting: groups = (prefix incl. "NAME="), (value), (trailing comment).
const settingLineRegex = (name) =>
  new RegExp(`^([ \\t]*(?:export[ \\t]+)?${name}=)("[^"\\n]*"|'[^'\\n]*'|[^\\s#]*)([ \\t]*(?:#.*)?)$`, 'm');

// POST /api/settings - Update configuration
app.post('/api/settings', async (req, res) => {
  try {
    const { setting, value } = req.body;
    logRequest('INFO', 'Settings update requested', { setting, value });

    const configPath = path.join(BASE_PATH, 'config.sh');
    
    if (!fs.existsSync(configPath)) {
      logRequest('ERROR', 'Config file not found', { path: configPath });
      return res.status(500).json({ error: 'Config file not found' });
    }

    // For safety, only allow specific settings, each with a strict value format.
    // Values are written unquoted into a file the agent sources, so anything
    // outside these patterns (quotes, $(), backticks, spaces) is rejected.
    const validator = SETTING_VALIDATORS[setting];
    if (!validator) {
      logRequest('WARN', 'Attempt to modify disallowed setting', { setting });
      return res.status(400).json({ error: 'Setting not allowed to be modified' });
    }
    const valueStr = typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean'
      ? String(value).trim()
      : '';
    const validationError = validator(valueStr);
    if (validationError) {
      logRequest('WARN', 'Invalid setting value', { setting, value });
      return res.status(400).json({ error: `Invalid value for ${setting}: ${validationError}` });
    }

    // Read current config
    const configContent = fs.readFileSync(configPath, 'utf-8');

    // Match the whole line for exactly this name (optional "export" prefix),
    // keeping any trailing comment. Names like ALPACA_TRADING_ENABLED never match TRADING_ENABLED.
    const regex = settingLineRegex(setting);
    if (!regex.test(configContent)) {
      logRequest('WARN', 'Setting not defined in config', { setting });
      return res.status(404).json({ error: `Setting ${setting} is not defined in config.sh` });
    }
    const updated = configContent.replace(
      settingLineRegex(setting),
      (_m, prefix, _val, comment) => `${prefix}${valueStr}${comment || ''}`,
    );
    fs.writeFileSync(configPath, updated);

    logRequest('INFO', 'Settings updated successfully', { setting, value });
    
    res.json({ success: true, message: `Setting ${setting} updated to ${value}` });
  } catch (error) {
    logRequest('ERROR', 'Settings update failed', { error: error.message });
    res.status(500).json({ error: error.message });
  }
});

// GET /api/settings - Get current configuration
app.get('/api/settings', (req, res) => {
  try {
    logRequest('INFO', 'Settings requested');
    
    const configPath = path.join(BASE_PATH, 'config.sh');
    
    if (!fs.existsSync(configPath)) {
      logRequest('ERROR', 'Config file not found', { path: configPath });
      return res.status(500).json({ error: 'Config file not found' });
    }

    const configContent = fs.readFileSync(configPath, 'utf-8');
    const settings = {};
    
    // Parse shell variables
    // Handles NAME=value and export NAME=value, with quoted values and trailing comments.
    const lines = configContent.split('\n');
    lines.forEach(line => {
      const match = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=("[^"]*"|'[^']*'|[^\s#]*)/);
      if (match) {
        const val = match[2].replace(/^(["'])(.*)\1$/, '$2');
        // Never send credentials to the browser.
        settings[match[1]] = SECRET_SETTING_PATTERN.test(match[1]) && val ? '********' : val;
      }
    });

    logRequest('INFO', 'Settings retrieved successfully');
    res.json(settings);
  } catch (error) {
    logRequest('ERROR', 'Settings retrieval failed', { error: error.message });
    res.status(500).json({ error: error.message });
  }
});

// GET /api/backtest - Get backtest results
app.get('/api/backtest', (req, res) => {
  try {
    logRequest('INFO', 'Backtest results requested');
    
    const backtestDir = BACKTEST_DIR;
    
    if (!fs.existsSync(backtestDir)) {
      logRequest('WARN', 'Backtest results directory not found', { path: backtestDir });
      return res.json({ results: [], message: 'No backtest results available' });
    }

    const files = fs.readdirSync(backtestDir);
    const results = [];
    
    files.forEach(file => {
      try {
        const filePath = path.join(backtestDir, file);
        const data = JSON.parse(fs.readFileSync(filePath, 'utf-8'));
        // Provenance of the prices behind the metrics: "yfinance",
        // "synthetic" (demo/test run) or "unknown" (file predates the field).
        const dataSource = typeof data.data_source === 'string' && data.data_source ? data.data_source : 'unknown';
        results.push({ file, data, data_source: dataSource, synthetic: dataSource === 'synthetic' });
      } catch (err) {
        logRequest('WARN', `Failed to parse backtest file: ${file}`, { error: err.message });
      }
    });

    logRequest('INFO', 'Backtest results retrieved', { count: results.length });
    res.json({ results });
  } catch (error) {
    logRequest('ERROR', 'Backtest retrieval failed', { error: error.message });
    res.status(500).json({ error: error.message });
  }
});

// Error handling middleware
app.use((err, req, res, next) => {
  logRequest('ERROR', 'Unhandled error', { error: err.message, stack: err.stack });
  res.status(500).json({ error: 'Internal server error', message: err.message });
});

// Start server when run directly (node server.js); tests require() the app.
if (require.main === module) app.listen(PORT, () => {
  logRequest('INFO', `Backend server started on port ${PORT}`);
  console.log(`🚀 StockSwingTrader Backend API running on http://localhost:${PORT}`);
  console.log(`📊 API Documentation:`);
  console.log(`   GET  /api/health              - Health check`);
  console.log(`   GET  /api/portfolio           - Get portfolio state`);
  console.log(`   GET  /api/quotes/:symbol      - Get real-time quotes`);
  console.log(`   GET  /api/signals/:symbol     - Get trading signals`);
  console.log(`   GET  /api/indicators/:symbol  - Get technical indicators`);
  console.log(`   GET  /api/trades              - Get trade history`);
  console.log(`   GET  /api/stats               - Get portfolio statistics`);
  console.log(`   GET  /api/settings            - Get current settings`);
  console.log(`   POST /api/settings            - Update settings`);
  console.log(`   GET  /api/backtest            - Get backtest results`);
});

module.exports = app;
