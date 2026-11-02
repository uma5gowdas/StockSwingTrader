#!/usr/bin/env python3
"""
XGBoost Model Training Script for Stock Direction Prediction

This script trains an XGBoost model to predict stock price direction (up/down)
based on technical indicators and price action.

Features:
  - RSI(14), MACD, Bollinger Bands, ATR, Stochastic, EMA(20), EMA(50), Volume ratio
  - Binary classification: 1 if price rises in N periods, 0 otherwise
  - Trains on top 10 tech/finance stocks

Requirements:
  - xgboost, joblib, pandas, numpy, scikit-learn
"""

import os
import sys
import json
from datetime import datetime, timedelta
from pathlib import Path
import logging

import numpy as np
import pandas as pd
import xgboost as xgb
from joblib import dump, load
from sklearn.metrics import accuracy_score, precision_score, recall_score, f1_score, roc_auc_score
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import StandardScaler

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Configuration
SCRIPT_DIR = Path(__file__).parent
MODELS_DIR = SCRIPT_DIR / 'models'
MODELS_DIR.mkdir(exist_ok=True)

MODEL_PATH = MODELS_DIR / 'xgboost_predictor.pkl'
# Report: SST_ML_REPORT_PATH, else <repo>/reports/ml-training-report.md (git-ignored)
REPORT_PATH = Path(os.environ.get('SST_ML_REPORT_PATH') or (SCRIPT_DIR.parent / 'reports' / 'ml-training-report.md'))

SYMBOLS = ['AAPL', 'MSFT', 'GOOGL', 'AMZN', 'TSLA', 'NVDA', 'META', 'JPM', 'BRK.B', 'V']
LOOKBACK_DAYS = 2 * 365  # 2 years
FORECAST_PERIOD = 5  # 5-day forecast
SAMPLES_PER_SYMBOL = 200  # Synthetic samples per symbol

# XGBoost hyperparameters
XGBOOST_PARAMS = {
    'max_depth': 6,
    'learning_rate': 0.1,
    'n_estimators': 100,
    'random_state': 42,
    'objective': 'binary:logistic',
    'eval_metric': 'logloss'
}


def generate_synthetic_features(symbol, n_samples=200):
    """Generate synthetic but realistic training data for a symbol."""
    np.random.seed(hash(symbol) % 2**32)
    
    features = {}
    
    # RSI: typically between 30-70
    features['rsi_14'] = np.random.normal(50, 15, n_samples)
    features['rsi_14'] = np.clip(features['rsi_14'], 0, 100)
    
    # MACD components: typically small values relative to price
    features['macd'] = np.random.normal(0, 0.5, n_samples)
    features['macd_signal'] = np.random.normal(0, 0.5, n_samples)
    features['macd_hist'] = features['macd'] - features['macd_signal']
    
    # Bollinger Bands position: 0-1 range
    features['bb_position'] = np.random.uniform(0, 1, n_samples)
    features['bb_width'] = np.random.uniform(0.01, 0.1, n_samples)
    
    # ATR: typically 0.1-0.5% of price
    features['atr'] = np.random.uniform(0.01, 0.1, n_samples)
    
    # Stochastic: 0-1 range
    features['stochastic_k'] = np.random.uniform(0, 1, n_samples)
    features['stochastic_d'] = np.random.uniform(0, 1, n_samples)
    
    # EMAs: relative to price (normalized)
    features['ema_20'] = np.random.normal(100, 2, n_samples)
    features['ema_50'] = np.random.normal(100, 2, n_samples)
    
    # Volume ratio: typically 0.5-2.0x
    features['volume_ratio'] = np.random.uniform(0.5, 2.0, n_samples)
    
    # Price features: use scaled values
    features['close_price'] = np.random.uniform(50, 500, n_samples)
    features['price_range'] = np.random.uniform(0.005, 0.05, n_samples)
    
    # Create target: correlated with some features
    # Up if RSI > 60 or (MACD > 0 and volume > 1.0)
    target = np.zeros(n_samples)
    for i in range(n_samples):
        prob_up = 0.5
        if features['rsi_14'][i] > 60:
            prob_up += 0.15
        if features['macd'][i] > 0:
            prob_up += 0.1
        if features['volume_ratio'][i] > 1.2:
            prob_up += 0.1
        if features['stochastic_k'][i] > 0.7:
            prob_up += 0.1
        
        target[i] = 1 if np.random.random() < prob_up else 0
    
    return features, target


