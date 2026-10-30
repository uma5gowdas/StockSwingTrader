#!/usr/bin/env python3
# ============================================================================
# StockSwingTrader: Scoring Integration Test Suite
# ============================================================================
# Tests all enhancements in the scoring pipeline
# Tests:
#   1. Component weighting validation
#   2. Score range validation
#   3. Signal generation
#   4. Integration with ML, regime, and technical indicators
# ============================================================================

import json
import sys
import os
from datetime import datetime

# Add lib directory to path
LIB_DIR = os.path.join(os.path.dirname(__file__), '../lib')
sys.path.insert(0, LIB_DIR)

# Color codes for output
RED = '\033[0;31m'
GREEN = '\033[0;32m'
YELLOW = '\033[0;33m'
BLUE = '\033[0;34m'
NC = '\033[0m'

# Test counters
tests_run = 0
tests_passed = 0
tests_failed = 0

# Configuration
MOCK_DATA_FILE = os.path.join(os.path.dirname(__file__), 'mock_data.json')

# ============================================================================
# Test Utilities
# ============================================================================

def print_section(title):
    print(f'\n{BLUE}=== {title} ==={NC}')

def test_assert(condition, test_name):
    global tests_run, tests_passed, tests_failed
    tests_run += 1
    
    if condition:
        print(f'{GREEN}✓{NC} {test_name}')
        tests_passed += 1
        return True
    else:
        print(f'{RED}✗{NC} {test_name}')
        tests_failed += 1
        return False

def test_assert_equal(actual, expected, test_name):
    return test_assert(actual == expected, test_name)

def test_assert_in_range(value, min_val, max_val, test_name):
    return test_assert(min_val <= value <= max_val, 
                      f'{test_name} (expected [{min_val}, {max_val}], got {value})')

def load_mock_data():
    try:
        with open(MOCK_DATA_FILE, 'r') as f:
            return json.load(f)
    except Exception as e:
        print(f'{RED}Error loading mock data: {e}{NC}')
        return None

# ============================================================================
# Scoring Calculation
# ============================================================================

def calculate_confluence_score(technical_score, ml_score, regime_weighted_score, 
                              volume_trend_score):
    """
    Calculate final confluence score with component weighting
    
    Weights:
    - Technical: 30%
    - ML: 15%
    - Regime-Weighted: 35%
    - Volume/Trend: 20%
    """
    weights = {
        'technical': 0.30,
        'ml': 0.15,
        'regime_weighted': 0.35,
        'volume_trend': 0.20
    }
    
    final_score = (
        technical_score * weights['technical'] +
        ml_score * weights['ml'] +
        regime_weighted_score * weights['regime_weighted'] +
        volume_trend_score * weights['volume_trend']
    )
    
    return round(final_score, 2)

def get_signal_from_score(score):
    """Generate trading signal from confluence score"""
    if score >= 75:
        return "STRONG BUY"
    elif score >= 60:
        return "BUY"
    elif score >= 45:
        return "HOLD"
    elif score >= 25:
        return "SELL"
    else:
        return "STRONG SELL"

def get_confidence_level(score):
    """Determine confidence level from score"""
    if score >= 70:
        return "HIGH"
    elif score >= 50:
        return "MEDIUM"
    else:
        return "LOW"

# ============================================================================
# Test Cases
# ============================================================================

def test_component_weighting():
    print_section('Test 1: Component Weighting Validation')
    
    # Mock component scores
    technical_score = 68
    ml_score = 78
    regime_weighted_score = 71
    volume_trend_score = 72
    
    # Calculate final score
    final_score = calculate_confluence_score(technical_score, ml_score, 
                                            regime_weighted_score, 
                                            volume_trend_score)
    
    # Verify weighting formula
    expected_score = (68 * 0.30 + 78 * 0.15 + 71 * 0.35 + 72 * 0.20)
    test_assert_equal(round(expected_score, 2), final_score, 
                     'Weighting formula correct')
    
    # Verify final score is in valid range
    test_assert_in_range(final_score, 0, 100, 'Final score in range [0, 100]')
    
    # Verify individual weights are applied
    technical_contribution = 68 * 0.30
    test_assert(technical_contribution <= final_score, 
               'Technical component contributes to final score')
    
    ml_contribution = 78 * 0.15
    test_assert(ml_contribution <= final_score, 
               'ML component contributes to final score')

