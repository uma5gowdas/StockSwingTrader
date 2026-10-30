import axios from 'axios';

/**
 * API client for the StockSwingTrader Express backend (backend/server.js).
 * All backend routes live under /api. In development Vite proxies /api to
 * the backend (see vite.config.ts); in production serve the built app from
 * the same origin or set VITE_API_BASE_URL.
 */
const API_BASE_URL: string = import.meta.env.VITE_API_BASE_URL ?? '/api';

const apiClient = axios.create({
  baseURL: API_BASE_URL,
  headers: {
    'Content-Type': 'application/json',
  },
  timeout: 30000,
});

/** Loose JSON object returned by the bash-backed endpoints. */
export type JsonObject = Record<string, unknown>;

export interface HealthResponse {
  status: string;
  timestamp: string;
}

export interface Trade {
  symbol?: string;
  side?: string;
  action?: string;
  quantity?: number;
  qty?: number;
  entry_price?: number;
  exit_price?: number;
  price?: number;
  pnl?: number;
  profit_loss?: number;
  timestamp?: string;
  date?: string;
  [key: string]: unknown;
}

export interface TradesResponse {
  trades: Trade[];
  message?: string;
}

export interface BacktestResult {
  file: string;
  data: JsonObject;
}

export interface BacktestResponse {
  results: BacktestResult[];
  message?: string;
}

export type SettingsResponse = Record<string, string>;

/** Settings the backend allows to be modified via POST /api/settings. */
export const EDITABLE_SETTINGS = [
  'RISK_PER_TRADE',
  'MAX_POSITION_SIZE',
  'MIN_CONFLUENCE_SCORE',
  'TRADING_ENABLED',
] as const;
export type EditableSetting = (typeof EDITABLE_SETTINGS)[number];

const NON_NEGATIVE_NUMBER = /^\d+(\.\d+)?$/;

/**
 * Validate a setting value before it is sent. Mirrors the backend whitelist:
 * values are written unquoted into config.sh, which the agent sources.
 * Returns an error message, or null when the value is valid.
 */
export function validateSetting(key: EditableSetting, raw: string): string | null {
  const value = raw.trim();
  switch (key) {
    case 'TRADING_ENABLED':
      return value === 'true' || value === 'false' ? null : 'Must be true or false.';
    case 'MIN_CONFLUENCE_SCORE':
      return NON_NEGATIVE_NUMBER.test(value) && Number(value) <= 100
        ? null
        : 'Must be a number from 0 to 100.';
    case 'RISK_PER_TRADE':
    case 'MAX_POSITION_SIZE':
      return NON_NEGATIVE_NUMBER.test(value) && Number.isFinite(Number(value))
        ? null
        : 'Must be a non-negative number (digits and an optional decimal point).';
    default:
      return 'Setting cannot be edited.';
  }
}

/** Ticker symbols: letters, digits, dot or dash, max 10 chars. */
const SYMBOL_PATTERN = /^[A-Z][A-Z0-9.-]{0,9}$/;

export function normalizeSymbol(raw: string): string {
  return raw.trim().toUpperCase();
}

export function isValidSymbol(symbol: string): boolean {
  return SYMBOL_PATTERN.test(symbol);
}

function symbolPath(symbol: string): string {
  const normalized = normalizeSymbol(symbol);
  if (!isValidSymbol(normalized)) {
    throw new Error(`Invalid symbol: ${symbol}`);
  }
  return encodeURIComponent(normalized);
}

async function get<T>(url: string, signal?: AbortSignal): Promise<T> {
  const response = await apiClient.get<T>(url, { signal });
  return response.data;
}

export const getHealth = (signal?: AbortSignal) =>
  get<HealthResponse>('/health', signal);

export const getPortfolio = (signal?: AbortSignal) =>
  get<JsonObject>('/portfolio', signal);

export const getQuote = (symbol: string, signal?: AbortSignal) =>
  get<JsonObject>(`/quotes/${symbolPath(symbol)}`, signal);

export const getSignals = (symbol: string, signal?: AbortSignal) =>
  get<JsonObject>(`/signals/${symbolPath(symbol)}`, signal);

export const getIndicators = (symbol: string, signal?: AbortSignal) =>
  get<JsonObject>(`/indicators/${symbolPath(symbol)}`, signal);

export const getTrades = (signal?: AbortSignal) =>
  get<TradesResponse>('/trades', signal);

export const getStats = (signal?: AbortSignal) =>
  get<JsonObject>('/stats', signal);

export const getSettings = (signal?: AbortSignal) =>
  get<SettingsResponse>('/settings', signal);

export const updateSetting = async (setting: EditableSetting, value: string) => {
  const response = await apiClient.post<{ success: boolean; message: string }>(
    '/settings',
    { setting, value },
  );
  return response.data;
};

export const getBacktestResults = (signal?: AbortSignal) =>
  get<BacktestResponse>('/backtest', signal);

/** Extract a readable message from an axios/unknown error. */
export function errorMessage(err: unknown): string {
  if (axios.isAxiosError(err)) {
    const data = err.response?.data as { error?: string; message?: string } | undefined;
    return data?.error ?? data?.message ?? err.message;
  }
  if (err instanceof Error) return err.message;
  return String(err);
}

export function isCancelled(err: unknown): boolean {
  return axios.isCancel(err);
}

export default apiClient;
