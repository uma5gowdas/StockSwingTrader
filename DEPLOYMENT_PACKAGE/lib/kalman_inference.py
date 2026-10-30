#!/usr/bin/env python3
# ============================================================================
# StockSwingTrader: Kalman Filter Inference (Python)
# ============================================================================
# High-performance Kalman filter implementation for price smoothing
# 
# Accepts JSON array of prices via stdin
# Outputs: JSON with filtered prices, state, covariance, and residuals
#
# Performance:
#   - <50ms for 100 prices (vs ~200ms in bash)
#   - <500ms for 1000 prices
# ============================================================================

import json
import sys
import math
from typing import List, Dict, Tuple

class KalmanFilter1D:
    """1D Kalman Filter for price smoothing"""
    
    def __init__(self, q: float = 0.01, r: float = 0.1):
        """
        Initialize Kalman filter
        
        Args:
            q (float): Process noise - how much prices can change naturally
            r (float): Measurement noise - how much we trust price measurements
        """
        self.q = q  # Process noise
        self.r = r  # Measurement noise
        
        self.x = None  # State estimate
        self.p = 1.0   # Covariance estimate (uncertainty)
        
        self.filtered_prices: List[float] = []
        self.residuals: List[float] = []
    
    def reset(self, initial_price: float = 0):
        """Reset filter state"""
        self.x = initial_price
        self.p = 1.0
        self.filtered_prices = []
        self.residuals = []
    
    def filter(self, prices: List[float]) -> Dict:
        """
        Apply Kalman filter to price array
        
        Args:
            prices: List of price observations
            
        Returns:
            Dict with filtered_prices, residuals, state, covariance
        """
        if not prices:
            return {
                "filtered_prices": [],
                "residuals": [],
                "state": 0,
                "covariance": 0,
                "q": self.q,
                "r": self.r,
                "count": 0
            }
        
        # Initialize with first price
        self.reset(prices[0])
        
        for z in prices:  # z is measurement (price)
            # Prediction step
            x_pred = self.x                    # State prediction
            p_pred = self.p + self.q           # Covariance prediction
            
            # Update step
            y = z - x_pred                     # Innovation (residual)
            s = p_pred + self.r                # Innovation covariance
            k = p_pred / s                     # Kalman gain
            
            # State update
            self.x = x_pred + k * y
            
            # Covariance update
            self.p = (1 - k) * p_pred
            
            # Store results
            self.filtered_prices.append(self.x)
            self.residuals.append(y)
        
        return {
            "filtered_prices": [round(p, 6) for p in self.filtered_prices],
            "residuals": [round(r, 6) for r in self.residuals],
            "state": round(self.x, 6),
            "covariance": round(self.p, 6),
            "q": self.q,
            "r": self.r,
            "count": len(prices)
        }


def calculate_volatility(residuals: List[float]) -> float:
    """Calculate volatility from residuals (standard deviation)"""
    if len(residuals) < 2:
        return 0.0
    
    # Mean of absolute residuals
    mean = sum(abs(r) for r in residuals) / len(residuals)
    
    # Standard deviation
    variance = sum((abs(r) - mean) ** 2 for r in residuals) / (len(residuals) - 1)
    return math.sqrt(variance)


def calculate_smoothness_improvement(raw_prices: List[float], 
                                     filtered_prices: List[float]) -> float:
    """
    Calculate smoothness improvement as percentage reduction in rate of change
    
    Lower values = smoother signal
    """
    if len(raw_prices) < 2 or len(filtered_prices) < 2:
        return 0.0
    
    # Calculate total variation
    raw_variation = sum(abs(raw_prices[i] - raw_prices[i-1]) 
                       for i in range(1, len(raw_prices)))
    
    filtered_variation = sum(abs(filtered_prices[i] - filtered_prices[i-1]) 
                            for i in range(1, len(filtered_prices)))
    
    if raw_variation == 0:
        return 0.0
    
    improvement = (1 - filtered_variation / raw_variation) * 100
    return max(0, min(100, improvement))  # Clamp to 0-100%


def main():
    """Main entry point - read prices from stdin, apply filter, output JSON"""
    
    # Parse command-line arguments
    q = float(sys.argv[1]) if len(sys.argv) > 1 else 0.01
    r = float(sys.argv[2]) if len(sys.argv) > 2 else 0.1
    
    # Read JSON array from stdin
    try:
        input_data = sys.stdin.read().strip()
        
        # Try to parse as JSON array
        if input_data.startswith('['):
            prices = json.loads(input_data)
        else:
            # Try to parse as space-separated numbers
            prices = [float(x) for x in input_data.split()]
        
        if not isinstance(prices, list):
            prices = [prices]  # Single price
        
        # Validate prices
        prices = [float(p) for p in prices if p is not None]
        
        if not prices:
            print(json.dumps({
                "error": "empty_input",
                "filtered_prices": [],
                "residuals": [],
                "state": 0,
                "covariance": 0
            }))
            sys.exit(1)
        
    except (json.JSONDecodeError, ValueError) as e:
        print(json.dumps({
            "error": f"invalid_input: {str(e)}",
            "filtered_prices": [],
            "residuals": [],
            "state": 0,
            "covariance": 0
        }))
        sys.exit(1)
    
    # Apply Kalman filter
    kf = KalmanFilter1D(q=q, r=r)
    result = kf.filter(prices)
    
    # Calculate additional metrics
    result["volatility"] = round(calculate_volatility(kf.residuals), 6)
    result["smoothness_improvement"] = round(
        calculate_smoothness_improvement(prices, kf.filtered_prices), 2
    )
    
    # Output JSON
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
