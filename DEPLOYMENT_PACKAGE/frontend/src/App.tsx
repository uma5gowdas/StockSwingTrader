import { useEffect, useRef } from 'react';
import { NavLink, Route, Routes, useLocation } from 'react-router-dom';
import Dashboard from './pages/Dashboard';
import Analysis from './pages/Analysis';
import TradeHistory from './pages/TradeHistory';
import Watchlist from './pages/Watchlist';
import Settings from './pages/Settings';
import NotFound from './pages/NotFound';

const NAV_ITEMS = [
  { to: '/', label: 'Dashboard' },
  { to: '/analysis', label: 'Analysis' },
  { to: '/trades', label: 'Trade History' },
  { to: '/watchlist', label: 'Watchlist' },
  { to: '/settings', label: 'Settings' },
];

export default function App() {
  const location = useLocation();
  const mainRef = useRef<HTMLElement>(null);

  // Move focus to the main region on route change so screen readers announce the new page.
  useEffect(() => {
    mainRef.current?.focus();
  }, [location.pathname]);

  return (
    <div className="min-h-screen">
      <a
        href="#main-content"
        className="sr-only focus:not-sr-only focus:absolute focus:left-4 focus:top-4 focus:z-50 focus:rounded focus:bg-blue-600 focus:px-4 focus:py-2 focus:text-white"
      >
        Skip to main content
      </a>
      <header className="border-b border-gray-700 bg-dark-card">
        <div className="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-4 px-4 py-3">
          <p className="text-lg font-bold text-white">StockSwingTrader v6.3</p>
          <nav aria-label="Main">
            <ul className="flex flex-wrap gap-1">
              {NAV_ITEMS.map((item) => (
                <li key={item.to}>
                  <NavLink
                    to={item.to}
                    end={item.to === '/'}
                    className={({ isActive }) =>
                      `block rounded-md px-3 py-2 text-sm font-medium focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-400 ${
                        isActive ? 'bg-blue-600 text-white' : 'text-gray-200 hover:bg-gray-700'
                      }`
                    }
                  >
                    {item.label}
                  </NavLink>
                </li>
              ))}
            </ul>
          </nav>
        </div>
      </header>
      <main id="main-content" ref={mainRef} tabIndex={-1} className="mx-auto max-w-7xl px-4 py-6 focus:outline-none">
        <Routes>
          <Route path="/" element={<Dashboard />} />
          <Route path="/analysis" element={<Analysis />} />
          <Route path="/trades" element={<TradeHistory />} />
          <Route path="/watchlist" element={<Watchlist />} />
          <Route path="/settings" element={<Settings />} />
          <Route path="*" element={<NotFound />} />
        </Routes>
      </main>
    </div>
  );
}