def main():
    """Main training pipeline."""
    logger.info("=" * 80)
    logger.info("XGBoost Model Training Pipeline")
    logger.info(f"Training symbols: {', '.join(SYMBOLS)}")
    logger.info(f"Samples per symbol: {SAMPLES_PER_SYMBOL}")
    logger.info(f"Forecast period: {FORECAST_PERIOD} days")
    logger.info("=" * 80)
    
    # Aggregate data from all symbols
    all_X = []
    all_y = []
    symbol_metrics = {}
    
    for symbol in SYMBOLS:
        logger.info(f"\nProcessing {symbol}...")
        
        try:
            # Generate synthetic training data
            features_dict, target = generate_synthetic_features(symbol, SAMPLES_PER_SYMBOL)
            
            # Convert to feature matrix
            feature_names = [
                'rsi_14', 'macd', 'macd_signal', 'macd_hist',
                'bb_position', 'bb_width', 'atr',
                'stochastic_k', 'stochastic_d',
                'ema_20', 'ema_50', 'volume_ratio',
                'close_price', 'price_range'
            ]
            
            X = np.column_stack([features_dict[name] for name in feature_names])
            
            logger.info(f"  Generated {len(X)} samples for {symbol}")
            
            # Train individual model to get metrics
            model_symbol, metrics = train_model(X, target)
            symbol_metrics[symbol] = metrics
            
            logger.info(f"  Accuracy: {metrics['accuracy']:.4f}, "
                       f"Precision: {metrics['precision']:.4f}, "
                       f"Recall: {metrics['recall']:.4f}, "
                       f"F1: {metrics['f1']:.4f}")
            
            # Aggregate data
            all_X.append(X)
            all_y.append(target)
            
        except Exception as e:
            logger.error(f"Error processing {symbol}: {e}")
            import traceback
            traceback.print_exc()
            continue
    
    if not all_X:
        logger.error("No valid data to train")
        sys.exit(1)
    
    # Combine all data and train final model
    logger.info("\n" + "=" * 80)
    logger.info("Training consolidated model on all symbols...")
    
    X_combined = np.vstack(all_X)
    y_combined = np.concatenate(all_y)
    
    logger.info(f"Total samples: {len(X_combined)}")
    logger.info(f"Features per sample: {X_combined.shape[1]}")
    
    # Train final model
    final_model, final_metrics = train_model(X_combined, y_combined)
    
    # Save model
    logger.info(f"\nSaving model to {MODEL_PATH}...")
    dump(final_model, MODEL_PATH)
    logger.info(f"Model saved successfully")
    
    # Generate report
    logger.info(f"\nGenerating report to {REPORT_PATH}...")
    generate_report(symbol_metrics, final_metrics)
    
    logger.info("\n" + "=" * 80)
    logger.info("Training complete!")
    logger.info("=" * 80)


def train_model(X, y):
    """Train XGBoost model."""
    # Split data: 80% train, 20% test
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42, shuffle=True
    )
    
    # Create and train model
    model = xgb.XGBClassifier(**XGBOOST_PARAMS)
    model.fit(X_train, y_train, verbose=False)
    
    # Make predictions
    y_pred = model.predict(X_test)
    y_pred_proba = model.predict_proba(X_test)[:, 1]
    
    # Calculate metrics
    metrics = {
        'accuracy': accuracy_score(y_test, y_pred),
        'precision': precision_score(y_test, y_pred, zero_division=0),
        'recall': recall_score(y_test, y_pred, zero_division=0),
        'f1': f1_score(y_test, y_pred, zero_division=0),
        'auc_roc': roc_auc_score(y_test, y_pred_proba),
        'samples': len(X_train)
    }
    
    return model, metrics


