#!/bin/bash
# ============================================================================
# Example: Using ML-Integrated Scoring Pipeline
# ============================================================================
# This example demonstrates how to use the new calculate_confluence_score_v2()
# function to generate trading signals with ML predictions.
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
LIB_DIR="${PROJECT_ROOT}/lib"

# Source all required modules
source "${LIB_DIR}/scoring.sh"
source "${LIB_DIR}/indicators.sh" 2>/dev/null || true
source "${LIB_DIR}/regime_detector.sh" 2>/dev/null || true

echo "=============================================="
echo "ML Scoring Integration Example"
echo "=============================================="
echo ""

# ============================================================================
# Example 1: Simple Scoring with Defaults
# ============================================================================

echo "--- Example 1: Simple Scoring (Most Common) ---"
echo ""
echo "Scenario: You have technical indicator scores and want a recommendation."
echo ""

SYMBOL="AAPL"
RSI_SCORE=65
MACD_SCORE=60
BB_SCORE=70
OBV_SCORE=55
REGIME="sideways"

echo "Input:"
echo "  Symbol: $SYMBOL"
echo "  RSI Score: $RSI_SCORE"
echo "  MACD Score: $MACD_SCORE"
echo "  Bollinger Bands Score: $BB_SCORE"
echo "  OBV Score: $OBV_SCORE"
echo "  Market Regime: $REGIME"
echo ""

result=$(calculate_confluence_score_v2 "$SYMBOL" \
    "$RSI_SCORE" "$MACD_SCORE" "$BB_SCORE" "$OBV_SCORE" \
    "$REGIME")

echo "Output:"
echo "$result" | jq '.'
echo ""

# Extract key fields
recommendation=$(echo "$result" | jq -r '.recommendation')
confluence=$(echo "$result" | jq -r '.confluence_score')
signal_strength=$(echo "$result" | jq -r '.signal_strength')

echo "Interpretation:"
echo "  Recommendation: $recommendation"
echo "  Confidence Score: $confluence/100"
echo "  Signal Strength: $signal_strength/4 components aligned"
echo ""

# ============================================================================
# Example 2: Full Scoring with Strategy Scores and Kalman Trend
# ============================================================================

echo "--- Example 2: Full Scoring with All Components ---"
echo ""
echo "Scenario: You have all scores available (indicators, strategies, Kalman)."
echo ""

SYMBOL="MSFT"
RSI_SCORE=72
MACD_SCORE=75
BB_SCORE=68
OBV_SCORE=70
REGIME="trending_bull"
MR_SCORE=45        # Mean Reversion score (lower in uptrend)
TF_SCORE=85        # Trend Following score (higher in uptrend)
KALMAN_TREND=1     # Kalman filter confirms uptrend (+1)

echo "Input:"
echo "  Symbol: $SYMBOL"
echo "  RSI Score: $RSI_SCORE (overbought zone)"
echo "  MACD Score: $MACD_SCORE (strong bullish)"
echo "  Bollinger Bands Score: $BB_SCORE (upper band)"
echo "  OBV Score: $OBV_SCORE (rising volume)"
echo "  Market Regime: $REGIME"
echo "  Mean Reversion Score: $MR_SCORE"
echo "  Trend Following Score: $TF_SCORE"
echo "  Kalman Trend: $KALMAN_TREND (confirmed uptrend)"
echo ""

result=$(calculate_confluence_score_v2 "$SYMBOL" \
    "$RSI_SCORE" "$MACD_SCORE" "$BB_SCORE" "$OBV_SCORE" \
    "$REGIME" "$MR_SCORE" "$TF_SCORE" "$KALMAN_TREND")

echo "Output:"
echo "$result" | jq '.'
echo ""

# Analyze components
ml_conf=$(echo "$result" | jq -r '.components.ml_confidence.score')
regime_conf=$(echo "$result" | jq -r '.components.regime_score.score')
tech_conf=$(echo "$result" | jq -r '.components.technical_score.score')
volume_conf=$(echo "$result" | jq -r '.components.volume_trend_score.score')

echo "Component Breakdown:"
echo "  ML Confidence (15%): $ml_conf/100"
echo "  Regime Score (35%): $regime_conf/100 - Trending regime favors TF"
echo "  Technical Score (30%): $tech_conf/100"
echo "  Volume/Trend (20%): $volume_conf/100 - Kalman confirms trend"
echo ""

