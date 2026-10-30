/**
 * Client-side preferences persisted in localStorage. The backend has no
 * watchlist or polling endpoints, so these live in the browser.
 */

export const DEFAULT_POLLING_INTERVAL_MS = 5000;
export const MIN_POLLING_INTERVAL_MS = 1000;
export const DEFAULT_WATCHLIST = ['AAPL', 'MSFT', 'GOOGL'];

const KEYS = {
  watchlist: 'sst.watchlist',
  alerts: 'sst.alerts',
  pollingInterval: 'sst.pollingIntervalMs',
} as const;

export interface SymbolAlert {
  /** Alert when the price rises to or above this value. */
  priceAbove?: number;
  /** Alert when the price falls to or below this value. */
  priceBelow?: number;
  /** Alert when the confluence score reaches this value. */
  scoreAbove?: number;
}

export type AlertMap = Record<string, SymbolAlert>;

const listeners = new Set<() => void>();

function read<T>(key: string, fallback: T): T {
  try {
    const raw = window.localStorage.getItem(key);
    return raw === null ? fallback : (JSON.parse(raw) as T);
  } catch {
    return fallback;
  }
}

function write(key: string, value: unknown): void {
  window.localStorage.setItem(key, JSON.stringify(value));
  listeners.forEach((listener) => listener());
}

/** Subscribe to preference changes (for useSyncExternalStore). */
export function subscribePreferences(listener: () => void): () => void {
  listeners.add(listener);
  const onStorage = () => listener();
  window.addEventListener('storage', onStorage);
  return () => {
    listeners.delete(listener);
    window.removeEventListener('storage', onStorage);
  };
}

export function getWatchlist(): string[] {
  const list = read<unknown>(KEYS.watchlist, DEFAULT_WATCHLIST);
  return Array.isArray(list) ? list.filter((s): s is string => typeof s === 'string') : DEFAULT_WATCHLIST;
}

export function setWatchlist(symbols: string[]): void {
  write(KEYS.watchlist, Array.from(new Set(symbols)));
}

export function getAlerts(): AlertMap {
  const alerts = read<unknown>(KEYS.alerts, {});
  return alerts && typeof alerts === 'object' ? (alerts as AlertMap) : {};
}

export function setAlerts(alerts: AlertMap): void {
  write(KEYS.alerts, alerts);
}

export function getPollingInterval(): number {
  const value = Number(read<unknown>(KEYS.pollingInterval, DEFAULT_POLLING_INTERVAL_MS));
  return Number.isFinite(value) && value >= MIN_POLLING_INTERVAL_MS ? value : DEFAULT_POLLING_INTERVAL_MS;
}

export function setPollingInterval(ms: number): void {
  write(KEYS.pollingInterval, Math.max(MIN_POLLING_INTERVAL_MS, Math.round(ms)));
}
