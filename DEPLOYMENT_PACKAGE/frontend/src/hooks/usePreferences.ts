import { useSyncExternalStore } from 'react';
import { getAlerts, getPollingInterval, getWatchlist, subscribePreferences } from '../utils/preferences';

// Snapshots must be referentially stable between changes, so cache by raw JSON.
function cached<T>(getter: () => T): () => T {
  let lastJson = '';
  let lastValue: T;
  return () => {
    const value = getter();
    const json = JSON.stringify(value);
    if (json !== lastJson) {
      lastJson = json;
      lastValue = value;
    }
    return lastValue;
  };
}

const watchlistSnapshot = cached(getWatchlist);
const alertsSnapshot = cached(getAlerts);

export const useWatchlist = () => useSyncExternalStore(subscribePreferences, watchlistSnapshot);
export const useAlerts = () => useSyncExternalStore(subscribePreferences, alertsSnapshot);
export const usePollingInterval = () => useSyncExternalStore(subscribePreferences, getPollingInterval);
