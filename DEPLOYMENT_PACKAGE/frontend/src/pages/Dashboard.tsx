import { Link } from 'react-router-dom';
import { Bar, BarChart, CartesianGrid, Cell, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';
import { usePolling } from '../hooks/usePolling';
import { useWatchlist } from '../hooks/usePreferences';
import { errorMessage, getHealth, getPortfolio, getSignals, getStats, type JsonObject } from '../utils/api';
import { dataProvenance, extractScore, extractSignal, flatten, formatNumber } from '../utils/format';
import { ErrorMessage, KeyValueList, LastUpdated, Loading, PageHeader, Section, SignalBadge, StatCard } from '../components/ui';

interface SymbolSignal {
  symbol: string;
  score?: number;
  signal?: string;
  /** Score was computed from synthetic (demo/test) data. */
  synthetic?: boolean;
  error?: string;
}

async function fetchWatchlistSignals(symbols: string[], signal: AbortSignal): Promise<SymbolSignal[]> {
  const results = await Promise.allSettled(symbols.map((s) => getSignals(s, signal)));
  return results.map((result, i) => {
    if (result.status === 'rejected') return { symbol: symbols[i], error: errorMessage(result.reason) };
    const data: JsonObject = result.value;
    return { symbol: symbols[i], score: extractScore(data), signal: extractSignal(data), synthetic: dataProvenance(data).synthetic };
  });
}

function barColor(signal: string | undefined): string {
  if (signal?.includes('BUY')) return '#10b981';
  if (signal?.includes('SELL')) return '#ef4444';
  return '#eab308';
}

export default function Dashboard() {
  const watchlist = useWatchlist();
  const health = usePolling(getHealth, []);
  const portfolio = usePolling(getPortfolio, []);
  const stats = usePolling(getStats, []);
  const signals = usePolling((signal) => fetchWatchlistSignals(watchlist, signal), [watchlist.join(',')]);

  const rows = signals.data ?? [];
  const scored = rows.filter((r) => r.score !== undefined);
  const count = (kind: string) => rows.filter((r) => r.signal?.includes(kind)).length;
  const avgScore = scored.length ? scored.reduce((sum, r) => sum + (r.score ?? 0), 0) / scored.length : undefined;
  const chartData = scored.map((r) => ({ symbol: r.symbol, score: r.score ?? 0, signal: r.signal }));

  return (
    <>
      <PageHeader title="Dashboard" description="Watchlist signals, portfolio overview and quick stats. Refreshes every few seconds.">
        <div className="text-right">
          <p className="text-sm">
            Backend:{' '}
            <span className={health.data?.status === 'healthy' ? 'text-green-400' : 'text-red-400'}>
              {health.data?.status ?? (health.error ? 'unreachable' : 'checking…')}
            </span>
          </p>
          <LastUpdated date={signals.lastUpdated} loading={signals.loading} />
        </div>
      </PageHeader>

      <dl className="mb-6 grid grid-cols-2 gap-4 md:grid-cols-5">
        <StatCard label="Symbols" value={rows.length || watchlist.length} />
        <StatCard label="Buy signals" value={count('BUY')} />
        <StatCard label="Sell signals" value={count('SELL')} />
        <StatCard label="Hold signals" value={count('HOLD')} />
        <StatCard label="Average score" value={formatNumber(avgScore, 1)} />
      </dl>

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <Section title="Signal scores">
          {signals.loading && !signals.data ? (
            <Loading label="Calculating signals…" />
          ) : chartData.length === 0 ? (
            <p className="text-sm text-gray-300">No scores available yet.</p>
          ) : (
            <figure>
              <div className="h-64" aria-hidden="true">
                <ResponsiveContainer width="100%" height="100%">
                  <BarChart data={chartData}>
                    <CartesianGrid strokeDasharray="3 3" stroke="#334155" />
                    <XAxis dataKey="symbol" stroke="#cbd5e1" />
                    <YAxis domain={[0, 100]} stroke="#cbd5e1" />
                    <Tooltip contentStyle={{ backgroundColor: '#1e293b', border: '1px solid #475569' }} />
                    <Bar dataKey="score" name="Confluence score">
                      {chartData.map((d) => (
                        <Cell key={d.symbol} fill={barColor(d.signal)} />
                      ))}
                    </Bar>
                  </BarChart>
                </ResponsiveContainer>
              </div>
              <figcaption className="sr-only">
                Confluence scores: {chartData.map((d) => `${d.symbol} ${formatNumber(d.score, 0)}`).join(', ')}
              </figcaption>
            </figure>
          )}
        </Section>

        <Section title="Watchlist signals">
          <ErrorMessage message={signals.error} />
          {rows.some((r) => r.synthetic) && (
            <p role="alert" className="mb-3 rounded-md border border-amber-600 bg-amber-950 px-3 py-2 text-sm text-amber-100">
              <strong>Synthetic data:</strong> scores marked “synthetic” were computed from generated demo/test data, not market data.
            </p>
          )}
          <div className="overflow-x-auto">
            <table className="w-full text-left">
              <caption className="sr-only">Current signal per watchlist symbol</caption>
              <thead>
                <tr>
                  <th scope="col" className="table-header">Symbol</th>
                  <th scope="col" className="table-header">Score</th>
                  <th scope="col" className="table-header">Signal</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.symbol}>
                    <th scope="row" className="table-cell font-medium">
                      <Link className="text-blue-300 underline hover:text-blue-200" to={`/analysis?symbol=${encodeURIComponent(r.symbol)}`}>
                        {r.symbol}
                      </Link>
                    </th>
                    <td className="table-cell">
                      {r.error ? <span className="text-red-300">{r.error}</span> : formatNumber(r.score, 1)}
                      {r.synthetic && <span className="ml-2 rounded bg-amber-900 px-1.5 py-0.5 text-xs font-semibold text-amber-100">synthetic</span>}
                    </td>
                    <td className="table-cell"><SignalBadge signal={r.signal} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Section>

        <Section title="Portfolio">
          <ErrorMessage message={portfolio.error} />
          {portfolio.loading && !portfolio.data ? <Loading /> : <KeyValueList entries={flatten(portfolio.data)} />}
        </Section>

        <Section title="Statistics">
          <ErrorMessage message={stats.error} />
          {stats.loading && !stats.data ? <Loading /> : <KeyValueList entries={flatten(stats.data)} />}
        </Section>
      </div>
    </>
  );
}
