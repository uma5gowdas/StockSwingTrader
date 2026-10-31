#!/usr/bin/env python3
"""
XGBoost Model Inference Script

Loads trained XGBoost model and makes real-time predictions on stock data.

Usage:
  python3 ml_inference.py --symbol AAPL --period 5 < ohlcv_data.json

Input JSON Format:
  {
    "symbol": "AAPL",
    "date": "2024-01-15",
    "open": 185.50,
    "high": 186.75,
    "low": 185.25,
    "close": 186.30,
    "volume": 52000000
  }

Output JSON Format:
  {
    "symbol": "AAPL",
    "available": true,
    "direction": "up|down",
    "confidence": 0-100,
    "probability": 0.0-1.0,
    "data_source": "yfinance|file|stdin|synthetic",
    "model_training_data": "synthetic",
    "timestamp": "2024-01-15T14:30:00Z"
  }

  When there is not enough real data (and synthetic data was not requested):
  {"symbol": "AAPL", "available": false, "reason": "...", "data_source": null, ...}

Synthetic features are used ONLY when explicitly requested: --synthetic,
SST_ALLOW_SYNTHETIC=1 (real data first, synthetic fallback) or SST_OFFLINE=1
(no network, synthetic). Such results carry "data_source": "synthetic" and a
"warning" string.
"""

import os
import sys
import json
import zlib
import argparse
from pathlib import Path
import logging
from datetime import datetime, timezone

import numpy as np
import pandas as pd

# yfinance is imported lazily in fetch_current_data() (it is slow to import
# and not needed in offline mode or when data is supplied).

# Try importing joblib
try:
    from joblib import load
except ImportError:
    print(json.dumps({"error": "joblib not installed"}), file=sys.stdout)
    sys.exit(1)

# Setup logging to stderr only
logging.basicConfig(
    level=logging.WARNING,
    format='%(levelname)s: %(message)s',
    stream=sys.stderr
)
logger = logging.getLogger(__name__)

SCRIPT_DIR = Path(__file__).parent
MODELS_DIR = SCRIPT_DIR / 'models'
MODEL_PATH = MODELS_DIR / 'xgboost_predictor.pkl'

# Rows of real OHLCV needed for the indicator features (EMA50 etc.)
MIN_ROWS = 50

# train_ml_model.py only trains on generated data; reported with every
# prediction so a real-data prediction is not mistaken for a validated model.
MODEL_TRAINING_DATA = 'synthetic'

SYNTHETIC_WARNING = ('Prediction uses SYNTHETIC features (demo/test mode), '
                     'not market data. Do not trade on it.')


def synthetic_allowed(flag=False):
    """Synthetic data is opt-in: --synthetic, SST_ALLOW_SYNTHETIC=1 or SST_OFFLINE=1."""
    return (bool(flag)
            or os.environ.get('SST_ALLOW_SYNTHETIC') == '1'
            or os.environ.get('SST_OFFLINE') == '1')


def calculate_rsi(prices, period=14):
    """Calculate Relative Strength Index."""
    if len(prices) < period + 1:
        return np.full(len(prices), 50.0)
    
    deltas = np.diff(prices)
    seed = deltas[:period+1]
    up = seed[seed >= 0].sum() / period
    down = -seed[seed < 0].sum() / period
    rs = up / down if down != 0 else 1.0
    rsi = np.zeros_like(prices, dtype=float)
    rsi[:period] = 100. - 100. / (1. + rs)
    
    for i in range(period, len(prices)):
        delta = deltas[i - 1]
        if delta > 0:
            upval = delta
            downval = 0.
        else:
            upval = 0.
            downval = -delta
        
        up = (up * (period - 1) + upval) / period
        down = (down * (period - 1) + downval) / period
        rs = up / down if down != 0 else 1.0
        rsi[i] = 100. - 100. / (1. + rs)
    
    return rsi


def calculate_macd(prices, fast=12, slow=26, signal=9):
    """Calculate MACD."""
    if len(prices) < slow:
        return np.zeros_like(prices), np.zeros_like(prices), np.zeros_like(prices)
    
    ema_fast = pd.Series(prices).ewm(span=fast).mean().values
    ema_slow = pd.Series(prices).ewm(span=slow).mean().values
    macd = ema_fast - ema_slow
    macd_signal = pd.Series(macd).ewm(span=signal).mean().values
    macd_hist = macd - macd_signal
    return macd, macd_signal, macd_hist


