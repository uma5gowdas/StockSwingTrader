import { useId, useMemo, useState } from 'react';
import { CartesianGrid, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';
import { usePolling } from '../hooks/usePolling';
import { getBacktestResults, getTrades, type Trade } from '../utils/api';
import { flatten, formatNumber, formatValue, toNumber } from '../utils/format';
import { DataSourceNotice, ErrorMessage, KeyValueList, LastUpdated, Loading, PageHeader, Section, StatCard } from '../components/ui';

type Outcome = 'all' | 'win' | 'loss';

const tradePnl = (t: Trade) => toNumber(t.pnl) ?? toNumber(t.profit_loss);
const tradeDate = (t: Trade) => (typeof t.timestamp === 'string' ? t.timestamp : typeof t.date === 'string' ? t.date : '');

/** Annualization-free Sharpe-like ratio over per-trade P&L. */
function sharpe(pnls: number[]): number | undefined {
  if (pnls.length < 2) return undefined;
  const mean = pnls.reduce((a, b) => a + b, 0) / pnls.length;
  const variance = pnls.reduce((a, b) => a + (b - mean) ** 2, 0) / (pnls.length - 1);
  const sd = Math.sqrt(variance);
  return sd === 0 ? undefined : mean / sd;
}

export default function TradeHistory() {
  const trades = usePolling(getTrades, []);
  const backtest = usePolling(getBacktestResults, []);
  const [symbolFilter, setSymbolFilter] = useState('');
  const [outcome, setOutcome] = useState<Outcome>('all');
  const [fromDate, setFromDate] = useState('');
  const symbolId = useId();
  const outcomeId = useId();
  const dateId = useId();

  const all = useMemo(() => trades.data?.trades ?? [], [trades.data]);
  const filtered = useMemo(
    () =>
      all.filter((t) => {
        const pnl = tradePnl(t);
        if (symbolFilter && !String(t.symbol ?? '').toUpperCase().includes(symbolFilter.toUpperCase())) return false;
        if (outcome === 'win' && !(pnl !== undefined && pnl > 0)) return false;
        if (outcome === 'loss' && !(pnl !== undefined && pnl < 0)) return false;
        if (fromDate && tradeDate(t) && tradeDate(t).slice(0, 10) < fromDate) return false;
        return true;
      }),
    [all, symbolFilter, outcome, fromDate],
  );

  const pnls = filtered.map(tradePnl).filter((p): p is number => p !== undefined);
  const wins = pnls.filter((p) => p > 0).length;
  const total = pnls.reduce((a, b) => a + b, 0);
  let running = 0;
  const equity = filtered
    .filter((t) => tradePnl(t) !== undefined)
    .map((t, i) => {
      running += tradePnl(t) ?? 0;
      return { label: tradeDate(t).slice(0, 10) || `#${i + 1}`, equity: Number(running.toFixed(2)) };
    });

  const columns = ['symbol', 'side', 'quantity', 'entry_price', 'exit_price', 'pnl', 'date'] as const;
  const cell = (t: Trade, col: (typeof columns)[number]) => {
    if (col === 'side') return t.side ?? t.action;
    if (col === 'quantity') return t.quantity ?? t.qty;
    if (col === 'entry_price') return t.entry_price ?? t.price;
    if (col === 'pnl') return tradePnl(t);
    if (col === 'date') return tradeDate(t);
    return t[col];
  };

  return (
    <>
      <PageHeader title="Trade History" description="Past trades with P&L, win rate and Sharpe ratio.">
        <LastUpdated date={trades.lastUpdated} loading={trades.loading} />
      </PageHeader>

      <dl className="mb-6 grid grid-cols-2 gap-4 md:grid-cols-4">
        <StatCard label="Trades" value={filtered.length} />
        <StatCard label="Win rate" value={pnls.length ? `${formatNumber((wins / pnls.length) * 100, 1)}%` : '—'} />
        <StatCard label="Total P&L" value={pnls.length ? formatNumber(total) : '—'} />
        <StatCard label="Sharpe (per trade)" value={formatNumber(sharpe(pnls))} />
      </dl>

      <Section title="Filters" className="mb-6">
        <form className="flex flex-wrap gap-4" onSubmit={(e) => e.preventDefault()} role="search" aria-label="Filter trades">
          <div>
            <label htmlFor={symbolId} className="block text-sm text-gray-300">Symbol</label>
            <input
              id={symbolId}
              value={symbolFilter}
              onChange={(e) => setSymbolFilter(e.target.value)}
              className="mt-1 rounded-md border border-gray-600 bg-gray-900 px-3 py-2 text-white focus:outline-none focus:ring-2 focus:ring-blue-400"
            />
          </div>
          <div>
            <label htmlFor={outcomeId} className="block text-sm text-gray-300">Outcome</label>
            <select
              id={outcomeId}
              value={outcome}
              onChange={(e) => setOutcome(e.target.value as Outcome)}
              className="mt-1 rounded-md border border-gray-600 bg-gray-900 px-3 py-2 text-white focus:outline-none focus:ring-2 focus:ring-blue-400"
            >
              <option value="all">All</option>
              <option value="win">Winners</option>
              <option value="loss">Losers</option>
            </select>
          </div>
          <div>
            <label htmlFor={dateId} className="block text-sm text-gray-300">From date</label>
            <input
              id={dateId}
              type="date"
              value={fromDate}
              onChange={(e) => setFromDate(e.target.value)}
              className="mt-1 rounded-md border border-gray-600 bg-gray-900 px-3 py-2 text-white focus:outline-none focus:ring-2 focus:ring-blue-400"
            />
          </div>
        </form>
      </Section>

      {equity.length > 1 && (
        <Section title="Cumulative P&L" className="mb-6">
          <figure>
            <div className="h-64" aria-hidden="true">
              <ResponsiveContainer width="100%" height="100%">
                <LineChart data={equity}>
                  <CartesianGrid strokeDasharray="3 3" stroke="#334155" />
                  <XAxis dataKey="label" stroke="#cbd5e1" />
                  <YAxis stroke="#cbd5e1" />
                  <Tooltip contentStyle={{ backgroundColor: '#1e293b', border: '1px solid #475569' }} />
                  <Line type="monotone" dataKey="equity" stroke="#10b981" dot={false} />
                </LineChart>
              </ResponsiveContainer>
            </div>
            <figcaption className="sr-only">Cumulative P&L ends at {formatNumber(total)}.</figcaption>
          </figure>
        </Section>
      )}

      <Section title="Trades" className="mb-6">
        <ErrorMessage message={trades.error} />
        {trades.loading && !trades.data ? (
          <Loading />
        ) : filtered.length === 0 ? (
          <p className="text-sm text-gray-300">{trades.data?.message ?? 'No trades match the current filters.'}</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left">
              <caption className="sr-only">Trade history</caption>
              <thead>
                <tr>
                  {columns.map((c) => (
                    <th key={c} scope="col" className="table-header">{c.replace('_', ' ')}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {filtered.map((t, i) => {
                  const pnl = tradePnl(t);
                  return (
                    <tr key={`${tradeDate(t)}-${String(t.symbol)}-${i}`}>
                      {columns.map((c) => (
                        <td
                          key={c}
                          className={`table-cell ${c === 'pnl' && pnl !== undefined ? (pnl >= 0 ? 'text-green-300' : 'text-red-300') : ''}`}
                        >
                          {formatValue(cell(t, c))}
                        </td>
                      ))}
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </Section>

      <Section title="Backtest results">
        <ErrorMessage message={backtest.error} />
        {backtest.loading && !backtest.data ? (
          <Loading />
        ) : (backtest.data?.results.length ?? 0) === 0 ? (
          <p className="text-sm text-gray-300">{backtest.data?.message ?? 'No backtest results available.'}</p>
        ) : (
          <div className="space-y-4">
            {backtest.data?.results.map((r) => (
              <details key={r.file} className="rounded-md border border-gray-700 p-3">
                <summary className="cursor-pointer font-medium focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-400">
                  {r.file}{' '}
                  <span
                    className={`ml-2 rounded px-1.5 py-0.5 text-xs font-semibold ${
                      (r.data_source ?? 'unknown') === 'synthetic' || (r.data_source ?? 'unknown') === 'unknown'
                        ? 'bg-amber-900 text-amber-100'
                        : 'bg-gray-700 text-gray-100'
                    }`}
                  >
                    Data: {r.data_source ?? 'unknown'}
                  </span>
                </summary>
                <div className="mt-3">
                  <DataSourceNotice data={{ ...r.data, data_source: r.data_source ?? r.data.data_source }} unknownSourceWarning />
                  <KeyValueList entries={flatten(r.data.performance ?? r.data)} />
                </div>
              </details>
            ))}
          </div>
        )}
      </Section>
    </>
  );
}
