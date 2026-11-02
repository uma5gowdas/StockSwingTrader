#!/bin/bash
# ============================================================================
# StockSwingTrader v6.1: Backtesting Module
# ============================================================================
# Purpose: Complete backtesting framework for strategy validation
#          Parameter grid search, performance metrics, trade logging
# 
# Usage:
#   backtest_strategy "AAPL" "2022-01-01" "2024-01-01" 80
#   backtest_multi_symbol "AAPL,MSFT,GOOGL" "2022-01-01" "2024-01-01"
#
# Features:
#   - Train/test split (configurable)
#   - Parameter grid search (RSI, Bollinger Bands, stops, targets)
#   - Performance metrics (Sharpe, max drawdown, win rate, profit factor)
#   - Trade journal generation
#   - Realistic slippage & commission simulation
#   - HTML report with Plotly charts
#   - JSON and CSV export
#
# ============================================================================

set -o pipefail

# File-specific dir variable: this file is sourced, so it must not change the
# caller's SCRIPT_DIR.
BACKTEST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BACKTEST_LIB_DIR}/portable.sh"
# Use <repo>/.venv when it exists (PATH only; SST_NO_REPO_VENV=1 disables)
sst_use_repo_venv

# ============================================================================
# Configuration
# ============================================================================

# Default parameters
# Results go to <repo>/output/backtests (git-ignored) unless BACKTEST_OUTPUT_DIR is set
BACKTEST_OUTPUT_DIR="${BACKTEST_OUTPUT_DIR:-$(dirname "$BACKTEST_LIB_DIR")/output/backtests}"
SLIPPAGE_PCT=0.001        # 0.1% slippage
COMMISSION_PCT=0.0001     # 0.01% commission
KELLY_DIVISOR=4           # Conservative Kelly: full / 4

# Parameter grid ranges
RSI_MIN=20
RSI_MAX=80
RSI_STEP=10

BB_STD_MIN=1.5
BB_STD_MAX=3.0
BB_STD_STEP=0.5

STOP_LOSS_MIN=1
STOP_LOSS_MAX=5
STOP_LOSS_STEP=1

PROFIT_TARGET_MIN=2
PROFIT_TARGET_MAX=10
PROFIT_TARGET_STEP=2

# ============================================================================
# Utility Functions
# ============================================================================

log_info() {
    local msg="$1"
    echo "[INFO] $msg"
}

log_error() {
    local msg="$1"
    echo "[ERROR] $msg" >&2
}

log_warn() {
    local msg="$1"
    echo "[WARN] $msg" >&2
}

log_debug() {
    if [[ "$DEBUG_BACKTEST" == "true" ]]; then
        local msg="$1"
        echo "[DEBUG] $msg"
    fi
}

# Calculate Sharpe Ratio
# Args: returns_array_json, rf_rate (risk-free rate, default 0.02)
# Returns: Sharpe ratio
calculate_sharpe_ratio() {
    local returns_json="$1"
    local rf_rate="${2:-0.02}"
    
    python3 << PYTHON
import json
import numpy as np

returns = json.loads('$returns_json')
if len(returns) == 0:
    print("0")
else:
    returns_array = np.array(returns)
    excess_returns = returns_array - ($rf_rate / 252)  # Daily risk-free rate
    if np.std(excess_returns) == 0:
        sharpe = 0
    else:
        sharpe = np.mean(excess_returns) / np.std(excess_returns) * np.sqrt(252)
    print(f"{sharpe:.4f}")
PYTHON
}

# Calculate Maximum Drawdown
# Args: equity_curve_json
# Returns: Max drawdown percentage
calculate_max_drawdown() {
    local equity_json="$1"
    
    python3 << PYTHON
import json
import numpy as np

equity = json.loads('$equity_json')
if len(equity) == 0:
    print("0")
else:
    equity_array = np.array(equity, dtype=float)
    running_max = np.maximum.accumulate(equity_array)
    drawdown = (equity_array - running_max) / running_max
    max_dd = np.min(drawdown)
    print(f"{max_dd*100:.4f}")
PYTHON
}

