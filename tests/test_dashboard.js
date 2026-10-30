#!/usr/bin/env node
// ============================================================================
// StockSwingTrader: Dashboard Test Suite
// ============================================================================
// Tests Enhancement 3: React Dashboard (frontend/src) by executing the real
// TypeScript sources.
// Run: node --test tests/test_dashboard.js   (or: npm test --prefix frontend)
//
// The frontend sources are bundled with the project's own esbuild (Vite's
// bundler) into a temporary ESM module, then:
//   - utils (api, format, preferences) are unit tested
//   - the usePolling hook is driven with react-test-renderer + mocked timers
//   - every route of <App/> is rendered against a mocked axios adapter
//   - the TypeScript project type-checks (tsc --noEmit)
// No dev server or network is used.
// ============================================================================

'use strict';

const { test, before, after, mock } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');

const FRONTEND_DIR = path.join(__dirname, '..', 'frontend');
const SRC_DIR = path.join(FRONTEND_DIR, 'src');
const esbuild = require(path.join(FRONTEND_DIR, 'node_modules', 'esbuild'));

// The bundle lives under frontend/node_modules so its external imports
// (react, react-test-renderer) resolve to the project's installed copies.
const CACHE_DIR = path.join(FRONTEND_DIR, 'node_modules', '.cache');
fs.mkdirSync(CACHE_DIR, { recursive: true });
const TMP_DIR = fs.mkdtempSync(path.join(CACHE_DIR, 'sst_dashboard_test.'));

// ---------------------------------------------------------------------------
// Browser-ish globals used by src/utils/preferences.ts
// ---------------------------------------------------------------------------
class MemoryStorage {
  constructor() { this.map = new Map(); }
  getItem(k) { return this.map.has(k) ? this.map.get(k) : null; }
  setItem(k, v) { this.map.set(k, String(v)); }
  removeItem(k) { this.map.delete(k); }
  clear() { this.map.clear(); }
}
const storage = new MemoryStorage();
globalThis.window = {
  localStorage: storage,
  addEventListener() {},
  removeEventListener() {},
};
globalThis.IS_REACT_ACT_ENVIRONMENT = true;
globalThis.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };

// ---------------------------------------------------------------------------
// Mock backend: axios adapter keyed by request path
// ---------------------------------------------------------------------------
const requests = [];
let routes = {};
function mockAdapter(config) {
  const url = `${config.baseURL || ''}${config.url}`;
  requests.push({ method: config.method, url, data: config.data });
  const handler = routes[`${config.method.toUpperCase()} ${url}`];
  if (!handler) {
    const err = new Error(`No mock for ${config.method} ${url}`);
    err.config = config;
    return Promise.reject(err);
  }
  const { status = 200, data } = typeof handler === 'function' ? handler(config) : handler;
  return Promise.resolve({ data, status, statusText: 'OK', headers: {}, config, request: {} });
}

const BACKEND = {
  'GET /api/health': { data: { status: 'healthy', timestamp: '2024-10-30T14:30:00Z' } },
  'GET /api/portfolio': { data: { cash: 1000, equity: 2500 } },
  'GET /api/stats': { data: { win_rate: 62.5, sharpe_ratio: 1.4 } },
  'GET /api/signals/AAPL': { data: { symbol: 'AAPL', confluence_score: 71 } },
  'GET /api/signals/MSFT': { data: { symbol: 'MSFT', confluence: { final_score: 80 } } },
  'GET /api/signals/GOOGL': { data: { symbol: 'GOOGL', signal: 'sell', confluence_score: 30 } },
  'GET /api/indicators/AAPL': { data: { rsi: 55.2, macd: { histogram: 0.23 } } },
  'GET /api/quotes/AAPL': { data: { symbol: 'AAPL', price: { current: 235.45 } } },
  'GET /api/quotes/MSFT': { data: { symbol: 'MSFT', last: 441.5 } },
  'GET /api/quotes/GOOGL': { data: { symbol: 'GOOGL', c: 170.1 } },
  'GET /api/trades': { data: { trades: [{ symbol: 'AAPL', side: 'buy', qty: 10, entry_price: 100, exit_price: 110, pnl: 100, date: '2024-01-02' }] } },
  'GET /api/backtest': { data: { results: [{ file: 'backtest_AAPL.json', data: { symbol: 'AAPL', total_pnl: 42 } }] } },
  'GET /api/settings': { data: { RISK_PER_TRADE: '0.02', MAX_POSITION_SIZE: '1000', MIN_CONFLUENCE_SCORE: '60', TRADING_ENABLED: 'false', ALPACA_API_KEY: '********' } },
};

