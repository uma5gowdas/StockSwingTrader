"""Strategy Validation Agent (plan items 15-20, decisions D16-D22).

engine       vectorbt OSS backtests: legacy-parity mode and gate mode
walkforward  calendar / bar-count folds and train-only tuning
stats        Sharpe, max drawdown, PSR, DSR, PBO (CSCV)
benchmarks   SPY and equal-weight buy-and-hold over the test folds
trials       JSONL trial log (DSR trial count)
gate         §5.6 criteria and gate files cache/agents/gates/<signal_id>.json
report       report.json + self-contained report.html
agent        `python -m agents validate gate|parity|status`
"""