# Calculate Profit Factor (gross profit / gross loss)
# Args: trades_json (array of {pnl: value})
# Returns: Profit factor
calculate_profit_factor() {
    local trades_json="$1"
    
    python3 << PYTHON
import json

trades = json.loads('$trades_json')
if len(trades) == 0:
    print("0")
else:
    gross_profit = sum(max(0, t['pnl']) for t in trades)
    gross_loss = abs(sum(min(0, t['pnl']) for t in trades))
    
    if gross_loss == 0:
        pf = 0 if gross_profit == 0 else 999.99
    else:
        pf = gross_profit / gross_loss if gross_loss > 0 else 0
    
    print(f"{pf:.4f}")
PYTHON
}

# Calculate Payoff Ratio (avg win / avg loss)
# Args: trades_json (array of {pnl: value})
# Returns: Payoff ratio
calculate_payoff_ratio() {
    local trades_json="$1"
    
    python3 << PYTHON
import json

trades = json.loads('$trades_json')
if len(trades) == 0:
    print("0")
else:
    wins = [t['pnl'] for t in trades if t['pnl'] > 0]
    losses = [t['pnl'] for t in trades if t['pnl'] < 0]
    
    if len(losses) == 0:
        pr = 0 if len(wins) == 0 else 999.99
    else:
        avg_win = sum(wins) / len(wins) if len(wins) > 0 else 0
        avg_loss = abs(sum(losses) / len(losses))
        pr = avg_win / avg_loss if avg_loss > 0 else 0
    
    print(f"{pr:.4f}")
PYTHON
}

# ============================================================================
# Backtest Engine Integration
# ============================================================================

# Execute Python backtest engine with configuration
# Args: config_json_file
# Returns: Results file path
run_backtest_engine() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        return 1
    fi
    
    # Call Python backtest engine
    python3 "$BACKTEST_LIB_DIR/backtest_engine.py" "$config_file"
}

# ============================================================================
# Strategy Backtesting
# ============================================================================

# Main backtest function
# Args: symbol, start_date, end_date, train_pct (default 80)
# Runs parameter grid search and generates reports
backtest_strategy() {
    local symbol="$1"
    local start_date="$2"
    local end_date="$3"
    local train_pct="${4:-80}"
    
    if [[ -z "$symbol" ]] || [[ -z "$start_date" ]] || [[ -z "$end_date" ]]; then
        log_error "Usage: backtest_strategy SYMBOL START_DATE END_DATE [TRAIN_PCT]"
        return 1
    fi
    
    log_info "Starting backtest for $symbol ($start_date to $end_date)"
    log_info "Train/Test split: $train_pct% / $((100-train_pct))%"
    
    # Create output directory
    mkdir -p "$BACKTEST_OUTPUT_DIR"
    
    # Generate timestamp
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local results_file="$BACKTEST_OUTPUT_DIR/backtest_${symbol}_${timestamp}.json"
    
    # Create backtest configuration
    local config_file
    config_file=$(mktemp "${TMPDIR:-/tmp}/sst_backtest_cfg.XXXXXX") || return 1
    
    cat > "$config_file" << EOF
{
  "symbol": "$symbol",
  "start_date": "$start_date",
  "end_date": "$end_date",
  "train_pct": $train_pct,
  "slippage_pct": $SLIPPAGE_PCT,
  "commission_pct": $COMMISSION_PCT,
  "parameter_grid": {
    "rsi_thresholds": {
      "min": $RSI_MIN,
      "max": $RSI_MAX,
      "step": $RSI_STEP
    },
    "bollinger_std": {
      "min": $BB_STD_MIN,
      "max": $BB_STD_MAX,
      "step": $BB_STD_STEP
    },
    "stop_loss_pct": {
      "min": $STOP_LOSS_MIN,
      "max": $STOP_LOSS_MAX,
      "step": $STOP_LOSS_STEP
    },
    "profit_target_pct": {
      "min": $PROFIT_TARGET_MIN,
      "max": $PROFIT_TARGET_MAX,
      "step": $PROFIT_TARGET_STEP
    }
  },
  "strategies": ["mean_reversion", "trend_follow"],
  "output_file": "$results_file"
}
EOF
    
    log_debug "Config: $config_file"
    
    # Run backtest engine. Its stdout is an error JSON when there is no real
    # market data (exit 2); keep it off our stdout, which is the results path.
    local engine_out
    engine_out=$(run_backtest_engine "$config_file")
    local engine_exit=$?
    if [[ $engine_exit -ne 0 ]]; then
        local reason
        reason=$(echo "$engine_out" | jq -r '.reason // empty' 2>/dev/null)
        log_error "Backtest failed for $symbol (engine exit $engine_exit)${reason:+: $reason}"
        [[ -n "$engine_out" ]] && echo "$engine_out" >&2
        rm -f "$config_file" "$results_file"
        return 1
    fi
    
    # Verify results file was created
    if [[ ! -f "$results_file" ]]; then
        log_error "Results file not created: $results_file"
        rm -f "$config_file"
        return 1
    fi
    
    log_info "Backtest complete: $results_file"
    
    # Clean up config
    rm -f "$config_file"
    
    # Generate reports (suppress report output)
    generate_backtest_reports "$results_file" > /dev/null 2>&1
    
    echo "$results_file"
}