let m; // bundled frontend module

before(async () => {
  const entry = [
    "export * as api from './utils/api';",
    "export { default as apiClient } from './utils/api';",
    "export * as format from './utils/format';",
    "export * as prefs from './utils/preferences';",
    "export { usePolling } from './hooks/usePolling';",
    "export { default as App } from './App';",
    "export { MemoryRouter } from 'react-router-dom';",
    "export * as React from 'react';",
    "export { default as TestRenderer, act } from 'react-test-renderer';",
  ].join('\n');
  const outfile = path.join(TMP_DIR, 'frontend.bundle.mjs');
  // Recharts measures SVG text through the DOM, which react-test-renderer
  // does not have. Swap it for stubs that keep the chart's data visible.
  const RECHARTS = ['Bar', 'BarChart', 'CartesianGrid', 'Cell', 'Line', 'LineChart', 'ResponsiveContainer', 'Tooltip', 'XAxis', 'YAxis'];
  const rechartsStub = {
    name: 'recharts-stub',
    setup(build) {
      build.onResolve({ filter: /^recharts$/ }, () => ({ path: 'recharts', namespace: 'stub' }));
      build.onLoad({ filter: /.*/, namespace: 'stub' }, () => ({
        resolveDir: SRC_DIR,
        loader: 'js',
        contents: "import { createElement } from 'react';\n" + RECHARTS.map((name) =>
          `export const ${name} = (props) => createElement('recharts-${name}', { data: props.data, dataKey: props.dataKey }, props.children);`).join('\n'),
      }));
    },
  };
  await esbuild.build({
    stdin: { contents: entry, resolveDir: SRC_DIR, loader: 'ts', sourcefile: 'test-entry.ts' },
    bundle: true,
    platform: 'node',
    format: 'esm',
    jsx: 'automatic',
    loader: { '.css': 'empty' },
    define: { 'import.meta.env': '{}', 'process.env.NODE_ENV': '"development"' },
    nodePaths: [path.join(FRONTEND_DIR, 'node_modules')],
    // Load React natively (one shared copy). Bundled, React's act() cannot
    // find node's setImmediate and leaks a MessageChannel per call.
    external: ['react', 'react/*', 'react-test-renderer', 'scheduler'],
    // CJS deps (react, axios) need require() inside an ESM bundle
    banner: { js: "import { createRequire as __cr } from 'node:module'; const require = __cr(import.meta.url);" },
    plugins: [rechartsStub],
    outfile,
    logLevel: 'silent',
  });
  await esbuild.stop(); // the esbuild service would keep the process alive
  m = await import(pathToFileURL(outfile).href);
  m.apiClient.defaults.adapter = mockAdapter;
});

after(() => {
  fs.rmSync(TMP_DIR, { recursive: true, force: true });
});

function resetBrowserState() {
  storage.clear();
  requests.length = 0;
  routes = { ...BACKEND };
}

// Wait for pending promises (mocked requests) and React updates
async function flush() {
  await m.act(async () => {
    for (let i = 0; i < 5; i++) await new Promise((r) => setImmediate(r));
  });
}

const textOf = (node) =>
  typeof node === 'string' ? node : (node.children || []).map(textOf).join('');

const createNodeMock = () => ({
  focus() {},
  getBoundingClientRect: () => ({ width: 800, height: 300, top: 0, left: 0, right: 800, bottom: 300 }),
  clientWidth: 800,
  clientHeight: 300,
  addEventListener() {},
  removeEventListener() {},
  style: {},
});

// ===========================================================================
// Type check
// ===========================================================================

test('frontend type-checks with tsc --noEmit', () => {
  const tsc = path.join(FRONTEND_DIR, 'node_modules', '.bin', 'tsc');
  const res = spawnSync(tsc, ['--noEmit', '-p', 'tsconfig.json'], { cwd: FRONTEND_DIR, encoding: 'utf8' });
  assert.equal(res.status, 0, `tsc failed:\n${res.stdout}${res.stderr}`);
});

// ===========================================================================
// utils/api.ts
// ===========================================================================

test('api: symbols are normalized and validated', () => {
  assert.equal(m.api.normalizeSymbol('  brk.b '), 'BRK.B');
  for (const ok of ['AAPL', 'BRK.B', 'BF-B', 'A']) assert.ok(m.api.isValidSymbol(ok), ok);
  for (const bad of ['', 'aapl', '1ABC', 'AAPL;rm', 'TOOLONGSYMB', '$(id)']) assert.ok(!m.api.isValidSymbol(bad), bad);
});

