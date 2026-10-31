import { useState, type FormEvent } from 'react';
import { useSearchParams } from 'react-router-dom';
import { Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';
import { usePolling } from '../hooks/usePolling';
import { getIndicators, getQuote, getSignals, isValidSymbol, normalizeSymbol } from '../utils/api';
import { extractPrice, extractScore, extractSignal, flatten, formatNumber, numericEntries } from '../utils/format';
import { DataSourceNotice, ErrorMessage, KeyValueList, LastUpdated, Loading, PageHeader, Section, SignalBadge, StatCard } from '../components/ui';

export default function Analysis() {
  const [params, setParams] = useSearchParams();
  const symbol = normalizeSymbol(params.get('symbol') ?? 'AAPL');
  const valid = isValidSymbol(symbol);
  const [input, setInput] = useState(symbol);
  const [inputError, setInputError] = useState<string | null>(null);

  const signals = usePolling((s) => getSignals(symbol, s), [symbol], valid);
  const indicators = usePolling((s) => getIndicators(symbol, s), [symbol], valid);
  const quote = usePolling((s) => getQuote(symbol, s), [symbol], valid);

  const onSubmit = (e: FormEvent) => {
    e.preventDefault();
    const next = normalizeSymbol(input);
    if (!isValidSymbol(next)) {
      setInputError('Enter a ticker of 1–10 letters, digits, dots or dashes, starting with a letter.');
      return;
    }
    setInputError(null);
    setParams({ symbol: next });
  };

  const score = extractScore(signals.data);
  const indicatorChart = numericEntries(indicators.data).filter((e) => e.name !== 'timestamp').slice(0, 20);

  return (
    <>
      <PageHeader title={`Analysis: ${symbol}`} description="Full signal, indicator and quote breakdown for one symbol.">
        <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-2" noValidate>
          <div>
            <label htmlFor="symbol-input" className="block text-sm text-gray-300">
              Symbol
            </label>
            <input
              id="symbol-input"
              value={input}
              onChange={(e) => setInput(e.target.value)}
              aria-invalid={inputError ? true : undefined}
              aria-describedby={inputError ? 'symbol-error' : undefined}
              autoComplete="off"
              className="mt-1 w-32 rounded-md border border-gray-600 bg-gray-900 px-3 py-2 uppercase text-white focus:border-blue-400 focus:outline-none focus:ring-2 focus:ring-blue-400"
            />
          </div>
          <button type="submit" className="btn-primary">Analyze</button>
          {inputError && (
            <p id="symbol-error" role="alert" className="w-full text-sm text-red-300">
              {inputError}
            </p>
          )}
        </form>
      </PageHeader>

      {!valid ? (
        <ErrorMessage message={`"${symbol}" is not a valid symbol.`} />
      ) : (
        <>
          <dl className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-3">
            <StatCard label="Price" value={formatNumber(extractPrice(quote.data))} />
            <StatCard label="Confluence score" value={formatNumber(score, 1)} hint="0–100" />
            <StatCard label="Signal" value={<SignalBadge signal={extractSignal(signals.data)} />} />
          </dl>
          <DataSourceNotice data={signals.data} />
          <LastUpdated date={signals.lastUpdated} loading={signals.loading} />

          <div className="mt-4 grid grid-cols-1 gap-6 lg:grid-cols-2">
            <Section title="Indicator values">
              {indicators.loading && !indicators.data ? (
                <Loading />
              ) : indicatorChart.length === 0 ? (
                <p className="text-sm text-gray-300">No numeric indicator values returned.</p>
              ) : (
                <figure>
                  <div className="h-72" aria-hidden="true">
                    <ResponsiveContainer width="100%" height="100%">
                      <BarChart data={indicatorChart} layout="vertical" margin={{ left: 40 }}>
                        <CartesianGrid strokeDasharray="3 3" stroke="#334155" />
                        <XAxis type="number" stroke="#cbd5e1" />
                        <YAxis type="category" dataKey="name" stroke="#cbd5e1" width={120} />
                        <Tooltip contentStyle={{ backgroundColor: '#1e293b', border: '1px solid #475569' }} />
                        <Bar dataKey="value" fill="#3b82f6" />
                      </BarChart>
                    </ResponsiveContainer>
                  </div>
                  <figcaption className="sr-only">Indicator values are listed in the Indicators section.</figcaption>
                </figure>
              )}
            </Section>

            <Section title="Signal details">
              <ErrorMessage message={signals.error} />
              {signals.loading && !signals.data ? <Loading /> : <KeyValueList entries={flatten(signals.data)} />}
            </Section>

            <Section title="Indicators">
              <ErrorMessage message={indicators.error} />
              {indicators.loading && !indicators.data ? <Loading /> : <KeyValueList entries={flatten(indicators.data)} />}
            </Section>

            <Section title="Quote">
              <ErrorMessage message={quote.error} />
              {quote.loading && !quote.data ? <Loading /> : <KeyValueList entries={flatten(quote.data)} />}
            </Section>
          </div>
        </>
      )}
    </>
  );
}