# Backtest multiple symbols
# Args: symbol_list (comma-separated), start_date, end_date, train_pct
backtest_multi_symbol() {
    local symbol_list="$1"
    local start_date="$2"
    local end_date="$3"
    local train_pct="${4:-80}"
    
    if [[ -z "$symbol_list" ]] || [[ -z "$start_date" ]] || [[ -z "$end_date" ]]; then
        log_error "Usage: backtest_multi_symbol SYMBOLS START_DATE END_DATE [TRAIN_PCT]"
        return 1
    fi
    
    local IFS=','
    local results_files=()
    local failed=0
    
    for symbol in $symbol_list; do
        symbol=$(echo "$symbol" | xargs)  # trim whitespace
        local result
        if result=$(backtest_strategy "$symbol" "$start_date" "$end_date" "$train_pct") && [[ -n "$result" ]]; then
            # stdout also carries [INFO] lines; the results path is the last line
            results_files+=("$(echo "$result" | tail -1)")
        else
            failed=$((failed + 1))
        fi
    done
    
    log_info "Portfolio backtest complete: ${#results_files[@]} symbols processed, $failed failed"
    
    # Generate portfolio summary
    if [[ ${#results_files[@]} -gt 0 ]]; then
        log_debug "Portfolio summary input files: ${results_files[@]}"
        generate_portfolio_summary "${results_files[@]}"
    else
        log_error "No backtest results (no market data?); nothing to summarize"
        return 1
    fi
    # Any failed symbol (e.g. no market data) makes the run fail
    [[ $failed -eq 0 ]]
}

# ============================================================================
# Report Generation
# ============================================================================

# Generate HTML report from backtest results
# Args: results_json_file
generate_backtest_reports() {
    local results_file="$1"
    
    if [[ ! -f "$results_file" ]]; then
        log_error "Results file not found: $results_file"
        return 1
    fi
    
    local base_name=$(basename "$results_file" .json)
    local html_file="${results_file%.*}.html"
    local csv_file="${results_file%.*}.csv"
    
    # Create Python script for report generation
    local temp_script
    temp_script=$(mktemp "${TMPDIR:-/tmp}/sst_gen_backtest_reports.XXXXXX") || return 1
    
    cat > "$temp_script" << 'PYSCRIPT'
#!/usr/bin/env python3
import json
import sys
import csv
import html as html_lib
from pathlib import Path

results_file = sys.argv[1]
html_file = sys.argv[2]
csv_file = sys.argv[3]

try:
    with open(results_file, 'r') as f:
        results = json.load(f)
    
    data_source = html_lib.escape(str(results.get('data_source') or 'unknown'))
    if data_source == 'synthetic':
        source_banner = ('<div class="data-warning" role="alert"><strong>SYNTHETIC DATA:</strong> '
                         'this backtest ran on generated prices (demo/test mode), not market data. '
                         'The metrics below say nothing about real performance.</div>')
    elif data_source == 'unknown':
        source_banner = ('<div class="data-warning" role="alert"><strong>Unknown data source:</strong> '
                         'this result does not record where its prices came from.</div>')
    else:
        source_banner = ''
    
    # Generate HTML report
    html = f'''<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Backtest Report</title>
    <script src="https://cdn.plot.ly/plotly-latest.min.js"></script>
    <style>
        body {{ font-family: Arial, sans-serif; margin: 20px; background: #f5f5f5; }}
        .container {{ max-width: 1200px; margin: 0 auto; background: white; padding: 20px; border-radius: 8px; }}
        h1 {{ color: #333; border-bottom: 2px solid #007bff; padding-bottom: 10px; }}
        .metrics {{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 15px; margin: 20px 0; }}
        .metric {{ padding: 15px; background: #f9f9f9; border-left: 4px solid #007bff; border-radius: 4px; }}
        .metric-value {{ font-size: 24px; font-weight: bold; color: #007bff; }}
        .metric-label {{ font-size: 12px; color: #666; margin-top: 5px; }}
        .positive {{ color: green; }}
        .negative {{ color: red; }}
        table {{ width: 100%; border-collapse: collapse; margin: 20px 0; }}
        th, td {{ padding: 10px; text-align: left; border-bottom: 1px solid #ddd; }}
        th {{ background: #f9f9f9; font-weight: bold; }}
        .data-warning {{ background: #fff3cd; border: 2px solid #b45309; color: #78350f; padding: 12px; border-radius: 4px; margin: 15px 0; }}
    </style>
</head>
<body>
    <div class="container">
        <h1>Backtest Report: {results.get('symbol', 'UNKNOWN')}</h1>
        {source_banner}
        <p>Data source: <strong>{data_source}</strong></p>
        
        <div class="metrics">
            <div class="metric">
                <div class="metric-label">Total P&L</div>
                <div class="metric-value {("positive" if results.get("total_pnl", 0) >= 0 else "negative")}">
                    ${results.get("total_pnl", 0):.2f}
                </div>
            </div>
            <div class="metric">
                <div class="metric-label">Win Rate</div>
                <div class="metric-value">{results.get("win_rate", 0):.2f}%</div>
            </div>
            <div class="metric">
                <div class="metric-label">Sharpe Ratio</div>
                <div class="metric-value">{results.get("sharpe_ratio", 0):.2f}</div>
            </div>
            <div class="metric">
                <div class="metric-label">Max Drawdown</div>
                <div class="metric-value negative">{results.get("max_drawdown", 0):.2f}%</div>
            </div>
            <div class="metric">
                <div class="metric-label">Profit Factor</div>
                <div class="metric-value">{results.get("profit_factor", 0):.2f}</div>
            </div>
            <div class="metric">
                <div class="metric-label">Payoff Ratio</div>
                <div class="metric-value">{results.get("payoff_ratio", 0):.2f}</div>
            </div>
            <div class="metric">
                <div class="metric-label">Trades</div>
                <div class="metric-value">{results.get("num_trades", 0)}</div>
            </div>
        </div>
        
        <h2>Performance Summary</h2>
        <table>
            <tr>
                <th>Metric</th>
                <th>Value</th>
            </tr>
            <tr>
                <td>Strategy</td>
                <td>{results.get("strategy", "N/A")}</td>
            </tr>
            <tr>
                <td>Period</td>
                <td>{results.get("period", "N/A")}</td>
            </tr>
            <tr>
                <td>Data Points</td>
                <td>{results.get("data_points", 0)}</td>
            </tr>
            <tr>
                <td>Initial Capital</td>
                <td>${results.get("initial_capital", 0):,.2f}</td>
            </tr>
            <tr>
                <td>Final Capital</td>
                <td>${results.get("final_capital", 0):,.2f}</td>
            </tr>
            <tr>
                <td>Total Return</td>
                <td>{((results.get("final_capital", 0) - results.get("initial_capital", 0)) / results.get("initial_capital", 1) * 100):.2f}%</td>
            </tr>
        </table>
    </div>
</body>
</html>
'''
    
    with open(html_file, 'w') as f:
        f.write(html)
    
    # Export trades to CSV
    if 'trade_journal' in results and results['trade_journal']:
        with open(csv_file, 'w', newline='') as f:
            fieldnames = ['entry_time', 'exit_time', 'entry_price', 'exit_price', 'pnl', 'return_pct', 'reason']
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(results['trade_journal'])
    
    print(f"HTML: {html_file}")
    print(f"CSV: {csv_file}")

except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYSCRIPT
    
    # Run report generator
    python3 "$temp_script" "$results_file" "$html_file" "$csv_file"
    local exit_code=$?
    
    rm -f "$temp_script"
    
    if [[ $exit_code -eq 0 ]]; then
        log_info "Reports generated: $html_file, $csv_file"
    else
        log_error "Failed to generate reports"
    fi
    
    return $exit_code
}

# Generate portfolio summary
# Args: results_file_list
generate_portfolio_summary() {
    local results_files=("$@")
    
    if [[ ${#results_files[@]} -eq 0 ]]; then
        log_error "No results files provided"
        return 1
    fi
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local summary_file="$BACKTEST_OUTPUT_DIR/portfolio_summary_${timestamp}.json"
    
    # Create Python script
    local temp_script
    temp_script=$(mktemp "${TMPDIR:-/tmp}/sst_gen_portfolio_summary.XXXXXX") || return 1
    
    cat > "$temp_script" << 'PYSCRIPT'
#!/usr/bin/env python3
import json
import sys
from pathlib import Path

# Last argument is the summary file
summary_file = sys.argv[-1]
results_files = sys.argv[1:-1]

portfolio_metrics = {
    'symbols': [],
    'metrics': {}
}

for file in results_files:
    if Path(file).exists():
        with open(file, 'r') as f:
            result = json.load(f)
            symbol = result.get('symbol', 'UNKNOWN')
            portfolio_metrics['symbols'].append(symbol)
            portfolio_metrics['metrics'][symbol] = {
                'data_source': result.get('data_source') or 'unknown',
                'total_pnl': result.get('total_pnl', 0),
                'win_rate': result.get('win_rate', 0),
                'sharpe_ratio': result.get('sharpe_ratio', 0),
                'max_drawdown': result.get('max_drawdown', 0),
                'profit_factor': result.get('profit_factor', 0)
            }

# Calculate portfolio-level metrics
total_pnl = sum(m.get('total_pnl', 0) for m in portfolio_metrics['metrics'].values())
portfolio_metrics['portfolio_total_pnl'] = total_pnl
portfolio_metrics['num_symbols'] = len(portfolio_metrics['symbols'])
sources = sorted({m['data_source'] for m in portfolio_metrics['metrics'].values()})
portfolio_metrics['data_sources'] = sources
if 'synthetic' in sources:
    portfolio_metrics['warning'] = 'Includes backtests on SYNTHETIC prices (demo/test mode), not market data.'

with open(summary_file, 'w') as f:
    json.dump(portfolio_metrics, f, indent=2)

print(summary_file)
PYSCRIPT
    
    python3 "$temp_script" "${results_files[@]}" "$summary_file" 2>/dev/null
    rm -f "$temp_script"
    
    log_info "Portfolio summary: $summary_file"
}

# ============================================================================
# Public API
# ============================================================================

# Export functions
export -f backtest_strategy
export -f backtest_multi_symbol
export -f generate_backtest_reports
export -f log_info
export -f log_error
export -f log_warn
export -f log_debug