test('api: validateSetting mirrors the backend whitelist rules', () => {
  const v = m.api.validateSetting;
  assert.equal(v('TRADING_ENABLED', 'true'), null);
  assert.match(v('TRADING_ENABLED', 'yes'), /true or false/);
  assert.equal(v('MIN_CONFLUENCE_SCORE', '100'), null);
  assert.match(v('MIN_CONFLUENCE_SCORE', '100.5'), /0 to 100/);
  assert.equal(v('RISK_PER_TRADE', ' 0.02 '), null);
  for (const bad of ['-1', '1e3', '$(id)', '1 2', '']) assert.ok(v('MAX_POSITION_SIZE', bad), bad);
  assert.deepEqual([...m.api.EDITABLE_SETTINGS], ['RISK_PER_TRADE', 'MAX_POSITION_SIZE', 'MIN_CONFLUENCE_SCORE', 'TRADING_ENABLED']);
});

test('api: requests go to the real backend routes under /api', async () => {
  resetBrowserState();
  routes['GET /api/signals/BRK.B'] = { data: { confluence_score: 50 } };
  routes['POST /api/settings'] = (config) => ({ data: { success: true, message: config.data } });

  assert.deepEqual(await m.api.getHealth(), BACKEND['GET /api/health'].data);
  assert.deepEqual(await m.api.getSignals(' brk.b'), { confluence_score: 50 });
  assert.deepEqual(await m.api.getTrades(), BACKEND['GET /api/trades'].data);
  const saved = await m.api.updateSetting('RISK_PER_TRADE', '0.03');
  assert.deepEqual(JSON.parse(saved.message), { setting: 'RISK_PER_TRADE', value: '0.03' });

  assert.deepEqual(requests.map((r) => `${r.method} ${r.url}`), [
    'get /api/health', 'get /api/signals/BRK.B', 'get /api/trades', 'post /api/settings',
  ]);
});

test('api: invalid symbols are rejected before any request is made', async () => {
  resetBrowserState();
  await assert.rejects(async () => m.api.getSignals('AAPL;touch x'), /Invalid symbol/);
  await assert.rejects(async () => m.api.getQuote('../health'), /Invalid symbol/);
  assert.equal(requests.length, 0);
});

test('api: errorMessage prefers the backend error field', async () => {
  resetBrowserState();
  m.apiClient.defaults.adapter = (config) => Promise.reject(Object.assign(new Error('Request failed with status code 500'), {
    isAxiosError: true, config, response: { status: 500, data: { error: 'Stats script not found' } },
  }));
  try {
    const err = await m.api.getStats().catch((e) => e);
    assert.equal(m.api.errorMessage(err), 'Stats script not found');
  } finally {
    m.apiClient.defaults.adapter = mockAdapter;
  }
  assert.equal(m.api.errorMessage(new Error('plain')), 'plain');
  assert.equal(m.api.errorMessage('text'), 'text');
});

// ===========================================================================
// utils/format.ts
// ===========================================================================

test('format: classifyScore uses the v6.3 signal thresholds', () => {
  const c = m.format.classifyScore;
  assert.deepEqual([100, 75, 74.9, 60, 59, 45, 44, 26, 25, 0].map(c), [
    'STRONG BUY', 'STRONG BUY', 'BUY', 'BUY', 'HOLD', 'HOLD', 'SELL', 'SELL', 'STRONG SELL', 'STRONG SELL',
  ]);
});

test('format: extractScore/extractSignal/extractPrice handle backend payload shapes', () => {
  const f = m.format;
  assert.equal(f.extractScore({ confluence_score: 71 }), 71);
  assert.equal(f.extractScore({ final_score: '64' }), 64);
  assert.equal(f.extractScore({ confluence: { final_score: 80 } }), 80);
  assert.equal(f.extractScore({ raw: '' }), undefined);
  assert.equal(f.extractSignal({ signal: 'buy' }), 'BUY');
  assert.equal(f.extractSignal({ confluence_score: 20 }), 'STRONG SELL');
  assert.equal(f.extractPrice({ price: { current: 235.45 } }), 235.45);
  assert.equal(f.extractPrice({ ap: '101.5' }), 101.5);
  assert.equal(f.extractPrice(null), undefined);
});

