"""StockSwingTrader agent layer (Phase 0-2).

Batch Python agents that write JSON envelopes to cache/agents/; the bash scan
only reads those files (lib/agent_adapter.sh). Nothing in this package can
place, cancel or modify orders.
"""

__version__ = "0.2.0"

# Every agent name accepted by the CLI and the cache layout
AGENT_NAMES = ("market", "fundamental", "technical", "quant", "validate", "portfolio")