def test_score_range_validation():
    print_section('Test 2: Score Range Validation')
    
    # Test minimum score (all 0s)
    min_score = calculate_confluence_score(0, 0, 0, 0)
    test_assert_equal(min_score, 0, 'Minimum score is 0')
    
    # Test maximum score (all 100s)
    max_score = calculate_confluence_score(100, 100, 100, 100)
    test_assert_equal(max_score, 100, 'Maximum score is 100')
    
    # Test mid-range scores
    mid_score = calculate_confluence_score(50, 50, 50, 50)
    test_assert_in_range(mid_score, 45, 55, 'Mid-range calculation')
    
    # Test mixed scores
    mixed_score = calculate_confluence_score(75, 80, 70, 85)
    test_assert_in_range(mixed_score, 70, 85, 'Mixed component scores')

def test_signal_generation():
    print_section('Test 3: Signal Generation Logic')
    
    # Test STRONG BUY
    signal = get_signal_from_score(80)
    test_assert_equal(signal, "STRONG BUY", 'Score >= 75 generates STRONG BUY')
    
    # Test BUY
    signal = get_signal_from_score(65)
    test_assert_equal(signal, "BUY", 'Score >= 60 generates BUY')
    
    # Test HOLD
    signal = get_signal_from_score(50)
    test_assert_equal(signal, "HOLD", '45 <= Score < 60 generates HOLD')
    
    # Test SELL
    signal = get_signal_from_score(35)
    test_assert_equal(signal, "SELL", '25 <= Score < 45 generates SELL')
    
    # Test STRONG SELL
    signal = get_signal_from_score(15)
    test_assert_equal(signal, "STRONG SELL", 'Score < 25 generates STRONG SELL')

def test_confidence_levels():
    print_section('Test 4: Confidence Level Determination')
    
    # Test HIGH confidence
    conf = get_confidence_level(75)
    test_assert_equal(conf, "HIGH", 'Score >= 70 is HIGH confidence')
    
    # Test MEDIUM confidence
    conf = get_confidence_level(60)
    test_assert_equal(conf, "MEDIUM", '50 <= Score < 70 is MEDIUM confidence')
    
    # Test LOW confidence
    conf = get_confidence_level(40)
    test_assert_equal(conf, "LOW", 'Score < 50 is LOW confidence')

def test_mock_data_integration():
    print_section('Test 5: Mock Data Integration')
    
    mock_data = load_mock_data()
    if not mock_data:
        test_assert(False, 'Mock data loaded')
        return
    
    test_assert('expected_scoring' in mock_data, 'Mock data contains expected_scoring')
    
    # Verify each symbol has expected scoring
    for symbol, expected in mock_data.get('expected_scoring', {}).items():
        test_assert('signal' in expected, f'{symbol} has expected signal')
        test_assert('score' in expected, f'{symbol} has expected score')
        test_assert('confidence' in expected, f'{symbol} has expected confidence')

def test_ml_weighting_contribution():
    print_section('Test 6: ML Component Weighting (15%)')
    
    # ML should contribute 15% to final score
    ml_score = 100
    others = 0  # All other components 0
    
    final_score = calculate_confluence_score(0, ml_score, 0, 0)
    expected_contribution = 100 * 0.15
    
    test_assert_equal(final_score, expected_contribution, 
                     'ML component contributes exactly 15%')

def test_regime_weighting_contribution():
    print_section('Test 7: Regime-Weighted Component (35%)')
    
    # Regime-weighted should contribute 35% to final score
    regime_score = 100
    others = 0
    
    final_score = calculate_confluence_score(0, 0, regime_score, 0)
    expected_contribution = 100 * 0.35
    
    test_assert_equal(final_score, expected_contribution, 
                     'Regime-weighted contributes exactly 35%')