# ============================================================================
# Example 3: Weak Signal Detection
# ============================================================================

echo "--- Example 3: Weak/Mixed Signal Detection ---"
echo ""
echo "Scenario: Mixed signals where we should be cautious."
echo ""

SYMBOL="GOOGL"
RSI_SCORE=55
MACD_SCORE=45
BB_SCORE=52
OBV_SCORE=48
REGIME="sideways"

echo "Input:"
echo "  Symbol: $SYMBOL"
echo "  RSI Score: $RSI_SCORE (neutral)"
echo "  MACD Score: $MACD_SCORE (bearish)"
echo "  Bollinger Bands Score: $BB_SCORE (middle band)"
echo "  OBV Score: $OBV_SCORE (flat)"
echo "  Market Regime: $REGIME"
echo ""

result=$(calculate_confluence_score_v2 "$SYMBOL" \
    "$RSI_SCORE" "$MACD_SCORE" "$BB_SCORE" "$OBV_SCORE" \
    "$REGIME")

echo "Output:"
echo "$result" | jq '.'
echo ""

recommendation=$(echo "$result" | jq -r '.recommendation')
confidence_note=$(echo "$result" | jq -r '.metadata.confidence_note')
signal_strength=$(echo "$result" | jq -r '.signal_strength')

echo "Interpretation:"
echo "  Recommendation: $recommendation"
echo "  Signal Strength: $signal_strength/4 (weak agreement)"
echo "  Note: $confidence_note"
echo "  ACTION: Wait for clearer direction or smaller position size"
echo ""

# ============================================================================
# Example 4: Monitoring Signal Quality Over Time
# ============================================================================

echo "--- Example 4: Tracking Signal Quality Over Multiple Checks ---"
echo ""
echo "Scenario: Monitoring how a signal evolves as price changes."
echo ""

SYMBOL="TSLA"

echo "Time Series Analysis for $SYMBOL:"
echo ""

# Simulate different market states at different times
declare -a times=("10:30 AM" "11:00 AM" "11:30 AM" "12:00 PM")
declare -a rsi_values=(58 62 68 72)
declare -a macd_values=(48 55 62 68)
declare -a bb_values=(50 58 65 70)
declare -a obv_values=(45 50 58 65)

for i in "${!times[@]}"; do
    time="${times[$i]}"
    rsi="${rsi_values[$i]}"
    macd="${macd_values[$i]}"
    bb="${bb_values[$i]}"
    obv="${obv_values[$i]}"
    
    result=$(calculate_confluence_score_v2 "$SYMBOL" \
        "$rsi" "$macd" "$bb" "$obv" "sideways")
    
    confidence=$(echo "$result" | jq -r '.confluence_score')
    recommendation=$(echo "$result" | jq -r '.recommendation')
    signal=$(echo "$result" | jq -r '.signal_strength')
    
    printf "  %8s | Score: %3d | Rec: %-12s | Signals: %d\n" \
        "$time" "$confidence" "$recommendation" "$signal"
done

echo ""
echo "Observation: Signal strengthens from HOLD → BUY as bullish indicators align"
echo ""

# ============================================================================
# Example 5: Using Scores in Trading Logic
# ============================================================================

echo "--- Example 5: Integration with Trading Logic ---"
echo ""
echo "Scenario: Real trading decision based on confidence and regime."
echo ""

SYMBOL="NVDA"
RSI_SCORE=70
MACD_SCORE=72
BB_SCORE=75
OBV_SCORE=68
REGIME="trending_bull"
MR_SCORE=40
TF_SCORE=88
KALMAN_TREND=1

result=$(calculate_confluence_score_v2 "$SYMBOL" \
    "$RSI_SCORE" "$MACD_SCORE" "$BB_SCORE" "$OBV_SCORE" \
    "$REGIME" "$MR_SCORE" "$TF_SCORE" "$KALMAN_TREND")

recommendation=$(echo "$result" | jq -r '.recommendation')
confidence=$(echo "$result" | jq -r '.confluence_score')
signal_strength=$(echo "$result" | jq -r '.signal_strength')

echo "Output: $recommendation (Score: $confidence, Signals: $signal_strength/4)"
echo ""