def calculate_bollinger_bands(prices, period=20, num_std=2):
    """Calculate Bollinger Bands."""
    if len(prices) < period:
        return prices, prices + 1, prices - 1, np.full_like(prices, 0.5, dtype=float)
    
    sma = pd.Series(prices).rolling(window=period).mean().values
    std = pd.Series(prices).rolling(window=period).std().values
    upper_band = sma + (std * num_std)
    lower_band = sma - (std * num_std)
    bb_position = (prices - lower_band) / (upper_band - lower_band)
    bb_position = np.clip(bb_position, 0, 1)
    return sma, upper_band, lower_band, bb_position


def calculate_atr(high, low, close, period=14):
    """Calculate Average True Range."""
    tr = np.maximum(
        high - low,
        np.maximum(
            np.abs(high - np.roll(close, 1)),
            np.abs(low - np.roll(close, 1))
        )
    )
    atr = pd.Series(tr).rolling(window=period).mean().values
    return atr


def calculate_stochastic(high, low, close, period=14):
    """Calculate Stochastic Oscillator."""
    if len(close) < period:
        return np.full_like(close, 50.0, dtype=float), np.full_like(close, 50.0, dtype=float)
    
    lowest_low = pd.Series(low).rolling(window=period).min().values
    highest_high = pd.Series(high).rolling(window=period).max().values
    
    k_percent = np.zeros_like(close, dtype=float)
    for i in range(period, len(close)):
        denom = highest_high[i] - lowest_low[i]
        if denom != 0:
            k_percent[i] = 100 * (close[i] - lowest_low[i]) / denom
        else:
            k_percent[i] = 50
    
    d_percent = pd.Series(k_percent).rolling(window=3).mean().values
    return np.clip(k_percent, 0, 100), np.clip(d_percent, 0, 100)


def calculate_ema(prices, period):
    """Calculate Exponential Moving Average."""
    if len(prices) < period:
        return np.full_like(prices, prices[-1], dtype=float)
    return pd.Series(prices).ewm(span=period).mean().values


def fetch_current_data(symbol, periods=50):
    """Fetch recent daily OHLCV from yfinance.

    Returns (DataFrame, None) on success or (None, reason) when offline
    (SST_OFFLINE=1), yfinance is missing, the fetch fails or returns nothing.
    """
    if os.environ.get('SST_OFFLINE') == '1':
        return None, 'SST_OFFLINE=1: market data fetch disabled'
    try:
        import yfinance as yf
    except ImportError:
        return None, 'yfinance not installed'
    try:
        data = yf.download(symbol, period='3mo', progress=False)
        if data is None or data.empty:
            return None, f'yfinance returned no data for {symbol}'
        # Recent yfinance returns (field, ticker) MultiIndex columns
        if isinstance(data.columns, pd.MultiIndex):
            data.columns = data.columns.get_level_values(0)
        return data.tail(periods).reset_index(), None
    except Exception as e:
        logger.error(f"Error fetching data: {e}")
        return None, f'yfinance fetch failed: {e}'


def generate_synthetic_features_for_symbol(symbol):
    """Generate seeded synthetic features for a symbol.

    Only called when synthetic data was explicitly requested (see
    synthetic_allowed()); results are marked "data_source": "synthetic".
    """
    # Stable per-symbol seed (built-in hash() is randomised per process)
    np.random.seed(zlib.crc32(symbol.encode('utf-8')))
    
    features = {}
    features['rsi_14'] = float(np.random.normal(50, 15))
    features['rsi_14'] = np.clip(features['rsi_14'], 0, 100)
    features['macd'] = float(np.random.normal(0, 0.5))
    features['macd_signal'] = float(np.random.normal(0, 0.5))
    features['macd_hist'] = features['macd'] - features['macd_signal']
    features['bb_position'] = float(np.random.uniform(0, 1))
    features['bb_width'] = float(np.random.uniform(0.01, 0.1))
    features['atr'] = float(np.random.uniform(0.01, 0.1))
    features['stochastic_k'] = float(np.random.uniform(0, 1))
    features['stochastic_d'] = float(np.random.uniform(0, 1))
    features['ema_20'] = float(np.random.normal(100, 2))
    features['ema_50'] = float(np.random.normal(100, 2))
    features['volume_ratio'] = float(np.random.uniform(0.5, 2.0))
    features['close_price'] = float(np.random.uniform(50, 500))
    features['price_range'] = float(np.random.uniform(0.005, 0.05))
    
    return features