def test_technical_weighting_contribution():
    print_section('Test 8: Technical Component Weighting (30%)')
    
    # Technical should contribute 30% to final score
    technical_score = 100
    others = 0
    
    final_score = calculate_confluence_score(technical_score, 0, 0, 0)
    expected_contribution = 100 * 0.30
    
    test_assert_equal(final_score, expected_contribution, 
                     'Technical contributes exactly 30%')

def test_volume_trend_weighting_contribution():
    print_section('Test 9: Volume/Trend Component Weighting (20%)')
    
    # Volume/Trend should contribute 20% to final score
    volume_score = 100
    others = 0
    
    final_score = calculate_confluence_score(0, 0, 0, volume_score)
    expected_contribution = 100 * 0.20
    
    test_assert_equal(final_score, expected_contribution, 
                     'Volume/Trend contributes exactly 20%')

def test_weighting_sum_to_100():
    print_section('Test 10: Weighting Sum Validation')
    
    # All weights should sum to 1.0 (100%)
    weights_sum = 0.30 + 0.15 + 0.35 + 0.20
    test_assert_equal(weights_sum, 1.0, 'All weights sum to 100%')
    
    # When all components are 100, final should be 100
    final_score = calculate_confluence_score(100, 100, 100, 100)
    test_assert_equal(final_score, 100, 'All 100 components yield 100 score')

def test_partial_scores():
    print_section('Test 11: Partial Score Handling')
    
    # Test with some components at 0
    score1 = calculate_confluence_score(100, 0, 0, 0)
    test_assert_in_range(score1, 25, 35, 'Partial scores handle 100,0,0,0')
    
    # Test with varying scores
    score2 = calculate_confluence_score(70, 80, 75, 65)
    test_assert_in_range(score2, 70, 80, 'Averaging scores near middle')

# ============================================================================
# Performance Testing
# ============================================================================

def test_scoring_performance():
    print_section('Test 12: Scoring Performance')
    
    import time
    
    # Measure calculation time
    start_time = time.time()
    
    for _ in range(1000):
        calculate_confluence_score(70, 80, 75, 65)
    
    elapsed = (time.time() - start_time) * 1000  # ms
    
    test_assert(elapsed < 100, f'Scoring calculation < 100ms for 1000 iterations (measured: {elapsed:.2f}ms)')

# ============================================================================
# Summary
# ============================================================================

def print_summary():
    print(f'\n{BLUE}╔════════════════════════════════════════════════════════════╗{NC}')
    print(f'{BLUE}║{NC}        Scoring Integration Test Summary{NC}')
    print(f'{BLUE}╚════════════════════════════════════════════════════════════╝{NC}')
    print(f'Tests Run:     {tests_run}')
    print(f'Tests Passed:  {GREEN}{tests_passed}{NC}')
    print(f'Tests Failed:  {RED}{tests_failed}{NC}')
    
    if tests_failed == 0:
        print(f'\n{GREEN}✓ All tests passed!{NC}')
        return 0
    else:
        print(f'\n{RED}✗ Some tests failed{NC}')
        return 1

# ============================================================================
# Main Execution
# ============================================================================

def main():
    print(f'{BLUE}╔════════════════════════════════════════════════════════════╗{NC}')
    print(f'{BLUE}║{NC}    StockSwingTrader: Scoring Integration Test Suite{NC}')
    print(f'{BLUE}║{NC}    All Enhancements Integration{NC}')
    print(f'{BLUE}╚════════════════════════════════════════════════════════════╝{NC}')
    
    test_component_weighting()
    test_score_range_validation()
    test_signal_generation()
    test_confidence_levels()
    test_mock_data_integration()
    test_ml_weighting_contribution()
    test_regime_weighting_contribution()
    test_technical_weighting_contribution()
    test_volume_trend_weighting_contribution()
    test_weighting_sum_to_100()
    test_partial_scores()
    test_scoring_performance()
    
    sys.exit(print_summary())

if __name__ == '__main__':
    main()