# Decision logic
echo "Trading Decision Logic:"
if [[ "$recommendation" == "STRONG_BUY" && "$signal_strength" -ge 3 ]]; then
    echo "  ✓ Signal: STRONG_BUY with 3+ confirmations"
    echo "  Action: ENTER LONG - Full position size (2-3% risk)"
    echo "  Entry: Market price"
    echo "  Stop Loss: ATR × 2"
    echo "  Take Profit: 2:1 risk-reward ratio"
elif [[ "$recommendation" == "BUY" ]]; then
    echo "  ✓ Signal: BUY with moderate confirmation"
    echo "  Action: ENTER LONG - Reduced position size (1-2% risk)"
    echo "  Entry: Limit order on support"
    echo "  Stop Loss: ATR × 2.5"
    echo "  Take Profit: 1.5:1 risk-reward ratio"
elif [[ "$recommendation" == "HOLD" ]]; then
    echo "  ⊗ Signal: HOLD with mixed signals"
    echo "  Action: STAND ASIDE - Await confirmation or smaller setup"
    echo "  Note: Wait for 3+ signals aligned for high-confidence entry"
elif [[ "$recommendation" == "SELL" ]]; then
    echo "  ✗ Signal: SELL with bearish confirmation"
    echo "  Action: EXIT LONGS - Close positions"
    echo "  Exit: Market price or limit above support"
elif [[ "$recommendation" == "STRONG_SELL" && "$signal_strength" -ge 3 ]]; then
    echo "  ✗✗ Signal: STRONG_SELL with 3+ confirmations"
    echo "  Action: EXIT LONGS IMMEDIATELY - Avoid reversal"
    echo "  Exit: Market price (priority = speed)"
fi

echo ""

# ============================================================================
# Example 6: Batch Scoring Multiple Symbols
# ============================================================================

echo "--- Example 6: Batch Scoring Portfolio ---"
echo ""
echo "Scenario: Score multiple symbols for portfolio management."
echo ""

declare -A portfolio=(
    ["AAPL"]="65:60:70:55:sideways"
    ["MSFT"]="72:75:68:70:trending_bull"
    ["GOOGL"]="55:45:52:48:sideways"
    ["TSLA"]="70:72:75:68:trending_bull"
    ["AMZN"]="35:30:38:32:trending_bear"
)

echo "Portfolio Analysis:"
echo "────────────────────────────────────────────────────────────────"

for symbol in "${!portfolio[@]}"; do
    IFS=':' read -r rsi macd bb obv regime <<< "${portfolio[$symbol]}"
    
    result=$(calculate_confluence_score_v2 "$symbol" \
        "$rsi" "$macd" "$bb" "$obv" "$regime")
    
    confidence=$(echo "$result" | jq -r '.confluence_score')
    recommendation=$(echo "$result" | jq -r '.recommendation')
    
    # Format recommendation for display
    if [[ "$recommendation" =~ "STRONG" ]]; then
        rec_display="[$recommendation]"
    else
        rec_display="  $recommendation  "
    fi
    
    printf "%-6s  Confidence: %3d  Recommendation: %s\n" \
        "$symbol" "$confidence" "$rec_display"
done

echo "────────────────────────────────────────────────────────────────"
echo ""

# ============================================================================
# Summary
# ============================================================================

echo "=============================================="
echo "Summary: ML Scoring Integration"
echo "=============================================="
echo ""
echo "Key Points:"
echo "  1. Calculate_confluence_score_v2() weights 4 components"
echo "  2. ML predictions (15%) provide machine learning signal"
echo "  3. Regime adaptation (35%) adjusts strategy weighting"
echo "  4. Technical scores (30%) confirm with traditional indicators"
echo "  5. Volume/Trend (20%) validates with Kalman filtering"
echo ""
echo "Signal Validation:"
echo "  • STRONG signals require ≥3 component agreement"
echo "  • Signal strength (0-4) indicates consensus level"
echo "  • Mixed signals default to HOLD for safety"
echo ""
echo "Usage:"
echo "  source lib/scoring.sh"
echo "  result=\$(calculate_confluence_score_v2 SYMBOL RSI MACD BB OBV REGIME [MR] [TF] [KALMAN])"
echo "  recommendation=\$(echo \"\$result\" | jq -r '.recommendation')"
echo ""
echo "For more information:"
echo "  See: .agents/tasks/scoring-integration-report.md"
echo "=============================================="
