#!/bin/bash
# ============================================================================
# Generate the v2 scoring goldens (run ONCE on the unmodified code, 970af57)
# ============================================================================
# Writes cases.json, ohlcv_60.json and expected/<case>.json next to this
# script. tests/test_scoring_agents.sh re-runs every case with run_case.sh
# and compares (jq -S) against expected/, which proves the agent layer leaves
# calculate_confluence_score_v2 and analyze_stock unchanged when disabled.
#
# Cases:
#   (a) 8 vectors, ML absent (`unset -f ml_predict_direction`, ML neutral 50):
#       every regime, kalman -1/0/1, bullish/bearish/mixed scores
#   (b) 3 of them with a 10th sentiment arg (70, na, 30)
#   (c) 1 with MiroFish on (temp cache BULLISH 0.8 written with the current time)
#   (d) 1 with SST_OFFLINE=1 and the real offline ML predictor
#   (e) analyze_stock AAPL on ohlcv_60.json (60 yfinance_fixture bars)
# Usage: bash tests/fixtures/agents/v2_golden/generate_goldens.sh
# ============================================================================
set -o pipefail
GOLDEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$GOLDEN_DIR/../../../.." && pwd)"
RUN="$GOLDEN_DIR/run_case.sh"

cat > "$GOLDEN_DIR/cases.json" <<'EOF'
[
  {"name": "a1_bull_trending_bull_k1",  "ml": "absent", "args": ["AAPL", "75", "80", "70", "72", "trending_bull", "60", "80", "1"]},
  {"name": "a2_bear_trending_bear_km1", "ml": "absent", "args": ["AAPL", "20", "25", "30", "28", "trending_bear", "30", "20", "-1"]},
  {"name": "a3_mixed_sideways_k0",      "ml": "absent", "args": ["AAPL", "65", "40", "55", "50", "sideways", "70", "45", "0"]},
  {"name": "a4_volatile_k1",            "ml": "absent", "args": ["AAPL", "60", "55", "45", "62", "volatile", "55", "60", "1"]},
  {"name": "a5_unknown_neutral_k0",     "ml": "absent", "args": ["AAPL", "50", "50", "50", "50", "unknown", "50", "50", "0"]},
  {"name": "a6_bull_sideways_k1",       "ml": "absent", "args": ["MSFT", "70", "72", "68", "66", "sideways", "75", "60", "1"]},
  {"name": "a7_mixed_trending_bull_km1","ml": "absent", "args": ["MSFT", "45", "70", "35", "40", "trending_bull", "40", "70", "-1"]},
  {"name": "a8_bear_trending_bear_k1",  "ml": "absent", "args": ["NVDA", "30", "20", "35", "45", "trending_bear", "25", "30", "1"]},
  {"name": "b1_bull_sentiment_70",      "ml": "absent", "args": ["AAPL", "75", "80", "70", "72", "trending_bull", "60", "80", "1", "70"]},
  {"name": "b2_bear_sentiment_na",      "ml": "absent", "args": ["AAPL", "20", "25", "30", "28", "trending_bear", "30", "20", "-1", "na"]},
  {"name": "b3_mixed_sentiment_30",     "ml": "absent", "args": ["AAPL", "65", "40", "55", "50", "sideways", "70", "45", "0", "30"]},
  {"name": "c1_mirofish_bullish_08",    "ml": "absent", "args": ["AAPL", "65", "40", "55", "50", "sideways", "70", "45", "0"],
   "env": {"MIROFISH_WEIGHT": "0.10"}, "mirofish_cache": {"prediction": "BULLISH", "confidence": 0.8}},
  {"name": "d1_offline_ml",             "ml": "offline", "args": ["AAPL", "75", "80", "70", "72", "trending_bull", "60", "80", "1"]}
]
EOF

# 60-bar yfinance_fixture series, produced with the agent's own yfinance snippet
PYTHONPATH="$PROJECT_DIR/tests/stubs/yfinance_fixture" SST_OFFLINE=0 /bin/bash -c '
    source "$1/StockSwingTrader_Agent.sh" >/dev/null 2>&1
    fetch_stock_ohlcv_yfinance AAPL 60' _ "$PROJECT_DIR" | jq -c . > "$GOLDEN_DIR/ohlcv_60.json" || {
    echo "ERROR: could not build ohlcv_60.json" >&2; exit 1; }
[[ "$(jq '.ohlcv | length' "$GOLDEN_DIR/ohlcv_60.json")" == "60" ]] || { echo "ERROR: ohlcv_60.json is not 60 bars" >&2; exit 1; }

rm -rf "$GOLDEN_DIR/expected"
mkdir -p "$GOLDEN_DIR/expected"
n=$(jq length "$GOLDEN_DIR/cases.json")
for ((i = 0; i < n; i++)); do
    c=$(jq -c ".[$i]" "$GOLDEN_DIR/cases.json")
    name=$(printf '%s' "$c" | jq -r .name)
    out=$(bash "$RUN" v2 "$c")
    if [[ -z "$out" ]] || ! printf '%s' "$out" | jq -e '.confluence_score | type == "number"' >/dev/null; then
        echo "ERROR: case $name produced no v2 JSON" >&2; exit 1
    fi
    printf '%s\n' "$out" > "$GOLDEN_DIR/expected/$name.json"
    echo "  $name: $(printf '%s' "$out" | jq -r '"\(.confluence_score) \(.recommendation)"')"
done
out=$(bash "$RUN" analyze)
if [[ -z "$out" ]] || ! printf '%s' "$out" | jq -e '.confluence.final_confidence | type == "number"' >/dev/null; then
    echo "ERROR: analyze_stock golden is empty" >&2; exit 1
fi
printf '%s\n' "$out" > "$GOLDEN_DIR/expected/e1_analyze_stock_AAPL.json"
echo "  e1_analyze_stock_AAPL: $(printf '%s' "$out" | jq -r '"\(.confluence.final_confidence) \(.confluence.signal)"')"
echo "Goldens written to $GOLDEN_DIR/expected ($((n + 1)) files)"
