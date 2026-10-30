import type { JsonObject } from './api';

export type SignalLabel = 'STRONG BUY' | 'BUY' | 'HOLD' | 'SELL' | 'STRONG SELL';

/** Classify a 0-100 confluence score using the v6.3 thresholds. */
export function classifyScore(score: number): SignalLabel {
  if (score >= 75) return 'STRONG BUY';
  if (score >= 60) return 'BUY';
  if (score >= 45) return 'HOLD';
  if (score > 25) return 'SELL';
  return 'STRONG SELL';
}

export function toNumber(value: unknown): number | undefined {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string' && value.trim() !== '') {
    const n = Number(value);
    if (Number.isFinite(n)) return n;
  }
  return undefined;
}

function isObject(value: unknown): value is JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** Pull the confluence score out of the various shapes scoring.sh may emit. */
export function extractScore(data: JsonObject | null | undefined): number | undefined {
  if (!data) return undefined;
  const confluence = data.confluence;
  return (
    toNumber(data.confluence_score) ??
    toNumber(data.final_score) ??
    toNumber(data.score) ??
    (isObject(confluence) ? toNumber(confluence.final_score) : toNumber(confluence))
  );
}

export function extractSignal(data: JsonObject | null | undefined): string | undefined {
  if (!data) return undefined;
  if (typeof data.signal === 'string') return data.signal.toUpperCase();
  const score = extractScore(data);
  return score === undefined ? undefined : classifyScore(score);
}

/** Pull a price out of a quote payload. */
export function extractPrice(data: JsonObject | null | undefined): number | undefined {
  if (!data) return undefined;
  const price = data.price;
  return (
    (isObject(price) ? toNumber(price.current) : toNumber(price)) ??
    toNumber(data.current) ??
    toNumber(data.last) ??
    toNumber(data.ask_price) ??
    toNumber(data.ap) ??
    toNumber(data.c)
  );
}

export function formatNumber(value: number | undefined, digits = 2): string {
  return value === undefined ? '—' : value.toLocaleString(undefined, { maximumFractionDigits: digits, minimumFractionDigits: digits });
}

export function formatValue(value: unknown): string {
  if (value === null || value === undefined || value === '') return '—';
  if (typeof value === 'number') return Number.isInteger(value) ? String(value) : value.toFixed(2);
  if (typeof value === 'boolean') return value ? 'Yes' : 'No';
  if (typeof value === 'string') return value;
  return JSON.stringify(value);
}

export function humanizeKey(key: string): string {
  return key.replace(/[_-]+/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
}

/** Flatten nested objects into dotted key/value pairs for display. */
export function flatten(data: unknown, prefix = ''): Array<[string, unknown]> {
  if (!isObject(data)) return prefix ? [[prefix, data]] : [];
  return Object.entries(data).flatMap(([key, value]) => {
    const path = prefix ? `${prefix}.${key}` : key;
    return isObject(value) ? flatten(value, path) : [[path, value] as [string, unknown]];
  });
}

/** Numeric leaf values only, for charts. */
export function numericEntries(data: unknown): Array<{ name: string; value: number }> {
  return flatten(data)
    .map(([name, value]) => ({ name, value: toNumber(value) }))
    .filter((e): e is { name: string; value: number } => e.value !== undefined);
}

export function signalClass(signal: string | undefined): string {
  if (!signal) return 'bg-gray-700 text-gray-200';
  if (signal.includes('BUY')) return 'bg-green-900 text-green-200';
  if (signal.includes('SELL')) return 'bg-red-900 text-red-200';
  return 'bg-yellow-900 text-yellow-100';
}

const SECRET_PATTERN = /(KEY|SECRET|TOKEN|PASSWORD|PASS|AUTH|CREDENTIAL)/i;

export function isSecretKey(key: string): boolean {
  return SECRET_PATTERN.test(key);
}