test('format: flatten, numericEntries and secret detection', () => {
  const f = m.format;
  assert.deepEqual(f.flatten({ a: 1, b: { c: 'x', d: { e: 2 } } }), [['a', 1], ['b.c', 'x'], ['b.d.e', 2]]);
  assert.deepEqual(f.numericEntries({ rsi: 55, sig: 'buy', macd: { h: '0.2' } }), [{ name: 'rsi', value: 55 }, { name: 'macd.h', value: 0.2 }]);
  assert.equal(f.formatValue(null), '—');
  assert.equal(f.formatValue(1.234), '1.23');
  assert.equal(f.humanizeKey('stop_loss-pct'), 'Stop Loss Pct');
  assert.ok(f.isSecretKey('ALPACA_API_KEY') && f.isSecretKey('ROBINHOOD_PASSWORD'));
  assert.ok(!f.isSecretKey('RISK_PER_TRADE'));
});

// ===========================================================================
// utils/preferences.ts
// ===========================================================================

test('preferences: polling defaults to 5 seconds with a 1 second minimum', () => {
  resetBrowserState();
  const p = m.prefs;
  assert.equal(p.DEFAULT_POLLING_INTERVAL_MS, 5000);
  assert.equal(p.getPollingInterval(), 5000);
  p.setPollingInterval(250);
  assert.equal(p.getPollingInterval(), 1000);
  p.setPollingInterval(10000);
  assert.equal(p.getPollingInterval(), 10000);
  storage.setItem('sst.pollingIntervalMs', 'not json');
  assert.equal(p.getPollingInterval(), 5000);
});

test('preferences: watchlist and alerts persist, dedupe and notify subscribers', () => {
  resetBrowserState();
  const p = m.prefs;
  assert.deepEqual(p.getWatchlist(), ['AAPL', 'MSFT', 'GOOGL']);
  let calls = 0;
  const unsubscribe = p.subscribePreferences(() => { calls++; });
  p.setWatchlist(['TSLA', 'AAPL', 'TSLA']);
  assert.deepEqual(p.getWatchlist(), ['TSLA', 'AAPL']);
  p.setAlerts({ AAPL: { priceAbove: 250 } });
  assert.deepEqual(p.getAlerts(), { AAPL: { priceAbove: 250 } });
  assert.equal(calls, 2);
  unsubscribe();
  p.setWatchlist(['X']);
  assert.equal(calls, 2);
  storage.setItem('sst.watchlist', JSON.stringify(['OK', 5, null]));
  assert.deepEqual(p.getWatchlist(), ['OK']);
});

// ===========================================================================
// hooks/usePolling.ts
// ===========================================================================

function renderPolling(fetcher, deps) {
  const { React, TestRenderer, usePolling } = m;
  const state = { current: null };
  function Probe(props) {
    state.current = usePolling(fetcher, props.deps);
    return null;
  }
  let renderer;
  m.act(() => { renderer = TestRenderer.create(React.createElement(Probe, { deps })); });
  return { state, renderer, rerender: (d) => m.act(() => renderer.update(React.createElement(Probe, { deps: d }))) };
}

test('usePolling: fetches on mount and every 5s after the previous request settles', async (t) => {
  resetBrowserState();
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let n = 0;
  const signals = [];
  const fetcher = mock.fn(async (signal) => { signals.push(signal); return ++n; });
  const { state, renderer } = renderPolling(fetcher, ['AAPL']);

  await flush();
  assert.equal(fetcher.mock.callCount(), 1);
  assert.equal(state.current.data, 1);
  assert.equal(state.current.loading, false);
  assert.ok(state.current.lastUpdated instanceof Date);

  t.mock.timers.tick(4999);
  await flush();
  assert.equal(fetcher.mock.callCount(), 1, 'must not poll before 5s');

  t.mock.timers.tick(1);
  await flush();
  assert.equal(fetcher.mock.callCount(), 2);
  assert.equal(state.current.data, 2);

  m.act(() => renderer.unmount());
  assert.equal(signals.at(-1).aborted, true, 'in-flight request aborted on unmount');
  t.mock.timers.tick(20000);
  await flush();
  assert.equal(fetcher.mock.callCount(), 2, 'no polling after unmount');
});

