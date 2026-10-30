import { useCallback, useEffect, useRef, useState } from 'react';
import { errorMessage, isCancelled } from '../utils/api';
import { getPollingInterval } from '../utils/preferences';

export interface PollingState<T> {
  data: T | null;
  error: string | null;
  loading: boolean;
  lastUpdated: Date | null;
  refresh: () => void;
}

/**
 * Poll an async fetcher. The next request is scheduled only after the
 * previous one settles, so slow bash-backed endpoints never stack up.
 * Interval defaults to 5 seconds (configurable on the Settings page).
 */
export function usePolling<T>(
  fetcher: (signal: AbortSignal) => Promise<T>,
  deps: ReadonlyArray<unknown>,
  enabled = true,
): PollingState<T> {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState<boolean>(enabled);
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);
  const [tick, setTick] = useState(0);
  const fetcherRef = useRef(fetcher);
  fetcherRef.current = fetcher;

  const refresh = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    if (!enabled) {
      setLoading(false);
      return undefined;
    }
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const controller = new AbortController();
    setLoading(true);

    const run = async () => {
      try {
        const result = await fetcherRef.current(controller.signal);
        if (cancelled) return;
        setData(result);
        setError(null);
        setLastUpdated(new Date());
      } catch (err) {
        if (cancelled || isCancelled(err)) return;
        setError(errorMessage(err));
      } finally {
        if (!cancelled) {
          setLoading(false);
          timer = setTimeout(run, getPollingInterval());
        }
      }
    };

    void run();
    return () => {
      cancelled = true;
      controller.abort();
      if (timer) clearTimeout(timer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [enabled, tick, ...deps]);

  return { data, error, loading, lastUpdated, refresh };
}