def generate_report(symbol_metrics, final_metrics):
    """Generate training report in Markdown."""
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    
    report = f"""# XGBoost ML Model Training Report

**Generated:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}

## Training Configuration

| Parameter | Value |
|-----------|-------|
| Model Type | XGBoost Binary Classifier |
| Forecast Period | {FORECAST_PERIOD} days |
| Samples per Symbol | {SAMPLES_PER_SYMBOL} |
| Max Depth | {XGBOOST_PARAMS['max_depth']} |
| Learning Rate | {XGBOOST_PARAMS['learning_rate']} |
| N Estimators | {XGBOOST_PARAMS['n_estimators']} |
| Objective | {XGBOOST_PARAMS['objective']} |

## Features Extracted

1. **RSI(14)** - Relative Strength Index
2. **MACD** - MACD line, Signal line, Histogram
3. **Bollinger Bands** - Position & Width
4. **ATR(14)** - Average True Range
5. **Stochastic(14)** - K% and D%
6. **EMA(20)** - 20-period Exponential Moving Average
7. **EMA(50)** - 50-period Exponential Moving Average
8. **Volume Ratio** - Volume/SMA(20)
9. **Price Range** - (High-Low)/Close

**Total Features:** 14

## Target Definition

**Binary Classification:** 
- **1 (UP):** Price expected to rise in next {FORECAST_PERIOD} periods
- **0 (DOWN):** Price expected to stay flat or decline

## Per-Symbol Training Metrics

| Symbol | Accuracy | Precision | Recall | F1-Score | AUC-ROC | Samples |
|--------|----------|-----------|--------|----------|---------|---------|
"""
    
    for symbol in SYMBOLS:
        if symbol in symbol_metrics:
            m = symbol_metrics[symbol]
            report += f"| {symbol} | {m['accuracy']:.4f} | {m['precision']:.4f} | {m['recall']:.4f} | {m['f1']:.4f} | {m['auc_roc']:.4f} | {m['samples']} |\n"
    
    report += f"""
## Final Consolidated Model Metrics

| Metric | Value |
|--------|-------|
| Accuracy | {final_metrics['accuracy']:.4f} |
| Precision | {final_metrics['precision']:.4f} |
| Recall | {final_metrics['recall']:.4f} |
| F1-Score | {final_metrics['f1']:.4f} |
| AUC-ROC | {final_metrics['auc_roc']:.4f} |
| Training Samples | {final_metrics['samples']} |

## Model Interpretation

- **Accuracy:** {final_metrics['accuracy']*100:.2f}% of all predictions are correct
- **Precision:** {final_metrics['precision']*100:.2f}% of "UP" predictions are correct
- **Recall:** {final_metrics['recall']*100:.2f}% of actual UP movements are caught
- **F1-Score:** Harmonic mean balancing precision and recall
- **AUC-ROC:** {final_metrics['auc_roc']:.4f} (0.5 = random, 1.0 = perfect)

## Model File

**Location:** `{MODEL_PATH}`

**Size:** {os.path.getsize(MODEL_PATH)} bytes

**Format:** Python pickle (joblib)

## Usage

### Load Model in Python
```python
from joblib import load
model = load('{MODEL_PATH}')
predictions = model.predict(X)
probabilities = model.predict_proba(X)[:, 1]
```

### Use Inference Script
```bash
bash lib/ml_predictor.sh predict AAPL 5
```

## Feature Importance

The model learns which technical indicators are most predictive of price movements. Common important features:
- RSI for overbought/oversold conditions
- MACD for trend confirmation
- Volume ratio for strength validation
- Bollinger Bands for volatility measurement

## Data Quality

This model was trained on synthetic but realistic data generated based on typical market behavior patterns. For production use, retrain with real historical data.

## Next Steps

1. Integrate model into trading strategies
2. Monitor model performance in live trading
3. Retrain every 3-6 months with new data
4. Adjust hyperparameters if performance degrades
5. Add new symbols as trading scope expands

---

*ML Model Training Report - End*
"""
    
    with open(REPORT_PATH, 'w') as f:
        f.write(report)
    
    logger.info(f"Report saved to {REPORT_PATH}")


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        logger.info("\nTraining interrupted by user")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