test('usePolling: honours the configured interval and reports errors', async (t) => {
  resetBrowserState();
  m.prefs.setPollingInterval(2000);
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let fail = true;
  const fetcher = mock.fn(async () => {
    if (fail) throw new Error('backend down');
    return 'ok';
  });
  const { state, renderer } = renderPolling(fetcher, ['X']);
  await flush();
  assert.equal(state.current.error, 'backend down');
  assert.equal(state.current.data, null);

  fail = false;
  t.mock.timers.tick(2000);
  await flush();
  assert.equal(fetcher.mock.callCount(), 2);
  assert.equal(state.current.data, 'ok');
  assert.equal(state.current.error, null);
  m.act(() => renderer.unmount());
});

test('usePolling: changing deps drops stale data and refetches', async (t) => {
  resetBrowserState();
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const resolvers = [];
  const fetcher = mock.fn(() => new Promise((resolve) => resolvers.push(resolve)));
  const { state, renderer, rerender } = renderPolling(fetcher, ['AAPL']);
  resolvers[0]('aapl-data');
  await flush();
  assert.equal(state.current.data, 'aapl-data');

  rerender(['MSFT']);
  assert.equal(state.current.data, null, 'AAPL data must not show under MSFT');
  assert.equal(state.current.loading, true);
  assert.equal(fetcher.mock.callCount(), 2);
  resolvers[1]('msft-data');
  await flush();
  assert.equal(state.current.data, 'msft-data');
  m.act(() => renderer.unmount());
});

// ===========================================================================
// App routes
// ===========================================================================

async function renderRoute(url) {
  const { React, TestRenderer, MemoryRouter, App } = m;
  let renderer;
  m.act(() => {
    renderer = TestRenderer.create(
      React.createElement(MemoryRouter, { initialEntries: [url] }, React.createElement(App)),
      { createNodeMock },
    );
  });
  await flush();
  return renderer;
}

const PAGES = [
  ['/', 'Dashboard', ['GET /api/signals/AAPL', 'GET /api/signals/MSFT', 'GET /api/signals/GOOGL', 'GET /api/portfolio', 'GET /api/stats']],
  ['/analysis?symbol=aapl', 'Analysis: AAPL', ['GET /api/signals/AAPL', 'GET /api/indicators/AAPL', 'GET /api/quotes/AAPL']],
  ['/trades', 'Trade History', ['GET /api/trades', 'GET /api/backtest']],
  ['/watchlist', 'Watchlist', ['GET /api/quotes/AAPL', 'GET /api/signals/AAPL', 'GET /api/quotes/MSFT', 'GET /api/quotes/GOOGL']],
  ['/settings', 'Settings', ['GET /api/settings']],
  ['/no-such-page', 'Page not found', []],
];

for (const [url, heading, expectedRequests] of PAGES) {
  test(`App renders ${url} with its page heading and loads its data`, async (t) => {
    resetBrowserState();
    t.mock.timers.enable({ apis: ['setTimeout'] });
    const renderer = await renderRoute(url);
    try {
      const root = renderer.root;
      const h1 = root.findAll((n) => n.type === 'h1');
      assert.equal(h1.length, 1);
      assert.equal(textOf(h1[0]), heading);

      // Accessible landmarks: skip link, labelled nav with all five pages, main target
      const nav = root.find((n) => n.type === 'nav');
      assert.equal(nav.props['aria-label'], 'Main');
      assert.deepEqual(nav.findAll((n) => n.type === 'a').map(textOf), ['Dashboard', 'Analysis', 'Trade History', 'Watchlist', 'Settings']);
      assert.equal(root.find((n) => n.type === 'main').props.id, 'main-content');
      assert.ok(root.findAll((n) => n.type === 'a' && n.props.href === '#main-content').length === 1);

      const made = new Set(requests.map((r) => `${r.method.toUpperCase()} ${r.url}`));
      for (const r of expectedRequests) assert.ok(made.has(r), `expected request ${r}; made: ${[...made].join(', ')}`);
      const unmocked = [...made].filter((r) => !(r in routes));
      assert.deepEqual(unmocked, [], 'page requested a route the backend does not serve');
    } finally {
      m.act(() => renderer.unmount());
    }
  });
}

test('Dashboard shows watchlist scores classified with the v6.3 thresholds', async (t) => {
  resetBrowserState();
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const renderer = await renderRoute('/');
  try {
    const text = textOf(renderer.toJSON() ? { children: [].concat(renderer.toJSON()) } : '');
    assert.match(text, /AAPL[\s\S]*71[\s\S]*BUY/);
    assert.match(text, /MSFT[\s\S]*80[\s\S]*STRONG BUY/);
    assert.match(text, /GOOGL[\s\S]*SELL/);
  } finally {
    m.act(() => renderer.unmount());
  }
});
