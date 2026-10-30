import axios from 'axios';

const API_BASE_URL = '/api';

const apiClient = axios.create({
  baseURL: API_BASE_URL,
  headers: {
    'Content-Type': 'application/json',
  },
});

// Portfolio and Dashboard APIs
export const getPortfolioSummary = () =>
  apiClient.get('/portfolio/summary');

export const getActivePositions = () =>
  apiClient.get('/portfolio/positions');

export const getEquityCurve = (days = 30) =>
  apiClient.get(`/portfolio/equity-curve?days=${days}`);

export const getTopPerformers = () =>
  apiClient.get('/portfolio/top-performers');

// Signal Analysis APIs
export const getSignalScores = () =>
  apiClient.get('/analysis/scores');

export const getSignalDetail = (symbol: string) =>
  apiClient.get(`/analysis/detail/${symbol}`);

export const getPriceChart = (symbol: string, period = '1d') =>
  apiClient.get(`/analysis/chart/${symbol}?period=${period}`);

export const getIndicators = (symbol: string) =>
  apiClient.get(`/analysis/indicators/${symbol}`);

// Trade History APIs
export const getTradeHistory = (limit = 100, offset = 0) =>
  apiClient.get(`/trades/history?limit=${limit}&offset=${offset}`);

export const getTradeStats = () =>
  apiClient.get('/trades/stats');

export const exportTrades = (format = 'csv') =>
  apiClient.get(`/trades/export?format=${format}`);

// Watchlist APIs
export const getWatchlist = () =>
  apiClient.get('/watchlist');

export const addToWatchlist = (symbol: string) =>
  apiClient.post('/watchlist/add', { symbol });

export const removeFromWatchlist = (symbol: string) =>
  apiClient.post(`/watchlist/remove/${symbol}`);

export const getQuote = (symbol: string) =>
  apiClient.get(`/watchlist/quote/${symbol}`);

export const getWatchlistQuotes = () =>
  apiClient.get('/watchlist/quotes');

// Settings APIs
export const getSettings = () =>
  apiClient.get('/settings');

export const updateSettings = (settings: any) =>
  apiClient.put('/settings', settings);

export const reloadConfig = () =>
  apiClient.post('/settings/reload');

export default apiClient;