def extract_features_from_data(df):
    """Extract features from DataFrame."""
    if df is None or len(df) < MIN_ROWS:
        return None
    
    close = df['Close'].values
    high = df['High'].values
    low = df['Low'].values
    volume = df['Volume'].values
    
    features = {}
    
    # RSI
    rsi = calculate_rsi(close, period=14)
    features['rsi_14'] = rsi[-1]
    
    # MACD
    macd, macd_signal, macd_hist = calculate_macd(close)
    features['macd'] = macd[-1]
    features['macd_signal'] = macd_signal[-1]
    features['macd_hist'] = macd_hist[-1]
    
    # Bollinger Bands
    bb_sma, bb_upper, bb_lower, bb_position = calculate_bollinger_bands(close)
    features['bb_position'] = bb_position[-1]
    bb_width = (bb_upper[-1] - bb_lower[-1]) / (bb_sma[-1] if bb_sma[-1] != 0 else 1)
    features['bb_width'] = bb_width
    
    # ATR
    atr = calculate_atr(high, low, close, period=14)
    features['atr'] = atr[-1]
    
    # Stochastic
    k_percent, d_percent = calculate_stochastic(high, low, close, period=14)
    features['stochastic_k'] = k_percent[-1] / 100.0
    features['stochastic_d'] = d_percent[-1] / 100.0
    
    # EMA
    ema_20 = calculate_ema(close, period=20)
    ema_50 = calculate_ema(close, period=50)
    features['ema_20'] = ema_20[-1]
    features['ema_50'] = ema_50[-1]
    
    # Volume ratio
    vol_sma = pd.Series(volume).rolling(window=20).mean().iloc[-1]
    features['volume_ratio'] = volume[-1] / vol_sma if vol_sma != 0 else 1.0
    
    # Price features
    features['close_price'] = close[-1]
    price_range = (high[-1] - low[-1]) / (close[-1] if close[-1] != 0 else 1)
    features['price_range'] = price_range
    
    return features


def unavailable_result(symbol, period, reason):
    """Explicit 'no prediction' result: callers give ML zero weight."""
    return {
        "symbol": symbol,
        "available": False,
        "reason": reason,
        "data_source": None,
        "period": period,
        "timestamp": datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    }


def predict(symbol, period, model, historical_data=None, data_source=None, allow_synthetic=False):
    """Make prediction using loaded model.

    historical_data/data_source: OHLCV supplied by the caller ('file' or
    'stdin'). With fewer than MIN_ROWS supplied rows, stdin data is ignored
    and yfinance is tried; a too-short data file is reported as such.
    Without enough real data the result is unavailable_result() unless
    synthetic data is allowed (synthetic_allowed()).
    """
    try:
        features_dict = None
        source = None
        reason = None

        if historical_data is not None and len(historical_data) >= MIN_ROWS:
            features_dict = extract_features_from_data(historical_data)
            source = data_source
        elif historical_data is not None and data_source == 'file':
            reason = f'data file has {len(historical_data)} rows; {MIN_ROWS} needed'
        else:
            df, reason = fetch_current_data(symbol, periods=MIN_ROWS)
            if df is not None and len(df) >= MIN_ROWS:
                features_dict = extract_features_from_data(df)
                source = 'yfinance'
            elif df is not None:
                reason = f'yfinance returned {len(df)} rows for {symbol}; {MIN_ROWS} needed'

        if features_dict is None and source is None:
            if not synthetic_allowed(allow_synthetic):
                return unavailable_result(symbol, period, reason or 'no market data')
            logger.warning(f"No real data for {symbol} ({reason}); using SYNTHETIC features (explicitly allowed)")
            features_dict = generate_synthetic_features_for_symbol(symbol)
            source = 'synthetic'

        if features_dict is None:
            return {"error": "Failed to extract features"}
        
        # Convert to feature vector in correct order (must match training)
        feature_names = [
            'rsi_14', 'macd', 'macd_signal', 'macd_hist',
            'bb_position', 'bb_width', 'atr',
            'stochastic_k', 'stochastic_d',
            'ema_20', 'ema_50', 'volume_ratio',
            'close_price', 'price_range'
        ]
        
        feature_vector = []
        for fname in feature_names:
            if fname in features_dict:
                feature_vector.append(features_dict[fname])
            else:
                feature_vector.append(0.0)
        
        feature_vector = np.array(feature_vector).reshape(1, -1)
        
        # Make prediction
        prediction = model.predict(feature_vector)[0]
        probability = model.predict_proba(feature_vector)[0]
        
        # Determine direction and confidence
        direction = "up" if prediction == 1 else "down"
        prob_value = float(probability[1]) if prediction == 1 else float(probability[0])
        confidence = int(prob_value * 100)
        
        result = {
            "symbol": symbol,
            "available": True,
            "direction": direction,
            "confidence": confidence,
            "probability": round(prob_value, 4),
            "period": period,
            "data_source": source,
            "model_training_data": MODEL_TRAINING_DATA,
            "timestamp": datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        }
        if source == 'synthetic':
            result["warning"] = SYNTHETIC_WARNING
        
        return result
    
    except Exception as e:
        logger.error(f"Prediction error: {e}")
        return {"error": str(e)}


