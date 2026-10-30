import { useState, type FormEvent } from 'react';
import { Link } from 'react-router-dom';
import { usePolling } from '../hooks/usePolling';
import { useAlerts, useWatchlist } from '../hooks/usePreferences';
import { errorMessage, getQuote, getSignals, isValidSymbol, normalizeSymbol } from '../utils/api';
import { extractPrice, extractScore, extractSignal, formatNumber } from '../utils/format';
import { setAlerts, setWatchlist, type SymbolAlert } from '../utils/preferences';
import { ErrorMessage, LastUpdated, PageHeader, Section, SignalBadge } from '../components/ui';

interface Row {
  symbol: string;
  price?: number;
  score?: number;
  signal?: string;
  error?: string;
}

async function fetchRows(symbols: string[], signal: AbortSignal): Promise<Row[]> {
  return Promise.all(
    symbols.map(async (symbol) => {
      const [quote, sig] = await Promise.allSettled([getQuote(symbol, signal), getSignals(symbol, signal)]);
      const row: Row = { symbol };
      if (quote.status === 'fulfilled') row.price = extractPrice(quote.value);
      if (sig.status === 'fulfilled') {
        row.score = extractScore(sig.value);
        row.signal = extractSignal(sig.value);
      }
      const failure = [quote, sig].find((r): r is PromiseRejectedResult => r.status === 'rejected');
      if (failure) row.error = errorMessage(failure.reason);
      return row;
    }),
  );
}

function triggeredAlerts(row: Row, alert: SymbolAlert | undefined): string[] {
  if (!alert) return [];
  const hits: string[] = [];
  if (alert.priceAbove !== undefined && row.price !== undefined && row.price >= alert.priceAbove) hits.push(`price ≥ ${alert.priceAbove}`);
  if (alert.priceBelow !== undefined && row.price !== undefined && row.price <= alert.priceBelow) hits.push(`price ≤ ${alert.priceBelow}`);
  if (alert.scoreAbove !== undefined && row.score !== undefined && row.score >= alert.scoreAbove) hits.push(`score ≥ ${alert.scoreAbove}`);
  return hits;
}

const inputClass =
  'mt-1 w-28 rounded-md border border-gray-600 bg-gray-900 px-2 py-1 text-white focus:outline-none focus:ring-2 focus:ring-blue-400';

