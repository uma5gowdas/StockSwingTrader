#!/usr/bin/env node
// ============================================================================
// StockSwingTrader: Backend API Test Suite
// ============================================================================
// Tests Enhancement 3: React Dashboard Backend (backend/server.js).
// Run: node --test tests/test_backend.js   (or: npm test --prefix backend)
//
// The real Express app is started on an ephemeral port. SST_BASE_PATH points
// it at a temporary project directory with a fixture config.sh, trade log and
// small stand-in lib/*.sh scripts, so the bash-backed routes are exercised
// end to end (spawn, argument passing, JSON parsing) without hitting broker
// APIs or modifying the repo's real config.sh.
// ============================================================================

'use strict';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'sst_backend_test.'));
const BACKTEST_DIR = path.join(ROOT, 'backtest_results');

const CONFIG_SH = [
  '#!/bin/bash',
  'export ALPACA_API_KEY="pk_live_secret_value"',
  "ALPACA_SECRET_KEY='another-secret'",
  'RISK_PER_TRADE=0.02 # percent of equity',
  'MAX_POSITION_SIZE=1000',
  'MIN_CONFLUENCE_SCORE=60',
  'TRADING_ENABLED=false',
  'ALPACA_TRADING_ENABLED=true',
  '',
].join('\n');

function writeFixture(rel, content, mode) {
  const file = path.join(ROOT, rel);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content);
  if (mode) fs.chmodSync(file, mode);
}

function setupFixtures() {
  writeFixture('config.sh', CONFIG_SH);
  writeFixture('.trades/trade_log.json', JSON.stringify([
    { symbol: 'AAPL', side: 'buy', qty: 10, price: 190.5 },
    { symbol: 'MSFT', side: 'sell', qty: 5, price: 410.25 },
  ]));
  // Stand-ins echo their arguments so the test can see exactly what was passed.
  writeFixture('lib/alpaca_broker.sh',
    '#!/bin/bash\nif [[ "$1" == "get-quote" ]]; then printf \'{"symbol":"%s","price":123.45,"argc":%d}\\n\' "$2" "$#";\n' +
    'else printf \'{"cash":1000,"cmd":"%s"}\\n\' "$1"; fi\n');
  writeFixture('lib/scoring.sh',
    '#!/bin/bash\nprintf \'{"symbol":"%s","confluence_score":71,"argc":%d}\\n\' "$1" "$#"\n');
  writeFixture('lib/indicators_new.sh', '#!/bin/bash\necho "not json for $1"\n');
  writeFixture('lib/risk_management.sh', '#!/bin/bash\necho "boom" >&2\nexit 3\n');
  fs.mkdirSync(BACKTEST_DIR, { recursive: true });
  fs.writeFileSync(path.join(BACKTEST_DIR, 'backtest_AAPL_1.json'), JSON.stringify({ symbol: 'AAPL', total_pnl: 42 }));
  fs.writeFileSync(path.join(BACKTEST_DIR, 'backtest_AAPL_1.html'), '<html></html>');
}

setupFixtures();
process.env.SST_BASE_PATH = ROOT;
process.env.SST_LOG_FILE = path.join(ROOT, 'backend.log');
process.env.BACKTEST_OUTPUT_DIR = BACKTEST_DIR;

const app = require('../backend/server.js');

let server;
let baseUrl;

before(async () => {
  server = await new Promise((resolve) => {
    const s = app.listen(0, '127.0.0.1', () => resolve(s));
  });
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  await new Promise((resolve) => server.close(resolve));
  fs.rmSync(ROOT, { recursive: true, force: true });
});

