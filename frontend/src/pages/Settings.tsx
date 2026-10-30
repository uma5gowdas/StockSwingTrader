import { useEffect, useState, type FormEvent } from 'react';
import { usePolling } from '../hooks/usePolling';
import { usePollingInterval } from '../hooks/usePreferences';
import { EDITABLE_SETTINGS, errorMessage, getSettings, updateSetting, type EditableSetting } from '../utils/api';
import { humanizeKey, isSecretKey } from '../utils/format';
import { MIN_POLLING_INTERVAL_MS, setPollingInterval } from '../utils/preferences';
import { ErrorMessage, KeyValueList, Loading, PageHeader, Section } from '../components/ui';

const fieldClass =
  'mt-1 w-full rounded-md border border-gray-600 bg-gray-900 px-3 py-2 text-white focus:outline-none focus:ring-2 focus:ring-blue-400';

export default function Settings() {
  // Polled like other pages so edits made to config.sh outside the UI show up.
  const settings = usePolling(getSettings, []);
  const intervalMs = usePollingInterval();
  const [intervalInput, setIntervalInput] = useState(String(intervalMs / 1000));
  const [drafts, setDrafts] = useState<Partial<Record<EditableSetting, string>>>({});
  const [status, setStatus] = useState<string | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [saving, setSaving] = useState<EditableSetting | null>(null);

  useEffect(() => setIntervalInput(String(intervalMs / 1000)), [intervalMs]);

  const saveInterval = (e: FormEvent) => {
    e.preventDefault();
    const seconds = Number(intervalInput);
    if (!Number.isFinite(seconds) || seconds * 1000 < MIN_POLLING_INTERVAL_MS) {
      setSaveError(`Polling interval must be at least ${MIN_POLLING_INTERVAL_MS / 1000} second.`);
      return;
    }
    setPollingInterval(seconds * 1000);
    setSaveError(null);
    setStatus(`Polling interval set to ${seconds} seconds.`);
  };

  const saveSetting = async (e: FormEvent, key: EditableSetting) => {
    e.preventDefault();
    const value = drafts[key] ?? settings.data?.[key] ?? '';
    setSaving(key);
    setSaveError(null);
    try {
      const result = await updateSetting(key, value);
      setStatus(result.message);
      setDrafts((d) => ({ ...d, [key]: undefined }));
      settings.refresh();
    } catch (err) {
      setSaveError(errorMessage(err));
    } finally {
      setSaving(null);
    }
  };

  const readOnly = Object.entries(settings.data ?? {})
    .filter(([key]) => !(EDITABLE_SETTINGS as readonly string[]).includes(key))
    .map(([key, value]): [string, unknown] => [key, isSecretKey(key) && value ? '••••••••' : value]);

  return (
    <>
      <PageHeader title="Settings" description="Dashboard preferences and trading configuration (config.sh)." />

      <div aria-live="polite" className="mb-4 space-y-2">
        {status && <p role="status" className="rounded-md border border-green-700 bg-green-950 px-3 py-2 text-sm text-green-200">{status}</p>}
        <ErrorMessage message={saveError} />
      </div>

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <Section title="Dashboard">
          <form onSubmit={saveInterval} className="flex items-end gap-2">
            <div className="flex-1">
              <label htmlFor="polling-interval" className="block text-sm text-gray-300">Polling interval (seconds)</label>
              <input
                id="polling-interval"
                type="number"
                min={MIN_POLLING_INTERVAL_MS / 1000}
                step={1}
                value={intervalInput}
                onChange={(e) => setIntervalInput(e.target.value)}
                className={fieldClass}
              />
            </div>
            <button type="submit" className="btn-primary">Save</button>
          </form>
        </Section>

        <Section title="Risk and trading">
          <ErrorMessage message={settings.error} />
          {settings.loading && !settings.data ? (
            <Loading />
          ) : (
            <div className="space-y-4">
              {EDITABLE_SETTINGS.map((key) => {
                const id = `setting-${key}`;
                const current = settings.data?.[key] ?? '';
                const value = drafts[key] ?? current;
                return (
                  <form key={key} onSubmit={(e) => void saveSetting(e, key)} className="flex items-end gap-2">
                    <div className="flex-1">
                      <label htmlFor={id} className="block text-sm text-gray-300">{humanizeKey(key)}</label>
                      {key === 'TRADING_ENABLED' ? (
                        <select id={id} value={value} onChange={(e) => setDrafts((d) => ({ ...d, [key]: e.target.value }))} className={fieldClass}>
                          {value !== 'true' && value !== 'false' && <option value={value}>{value || '(unset)'}</option>}
                          <option value="true">true</option>
                          <option value="false">false</option>
                        </select>
                      ) : (
                        <input id={id} value={value} inputMode="decimal" onChange={(e) => setDrafts((d) => ({ ...d, [key]: e.target.value }))} className={fieldClass} />
                      )}
                    </div>
                    <button type="submit" className="btn-primary" disabled={saving === key || value === current} aria-label={`Save ${humanizeKey(key)}`}>
                      {saving === key ? 'Saving…' : 'Save'}
                    </button>
                  </form>
                );
              })}
            </div>
          )}
        </Section>

        <Section title="Other configuration (read only)" className="lg:col-span-2">
          <p className="mb-3 text-xs text-gray-400">Secret values are masked. Edit config.sh directly to change these.</p>
          {settings.loading && !settings.data ? <Loading /> : <KeyValueList entries={readOnly} />}
        </Section>
      </div>
    </>
  );
}
