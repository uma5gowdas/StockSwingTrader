import type { ReactNode } from 'react';
import { dataProvenance, formatValue, humanizeKey, signalClass } from '../utils/format';

/**
 * Warns when a payload was computed from synthetic (demo/test) data or from
 * a source that is not recorded, and notes an unavailable ML component.
 * Renders nothing for payloads backed by real data.
 */
export function DataSourceNotice({ data, unknownSourceWarning = false }: { data: unknown; unknownSourceWarning?: boolean }) {
  if (data === null || data === undefined) return null;
  const p = dataProvenance(data);
  const unknown = unknownSourceWarning && !p.synthetic && (p.source === undefined || p.source === 'unknown');
  if (!p.synthetic && !unknown && !p.mlUnavailable) return null;
  return (
    <div className="mb-3 space-y-2">
      {p.synthetic && (
        <p role="alert" className="rounded-md border border-amber-600 bg-amber-950 px-3 py-2 text-sm text-amber-100">
          <strong>Synthetic data:</strong> these numbers were computed from generated demo/test data, not market data. Do not trade on them.
        </p>
      )}
      {unknown && (
        <p role="status" className="rounded-md border border-amber-700 bg-gray-900 px-3 py-2 text-sm text-amber-200">
          <strong>Unknown data source:</strong> this result does not record where its prices came from.
        </p>
      )}
      {p.mlUnavailable && (
        <p role="status" className="rounded-md border border-gray-600 bg-gray-900 px-3 py-2 text-sm text-gray-200">
          ML prediction unavailable ({p.mlUnavailable}); it has zero weight in this score.
        </p>
      )}
    </div>
  );
}

export function PageHeader({ title, description, children }: { title: string; description?: string; children?: ReactNode }) {
  return (
    <header className="mb-6 flex flex-wrap items-end justify-between gap-4">
      <div>
        <h1 className="text-2xl font-bold text-white">{title}</h1>
        {description && <p className="mt-1 text-sm text-gray-300">{description}</p>}
      </div>
      {children}
    </header>
  );
}

export function Section({ title, children, className = '' }: { title: string; children: ReactNode; className?: string }) {
  const id = `section-${title.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`;
  return (
    <section aria-labelledby={id} className={`card ${className}`}>
      <h2 id={id} className="mb-4 text-lg font-semibold text-white">
        {title}
      </h2>
      {children}
    </section>
  );
}

export function StatCard({ label, value, hint }: { label: string; value: ReactNode; hint?: string }) {
  return (
    <div className="card">
      <dt className="text-sm text-gray-300">{label}</dt>
      <dd className="mt-2 text-2xl font-semibold text-white">{value}</dd>
      {hint && <dd className="mt-1 text-xs text-gray-400">{hint}</dd>}
    </div>
  );
}

export function ErrorMessage({ message }: { message: string | null }) {
  if (!message) return null;
  return (
    <p role="alert" className="rounded-md border border-red-700 bg-red-950 px-3 py-2 text-sm text-red-200">
      {message}
    </p>
  );
}

export function Loading({ label = 'Loading…' }: { label?: string }) {
  return (
    <p role="status" aria-live="polite" className="text-sm text-gray-300">
      {label}
    </p>
  );
}

export function LastUpdated({ date, loading }: { date: Date | null; loading?: boolean }) {
  return (
    <p className="text-xs text-gray-400" aria-live="polite">
      {loading && !date ? 'Loading…' : date ? `Updated ${date.toLocaleTimeString()}` : 'Not loaded yet'}
    </p>
  );
}

export function SignalBadge({ signal }: { signal: string | undefined }) {
  return (
    <span className={`inline-block rounded px-2 py-0.5 text-xs font-semibold ${signalClass(signal)}`}>{signal ?? 'N/A'}</span>
  );
}

/** Render an arbitrary key/value list as a description list. */
export function KeyValueList({ entries, emptyText = 'No data available.' }: { entries: Array<[string, unknown]>; emptyText?: string }) {
  if (entries.length === 0) return <p className="text-sm text-gray-300">{emptyText}</p>;
  return (
    <dl className="grid grid-cols-1 gap-x-6 gap-y-2 sm:grid-cols-2">
      {entries.map(([key, value]) => (
        <div key={key} className="flex justify-between gap-4 border-b border-gray-700 py-1 text-sm">
          <dt className="text-gray-300">{humanizeKey(key)}</dt>
          <dd className="break-all text-right font-mono text-gray-100">{formatValue(value)}</dd>
        </div>
      ))}
    </dl>
  );
}