async function request(method, urlPath, { body, headers } = {}) {
  const res = await fetch(baseUrl + urlPath, {
    method,
    headers: { 'Content-Type': 'application/json', ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* not JSON */ }
  return { status: res.status, headers: res.headers, text, json };
}

const configText = () => fs.readFileSync(path.join(ROOT, 'config.sh'), 'utf8');

// ----------------------------------------------------------------------------

test('GET /api/health returns healthy status with ISO timestamp', async () => {
  const res = await request('GET', '/api/health');
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type'), /application\/json/);
  assert.equal(res.json.status, 'healthy');
  assert.ok(!Number.isNaN(Date.parse(res.json.timestamp)));
});

test('CORS allows the Vite dev origin and rejects unknown origins', async () => {
  const ok = await request('GET', '/api/health', { headers: { Origin: 'http://localhost:5173' } });
  assert.equal(ok.headers.get('access-control-allow-origin'), 'http://localhost:5173');
  assert.equal(ok.headers.get('access-control-allow-credentials'), 'true');
  const bad = await request('GET', '/api/health', { headers: { Origin: 'http://evil.example' } });
  assert.equal(bad.headers.get('access-control-allow-origin'), null);
});

test('GET /api/portfolio runs alpaca_broker.sh get-portfolio and returns its JSON', async () => {
  const res = await request('GET', '/api/portfolio');
  assert.equal(res.status, 200);
  assert.deepEqual(res.json, { cash: 1000, cmd: 'get-portfolio' });
});

test('GET /api/quotes/:symbol passes the symbol as a single argument', async () => {
  const res = await request('GET', '/api/quotes/aapl');
  assert.equal(res.status, 200);
  assert.deepEqual(res.json, { symbol: 'AAPL', price: 123.45, argc: 2 });
});

test('GET /api/signals/:symbol returns the scoring output', async () => {
  const res = await request('GET', '/api/signals/BRK.B');
  assert.equal(res.status, 200);
  assert.deepEqual(res.json, { symbol: 'BRK.B', confluence_score: 71, argc: 1 });
});

test('symbol routes reject shell metacharacters with 400', async () => {
  for (const bad of ['AAPL;touch%20pwned', '$(id)', 'A%20B', 'TOOLONGSYMBOL1']) {
    const res = await request('GET', `/api/signals/${bad}`);
    assert.equal(res.status, 400, `expected 400 for ${bad}`);
    assert.equal(res.json.error, 'Invalid symbol');
  }
  assert.equal(fs.existsSync(path.join(ROOT, 'pwned')), false);
});

test('GET /api/indicators/:symbol wraps non-JSON script output as raw', async () => {
  const res = await request('GET', '/api/indicators/MSFT');
  assert.equal(res.status, 200);
  assert.equal(res.json.symbol, 'MSFT');
  assert.equal(res.json.raw.trim(), 'not json for MSFT');
});

test('GET /api/stats returns 500 with an error when the script fails', async () => {
  const res = await request('GET', '/api/stats');
  assert.equal(res.status, 500);
  assert.equal(typeof res.json.error, 'string');
});

test('GET /api/trades returns the trade log as an array', async () => {
  const res = await request('GET', '/api/trades');
  assert.equal(res.status, 200);
  assert.equal(res.json.trades.length, 2);
  assert.equal(res.json.trades[1].symbol, 'MSFT');
});

test('GET /api/trades returns an empty list when there is no trade log', async () => {
  const log = path.join(ROOT, '.trades/trade_log.json');
  const saved = fs.readFileSync(log);
  fs.rmSync(log);
  try {
    const res = await request('GET', '/api/trades');
    assert.equal(res.status, 200);
    assert.deepEqual(res.json.trades, []);
  } finally {
    fs.writeFileSync(log, saved);
  }
});

test('GET /api/settings parses config.sh and masks secrets', async () => {
  const res = await request('GET', '/api/settings');
  assert.equal(res.status, 200);
  assert.equal(res.json.ALPACA_API_KEY, '********');
  assert.equal(res.json.ALPACA_SECRET_KEY, '********');
  assert.equal(res.json.RISK_PER_TRADE, '0.02');
  assert.equal(res.json.TRADING_ENABLED, 'false');
  assert.ok(!res.text.includes('pk_live_secret_value'));
});

test('POST /api/settings updates an allowed setting and keeps comments', async () => {
  const res = await request('POST', '/api/settings', { body: { setting: 'RISK_PER_TRADE', value: '0.05' } });
  assert.equal(res.status, 200);
  assert.equal(res.json.success, true);
  assert.match(configText(), /^RISK_PER_TRADE=0\.05 # percent of equity$/m);
});

test('POST /api/settings only touches the exact setting name', async () => {
  const res = await request('POST', '/api/settings', { body: { setting: 'TRADING_ENABLED', value: true } });
  assert.equal(res.status, 200);
  assert.match(configText(), /^TRADING_ENABLED=true$/m);
  assert.match(configText(), /^ALPACA_TRADING_ENABLED=true$/m);
});

test('POST /api/settings rejects disallowed settings and unsafe values', async () => {
  const before = configText();
  const cases = [
    [{ setting: 'ALPACA_API_KEY', value: 'x' }, /not allowed/],
    [{ setting: 'MAX_POSITION_SIZE', value: '$(rm -rf /)' }, /Invalid value/],
    [{ setting: 'MIN_CONFLUENCE_SCORE', value: '101' }, /Invalid value/],
    [{ setting: 'TRADING_ENABLED', value: 'yes' }, /Invalid value/],
  ];
  for (const [body, msg] of cases) {
    const res = await request('POST', '/api/settings', { body });
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.match(res.json.error, msg);
  }
  assert.equal(configText(), before);
});

test('GET /api/backtest returns parsed JSON result files only', async () => {
  const res = await request('GET', '/api/backtest');
  assert.equal(res.status, 200);
  assert.deepEqual(res.json.results, [{ file: 'backtest_AAPL_1.json', data: { symbol: 'AAPL', total_pnl: 42 } }]);
});

test('unknown routes return 404', async () => {
  const res = await request('GET', '/api/nonexistent');
  assert.equal(res.status, 404);
});