def main():
    """Main inference function."""
    parser = argparse.ArgumentParser(description='XGBoost Stock Direction Predictor')
    parser.add_argument('--symbol', type=str, required=True, help='Stock symbol (e.g., AAPL)')
    parser.add_argument('--period', type=int, default=5, help='Forecast period in days')
    parser.add_argument('--data-file', type=str, default=None,
                        help='Optional CSV file with Open/High/Low/Close/Volume columns')
    parser.add_argument('--synthetic', action='store_true',
                        help='Allow seeded synthetic features when real data is unavailable '
                             '(demo/test only; output is marked data_source=synthetic)')
    
    args = parser.parse_args()
    
    # Check if model exists
    if not MODEL_PATH.exists():
        result = {"error": f"Model not found at {MODEL_PATH}. Train model first using train_ml_model.py"}
        print(json.dumps(result), file=sys.stdout)
        return 1
    
    try:
        # Load model
        model = load(MODEL_PATH)
        
        historical_data = None
        data_source = None
        if args.data_file:
            # Historical OHLCV from CSV (column names are case-insensitive)
            try:
                df = pd.read_csv(args.data_file)
            except Exception as e:
                print(json.dumps({"error": f"Cannot read data file {args.data_file}: {e}"}))
                return 1
            df.columns = [str(c).strip().capitalize() for c in df.columns]
            missing = [c for c in ('High', 'Low', 'Close', 'Volume') if c not in df.columns]
            if missing:
                print(json.dumps({"error": f"Data file missing columns: {', '.join(missing)}"}))
                return 1
            historical_data = df
            data_source = 'file'
        # Otherwise try to read input data from stdin
        elif not sys.stdin.isatty():
            try:
                stdin_data = sys.stdin.read()
                if stdin_data.strip():
                    # Try parsing as JSON
                    try:
                        json_data = json.loads(stdin_data)
                        # Could be single record or array of records
                        if isinstance(json_data, dict):
                            # Single record - create minimal DataFrame
                            df_dict = {
                                'Close': [json_data.get('close', 0)],
                                'High': [json_data.get('high', 0)],
                                'Low': [json_data.get('low', 0)],
                                'Volume': [json_data.get('volume', 0)]
                            }
                            historical_data = pd.DataFrame(df_dict)
                            data_source = 'stdin'
                        elif isinstance(json_data, list) and json_data:
                            # Array of OHLCV records (keys case-insensitive,
                            # values may be numeric strings)
                            df = pd.DataFrame(json_data)
                            df.columns = [str(c).strip().capitalize() for c in df.columns]
                            ohlcv_cols = ('High', 'Low', 'Close', 'Volume')
                            if all(c in df.columns for c in ohlcv_cols):
                                for c in ohlcv_cols:
                                    df[c] = pd.to_numeric(df[c], errors='coerce')
                                historical_data = df.dropna(subset=list(ohlcv_cols)).reset_index(drop=True)
                                data_source = 'stdin'
                    except json.JSONDecodeError:
                        pass
            except Exception as e:
                logger.debug(f"No stdin data: {e}")
        
        # Make prediction
        result = predict(args.symbol, args.period, model, historical_data,
                         data_source=data_source, allow_synthetic=args.synthetic)
        
        # Output JSON to stdout
        print(json.dumps(result), file=sys.stdout)
        
        return 0 if 'error' not in result else 1
    
    except Exception as e:
        result = {"error": f"Inference failed: {str(e)}"}
        print(json.dumps(result), file=sys.stdout)
        return 1


if __name__ == '__main__':
    sys.exit(main())