export default function Watchlist() {
  const symbols = useWatchlist();
  const alerts = useAlerts();
  const [input, setInput] = useState('');
  const [formError, setFormError] = useState<string | null>(null);
  const [status, setStatus] = useState('');
  const rows = usePolling((s) => fetchRows(symbols, s), [symbols.join(',')], symbols.length > 0);

  const add = (e: FormEvent) => {
    e.preventDefault();
    const symbol = normalizeSymbol(input);
    if (!isValidSymbol(symbol)) {
      setFormError('Enter a ticker of 1–10 letters, digits, dots or dashes, starting with a letter.');
      return;
    }
    if (symbols.includes(symbol)) {
      setFormError(`${symbol} is already on the watchlist.`);
      return;
    }
    setFormError(null);
    setWatchlist([...symbols, symbol]);
    setInput('');
    setStatus(`${symbol} added to the watchlist.`);
  };

  const remove = (symbol: string) => {
    setWatchlist(symbols.filter((s) => s !== symbol));
    const { [symbol]: _removed, ...rest } = alerts;
    void _removed;
    setAlerts(rest);
    setStatus(`${symbol} removed from the watchlist.`);
  };

  const updateAlert = (symbol: string, field: keyof SymbolAlert, raw: string) => {
    const value = raw.trim() === '' ? undefined : Number(raw);
    const next: SymbolAlert = { ...alerts[symbol], [field]: value !== undefined && Number.isFinite(value) ? value : undefined };
    setAlerts({ ...alerts, [symbol]: next });
  };

  const rowFor = (symbol: string): Row => rows.data?.find((r) => r.symbol === symbol) ?? { symbol };

  return (
    <>
      <PageHeader title="Watchlist" description="Manage symbols and set price or score alerts. Saved in this browser.">
        <LastUpdated date={rows.lastUpdated} loading={rows.loading} />
      </PageHeader>

      <p className="sr-only" role="status" aria-live="polite">{status}</p>

      <Section title="Add symbol" className="mb-6">
        <form onSubmit={add} className="flex flex-wrap items-end gap-2" noValidate>
          <div>
            <label htmlFor="watchlist-symbol" className="block text-sm text-gray-300">Symbol</label>
            <input
              id="watchlist-symbol"
              value={input}
              onChange={(e) => setInput(e.target.value)}
              aria-invalid={formError ? true : undefined}
              aria-describedby={formError ? 'watchlist-error' : undefined}
              autoComplete="off"
              className="mt-1 w-32 rounded-md border border-gray-600 bg-gray-900 px-3 py-2 uppercase text-white focus:outline-none focus:ring-2 focus:ring-blue-400"
            />
          </div>
          <button type="submit" className="btn-success">Add</button>
          {formError && <p id="watchlist-error" role="alert" className="w-full text-sm text-red-300">{formError}</p>}
        </form>
      </Section>

      <Section title="Symbols">
        <ErrorMessage message={rows.error} />
        {symbols.length === 0 ? (
          <p className="text-sm text-gray-300">Your watchlist is empty.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left">
              <caption className="sr-only">Watchlist symbols with live price, score and alerts</caption>
              <thead>
                <tr>
                  <th scope="col" className="table-header">Symbol</th>
                  <th scope="col" className="table-header">Price</th>
                  <th scope="col" className="table-header">Score</th>
                  <th scope="col" className="table-header">Signal</th>
                  <th scope="col" className="table-header">Alerts</th>
                  <th scope="col" className="table-header"><span className="sr-only">Actions</span></th>
                </tr>
              </thead>
              <tbody>
                {symbols.map((symbol) => {
                  const row = rowFor(symbol);
                  const alert = alerts[symbol];
                  const hits = triggeredAlerts(row, alert);
                  return (
                    <tr key={symbol}>
                      <th scope="row" className="table-cell font-medium">
                        <Link className="text-blue-300 underline hover:text-blue-200" to={`/analysis?symbol=${encodeURIComponent(symbol)}`}>
                          {symbol}
                        </Link>
                      </th>
                      <td className="table-cell">{formatNumber(row.price)}</td>
                      <td className="table-cell">{formatNumber(row.score, 1)}</td>
                      <td className="table-cell">
                        <SignalBadge signal={row.signal} />
                        {row.error && <span className="ml-2 text-xs text-red-300">{row.error}</span>}
                      </td>
                      <td className="table-cell">
                        <fieldset className="flex flex-wrap gap-2">
                          <legend className="sr-only">Alerts for {symbol}</legend>
                          <label className="text-xs text-gray-300">
                            Price above
                            <input type="number" step="any" inputMode="decimal" className={`${inputClass} block`}
                              value={alert?.priceAbove ?? ''} onChange={(e) => updateAlert(symbol, 'priceAbove', e.target.value)} />
                          </label>
                          <label className="text-xs text-gray-300">
                            Price below
                            <input type="number" step="any" inputMode="decimal" className={`${inputClass} block`}
                              value={alert?.priceBelow ?? ''} onChange={(e) => updateAlert(symbol, 'priceBelow', e.target.value)} />
                          </label>
                          <label className="text-xs text-gray-300">
                            Score at least
                            <input type="number" min={0} max={100} className={`${inputClass} block`}
                              value={alert?.scoreAbove ?? ''} onChange={(e) => updateAlert(symbol, 'scoreAbove', e.target.value)} />
                          </label>
                        </fieldset>
                        {hits.length > 0 && (
                          <p role="alert" className="mt-1 text-xs font-semibold text-yellow-300">Alert: {hits.join(', ')}</p>
                        )}
                      </td>
                      <td className="table-cell">
                        <button type="button" className="btn-danger" onClick={() => remove(symbol)} aria-label={`Remove ${symbol} from watchlist`}>
                          Remove
                        </button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </Section>
    </>
  );
}
